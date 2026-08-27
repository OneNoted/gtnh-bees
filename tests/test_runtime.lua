local H = require("tests.harness")
local Adapter = require("gtnh_bees.hardware")
local Application = require("gtnh_bees.application")
local Catalog = require("gtnh_bees.catalog")
local Config = require("gtnh_bees.config")
local Menu = require("gtnh_bees.menu")
local Official = require("gtnh_bees.official_driver")
local Operations = require("gtnh_bees.operations")
local Planner = require("gtnh_bees.planner")
local util = require("gtnh_bees.util")

local function callable(fn)
  return setmetatable({}, {__call=function(_, ...) return fn(...) end})
end

local function raw_bee(caste, active, inactive, slot, size, genome)
  return {
    caste=caste, active=active, inactive=inactive, scanned=true,
    size=size or 1, maxSize=64, genome=genome or {species=active}, slot=slot
  }
end

local function valid_config()
  return {
    archive_size=32,
    driver_module="gtnh_bees.official_driver",
    complete_imprint="all",
    limits={breeding=4,archive=4,scanning=4,conversion=4,imprint=4,transfer=4,robot_attempts=2,robot_timeout=2},
    network={foundation_port=24193},
    roles={
      genetics={address="house"},
      bee_storage={address="tx",side=0,reserved_slot=4,caste_items={princess_item="princess",drone_item="drone",queen_item="queen"}},
      breeder={address="tx",side=1,princess_slot=1,drone_slot=2,output_slots={3,4},minimum_outputs=1},
      scanner={address="tx",side=2,input_slot=1,output_slots={2},component_address="analyzer"},
      recovery={address="tx",side=3,output_slots={1,2,3,4}}
    }
  }
end

local function callable_adapter(driver)
  local inventories={}
  for side=0,3 do inventories[side]={size=4,slots={}} end
  local tx={}
  tx.getInventorySize=callable(function(side) return inventories[side].size end)
  tx.getStackInSlot=callable(function(side,slot) return util.copy(inventories[side].slots[slot]) end)
  tx.transferItem=callable(function(source_side,destination_side,count,source_slot,destination_slot)
    local source=inventories[source_side].slots[source_slot]
    if not source then return 0 end
    local moved=math.min(count,source.size)
    local destination=inventories[destination_side].slots[destination_slot]
    if destination then destination.size=destination.size+moved else destination=util.copy(source);destination.size=moved;inventories[destination_side].slots[destination_slot]=destination end
    source.size=source.size-moved
    if source.size==0 then inventories[source_side].slots[source_slot]=nil end
    return moved
  end)
  local proxies={tx=tx,house={},analyzer={}}
  local runtime={component={proxy=function(address)return proxies[address]end},event={pull=function()end}}
  local custom=driver or {
    list_species=function()return {{uid="a"}}end,
    list_mutations=function()return {}end,
    inspect_stack=function(raw)return util.copy(raw)end,
    scan_generation=function(_,bee)return {safe=true,complete=true,identity={caste=bee.caste,active=bee.active,inactive=bee.inactive},location="bee_storage",scanned=true}end,
    breed_generation=function(_,step)return {safe=true,complete=true,uid=step.uid or step.archive_uid,location="bee_storage",outputs={}}end,
    convert_generation=function(_,uid,princess)return {safe=true,complete=true,uid=uid,princess_identity=princess.active,location="bee_storage"}end,
    imprint_generation=function(_,uid)return {safe=true,complete=true,uid=uid,scanned=true,template_retained=true,location="bee_storage"}end
  }
  local config=valid_config()
  local adapter,err=Adapter.new(config,custom,runtime)
  return adapter,err,inventories,proxies
end

H.test("Lua 5.2 callable-table transposer callbacks are invoked", function()
  local adapter,err,inventories=callable_adapter()
  H.truthy(adapter,err)
  inventories[0].slots[1]=raw_bee("drone","a","a",1,2)
  H.equal(assert(adapter:transfer_verified("bee_storage",1,"scanner",1,1)),1)
  H.equal(inventories[2].slots[1].size,1)
end)

H.test("official fixed callbacks work through callable-table proxies", function()
  local adapter,err,_,proxies=callable_adapter(Official)
  proxies.house.listAllSpecies=callable(function()return {{uid="forestry.a",name="A"},{uid="forestry.b",name="B"},{uid="forestry.c",name="C"}}end)
  proxies.house.getBeeBreedingData=callable(function()return {{allele1="A",allele2="B",result="C",chance=12,specialConditions={"humid"}}}end)
  proxies.analyzer.getIndividualOnDisplay=callable(function()return nil end)
  -- Topology was checked before callbacks were installed; reconstruct with the faithful proxy shape.
  local config=valid_config()
  adapter,err=Adapter.new(config,Official,{component={proxy=function(address)return proxies[address]end},event={pull=function()end}})
  H.truthy(adapter,err)
  local catalog=assert(Catalog.discover(adapter))
  H.truthy(catalog.species["forestry.c"])
  H.equal(catalog.routes[1].parents,{"forestry.a","forestry.b"})
end)

