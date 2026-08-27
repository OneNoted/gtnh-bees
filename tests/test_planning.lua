local H=require("tests.harness")
local Catalog=require("gtnh_bees.catalog")
local Official=require("gtnh_bees.official_driver")
local Operations=require("gtnh_bees.operations")
local Planner=require("gtnh_bees.planner")
local util=require("gtnh_bees.util")

local function bee(caste,uid,slot,size,genome)
  return {caste=caste,active=uid,inactive=uid,scanned=true,size=size or 1,maxSize=64,
    genome=genome or {uid=uid},inventory="bee_storage",slot=slot}
end

H.test("conversion retry follows exact stored lineage through duplicate genomes",function()
  local source=bee("princess","b",1,1,{same=true})
  local duplicate=bee("princess","b",2,1,{same=true})
  local drone=bee("drone","a",4,4,{uid="a"})
  local stock={source,duplicate,drone}
  local calls=0
  local fake={recover_pending=function()return{}end,snapshot_storage=function()return{size=8,reserved_slot=8,bees=stock}end,
    list_species=function()return{{uid="a",name="A"},{uid="b",name="B"}}end,list_mutations=function()return{}end,
    convert_one=function(_,uid,princess)
      calls=calls+1
      if calls==1 then
        H.equal(princess.slot,1)
        source.slot=3
        return{safe=true,complete=false,uid=uid,princess_identity="b",retained_princess=util.copy(source),location="bee_storage",error="ordinary miss"}
      end
      H.equal(princess.slot,3)
      source.active,source.inactive,source.genome=uid,uid,{uid=uid}
      return{safe=true,complete=true,uid=uid,princess_identity="b",location="bee_storage"}
    end}
  local result=assert(Operations.new(fake,{limits={conversion=2,conversion_generations=3}}):convert({species="A",count=1,all=false}))
  H.truthy(result.success);H.equal(calls,2)
end)

H.test("conversion retry rejects absent physical evidence among duplicate genomes",function()
  local stock={bee("princess","b",1,1,{same=true}),bee("princess","b",2,1,{same=true}),bee("drone","a",3)}
  local calls=0
  local fake={recover_pending=function()return{}end,snapshot_storage=function()return{size=5,reserved_slot=5,bees=stock}end,
    list_species=function()return{{uid="a",name="A"},{uid="b",name="B"}}end,list_mutations=function()return{}end,
    convert_one=function(_,uid,princess)calls=calls+1;return{safe=true,complete=false,uid=uid,princess_identity=princess.active,location="bee_storage",error="ordinary miss"}end}
  local value,err=Operations.new(fake,{limits={conversion=2,conversion_generations=3}}):convert({species="A",count=1,all=false})
  H.falsy(value);H.contains(err,"exact ordinary bee_storage slot");H.equal(calls,1)
end)

H.test("official conversion collects return_output final storage evidence",function()
  local machine={}
  local adapter={config={roles={breeder={princess_slot=1,drone_slot=2,output_slots={3,4},terminal_stable_polls=2}},limits={scanning=1}}}
  function adapter:raw_stack(role,slot)if role=="breeder"then return machine[slot]end end
  function adapter:transfer_verified(_,_,role,slot)
    H.equal(role,"breeder");machine[slot]={size=1}
    if slot==2 then
      machine[1],machine[2]=nil,nil
      machine[3]={size=1,decoded={caste="princess",active="a",inactive="a",scanned=true,size=1,maxSize=1,genome={uid="a"}}}
      machine[4]={size=1,decoded={caste="drone",active="a",inactive="a",scanned=true,size=1,maxSize=64,genome={uid="a"}}}
    end
    return 1
  end
  function adapter:decode(raw)return raw.decoded end
  function adapter:return_output(_,slot,decoded)
    machine[slot]=nil
    local stored=util.copy(decoded);stored.inventory,stored.slot="bee_storage",slot+10
    return true,stored
  end
  function adapter:wait_tick()end
  local result=assert(Official.convert_generation(adapter,"a",bee("princess","b",1),bee("drone","a",2),4))
  H.truthy(result.complete);H.equal(result.retained_princess.inventory,"bee_storage");H.equal(result.retained_princess.slot,13)
end)

