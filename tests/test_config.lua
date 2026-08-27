local H = require("tests.harness")
local Catalog = require("gtnh_bees.catalog")
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
      scanner={address="t",side=2,component_address="s",input_slot=1,output_slots={2}},
      recovery={address="t",side=3,output_slots={1,2}}
    }
  }
end

local function discover(species, mutations)
  return Catalog.discover({
    list_species=function() return species end,
    list_mutations=function() return mutations end
  })
end

local species_array={{uid="a"},{uid="b"},{uid="c"}}
local route={result="c",parents={"a","b"},chance=25}

H.test("configuration save accepts OpenOS nil close success",function()
  local old_open=io.open;local written={}
  io.open=function()
    return{write=function(_,... )for index=1,select("#",...)do written[#written+1]=tostring(select(index,...))end;return true end,flush=function()return true end,close=function()return nil end}
  end
  local fs={exists=function()return false end,remove=function()return true end,rename=function()return true end}
  local survived,ok,err=pcall(Config.save,valid_config(),"/config",fs)
  io.open=old_open
  H.truthy(survived);H.truthy(ok,err);H.truthy(#table.concat(written)>0)
end)

H.test("generic discovery accepts contiguous arrays and deterministic string-keyed maps",function()
  local array_catalog=assert(discover(species_array,{route}))
  H.truthy(array_catalog.species.a);H.equal(array_catalog.routes[1].result,"c")

  local map_catalog=assert(discover({third={uid="c"},first={uid="a"},second={uid="b"}},{only=route}))
  H.truthy(map_catalog.species.b);H.equal(#map_catalog.routes,1);H.equal(map_catalog.routes[1].parents,{"a","b"})
end)

local function hostile_collections(entry)
  return {
    {name="mixed array/map",value={[1]=entry,extra=entry}},
    {name="sparse numeric",value={[2]=entry}},
    {name="numeric hole",value={[1]=entry,[3]=entry}},
    {name="zero numeric key",value={[0]=entry}},
    {name="negative numeric key",value={[-1]=entry}},
    {name="fractional numeric key",value={[1.5]=entry}},
    {name="infinite numeric key",value={[math.huge]=entry}},
    {name="non-string map key",value={[false]=entry}}
  }
end

H.test("species discovery rejects every collection shape that could omit entries",function()
  for _,case in ipairs(hostile_collections({uid="a"})) do
    local catalog,err=discover(case.value,{})
    H.falsy(catalog,case.name);H.contains(err,"species discovery failed")
  end
end)

H.test("mutation discovery applies the same strict collection validation atomically",function()
  for _,case in ipairs(hostile_collections(route)) do
    local catalog,err=discover(species_array,case.value)
    H.falsy(catalog,case.name);H.contains(err,"mutation discovery failed")
  end
end)

H.test("archive and slot policy rejects NaN and both infinities",function()
  for _,value in ipairs({0/0,math.huge,-math.huge}) do
    local config=valid_config();config.archive_size=value
    local ok,err=Config.validate(config);H.falsy(ok);H.contains(err,"archive_size")
  end

  local slot_cases={
    function(config,value) config.roles.bee_storage.reserved_slot=value end,
    function(config,value) config.roles.scanner.input_slot=value end,
    function(config,value) config.roles.breeder.princess_slot=value end,
    function(config,value) config.roles.breeder.drone_slot=value end,
    function(config,value) config.roles.breeder.output_slots={3,value} end
  }
  for _,set_slot in ipairs(slot_cases) do
    for _,value in ipairs({0/0,math.huge,-math.huge}) do
      local config=valid_config();set_slot(config,value)
      local ok,err=Config.validate(config);H.falsy(ok);H.truthy(err)
    end
  end
end)

H.test("official output slot lists must be contiguous arrays",function()
  local mixed=valid_config();mixed.roles.recovery.output_slots={[1]=1,extra=2}
  local ok,err=Config.validate(mixed);H.falsy(ok);H.contains(err,"contiguous array")

  local sparse=valid_config();sparse.roles.scanner.output_slots={[2]=2}
  ok,err=Config.validate(sparse);H.falsy(ok);H.contains(err,"contiguous array")
end)

H.test("complete imprint policy accepts only none and all after applying its default",function()
  for _,mode in ipairs({"none","all"}) do
    local config=valid_config();config.complete_imprint=mode;H.truthy(Config.validate(config))
  end
  local defaulted=valid_config();defaulted.complete_imprint=nil;H.truthy(Config.validate(defaulted))
  for _,mode in ipairs({"ALL","everything",true,false,1}) do
    local config=valid_config();config.complete_imprint=mode
    local ok,err=Config.validate(config);H.falsy(ok);H.contains(err,"complete_imprint")
  end
end)

H.test("official breeder outputs cannot overlap either input slot",function()
  for _,outputs in ipairs({{1,3},{2,3}}) do
    local config=valid_config();config.roles.breeder.output_slots=outputs
    local ok,err=Config.validate(config);H.falsy(ok);H.contains(err,"distinct")
  end
end)

local function answers(breeder_slots)
  return {
    "genetics-address",
    "transposer-address","0","8",
    "princess-item,drone-item,queen-item",
    "transposer-address","1",breeder_slots,"1","2",
    "transposer-address","2"," 2 ","analyzer-address","1",
    "transposer-address","3"," 1, 2 "
  }
end

local filesystem={}
function filesystem.exists(path)
  local handle=io.open(path,"r")
  if not handle then return false end
  handle:close();return true
end
function filesystem.remove(path) os.remove(path);return true end
function filesystem.rename(source,destination) return os.rename(source,destination) end

local function run_wizard(breeder_slots,path)
  local supplied=answers(breeder_slots)
  local index=0
  local function input() index=index+1;return supplied[index] end
  return Config.wizard(input,function() end,nil,path,filesystem)
end

H.test("wizard accepts only well-formed positive decimal slot lists with surrounding whitespace",function()
  local path="/tmp/gtnh-bees-valid-wizard.cfg"
  os.remove(path);os.remove(path..".new");os.remove(path..".previous")
  local config,err=run_wizard(" 3, 4 , 005 ",path)
  H.truthy(config,err);H.equal(config.roles.breeder.output_slots,{3,4,5})
  H.equal(config.roles.scanner.output_slots,{2});H.equal(config.roles.recovery.output_slots,{1,2})
  os.remove(path);os.remove(path..".new");os.remove(path..".previous")
end)

H.test("wizard rejects malformed slot lists instead of extracting digit fragments",function()
  local path="/tmp/gtnh-bees-invalid-wizard.cfg"
  for _,text in ipairs({"-1","1.5","1,,2","1x"}) do
    os.remove(path);os.remove(path..".new");os.remove(path..".previous")
    local config,err=run_wizard(text,path)
    H.falsy(config,text);H.contains(err,"configuration was not saved")
    H.falsy(filesystem.exists(path),text)
  end
  os.remove(path);os.remove(path..".new");os.remove(path..".previous")
end)
