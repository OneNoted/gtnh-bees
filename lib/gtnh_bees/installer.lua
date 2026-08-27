local Calls=require("gtnh_bees.component_call")
local Transaction=require("gtnh_bees.transaction")
local Manifest=require("gtnh_bees.install_manifest")
local M={}
local function fs_wrapper(filesystem)return {exists=filesystem.exists,isDirectory=filesystem.isDirectory,rename=filesystem.rename,remove=filesystem.remove,makeDirectory=filesystem.makeDirectory,open=io.open}end
local function call(object,method,...)
  local member=object and object[method]
  if not Calls.callable(member)then return nil,"request handle lacks '"..method.."'"end
  local ok,a,b,c=pcall(member,...);if not ok then return nil,tostring(a)end return a,b,c
end
local function hex(value)return(tostring(value):gsub(".",function(c)return string.format("%02x",string.byte(c))end))end
local function close(handle)if handle then pcall(function()handle.close()end)end end
local function valid_count(value)return type(value)=="number"and value>=0 and value<math.huge and value%1==0 end
local function checked_file_close(handle,label)
  local called,closed,close_err=pcall(function()return handle:close()end)
  if not called then return nil,label.." close failed: "..tostring(closed)end
  if closed==nil or closed==false then return nil,label.." close failed: "..tostring(close_err)end
  return true
