local bounded=require("gtnh_bees.bounded")
local Calls=require("gtnh_bees.component_call")
local util=require("gtnh_bees.util")
local M={port=24193,version="gtnh-bees.foundation.v3"}

local function field(value)
  value=tostring(value or "")
  if value=="" or value:find("|",1,true) then return nil end
  return value
end
local function valid_epoch(value)
  return type(value)=="string"and #value>=16 and not value:find("|",1,true)
end
local function finite_positive(value)
  return type(value)=="number"and value==value and value~=math.huge and value~=-math.huge and value>0
end
local function hex(value)return (tostring(value):gsub(".",function(c)return string.format("%02x",string.byte(c))end))end
local function equal(a,b)if type(a)~="string"or type(b)~="string"or #a~=#b then return false end local n=0 for i=1,#a do n=n+(string.byte(a,i)~=string.byte(b,i) and 1 or 0)end return n==0 end

function M.valid_epoch(value)return valid_epoch(value)end

function M.data_auth(data,secret)
  if type(secret)~="string"or #secret<16 then return nil,"foundation shared secret must contain at least 16 bytes" end
  if not data or not Calls.callable(data.sha256) then return nil,"a tier-2-or-better data card with HMAC-SHA256 is required" end
  return function(payload)
    local ok,digest=pcall(data.sha256,payload,secret)
    if not ok or type(digest)~="string"then return nil,"foundation authentication failed" end
    return hex(digest)
  end
end

function M.encode(kind,epoch,id,nonce,block,detail,auth)
  kind,id,nonce=field(kind),field(id),field(nonce)
  if block~=nil then block=field(block) else block="-" end
  detail=detail and tostring(detail):gsub("|","/") or "-"
  if not valid_epoch(epoch)then return nil,"foundation replay epoch must contain at least 16 bytes and no '|'"end
  if not kind or not id or not nonce or not block or type(auth)~="function"then return nil,"invalid foundation message field" end
  local body=table.concat({M.version,epoch,kind,id,nonce,block,detail},"|")
  local mac,err=auth(body);if type(mac)~="string"or mac==""or mac:find("|",1,true)then return nil,err or "foundation authenticator failed" end
  return body.."|"..mac
end

function M.decode(message,auth,expected_epoch)
  if not valid_epoch(expected_epoch)then return nil,"foundation replay epoch is not configured"end
  if type(message)~="string"then return nil,"foundation message is not text" end
  local version,epoch,kind,id,nonce,block,detail,mac=message:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]*)|([^|]+)$")
  if version~=M.version then return nil,"unsupported foundation protocol" end
  if epoch~=expected_epoch then return nil,"foundation replay epoch does not match the configured epoch"end
  if kind~="request"and kind~="ok"and kind~="error"then return nil,"invalid foundation message kind" end
  if type(auth)~="function"then return nil,"foundation authentication is not configured" end
  local body=table.concat({version,epoch,kind,id,nonce,block,detail},"|")
  local expected=auth(body)
  if not equal(mac,expected)then return nil,"foundation message authentication failed" end
  return {epoch=epoch,kind=kind,id=id,nonce=nonce,block=block~="-"and block or nil,detail=detail~="-"and detail or nil}
end

local Controller={};Controller.__index=Controller
function Controller.new(modem,event,options)
  options=options or {}
  assert(type(options.peer_address)=="string"and options.peer_address~="","foundation robot modem address is required")
  assert(type(options.local_address)=="string"and options.local_address~="","foundation controller modem address is required")
  assert(type(options.auth)=="function","foundation authenticator is required")
  assert(type(options.nonce)=="function","replay-resistant nonce source is required")
  assert(valid_epoch(options.epoch),"foundation replay epoch must contain at least 16 bytes and no '|'")
  local port=options.port or M.port
  local attempts=options.attempts or 3
  local timeout=options.timeout or 8
  assert(util.finite_integer(port,1,65535),"foundation port must be a finite integer from 1 through 65535")
  assert(util.finite_integer(attempts,1),"foundation attempts must be a finite positive integer")
  assert(finite_positive(timeout),"foundation timeout must be finite and positive")
  local poll_limit=math.ceil(timeout*4)
  assert(util.finite_integer(poll_limit,1),"foundation timeout produces a non-finite poll budget")
  return setmetatable({modem=modem,event=event,port=port,attempts=attempts,timeout=timeout,poll_limit=poll_limit,clock=options.clock or os.time,peer=options.peer_address,local_address=options.local_address,auth=options.auth,nonce=options.nonce,epoch=options.epoch,port_open=false},Controller)
end
function Controller:ensure_port()
  if self.port_open then return true end
  local ok,opened,open_err=pcall(self.modem.open,self.port)
  if not ok then return nil,"foundation modem could not open port "..self.port..": "..tostring(opened)end
  if opened==false then
    if not Calls.callable(self.modem.isOpen)then return nil,"foundation modem could not open port "..self.port..": "..tostring(open_err)end
    local checked,is_open=pcall(self.modem.isOpen,self.port)
    if not checked or is_open~=true then return nil,"foundation modem could not open port "..self.port..": "..tostring(open_err)end
  end
  self.port_open=true
  return true
end
function Controller:request(block)
  if not field(block)then return nil,"foundation block identifier is invalid" end
  local generated,nonce,nonce_err=pcall(self.nonce)
  if not generated then return nil,"foundation nonce generation failed: "..tostring(nonce),"transient" end
  nonce=field(nonce);if not nonce then return nil,"foundation nonce generation failed: "..tostring(nonce_err or "invalid random bytes"),"transient" end
  local id=tostring(self.clock()).."."..nonce
  local payload,encode_err=M.encode("request",self.epoch,id,nonce,block,nil,self.auth);if not payload then return nil,encode_err end
  local opened,open_err=self:ensure_port();if not opened then return nil,open_err,"transient" end
  for attempt=1,self.attempts do
    local called,sent,send_err=pcall(self.modem.send,self.peer,self.port,payload)
    if not called then return nil,"foundation request send failed: "..tostring(sent),"transient"end
    if sent~=true then return nil,"foundation request send failed: "..tostring(send_err or sent),"transient"end
    local answer,err=bounded.poll({limit=self.poll_limit,interval=0.25,accept=function(v)return v~=nil end,timeout_message="foundation robot did not reply"},function()
      local signal={self.event.pull(0.25,"modem_message")};if #signal==0 then return nil end
      if signal[2]~=self.local_address or signal[3]~=self.peer or signal[4]~=self.port then return nil end
      local decoded=M.decode(signal[6],self.auth,self.epoch)
      if decoded and decoded.id==id and decoded.nonce==nonce then return decoded end
    end)
    if answer then
      if answer.block~=block then return nil,"foundation reply named a different requested block" end
      if answer.kind=="ok"then return true,answer.detail end
      return nil,answer.detail or "foundation robot rejected the request"
    end
    if err and attempt==self.attempts then return nil,err,"transient" end
  end
  return nil,"foundation robot request exhausted its retry budget","transient"
end
M.Controller=Controller
return M
