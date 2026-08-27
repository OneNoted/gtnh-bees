local H = require("tests.harness")
local util = require("gtnh_bees.util")
local Adapter = require("gtnh_bees.hardware")
local Operations = require("gtnh_bees.operations")
local Transaction = require("gtnh_bees.transaction")
local Foundation = require("gtnh_bees.foundation")
local RobotService = require("gtnh_bees.robot_service")
local RobotMain = require("gtnh_bees.robot_main")
local Config = require("gtnh_bees.config")
local Official = require("gtnh_bees.official_driver")
local Application = require("gtnh_bees.application")
local Installer = require("gtnh_bees.installer")
local Manifest = require("gtnh_bees.install_manifest")
local Planner = require("gtnh_bees.planner")
local unpack_values=table.unpack or unpack

local function adapter_fixture(options)
  options=options or {}
  local inventories={
    [0]={size=4,slots={}}, [1]={size=4,slots={}}, [2]={size=4,slots={}}, [3]={size=4,slots={}}
  }
  local calls=0
  local tx={}
  function tx.getInventorySize(side) return inventories[side].size end
  function tx.getStackInSlot(side,slot) return util.copy(inventories[side].slots[slot]) end
  function tx.transferItem(sourceSide,destinationSide,count,sourceSlot,destinationSlot)
    calls=calls+1
    if options.block_after and calls>options.block_after then return 0 end
    local source=inventories[sourceSide].slots[sourceSlot]; if not source then return 0 end
    local moved=math.min(count,source.size,options.max_per_call or count)
    local destination=inventories[destinationSide].slots[destinationSlot]
    if destination then destination.size=destination.size+moved else destination=util.copy(source); destination.size=moved; inventories[destinationSide].slots[destinationSlot]=destination end
    source.size=source.size-moved; if source.size==0 then inventories[sourceSide].slots[sourceSlot]=nil end
    return moved
  end
  local genetics={}
  local runtime={component={proxy=function(address) return address=="tx" and tx or genetics end}}
  local driver={
    list_species=function() return {{uid="a",name="A"},{uid="b",name="B"}} end,
    list_mutations=function() return {} end,
    inspect_stack=function(raw) return util.copy(raw) end,
    scan_generation=function(_,bee) return {safe=true,complete=true,identity={caste=bee.caste,active=bee.active,inactive=bee.inactive},location="bee_storage",scanned=true,bee=util.copy(bee)} end,
    breed_generation=function(_,step) return {safe=true,complete=true,uid=step.uid or step.archive_uid,location="bee_storage",outputs={}} end,
    convert_generation=function(_,uid,princess) return {safe=true,complete=true,uid=uid,princess_identity=princess.active,location="bee_storage"} end,
    imprint_generation=function(_,uid) return {safe=true,complete=true,uid=uid,scanned=true,template_retained=true,location="bee_storage"} end
  }
  if options.driver then for key,value in pairs(options.driver) do driver[key]=value end end
  local roles={
    genetics={address="gen"}, bee_storage={address="tx",side=0,reserved_slot=4},
    breeder={address="tx",side=1,princess_slot=1,drone_slot=2,output_slots={3,4}}, scanner={address="tx",side=2,input_slot=1,output_slots={2}}, recovery={address="tx",side=3,output_slots={1,2,3,4}}
  }
  local config={roles=roles,limits={transfer=options.transfer_limit or 3,scanning=3,breeding=3,archive=3,conversion=3,imprint=3}}
  local adapter=assert(Adapter.new(config,driver,runtime))
  return adapter,inventories,function() return calls end
end

local function raw_bee(caste,active,inactive,slot,size,genome)
  return {caste=caste,active=active,inactive=inactive,scanned=true,size=size or 1,maxSize=64,genome=genome or {speed="steady"},slot=slot}
end