end
local function verify_staged(runtime,destination,item,limits)
  local opened,handle,open_err=pcall(runtime.open,destination,"rb")
  if not opened then return nil,"cannot reopen staged file "..destination..": "..tostring(handle)end
  if not handle then return nil,"cannot reopen staged file "..destination..": "..tostring(open_err)end
  local inspected,member=pcall(function()return handle.read end)
  if not inspected or not Calls.callable(member)then
    local _,close_err=checked_file_close(handle,"staged verification")
    local read_err=not inspected and("staged file read failed for "..destination..": "..tostring(member))or"staged SHA-256 verification handle lacks read"
    return nil,read_err..(close_err and"; "..close_err or"")
  end
  local chunk_size=limits.verify_chunk or 8192
  if not valid_count(chunk_size)or chunk_size<1 then
    local _,close_err=checked_file_close(handle,"staged verification")
    return nil,"staged verification chunk budget is invalid"..(close_err and"; "..close_err or"")
  end
  local read_budget=limits.verify_reads or(math.ceil(item.size/chunk_size)+16)
  if not valid_count(read_budget)or read_budget<1 then
    local _,close_err=checked_file_close(handle,"staged verification")
    return nil,"staged verification read budget is invalid"..(close_err and"; "..close_err or"")
  end
  local chunks,total,reads={},0,0
  local failure
  while not failure do
    reads=reads+1
    if reads>read_budget then failure="staged verification read budget exceeded for "..destination;break end
    local amount=math.min(chunk_size,item.size-total+1)
    local called,chunk,read_err=pcall(function()return handle:read(amount)end)
    if not called then failure="staged file read failed for "..destination..": "..tostring(chunk)
    elseif chunk==nil then
      if read_err~=nil then failure="staged file read failed for "..destination..": "..tostring(read_err)else break end
    elseif type(chunk)~="string"then failure="staged file read returned malformed data for "..destination
    elseif #chunk>0 then
      total=total+#chunk
      if total>item.size then failure="staged file exceeds pinned size "..item.size.." at "..destination
      else chunks[#chunks+1]=chunk end
    end
  end
  local closed,close_err=checked_file_close(handle,"staged verification")
  if not closed then failure=failure and(failure.."; "..close_err)or close_err end
  if failure then return nil,failure end
  if total~=item.size then return nil,"staged file is short at "..destination..": read "..total.." bytes, pinned size is "..item.size end
  local called,digest,digest_err=pcall(runtime.data.sha256,table.concat(chunks))
  if not called then return nil,"staged SHA-256 failed: "..tostring(digest)end
  if type(digest)~="string"then return nil,"staged SHA-256 failed: "..tostring(digest_err)end
  if hex(digest)~=item.sha256:lower()then return nil,"staged file SHA-256 does not match pinned manifest at "..destination end
  return true
end
local function fetcher(runtime,limits)
  limits=limits or {};local clock=assert(runtime.computer.uptime);local started=clock()
  local connect_limit=limits.connect or 10;local read_limit=limits.read or 10;local file_limit=limits.file or 60;local overall_limit=limits.overall or 300
  return function(url,destination,item)
    if type(item)~="table"or not valid_count(item.size)or type(item.sha256)~="string"then return nil,"manifest entry lacks pinned size/digest"end
    local file_started=clock();if file_started-started>overall_limit then return nil,"installer overall deadline reached before request"end
    local request,request_err=runtime.internet.request(url)
    if not request then return nil,request_err end
    while true do
      local connected,connect_err=call(request,"finishConnect")
      if connected==true then break end
      if connect_err then close(request);return nil,"connection failed: "..tostring(connect_err)end
      local now=clock();if now-file_started>connect_limit or now-started>overall_limit then close(request);return nil,"connection deadline reached"end
      runtime.computer.pullSignal(0.05)
    end
    local code,message=call(request,"response")
    if type(code)~="number"or code<200 or code>=300 then close(request);return nil,"HTTPS response was "..tostring(code).." "..tostring(message)end
    local handle,open_err=runtime.open(destination,"wb");if not handle then close(request);return nil,open_err end
    local total,last=0,clock()
    local function fail(reason)close(request);if handle then pcall(function()handle:close()end)end;return nil,reason end
    while true do
      local chunk,read_err=call(request,"read",8192)
      local now=clock()
      if chunk==nil then if read_err then return fail("read failed: "..tostring(read_err))end break end
      if type(chunk)~="string"then return fail("read returned a malformed chunk")end
      if #chunk>0 then
        total=total+#chunk;if total>item.size then return fail("download exceeds pinned size")end
        local called,written,write_err=pcall(function()return handle:write(chunk)end)
        if not called then return fail("write failed: "..tostring(written))end
        if not written then return fail("write failed: "..tostring(write_err))end
        last=now
      elseif now-last>read_limit then return fail("read deadline reached")end
      if now-file_started>file_limit then return fail("file deadline reached")end
      if now-started>overall_limit then return fail("installer overall deadline reached")end
      if #chunk==0 then runtime.computer.pullSignal(0.05)end
    end
    close(request)
    if total~=item.size then return fail("download size "..total.." does not match pinned size "..item.size)end
    if type(handle.flush)~="function"then return fail("download handle has no explicit flush")end
    local called,flushed,flush_err=pcall(function()return handle:flush()end)
    if not called then return fail("download flush failed: "..tostring(flushed))end
    if not flushed then return fail("download flush failed: "..tostring(flush_err))end
    local closed,close_err=checked_file_close(handle,"download");handle=nil
    if not closed then return nil,close_err end
    return verify_staged(runtime,destination,item,limits)
  end
end
M.fetcher=fetcher
function M.run(kind,argv,runtime)
  argv=argv or {}
  local base
  for _,arg in ipairs(argv)do local value=arg:match("^%-%-base%-url=(.+)$");if value then base=value elseif arg=="--help"or arg=="-h"then print("Usage: install-"..kind..".lua --base-url=https://approved-host/path/");return true else return nil,"unknown installer option '"..arg.."'"end end
  if not base or not base:match("^https://")then return nil,"an HTTPS --base-url is required"end;if base:sub(-1)~="/"then base=base.."/"end
  if not runtime then
    local component=require("component")
    local function primary(name)local ok,value=pcall(function()return component[name]end);if ok then return value end end
    runtime={filesystem=require("filesystem"),internet=primary("internet"),data=primary("data"),computer=require("computer"),open=io.open}
  end
  runtime.open=runtime.open or io.open
  if not runtime.internet then return nil,"an internet card is required"end
  if not runtime.data or not Calls.callable(runtime.data.sha256)then return nil,"a tier-2-or-better data card providing SHA-256 is required for pinned release validation"end
  local manifest=kind=="robot"and Manifest.robot(base)or Manifest.computer(base)
  local ok,backup_or_err=Transaction.install({fs=fs_wrapper(runtime.filesystem),fetch=fetcher(runtime,runtime.deadlines),root="/",manifest=manifest})
  if not ok then return nil,backup_or_err end
  print("Installed a complete verified "..kind.." file set. Previous files remain in "..backup_or_err);return true
end
return M
