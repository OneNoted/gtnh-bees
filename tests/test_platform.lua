local H=require("tests.harness")
local Adapter=require("gtnh_bees.hardware")
local Application=require("gtnh_bees.application")
local Catalog=require("gtnh_bees.catalog")
local Official=require("gtnh_bees.official_driver")
local Operations=require("gtnh_bees.operations")
local util=require("gtnh_bees.util")

local function bee(caste,uid,slot,size,genome)
  return {caste=caste,active=uid,inactive=uid,scanned=true,size=size or 1,maxSize=64,genome=genome or {uid=uid},inventory="bee_storage",slot=slot}
end

local function imprint_cycle(target_matches)
  local machine={}
  local template_genome={mark="template"}
  local adapter={config={roles={
    breeder={princess_slot=1,drone_slot=2,output_slots={3,4},terminal_stable_polls=2},
    bee_storage={reserved_slot=8}
  },limits={scanning=1}}}
  function adapter:raw_stack(role,slot)if role=="breeder"then return machine[slot]end end
  function adapter:transfer_verified(_,_,to_role,to_slot)
    if to_role~="breeder"then return nil,"unexpected transfer"end
    machine[to_slot]={size=1}
    if to_slot==2 then
      machine[1],machine[2]=nil,nil
      machine[3]={size=1,decoded={caste="princess",active=target_matches and "template"or"target",inactive=target_matches and"template"or"target",scanned=true,size=1,maxSize=1,genome=target_matches and util.copy(template_genome)or{mark="unchanged"}}}
      machine[4]={size=1,decoded={caste="drone",active="template",inactive="template",scanned=true,size=1,maxSize=64,genome=util.copy(template_genome)}}
    end
    return 1
  end
  function adapter:decode(raw)return raw.decoded end
  function adapter:return_output(_,slot)machine[slot]=nil;return true end
  function adapter:wait_tick()end
  local template=bee("drone","template",8,1,template_genome)
  local princess=bee("princess","target",1,1,{mark="unchanged"})
  local donor=bee("drone","template",2,1,template_genome)
  return Official.imprint_generation(adapter,"target",template,4,princess,donor)
end

H.test("official imprint rejects a donor-only template genome match",function()
  local result=assert(imprint_cycle(false))
  H.truthy(result.safe);H.falsy(result.complete);H.falsy(result.scanned);H.contains(result.error,"target princess lineage")
end)

H.test("official imprint accepts the explicitly graded target princess lineage",function()
  local result=assert(imprint_cycle(true))
  H.truthy(result.safe);H.truthy(result.complete);H.truthy(result.scanned);H.truthy(result.template_retained)
end)

