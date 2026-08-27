local H=require("tests.harness")
local Catalog=require("gtnh_bees.catalog")
local Official=require("gtnh_bees.official_driver")
local util=require("gtnh_bees.util")

local function bee(caste,uid,slot,size,genome)
  return {caste=caste,active=uid,inactive=uid,scanned=true,size=size or 1,maxSize=64,
    genome=genome or {uid=uid},inventory="bee_storage",slot=slot}
end

H.test("official collections accept only deterministic contiguous arrays and string maps",function()
  H.equal(assert(Official.normalize_collection({"first","second"})),{"first","second"})
  H.equal(assert(Official.normalize_collection({z="last",a="first"})),{"first","last"})
  H.equal(assert(Official.normalize_collection({})),{})
end)

H.test("official collections reject every raw key shape that can omit data",function()
  local entry={uid="a"}
  local cases={
    {name="zero key",value={[0]=entry}},
    {name="negative key",value={[-1]=entry}},
    {name="fractional key",value={[1.5]=entry}},
    {name="positive infinity",value={[math.huge]=entry}},
    {name="negative infinity",value={[-math.huge]=entry}},
    {name="sparse start",value={[2]=entry}},
    {name="numeric hole",value={[1]=entry,[3]=entry}},
    {name="mixed array and map",value={[1]=entry,metadata=entry}},
    {name="boolean map key",value={[false]=entry}},
    {name="table map key",value={[{}]=entry}}
  }
  for _,case in ipairs(cases)do
    local values,err=Official.normalize_collection(case.value)
    H.falsy(values,case.name);H.truthy(err,case.name)
  end

  local oversized={}
  for index=1,4097 do oversized["entry-"..index]=entry end
  local values,err=Official.normalize_collection(oversized)
  H.falsy(values);H.contains(err,"finite item bound")
end)

local function catalog()
  local value=Catalog.new()
  for _,uid in ipairs({"a","b","c"})do assert(value:add_species({uid=uid}))end
  return value
end

H.test("catalog accepts each unambiguous complete parent representation",function()
  local value=catalog()
  H.equal(assert(value:add_route({result="c",parents={"a","b"}})).parents,{"a","b"})
  H.equal(assert(value:add_route({result="c",parent1="a",parent2="b"})).parents,{"a","b"})
  H.equal(assert(value:add_route({result="c",first="a",second="b"})).parents,{"a","b"})
end)

