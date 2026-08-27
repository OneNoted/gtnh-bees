local Protocol=require("gtnh_bees.foundation")
local Calls=require("gtnh_bees.component_call")
local util=require("gtnh_bees.util")
local Service={};Service.__index=Service
local JOURNAL_HEADER="gtnh-bees.foundation.replay.v2"
local ANCHOR_HEADER="gtnh-bees.foundation.epoch.v1"

local function defaults()
  return {component=require("component"),robot=require("robot"),event=require("event"),sides=require("sides"),filesystem=require("filesystem"),open=io.open}
end
local function hex(value)
  return (tostring(value or ""):gsub(".",function(c)return string.format("%02x",string.byte(c))end))
end
local function unhex(value)
  if type(value)~="string"or #value%2~=0 or value:find("[^0-9a-f]")then return nil end
  return (value:gsub("..",function(pair)return string.char(tonumber(pair,16))end))
end
local function same(a,b)
  if type(a)~="string"or type(b)~="string"or #a~=#b then return false end
  local different=0
  for index=1,#a do different=different+(string.byte(a,index)~=string.byte(b,index)and 1 or 0)end
  return different==0
end
local function fs_exists(fs,path)
  local ok,value=pcall(fs.exists,path)
  if not ok then return nil,tostring(value)end
  return value==true
end

local function authenticated_body(data,prefix,header,auth,label)
  if type(data)~="string"then return nil,label.." is not text"end
  local body,mac=data:match("^(.*\n)mac|([0-9a-f]+)\n$")
  if not body then return nil,label.." is malformed or corrupt"end
  local auth_ok,expected=pcall(auth,prefix.."|"..body)
  if not auth_ok or type(expected)~="string"or not same(mac,expected)then return nil,label.." authentication failed; state is malformed or corrupt"end
  local epoch_hex=body:match("^"..header:gsub("([^%w])","%%%1").."|([0-9a-f]+)\n")
  local epoch=unhex(epoch_hex)
  if not epoch or not Protocol.valid_epoch(epoch)then return nil,label.." epoch is malformed"end
  return body,epoch
end

local function read_all(open,path,label)
  local handle,open_err=open(path,"r")
  if not handle then return nil,"cannot open "..label..": "..tostring(open_err)end
  local ok,data,read_err=pcall(handle.read,handle,"*a")
  local closed,close_err=pcall(handle.close,handle)
  if not ok or type(data)~="string"then return nil,"cannot read "..label..": "..tostring(read_err or data)end
  if not closed then return nil,"cannot close "..label.." after reading: "..tostring(close_err)end
  return data
end

local function atomic_write(fs,open,path,temporary,data,label)
  local exists,exists_err=fs_exists(fs,temporary)
  if exists==nil then return nil,"cannot inspect "..label.." temporary file: "..exists_err end
  if exists then return nil,label.." temporary replacement already exists; supervised reconciliation required"end
  local handle,open_err=open(temporary,"w")
  if not handle then return nil,"cannot open "..label.." temporary file: "..tostring(open_err)end
  local wrote,write_result,write_err=pcall(handle.write,handle,data)
  if not wrote or not write_result then pcall(handle.close,handle);return nil,"cannot write "..label.." temporary file: "..tostring(write_err or write_result)end
  if type(handle.flush)~="function"then pcall(handle.close,handle);return nil,label.." handle has no explicit flush"end
  local flushed,flush_result,flush_err=pcall(handle.flush,handle)
  if not flushed or not flush_result then pcall(handle.close,handle);return nil,"cannot flush "..label.." temporary file: "..tostring(flush_err or flush_result)end
  local close_ok,closed,close_err=pcall(handle.close,handle)
  if not close_ok or closed==false or(closed==nil and close_err~=nil)then return nil,"cannot close "..label.." temporary file: "..tostring(close_err or closed)end
  local renamed,rename_result,rename_err=pcall(fs.rename,temporary,path)
  if not renamed or not rename_result then return nil,"cannot atomically replace "..label..": "..tostring(rename_err or rename_result)end
  return true
end

local function anchor_data(epoch,auth)
  local body=ANCHOR_HEADER.."|"..hex(epoch).."\n"
  local ok,mac,err=pcall(auth,"anchor|"..body)
  if not ok or type(mac)~="string"or mac==""or mac:find("|",1,true)then return nil,"cannot authenticate replay epoch anchor: "..tostring(err or mac)end
  return body.."mac|"..mac.."\n"
end

