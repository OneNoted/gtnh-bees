local H = require("tests.harness")
local Catalog = require("gtnh_bees.catalog")
local Command = require("gtnh_bees.command")
local Config = require("gtnh_bees.config")

local function valid_config()
  return {
    archive_size=32,
    complete_imprint="all",
    driver_module="gtnh_bees.official_driver",
    limits={transfer=2},
    network={},
    roles={
      genetics={address="g"},
      bee_storage={address="t",side=0,reserved_slot=8,caste_items={p="princess",d="drone",q="queen"}},
      breeder={address="t",side=1,princess_slot=1,drone_slot=2,output_slots={3,4},terminal_stable_polls=2},
      scanner={address="t",side=2,component_address="s",input_slot=1,output_slots={2,3}},
      recovery={address="t",side=3,output_slots={1,2}}
    }
  }
end

local function discover_conditions(conditions, mappings, singular)
  local route={result="c",parents={"a","b"}}
  if singular then route.condition=conditions else route.conditions=conditions end
  return Catalog.discover({
    config={mutation_conditions=mappings or {Exact={policy="unmet"},Other={policy="satisfied"}}},
    list_species=function()return{{uid="a"},{uid="b"},{uid="c"}}end,
    list_mutations=function()return{route}end
  })
end

H.test("mutation conditions accept strict arrays maps and an unambiguous single identity",function()
  local array=assert(discover_conditions({"Exact",{identity="Other",satisfied=false}}))
  H.equal(#array.routes[1].conditions,2)
  H.falsy(array.routes[1].conditions[1].satisfied)
  H.truthy(array.routes[1].conditions[2].satisfied)

  local map=assert(discover_conditions({first="Exact",second={identity="Other"}}))
  H.equal(#map.routes[1].conditions,2)

  local single=assert(discover_conditions({identity="Exact",description="forged",satisfied=true,policy="satisfied",foundation="evil:block"}))
  local condition=single.routes[1].conditions[1]
  H.equal(condition.identity,"Exact")
  H.equal(condition.description,"Exact")
  H.falsy(condition.satisfied)
  H.falsy(condition.foundation)
end)

H.test("mutation conditions reject collection shapes that could omit an entry",function()
  local cases={
    {name="mixed array and map",value={[1]="Exact",named="Other"}},
    {name="sparse array",value={[2]="Exact"}},
    {name="array hole",value={[1]="Exact",[3]="Other"}},
    {name="zero key",value={[0]="Exact"}},
    {name="negative key",value={[-1]="Exact"}},
    {name="fractional key",value={[1.5]="Exact"}},
    {name="infinite key",value={[math.huge]="Exact"}},
    {name="boolean map key",value={[false]="Exact"}},
    {name="table map key",value={[{}]="Exact"}}
  }
  for _,case in ipairs(cases)do
    local catalog,err=discover_conditions(case.value)
    H.falsy(catalog,case.name)
    H.contains(err,"mutation entry 1")
  end
end)

H.test("single condition tables reject ambiguous collection entries",function()
  for _,value in ipairs({
    {identity="Exact",other="Other"},
    {identity="Exact",[1]="Other"},
    {{identity="Exact",other="Other"}}
  })do
    local catalog,err=discover_conditions(value)
    H.falsy(catalog)
    H.contains(err,"ambiguous")
  end

  local adapter={
    config={mutation_conditions={Exact={policy="unmet"},Other={policy="satisfied"}}},
    list_species=function()return{{uid="a"},{uid="b"},{uid="c"}}end,
    list_mutations=function()return{{result="c",parents={"a","b"},conditions={"Exact"},condition="Other"}}end
  }
  local catalog,err=Catalog.discover(adapter)
  H.falsy(catalog)
  H.contains(err,"both conditions and condition")
end)

H.test("condition identity matching remains exact and policy comes only from configuration",function()
  local catalog=assert(discover_conditions({"Exact","exact"},{Exact={policy="satisfied"}}))
  H.truthy(catalog.routes[1].conditions[1].satisfied)
  H.falsy(catalog.routes[1].conditions[2].satisfied)
  H.equal(catalog.routes[1].conditions[2].identity,"exact")
end)

H.test("official scanner output slots cannot overlap its input slot",function()
  local config=valid_config()
  H.truthy(Config.validate(config))
  for _,outputs in ipairs({{1},{1,2},{2,1}})do
    config=valid_config()
    config.roles.scanner.output_slots=outputs
    local ok,err=Config.validate(config)
    H.falsy(ok)
    H.contains(err,"scanner output_slots must be distinct")
  end
end)

H.test("foundation port accepts only finite official modem ports including defaults",function()
  for _,port in ipairs({1,65535})do
    local config=valid_config()
    config.network.foundation_port=port
    H.truthy(Config.validate(config))
  end
  local defaulted=valid_config()
  defaulted.network.foundation_port=nil
  H.truthy(Config.validate(defaulted))

  for _,port in ipairs({0,65536,math.huge,-math.huge,0/0})do
    local config=valid_config()
    config.network.foundation_port=port
    local ok,err=Config.validate(config)
    H.falsy(ok)
    H.contains(err,"network.foundation_port")
  end
end)

H.test("conversion count rejects non-finite numeric syntax",function()
  local command,err=Command.parse({"convert","Exact","--count=1e309"})
  H.falsy(command)
  H.contains(err,"finite positive integer")
  H.equal(assert(Command.parse({"convert","Exact","--count=3"})).count,3)
end)

local load_index=0
local function load_source(source)
  load_index=load_index+1
  local path="/tmp/gtnh-bees-validation-load-"..load_index..".cfg"
  local handle=assert(io.open(path,"w"))
  assert(handle:write(source))
  assert(handle:close())
  local called,config,err=pcall(Config.load,path)
  os.remove(path)
  H.truthy(called,"Config.load threw instead of returning a diagnostic")
  return config,err
end

H.test("configuration load diagnoses scalar top-level and nested merge inputs",function()
  local cases={
    {source="return 7\n",fragment="configuration must be a table"},
    {source="return {limits=7}\n",fragment="configuration limits must be a table"},
    {source="return {network=false}\n",fragment="configuration network must be a table"}
  }
  for _,case in ipairs(cases)do
    local config,err=load_source(case.source)
    H.falsy(config)
    H.contains(err,case.fragment)
  end
end)

H.test("configuration load merges and validates default network port",function()
  local source=[[return {
    archive_size=32,
    roles={
      genetics={address="g"},
      bee_storage={address="t",side=0,reserved_slot=8,caste_items={p="princess",d="drone",q="queen"}},
      breeder={address="t",side=1,princess_slot=1,drone_slot=2,output_slots={3},terminal_stable_polls=2},
      scanner={address="t",side=2,component_address="s",input_slot=1,output_slots={2}},
      recovery={address="t",side=3,output_slots={1}}
    }
  }
]]
  local config,err=load_source(source)
  H.truthy(config,err)
  H.equal(config.network.foundation_port,24193)
end)
