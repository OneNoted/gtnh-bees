local H=require("tests.harness")
local Installer=require("gtnh_bees.installer")
local Transaction=require("gtnh_bees.transaction")

local function hex(text)return(text:gsub(".",function(c)return string.format("%02x",string.byte(c))end))end

local function fetch_fixture(network,stored,options)
  options=options or {}
  local files={}
  local reads={network,nil}
  local request={
    finishConnect=function()return true end,
    response=function()return 200,"OK"end,
    read=function()return table.remove(reads,1)end,
    close=function()return true end
  }
  local runtime={
    internet={request=function()return request end},
    computer={uptime=function()return 0 end,pullSignal=function()end},
    data={sha256=function(value)if options.digest_error then return nil,options.digest_error end;return value end},
    open=function(path,mode)
      if mode=="wb"then
        local chunks={}
        return {
          write=function(_,chunk)chunks[#chunks+1]=chunk;return true end,
          flush=function()return true end,
          close=function()files[path]=stored~=nil and stored or table.concat(chunks);if options.nil_close_success then return nil end;return true end
        }
      end
      H.equal(mode,"rb");local value=files[path]or"";local position=1;local calls=0
      return {
        read=function(_,amount)
          calls=calls+1
          if options.read_error and calls==options.read_error then return nil,"injected staged read error"end
          if options.empty_reads then return""end
          if position>#value then return nil end
          local chunk=value:sub(position,position+amount-1);position=position+#chunk;return chunk
        end,
        close=function()if options.close_error then return nil,"injected staged close error"end;if options.nil_close_success then return nil end;return true end
      }
    end
  }
  return runtime,files
end

H.test("staged verifier hashes reopened stored bytes rather than network chunks",function()
  local runtime=fetch_fixture("abc","abd")
  local ok,err=Installer.fetcher(runtime,{verify_reads=4})("u","/stage/file",{size=3,sha256=hex("abc")})
  H.falsy(ok);H.contains(err,"staged file SHA-256");H.contains(err,"/stage/file")
end)

H.test("staged verifier rejects truncation and short stored files",function()
  for _,stored in ipairs({"ab",""})do
    local runtime=fetch_fixture("abc",stored)
    local ok,err=Installer.fetcher(runtime,{verify_reads=4})("u","/stage/short",{size=3,sha256=hex("abc")})
    H.falsy(ok);H.contains(err,"staged file is short");H.contains(err,"/stage/short")
  end
end)

H.test("staged verifier rejects stored bytes beyond the pinned size",function()
  local runtime=fetch_fixture("abc","abcd")
  local ok,err=Installer.fetcher(runtime,{verify_reads=4})("u","/stage/large",{size=3,sha256=hex("abc")})
  H.falsy(ok);H.contains(err,"exceeds pinned size");H.contains(err,"/stage/large")
end)

H.test("staged verifier propagates staged read and close failures",function()
  local runtime=fetch_fixture("abc","abc",{read_error=1})
  local ok,err=Installer.fetcher(runtime,{verify_reads=4})("u","/stage/read",{size=3,sha256=hex("abc")})
  H.falsy(ok);H.contains(err,"staged file read failed");H.contains(err,"injected staged read error")
  runtime=fetch_fixture("abc","abc",{close_error=true})
  ok,err=Installer.fetcher(runtime,{verify_reads=4})("u","/stage/close",{size=3,sha256=hex("abc")})
  H.falsy(ok);H.contains(err,"staged verification close failed");H.contains(err,"injected staged close error")
end)

H.test("installer accepts OpenOS nil close success for downloaded and reopened files",function()
  local runtime=fetch_fixture("abc","abc",{nil_close_success=true})
  H.truthy(Installer.fetcher(runtime,{verify_reads=4})("u","/stage/file",{size=3,sha256=hex("abc")}))
end)

H.test("staged verifier rejects exact stored bytes with a wrong SHA pin",function()
  local runtime=fetch_fixture("abc","abc")
  local ok,err=Installer.fetcher(runtime,{verify_reads=4})("u","/stage/hash",{size=3,sha256=hex("abd")})
  H.falsy(ok);H.contains(err,"SHA-256");H.contains(err,"/stage/hash")
end)

H.test("staged verification empty reads terminate at a finite read budget",function()
  local runtime=fetch_fixture("a","a",{empty_reads=true})
  local ok,err=Installer.fetcher(runtime,{verify_reads=3})("u","/stage/stall",{size=1,sha256=hex("a")})
  H.falsy(ok);H.contains(err,"read budget exceeded")
end)

local function copy(values)local result={}for key,value in pairs(values or{})do result[key]=value end return result end
local function memory_fs(initial,control)
  local files=copy(initial);files["/"]=files["/"]or{directory=true};control=control or{};local fs={}
  function fs.exists(path)return files[path]~=nil end
  function fs.isDirectory(path)return type(files[path])=="table"and files[path].directory==true end
  function fs.makeDirectory(path)files[path]=files[path]or{directory=true};return true end
  function fs.remove(path)
    if control.remove and control.remove(path,files)then return nil,"injected remove failure"end
    files[path]=nil;return true
  end
  function fs.rename(source,destination)
    if control.rename then local fail,detail=control.rename(source,destination,files);if fail then return nil,detail or"injected rename failure"end end
    if files[source]==nil then return nil,"missing source "..source end
    files[destination],files[source]=files[source],nil;return true
  end
  function fs.open(path,mode)
    if mode=="w"then
      if control.open and control.open(path,files)then return nil,"injected open failure"end
      local chunks={}
      return {
        write=function(_,...)
          if control.write and control.write(path,chunks,files)then return nil,"injected write failure"end
          for index=1,select("#",...)do chunks[#chunks+1]=tostring(select(index,...))end
          return true
        end,
        flush=function()
          if control.flush and control.flush(path,chunks,files)then return nil,"injected flush failure"end
          return true
        end,
        close=function()
          files[path]=table.concat(chunks)
          if control.close and control.close(path,chunks,files)then return nil,"injected close failure"end
          if control.nil_close_success then return nil end
          return true
        end
      }
    end
    local data=files[path];if type(data)~="string"then return nil,"missing file"end
    local position=1
    return {
      read=function(_,format)
        H.equal(format,"*l")
        if position>#data then return nil end
        local start,finish=data:find("\n",position,true)
        local line=start and data:sub(position,start-1)or data:sub(position)
        position=start and finish+1 or#data+1
        return line
      end,
      lines=function(self)return function()return self:read("*l")end end,
      close=function()return true end
    }
  end
  return fs,files
end

local journal_path="/.gtnh-bees-install.journal"
local temporary_path=journal_path..".tmp"

H.test("installing journal publish failure retains staging without destination mutation",function()
  local enabled=true
  local control={rename=function(source,destination)
    if enabled and source==temporary_path and destination==journal_path then return true,"injected installing journal rename failure"end
  end}
  local fs,files=memory_fs({["/a"]="old-a"},control)
  local ok,err=Transaction.install({fs=fs,root="/",manifest={{url="a",path="a"}},now=function()return 29 end,fetch=function(_,path)files[path]="new-a";return true end})
  H.falsy(ok);H.equal(files["/a"],"old-a");H.truthy(files["/.gtnh-bees-stage-29/a"]);H.falsy(files[journal_path]);H.truthy(files[temporary_path]);H.contains(err,"/.gtnh-bees-stage-29");H.contains(err,temporary_path)
  enabled=false;H.truthy(Transaction.recover(fs,journal_path));H.equal(files["/a"],"old-a");H.falsy(files[temporary_path])
end)

H.test("installing temporary journal interruption precedes all destination mutation",function()
  local unpublished="installing\n/a\t/stage/a\t/backup/a\t1\t0\n"
  local fs,files=memory_fs({[temporary_path]=unpublished,["/a"]="old-a"})
  H.truthy(Transaction.recover(fs,journal_path));H.equal(files["/a"],"old-a");H.falsy(files[temporary_path]);H.falsy(files[journal_path])
end)

H.test("installing live journal wins over an interrupted committed temporary journal",function()
  local installing="installing\n/a\t/stage/a\t/backup/a\t1\t1\n"
  local committed="committed\n/a\t/stage/a\t/backup/a\t1\t1\n"
  local fs,files=memory_fs({[journal_path]=installing,[temporary_path]=committed,["/a"]="new-a",["/backup/a"]="old-a"})
  H.truthy(Transaction.recover(fs,journal_path));H.equal(files["/a"],"old-a");H.falsy(files["/backup/a"]);H.falsy(files[journal_path]);H.falsy(files[temporary_path])
end)

H.test("committed live journal interruption finalizes the installed release",function()
  local committed="committed\n/a\t/stage/a\t/backup/a\t1\t1\n"
  local fs,files=memory_fs({[journal_path]=committed,["/a"]="new-a",["/backup/a"]="old-a"})
  H.truthy(Transaction.recover(fs,journal_path));H.equal(files["/a"],"new-a");H.equal(files["/backup/a"],"old-a");H.falsy(files[journal_path])
end)

H.test("journal phase replacement is one rename while the prior live journal exists",function()
  local committed_replace_saw_live=false
  local control={rename=function(source,destination,files)
    if source==temporary_path and destination==journal_path and type(files[source])=="string"and files[source]:match("^committed\n")then
      committed_replace_saw_live=type(files[destination])=="string"and files[destination]:match("^installing\n")~=nil
    end
  end}
  local fs,files=memory_fs({["/a"]="old-a"},control)
  local ok=Transaction.install({fs=fs,root="/",manifest={{url="a",path="a"}},now=function()return 30 end,fetch=function(_,path)files[path]="new-a";return true end})
  H.truthy(ok);H.truthy(committed_replace_saw_live);H.equal(files["/a"],"new-a");H.falsy(files[journal_path]);H.falsy(files[temporary_path])
end)

H.test("transaction journals accept OpenOS nil close success",function()
  local fs,files=memory_fs({["/a"]="old-a"},{nil_close_success=true})
  H.truthy(Transaction.install({fs=fs,root="/",manifest={{url="a",path="a"}},now=function()return 32 end,fetch=function(_,path)files[path]="new-a";return true end}))
  H.equal(files["/a"],"new-a");H.falsy(files[journal_path]);H.falsy(files[temporary_path])
end)

H.test("committed phase journal failures preserve the installing journal until recovery",function()
  for _,mode in ipairs({"open","write","flush","close","rename"})do
    local enabled=true
    local backup="/.gtnh-bees-backup-31/a"
    local control={}
    control.open=function(path,files)return enabled and mode=="open"and path==temporary_path and files[journal_path]~=nil and files["/a"]=="new-a"end
    control.write=function(path,_,files)return enabled and mode=="write"and path==temporary_path and files[journal_path]~=nil and files["/a"]=="new-a"end
    control.flush=function(path,chunks,files)return enabled and mode=="flush"and path==temporary_path and files[journal_path]~=nil and table.concat(chunks):match("^committed\n")~=nil end
    control.close=function(path,chunks,files)return enabled and mode=="close"and path==temporary_path and files[journal_path]~=nil and table.concat(chunks):match("^committed\n")~=nil end
    control.rename=function(source,destination,files)
      if enabled and source==backup and destination=="/a"then return true,"injected restore failure"end
      if enabled and mode=="rename"and source==temporary_path and destination==journal_path and type(files[source])=="string"and files[source]:match("^committed\n")then return true,"injected journal rename failure"end
    end
    local fs,files=memory_fs({["/a"]="old-a"},control)
    local ok,err=Transaction.install({fs=fs,root="/",manifest={{url="a",path="a"}},now=function()return 31 end,fetch=function(_,path)files[path]="new-a";return true end})
    H.falsy(ok,"expected committed "..mode.." failure");H.contains(err,"/a");H.contains(err,journal_path)
    H.truthy(type(files[journal_path])=="string"and files[journal_path]:match("^installing\n"),"prior journal lost after "..mode)
    H.equal(files[backup],"old-a");H.falsy(files["/a"])
    if mode~="open"then H.truthy(files[temporary_path],"temporary artifact missing after "..mode)end
    enabled=false
    H.truthy(Transaction.recover(fs,journal_path));H.equal(files["/a"],"old-a");H.falsy(files[backup]);H.falsy(files[journal_path]);H.falsy(files[temporary_path])
  end
end)

local function verify_self_contained_launcher(path)
  local file=assert(io.open(path,"r"));local shebang=file:read("*l");file:close();H.equal(shebang,"#!/bin/lua.lua")
  local names={
    "gtnh_bees.component_call","gtnh_bees.transaction","gtnh_bees.install_manifest","gtnh_bees.installer",
    "component","filesystem","computer"
  }
  local saved={}
  for _,name in ipairs(names)do
    saved[name]={loaded=package.loaded[name],preload=package.preload[name]}
    if name:match("^gtnh_bees%.")then package.loaded[name]={stale=true}else package.loaded[name]=nil end
    package.preload[name]=nil
  end
  package.preload.component=function()return{internet={},data={sha256=function()return""end}}end
  package.preload.filesystem=function()return{}end
  package.preload.computer=function()return{}end
  local old_path,old_print=package.path,print
  local messages={}
  package.path="/gtnh-bees-bootstrap-test/?.lua"
  print=function(message)messages[#messages+1]=tostring(message)end
  local chunk,load_err=loadfile(path)
  local called,run_err=false,load_err
  if chunk then called,run_err=pcall(chunk,"--help")end
  local bundled=type(package.loaded["gtnh_bees.installer"])=="table"and package.loaded["gtnh_bees.installer"].stale~=true
  package.path,print=old_path,old_print
  for _,name in ipairs(names)do
    package.loaded[name]=saved[name].loaded
    package.preload[name]=saved[name].preload
  end
  H.truthy(chunk,load_err);H.truthy(called,run_err);H.truthy(bundled)
  H.truthy(messages[1]);H.contains(messages[1],"Usage:")
end

H.test("generated launchers bootstrap without checkout or installed modules",function()
  verify_self_contained_launcher("install-computer.lua")
  verify_self_contained_launcher("install-robot.lua")
end)

H.test("installer accepts an OpenOS-safe positional HTTPS base URL",function()
  local ok,err=Installer.run("computer",{"https://release/"},{})
  H.falsy(ok);H.contains(err,"internet card")
end)

H.test("installer reports an absent primary data card without unwinding",function()
  local names={"component","filesystem","computer"};local saved={}
  for _,name in ipairs(names)do saved[name]=package.loaded[name]end
  package.loaded.component=setmetatable({internet={}},{__index=function(_,name)error("no primary '"..name.."' available")end})
  package.loaded.filesystem={};package.loaded.computer={}
  local survived,ok,err=pcall(Installer.run,"computer",{"--base-url=https://release/"})
  for _,name in ipairs(names)do package.loaded[name]=saved[name]end
  H.truthy(survived);H.falsy(ok);H.contains(err,"tier-2-or-better data card")
end)

return H
