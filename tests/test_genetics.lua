local H=require("tests.harness")
local Catalog=require("gtnh_bees.catalog")
local Config=require("gtnh_bees.config")
local Official=require("gtnh_bees.official_driver")
local Operations=require("gtnh_bees.operations")

local function discovery(species,mutations)
  local adapter={}
  function adapter:invoke(_,method)
    if method=="listAllSpecies" then return species end
    if method=="getBeeBreedingData" then return mutations end
    return nil,"unexpected callback"
  end
  return adapter,{address="housing"}
end

H.test("official references reject case-folded label and UID collisions but accept explicit UID shapes",function()
  local species={{uid="uid.a",name="Twin"},{uid="uid.b",name="twin"},{uid="Twin",name="Third"}}
  local ambiguous,role=discovery(species,{{allele1="TWIN",allele2="Third",result="Third"}})
  Official.list_species(nil,role,ambiguous)
  local ok,err=pcall(function()Official.list_mutations(nil,role,ambiguous)end)
  H.falsy(ok);H.contains(err,"ambiguous across stable UIDs");H.contains(err,"uid.a");H.contains(err,"uid.b")

  local explicit,explicit_role=discovery(species,{{allele1={uid="uid.a"},allele2={uid="uid.b"},result={uid="Twin"}}})
  Official.list_species(nil,explicit_role,explicit)
  local route=Official.list_mutations(nil,explicit_role,explicit)[1]
  H.equal(route.parents,{"uid.a","uid.b"});H.equal(route.result,"Twin")
end)

local function parent(caste,slot,active)
  return {inventory="bee_storage",slot=slot,caste=caste,active=active,inactive=active}
end

