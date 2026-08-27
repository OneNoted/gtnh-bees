local H=require("tests.harness")
local Transaction=require("gtnh_bees.transaction")

local function parent(path)
  local value=path:match("^(.*)/[^/]+$")
  if value==""then return "/"end
  return value
end

local function non_recursive_fs(options)
  options=options or{}
  local directories={["/"]=true}
  local files={}
  local calls={make={},rename={}}
  for _,path in ipairs(options.directories or{})do directories[path]=true end
  for path,value in pairs(options.files or{})do files[path]=value end
  local fs={}
  function fs.exists(path)return directories[path]==true or files[path]~=nil end
  function fs.isDirectory(path)return directories[path]==true end
  function fs.makeDirectory(path)
    calls.make[#calls.make+1]=path
    if options.fail_directory==path then return nil,"injected directory failure"end
    if options.race_existing==path then
      options.race_existing=nil
      directories[path]=true
      return nil,"file or directory with that name already exists"
    end
    if fs.exists(path)then return nil,"file or directory with that name already exists"end
    if not directories[parent(path)]then return nil,"no such directory"end
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
    if files[source]==nil then return nil,"missing source "..source end
    if not directories[parent(destination)]then return nil,"destination parent is missing"end
    files[destination],files[source]=files[source],nil
    return true
  end
  function fs.open(path,mode)
    if mode=="w"then
      if not directories[parent(path)]then return nil,"parent directory is missing"end
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
    if not directories[parent(path)]then return nil,"parent directory is missing"end
    files[path]=value
    return true
  end
  return fs,files,directories,calls
end

H.test("fresh OpenOS-style filesystem creates nested stage backup journal and destination parents",function()
  local fs,files,directories=non_recursive_fs()
  local manifest={
    {url="bin",path="usr/bin/gtnh-bees"},
    {url="lib",path="usr/lib/gtnh_bees/runtime.lua"}
  }
  local ok,backup=Transaction.install({
    fs=fs,root="/",journal="/.state/transactions/install.journal",manifest=manifest,now=function()return 71 end,
    fetch=function(url,path)return fs.put(path,"new-"..url)end
  })
  H.truthy(ok)
  H.equal(backup,"/.gtnh-bees-backup-71")
  H.equal(files["/usr/bin/gtnh-bees"],"new-bin")
  H.equal(files["/usr/lib/gtnh_bees/runtime.lua"],"new-lib")
  for _,path in ipairs({
    "/.gtnh-bees-stage-71/usr","/.gtnh-bees-stage-71/usr/bin",
    "/.gtnh-bees-stage-71/usr/lib","/.gtnh-bees-stage-71/usr/lib/gtnh_bees",
    "/.gtnh-bees-backup-71/usr","/.gtnh-bees-backup-71/usr/bin",
    "/.gtnh-bees-backup-71/usr/lib","/.gtnh-bees-backup-71/usr/lib/gtnh_bees",
    "/.state","/.state/transactions","/usr","/usr/bin","/usr/lib","/usr/lib/gtnh_bees"
  })do H.truthy(directories[path],"missing directory "..path)end
end)

H.test("staging directory failure aborts before fetch or destination mutation",function()
  local failed_path="/.gtnh-bees-stage-72/usr/lib"
  local fs,files,directories,calls=non_recursive_fs({fail_directory=failed_path,files={["/sentinel"]="old"}})
  local fetches=0
  local ok,err=Transaction.install({
    fs=fs,root="/",manifest={{url="lib",path="usr/lib/gtnh_bees/runtime.lua"}},now=function()return 72 end,
    fetch=function()fetches=fetches+1;return true end
  })
  H.falsy(ok)
  H.contains(err,"cannot create staging parent")
  H.contains(err,failed_path)
  H.contains(err,"injected directory failure")
  H.equal(fetches,0)
  H.equal(#calls.rename,0)
  H.equal(files["/sentinel"],"old")
  H.falsy(directories["/usr"])
end)

H.test("backup and journal directory failures are propagated before destination mutation",function()
  local cases={
    {path="/.gtnh-bees-backup-74/usr/lib",journal="/.gtnh-bees-install.journal",fragment="cannot create backup parent"},
    {path="/.state/transactions",journal="/.state/transactions/install.journal",fragment="cannot create journal parent"}
  }
  for _,case in ipairs(cases)do
    local fs,_,directories,calls=non_recursive_fs({fail_directory=case.path})
    local fetches=0
    local ok,err=Transaction.install({
      fs=fs,root="/",journal=case.journal,manifest={{url="lib",path="usr/lib/gtnh_bees/runtime.lua"}},now=function()return 74 end,
      fetch=function()fetches=fetches+1;return true end
    })
    H.falsy(ok)
    H.contains(err,case.fragment)
    H.contains(err,case.path)
    H.contains(err,"injected directory failure")
    H.equal(fetches,0)
    H.equal(#calls.rename,0)
    H.falsy(directories["/usr"])
  end
end)

H.test("an observed existing parent succeeds after makeDirectory reports already existing",function()
  local raced="/.gtnh-bees-stage-73/usr"
  local fs,files,directories,calls=non_recursive_fs({race_existing=raced})
  local ok=Transaction.install({
    fs=fs,root="/",manifest={{url="bin",path="usr/bin/tool"}},now=function()return 73 end,
    fetch=function(url,path)return fs.put(path,url)end
  })
  H.truthy(ok)
  H.equal(files["/usr/bin/tool"],"bin")
  H.truthy(directories[raced])
  local raced_calls=0
  for _,path in ipairs(calls.make)do if path==raced then raced_calls=raced_calls+1 end end
  H.equal(raced_calls,1)
end)

return H
