local Transaction={}
local unpack_values=table.unpack or unpack
local function join(a,b)return(a:gsub("/$","")).."/"..(b:gsub("^/",""))end
local MAX_PATH_COMPONENTS=64
local function observe_exists(fs,path)
  local called,exists=pcall(fs.exists,path)
  if not called then return nil,"cannot inspect path "..path..": "..tostring(exists)end
  if type(exists)~="boolean"then return nil,"cannot inspect path "..path..": exists did not return a boolean"end
  return exists
end
local function observe_directory(fs,path)
  local exists,exists_err=observe_exists(fs,path)
  if exists==nil then return nil,exists_err end
  if not exists then return false end
  if type(fs.isDirectory)~="function"then return nil,"filesystem cannot inspect directory type for "..path end
  local directory_called,is_directory=pcall(fs.isDirectory,path)
  if not directory_called then return nil,"cannot inspect directory "..path..": "..tostring(is_directory)end
  if type(is_directory)~="boolean"then return nil,"cannot inspect directory "..path..": isDirectory did not return a boolean"end
  if not is_directory then return nil,"path exists but is not a directory: "..path end
  return true
end
local function ensure_directory(fs,path)
  local exists,inspect_err=observe_directory(fs,path)
  if exists==nil then return nil,inspect_err end
  if exists then return true end
  local called,made,make_err=pcall(fs.makeDirectory,path)
  if not called then return nil,"makeDirectory failed for "..path..": "..tostring(made)end
  local observed,observe_err=observe_directory(fs,path)
  if observed then return true end
  if observed==nil then return nil,observe_err end
  if made then return nil,"makeDirectory reported success but directory was not observed: "..path end
  return nil,"makeDirectory failed for "..path..": "..tostring(make_err or"no error detail")
end
local function require_fresh_path(fs,path)
  local exists,inspect_err=observe_exists(fs,path)
  if exists==nil then return nil,inspect_err end
  if exists then return nil,"transaction root already exists: "..path end
  return true
end
local function create_fresh_directory(fs,path)
  local fresh,fresh_err=require_fresh_path(fs,path)
  if not fresh then return nil,fresh_err end
  local called,made,make_err=pcall(fs.makeDirectory,path)
  if not called then return nil,"makeDirectory failed for fresh transaction root "..path..": "..tostring(made)end
  if not made then
    local exists,inspect_err=observe_exists(fs,path)
    if exists==nil then return nil,inspect_err end
    if exists then return nil,"transaction root appeared while being created: "..path end
    return nil,"makeDirectory failed for fresh transaction root "..path..": "..tostring(make_err or"no error detail")
  end
  local observed,observe_err=observe_directory(fs,path)
  if observed then return true end
  if observed==nil then return nil,observe_err end
  return nil,"fresh transaction root was not observed after creation: "..path