H.test("stacked unanalyzed breeder offspring are scanned one physical bee at a time",function()
  local machine,scanned={},0
  local adapter={config={roles={
    breeder={princess_slot=1,drone_slot=2,output_slots={3},terminal_stable_polls=2},
    scanner={input_slot=1,output_slots={2},component_address="analyzer"},
    bee_storage={address="tx",side=0,reserved_slot=8,caste_items={drone_item="drone",princess_item="princess",queen_item="queen"}}
  },limits={scanning=2}}}
  function adapter:raw_stack(role,slot)
    if role=="breeder" then return machine[slot] end
    return nil
  end
  function adapter:transfer_verified(_,_,to_role,to_slot)
    if to_role=="breeder" and to_slot==1 then machine[1]={name="princess_item",size=1};return 1 end
    if to_role=="breeder" and to_slot==2 then
      machine[1],machine[2]=nil,nil
      machine[3]={name="drone_item",size=3,maxSize=64}
      return 1
    end
    return nil,"unexpected transfer"
  end
  function adapter:decode()return nil,"bee analysis is required"end
  function adapter:wait_tick()end
  local original_scan=Official.scan_generation
  Official.scan_generation=function(_,transport)
    H.equal(transport.slot,3)
    scanned=scanned+1
    machine[3].size=machine[3].size-1
    if machine[3].size==0 then machine[3]=nil end
    local bee={caste="drone",active="child",inactive="child",genome={active={species="child"},inactive={species="child"}},scanned=true,size=1,maxSize=64}
    return {operation="scanning",safe=true,complete=true,bee=bee,identity={caste="drone",active="child",inactive="child"},location="bee_storage",scanned=true}
  end
  local ok,value=pcall(Official.breed_generation,adapter,{uid="child",princess=parent("princess",1,"a"),drone=parent("drone",2,"b")},4)
  Official.scan_generation=original_scan
  H.truthy(ok,value);H.truthy(value.safe);H.truthy(value.complete);H.equal(scanned,3);H.equal(#value.outputs,3);H.falsy(machine[3])
end)

local function terminal_adapter(options)
  options=options or {}
  local machine,ticks={},{value=0}
  local adapter={config={roles={
    breeder={princess_slot=1,drone_slot=2,output_slots={3},minimum_outputs=1,terminal_stable_polls=2},
    bee_storage={address="tx",side=0,reserved_slot=8,caste_items={drone_item="drone",princess_item="princess",queen_item="queen"}},
    scanner={input_slot=1,output_slots={2},component_address="analyzer"}
  },limits={scanning=1}}}
  function adapter:raw_stack(role,slot)if role=="breeder" then return machine[slot] end end
  function adapter:transfer_verified(_,_,to_role,to_slot)
    if to_role~="breeder" then return nil,"unexpected transfer" end
    machine[to_slot]={name=to_slot==1 and "princess_item" or "drone_item",size=1,decoded={caste=to_slot==1 and "princess" or "drone",active=to_slot==1 and "a" or "b",inactive=to_slot==1 and "a" or "b",size=1}}
    if to_slot==2 then
      if not options.keep_inputs then machine[1],machine[2]=nil,nil end
      machine[3]={name="drone_item",size=1,decoded={caste="drone",active="child",inactive="child",size=1}}
    end
    return 1
  end
  function adapter:decode(raw)return raw.decoded end
  function adapter:return_output(_,slot)machine[slot]=nil;return true end
  function adapter:wait_tick()
    ticks.value=ticks.value+1
    if options.late and ticks.value==2 then machine[3]={name="drone_item",size=1,decoded={caste="drone",active="late",inactive="late",size=1}} end
  end
  return adapter,machine
end

H.test("minimum output occupancy cannot complete while breeder inputs remain",function()
  local adapter,machine=terminal_adapter({keep_inputs=true})
  local result=Official.breed_generation(adapter,{uid="child",princess=parent("princess",1,"a"),drone=parent("drone",2,"b")},3)
  H.truthy(result.safe);H.falsy(result.complete);H.contains(result.error,"stable terminal state");H.falsy(machine[1]);H.falsy(machine[2]);H.falsy(machine[3])
end)

H.test("late breeder output fails completion closed and is recovered",function()
  local adapter,machine=terminal_adapter({late=true})
  local result=Official.breed_generation(adapter,{uid="child",princess=parent("princess",1,"a"),drone=parent("drone",2,"b")},4)
  H.truthy(result.safe);H.falsy(result.complete);H.contains(result.error,"late or unsettled");H.falsy(machine[3])
end)

local function stocked(caste,uid,slot,size)
  return {inventory="bee_storage",slot=slot,caste=caste,active=uid,inactive=uid,scanned=true,size=size or 1,maxSize=64,genome={uid=uid}}
end

local function route_adapter(route_behavior,with_alternate)
  local bees={stocked("princess","a",1),stocked("drone","a",2,32),stocked("princess","b",3),stocked("drone","b",4,32)}
  if with_alternate then bees[#bees+1]=stocked("princess","d",5);bees[#bees+1]=stocked("drone","d",6,32) end
  local fake={config={}}
  function fake:recover_pending()return {}end
  function fake:snapshot_storage()return {size=10,reserved_slot=10,bees=bees}end
  function fake:list_species()
    local out={{uid="a"},{uid="b"},{uid="c"}}
    if with_alternate then out[#out+1]={uid="d"} end
    return out
  end
  function fake:list_mutations()
    local out={{result="c",parents={"a","b"},chance=90}}
    if with_alternate then out[#out+1]={result="c",parents={"a","d"},chance=80} end
    return out
  end
  function fake:produce_species(step)
    local value,err=route_behavior(step,bees)
    return value,err
  end
  return fake
end

H.test("unsafe or malformed breeding attestation is fatal and never permits an alternate movement",function()
  for _,bad in ipairs({
    {safe=false,complete=false,error="lost bee",location="breeder slot 3",uid="c",outputs={}},
    {safe=true,complete=true,uid="c",outputs={}}
  }) do
    local calls=0
    local fake=route_adapter(function()calls=calls+1;return bad end,true)
    local value,err=Operations.new(fake,{limits={progress=8,mutation_generations=2}}):complete({imprint="none"})
    H.falsy(value);H.truthy(err);H.equal(calls,1)
  end
end)

H.test("safe ordinary mutation miss retries the same route within its configured budget",function()
  local calls={}
  local fake=route_adapter(function(step,bees)
    calls[#calls+1]=table.concat(step.route.parents,"+")
    if #calls==1 then return {safe=true,complete=false,uid="c",location="bee_storage",outputs={},error="ordinary chance miss"} end
    bees[#bees+1]=stocked("princess","c",7);bees[#bees+1]=stocked("drone","c",8,32)
    return {safe=true,complete=true,uid="c",location="bee_storage",outputs={bees[#bees-1],bees[#bees]}}
  end,false)
  local outcome=assert(Operations.new(fake,{limits={progress=8,mutation_generations=3}}):complete({imprint="none"}))
  H.equal(calls,{"a+b","a+b"});H.equal(outcome.missing,{})
end)

H.test("transient foundation failure retries the same route within its configured budget",function()
  local calls={}
  local fake=route_adapter(function(step,bees)
    calls[#calls+1]=table.concat(step.route.parents,"+")
    if #calls==1 then
      return {safe=true,complete=false,uid="c",location="bee_storage",outputs={},route_failure="transient",error="foundation robot did not reply"}
    end
    bees[#bees+1]=stocked("princess","c",7);bees[#bees+1]=stocked("drone","c",8,32)
    return {safe=true,complete=true,uid="c",location="bee_storage",outputs={bees[#bees-1],bees[#bees]}}
  end,false)
  local outcome=assert(Operations.new(fake,{limits={progress=8,mutation_generations=3}}):complete({imprint="none"}))
  H.equal(calls,{"a+b","a+b"});H.equal(outcome.missing,{})
end)

H.test("explicit deterministic safe route failure permits a deterministic alternate",function()
  local calls={}
  local fake=route_adapter(function(step,bees)
    calls[#calls+1]=table.concat(step.route.parents,"+")
    if step.route.parents[2]=="b" then return {safe=true,complete=false,uid="c",location="bee_storage",outputs={},route_failure="deterministic",error="installation rejects route"} end
    bees[#bees+1]=stocked("princess","c",7);bees[#bees+1]=stocked("drone","c",8,32)
    return {safe=true,complete=true,uid="c",location="bee_storage",outputs={}}
  end,true)
  local outcome=assert(Operations.new(fake,{limits={progress=8,mutation_generations=3}}):complete({imprint="none"}))
  H.equal(calls,{"a+b","a+d"});H.equal(outcome.missing,{})
end)

local function official_config()
  return {archive_size=32,driver_module="gtnh_bees.official_driver",limits={transfer=2},network={},roles={
    genetics={address="g"},
    bee_storage={address="t",side=0,reserved_slot=8,caste_items={p="princess",d="drone",q="queen"}},
    breeder={address="t",side=1,princess_slot=1,drone_slot=2,output_slots={3},terminal_stable_polls=2},
    scanner={address="t",side=2,component_address="s",input_slot=1,output_slots={2}},
    recovery={address="t",side=3,output_slots={1}}
  }}
end

H.test("exact condition mappings drive only validated foundation and satisfaction policies",function()
  local adapter={config={mutation_conditions={
    ["Exact foundation condition"]={policy="foundation",foundation="minecraft:stone"},
    ["Operator-verified enclosure"]={policy="satisfied"}
  }}}
  function adapter:list_species()return {{uid="a"},{uid="b"},{uid="c"}}end
  function adapter:list_mutations()return {{result="c",parents={"a","b"},conditions={"Exact foundation condition","Operator-verified enclosure","exact foundation condition"}}}end
  local catalog=assert(Catalog.discover(adapter));local conditions=catalog.routes[1].conditions
  H.equal(conditions[1].foundation,"minecraft:stone");H.falsy(conditions[1].satisfied)
  H.truthy(conditions[2].satisfied)
  H.falsy(conditions[3].satisfied);H.falsy(conditions[3].foundation);H.equal(conditions[3].identity,"exact foundation condition")

  local config=official_config();config.mutation_conditions={x={policy="foundation",foundation="not-namespaced"}}
  local valid,err=Config.validate(config);H.falsy(valid);H.contains(err,"namespaced")
end)

H.test("custom driver configuration is not forced through bundled analyzer topology or callback checks",function()
  local config={archive_size=32,driver_module="installation.custom_driver",limits={transfer=2},network={},roles={
    genetics={address="g",breed_method="custom-contract-data"},
    bee_storage={address="t",side=0,reserved_slot=8},
    breeder={address="t",side=1},scanner={address="t",side=2},recovery={address="t",side=3}
  }}
  H.truthy(Config.validate(config))
end)

H.test("configuration replacement reports both rename failures and both retained paths",function()
  local config={archive_size=32,driver_module="installation.custom_driver",limits={transfer=2},network={},roles={
    genetics={address="g"},bee_storage={address="t",side=0,reserved_slot=8},breeder={address="t",side=1},scanner={address="t",side=2},recovery={address="t",side=3}
  }}
  local path="/tmp/gtnh-bees-genetics-save.cfg"
  os.remove(path..".new")
  local files={[path]=true}
  local fs={}
  function fs.exists(name)return files[name]==true end
  function fs.remove(name)files[name]=nil;return true end
  function fs.rename(source,destination)
    if source==path and destination==path..".previous" then files[source]=nil;files[destination]=true;return true end
    if source==path..".new" and destination==path then return nil,"install rename boom" end
    if source==path..".previous" and destination==path then return nil,"restore rename boom" end
    return nil,"unexpected rename"
  end
  local ok,err=Config.save(config,path,fs)
  os.remove(path..".new")
  H.falsy(ok);H.contains(err,"install rename boom");H.contains(err,"restore rename boom");H.contains(err,path..".previous");H.contains(err,path..".new");H.truthy(files[path..".previous"])
end)