H.test("verified transfer moves exactly the requested amount", function()
  local adapter,inv=adapter_fixture({max_per_call=1,transfer_limit=4}); inv[0].slots[1]=raw_bee("drone","a","a",1,5)
  H.equal(assert(adapter:transfer_verified("bee_storage",1,"scanner",1,3)),3); H.equal(inv[0].slots[1].size,2); H.equal(inv[2].slots[1].size,3)
end)
H.test("partial transfer failure never drains more than requested", function()
  local adapter,inv=adapter_fixture({max_per_call=1,block_after=1,transfer_limit=3}); inv[0].slots[1]=raw_bee("drone","a","a",1,5)
  local moved,err=adapter:transfer_verified("bee_storage",1,"scanner",1,3); H.falsy(moved); H.contains(err,"retry limit"); H.equal(inv[0].slots[1].size,4)
end)
H.test("machine recovery preserves bee identity", function()
  local adapter,inv=adapter_fixture(); inv[2].slots[2]=raw_bee("drone","a","b",2,2,{trait={active=1,inactive=2}})
  local recovered=assert(adapter:recover_pending()); H.equal(#recovered,1); local snapshot=assert(adapter:snapshot_storage())
  H.equal(snapshot.bees[1].active,"a"); H.equal(snapshot.bees[1].inactive,"b"); H.equal(snapshot.bees[1].genome,{trait={active=1,inactive=2}})
end)
H.test("scanner rejects changed bee identity", function()
  local adapter=adapter_fixture({driver={scan_generation=function(_,bee) return {safe=true,complete=true,identity={caste=bee.caste,active="b",inactive=bee.inactive},location="bee_storage",scanned=true} end}})
  local result,err=adapter:scan_bee(raw_bee("drone","a","a",1)); H.falsy(result); H.contains(err,"identity")
end)

local function archive_adapter()
  local calls=0
  local princess=raw_bee("princess","a","a",1,1,{x=1}); local drone=raw_bee("drone","a","a",2,1,{x=1})
  princess.inventory,drone.inventory="bee_storage","bee_storage"
  return {
    snapshot_storage=function() return {size=4,reserved_slot=4,bees={princess,drone}} end,
    expand_archive=function() calls=calls+1; return {safe=true,complete=true,uid="a",location="bee_storage",outputs={}} end
  },function() return calls end
end
H.test("archive breeding terminates at its generation limit", function()
  local fake,calls=archive_adapter(); local operations=Operations.new(fake,{archive_size=32,limits={archive=3}})
  local result,err=operations:archive("a"); H.falsy(result); H.contains(err,"exceeded 3"); H.equal(calls(),3)
end)
H.test("imprinting terminates at its generation limit", function()
  local template=raw_bee("drone","a","a",4,1,{x=1}); template.inventory="bee_storage"
  local princess=raw_bee("princess","a","a",1,1,{x=2});local donor=raw_bee("drone","a","a",2,1,{x=1});princess.inventory,donor.inventory="bee_storage","bee_storage"
  local calls=0; local fake={snapshot_storage=function() return {size=4,reserved_slot=4,bees={princess,donor,template}} end,imprint_one=function() calls=calls+1; return {safe=true,uid="a",scanned=false,template_retained=true,retained_princess=util.copy(princess),location="bee_storage",complete=false} end}
  local operations=Operations.new(fake,{limits={imprint=2}}); local result,err=operations:optional_imprint("a"); H.falsy(result); H.contains(err,"exceeded 2"); H.equal(calls,2)
end)
H.test("conversion is bounded when the adapter never changes stock", function()
  local princess=raw_bee("princess","b","b",1); princess.inventory="bee_storage"
  local drone=raw_bee("drone","a","a",2); drone.inventory="bee_storage"
  local calls=0; local fake={recover_pending=function() return {} end,snapshot_storage=function() return {size=4,reserved_slot=4,bees={princess,drone}} end,scan_bee=function(b)return b end,
    list_species=function() return {{uid="a",name="A"},{uid="b",name="B"}} end,list_mutations=function() return {} end,
    convert_one=function(_,uid,princess) calls=calls+1; return {safe=true,uid=uid,princess_identity=princess.active,retained_princess=util.copy(princess),location="bee_storage",complete=false,error="generation budget reached"} end}
  local operations=Operations.new(fake,{limits={conversion=3,conversion_generations=3}}); local outcome=assert(operations:convert({species="A",all=true})); H.falsy(outcome.success); H.equal(calls,3); H.contains(outcome.error,"generation")
end)
H.test("scanner reconciliation terminates when scanning makes no progress", function()
  local drone=raw_bee("drone","a","a",1); drone.scanned=false; drone.inventory="bee_storage"
  local calls=0; local fake={snapshot_storage=function()return {size=2,reserved_slot=2,bees={drone}}end,scan_bee=function()calls=calls+1;return {safe=true,complete=true,identity={caste="drone",active="a",inactive="a"},location="bee_storage",scanned=true}end}
  local operations=Operations.new(fake,{}); local snapshot,err=operations:reconcile(true); H.falsy(snapshot); H.equal(calls,2); H.contains(err,"did not converge")
end)
H.test("complete keeps a startup target missing after route failure", function()
  local bees={raw_bee("princess","a","a",1,1,{x=1}),raw_bee("drone","a","a",2,32,{x=1}),raw_bee("princess","b","b",3,1,{x=2}),raw_bee("drone","b","b",4,32,{x=2})}
  for _,bee in ipairs(bees) do bee.inventory="bee_storage" end
  local fake={recover_pending=function()return {}end,snapshot_storage=function()return {size=6,reserved_slot=6,bees=bees}end,scan_bee=function(bee)return bee end,
    list_species=function()return {{uid="a",name="A"},{uid="b",name="B"},{uid="c",name="C"}}end,
    list_mutations=function()return {{result="c",parents={"a","b"},chance=10}}end,
    produce_species=function()return {safe=true,complete=false,uid="c",location="bee_storage",outputs={},route_failure="deterministic",error="environment rejected route"}end}
  local operations=Operations.new(fake,{limits={progress=5}}); local result=assert(operations:complete({imprint="none"}))
  H.equal(#result.missing,1); H.equal(result.missing[1].uid,"c"); H.contains(result.missing[1].reason,"environment rejected")
end)
local function auth(value)local n=0 for i=1,#value do n=(n*131+string.byte(value,i))%2147483647 end return string.format("%08x",n)end
local EPOCH="safety-epoch-0000000000000001"
local function epoch_encode(kind,id,nonce,block,detail,authenticate)return Foundation.encode(kind,EPOCH,id,nonce,block,detail,authenticate)end
local function epoch_decode(message,authenticate)return Foundation.decode(message,authenticate,EPOCH)end
local function new_service(options,runtime)
  local files={}
  runtime.filesystem={exists=function(path)return files[path]~=nil end,rename=function(source,destination)if files[source]==nil then return nil,"missing source"end files[destination],files[source]=files[source],nil;return true end}
  runtime.open=function(path,mode)
    if mode=="r"then local data=files[path];if type(data)~="string"then return nil,"missing"end return{read=function(_,format)if format=="*a"then return data end end,close=function()return true end}end
    local chunks={};return{write=function(_,value)chunks[#chunks+1]=value;return true end,flush=function()return true end,close=function()files[path]=table.concat(chunks);return true end}
  end
  options.epoch,options.journal_path=EPOCH,"/replay"
  return RobotService.new(options,runtime)
end
H.test("foundation data-card authentication uses the configured HMAC key",function()
  local secret=string.rep("s",16);local seen
  local keyed=assert(Foundation.data_auth({sha256=function(payload,key)seen={payload,key};return "\1\2\255"end},secret))
  H.equal(assert(keyed("body")),"0102ff");H.equal(seen[1],"body");H.equal(seen[2],secret)
  local value,err=Foundation.data_auth({sha256=function()end},"short");H.falsy(value);H.contains(err,"at least 16")
end)
H.test("foundation controller has bounded attempts and replies", function()
  local sends,pulls=0,0; local modem={open=function()end,send=function()sends=sends+1;return true end}; local event={pull=function()pulls=pulls+1 end}
  local controller=Foundation.Controller.new(modem,event,{attempts=2,timeout=0.5,clock=function()return 1 end,peer_address="robot",local_address="controller",auth=auth,epoch=EPOCH,nonce=function()return"nonce"end}); local ok,err,failure=controller:request("minecraft:dirt")
  H.falsy(ok); H.contains(err,"did not reply"); H.equal(failure,"transient"); H.equal(sends,2); H.equal(pulls,4)
end)
H.test("foundation protocol rejects ambiguous block fields", function() local value=epoch_encode("request","x","n","bad|block",nil,auth); H.falsy(value) end)
H.test("foundation robot confirms replacement before breaking", function()
  local swings=0; local runtime={sides={down=0},event={pull=function()end},robot={inventorySize=function()return 2 end,select=function(slot)return slot end,swing=function()swings=swings+1;return true end,place=function()return true end},
    component={modem={open=function()end},inventory_controller={getStackInInternalSlot=function()return nil end},geolyzer={analyze=function()return {name="minecraft:stone"} end}}}
  local service=new_service({peer_address="controller",local_address="robot",auth=auth,block_items={["minecraft:dirt"]="minecraft:dirt",["minecraft:stone"]="minecraft:stone"}},runtime); local ok,err=service:replace("minecraft:dirt"); H.falsy(ok); H.contains(err,"not in robot inventory"); H.equal(swings,0)
end)
H.test("foundation robot retry is idempotent after success", function()
  local sent,swings={},0; local installed="minecraft:stone";local inventory={{name="minecraft:dirt",size=2,maxSize=64},{name="minecraft:stone",size=1,maxSize=64}}
  local runtime={sides={down=0},event={pull=function()end},robot={inventorySize=function()return 2 end,select=function(slot)return slot end,swing=function()swings=swings+1;inventory[2].size=inventory[2].size+1;installed=nil;return true end,place=function()installed="minecraft:dirt";return true end},
    component={modem={open=function()end,send=function(_,_,payload)sent[#sent+1]=payload;return true end},inventory_controller={getStackInInternalSlot=function(slot)return inventory[slot]end},geolyzer={analyze=function()return installed and{name=installed}or nil end}}}
  local service=new_service({peer_address="controller",local_address="robot",auth=auth,block_items={["minecraft:dirt"]="minecraft:dirt",["minecraft:stone"]="minecraft:stone"}},runtime); local request=assert(epoch_encode("request","42","nonce","minecraft:dirt",nil,auth)); H.truthy(service:handle("controller",request,"robot")); H.truthy(service:handle("controller",request,"robot")); H.equal(swings,1); H.equal(#sent,2)
end)
H.test("foundation robot refuses to break when displaced block cannot be retained", function()
  local swings=0; local runtime={sides={down=0},event={pull=function()end},robot={inventorySize=function()return 1 end,select=function(slot)return slot end,swing=function()swings=swings+1;return true end,place=function()return true end},
    component={modem={open=function()end},inventory_controller={getStackInInternalSlot=function()return {name="minecraft:dirt",size=64,maxSize=64} end},geolyzer={analyze=function()return {name="minecraft:stone"} end}}}
  local service=new_service({peer_address="controller",local_address="robot",auth=auth,block_items={["minecraft:dirt"]="minecraft:dirt",["minecraft:stone"]="minecraft:stone"}},runtime); local ok,err=service:replace("minecraft:dirt"); H.falsy(ok); H.contains(err,"no proven capacity"); H.equal(swings,0)
end)

local function memory_fs(initial, fail_rule)
  local files=util.copy(initial or {}); files["/"]=files["/"]or{directory=true}; local fs={}
  function fs.exists(path)return files[path]~=nil end
  function fs.isDirectory(path)return type(files[path])=="table"and files[path].directory==true end
  function fs.makeDirectory(path) files[path]=files[path] or {directory=true}; return true end
  function fs.remove(path) files[path]=nil; return true end
  function fs.rename(source,destination)
    if fail_rule and fail_rule(source,destination) then return nil,"injected rename failure" end
    if files[source]==nil then return nil,"missing source" end
    files[destination],files[source]=files[source],nil; return true
  end
  function fs.open(path,mode)
    if mode=="w" then
      local chunks={}; return {write=function(self,...) for i=1,select("#",...) do chunks[#chunks+1]=tostring(select(i,...)) end; return true end,flush=function()return true end,close=function()files[path]=table.concat(chunks);return true end}
    end
    local data=files[path]; if type(data)~="string" then return nil end
    local position=1
    return {read=function(self,format) if format=="*l" then local s,e=data:find("\n",position,true); local line=s and data:sub(position,s-1) or data:sub(position); position=s and e+1 or #data+1; return line~="" and line or nil end end,
      lines=function(self)return function()return self:read("*l")end end,close=function()end}
  end
  return fs,files
end
H.test("installer rename failure restores the prior complete installation", function()
  local failed=false; local fs,files=memory_fs({["/a"]="old-a",["/b"]="old-b"},function(source,destination) if destination=="/b" and source:find("stage",1,true) then failed=true;return true end end)
  local manifest={{url="u/a",path="a"},{url="u/b",path="b"}}
  local ok,err=Transaction.install({fs=fs,root="/",manifest=manifest,now=function()return 9 end,fetch=function(url,path)files[path]="new-"..url;return true end})
  H.falsy(ok); H.truthy(failed); H.equal(files["/a"],"old-a"); H.equal(files["/b"],"old-b"); H.contains(err,"cannot install")
end)
H.test("installer download failure never replaces an old file", function()
  local fs,files=memory_fs({["/a"]="old-a"}); local ok=Transaction.install({fs=fs,root="/",manifest={{url="bad",path="a"}},now=function()return 8 end,fetch=function()return nil,"network" end})
  H.falsy(ok); H.equal(files["/a"],"old-a")
end)
H.test("installer recovery restores a pre-update set after interruption", function()
  local journal="installing\n/a\t/stage/a\t/backup/a\t1\t1\n/b\t/stage/b\t/backup/b\t1\t0\n"
  local fs,files=memory_fs({["/.gtnh-bees-install.journal"]=journal,["/a"]="new-a",["/backup/a"]="old-a",["/b"]="old-b"})
  H.truthy(Transaction.recover(fs,"/.gtnh-bees-install.journal")); H.equal(files["/a"],"old-a"); H.equal(files["/b"],"old-b"); H.falsy(files["/.gtnh-bees-install.journal"])
end)

H.test("callable-table transposer callbacks pass topology and transfer",function()
  local adapter,inv=adapter_fixture();local tx=adapter.proxies.tx
  for _,name in ipairs({"getInventorySize","getStackInSlot","transferItem"})do local fn=tx[name];tx[name]=setmetatable({}, {__call=function(_,...)return fn(...)end})end
  local rebuilt=assert(Adapter.new(adapter.config,adapter.driver,{component={proxy=function(address)return address=="tx"and tx or adapter.proxies.gen end}}))
  inv[0].slots[1]=raw_bee("drone","a","a",1,2)
  H.equal(assert(rebuilt:transfer_verified("bee_storage",1,"scanner",1,1)),1)
end)

H.test("hardware rejects reserved template slot at both transfer endpoints",function()
  local adapter,inv=adapter_fixture();inv[0].slots[4]=raw_bee("drone","a","a",4,1);inv[0].slots[1]=raw_bee("drone","a","a",1,1)
  local a,ae=adapter:transfer_verified("bee_storage",4,"scanner",1,1);local b,be=adapter:transfer_verified("bee_storage",1,"bee_storage",4,1)
  H.falsy(a);H.falsy(b);H.contains(ae,"reserved");H.contains(be,"reserved")
end)

H.test("official driver invokes fixed callable callbacks and maps stable UIDs",function()
  local callbacks={
    listAllSpecies=setmetatable({}, {__call=function()return {{uid="forestry.a",name="Alpha"},{uid="forestry.b",name="Beta"},{uid="forestry.c",name="Child"}}end}),
    getBeeBreedingData=setmetatable({}, {__call=function()return {{allele1="Alpha",allele2="Beta",result="Child",chance=12,specialConditions={}}}end})
  }
  local adapter={_official_species=nil,invoke=function(_,_,method)return callbacks[method]()end}
  local role={address="housing"};local species=Official.list_species(callbacks,role,adapter);local routes=Official.list_mutations(callbacks,role,adapter)
  H.equal(species[1].uid,"forestry.a");H.equal(routes[1].parents,{"forestry.a","forestry.b"});H.equal(routes[1].result,"forestry.c")
end)

H.test("official Forestry active and inactive genomes decode without aliases",function()
  local raw={name="bee.drone",size=2,maxSize=64,individual={type="bee",isAnalyzed=true,active={species={uid="a",name="A"},speed=1},inactive={species={uid="b",name="B"},speed=2}}}
  local decoded=assert(Official.inspect_stack(raw,{role="bee_storage",slot=1},{config={roles={bee_storage={caste_items={["bee.drone"]="drone"}}}}}))
  H.equal(decoded.active,"a");H.equal(decoded.inactive,"b");H.truthy(decoded.scanned);H.equal(decoded.genome.active.speed,1)
end)

H.test("malformed and non-finite mutation chances abort discovery",function()
  for _,chance in ipairs({"likely",math.huge,-1,101})do
    local adapter={list_species=function()return{{uid="a"},{uid="b"},{uid="c"}}end,list_mutations=function()return{{result="c",parents={"a","b"},chance=chance}}end}
    local catalog,err=require("gtnh_bees.catalog").discover(adapter);H.falsy(catalog);H.contains(err,"chance")
  end
end)

local function valid_config(archive)
  return {archive_size=archive,limits={transfer=1},network={},roles={genetics={address="g"},bee_storage={address="t",side=0,reserved_slot=4,caste_items={p="princess",d="drone",q="queen"}},breeder={address="t",side=1,princess_slot=1,drone_slot=2,output_slots={3}},scanner={address="t",side=2,component_address="s",input_slot=1,output_slots={2}},recovery={address="t",side=3,output_slots={1}}}}
end
H.test("archive target rejects zero fractions and every sub-32 value",function()
  for _,value in ipairs({0,1,31,31.5})do local ok,err=Config.validate(valid_config(value));H.falsy(ok);H.contains(err,"at least 32")end
  H.truthy(Config.validate(valid_config(32)))
end)

H.test("planner backtracks after a deterministic route exclusion",function()
  local catalog=require("gtnh_bees.catalog").new();for _,uid in ipairs({"a","b","c","d"})do assert(catalog:add_species({uid=uid}))end
  local first=assert(catalog:add_route({result="c",parents={"a","b"},chance=50}));assert(catalog:add_route({result="c",parents={"a","d"},chance=40}))
  local roles={princess={a=true,b=true,d=true},drone={a=true,b=true,d=true}}
  local one=assert(Planner.dependencies(catalog,"c",roles));H.equal(one[1].route.key,first.key)
  local two=assert(Planner.dependencies(catalog,"c",roles,{c={[first.key]="failed"}}));H.equal(two[1].route.parents,{"a","d"})
end)

H.test("complete executes reachable princess conversion preparation",function()
  local p=raw_bee("princess","b","b",1,1,{x=1});local ad=raw_bee("drone","a","a",2,1,{x=1});local bd=raw_bee("drone","b","b",3,32,{x=2});p.inventory,ad.inventory,bd.inventory="bee_storage","bee_storage","bee_storage"
  local bees={p,ad,bd};local conversions=0
  local fake={recover_pending=function()return{}end,snapshot_storage=function()return{size=5,reserved_slot=5,bees=bees}end,list_species=function()return{{uid="a",name="A"},{uid="b",name="B"}}end,list_mutations=function()return{}end,
    convert_one=function(_,uid,princess)conversions=conversions+1;princess.active,princess.inactive,princess.genome=uid,uid,{x=1};return{safe=true,complete=true,uid=uid,princess_identity="b",location="bee_storage"}end,
    expand_archive=function(_,uid)ad.size=32;return{safe=true,complete=true,uid=uid,location="bee_storage",outputs={}}end}
  local outcome=assert(Operations.new(fake,{limits={progress=8,archive=2}}):complete({imprint="none"}));H.equal(conversions,1);H.equal(outcome.missing,{})
end)

H.test("complete retries a deterministic alternate mutation route",function()
  local bees={};local slot=0
  for _,uid in ipairs({"a","b","d"})do slot=slot+1;local p=raw_bee("princess",uid,uid,slot,1,{x=uid});p.inventory="bee_storage";bees[#bees+1]=p;slot=slot+1;local d=raw_bee("drone",uid,uid,slot,32,{x=uid});d.inventory="bee_storage";bees[#bees+1]=d end
  local calls={}
  local fake={recover_pending=function()return{}end,snapshot_storage=function()return{size=10,reserved_slot=10,bees=bees}end,list_species=function()return{{uid="a"},{uid="b"},{uid="c"},{uid="d"}}end,list_mutations=function()return{{result="c",parents={"a","b"},chance=50},{result="c",parents={"a","d"},chance=40}}end,
    produce_species=function(_,step)calls[#calls+1]=step.route.parents[2];if step.route.parents[2]=="b"then return {safe=true,complete=false,uid="c",location="bee_storage",outputs={},route_failure="deterministic",error="first environment failed safely"}end;local p=raw_bee("princess","c","c",7,1,{x="c"});local d=raw_bee("drone","c","c",8,32,{x="c"});p.inventory,d.inventory="bee_storage","bee_storage";bees[#bees+1],bees[#bees+2]=p,d;return{safe=true,complete=true,uid="c",location="bee_storage",outputs={}}end}
  local outcome=assert(Operations.new(fake,{limits={progress=8}}):complete({imprint="none"}));H.equal(calls,{"b","d"});H.equal(outcome.missing,{})
end)

H.test("every malformed generation result fails closed",function()
  local princess=raw_bee("princess","a","a",1,1,{x=1});local drone=raw_bee("drone","a","a",2,1,{x=1});princess.inventory,drone.inventory="bee_storage","bee_storage"
  for _,bad in ipairs({true,"yes",{}, {safe=true}, {safe=false,complete=true,uid="a",location="bee_storage",outputs={}}})do
    local fake={snapshot_storage=function()return{size=4,reserved_slot=4,bees={princess,drone}}end,expand_archive=function()return bad end}
    local value,err=Operations.new(fake,{limits={archive=1}}):archive("a");H.falsy(value);H.truthy(err)
  end
end)

H.test("counted conversion reports an exact shortfall",function()
  local princess=raw_bee("princess","b","b",1);local drone=raw_bee("drone","a","a",2);princess.inventory,drone.inventory="bee_storage","bee_storage"
  local bees={princess,drone};local fake={recover_pending=function()return{}end,snapshot_storage=function()return{size=4,reserved_slot=4,bees=bees}end,list_species=function()return{{uid="a",name="A"},{uid="b",name="B"}}end,list_mutations=function()return{}end,
    convert_one=function(_,uid,p)local out={safe=true,complete=true,uid=uid,princess_identity=p.active,location="bee_storage"};bees={drone};return out end}
  local outcome=assert(Operations.new(fake,{limits={conversion=4}}):convert({species="A",count=2,all=false}));H.falsy(outcome.success);H.equal(outcome.converted,1);H.contains(outcome.error,"1 of 2")
end)

local function imprint_failure_adapter()
  local p=raw_bee("princess","a","a",1,1,{x=1});local d=raw_bee("drone","a","a",2,32,{x=1});local t=raw_bee("drone","a","a",4,1,{x=9});p.inventory,d.inventory,t.inventory="bee_storage","bee_storage","bee_storage"
  return {recover_pending=function()return{}end,snapshot_storage=function()return{size=4,reserved_slot=4,bees={p,d,t}}end,list_species=function()return{{uid="a",name="A"}}end,list_mutations=function()return{}end,imprint_one=function()return{safe=true,complete=false,uid="a",scanned=false,template_retained=true,location="bee_storage",error="grade missed"}end}
end
H.test("breed requested imprint failure is a truthful failed result",function()
  local outcome=assert(Operations.new(imprint_failure_adapter(),{}):breed({species="A",imprint="target",pause=false}));H.falsy(outcome.success);H.contains(outcome.error,"imprint")
end)
H.test("direct imprint failure makes the application non-successful",function()
  local app=Application.new(function()return imprint_failure_adapter(),{archive_size=32}end,function()end)
  local ok,err,outcome=app:execute({name="imprint",species="A"});H.falsy(ok);H.contains(err,"failed");H.equal(outcome.operation,"imprint");H.equal(outcome.safety_state,"known_safe")
end)

H.test("foundation authentication rejects altered content",function()
  local payload=assert(epoch_encode("request","1","n","stone",nil,auth));payload=payload:gsub("stone","dirt")
  local decoded,err=epoch_decode(payload,auth);H.falsy(decoded);H.contains(err,"authentication")
end)
H.test("foundation replay cache rejects ID content reuse",function()
  local sent,swings={},0;local installed="stone";local inventory={{name="dirt",size=2,maxSize=64},{name="stone",size=1,maxSize=64}}
  local runtime={sides={down=0},event={pull=function()end},robot={inventorySize=function()return 3 end,select=function(slot)return slot end,swing=function()swings=swings+1;inventory[2].size=inventory[2].size+1;installed=nil;return true end,place=function()installed="dirt";return true end},component={modem={open=function()end,send=function(_,_,p)sent[#sent+1]=p;return true end},inventory_controller={getStackInInternalSlot=function(slot)return inventory[slot]end},geolyzer={analyze=function()return installed and{name=installed}or nil end}}}
  local service=new_service({peer_address="controller",local_address="robot",auth=auth,block_items={dirt="dirt",stone="stone"}},runtime)
  H.truthy(service:handle("controller",assert(epoch_encode("request","same","n1","dirt",nil,auth)),"robot"))
  local ok,err=service:handle("controller",assert(epoch_encode("request","same","n2","sand",nil,auth)),"robot");H.falsy(ok);H.contains(err,"reused")
  H.equal(swings,1);local reply=assert(epoch_decode(sent[2],auth));H.equal(reply.kind,"error");H.contains(reply.detail,"reused")
end)
H.test("foundation replay cache rejects a nonce reused under another request ID",function()
  local sent,swings={},0;local installed="stone";local inventory={{name="dirt",size=2,maxSize=64},{name="stone",size=1,maxSize=64}}
  local runtime={sides={down=0},event={pull=function()end},robot={inventorySize=function()return 3 end,select=function(slot)return slot end,swing=function()swings=swings+1;inventory[2].size=inventory[2].size+1;installed=nil;return true end,place=function()installed="dirt";return true end},component={modem={open=function()end,send=function(_,_,p)sent[#sent+1]=p;return true end},inventory_controller={getStackInInternalSlot=function(slot)return inventory[slot]end},geolyzer={analyze=function()return installed and{name=installed}or nil end}}}
  local service=new_service({peer_address="controller",local_address="robot",auth=auth,block_items={dirt="dirt",stone="stone"}},runtime)
  H.truthy(service:handle("controller",assert(epoch_encode("request","one","same-nonce","dirt",nil,auth)),"robot"))
  local ok,err=service:handle("controller",assert(epoch_encode("request","two","same-nonce","dirt",nil,auth)),"robot")
  H.falsy(ok);H.contains(err,"nonce");H.equal(swings,1);local reply=assert(epoch_decode(sent[2],auth));H.equal(reply.kind,"error")
end)
H.test("foundation controller verifies local remote and requested block",function()
  local signals={
    {"modem_message","wrong-local","robot",24193,0,assert(epoch_encode("ok","1.nonce","nonce","stone","spoof",auth))},
    {"modem_message","controller","robot",24193,0,assert(epoch_encode("ok","1.nonce","nonce","dirt","wrong block",auth))}}
  local event={pull=function()local s=table.remove(signals,1);if s then return unpack_values(s)end end};local modem={open=function()end,send=function()return true end}
  local controller=Foundation.Controller.new(modem,event,{attempts=1,timeout=1,clock=function()return 1 end,peer_address="robot",local_address="controller",auth=auth,epoch=EPOCH,nonce=function()return"nonce"end})
  local ok,err=controller:request("stone");H.falsy(ok);H.contains(err,"different")
end)
H.test("foundation placement failure attempts original restoration",function()
  local selected,installed=1,"stone";local inventory={{name="dirt",size=1},{name="stone",size=1}}
  inventory[1].maxSize,inventory[2].maxSize=64,64
  local runtime={sides={down=0},event={pull=function()end},robot={inventorySize=function()return 2 end,select=function(slot)selected=slot;return slot end,swing=function()inventory[2].size=inventory[2].size+1;installed=nil;return true end,place=function()if selected==1 then return nil,"jam"end installed=inventory[selected].name;return true end},component={modem={open=function()end},inventory_controller={getStackInInternalSlot=function(slot)return inventory[slot]end},geolyzer={analyze=function()return installed and{name=installed}or nil end}}}
  local service=new_service({peer_address="controller",local_address="robot",auth=auth,restore_attempts=2,block_items={dirt="dirt",stone="stone"}},runtime);local ok,detail=service:replace("dirt");H.falsy(ok);H.contains(detail,"restored");H.equal(installed,"stone")
end)
H.test("foundation once mode propagates the handled replacement failure",function()
  local payload=assert(epoch_encode("request","once","nonce","missing",nil,auth));local delivered=false
  local runtime={sides={down=0},event={pull=function()if delivered then return end;delivered=true;return"modem_message","robot","controller",24193,0,payload end},robot={inventorySize=function()return 1 end,select=function(slot)return slot end,swing=function()return true end,place=function()return true end},component={modem={open=function()end,send=function()return true end},inventory_controller={getStackInInternalSlot=function()return nil end},geolyzer={analyze=function()return{name="stone"}end}}}
  local service=new_service({peer_address="controller",local_address="robot",auth=auth,block_items={missing="missing",stone="stone"}},runtime);local ok,err=service:run(true)
  H.falsy(ok);H.contains(err,"not in robot inventory")
end)
H.test("robot configuration rejects malformed port and side values",function()
  local function run(config)return RobotMain.run({}, {load_config=function()return config end,runtime={},auth=auth})end
  local ok,err=run({controller_address="controller",modem_address="robot",port="abc",side=0});H.falsy(ok);H.contains(err,"port")
  ok,err=run({controller_address="controller",modem_address="robot",port=24193,side="down"});H.falsy(ok);H.contains(err,"side")
end)

H.test("rollback failure is propagated and recovery artifacts remain",function()
  local fs,files=memory_fs({["/a"]="old-a",["/b"]="old-b"},function(source,destination)return(destination=="/b"and source:find("stage",1,true))or(destination=="/a"and source:find("backup",1,true))end)
  local ok,err=Transaction.install({fs=fs,root="/",manifest={{url="a",path="a"},{url="b",path="b"}},now=function()return 7 end,fetch=function(url,path)files[path]="new"..url;return true end})
  H.falsy(ok);H.contains(err,"rollback incomplete");H.contains(err,"/a");H.truthy(files["/.gtnh-bees-install.journal"]);H.truthy(files["/.gtnh-bees-backup-7/a"])
end)

local function digest_stub(text)return text end
H.test("low-level installer enforces a connection deadline",function()
  local now=0;local request={finishConnect=function()return false end,close=function()end};local runtime={internet={request=function()return request end},computer={uptime=function()return now end,pullSignal=function()now=now+0.1 end},data={sha256=digest_stub},open=function()error("must not open")end}
  local fetch=Installer.fetcher(runtime,{connect=0.2,overall=1,file=1,read=1});local ok,err=fetch("u","d",{size=1,sha256="00"});H.falsy(ok);H.contains(err,"connection deadline")
end)
H.test("low-level installer rejects flush failure",function()
  local now=0;local reads={"x",nil};local request={finishConnect=function()return true end,response=function()return 200,"OK"end,read=function()local v=table.remove(reads,1);return v end,close=function()end}
  local runtime={internet={request=function()return request end},computer={uptime=function()return now end,pullSignal=function()now=now+0.1 end},data={sha256=function()return"x"end},open=function()return{write=function()return true end,flush=function()return nil,"disk full"end,close=function()return true end}end}
  local fetch=Installer.fetcher(runtime,{});local ok,err=fetch("u","d",{size=1,sha256="78"});H.falsy(ok);H.contains(err,"flush")
end)
H.test("low-level installer rejects a pinned digest mismatch",function()
  local reads={"x",nil};local request={finishConnect=function()return true end,response=function()return 200,"OK"end,read=function()return table.remove(reads,1)end,close=function()end}
  local runtime={internet={request=function()return request end},computer={uptime=function()return 0 end,pullSignal=function()end},data={sha256=function()return"x"end},open=function()return{write=function()return true end,flush=function()return true end,close=function()return true end}end}
  local ok,err=Installer.fetcher(runtime,{})("u","d",{size=1,sha256="00"});H.falsy(ok);H.contains(err,"SHA-256")
end)
H.test("release manifest pins size and SHA-256 for every file",function()
  for _,entry in ipairs(Manifest.computer("https://release/"))do H.truthy(entry.size>0);H.truthy(entry.sha256:match("^[0-9a-f]+$")and#entry.sha256==64)end
  for _,entry in ipairs(Manifest.robot("https://release/"))do H.truthy(entry.size>0);H.truthy(entry.sha256:match("^[0-9a-f]+$")and#entry.sha256==64)end
end)
