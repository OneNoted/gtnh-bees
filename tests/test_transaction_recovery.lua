local H=require("tests.harness")
local Installer=require("gtnh_bees.installer")
local Transaction=require("gtnh_bees.transaction")

local function parent(path)
  local value=path:match("^(.*)/[^/]+$")
  if value==""then return "/"end
  return value
end

local function memory_fs(options)
  options=options or{}
  local directories={["/"]=true}
  local files={}
  local calls={fetch=0,rename={}}
  for _,path in ipairs(options.directories or{})do directories[path]=true end
  for path,value in pairs(options.files or{})do files[path]=value end
  local fs={}
  function fs.exists(path)return directories[path]==true or files[path]~=nil end
  function fs.isDirectory(path)return directories[path]==true end
  function fs.makeDirectory(path)
    if options.make then
      local handled,a,b=options.make(path,directories,files)
      if handled then return a,b end
    end
    if fs.exists(path)then return nil,"already exists"end
    if not directories[parent(path)]then return nil,"parent missing"end
    directories[path]=true
    return true
  end
  function fs.remove(path)
    files[path]=nil
    directories[path]=nil
    return true
  end
  function fs.rename(source,destination)
    calls.rename[#calls.rename+1]={source,destination}
    if options.rename then
      local fail,detail=options.rename(source,destination,directories,files)
      if fail then return nil,detail or"injected rename failure"end
    end
    if files[source]==nil then return nil,"missing source "..source end
    if not directories[parent(destination)]then return nil,"destination parent missing"end
    files[destination],files[source]=files[source],nil
    return true
  end
  function fs.open(path,mode)
    if mode=="w"then
      if not directories[parent(path)]then return nil,"parent missing"end
      local chunks={}
      return {
        write=function(_,...)
          for index=1,select("#",...)do chunks[#chunks+1]=tostring(select(index,...))end
          return true
        end,
        flush=function()return true end,
        close=function()files[path]=table.concat(chunks);return true end
      }
    end
    local data=files[path]
    if type(data)~="string"then return nil,"missing file"end
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
  function fs.put(path,value)
    if not directories[parent(path)]then return nil,"parent missing"end
    files[path]=value
    return true
  end
  local function fetch(url,path)
    calls.fetch=calls.fetch+1
    return fs.put(path,"new-"..url)
  end
  return fs,files,directories,calls,fetch
end

H.test("stale stage or backup roots abort before download and destination mutation",function()
  for _,stale in ipairs({"/.gtnh-bees-stage-100","/.gtnh-bees-backup-100"})do
    local fs,files,_,calls,fetch=memory_fs({directories={stale},files={["/a"]="old-a"}})
    local ok,err=Transaction.install({fs=fs,root="/",manifest={{url="a",path="a"}},now=function()return 100 end,fetch=fetch})
    H.falsy(ok);H.contains(err,"transaction root already exists");H.contains(err,stale)
    H.equal(calls.fetch,0);H.equal(#calls.rename,0);H.equal(files["/a"],"old-a")
  end
end)

H.test("transaction root create races fail instead of reusing the winner",function()
  for _,raced in ipairs({"/.gtnh-bees-stage-101","/.gtnh-bees-backup-101"})do
    local armed=true
    local fs,files,_,calls,fetch=memory_fs({files={["/a"]="old-a"},make=function(path,directories)
      if armed and path==raced then armed=false;directories[path]=true;return true,nil,"already exists"end
      return false
    end})
    local ok,err=Transaction.install({fs=fs,root="/",manifest={{url="a",path="a"}},now=function()return 101 end,fetch=fetch})
    H.falsy(ok);H.contains(err,"transaction root appeared while being created");H.contains(err,raced)
    H.equal(calls.fetch,0);H.equal(#calls.rename,0);H.equal(files["/a"],"old-a")
  end
end)

H.test("a second same-second install cannot reuse the first backup root",function()
  local fs,files,_,calls,fetch=memory_fs({files={["/a"]="old-a"}})
  local options={fs=fs,root="/",manifest={{url="a",path="a"}},now=function()return 102 end,fetch=fetch}
  local first,backup=Transaction.install(options)
  H.truthy(first);H.equal(backup,"/.gtnh-bees-backup-102");H.equal(files["/a"],"new-a")
  local fetches,renames=calls.fetch,#calls.rename
  local second,err=Transaction.install(options)
  H.falsy(second);H.contains(err,"/.gtnh-bees-backup-102");H.contains(err,"transaction root already exists")
  H.equal(calls.fetch,fetches);H.equal(#calls.rename,renames);H.equal(files["/a"],"new-a")
end)

H.test("stale backup injection is retained and never restored as trusted bytes",function()
  local injected=false
  local fs,files,_,_,fetch=memory_fs({files={["/a"]="old-a",["/b"]="old-b"},rename=function(source,destination,_,values)
    if destination=="/a"and source:find("stage",1,true)then
      injected=true
      values["/.gtnh-bees-backup-103/b"]="attacker-bytes"
    end
  end})
  local ok,err=Transaction.install({fs=fs,root="/",manifest={{url="a",path="a"},{url="b",path="b"}},now=function()return 103 end,fetch=fetch})
  H.falsy(ok);H.truthy(injected);H.contains(err,"unowned backup");H.contains(err,"/.gtnh-bees-backup-103/b")
  H.equal(files["/a"],"old-a");H.equal(files["/b"],"old-b");H.equal(files["/.gtnh-bees-backup-103/b"],"attacker-bytes")
  H.truthy(files["/.gtnh-bees-install.journal"])
end)

H.test("recovery fails closed without durable backup ownership evidence",function()
  local journal="installing\n/a\t/stage/a\t/backup/a\t1\t0\n"
  local fs,files=memory_fs({files={["/.gtnh-bees-install.journal"]=journal,["/backup/a"]="untrusted"}})
  local ok,err=Transaction.recover(fs,"/.gtnh-bees-install.journal")
  H.falsy(ok);H.contains(err,"unowned backup");H.falsy(files["/a"]);H.equal(files["/backup/a"],"untrusted");H.truthy(files["/.gtnh-bees-install.journal"])
end)

H.test("committed recovery retains an injected unowned backup and its journal",function()
  local journal="committed\n/a\t/stage/a\t/backup/a\t0\t0\n"
  local fs,files=memory_fs({files={["/.gtnh-bees-install.journal"]=journal,["/a"]="new-a",["/backup/a"]="untrusted"}})
  local ok,err=Transaction.recover(fs,"/.gtnh-bees-install.journal")
  H.falsy(ok);H.contains(err,"unowned backup");H.equal(files["/a"],"new-a");H.equal(files["/backup/a"],"untrusted");H.truthy(files["/.gtnh-bees-install.journal"])
end)

H.test("durably owned backup restores cleanly after interruption",function()
  local journal="installing\n/a\t/stage/a\t/backup/a\t1\t1\n"
  local fs,files=memory_fs({files={["/.gtnh-bees-install.journal"]=journal,["/backup/a"]="old-a"}})
  H.truthy(Transaction.recover(fs,"/.gtnh-bees-install.journal"))
  H.equal(files["/a"],"old-a");H.falsy(files["/backup/a"]);H.falsy(files["/.gtnh-bees-install.journal"])
end)

H.test("backup ownership is durable before the old destination moves",function()
  local witnessed=false
  local fs,files,_,_,fetch=memory_fs({files={["/a"]="old-a"},rename=function(source,destination,_,values)
    if source=="/a"and destination=="/.gtnh-bees-backup-107/a"then
      witnessed=type(values["/.gtnh-bees-install.journal"])=="string"and values["/.gtnh-bees-install.journal"]:match("\t1\t1\n$")~=nil
    end
  end})
  H.truthy(Transaction.install({fs=fs,root="/",manifest={{url="a",path="a"}},now=function()return 107 end,fetch=fetch}))
  H.truthy(witnessed);H.equal(files["/a"],"new-a")
end)

H.test("backup ownership publication failure precedes destination mutation",function()
  local refused=false
  local fs,files,_,_,fetch=memory_fs({files={["/a"]="old-a"},rename=function(source,destination,_,values)
    if source=="/.gtnh-bees-install.journal.tmp"and destination=="/.gtnh-bees-install.journal"and
      type(values[source])=="string"and values[source]:match("\t1\n$")then
      refused=true;return true,"ownership publication interrupted"
    end
  end})
  local ok,err=Transaction.install({fs=fs,root="/",manifest={{url="a",path="a"}},now=function()return 104 end,fetch=fetch})
  H.falsy(ok);H.truthy(refused);H.contains(err,"durable backup ownership");H.contains(err,"prior file set was fully restored")
  H.equal(files["/a"],"old-a");H.falsy(files["/.gtnh-bees-backup-104/a"])
  H.falsy(files["/.gtnh-bees-install.journal"]);H.falsy(files["/.gtnh-bees-install.journal.tmp"])
end)

H.test("owned backup is journaled before staged replacement installation",function()
  local witnessed=false
  local fs,files,_,_,fetch=memory_fs({files={["/a"]="old-a"},rename=function(source,destination,_,values)
    if destination=="/a"and source:find("stage",1,true)then
      witnessed=type(values["/.gtnh-bees-install.journal"])=="string"and values["/.gtnh-bees-install.journal"]:match("\t1\t1\n$")~=nil
    end
  end})
  H.truthy(Transaction.install({fs=fs,root="/",manifest={{url="a",path="a"}},now=function()return 105 end,fetch=fetch}))
  H.truthy(witnessed);H.equal(files["/a"],"new-a")
end)

H.test("production installer rejects a regular-file destination parent before requests",function()
  local fs,files=memory_fs({files={["/usr"]="not-a-directory"}})
  local requests=0
  local runtime={
    filesystem=fs,
    internet={request=function()requests=requests+1;return nil,"must not request"end},
    data={sha256=function(value)return value end},
    computer={uptime=function()return 0 end,pullSignal=function()end},
    open=function()error("must not open a staged file")end
  }
  local ok,err=Installer.run("computer",{"--base-url=https://approved.example/release/"},runtime)
  H.falsy(ok);H.contains(err,"path exists but is not a directory: /usr");H.equal(requests,0);H.equal(files["/usr"],"not-a-directory")
end)

H.test("clean rollback restores every old file and removes recovery authority",function()
  local fs,files,_,_,fetch=memory_fs({files={["/a"]="old-a",["/b"]="old-b"},rename=function(source,destination)
    if destination=="/b"and source:find("stage",1,true)then return true,"injected install failure"end
  end})
  local ok,err=Transaction.install({fs=fs,root="/",manifest={{url="a",path="a"},{url="b",path="b"}},now=function()return 106 end,fetch=fetch})
  H.falsy(ok);H.contains(err,"prior file set was fully restored")
  H.equal(files["/a"],"old-a");H.equal(files["/b"],"old-b")
  H.falsy(files["/.gtnh-bees-backup-106/a"]);H.falsy(files["/.gtnh-bees-backup-106/b"])
  H.falsy(files["/.gtnh-bees-install.journal"]);H.falsy(files["/.gtnh-bees-install.journal.tmp"])
end)

return H