H.test("official analyzed genome decoding preserves stable UIDs and complete exposed maps", function()
  local adapter={config=valid_config()}
  local raw={name="princess_item",size=1,maxSize=1,individual={type="bee",isAnalyzed=true,
    active={species={uid="forestry.a",name="A"},speed=1.2,lifespan=20},
    inactive={species={uid="forestry.b",name="B"},speed=0.8,lifespan=10}}}
  local bee=assert(Official.inspect_stack(raw,{role="bee_storage",slot=1},adapter))
  H.equal(bee.active,"forestry.a")
  H.equal(bee.inactive,"forestry.b")
  H.equal(bee.genome.active.speed,1.2)
  H.truthy(bee.scanned)
end)

H.test("official collection normalization rejects speculative callable iterators", function()
  local callable=setmetatable({},{__call=function()return {uid="x"}end})
  local values,err=Official.normalize_collection(callable)
  H.falsy(values);H.contains(err,"array or map")
  local mixed,mixed_err=Official.normalize_collection({{uid="x"},metadata=true})
  H.falsy(mixed);H.contains(mixed_err,"ambiguously")
end)

H.test("official discovery fails closed when the real partial species list omits a parent", function()
  local _,_,_,proxies=callable_adapter()
  proxies.house.listAllSpecies=callable(function()return {{uid="a",name="A"},{uid="c",name="C"}}end)
  proxies.house.getBeeBreedingData=callable(function()return {{allele1="A",allele2="B",result="C",chance=10,specialConditions={}}}end)
  proxies.analyzer.getIndividualOnDisplay=callable(function()return nil end)
  local runtime={component={proxy=function(address)return proxies[address]end},event={pull=function()end}}
  local adapter=assert(Adapter.new(valid_config(),Official,runtime))
  adapter:list_species()
  local ok,err=pcall(function()adapter:list_mutations()end)
  H.falsy(ok);H.contains(err,"does not map")
end)

H.test("official scanner timeout returns its exact physical input safely", function()
  local machine,returned={},false
  local adapter={config={roles={scanner={input_slot=1,output_slots={2},component_address="ana"}},limits={scanning=1}}}
  function adapter:raw_stack(role,slot)return machine[slot]end
  function adapter:transfer_verified(from_role,from_slot,to_role,to_slot,count)
    if from_role=="bee_storage" then machine[to_slot]={name="princess",size=1};return true end
    if from_role=="scanner" and to_role=="bee_storage" then machine[from_slot]=nil;returned=to_slot==3;return true end
    return nil,"unexpected transfer"
  end
  function adapter:invoke()return nil end
  function adapter:wait_tick()end
  local result=Official.scan_generation(adapter,{inventory="bee_storage",slot=3,caste="princess",active="a",inactive="b"},1)
  H.truthy(result.safe);H.falsy(result.complete);H.equal(result.operation,"scanning");H.equal(result.location,"bee_storage");H.truthy(returned)
end)

H.test("official breeder failure after movement returns a complete safe attestation", function()
  local machine={}
  local adapter={config={roles={breeder={princess_slot=1,drone_slot=2,output_slots={3}}},limits={scanning=1}}}
  function adapter:raw_stack(role,slot)return machine[slot]end
  function adapter:transfer_verified(from_role,from_slot,to_role,to_slot)
    if to_role=="breeder" and to_slot==1 then machine[1]={name="princess",size=1};return true end
    if to_role=="breeder" and to_slot==2 then return nil,"drone transfer blocked" end
    return nil,"unexpected transfer"
  end
  function adapter:return_output(role,slot)machine[slot]=nil;return true end
  local result=Official.breed_generation(adapter,{uid="c",princess={inventory="bee_storage",slot=1,active="a"},drone={inventory="bee_storage",slot=2,active="b"}},2)
  H.equal(result.operation,"breeding");H.truthy(result.safe);H.falsy(result.complete);H.equal(result.uid,"c");H.equal(result.location,"bee_storage");H.equal(type(result.outputs),"table")
end)