local function read_anchor(open,path,auth,label)
  local data,read_err=read_all(open,path,label);if not data then return nil,read_err end
  local body,epoch=authenticated_body(data,"anchor",ANCHOR_HEADER,auth,label)
  if not body then return nil,epoch end
  if body~=ANCHOR_HEADER.."|"..hex(epoch).."\n"then return nil,label.." contains malformed trailing data"end
  return epoch
end

local Journal={};Journal.__index=Journal
function Journal.empty(options)
  return setmetatable({path=options.path,temporary=options.path..".tmp",anchor=options.path..".epoch",anchor_temporary=options.path..".epoch.tmp",epoch=options.epoch,fs=options.fs,open=options.open,auth=options.auth,max=options.max,entries={},by_id={},by_nonce={},blocked=false,failed=nil},Journal)
end
function Journal:load()
  local data,read_err=read_all(self.open,self.path,"replay journal");if not data then return nil,read_err end
  local body,epoch=authenticated_body(data,"journal",JOURNAL_HEADER,self.auth,"replay journal")
  if not body then return nil,epoch end
  if epoch~=self.epoch then return nil,"replay journal epoch does not match the configured epoch"end
  local header=JOURNAL_HEADER.."|"..hex(epoch).."\n"
  local remainder=body:sub(#header+1)
  for line in remainder:gmatch("([^\n]+)\n")do
    local state,id_hex,nonce_hex,block_hex,request_detail_hex,kind_hex,detail_hex=line:match("^entry|([^|]+)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
    local id,nonce,block,request_detail,kind,detail=unhex(id_hex),unhex(nonce_hex),unhex(block_hex),unhex(request_detail_hex),unhex(kind_hex),unhex(detail_hex)
    if(state~="pending"and state~="final")or not id or id==""or not nonce or nonce==""or not block or not request_detail or not kind or not detail then return nil,"replay journal entry is malformed or corrupt"end
    if state=="pending"and(kind~=""or detail~="")then return nil,"replay journal pending entry is malformed"end
    if state=="final"and(kind~="ok"and kind~="error")then return nil,"replay journal final entry is malformed"end
    if self.by_id[id]or self.by_nonce[nonce]then return nil,"replay journal contains duplicate request identity"end
    local entry={state=state,id=id,nonce=nonce,block=block~=""and block or nil,request_detail=request_detail~=""and request_detail or nil,kind=kind~=""and kind or nil,detail=detail~=""and detail or nil}
    self.entries[#self.entries+1]=entry;self.by_id[id]=entry;self.by_nonce[nonce]=entry
    if state=="pending"then self.blocked=true end
    if #self.entries>self.max then return nil,"replay journal exceeds configured entry bound"end
  end
  local rebuilt=header
  for _,entry in ipairs(self.entries)do rebuilt=rebuilt..table.concat({"entry",entry.state,hex(entry.id),hex(entry.nonce),hex(entry.block),hex(entry.request_detail),hex(entry.kind),hex(entry.detail)},"|").."\n"end
  if rebuilt~=body then return nil,"replay journal contains malformed trailing data"end
  return true
end
function Journal:serialize()
  local lines={JOURNAL_HEADER.."|"..hex(self.epoch)}
  for _,entry in ipairs(self.entries)do lines[#lines+1]=table.concat({"entry",entry.state,hex(entry.id),hex(entry.nonce),hex(entry.block),hex(entry.request_detail),hex(entry.kind),hex(entry.detail)},"|")end
  local body=table.concat(lines,"\n").."\n"
  local ok,mac,err=pcall(self.auth,"journal|"..body)
  if not ok or type(mac)~="string"or mac==""or mac:find("|",1,true)then return nil,"cannot authenticate replay journal: "..tostring(err or mac)end
  return body.."mac|"..mac.."\n"
end
function Journal:persist()
  if self.failed then return nil,self.failed end
  local data,serialize_err=self:serialize();if not data then self.failed=serialize_err;return nil,serialize_err end
  local ok,err=atomic_write(self.fs,self.open,self.path,self.temporary,data,"replay journal")
  if not ok then self.failed=err;return nil,err end
  return true
end

local function advance_anchor(journal)
  local data,data_err=anchor_data(journal.epoch,journal.auth);if not data then return nil,data_err end
  return atomic_write(journal.fs,journal.open,journal.anchor,journal.anchor_temporary,data,"replay epoch anchor")
end

function Journal.new(options)
  if type(options.path)~="string"or options.path==""then return nil,"durable replay journal path is required"end
  if not Protocol.valid_epoch(options.epoch)then return nil,"configured replay epoch must contain at least 16 bytes and no '|'"end
  if not util.finite_integer(options.max,1,1024)then return nil,"replay journal entry bound must be a finite integer from 1 through 1024"end
  if type(options.fs)~="table"or not Calls.callable(options.fs.exists)or not Calls.callable(options.fs.rename)or type(options.open)~="function"then return nil,"durable replay journal filesystem is unavailable"end
  local self=Journal.empty(options)
  local journal_tmp,tmp_err=fs_exists(self.fs,self.temporary)
  if journal_tmp==nil then return nil,"cannot inspect replay journal temporary file: "..tmp_err end
  if journal_tmp then return nil,"replay journal has an interrupted temporary replacement; supervised reconciliation required"end
  local journal_exists,journal_err=fs_exists(self.fs,self.path)
  if journal_exists==nil then return nil,"cannot inspect replay journal: "..journal_err end
  local anchor_exists,anchor_err=fs_exists(self.fs,self.anchor)
  if anchor_exists==nil then return nil,"cannot inspect replay epoch anchor: "..anchor_err end
  local anchor_tmp,anchor_tmp_err=fs_exists(self.fs,self.anchor_temporary)
  if anchor_tmp==nil then return nil,"cannot inspect replay epoch anchor temporary file: "..anchor_tmp_err end

  if not anchor_exists then
    if journal_exists then return nil,"replay epoch anchor is missing while a journal exists; supervised reconciliation required"end
    if anchor_tmp then return nil,"replay epoch anchor initialization is interrupted; supervised reconciliation required"end
    local created,create_err=self:persist();if not created then return nil,"cannot initialize authenticated empty replay journal: "..create_err end
    local anchored,anchor_write_err=advance_anchor(self);if not anchored then return nil,"empty replay journal was created but epoch anchor advance failed: "..anchor_write_err end
    return self
  end

  local anchor_epoch,read_anchor_err=read_anchor(self.open,self.anchor,self.auth,"replay epoch anchor")
  if not anchor_epoch then return nil,read_anchor_err end
  if anchor_tmp then
    if not journal_exists then return nil,"replay epoch anchor replacement exists without a journal; supervised reconciliation required"end
    local temporary_epoch,temp_anchor_err=read_anchor(self.open,self.anchor_temporary,self.auth,"replay epoch anchor temporary file")
    if not temporary_epoch then return nil,temp_anchor_err end
    local loaded,load_err=self:load();if not loaded then return nil,load_err end
    if temporary_epoch~=self.epoch or anchor_epoch==self.epoch or #self.entries~=0 then return nil,"replay epoch anchor replacement is inconsistent; supervised reconciliation required"end
    local renamed,rename_result,rename_err=pcall(self.fs.rename,self.anchor_temporary,self.anchor)
    if not renamed or not rename_result then return nil,"cannot finish interrupted replay epoch anchor advance: "..tostring(rename_err or rename_result)end
    return self
  end

  if anchor_epoch==self.epoch then
    if not journal_exists then return nil,"active replay journal disappeared while the durable epoch anchor still names the configured epoch"end
    local loaded,load_err=self:load();if not loaded then return nil,load_err end
    return self
  end

  if journal_exists then
    local loaded,load_err=self:load()
    if not loaded then return nil,"configured replay epoch changed but the old or inconsistent journal remains; archive/remove the full old journal before rotation: "..tostring(load_err)end
    if #self.entries~=0 then return nil,"interrupted replay rotation produced a nonempty new journal; supervised reconciliation required"end
    local anchored,advance_err=advance_anchor(self);if not anchored then return nil,"cannot finish interrupted replay epoch anchor advance: "..advance_err end
    return self
  end

  local created,create_err=self:persist();if not created then return nil,"cannot create authenticated empty journal for the new replay epoch: "..create_err end
  local anchored,advance_err=advance_anchor(self);if not anchored then return nil,"new replay journal was created but epoch anchor advance failed: "..advance_err end
  return self
end
function Journal:accept(request)
  if self.failed then return nil,self.failed end
  if self.blocked then return nil,"replay journal contains a pending physical action; supervised reconciliation required"end
  if #self.entries>=self.max then return nil,"replay journal is full; supervised rotation is required"end
  local entry={state="pending",id=request.id,nonce=request.nonce,block=request.block,request_detail=request.detail}
  self.entries[#self.entries+1]=entry;self.by_id[entry.id]=entry;self.by_nonce[entry.nonce]=entry
  local ok,err=self:persist()
  if not ok then self.entries[#self.entries]=nil;self.by_id[entry.id]=nil;self.by_nonce[entry.nonce]=nil;return nil,err end
  return entry
end
function Journal:finish(entry,kind,detail)
  entry.state,entry.kind,entry.detail="final",kind,detail
  local ok,err=self:persist()
  if not ok then entry.state,entry.kind,entry.detail="pending",nil,nil;self.blocked=true;return nil,err end
  return true
end

local function open_port(modem,port)
  local ok,opened,open_err=pcall(modem.open,port)
  if not ok then return nil,"foundation modem could not open port "..port..": "..tostring(opened)end
  if opened==false then
    if not Calls.callable(modem.isOpen)then return nil,"foundation modem could not open port "..port..": "..tostring(open_err)end
    local checked,is_open=pcall(modem.isOpen,port)
    if not checked or is_open~=true then return nil,"foundation modem could not open port "..port..": "..tostring(open_err)end
  end
  return true
end

function Service.new(options,runtime)
  options,runtime=options or{},runtime or defaults()
  local component=runtime.component
  assert(type(options.peer_address)=="string"and options.peer_address~="","foundation controller modem address is required")
  assert(type(options.local_address)=="string"and options.local_address~="","foundation robot modem address is required")
  assert(type(options.auth)=="function","foundation authenticator is required")
  assert(Protocol.valid_epoch(options.epoch),"foundation replay epoch must contain at least 16 bytes and no '|'")
  local port=options.port or Protocol.port
  local side=options.side
  if side==nil then side=runtime.sides.down end
  local max_cache=options.max_cache or 64
  local restore_attempts=options.restore_attempts or 2
  if not util.finite_integer(port,1,65535)then return nil,"foundation robot port must be a finite integer from 1 through 65535"end
  if not util.finite_integer(side,0,5)then return nil,"foundation robot side must be a finite integer from 0 through 5"end
  if not util.finite_integer(max_cache,1,1024)then return nil,"foundation replay maximum must be a finite integer from 1 through 1024"end
  if not util.finite_integer(restore_attempts,1)then return nil,"foundation restore attempts must be a finite positive integer"end
  local journal,journal_err=Journal.new({path=options.journal_path,epoch=options.epoch,fs=runtime.filesystem,open=runtime.open or io.open,auth=options.auth,max=max_cache})
  if not journal then return nil,journal_err end
  local self=setmetatable({component=component,robot=runtime.robot,event=runtime.event,modem=assert(component.modem,"a modem is required"),inventory=assert(component.inventory_controller,"an inventory controller upgrade is required"),geolyzer=assert(component.geolyzer,"a geolyzer is required"),side=side,port=port,peer=options.peer_address,local_address=options.local_address,auth=options.auth,epoch=options.epoch,journal=journal,block_items=options.block_items or{},restore_attempts=restore_attempts},Service)
  local opened,open_err=open_port(self.modem,self.port);if not opened then return nil,open_err end
  return self
end

function Service:installed_block()
  local ok,data=pcall(self.geolyzer.analyze,self.side)
  if not ok or type(data)~="table"or type(data.name)~="string"then return nil,"cannot identify the installed foundation" end
  return data.name
end
function Service:inventory_snapshot(item)
  local size_ok,size=pcall(self.robot.inventorySize)
  if not size_ok or not util.finite_integer(size,1)then return nil,"cannot determine finite robot inventory size"end
  local snapshot={counts={},stacks={},size=size}
  for slot=1,size do
    local ok,stack=pcall(self.inventory.getStackInInternalSlot,slot)
    if not ok then return nil,"cannot inspect robot inventory slot "..slot end
    if stack~=nil and(type(stack)~="table"or type(stack.name)~="string"or not util.finite_integer(stack.size,1)or(stack.maxSize~=nil and not util.finite_integer(stack.maxSize,stack.size)))then return nil,"robot inventory slot "..slot.." returned malformed finite stack data"end
    snapshot.stacks[slot]=stack or false
    snapshot.counts[slot]=stack and stack.name==item and stack.size or 0
  end
  return snapshot
end
function Service:replacement_slot(item,snapshot)
  snapshot=snapshot or self:inventory_snapshot(item)
  if not snapshot then return nil,"cannot inspect replacement inventory"end
  for slot=1,snapshot.size do if snapshot.counts[slot]>0 then return slot end end
  return nil,"replacement item '"..item.."' is not in robot inventory"
end
function Service:retention_available(item,snapshot)
  for slot=1,snapshot.size do
    local stack=snapshot.stacks[slot]
    if stack==false then return true end
    if stack.name==item and util.finite_integer(stack.maxSize,stack.size)and stack.size<stack.maxSize then return true end
  end
  return nil,"robot inventory has no proven capacity for displaced item '"..item.."'"
end
function Service:retention_proof(item,before)
  local after,after_err=self:inventory_snapshot(item);if not after then return nil,after_err end
  local gained,total={},0
  for slot=1,after.size do
    local delta=after.counts[slot]-(before.counts[slot]or 0)
    if delta>0 then
      gained[#gained+1]={slot=slot,count=after.counts[slot],increase=delta};total=total+delta
      if not util.finite_integer(total,0)then return nil,"displaced-item retention count is not a finite integer"end
    end
  end
  if total<1 then return nil,"displaced item '"..item.."' did not increase in robot inventory"end
  return gained
end
local function locations(snapshot)
  local found={}
  for slot=1,snapshot.size do if snapshot.counts[slot]>0 then found[#found+1]="slot "..slot.." count "..snapshot.counts[slot]end end
  return #found>0 and table.concat(found,", ")or"none observed"
end
local function robot_call(robot,name,...)
  local action=robot[name]
  if not Calls.callable(action)then return nil,"robot "..name.." is unavailable"end
  local called,result,detail=pcall(action,...)
  if not called then return nil,"robot "..name.." raised: "..tostring(result)end
  return result,detail
end
local function robot_select(robot,slot)
  local selected,detail=robot_call(robot,"select",slot)
  if selected~=slot then return nil,"robot select failed: "..tostring(detail or selected)end
  return true
end
local function robot_action(robot,name,...)
  local result,detail=robot_call(robot,name,...)
  if result~=true then return nil,"robot "..name.." failed: "..tostring(detail or result)end
  return true
end
function Service:residual(original,item,cause)
  local observed,observe_err=self:installed_block();local snapshot,snapshot_err=self:inventory_snapshot(item)
  return cause.."; observed foundation="..tostring(observed or("unknown ("..tostring(observe_err)..")")).."; expected displaced item '"..item.."' inventory="..(snapshot and locations(snapshot)or("unknown ("..tostring(snapshot_err)..")"))
end
function Service:restore(original,item,cause)
  local restore_detail
  for _=1,self.restore_attempts do
    local observed=self:installed_block()
    if observed==original then return nil,self:residual(original,item,cause.."; original foundation was restored")end
    if observed==nil or observed=="minecraft:air"then
      local snapshot=self:inventory_snapshot(item)
      local slot=snapshot and self:replacement_slot(item,snapshot)
      if slot then
        local selected,select_err=robot_select(self.robot,slot)
        if selected then
          local placed,place_err=robot_action(self.robot,"place",self.side)
          if not placed then restore_detail=place_err end
        else
          restore_detail=select_err
        end
      end
      local after=self:installed_block();if after==original then return nil,self:residual(original,item,cause.."; original foundation was restored")end
    else
      return nil,self:residual(original,item,cause.."; restoration refused to break unexpected foundation '"..observed.."'")
    end
  end
  local detail=restore_detail and("; last restoration callback failure: "..restore_detail)or""
  return nil,self:residual(original,item,cause.."; bounded restoration failed"..detail)
end
function Service:replace(block)
  local current,current_err=self:installed_block();if not current then return nil,current_err end
  if current==block then return true,"requested foundation is already installed"end
  local requested_item=self.block_items[block]
  if type(requested_item)~="string"or requested_item==""then return nil,"no exact configured inventory item mapping for requested foundation '"..block.."'; existing foundation was not broken"end
  local displaced_item=self.block_items[current]
  if type(displaced_item)~="string"or displaced_item==""then return nil,"no exact configured dropped-item mapping for displaced foundation '"..current.."'; existing foundation was not broken"end
  local before,before_err=self:inventory_snapshot(displaced_item);if not before then return nil,before_err.."; existing foundation was not broken"end
  local slot,slot_err=self:replacement_slot(requested_item);if not slot then return nil,slot_err.."; existing foundation was not broken"end
  local retained,retention_err=self:retention_available(displaced_item,before);if not retained then return nil,retention_err.."; existing foundation was not broken"end
  local selected,select_err=robot_select(self.robot,slot);if not selected then return nil,"replacement item slot could not be selected: "..tostring(select_err).."; existing foundation was not broken"end
  local broken,break_err=robot_action(self.robot,"swing",self.side);if not broken then return self:restore(current,displaced_item,"existing foundation removal was physically uncertain: "..tostring(break_err))end
  local proof,proof_err=self:retention_proof(displaced_item,before)
  if not proof then return self:restore(current,displaced_item,"displaced-block retention could not be proved: "..tostring(proof_err))end
  local replacement_after,after_err=self:inventory_snapshot(requested_item)
  if not replacement_after then return self:restore(current,displaced_item,"replacement inventory could not be inspected after removal: "..tostring(after_err))end
  local replacement_slot,replacement_err=self:replacement_slot(requested_item,replacement_after)
  if not replacement_slot then return self:restore(current,displaced_item,replacement_err)end
  selected,select_err=robot_select(self.robot,replacement_slot);if not selected then return self:restore(current,displaced_item,"replacement item slot could not be selected: "..tostring(select_err))end
  local placed,place_err=robot_action(self.robot,"place",self.side)
  if not placed then return self:restore(current,displaced_item,"replacement could not be placed: "..tostring(place_err)) end
  local observed,observe_err=self:installed_block()
  if not observed then return self:restore(current,displaced_item,"replacement placement could not be confirmed: "..tostring(observe_err)) end
  if observed~=block then return self:restore(current,displaced_item,"foundation confirmation saw '"..observed.."' instead of '"..block.."'") end
  local evidence={}
  for _,gain in ipairs(proof)do evidence[#evidence+1]="slot "..gain.slot.." count "..gain.count.." (+"..gain.increase..")"end
  return true,"foundation replaced; displaced item '"..displaced_item.."' retained at "..table.concat(evidence,", ")
end

function Service:send(remote,request,kind,detail)
  local payload,encode_err=Protocol.encode(kind,self.epoch,request.id,request.nonce,request.block,detail,self.auth);if not payload then return nil,encode_err end
  local called,sent,err=pcall(self.modem.send,remote,self.port,payload)
  if not called then return nil,"modem reply transiently failed: "..tostring(sent)end
  if sent~=true then return nil,"modem reply transiently failed: "..tostring(err or sent)end
  return true
end
function Service:collision(remote,request,detail)
  local sent,send_err=self:send(remote,request,"error",detail);if not sent then return nil,send_err end
  return nil,detail
end
function Service:handle(remote,raw,local_address)
  if remote~=self.peer or(local_address and local_address~=self.local_address)then return nil,"foundation sender or local modem address is not paired"end
  local request,decode_err=Protocol.decode(raw,self.auth,self.epoch);if not request or request.kind~="request"then return nil,decode_err or"not a request"end
  local cached=self.journal.by_id[request.id]
  if cached then
    if cached.block~=request.block or cached.nonce~=request.nonce or cached.request_detail~=request.detail then return self:collision(remote,request,"request ID was reused with different authenticated content")end
    if cached.state=="pending"then return self:collision(remote,request,"request is pending from an interrupted physical action; supervised reconciliation required")end
    local sent,send_err=self:send(remote,request,cached.kind,cached.detail);if not sent then return nil,send_err end
    return cached.kind=="ok"and true or nil,cached.detail
  end
  local nonce_owner=self.journal.by_nonce[request.nonce]
  if nonce_owner then return self:collision(remote,request,"request nonce was reused under another request ID")end
  if self.journal.blocked then return self:collision(remote,request,"replay journal contains a pending physical action; supervised reconciliation required")end
  local entry,accept_err=self.journal:accept(request)
  if not entry then return self:collision(remote,request,accept_err)end
  local ok,detail
  if not request.block then ok,detail=nil,"request omitted a block identifier"else ok,detail=self:replace(request.block)end
  local kind=ok and"ok"or"error"
  local finished,finish_err=self.journal:finish(entry,kind,detail)
  if not finished then return nil,"foundation outcome could not be persisted before reply: "..tostring(finish_err)end
  local sent,send_err=self:send(remote,request,kind,detail);if not sent then return nil,send_err end
  return ok,detail
end
function Service:run(once)
  repeat
    local signal={self.event.pull(1,"modem_message")}
    if #signal>0 then
      local local_address,remote,port,raw=signal[2],signal[3],signal[4],signal[6]
      if port==self.port and local_address==self.local_address and remote==self.peer then
        local ok,detail=self:handle(remote,raw,local_address)
        if once then return ok,detail end
      end
    elseif once then return nil,"no authenticated foundation request arrived during the supervised wait"end
  until false
end
return Service
