package.path="./lib/?.lua;./tests/?.lua;./?.lua;"..package.path
local H=require("tests.harness")
local Foundation=require("gtnh_bees.foundation")
local RobotService=require("gtnh_bees.robot_service")
local RobotMain=require("gtnh_bees.robot_main")
local EPOCH="foundation-epoch-0000000000000001"

local function auth(value)
  local n=0
  for index=1,#value do n=(n*131+string.byte(value,index))%2147483647 end
  return string.format("%08x",n)
end

local function memory_files(initial,fail_write)
  local files={}
  for path,value in pairs(initial or{})do files[path]=value end
  local fs={}
  function fs.exists(path)return files[path]~=nil end
  function fs.rename(source,destination)
    if files[source]==nil then return nil,"missing source"end
    files[destination],files[source]=files[source],nil
    return true
  end
  local function open(path,mode)
    if mode=="r"then
      local data=files[path];if type(data)~="string"then return nil,"missing"end
      return {read=function(_,format)if format=="*a"then return data end end,close=function()return true end}
    end
    if mode~="w"or fail_write then return nil,"injected unwritable state"end
    local chunks={}
    return {
      write=function(_,value)chunks[#chunks+1]=value;return true end,
      flush=function()return true end,
      close=function()files[path]=table.concat(chunks);return true end
    }
  end
  return fs,open,files
end

local function runtime_fixture(options)
  options=options or{}
  if not options.filesystem then options.filesystem,options.open=memory_files()end
  local slots=options.slots or{}
  local selected=1
  local installed=options.installed or"world:old"
  local swings,sends=0,{}
  local runtime={sides={down=0},event={pull=function()end}}
  runtime.robot={
    inventorySize=function()return options.inventory_size or 3 end,
    select=function(slot)selected=slot;return slot end,
    swing=function()
      swings=swings+1
      if options.swing_error then error("injected swing crash")end
      installed=nil
      if options.drop_slot then
        local stack=slots[options.drop_slot]
        if stack then stack.size=stack.size+1 else slots[options.drop_slot]={name=options.drop_item,size=1,maxSize=64}end
      end
      return true
    end,
    place=function()
      local stack=slots[selected]
      if not stack or stack.size<1 then return nil,"empty selected slot"end
      if options.place_errors and options.place_errors[stack.name]then error("injected place crash for "..stack.name)end
      local world=(options.item_world or{})[stack.name]
      if not world then return nil,"item cannot be placed"end
      stack.size=stack.size-1
      installed=world
      return true
    end
  }
  runtime.component={
    modem={open=function()return true end,isOpen=function()return true end,send=function(_,_,payload)sends[#sends+1]=payload;if options.send_error then error("injected reply crash")end;if options.send_failure then return false,"lost link"end return true end},
    inventory_controller={getStackInInternalSlot=function(slot)local stack=slots[slot];if not stack or stack.size==0 then return nil end return stack end},
    geolyzer={analyze=function()return installed and{name=installed}or nil end}
  }
  runtime.filesystem=options.filesystem
  runtime.open=options.open
  runtime.state=function()return{installed=installed,swings=swings,sends=sends,slots=slots}end
  return runtime
end
local function service(runtime,extra)
  extra=extra or{}
  return RobotService.new({peer_address="controller",local_address="robot",auth=auth,epoch=extra.epoch or EPOCH,journal_path=extra.journal_path or"/replay",max_cache=extra.max_cache or 8,restore_attempts=2,block_items=extra.block_items or{["world:old"]="item:drop",["world:new"]="item:target"}},runtime)
end

H.test("controller opens its pinned port once and repeats requests",function()
  local opened,sent=0,0
  local current
  local modem={
    open=function()opened=opened+1;return false,"already open"end,
    isOpen=function(port)H.equal(port,Foundation.port);return true end,
    send=function(_,_,payload)current=assert(Foundation.decode(payload,auth,EPOCH));sent=sent+1;return true end
  }
  local event={pull=function()
    local reply=assert(Foundation.encode("ok",EPOCH,current.id,current.nonce,current.block,"done",auth))
    return"modem_message","controller","robot",Foundation.port,0,reply
  end}
  local nonce=0
  local controller=Foundation.Controller.new(modem,event,{peer_address="robot",local_address="controller",auth=auth,epoch=EPOCH,clock=function()return 4 end,nonce=function()nonce=nonce+1;return"n"..nonce end})
  H.truthy(controller:request("world:new"));H.truthy(controller:request("world:new"))
  H.equal(opened,1);H.equal(sent,2)
end)

H.test("controller classifies pinned-port open failure as transient without sending",function()
  local sends=0
  local modem={open=function()return false,"closed"end,isOpen=function()return false end,send=function()sends=sends+1 end}
  local controller=Foundation.Controller.new(modem,{pull=function()end},{peer_address="robot",local_address="controller",auth=auth,epoch=EPOCH,clock=function()return 1 end,nonce=function()return"n"end})
  local ok,err,failure=controller:request("world:new");H.falsy(ok);H.contains(err,"could not open");H.equal(failure,"transient");H.equal(sends,0)
end)

H.test("controller classifies modem send failure as transient",function()
  local sends=0
  local modem={open=function()return true end,isOpen=function()return true end,send=function()sends=sends+1;return false,"link unavailable"end}
  local controller=Foundation.Controller.new(modem,{pull=function()error("must not poll after send failure")end},{peer_address="robot",local_address="controller",auth=auth,epoch=EPOCH,clock=function()return 1 end,nonce=function()return"n"end})
  local ok,err,failure=controller:request("world:new");H.falsy(ok);H.contains(err,"link unavailable");H.equal(failure,"transient");H.equal(sends,1)
end)

H.test("controller contains modem send exceptions as transient failures",function()
  local sends=0
  local modem={open=function()return true end,isOpen=function()return true end,send=function()sends=sends+1;error("modem disappeared")end}
  local controller=Foundation.Controller.new(modem,{pull=function()error("must not poll after send exception")end},{peer_address="robot",local_address="controller",auth=auth,epoch=EPOCH,clock=function()return 1 end,nonce=function()return"n"end})
  local survived,ok,err,failure=pcall(controller.request,controller,"world:new")
  H.truthy(survived);H.falsy(ok);H.contains(err,"modem disappeared");H.equal(failure,"transient");H.equal(sends,1)
end)

H.test("controller contains nonce failures as transient before opening or sending",function()
  for _,nonce in ipairs({function()error("data card disappeared")end,function()return nil,"no random bytes"end})do
    local opened,sends=0,0
    local modem={open=function()opened=opened+1;return true end,send=function()sends=sends+1;return true end}
    local controller=Foundation.Controller.new(modem,{pull=function()error("must not poll after nonce failure")end},{peer_address="robot",local_address="controller",auth=auth,epoch=EPOCH,clock=function()return 1 end,nonce=nonce})
    local survived,ok,err,failure=pcall(controller.request,controller,"world:new")
    H.truthy(survived);H.falsy(ok);H.contains(err,"nonce generation failed");H.equal(failure,"transient");H.equal(opened,0);H.equal(sends,0)
  end
end)

H.test("replacement refuses an unknown dropped-item mapping before swing",function()
  local runtime=runtime_fixture({slots={{name="item:target",size=1,maxSize=64}},inventory_size=2,item_world={["item:target"]="world:new"}})
  local instance=assert(service(runtime,{block_items={["world:new"]="item:target"}}))
  local ok,err=instance:replace("world:new");H.falsy(ok);H.contains(err,"dropped-item mapping");H.equal(runtime.state().swings,0)
end)

H.test("replacement proves a differently named drop at exact slot and count",function()
  local runtime=runtime_fixture({slots={{name="item:target",size=2,maxSize=64},{name="item:drop",size=4,maxSize=64}},drop_slot=2,drop_item="item:drop",item_world={["item:target"]="world:new",["item:drop"]="world:old"}})
  local instance=assert(service(runtime))
  local ok,detail=instance:replace("world:new");H.truthy(ok);H.contains(detail,"item:drop");H.contains(detail,"slot 2 count 5 (+1)");H.equal(runtime.state().installed,"world:new")
end)

H.test("unproved retention attempts bounded restoration and never reports success",function()
  local runtime=runtime_fixture({slots={{name="item:target",size=1,maxSize=64},{name="item:drop",size=1,maxSize=64}},inventory_size=3,item_world={["item:target"]="world:new",["item:drop"]="world:old"}})
  local instance=assert(service(runtime))
  local ok,detail=instance:replace("world:new");H.falsy(ok);H.contains(detail,"could not be proved");H.contains(detail,"restored");H.equal(runtime.state().installed,"world:old")
end)

H.test("placement exceptions after removal attempt bounded restoration without escaping",function()
  local runtime=runtime_fixture({
    slots={{name="item:target",size=1,maxSize=64},{name="item:drop",size=1,maxSize=64}},
    drop_slot=2,drop_item="item:drop",
    place_errors={["item:target"]=true},
    item_world={["item:target"]="world:new",["item:drop"]="world:old"}
  })
  local instance=assert(service(runtime))
  local survived,ok,detail=pcall(instance.replace,instance,"world:new")
  H.truthy(survived);H.falsy(ok);H.contains(detail,"place raised");H.contains(detail,"restored")
  H.equal(runtime.state().installed,"world:old")
end)

H.test("restoration callback exceptions stay inside the finite restoration budget",function()
  local runtime=runtime_fixture({
    slots={{name="item:target",size=1,maxSize=64},{name="item:drop",size=1,maxSize=64}},
    drop_slot=2,drop_item="item:drop",
    place_errors={["item:target"]=true,["item:drop"]=true},
    item_world={["item:target"]="world:new",["item:drop"]="world:old"}
  })
  local instance=assert(service(runtime))
  local survived,ok,detail=pcall(instance.replace,instance,"world:new")
  H.truthy(survived);H.falsy(ok);H.contains(detail,"bounded restoration failed");H.contains(detail,"restoration callback failure")
  H.falsy(runtime.state().installed)
end)

H.test("durable final outcome survives reply loss and restart",function()
  local fs,open,files=memory_files()
  local slots={{name="item:target",size=2,maxSize=64},{name="item:drop",size=2,maxSize=64}}
  local first=runtime_fixture({slots=slots,drop_slot=2,drop_item="item:drop",item_world={["item:target"]="world:new",["item:drop"]="world:old"},filesystem=fs,open=open,send_failure=true})
  local request=assert(Foundation.encode("request",EPOCH,"durable","nonce-a","world:new",nil,auth))
  local instance=assert(service(first,{journal_path="/replay"}))
  local ok,err=instance:handle("controller",request,"robot");H.falsy(ok);H.contains(err,"transiently failed");H.equal(first.state().swings,1);H.truthy(files["/replay"])
  local second=runtime_fixture({installed="world:new",slots=slots,item_world={["item:target"]="world:new",["item:drop"]="world:old"},filesystem=fs,open=open})
  local restarted=assert(service(second,{journal_path="/replay"}))
  H.truthy(restarted:handle("controller",request,"robot"));H.equal(second.state().swings,0)
  local collision=assert(Foundation.encode("request",EPOCH,"durable","nonce-a","world:old",nil,auth))
  local collision_ok,collision_err=restarted:handle("controller",collision,"robot");H.falsy(collision_ok);H.contains(collision_err,"request ID was reused");H.equal(second.state().swings,0)
  local content_collision=assert(Foundation.encode("request",EPOCH,"durable","nonce-a","world:new","different",auth))
  collision_ok,collision_err=restarted:handle("controller",content_collision,"robot");H.falsy(collision_ok);H.contains(collision_err,"authenticated content");H.equal(second.state().swings,0)
  local nonce_reuse=assert(Foundation.encode("request",EPOCH,"other","nonce-a","world:new",nil,auth))
  local nonce_ok,nonce_err=restarted:handle("controller",nonce_reuse,"robot");H.falsy(nonce_ok);H.contains(nonce_err,"nonce was reused");H.equal(second.state().swings,0)
end)

H.test("reply callback exception preserves durable replay without a second physical action",function()
  local fs,open,files=memory_files()
  local slots={{name="item:target",size=2,maxSize=64},{name="item:drop",size=2,maxSize=64}}
  local first=runtime_fixture({slots=slots,drop_slot=2,drop_item="item:drop",item_world={["item:target"]="world:new",["item:drop"]="world:old"},filesystem=fs,open=open,send_error=true})
  local request=assert(Foundation.encode("request",EPOCH,"reply-crash","nonce-r","world:new",nil,auth))
  local instance=assert(service(first,{journal_path="/replay"}))
  local survived,ok,err=pcall(instance.handle,instance,"controller",request,"robot")
  H.truthy(survived);H.falsy(ok);H.contains(err,"transiently failed");H.equal(first.state().swings,1);H.truthy(files["/replay"])
  local second=runtime_fixture({installed="world:new",slots=slots,item_world={["item:target"]="world:new",["item:drop"]="world:old"},filesystem=fs,open=open})
  local restarted=assert(service(second,{journal_path="/replay"}))
  H.truthy(restarted:handle("controller",request,"robot"));H.equal(second.state().swings,0)
end)

H.test("swing exceptions are reconciled and finalized instead of escaping as pending actions",function()
  local fs,open=memory_files()
  local first=runtime_fixture({slots={{name="item:target",size=1,maxSize=64}},inventory_size=2,swing_error=true,item_world={["item:target"]="world:new"},filesystem=fs,open=open})
  local request=assert(Foundation.encode("request",EPOCH,"pending","nonce-p","world:new",nil,auth))
  local instance=assert(service(first,{journal_path="/replay"}))
  local survived,ok,detail=pcall(instance.handle,instance,"controller",request,"robot")
  H.truthy(survived);H.falsy(ok);H.contains(detail,"physically uncertain");H.equal(first.state().installed,"world:old")
  local second=runtime_fixture({slots={{name="item:target",size=1,maxSize=64}},inventory_size=2,item_world={["item:target"]="world:new"},filesystem=fs,open=open})
  local restarted=assert(service(second,{journal_path="/replay"}))
  ok,detail=restarted:handle("controller",request,"robot");H.falsy(ok);H.contains(detail,"physically uncertain");H.equal(second.state().swings,0)
end)

H.test("robot config requires an absolute journal and exact block-item mappings",function()
  local base={port=24193,side=0,controller_address="controller",modem_address="robot",data_address="data",shared_secret=string.rep("s",16),replay_epoch=EPOCH,replay_journal="/replay",block_items={["world:old"]="item:drop"}}
  local function run(config)return RobotMain.run({}, {load_config=function()return config end,runtime={},auth=auth})end
  local missing={};for key,value in pairs(base)do missing[key]=value end;missing.replay_journal=nil
  local ok,err=run(missing);H.falsy(ok);H.contains(err,"replay_journal")
  local relative={};for key,value in pairs(base)do relative[key]=value end;relative.replay_journal="replay"
  ok,err=run(relative);H.falsy(ok);H.contains(err,"absolute")
  local unmapped={};for key,value in pairs(base)do unmapped[key]=value end;unmapped.block_items={}
  ok,err=run(unmapped);H.falsy(ok);H.contains(err,"at least one exact mapping")
end)

H.test("corrupt and unwritable replay state fail closed",function()
  local fs,open,files=memory_files()
  local runtime=runtime_fixture({slots={{name="item:target",size=1,maxSize=64}},inventory_size=2,item_world={["item:target"]="world:new"},filesystem=fs,open=open})
  local request=assert(Foundation.encode("request",EPOCH,"bad-state","nonce-b","world:new",nil,auth))
  local instance=assert(service(runtime,{journal_path="/replay"}));instance:handle("controller",request,"robot")
  files["/replay"]=files["/replay"]:gsub("mac|.","mac|f",1)
  local corrupt,corrupt_err=service(runtime,{journal_path="/replay"});H.falsy(corrupt);H.contains(corrupt_err,"authentication failed")
  local fs2,open2=memory_files(nil,true)
  local blocked_runtime=runtime_fixture({slots={{name="item:target",size=1,maxSize=64}},inventory_size=2,item_world={["item:target"]="world:new"},filesystem=fs2,open=open2})
  local blocked,err=service(blocked_runtime,{journal_path="/replay"})
  H.falsy(blocked);H.contains(err,"cannot open replay journal");H.equal(blocked_runtime.state().swings,0)
end)

return H