H.test("hardware mutation selection preserves an exact completed drone archive",function()
  local calls=0
  local driver={
    list_species=function()return{}end,list_mutations=function()return{}end,inspect_stack=function(raw)return util.copy(raw)end,
    scan_generation=function()end,convert_generation=function()end,imprint_generation=function()end,
    breed_generation=function(_,step)calls=calls+1;return{safe=true,complete=true,uid=step.uid,location="bee_storage",outputs={}}end
  }
  local adapter,err,inventories=callable_adapter(driver);H.truthy(adapter,err)
  inventories[0].slots[1]=raw_bee("princess","a","a",1,1)
  inventories[0].slots[2]=raw_bee("drone","b","b",2,32)
  local step={uid="c",route={conditions={}},orientation={princess="a",drone="b"}}
  local blocked=assert(adapter:produce_species(step,32))
  H.falsy(blocked.complete);H.equal(blocked.route_failure,"deterministic");H.contains(blocked.error,"protected minimum");H.equal(calls,0)
  inventories[0].slots[3]=raw_bee("drone","b","x",3,1)
  local produced=assert(adapter:produce_species(step,32))
  H.truthy(produced.complete);H.equal(step.drone.slot,3);H.equal(calls,1)
end)

H.test("archive configuration rejects zero fractions and sub-32 values", function()
  for _,size in ipairs({0,1,31,31.5}) do
    local config=valid_config();config.archive_size=size
    local ok,err=Config.validate(config)
    H.falsy(ok);H.contains(err,"at least 32")
  end
  H.truthy(Config.validate(valid_config()))
end)

H.test("obsolete genetics callback fields are rejected", function()
  local config=valid_config();config.roles.genetics.breed_method="imaginary"
  local ok,err=Config.validate(config)
  H.falsy(ok);H.contains(err,"obsolete")
end)

H.test("configured physical slots are checked against observed inventory size", function()
  local config=valid_config();config.roles.scanner.output_slots={5}
  local _,err=callable_adapter()
  local adapter
  local base_adapter,_,_,proxies=callable_adapter()
  H.truthy(base_adapter)
  adapter,err=Adapter.new(config,{
    list_species=function()return {{uid="a"}}end,list_mutations=function()return {}end,inspect_stack=function()end,
    scan_generation=function()end,breed_generation=function()end,convert_generation=function()end,imprint_generation=function()end
  },{component={proxy=function(address)return proxies[address]end},event={pull=function()end}})
  H.falsy(adapter);H.contains(err,"outside its observed inventory")
end)

H.test("reserved template slot is enforced at the physical transfer boundary", function()
  local adapter,err,inventories=callable_adapter();H.truthy(adapter,err)
  inventories[0].slots[4]=raw_bee("drone","a","a",4,1)
  local moved,move_err=adapter:transfer_verified("bee_storage",4,"scanner",1,1)
  H.falsy(moved);H.contains(move_err,"reserved")
  inventories[2].slots[1]=raw_bee("drone","a","a",1,1)
  moved,move_err=adapter:transfer_verified("scanner",1,"bee_storage",4,1)
  H.falsy(moved);H.contains(move_err,"reserved")
end)

H.test("malformed non-finite and out-of-range mutation chances abort discovery", function()
  for _,chance in ipairs({"12",0/0,math.huge,-1,101}) do
    local adapter={list_species=function()return {{uid="a"},{uid="b"},{uid="c"}}end,list_mutations=function()return {{result="c",parents={"a","b"},chance=chance}}end}
    local catalog,err=Catalog.discover(adapter)
    H.falsy(catalog);H.contains(err,"chance")
  end
end)

H.test("planner emits conversion explicitly and can exclude it for a deterministic route", function()
  local catalog=Catalog.new()
  for _,uid in ipairs({"a","b","c"})do assert(catalog:add_species({uid=uid}))end
  assert(catalog:add_route({result="c",parents={"a","b"},chance=10}))
  local roles={princess={a=true},drone={b=true,c=true},convertible={c=true}}
  local direct=assert(Planner.dependencies(catalog,"c",roles))
  H.equal(direct[1].kind,"convert")
  local alternate=assert(Planner.dependencies(catalog,"c",roles,{c={conversion="failed safely"}}))
  H.equal(alternate[1].uid,"c")
  H.truthy(alternate[1].route)
end)

local function stocked_bee(caste,uid,slot,size,genome)
  local bee=raw_bee(caste,uid,uid,slot,size,genome or {uid=uid})
  bee.inventory="bee_storage"
  return bee
end