H.test("official conversion retains a target-active princess until its full genome matches the source drone",function()
  local machine={}
  local adapter={config={roles={breeder={princess_slot=1,drone_slot=2,output_slots={3,4},terminal_stable_polls=2}},limits={scanning=1}}}
  function adapter:raw_stack(role,slot)if role=="breeder"then return machine[slot]end end
  function adapter:transfer_verified(_,_,role,slot)
    H.equal(role,"breeder");machine[slot]={size=1}
    if slot==2 then
      machine[1],machine[2]=nil,nil
      machine[3]={size=1,decoded={caste="princess",active="a",inactive="a",scanned=true,size=1,maxSize=1,genome={line="mixed"}}}
      machine[4]={size=1,decoded={caste="drone",active="a",inactive="a",scanned=true,size=1,maxSize=64,genome={line="target"}}}
    end
    return 1
  end
  function adapter:decode(raw)return raw.decoded end
  function adapter:return_output(_,slot,decoded)
    machine[slot]=nil
    local stored=util.copy(decoded);stored.inventory,stored.slot="bee_storage",slot+10
    return true,stored
  end
  function adapter:wait_tick()end
  local result=assert(Official.convert_generation(adapter,"a",bee("princess","b",1,1,{line="source"}),bee("drone","a",2,1,{line="target"}),4))
  H.falsy(result.complete)
  H.falsy(result.converted)
  H.equal(result.retained_princess.active,"a")
  H.contains(result.error,"full-genome-compatible")
end)

local function imprint_adapter(success_generation)
  local template=bee("drone","template",8,1,{mark="template"})
  local princess=bee("princess","a",1,1,{mark="target"})
  local donor=bee("drone","template",2,1,{mark="template"})
  local calls=0
  return {snapshot_storage=function()return{size=8,reserved_slot=8,bees={princess,donor,template}}end,
    imprint_one=function(_,uid)
      calls=calls+1
      local complete=calls==success_generation
      return{safe=true,complete=complete,uid=uid,scanned=complete,template_retained=true,retained_princess=complete and nil or util.copy(princess),location="bee_storage",error=complete and nil or"graded mismatch"}
    end},function()return calls end
end

H.test("safe graded imprint mismatches retry through third-generation success",function()
  local fake,calls=imprint_adapter(3)
  local result=assert(Operations.new(fake,{limits={imprint=3}}):optional_imprint("a"))
  H.equal(result.generations,3);H.equal(calls(),3)
end)

H.test("safe graded imprint mismatches exhaust the finite generation budget",function()
  local fake,calls=imprint_adapter(99)
  local result,err,safe=Operations.new(fake,{limits={imprint=3}}):optional_imprint("a")
  H.falsy(result);H.truthy(safe);H.contains(err,"exceeded 3");H.equal(calls(),3)
end)

H.test("drone-only stock is not executable conversion capability",function()
  local catalog=Catalog.new();assert(catalog:add_species({uid="a"}));assert(catalog:add_species({uid="b"}))
  local blocked=Planner.reachable(catalog,{princess={},drone={a=true},convertible={a=true}})
  H.falsy(blocked.roles.princess.a);H.falsy(blocked.targets.a)
  local viable=Planner.reachable(catalog,{princess={b=true},drone={a=true},convertible={a=true}})
  H.truthy(viable.roles.princess.a);H.truthy(viable.targets.a)
end)