H.test("imprint all selects only species with ordinary princess stock",function()
  local template=bee("drone","template",6,1,{mark="template"})
  local stock={bee("princess","a",1),bee("drone","b",2,32),bee("drone","b",3,1,{mark="template"}),template}
  local calls={}
  local fake={
    recover_pending=function()return{}end,
    snapshot_storage=function()return{size=6,reserved_slot=6,bees=stock}end,
    list_species=function()return{{uid="a"},{uid="b"}}end,list_mutations=function()return{}end,
    imprint_one=function(_,uid,_,princess,donor)
      calls[#calls+1]=uid
      H.equal(princess.caste,"princess");H.equal(princess.active,"a");H.equal(donor.slot,3)
      return{safe=true,complete=true,uid=uid,scanned=true,template_retained=true,location="bee_storage"}
    end
  }
  local result=assert(Operations.new(fake,{limits={imprint=2}}):imprint({}))
  H.truthy(result.success);H.equal(calls,{"a"})
end)

H.test("standalone imprint analyzes ordinary storage but rejects an unanalyzed reserved template",function()
  local function adapter(template_scanned)
    local princess=bee("princess","a",1);princess.scanned=false
    local donor=bee("drone","template",2,1,{mark="template"})
    local template=bee("drone","template",4,1,{mark="template"});template.scanned=template_scanned
    local prepared,imprints=0,0
    return {
      recover_pending=function()return{}end,
      prepare_storage=function()
        prepared=prepared+1
        if not template.scanned then return nil,"reserved template cannot be verified in place: bee analysis is required"end
        princess.scanned=true
        return true
      end,
      snapshot_storage=function()
        if not princess.scanned then return nil,"bee analysis is required"end
        return{size=4,reserved_slot=4,bees={princess,donor,template}}
      end,
      list_species=function()return{{uid="a",name="A"},{uid="template"}}end,list_mutations=function()return{}end,
      imprint_one=function(_,uid)
        imprints=imprints+1
        return{safe=true,complete=true,uid=uid,scanned=true,template_retained=true,location="bee_storage"}
      end
    },function()return prepared,imprints end
  end

  local ready,calls=adapter(true)
  local outcome=assert(Operations.new(ready,{limits={imprint=2}}):imprint({species="A"}))
  H.truthy(outcome.success);H.equal({calls()},{1,1})

  local rejected,rejected_calls=adapter(false)
  local value,err=Operations.new(rejected,{limits={imprint=2}}):imprint({species="A"})
  H.falsy(value);H.contains(err,"reserved template cannot be verified in place");H.equal({rejected_calls()},{1,0})
end)

local function incomplete_complete_adapter()
  local stock={bee("princess","a",1),bee("drone","a",2,32),bee("princess","b",3),bee("drone","b",4,32)}
  return {
    recover_pending=function()return{}end,
    snapshot_storage=function()return{size=6,reserved_slot=6,bees=stock}end,
    list_species=function()return{{uid="a",name="A"},{uid="b",name="B"},{uid="c",name="C"}}end,
    list_mutations=function()return{{result="c",parents={"a","b"},chance=10}}end,
    produce_species=function()return{safe=true,complete=false,uid="c",location="bee_storage",outputs={},route_failure="deterministic",error="fixed route rejected"}end
  }
end

H.test("incomplete complete preserves diagnostics and makes application status fail",function()
  local lines={}
  local app=Application.new(function()return incomplete_complete_adapter(),{archive_size=32,complete_imprint="none",limits={progress=4}}end,function(line)lines[#lines+1]=line end)
  local ok,err,result=app:execute({name="complete"})
  H.falsy(ok);H.falsy(result.success);H.equal(result.safety_state,"known_safe");H.equal(result.missing[1].uid,"c");H.contains(result.missing[1].reason,"fixed route rejected");H.contains(err,"still missing");H.contains(table.concat(lines,"\n"),"Missing archives")
end)

H.test("complete remains successful when its final bounded step finishes the last target",function()
  local stock={bee("princess","a",1),bee("drone","a",2,32),bee("princess","b",3),bee("drone","b",4,32)}
  local fake={recover_pending=function()return{}end,snapshot_storage=function()return{size=8,reserved_slot=8,bees=stock}end,
    list_species=function()return{{uid="a"},{uid="b"},{uid="c"}}end,list_mutations=function()return{{result="c",parents={"a","b"},chance=100}}end,
    produce_species=function(_,step)stock[#stock+1]=bee("princess",step.uid,5);stock[#stock+1]=bee("drone",step.uid,6,32);return{safe=true,complete=true,uid=step.uid,location="bee_storage",outputs={stock[#stock-1],stock[#stock]}}end}
  local result=assert(Operations.new(fake,{limits={progress=1}}):complete({imprint="none"}))
  H.truthy(result.success);H.equal(result.missing,{})
end)

local function direct_conversion_adapter(behavior)
  local source=bee("princess","b",1)
  local drone=bee("drone","a",2,8)
  local stock={source,drone}
  local calls=0
  return {
    recover_pending=function()return{}end,
    snapshot_storage=function()return{size=4,reserved_slot=4,bees=stock}end,
    list_species=function()return{{uid="a",name="A"},{uid="b",name="B"}}end,list_mutations=function()return{}end,
    convert_one=function(_,uid,princess)
      calls=calls+1
      return behavior(calls,uid,princess,source)
    end
  },function()return calls end
end

H.test("direct conversion retries an ordinary safe miss for the same source",function()
  local fake,calls=direct_conversion_adapter(function(call,uid,princess,source)
    local source_uid=princess.active
    if call==1 then return{safe=true,complete=false,uid=uid,princess_identity=source_uid,retained_princess=util.copy(source),location="bee_storage",error="ordinary miss"}end
    source.active,source.inactive,source.genome=uid,uid,{uid=uid}
    return{safe=true,complete=true,uid=uid,princess_identity=source_uid,retained_princess=util.copy(source),location="bee_storage"}
  end)
  local result=assert(Operations.new(fake,{limits={conversion=2,conversion_generations=3}}):convert({species="A",count=1,all=false}))
  H.truthy(result.success);H.equal(result.converted,1);H.equal(calls(),2)
end)

H.test("dependency conversion retries ordinary misses before archiving",function()
  local source=bee("princess","b",1)
  local target_drone=bee("drone","a",2,1)
  local b_drone=bee("drone","b",3,32)
  local stock={source,target_drone,b_drone}
  local calls=0
  local fake={recover_pending=function()return{}end,snapshot_storage=function()return{size=6,reserved_slot=6,bees=stock}end,
    list_species=function()return{{uid="a"},{uid="b"}}end,list_mutations=function()return{}end,
    convert_one=function(_,uid,princess)
      calls=calls+1;local source_uid=princess.active
      if calls==1 then return{safe=true,complete=false,uid=uid,princess_identity=source_uid,retained_princess=util.copy(source),location="bee_storage",error="ordinary miss"}end
      source.active,source.inactive,source.genome=uid,uid,{uid=uid}
      return{safe=true,complete=true,uid=uid,princess_identity=source_uid,retained_princess=util.copy(source),location="bee_storage"}
    end,
    expand_archive=function(_,uid)target_drone.size=32;return{safe=true,complete=true,uid=uid,location="bee_storage",outputs={target_drone}}end}
  local result=assert(Operations.new(fake,{limits={progress=8,archive=2,conversion_generations=3}}):complete({imprint="none"}))
  H.truthy(result.success);H.equal(result.missing,{});H.equal(calls,2)
end)

local function conversion_route_adapter(deterministic)
  local c_drone=bee("drone","c",5,1)
  local stock={bee("princess","a",1),bee("drone","a",2,32),bee("princess","b",3),bee("drone","b",4,32),c_drone}
  local conversions,breeds=0,0
  return {recover_pending=function()return{}end,snapshot_storage=function()return{size=8,reserved_slot=8,bees=stock}end,
    list_species=function()return{{uid="a"},{uid="b"},{uid="c"}}end,list_mutations=function()return{{result="c",parents={"a","b"},chance=50}}end,
    convert_one=function(_,uid,princess)
      conversions=conversions+1
      return{safe=true,complete=false,uid=uid,princess_identity=princess.active,retained_princess=util.copy(princess),location="bee_storage",route_failure=deterministic and"deterministic"or nil,error=deterministic and"validated deterministic rejection"or"ordinary miss"}
    end,
    produce_species=function(_,step)
      breeds=breeds+1;stock[#stock+1]=bee("princess",step.uid,6);c_drone.size=32
      return{safe=true,complete=true,uid=step.uid,location="bee_storage",outputs={stock[#stock],c_drone}}
    end},function()return conversions,breeds end
end

H.test("ordinary conversion exhaustion does not exclude the conversion route",function()
  local fake,calls=conversion_route_adapter(false)
  local result=assert(Operations.new(fake,{limits={progress=8,conversion_generations=2}}):complete({imprint="none"}))
  local conversions,breeds=calls()
  H.falsy(result.success);H.equal(result.missing[1].uid,"c");H.equal(conversions,2);H.equal(breeds,0)
end)

H.test("only explicit deterministic conversion failure permits an alternate route",function()
  local fake,calls=conversion_route_adapter(true)
  local result=assert(Operations.new(fake,{limits={progress=8,conversion_generations=3}}):complete({imprint="none"}))
  local conversions,breeds=calls()
  H.truthy(result.success);H.equal(conversions,1);H.equal(breeds,1)
end)

H.test("malformed conversion route classification is fatal without retry",function()
  local fake,calls=direct_conversion_adapter(function(_,uid,princess)
    return{safe=true,complete=false,uid=uid,princess_identity=princess.active,location="bee_storage",route_failure="probabilistic"}
  end)
  local value,err=Operations.new(fake,{limits={conversion=2,conversion_generations=3}}):convert({species="A",count=1,all=false})
  H.falsy(value);H.contains(err,"malformed route-failure");H.equal(calls(),1)
end)

H.test("deterministic conversion classification cannot bypass retained-source proof",function()
  local source=bee("princess","b",1);local drone=bee("drone","a",2);local stock={source,drone};local calls=0
  local fake={recover_pending=function()return{}end,snapshot_storage=function()return{size=4,reserved_slot=4,bees=stock}end,
    list_species=function()return{{uid="a",name="A"},{uid="b",name="B"}}end,list_mutations=function()return{}end,
    convert_one=function(_,uid,princess)calls=calls+1;stock={drone};return{safe=true,complete=false,uid=uid,princess_identity=princess.active,location="bee_storage",route_failure="deterministic",error="claimed deterministic"}end}
  local value,err=Operations.new(fake,{limits={conversion=2,conversion_generations=3}}):convert({species="A",count=1,all=false})
  H.falsy(value);H.contains(err,"retained source princess");H.equal(calls,1)
end)

local function stacked_storage_adapter(progress)
  local inventories={}
  for side=0,3 do inventories[side]={size=4,slots={}}end
  inventories[0].slots[1]={name="raw_princess",size=5}
  inventories[0].slots[4]={name="template",size=1}
  local tx={}
  function tx.getInventorySize(side)return inventories[side].size end
  function tx.getStackInSlot(side,slot)return util.copy(inventories[side].slots[slot])end
  function tx.transferItem()return 0 end
  local scans=0
  local driver={
    list_species=function()return{{uid="a"}}end,list_mutations=function()return{}end,
    inspect_stack=function(raw)
      if raw.name=="raw_princess"then return nil,"bee analysis is required"end
      if raw.name=="analyzed_princess"then return{caste="princess",active="a",inactive="a",genome={uid="a"},scanned=true,size=raw.size,maxSize=64}end
      if raw.name=="template"then return{caste="drone",active="t",inactive="t",genome={uid="t"},scanned=true,size=1,maxSize=64}end
      return nil,"not a bee"
    end,
    identify_stack=function(raw,context)return{caste="princess",size=raw.size,maxSize=64,inventory=context.role,slot=context.slot,raw=raw}end,
    scan_generation=function(_,transport)
      scans=scans+1
      if progress then
        local raw=inventories[0].slots[transport.slot];raw.size=raw.size-1;if raw.size==0 then inventories[0].slots[transport.slot]=nil end
        local analyzed=inventories[0].slots[2]
        if analyzed then analyzed.size=analyzed.size+1 else inventories[0].slots[2]={name="analyzed_princess",size=1}end
      end
      return{safe=true,complete=true,identity={caste="princess",active="a",inactive="a"},location="bee_storage",scanned=true}
    end,
    breed_generation=function()end,convert_generation=function()end,imprint_generation=function()end
  }
  local config={roles={genetics={address="gen"},bee_storage={address="tx",side=0,reserved_slot=4},breeder={address="tx",side=1},scanner={address="tx",side=2},recovery={address="tx",side=3}},limits={transfer=2,scanning=2}}
  local runtime={component={proxy=function(address)return address=="tx"and tx or{}end},event={pull=function()end}}
  return assert(Adapter.new(config,driver,runtime)),inventories,function()return scans end
end

H.test("stacked storage analysis uses startup bee count rather than slot count",function()
  local adapter,inventories,calls=stacked_storage_adapter(true)
  H.truthy(adapter:prepare_storage());H.equal(calls(),5);H.falsy(inventories[0].slots[1]);H.equal(inventories[0].slots[2].size,5);H.equal(inventories[0].slots[4].name,"template")
  H.truthy(adapter:prepare_storage());H.equal(calls(),5)
end)

H.test("stacked storage analysis fails on unverified progress with known locations",function()
  local adapter,_,calls=stacked_storage_adapter(false)
  local ok,err=adapter:prepare_storage()
  H.falsy(ok);H.equal(calls(),1);H.contains(err,"no verified physical-bee progress");H.contains(err,"known storage")
end)

H.test("condition policy tables cannot bypass exact configured identities",function()
  local hostile={config={mutation_conditions={}},list_species=function()return{{uid="a"},{uid="b"},{uid="c"}}end,
    list_mutations=function()return{{result="c",parents={"a","b"},conditions={{satisfied=true,foundation="evil:block"}}}}end}
  local value,err=Catalog.discover(hostile);H.falsy(value);H.contains(err,"exact string identity")

  local mapped={config={mutation_conditions={Exact={policy="unmet"}}},list_species=hostile.list_species,
    list_mutations=function()return{{result="c",parents={"a","b"},conditions={identity="Exact",satisfied=true,foundation="evil:block"}}}end}
  local catalog=assert(Catalog.discover(mapped));local condition=catalog.routes[1].conditions[1]
  H.equal(condition.identity,"Exact");H.falsy(condition.satisfied);H.falsy(condition.foundation)
end)