H.test("missing safe attestation fails closed", function()
  local princess=stocked_bee("princess","a",1,1)
  local drone=stocked_bee("drone","a",2,1)
  local fake={snapshot_storage=function()return {size=4,reserved_slot=4,bees={princess,drone}}end,expand_archive=function()return {complete=true,uid="a",location="bee_storage",outputs={}}end}
  local operations=Operations.new(fake,{limits={archive=1}})
  local value,err=operations:archive("a")
  H.falsy(value);H.contains(err,"safe=true")
end)

local function conversion_adapter(limit_behavior)
  local bees={stocked_bee("princess","b",1,1),stocked_bee("princess","b",2,1),stocked_bee("drone","a",3,8)}
  local calls=0
  return {
    recover_pending=function()return {}end,
    snapshot_storage=function()return {size=6,reserved_slot=6,bees=bees}end,
    list_species=function()return {{uid="a",name="A"},{uid="b",name="B"}}end,
    list_mutations=function()return {}end,
    convert_one=function(_,uid,princess)
      calls=calls+1
      local source_identity=princess.active
      if limit_behavior and calls>limit_behavior then return {safe=true,complete=false,uid=uid,princess_identity=source_identity,retained_princess=util.copy(princess),location="bee_storage",error="finite cycle limit"} end
      for _,bee in ipairs(bees)do if bee.slot==princess.slot then bee.active,bee.inactive,bee.genome=uid,uid,{uid=uid};break end end
      return {safe=true,complete=true,uid=uid,princess_identity=source_identity,location="bee_storage"}
    end
  },function()return calls end
end

H.test("counted conversion reports an exact truthful partial failure", function()
  local fake,calls=conversion_adapter(1)
  local outcome=assert(Operations.new(fake,{limits={conversion=3,conversion_generations=2}}):convert({species="A",count=2,all=false}))
  H.falsy(outcome.success);H.equal(outcome.converted,1);H.equal(calls(),3);H.contains(outcome.error,"converted 1 of 2")
end)

H.test("all conversion succeeds when the last eligible princess is converted on the final budget step", function()
  local fake=conversion_adapter()
  local outcome=assert(Operations.new(fake,{limits={conversion=2}}):convert({species="A",all=true}))
  H.truthy(outcome.success);H.equal(outcome.converted,2);H.contains(outcome.stopped,"no eligible")
end)

H.test("standalone conversion never spends an exact completed drone archive",function()
  local princess=stocked_bee("princess","b",1,1)
  local archive=stocked_bee("drone","a",2,32)
  local calls=0
  local fake={
    recover_pending=function()return{}end,snapshot_storage=function()return{size=4,reserved_slot=4,bees={princess,archive}}end,
    list_species=function()return{{uid="a",name="A"},{uid="b"}}end,list_mutations=function()return{}end,
    convert_one=function()calls=calls+1 end
  }
  local outcome=assert(Operations.new(fake,{limits={conversion=2}}):convert({species="A",count=1,all=false}))
  H.falsy(outcome.success);H.contains(outcome.error,"protected minimum");H.equal(calls,0);H.equal(archive.size,32)
end)