H.test("incompatible same-species stock uses a viable mutation before archive",function()
  local c_princess=bee("princess","c",5,1,{line="old-princess"})
  local c_drone=bee("drone","c",6,1,{line="old-drone"})
  local stock={bee("princess","a",1),bee("drone","a",2),bee("princess","b",3),bee("drone","b",4),c_princess,c_drone}
  local events={}
  local fake={recover_pending=function()return{}end,snapshot_storage=function()return{size=10,reserved_slot=10,bees=stock}end,
    list_species=function()return{{uid="a"},{uid="b"},{uid="c",name="C"}}end,
    list_mutations=function()return{{result="c",parents={"a","b"},chance=100}}end,
    convert_one=function(_,uid,princess)
      events[#events+1]="conversion:"..uid
      return{safe=true,complete=false,uid=uid,princess_identity=princess.active,retained_princess=util.copy(princess),location="bee_storage",route_failure="deterministic",error="validated incompatible conversion"}
    end,
    produce_species=function(_,step)
      events[#events+1]="mutation:"..step.uid
      c_princess.genome,c_drone.genome={line="fresh"},{line="fresh"}
      return{safe=true,complete=true,uid=step.uid,location="bee_storage",outputs={c_princess,c_drone}}
    end,
    expand_archive=function(_,uid)
      events[#events+1]="archive:"..uid;c_drone.size=32
      return{safe=true,complete=true,uid=uid,location="bee_storage",outputs={c_drone}}
    end}
  local result=assert(Operations.new(fake,{limits={progress=4,archive=2}}):breed({species="C",imprint="none",pause=false}))
  H.truthy(result.success);H.equal(events,{"conversion:c","mutation:c","archive:c"})
end)

H.test("breed retries a transient foundation failure without excluding its route",function()
  local stock={bee("princess","a",1),bee("drone","a",2),bee("princess","b",3),bee("drone","b",4)}
  local calls=0
  local fake={recover_pending=function()return{}end,snapshot_storage=function()return{size=8,reserved_slot=8,bees=stock}end,
    list_species=function()return{{uid="a"},{uid="b"},{uid="c",name="C"}}end,
    list_mutations=function()return{{result="c",parents={"a","b"},chance=100}}end,
    produce_species=function(_,step)
      calls=calls+1
      if calls==1 then return{safe=true,complete=false,uid=step.uid,location="bee_storage",outputs={},route_failure="transient",error="foundation robot did not reply"}end
      stock[#stock+1]=bee("princess","c",5);stock[#stock+1]=bee("drone","c",6)
      return{safe=true,complete=true,uid=step.uid,location="bee_storage",outputs={stock[#stock-1],stock[#stock]}}
    end,
    expand_archive=function(_,uid)stock[#stock].size=32;return{safe=true,complete=true,uid=uid,location="bee_storage",outputs={stock[#stock]}}end}
  local result=assert(Operations.new(fake,{limits={progress=4,mutation_generations=2,archive=2}}):breed({species="C",imprint="none",pause=false}))
  H.truthy(result.success);H.equal(calls,2)
end)

H.test("intermediate imprint waits until downstream production and archive finish",function()
  local stock={bee("princess","a",1),bee("drone","a",2),bee("princess","b",3),bee("drone","b",4),bee("drone","d",5)}
  stock[#stock+1]=bee("drone","template",19,1,{mark="template"})
  stock[#stock+1]=bee("drone","template",20,1,{mark="template"})
  local events={}
  local fake={recover_pending=function()return{}end,snapshot_storage=function()return{size=20,reserved_slot=20,bees=stock}end,
    list_species=function()return{{uid="a"},{uid="b"},{uid="c"},{uid="d"},{uid="e",name="E"},{uid="template"}}end,
    list_mutations=function()return{{result="c",parents={"a","b"},chance=100},{result="e",parents={"c","d"},chance=100}}end,
    produce_species=function(_,step)
      events[#events+1]="produce:"..step.uid
      local slot=step.uid=="c"and 6 or 8
      stock[#stock+1]=bee("princess",step.uid,slot,1,{uid=step.uid})
      stock[#stock+1]=bee("drone",step.uid,slot+1,1,{uid=step.uid})
      return{safe=true,complete=true,uid=step.uid,location="bee_storage",outputs={stock[#stock-1],stock[#stock]}}
    end,
    expand_archive=function(_,uid)
      events[#events+1]="archive:"..uid
      for _,item in ipairs(stock)do if item.caste=="drone"and item.active==uid then item.size=32 end end
      return{safe=true,complete=true,uid=uid,location="bee_storage",outputs={}}
    end,
    imprint_one=function(_,uid)
      events[#events+1]="imprint:"..uid
      return{safe=true,complete=true,uid=uid,scanned=true,template_retained=true,location="bee_storage"}
    end}
  local result=assert(Operations.new(fake,{limits={progress=8,archive=2,imprint=2}}):breed({species="E",imprint="intermediate",pause=false}))
  H.truthy(result.success);H.equal(events,{"produce:c","produce:e","archive:e","imprint:c"})
end)

H.test("dependency solver fills only one oriented role for each parent",function()
  local catalog=Catalog.new()
  for _,uid in ipairs({"a","b","x","y","target"})do assert(catalog:add_species({uid=uid}))end
  assert(catalog:add_route({result="y",parents={"a","b"},chance=100}))
  assert(catalog:add_route({result="target",parents={"x","y"},chance=100}))
  local roles={princess={x=true,a=true},drone={b=true},convertible={b=true},population={}}
  local steps=assert(Planner.dependencies(catalog,"target",roles))
  H.equal(#steps,2);H.equal(steps[1].uid,"y");H.equal(steps[1].orientation,{princess="a",drone="b"})
  H.equal(steps[2].uid,"target");H.equal(steps[2].orientation,{princess="x",drone="y"})
end)