H.test("catalog rejects ambiguous malformed and incomplete parents atomically",function()
  local cases={
    {name="parents is scalar",route={result="c",parents="a"}},
    {name="parents missing second",route={result="c",parents={[1]="a"}}},
    {name="parents missing first",route={result="c",parents={[2]="b"}}},
    {name="parents sparse",route={result="c",parents={[1]="a",[3]="b"}}},
    {name="parents zero extra",route={result="c",parents={[0]="x",[1]="a",[2]="b"}}},
    {name="parents fractional extra",route={result="c",parents={[1]="a",[2]="b",[1.5]="x"}}},
    {name="parents infinite extra",route={result="c",parents={[1]="a",[2]="b",[math.huge]="x"}}},
    {name="parents third extra",route={result="c",parents={[1]="a",[2]="b",[3]="x"}}},
    {name="parents map extra",route={result="c",parents={[1]="a",[2]="b",metadata="x"}}},
    {name="parents plus canonical pair",route={result="c",parents={"a","b"},parent1="a",parent2="b"}},
    {name="parents plus incomplete scalar",route={result="c",parents={"a","b"},parent1="a"}},
    {name="parent1 only",route={result="c",parent1="a"}},
    {name="parent2 only",route={result="c",parent2="b"}},
    {name="first only",route={result="c",first="a"}},
    {name="second only",route={result="c",second="b"}},
    {name="conflicting scalar forms",route={result="c",parent1="a",parent2="b",first="a",second="b"}},
    {name="no parents",route={result="c"}}
  }
  for _,case in ipairs(cases)do
    local value=catalog()
    local route,err=value:add_route(case.route)
    H.falsy(route,case.name);H.truthy(err,case.name);H.equal(#value.routes,0,case.name)
    H.falsy(value.routes_by_result.c,case.name)
  end
end)

local function imprint_cycle(target_matches,princess)
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
      machine[3]={size=1,decoded={caste="princess",active=target_matches and "template"or"changed-active",inactive="template",
        scanned=true,size=1,maxSize=1,genome=target_matches and util.copy(template_genome)or{mark="miss"}}}
      machine[4]={size=1,decoded={caste="drone",active="template",inactive="template",
        scanned=true,size=1,maxSize=64,genome=util.copy(template_genome)}}
    end
    return 1
  end
  function adapter:decode(raw)return raw.decoded end
  function adapter:return_output(_,slot,decoded)
    machine[slot]=nil
    local stored=util.copy(decoded)
    stored.inventory,stored.slot="bee_storage",slot+2
    return true,stored
  end
  function adapter:wait_tick()end
  local template=bee("drone","template",8,1,template_genome)
  princess=princess or bee("princess","requested-target",1,1,{mark="prior-grade"})
  local donor=bee("drone","template",2,1,template_genome)
  return Official.imprint_generation(adapter,"requested-target",template,4,princess,donor)
end

H.test("bundled imprint retries a retained lineage after grading changes its active allele",function()
  local first,first_err=imprint_cycle(false)
  H.truthy(first,first_err);H.truthy(first.safe);H.falsy(first.complete)
  H.equal(first.retained_princess.active,"changed-active");H.equal(first.retained_princess.slot,5)

  local result,err=imprint_cycle(true,first.retained_princess)
  H.truthy(result,err);H.truthy(result.safe);H.truthy(result.complete);H.truthy(result.scanned)
  H.equal(result.uid,"requested-target");H.equal(result.retained_princess.caste,"princess")
  H.equal(result.retained_princess.active,"template")
end)

H.test("bundled imprint still rejects donor-only success evidence",function()
  local result=assert(imprint_cycle(false,bee("princess","changed-active",1,1,{mark="prior-grade"})))
  H.truthy(result.safe);H.falsy(result.complete);H.falsy(result.scanned)
  H.contains(result.error,"target princess lineage")
end)

H.test("bundled imprint requires reserved template and exact ordinary target location",function()
  local template=bee("drone","template",8,1,{mark="template"})
  local princess=bee("princess","changed-active",1,1,{mark="prior"})
  local donor=bee("drone","template",2,1,{mark="template"})
  local adapter={config={roles={bee_storage={reserved_slot=8}}}}

  local wrong_template=util.copy(template);wrong_template.slot=7
  local value,err=Official.imprint_generation(adapter,"requested-target",wrong_template,1,princess,donor)
  H.falsy(value);H.contains(err,"reserved")

  for _,slot in ipairs({8,math.huge,-math.huge})do
    local wrong_princess=util.copy(princess);wrong_princess.slot=slot
    value,err=Official.imprint_generation(adapter,"requested-target",template,1,wrong_princess,donor)
    H.falsy(value);H.contains(err,"ordinary target princess")
  end
end)

H.test("official component-derived sizes counts slots and limits reject non-finite numbers",function()
  local config={roles={bee_storage={reserved_slot=8,caste_items={princess_item="princess"}}}}
  local adapter={config=config}
  local analyzed={name="princess_item",size=1,maxSize=1,individual={type="bee",isAnalyzed=true,
    active={species={uid="a"}},inactive={species={uid="a"}}}}
  for _,field in ipairs({"size","maxSize"})do
    for _,number in ipairs({0/0,math.huge,-math.huge})do
      local raw=util.copy(analyzed);raw[field]=number
      local decoded,err=Official.inspect_stack(raw,{role="bee_storage",slot=1},adapter)
      H.falsy(decoded);H.contains(err,"finite positive integer")
    end
  end

  for _,slot in ipairs({0/0,math.huge,-math.huge})do
    local transport,err=Official.identify_stack({name="princess_item",size=1},{role="scanner",slot=slot},adapter)
    H.falsy(transport);H.contains(err,"finite positive slot")
  end

  local template=bee("drone","template",8,1,{mark="template"})
  local princess=bee("princess","changed-active",1,1,{mark="prior"})
  local donor=bee("drone","template",2,1,{mark="template"})
  adapter.config.roles.breeder={princess_slot=1,drone_slot=2,output_slots={3},terminal_stable_polls=2}
  for _,limit in ipairs({0/0,math.huge,-math.huge})do
    local value,err=Official.imprint_generation(adapter,"requested-target",template,limit,princess,donor)
    H.falsy(value);H.contains(err,"finite positive integer")
  end
  for _,count in ipairs({0/0,math.huge,-math.huge})do
    local wrong_donor=util.copy(donor);wrong_donor.size=count
    local value,err=Official.imprint_generation(adapter,"requested-target",template,1,princess,wrong_donor)
    H.falsy(value);H.contains(err,"counts must be finite positive integers")
  end
  for _,count in ipairs({0/0,math.huge,-math.huge})do
    adapter.config.roles.breeder.terminal_stable_polls=count
    local value,err=Official.imprint_generation(adapter,"requested-target",template,1,princess,donor)
    H.falsy(value);H.contains(err,"stability count")
  end
end)