end
local function relative_components(path)
  if type(path)~="string"or path==""or path:sub(1,1)=="/"or path:sub(-1)=="/"or path:find("//",1,true)then return nil,"path is not a normalized relative file path"end
  local components={}
  for component in path:gmatch("[^/]+")do
    if component=="."or component==".."then return nil,"path traversal is not allowed"end
    components[#components+1]=component
    if #components>MAX_PATH_COMPONENTS then return nil,"path exceeds component limit"end
  end
  if #components==0 then return nil,"path has no components"end
  return components
end
local function ensure_relative_parent(fs,root,relative)
  local components,component_err=relative_components(relative)
  if not components then return nil,component_err end
  local current=root
  for index=1,#components-1 do
    current=join(current,components[index])
    local made,make_err=ensure_directory(fs,current)
    if not made then return nil,make_err end
  end
  return true
end
local function relative_to_root(root,path)
  local normalized=root:gsub("/+$","")
  if normalized==""then normalized="/"end
  if normalized=="/"then
    if path:sub(1,1)~="/"then return nil,"path is not rooted at "..normalized end
    return path:sub(2)
  end
  local prefix=normalized.."/"
  if path:sub(1,#prefix)~=prefix then return nil,"path is not rooted at "..normalized end
  return path:sub(#prefix+1)
end
local function checked_remove(fs,path)
  if not fs.exists(path)then return true end
  local ok,err=fs.remove(path);if ok==false or ok==nil then return nil,err or"remove failed"end return true
end
local function journal_temp(path)return path..".tmp"end
local function file_call(handle,method,...)
  local arguments={...}
  return pcall(function()return handle[method](handle,unpack_values(arguments))end)
end
local function write_journal(fs,path,journal)
  local temporary=journal_temp(path)
  if fs.exists(temporary)then return nil,"temporary journal already exists at "..temporary,temporary end
  local handle,err=fs.open(temporary,"w");if not handle then return nil,"cannot create temporary journal "..temporary..": "..tostring(err),temporary end
  local ok,write_err=true
  local called,written,detail=file_call(handle,"write",journal.phase.."\n")
  if not called then ok,write_err=nil,"journal write failed: "..tostring(written)
  elseif not written then ok,write_err=nil,"journal write failed: "..tostring(detail)end
  if ok then
    for _,entry in ipairs(journal.entries)do
      called,written,detail=file_call(handle,"write",table.concat({entry.destination,entry.staged,entry.backup,entry.had_old and"1"or"0",entry.backup_owned and"1"or"0"},"\t"),"\n")
      if not called then ok,write_err=nil,"journal write failed: "..tostring(written);break end
      if not written then ok,write_err=nil,"journal write failed: "..tostring(detail);break end
    end
  end
  if ok then
    if type(handle.flush)~="function"then ok,write_err=nil,"journal handle has no explicit flush"
    else
      local flush_called,flushed,flush_err=file_call(handle,"flush")
      if not flush_called then ok,write_err=nil,"journal flush failed: "..tostring(flushed)
      elseif not flushed then ok,write_err=nil,"journal flush failed: "..tostring(flush_err)end
    end
  end
  local close_called,closed,close_err=file_call(handle,"close")
  if not close_called then ok,write_err=nil,(write_err and(write_err.."; ")or"").."journal close failed: "..tostring(closed)
  elseif closed==false or(closed==nil and close_err~=nil)then ok,write_err=nil,(write_err and(write_err.."; ")or"").."journal close failed: "..tostring(close_err)end
  if not ok then return nil,write_err or"temporary journal write failed",temporary end
  local rename_called,renamed,rename_err=pcall(fs.rename,temporary,path)
  if not rename_called then return nil,"cannot atomically replace journal "..path.." from "..temporary..": "..tostring(renamed),temporary end
  if not renamed then return nil,"cannot atomically replace journal "..path.." from "..temporary..": "..tostring(rename_err),temporary end
  return true,nil,temporary
end
local function read_journal(fs,path)
  local handle=fs.open(path,"r");if not handle then return nil,"cannot open install recovery journal"end
  local phase=handle:read("*l");local entries={}
  for line in handle:lines()do
    local destination,staged,backup,old,owned=line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t([01])\t([01])$")
    if not destination or(owned=="1"and old~="1")then handle:close();return nil,"install journal is malformed"end
    entries[#entries+1]={destination=destination,staged=staged,backup=backup,had_old=old=="1",backup_owned=owned=="1"}
  end
  handle:close();if phase~="installing"and phase~="committed"then return nil,"install journal phase is malformed"end
  if phase=="committed"then for _,entry in ipairs(entries)do if entry.had_old and not entry.backup_owned then return nil,"install journal is malformed"end end end
  return {phase=phase,entries=entries}
end
local function rollback(fs,journal)
  local errors={}
  for index=#journal.entries,1,-1 do
    local entry=journal.entries[index]
    local backup_exists=fs.exists(entry.backup)
    if backup_exists and not entry.backup_owned then
      errors[#errors+1]=entry.destination.." (unowned backup retained at "..entry.backup..")"
    elseif entry.had_old and entry.backup_owned then
      if fs.exists(entry.backup)then
        if fs.exists(entry.destination)then local removed,remove_err=checked_remove(fs,entry.destination);if not removed then errors[#errors+1]=entry.destination.." (cannot remove new file: "..tostring(remove_err)..")" end end
        if not fs.exists(entry.destination)then local ok,err=fs.rename(entry.backup,entry.destination);if not ok then errors[#errors+1]=entry.destination.." (backup remains "..entry.backup..": "..tostring(err)..")"end end
      elseif not fs.exists(entry.destination)then errors[#errors+1]=entry.destination.." (destination and backup are both absent)"end
    elseif entry.had_old then
      if not fs.exists(entry.destination)then errors[#errors+1]=entry.destination.." (destination is absent and no transaction-owned backup was recorded)"end
    elseif fs.exists(entry.destination)then local ok,err=checked_remove(fs,entry.destination);if not ok then errors[#errors+1]=entry.destination.." (new file removal failed: "..tostring(err)..")"end end
  end
  if #errors>0 then return nil,"rollback incomplete; unresolved paths: "..table.concat(errors,"; ")end
  return true
end
Transaction.rollback=rollback
local function remove_temporary(fs,temporary,prefix)
  local removed,remove_err=checked_remove(fs,temporary)
  if not removed then return nil,prefix..": "..tostring(remove_err).."; path "..temporary end
  return true
end
function Transaction.recover(fs,journal_path)
  local temporary=journal_temp(journal_path)
  if not fs.exists(journal_path)then
    if fs.exists(temporary)then return remove_temporary(fs,temporary,"unpublished temporary journal could not be removed")end
    return true
  end
  local journal,err=read_journal(fs,journal_path)
  if not journal then
    local retained=fs.exists(temporary)and("; temporary journal retained at "..temporary)or""
    return nil,err.."; recovery artifact retained at "..journal_path..retained
  end
  if journal.phase=="committed"then
    for _,entry in ipairs(journal.entries)do
      local backup_exists,inspect_err=observe_exists(fs,entry.backup)
      if backup_exists==nil then return nil,"cannot inspect committed backup path "..entry.backup..": "..tostring(inspect_err).."; journal retained at "..journal_path end
      if backup_exists and not entry.backup_owned then return nil,"committed transaction has unowned backup retained at "..entry.backup.."; journal retained at "..journal_path end
    end
  end
  if journal.phase=="installing"then
    local ok,rollback_err=rollback(fs,journal)
    if not ok then
      local retained=fs.exists(temporary)and("; temporary journal retained at "..temporary)or""
      return nil,rollback_err.."; journal retained at "..journal_path..retained
    end
  end
  local removed,remove_err=checked_remove(fs,journal_path)
  if not removed then return nil,"transaction resolved but journal could not be removed: "..tostring(remove_err).."; path "..journal_path end
  return remove_temporary(fs,temporary,"transaction resolved but temporary journal could not be removed")
end
local function failed_commit(fs,journal_path,temporary,original)
  local journal,journal_err=read_journal(fs,journal_path)
  if not journal then
    local temp_detail=fs.exists(temporary)and("; temporary journal retained at "..temporary)or""
    return nil,original.."; cannot read durable rollback authority: "..tostring(journal_err).."; recovery artifacts retained at "..journal_path..temp_detail
  end
  if journal.phase~="installing"then return nil,original.."; durable journal is not in installing phase; recovery artifacts retained at "..journal_path end
  local rolled,rollback_err=rollback(fs,journal)
  if not rolled then
    local temp_detail=fs.exists(temporary)and("; temporary journal retained at "..temporary)or""
    return nil,original.."; "..rollback_err.."; recovery journal and backups retained at "..journal_path..temp_detail
  end
  local removed,remove_err=checked_remove(fs,journal_path)
  if not removed then return nil,original.."; prior file set restored but recovery journal remains at "..journal_path..": "..tostring(remove_err)end
  removed,remove_err=checked_remove(fs,temporary)
  if not removed then return nil,original.."; prior file set restored but temporary journal remains at "..temporary..": "..tostring(remove_err)end
  return nil,original.."; prior file set was fully restored"
end
function Transaction.install(options)
  local fs,fetch=assert(options.fs),assert(options.fetch);local root=assert(options.root)
  local journal_path=options.journal or join(root,".gtnh-bees-install.journal")
  local temporary=journal_temp(journal_path)
  local root_directory,root_err=observe_directory(fs,root)
  if not root_directory then return nil,"cannot use install root: "..tostring(root_err or("directory does not exist: "..root))end
  local recovered,recover_err=Transaction.recover(fs,journal_path);if not recovered then return nil,recover_err end
  local token=tostring((options.now or os.time)());local stage_root=join(root,".gtnh-bees-stage-"..token);local backup_root=join(root,".gtnh-bees-backup-"..token)
  local fresh,fresh_err=require_fresh_path(fs,stage_root);if not fresh then return nil,"cannot create stage: "..tostring(fresh_err)end
  fresh,fresh_err=require_fresh_path(fs,backup_root);if not fresh then return nil,"cannot create backup: "..tostring(fresh_err)end
  local made,make_err=create_fresh_directory(fs,stage_root);if not made then return nil,"cannot create stage: "..tostring(make_err)end
  made,make_err=create_fresh_directory(fs,backup_root);if not made then return nil,"cannot create backup: "..tostring(make_err).."; staging retained at "..stage_root end
  local entries={}
  for _,item in ipairs(options.manifest)do
    local staged,destination,backup=join(stage_root,item.path),join(root,item.path),join(backup_root,item.path)
    local components,path_err=relative_components(item.path)
    if not components then return nil,"invalid transaction path "..tostring(item.path)..": "..tostring(path_err)end
    entries[#entries+1]={destination=destination,staged=staged,backup=backup,item=item,backup_owned=false}
  end
  for _,entry in ipairs(entries)do
    local ok,err=ensure_relative_parent(fs,stage_root,entry.item.path)
    if not ok then return nil,"cannot create staging parent for "..entry.item.path..": "..tostring(err).."; staging retained at "..stage_root end
  end
  for _,entry in ipairs(entries)do
    local ok,err=ensure_relative_parent(fs,backup_root,entry.item.path)
    if not ok then return nil,"cannot create backup parent for "..entry.item.path..": "..tostring(err).."; staging retained at "..stage_root end
  end
  local journal_relative,journal_root_err=relative_to_root(root,journal_path)
  if not journal_relative then return nil,"cannot prepare install journal path: "..tostring(journal_root_err).."; staging retained at "..stage_root end
  made,make_err=ensure_relative_parent(fs,root,journal_relative)
  if not made then return nil,"cannot create journal parent: "..tostring(make_err).."; staging retained at "..stage_root end
  for _,entry in ipairs(entries)do
    local ok,err=ensure_relative_parent(fs,root,entry.item.path)
    if not ok then return nil,"cannot create destination parent for "..entry.item.path..": "..tostring(err).."; staging retained at "..stage_root end
  end
  for _,entry in ipairs(entries)do
    local item=entry.item
    local ok,err=fetch(item.url,entry.staged,item)
    if not ok then return nil,"download failed for "..item.path..": "..tostring(err).."; staging retained at "..stage_root end
    local destination_exists,inspect_err=observe_exists(fs,entry.destination)
    if destination_exists==nil then return nil,"cannot inspect destination for "..item.path..": "..tostring(inspect_err).."; staging retained at "..stage_root end
    entry.had_old=destination_exists
    entry.item=nil
  end
  local journal={phase="installing",entries=entries};local recorded,journal_err=write_journal(fs,journal_path,journal)
  if not recorded then return nil,"cannot record install transaction: "..tostring(journal_err).."; staging retained at "..stage_root.."; temporary journal path "..temporary end
  for _,entry in ipairs(entries)do
    if entry.had_old then
      local backup_exists,inspect_err=observe_exists(fs,entry.backup)
      if backup_exists==nil then return failed_commit(fs,journal_path,temporary,"cannot inspect backup path "..entry.backup..": "..tostring(inspect_err))end
      if backup_exists then return failed_commit(fs,journal_path,temporary,"refusing unowned backup already present at "..entry.backup)end
      entry.backup_owned=true
      local owned,ownership_err=write_journal(fs,journal_path,journal)
      if not owned then return failed_commit(fs,journal_path,temporary,"cannot record durable backup ownership for "..entry.backup..": "..tostring(ownership_err))end
      local ok,err=fs.rename(entry.destination,entry.backup)
      if not ok then return failed_commit(fs,journal_path,temporary,"cannot back up "..entry.destination..": "..tostring(err))end
    end
    local ok,err=fs.rename(entry.staged,entry.destination);if not ok then return failed_commit(fs,journal_path,temporary,"cannot install "..entry.destination..": "..tostring(err))end
  end
  journal.phase="committed";local committed,commit_err=write_journal(fs,journal_path,journal)
  if not committed then return failed_commit(fs,journal_path,temporary,"cannot commit install journal: "..tostring(commit_err))end
  local removed,remove_err=checked_remove(fs,journal_path);if not removed then return nil,"new release installed but committed journal remains at "..journal_path..": "..tostring(remove_err)end
  checked_remove(fs,stage_root)
  return true,backup_root
end
return Transaction
