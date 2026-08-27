package.path="./lib/?.lua;./tests/?.lua;./?.lua;"..package.path
local H=require("tests.harness")
local util=require("gtnh_bees.util")
local bounded=require("gtnh_bees.bounded")
local Inventory=require("gtnh_bees.inventory")
local Adapter=require("gtnh_bees.hardware")
local Operations=require("gtnh_bees.operations")
local Config=require("gtnh_bees.config")
local Command=require("gtnh_bees.command")
local Foundation=require("gtnh_bees.foundation")
local RobotService=require("gtnh_bees.robot_service")
local RobotMain=require("gtnh_bees.robot_main")

local EPOCH_A="foundation-epoch-a-000000000000001"
local EPOCH_B="foundation-epoch-b-000000000000002"

local function auth(value)
  local n=0
  for index=1,#value do n=(n*131+string.byte(value,index))%2147483647 end
  return string.format("%08x",n)
end

local function memory_files(initial,control)
  local files={}
  for path,value in pairs(initial or{})do files[path]=value end
  control=control or{}
  local fs={}
  function fs.exists(path)return files[path]~=nil end
  function fs.rename(source,destination)
    if control.fail_rename and control.fail_rename(source,destination)then return nil,"injected rename failure"end
    if files[source]==nil then return nil,"missing source"end
    files[destination],files[source]=files[source],nil
    return true
  end
  local function open(path,mode)
    if control.fail_open and control.fail_open(path,mode)then return nil,"injected open failure"end
    if mode=="r"then
      local data=files[path]
      if type(data)~="string"then return nil,"missing"end
      return{read=function(_,format)if format=="*a"then return data end end,close=function()return true end}
    end
    if mode~="w"then return nil,"unsupported mode"end
    local chunks={}
    return{
      write=function(_,...)for index=1,select("#",...)do chunks[#chunks+1]=tostring(select(index,...))end return true end,
      flush=function()return true end,
      close=function()files[path]=table.concat(chunks);return true end
    }
  end
  return fs,open,files
end

local function robot_runtime(fs,open,options)
  options=options or{}
  local sent={}
  local stacks=options.stacks or{}
  local runtime={filesystem=fs,open=open,sides={down=0},event={pull=function()end}}
  runtime.robot={
    inventorySize=function()return options.inventory_size or 2 end,
    select=function()return true end,swing=function()return true end,place=function()return true end
  }
  runtime.component={
    modem={open=function()return true end,send=function(_,_,payload)sent[#sent+1]=payload;return true end},
    inventory_controller={getStackInInternalSlot=function(slot)return stacks[slot]end},
    geolyzer={analyze=function()return{name=options.installed or"world:stone"}end}
  }
  runtime.sent=sent
  return runtime
end

local function service(epoch,fs,open,options)
  options=options or{}
  local runtime=robot_runtime(fs,open,options)
  local value,err=RobotService.new({
    peer_address="controller",local_address="robot",auth=auth,epoch=epoch,
    journal_path="/replay",max_cache=options.max_cache or 8,
    block_items={ ["world:stone"]="item:stone" }
  },runtime)
  return value,err,runtime
end

H.test("first replay initialization durably creates authenticated journal and epoch anchor",function()
  local fs,open,files=memory_files()
  local value,err=service(EPOCH_A,fs,open)
  H.truthy(value,err);H.truthy(files["/replay"]);H.truthy(files["/replay.epoch"])
  H.falsy(files["/replay.tmp"]);H.falsy(files["/replay.epoch.tmp"])
  H.contains(files["/replay"],"gtnh-bees.foundation.replay.v2")
  H.contains(files["/replay.epoch"],"gtnh-bees.foundation.epoch.v1")
end)

H.test("same-epoch journal deletion fails closed while the durable anchor remains",function()
  local fs,open,files=memory_files();assert(service(EPOCH_A,fs,open))
  files["/replay"]=nil
  local restarted,err=service(EPOCH_A,fs,open)
  H.falsy(restarted);H.contains(err,"disappeared")
end)

H.test("supervised epoch rotation archives the old journal and rejects captured old requests",function()
  local fs,open,files=memory_files()
  local first=assert(service(EPOCH_A,fs,open))
  local captured=assert(Foundation.encode("request",EPOCH_A,"captured","nonce-old","world:stone",nil,auth))
  H.truthy(first:handle("controller",captured,"robot"))
  files["/archive/replay-epoch-a"]=files["/replay"]
  files["/replay"]=nil
  local rotated,rotate_err,runtime=service(EPOCH_B,fs,open)
  H.truthy(rotated,rotate_err);H.truthy(files["/archive/replay-epoch-a"])
  local ok,err=rotated:handle("controller",captured,"robot")
  H.falsy(ok);H.contains(err,"epoch");H.equal(#runtime.sent,0)
  local fresh=assert(Foundation.encode("request",EPOCH_B,"fresh","nonce-new","world:stone",nil,auth))
  H.truthy(rotated:handle("controller",fresh,"robot"))
end)

H.test("epoch change never erases an old or pending journal automatically",function()
  local fs,open,files=memory_files();assert(service(EPOCH_A,fs,open))
  local old=files["/replay"]
  local rotated,err=service(EPOCH_B,fs,open)
  H.falsy(rotated);H.contains(err,"archive/remove");H.equal(files["/replay"],old)
end)

H.test("interrupted rotation resumes only from an authenticated empty new journal",function()
  local fail_anchor=false
  local control={fail_open=function(path,mode)if fail_anchor and path=="/replay.epoch.tmp"and mode=="w"then fail_anchor=false;return true end end}
  local fs,open,files=memory_files(nil,control)
  assert(service(EPOCH_A,fs,open));files["/archive/old"]=files["/replay"];files["/replay"]=nil
  fail_anchor=true
  local interrupted,err=service(EPOCH_B,fs,open)
  H.falsy(interrupted);H.contains(err,"anchor advance failed")
  H.truthy(files["/replay"]);H.truthy(files["/replay.epoch"])
  local resumed,resume_err=service(EPOCH_B,fs,open)
  H.truthy(resumed,resume_err);H.falsy(files["/replay.epoch.tmp"])
end)

H.test("missing replay anchor and journal combinations are deterministic",function()
  local fs,open,files=memory_files();assert(service(EPOCH_A,fs,open))
  files["/replay.epoch"]=nil
  local missing_anchor,anchor_err=service(EPOCH_A,fs,open)
  H.falsy(missing_anchor);H.contains(anchor_err,"anchor is missing while a journal exists")

  local fs2,open2,files2=memory_files();assert(service(EPOCH_A,fs2,open2))
  files2["/replay"]=nil;files2["/replay.epoch"]=nil
  H.truthy(service(EPOCH_A,fs2,open2))
end)

H.test("failed first anchor creation leaves evidence and cannot silently reinitialize",function()
  local fail_anchor=true
  local fs,open,files=memory_files(nil,{fail_open=function(path,mode)if fail_anchor and path=="/replay.epoch.tmp"and mode=="w"then fail_anchor=false;return true end end})
  local value,err=service(EPOCH_A,fs,open)
  H.falsy(value);H.contains(err,"anchor advance failed");H.truthy(files["/replay"]);H.falsy(files["/replay.epoch"])
  local retry,retry_err=service(EPOCH_A,fs,open)
  H.falsy(retry);H.contains(retry_err,"anchor is missing while a journal exists")
end)

H.test("foundation messages authenticate and enforce the configured high-entropy epoch",function()
  local message=assert(Foundation.encode("request",EPOCH_A,"id","nonce","world:stone",nil,auth))
  H.equal(assert(Foundation.decode(message,auth,EPOCH_A)).epoch,EPOCH_A)
  local old,err=Foundation.decode(message,auth,EPOCH_B);H.falsy(old);H.contains(err,"epoch")
  H.falsy(Foundation.encode("request","short","id","nonce","world:stone",nil,auth))
  local ok=pcall(Foundation.Controller.new,{},{},{peer_address="r",local_address="c",auth=auth,nonce=function()end,epoch="short"})
  H.falsy(ok)
end)

H.test("finite integer authority rejects NaN and both infinities with valid boundaries",function()
  for _,value in ipairs({0/0,math.huge,-math.huge,1.5})do H.falsy(util.finite_integer(value))end
  H.truthy(util.finite_integer(0,0,5));H.truthy(util.finite_integer(5,0,5));H.falsy(util.finite_integer(6,0,5))
end)

H.test("bounded execution rejects non-finite limits before calling the action",function()
  for _,limit in ipairs({0/0,math.huge,-math.huge})do
    local calls=0;local value,err=bounded.repeat_until({limit=limit},function()calls=calls+1;return true end,function()return false end)
    H.falsy(value);H.contains(err,"finite positive integer");H.equal(calls,0)
  end
  local calls=0;local value=assert(bounded.repeat_until({limit=2},function()calls=calls+1;return true,calls end,function(current)return current==2 end))
  H.equal(value,2);H.equal(calls,2)
end)

local function raw_bee(overrides)
  local value={caste="drone",active="a",inactive="a",size=1,maxSize=64,scanned=true,genome={a=1},slot=1}
  for key,item in pairs(overrides or{})do value[key]=item end
  return value
end

H.test("inventory rejects non-finite stack sizes slots amounts and archive counts",function()
  for _,value in ipairs({0/0,math.huge,-math.huge})do
    local bee,err=Inventory.bee(raw_bee({size=value}));H.falsy(bee);H.contains(err,"stack size")
    bee,err=Inventory.bee(raw_bee({maxSize=value}));H.falsy(bee);H.contains(err,"maximum")
    bee,err=Inventory.bee(raw_bee({slot=value}));H.falsy(bee);H.contains(err,"slot")
    local plan=Inventory.destinations({size=4,reserved_slot=4,bees={}},raw_bee(),value);H.falsy(plan)
  end
  local count,err=Inventory.pure_drone_count({reserved_slot=4,bees={raw_bee({size=math.huge})}},"a")
  H.falsy(count);H.contains(err,"finite")
  H.truthy(Inventory.destinations({size=4,reserved_slot=4,bees={}},raw_bee(),1))
end)

local function hardware_fixture(size,limit)
  local slots={[0]={[1]={name="bee",size=2,maxSize=64}},[1]={},[2]={},[3]={}}
  local tx={getInventorySize=function()return size end,getStackInSlot=function(side,slot)return slots[side][slot]end,transferItem=function()return 0 end}
  local driver={list_species=function()return{}end,list_mutations=function()return{}end,inspect_stack=function()return nil,"not a bee"end,scan_generation=function()end,breed_generation=function()end,convert_generation=function()end,imprint_generation=function()end}
  local config={roles={genetics={address="g"},bee_storage={address="t",side=0,reserved_slot=4},breeder={address="t",side=1,output_slots={1}},scanner={address="t",side=2,output_slots={1}},recovery={address="t",side=3,output_slots={1}}},limits={transfer=limit or 2}}
  return Adapter.new(config,driver,{component={proxy=function(address)return address=="t"and tx or{}end},event={pull=function()end}})
end

H.test("hardware rejects non-finite inventory sizes transfer counts and loop limits",function()
  for _,value in ipairs({0/0,math.huge,-math.huge})do
    local adapter=hardware_fixture(value,2);H.falsy(adapter)
    local ok=pcall(hardware_fixture,4,value);H.falsy(ok)
  end
  local adapter=assert(hardware_fixture(4,2))
  for _,value in ipairs({0/0,math.huge,-math.huge})do local moved,err=adapter:transfer_verified("bee_storage",1,"scanner",1,value);H.falsy(moved);H.contains(err,"positive integer")end
end)

local function custom_config()
  return{archive_size=32,driver_module="custom.driver",limits={transfer=2},network={foundation_port=24193},roles={genetics={address="g"},bee_storage={address="t",side=0,reserved_slot=4},breeder={address="t",side=1},scanner={address="t",side=2},recovery={address="t",side=3}}}
end

H.test("configuration rejects non-finite archives ports sides slots and limits",function()
  for _,value in ipairs({0/0,math.huge,-math.huge})do
    local config=custom_config();config.archive_size=value;H.falsy(Config.validate(config))
    config=custom_config();config.network.foundation_port=value;H.falsy(Config.validate(config))
    config=custom_config();config.roles.breeder.side=value;H.falsy(Config.validate(config))
    config=custom_config();config.roles.bee_storage.reserved_slot=value;H.falsy(Config.validate(config))
    config=custom_config();config.limits.transfer=value;H.falsy(Config.validate(config))
  end
  H.truthy(Config.validate(custom_config()))
end)

H.test("operations reject non-finite archive and loop budgets before any loop",function()
  local fake={}
  for _,value in ipairs({0/0,math.huge,-math.huge})do
    H.falsy(pcall(Operations.new,fake,{archive_size=value}))
    H.falsy(pcall(Operations.new,fake,{limits={archive=value}}))
  end
  H.truthy(Operations.new(fake,{archive_size=32,limits={archive=1}}))
end)

H.test("robot rejects non-finite replay bounds inventory sizes and stack maxima",function()
  local fs,open=memory_files()
  for _,value in ipairs({0/0,math.huge,-math.huge})do local instance=service(EPOCH_A,fs,open,{max_cache=value});H.falsy(instance)end

  local fs2,open2=memory_files();local instance=assert(service(EPOCH_A,fs2,open2,{inventory_size=math.huge}))
  local snapshot,err=instance:inventory_snapshot("item:stone");H.falsy(snapshot);H.contains(err,"finite")

  local fs3,open3=memory_files();instance=assert(service(EPOCH_A,fs3,open3,{stacks={{name="item:stone",size=1,maxSize=math.huge}}}))
  snapshot,err=instance:inventory_snapshot("item:stone");H.falsy(snapshot);H.contains(err,"malformed finite")
end)

H.test("robot and CLI numeric configuration reject non-finite values with valid controls",function()
  local base={port=24193,side=0,controller_address="controller",modem_address="robot",data_address="data",shared_secret=string.rep("s",16),replay_epoch=EPOCH_A,replay_journal="/replay",max_replay_entries=8,block_items={["world:stone"]="item:stone"}}
  local function run(config)return RobotMain.run({}, {load_config=function()return config end,runtime={},auth=auth})end
  for _,field in ipairs({"port","side","max_replay_entries"})do
    for _,value in ipairs({0/0,math.huge,-math.huge})do local config=util.copy(base);config[field]=value;local ok=run(config);H.falsy(ok)end
  end
  local command,err=Command.parse({"convert","a","--count=1e309"});H.falsy(command);H.contains(err,"finite positive integer")
  H.equal(assert(Command.parse({"convert","a","--count=2"})).count,2)
end)

return H