H.test("complete executes conversion preparation instead of treating a drone role as physical princess stock", function()
  local bees={stocked_bee("princess","a",1,1,{uid="a"}),stocked_bee("drone","a",2,32,{uid="a"}),stocked_bee("drone","c",3,1,{uid="c"})}
  local conversions=0
  local fake={
    recover_pending=function()return {}end,snapshot_storage=function()return {size=8,reserved_slot=8,bees=bees}end,
    list_species=function()return {{uid="a"},{uid="c"}}end,list_mutations=function()return {}end,
    convert_one=function(_,uid,princess)conversions=conversions+1;bees[#bees+1]=stocked_bee("princess",uid,4,1,{uid=uid});return {safe=true,complete=true,uid=uid,princess_identity=princess.active,location="bee_storage"}end,
    expand_archive=function(_,uid)bees[3].size=32;return {safe=true,complete=true,uid=uid,location="bee_storage",outputs={bees[3]}}end
  }
  local outcome=assert(Operations.new(fake,{limits={progress=5}}):complete({imprint="none"}))
  H.equal(conversions,1);H.equal(outcome.missing,{})
end)

H.test("complete excludes a failed route and tries the next deterministic alternative", function()
  local bees={
    stocked_bee("princess","a",1,1),stocked_bee("drone","a",2,32),
    stocked_bee("princess","b",3,1),stocked_bee("drone","b",4,32),
    stocked_bee("princess","d",5,1),stocked_bee("drone","d",6,32)
  }
  local attempts={}
  local fake={
    recover_pending=function()return {}end,snapshot_storage=function()return {size=10,reserved_slot=10,bees=bees}end,
    list_species=function()return {{uid="a"},{uid="b"},{uid="c"},{uid="d"}}end,
    list_mutations=function()return {{result="c",parents={"a","b"},chance=90},{result="c",parents={"a","d"},chance=10}}end,
    produce_species=function(_,step)
      attempts[#attempts+1]=table.concat(step.route.parents,"+")
      if step.route.parents[2]=="b" then return {safe=true,complete=false,uid="c",location="bee_storage",outputs={},route_failure="deterministic",error="route rejected"} end
      bees[#bees+1]=stocked_bee("princess","c",7,1);bees[#bees+1]=stocked_bee("drone","c",8,32)
      return {safe=true,complete=true,uid="c",location="bee_storage",outputs={bees[#bees-1],bees[#bees]}}
    end
  }
  local outcome=assert(Operations.new(fake,{limits={progress=8}}):complete({imprint="none"}))
  H.equal(attempts,{"a+b","a+d"});H.equal(outcome.missing,{})
end)

local function imprint_adapter(result_value)
  local template=stocked_bee("drone","template",6,1,{template=true})
  local bees={stocked_bee("princess","a",1,1,{uid="a"}),stocked_bee("drone","a",2,32,{uid="a"}),stocked_bee("drone","a",3,1,{template=true}),template}
  return {
    recover_pending=function()return {}end,snapshot_storage=function()return {size=6,reserved_slot=6,bees=bees}end,
    list_species=function()return {{uid="a",name="A"},{uid="template",name="Template"}}end,list_mutations=function()return {}end,
    imprint_one=function(_,uid,_,princess)return result_value(uid,princess)end
  }
end

H.test("complete reports safe optional imprint misses but treats unsafe imprint as fatal", function()
  local safe=imprint_adapter(function(uid,princess)return {safe=true,complete=false,uid=uid,scanned=false,template_retained=true,retained_princess=util.copy(princess),location="bee_storage",error="optional miss"}end)
  local outcome=assert(Operations.new(safe,{limits={progress=3,imprint=1}}):complete({imprint="all"}))
  H.equal(#outcome.imprints,1);H.falsy(outcome.imprints[1].ok);H.truthy(outcome.imprints[1].safe)
  local unsafe=imprint_adapter(function()return {safe=false,complete=false,error="unknown output",location="scanner slot 2"}end)
  local value,err=Operations.new(unsafe,{limits={progress=3,imprint=1}}):complete({imprint="all"})
  H.falsy(value);H.contains(err,"unsafe")
end)

H.test("breed and direct imprint are command failures after a safe requested miss", function()
  local fake=imprint_adapter(function(uid,princess)return {safe=true,complete=false,uid=uid,scanned=false,template_retained=true,retained_princess=util.copy(princess),location="bee_storage",error="requested miss"}end)
  local operations=Operations.new(fake,{limits={imprint=1}})
  local breed=assert(operations:breed({species="A",imprint="all",pause=false}))
  H.falsy(breed.success);H.contains(breed.error,"requested imprint failed")
  local direct=assert(operations:imprint({species="A"}))
  H.falsy(direct.success);H.contains(direct.error,"requested imprint")
end)

H.test("application returns failure status for a requested imprint miss", function()
  local fake=imprint_adapter(function(uid,princess)return {safe=true,complete=false,uid=uid,scanned=false,template_retained=true,retained_princess=util.copy(princess),location="bee_storage",error="requested miss"}end)
  local lines={}
  local app=Application.new(function()return fake,{archive_size=32,limits={imprint=1}}end,function(line)lines[#lines+1]=line end)
  local ok,err,result=app:execute({name="imprint",species="A"})
  H.falsy(ok);H.falsy(result.success);H.equal(result.safety_state,"known_safe");H.contains(err,"requested imprint")
end)

H.test("full TUI path rejects a nonblank malformed conversion count", function()
  local original_read,original_write,original_print=io.read,io.write,print
  local answers={"A","abc",""}
  local keys={down=2,enter=3,q=4,up=1,esc=5,back=6}
  local events={keys.down,keys.down,keys.enter,keys.q}
  local executed,lines=0,{}
  io.read=function()local value=answers[1];table.remove(answers,1);return value end
  io.write=function()return true end
  _G.print=function(value)lines[#lines+1]=tostring(value)end
  local ok,err=pcall(function()
    Menu.run(function()executed=executed+1;return true end,{term={clear=function()end},keyboard={keys=keys},event={pull=function()local code=events[1];table.remove(events,1);return "key_down",nil,nil,code end}})
  end)
  io.read,io.write,_G.print=original_read,original_write,original_print
  H.truthy(ok,err);H.equal(executed,0)
  local joined=table.concat(lines,"\n");H.contains(joined,"Input error")
end)
