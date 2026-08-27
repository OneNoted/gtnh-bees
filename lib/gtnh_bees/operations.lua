local Catalog = require("gtnh_bees.catalog")
local Inventory = require("gtnh_bees.inventory")
local Planner = require("gtnh_bees.planner")
local util = require("gtnh_bees.util")

local Operations = {}
Operations.__index = Operations
local default_limits = {progress=512, archive=256, conversion=128, conversion_generations=8, imprint=128, mutation_generations=8}

function Operations.new(adapter, options)
  options = options or {}
  assert(options.limits==nil or type(options.limits)=="table","operation limits must be a table of finite positive integers")
  local archive_size=options.archive_size or 32
  assert(util.finite_integer(archive_size,32),"archive_size must be a finite integer of at least 32")
  local limits=util.merge(default_limits,options.limits)
  for name,value in pairs(limits)do assert(util.finite_integer(value,1),"limit '"..tostring(name).."' must be a finite positive integer")end
  return setmetatable({adapter=assert(adapter),archive_size=archive_size,limits=limits,pause=options.pause or function()end,notify=options.notify or function()end,safety_state="not_started"},Operations)
end

local schemas={
  scanning={"complete","identity","location","scanned"},
  breeding={"complete","uid","location","outputs"},
  archive={"complete","uid","location","outputs"},
  conversion={"complete","uid","princess_identity","location"},
  imprint={"complete","uid","scanned","template_retained","location"}
}

local function result(value,operation)
  if type(value)~="table" then return nil,operation.." returned a malformed result (table required)" end
  if value.safe~=true then return nil,operation.." lacks safe=true; retained bee location is not proven: "..tostring(value.error or value.location or "unknown") end
  local schema=schemas[operation]
  if not schema then return nil,"internal result schema is missing for "..operation end
  for _,field in ipairs(schema) do if value[field]==nil then return nil,operation.." result is missing required field '"..field.."'" end end
  if type(value.complete)~="boolean" then return nil,operation.." result has malformed completion state" end
  if value.location~="bee_storage" then return nil,operation.." result does not prove return to configured bee_storage" end
  if operation=="scanning" then
    if type(value.identity)~="table" or type(value.identity.caste)~="string" or value.identity.active==nil or value.identity.inactive==nil or type(value.scanned)~="boolean" then
      return nil,"scanning result has malformed identity evidence"
    end
  elseif operation=="breeding" or operation=="archive" then
    if type(value.uid)~="string" or type(value.outputs)~="table" then return nil,operation.." result has malformed target/output identity evidence" end
    local valid_failure=value.route_failure==nil or value.route_failure=="deterministic" or(operation=="breeding"and value.route_failure=="transient")
    if not valid_failure then return nil,operation.." result has malformed route-failure classification" end
  elseif operation=="conversion" then
    if type(value.uid)~="string" or type(value.princess_identity)~="string" then return nil,"conversion result has malformed identity evidence" end
    if value.route_failure~=nil and value.route_failure~="deterministic" then return nil,"conversion result has malformed route-failure classification" end
  elseif operation=="imprint" then
    if type(value.uid)~="string" or type(value.scanned)~="boolean" or type(value.template_retained)~="boolean" then return nil,"imprint result has malformed identity evidence" end
    if value.route_failure~=nil and value.route_failure~="deterministic" then return nil,"imprint result has malformed route-failure classification" end
  end
  return value
end

function Operations:recover()
  self.safety_state="unknown"
  local recovered,err=self.adapter:recover_pending()
  if not recovered then return nil,"machine-output recovery failed; run stopped safely: "..tostring(err) end
  return recovered
end

function Operations:reconcile(scan)
  if scan and self.adapter.prepare_storage then
    self.safety_state="unknown"
    local prepared,prepare_err=self.adapter:prepare_storage()
    if not prepared then return nil,"storage analysis failed; run stopped safely: "..tostring(prepare_err) end
  end
  local snapshot,err=self.adapter:snapshot_storage()
  if not snapshot then return nil,"bee-storage inventory failed: "..tostring(err) end
  if not util.finite_integer(snapshot.size,1)or not util.finite_integer(snapshot.reserved_slot,1,snapshot.size)then return nil,"bee-storage inventory returned a non-finite size or reserved slot"end
  self.safety_state="known_safe"
  if not scan then return snapshot end
  for _=1,snapshot.size do
    local selected
    for _,bee in ipairs(snapshot.bees) do if bee.slot~=snapshot.reserved_slot and not bee.scanned then selected=bee;break end end
    if not selected then return snapshot end
    self.safety_state="unknown"
    local scanned,scan_err=self.adapter:scan_bee(selected)
    if not scanned then return nil,"scanning "..selected.active.." from bee_storage slot "..selected.slot.." failed; run stopped safely: "..tostring(scan_err) end
    local safe,safe_err=result(scanned,"scanning")
    if not safe then return nil,safe_err end
    if not safe.complete then return nil,"scanning did not complete: "..tostring(safe.error or "finite scanner budget reached") end
    if safe.identity.caste~=selected.caste or safe.identity.active~=selected.active or safe.identity.inactive~=selected.inactive then return nil,"scanner output identity does not match its input; output location: "..safe.location end
    snapshot,err=self.adapter:snapshot_storage()
    if not snapshot then return nil,"post-scan reconciliation failed: "..tostring(err) end
    self.safety_state="known_safe"
  end
  return nil,"scanning did not converge within the physical storage-slot bound"
end

function Operations:catalog() return Catalog.discover(self.adapter) end
local function completed_uids(state)local out={} for uid in pairs(state.completed)do out[#out+1]=uid end table.sort(out)return out end
local function archive_count(snapshot,uid)
  local count,err=Inventory.pure_drone_count(snapshot,uid)
  if not count then return nil,"archive count for "..uid.." is invalid: "..tostring(err)end
  return count
end

local function completed_archives(snapshot,minimum)
  local candidates={}
  for _,bee in ipairs(snapshot.bees or{})do
    if bee.slot~=snapshot.reserved_slot and Inventory.is_pure_drone(bee)then candidates[bee.active]=true end
  end
  local completed={}
  for _,uid in ipairs(util.sorted_keys(candidates))do
    local count,count_err=archive_count(snapshot,uid)
    if not count then return nil,count_err end
    if count>=minimum then completed[#completed+1]=uid end
  end
  return completed
end

function Operations:archive(uid,target)
  target=target or self.archive_size
  if not util.finite_integer(target,self.archive_size)then return nil,"archive target must be a finite integer at least as large as archive_size"end
  for generation=1,self.limits.archive do
    local snapshot,err=self:reconcile(false);if not snapshot then return nil,err end
    local count,count_err=archive_count(snapshot,uid);if not count then return nil,count_err end
    if count>=target then return {uid=uid,count=count,generations=generation-1} end
    local princess,drone=Inventory.population_pair(snapshot,uid)
    if not princess then return nil,drone end
    self.safety_state="unknown"
    local produced,produce_err=self.adapter:expand_archive(uid,target,princess,drone)
    if not produced then return nil,"archive generation for "..uid.." failed; run stopped safely: "..tostring(produce_err) end
    local safe,safe_err=result(produced,"archive");if not safe then return nil,safe_err end
    if safe.uid~=uid then return nil,"archive result target identity does not match "..uid end
    if not safe.complete then return nil,"archive generation did not complete: "..tostring(safe.error or "finite breeder budget reached") end
  end
  return nil,"archive for "..uid.." exceeded "..self.limits.archive.." generations"
end

local function prepare_mutation_surplus(self,step,snapshot)
  if self.adapter.requires_mutation_surplus~=true then return true end
  local uid=step.orientation.drone
  local spendable=Inventory.spendable_drone(snapshot,uid,self.archive_size)
  if spendable then return true end
  local count,count_err=archive_count(snapshot,uid)
  if not count then return nil,count_err end
  if count~=self.archive_size then return true end
  local princess=Inventory.population_pair(snapshot,uid)
  if not princess then return true end
  local prepared,prepare_err=self:archive(uid,self.archive_size+1)
  if not prepared then return nil,"could not prepare surplus mutation stock for "..uid..": "..tostring(prepare_err)end
  return true
end

local function same_princess(a,b)
  return a and b and a.caste=="princess" and b.caste=="princess" and a.active==b.active and a.inactive==b.inactive and Inventory.genome_equal(a,b)
end

local function retained_princess(snapshot,evidence)
  if type(evidence)~="table" or evidence.inventory~="bee_storage" or not util.finite_integer(evidence.slot,1)
    or evidence.slot>snapshot.size or evidence.slot==snapshot.reserved_slot then
    return nil,"retained princess evidence lacks an exact ordinary bee_storage slot"
  end
  if evidence.caste~="princess" or evidence.size~=1 then return nil,"retained princess evidence is not one physical princess" end
  local matched
  for _,bee in ipairs(snapshot.bees or {})do
    if bee.slot==evidence.slot then
      if matched then return nil,"retained princess evidence maps to more than one storage record" end
      matched=bee
    end
  end
  if not matched or matched.inventory~="bee_storage" or matched.size~=1 or not same_princess(matched,evidence)then
    return nil,"retained princess evidence does not match the exact returned bee_storage slot"
  end
  return matched
end

function Operations:optional_imprint(uid)
  local current
  for generation=1,self.limits.imprint do
    local snapshot,snapshot_err=self:reconcile(false)
    if not snapshot then return nil,snapshot_err,false end
    local template,template_err=Inventory.template(snapshot)
    if not template then return nil,template_err,true end
    if current then
      local lineage_err
      current,lineage_err=retained_princess(snapshot,current)
      if not current then return nil,"imprint target princess can no longer be identified in ordinary storage: "..tostring(lineage_err),false end
    else
      local princesses=Inventory.find(snapshot,function(bee)return bee.caste=="princess" and bee.active==uid end)
      current=princesses[1]
    end
    local donors=Inventory.find(snapshot,function(bee)return bee.caste=="drone" and Inventory.genome_equal(bee,template) end)
    local donor
    local archive_counts={}
    for _,candidate in ipairs(donors)do
      if Inventory.is_pure_drone(candidate)then
        local count=archive_counts[candidate.active]
        if count==nil then
          local count_err
          count,count_err=archive_count(snapshot,candidate.active)
          if not count then return nil,count_err,false end
          archive_counts[candidate.active]=count
        end
        local at_archive_minimum=count==self.archive_size
        if not at_archive_minimum then donor=candidate;break end
      else donor=candidate;break end
    end
    if not current then return nil,"no eligible ordinary target princess for "..uid,true end
    if not donor then
      local detail=#donors>0 and "; matching drones are protected archive stock with no surplus" or "; reserved template was not moved"
      return nil,"no eligible ordinary template-equivalent donor drone for "..uid..detail,true
    end
    self.safety_state="unknown"
    local value,err=self.adapter:imprint_one(uid,template,current,donor)
    if not value then return nil,"imprint for "..uid.." returned no safety attestation: "..tostring(err),false end
    local safe,safe_err=result(value,"imprint")
    if not safe then return nil,safe_err,false end
    if safe.uid~=uid then return nil,"imprint result target identity does not match "..uid,false end
    local after,after_err=self:reconcile(false)
    if not after then return nil,after_err,false end
    local retained,retained_err=Inventory.template(after)
    if not retained then return nil,"reserved template was not retained: "..retained_err,false end
    if retained.active~=template.active or retained.inactive~=template.inactive or not Inventory.genome_equal(retained,template) or safe.template_retained~=true then
      return nil,"reserved template identity changed; imprint stopped",false
    end
    if safe.complete and safe.scanned then return {uid=uid,generations=generation,safe=true},nil,true end
    local lineage_err
    current,lineage_err=retained_princess(after,safe.retained_princess)
    if not current then return nil,"safe incomplete imprint did not identify its retained target princess in ordinary storage: "..tostring(lineage_err),false end
    if safe.route_failure=="deterministic" then return nil,safe.error or "imprint grading failed deterministically after safe storage",true end
  end
  return nil,"imprint for "..uid.." exceeded "..self.limits.imprint.." generations",true
end

local function exclusion(exclusions,uid,key,reason)
  exclusions[uid]=exclusions[uid] or {};exclusions[uid][key]=reason or true
end

function Operations:convert_source(uid,princess)
  local current=princess
  for generation=1,self.limits.conversion_generations do
    local snapshot,snapshot_err=self:reconcile(false)
    if not snapshot then return nil,snapshot_err,"fatal" end
    local located,location_err=retained_princess(snapshot,current)
    if not located then return nil,"conversion source princess can no longer be identified in ordinary storage: "..tostring(location_err),"fatal" end
    current=located
    local drone,drone_err=Inventory.spendable_drone(snapshot,uid,self.archive_size)
    if not drone then return nil,"conversion source drone unavailable after "..(generation-1).." generation(s): "..tostring(drone_err),"exhausted" end
    local source_identity=current.active
    self.safety_state="unknown"
    local value,err=self.adapter:convert_one(uid,current,drone)
    if not value then return nil,"conversion to "..uid.." returned no safety attestation: "..tostring(err),"fatal" end
    local safe,safe_err=result(value,"conversion")
    if not safe then return nil,safe_err,"fatal" end
    if safe.uid~=uid or safe.princess_identity~=source_identity then return nil,"conversion result identity does not match its requested target and source princess","fatal" end
    if safe.complete then return {generations=generation,result=safe} end
    local refreshed,refresh_err=self:reconcile(false)
    if not refreshed then return nil,refresh_err,"fatal" end
    current,refresh_err=retained_princess(refreshed,safe.retained_princess)
    if not current then return nil,"safe incomplete conversion did not identify its retained source princess in ordinary storage: "..tostring(refresh_err),"fatal" end
    if safe.route_failure=="deterministic" then
      return nil,safe.error or "conversion route failed deterministically after safe storage","deterministic"
    end
    if generation==self.limits.conversion_generations then
      return nil,"safe conversion misses exhausted "..self.limits.conversion_generations.." configured generations for one source princess: "..tostring(safe.error or "target princess not observed"),"exhausted"
    end
  end
  return nil,"conversion generation budget was exhausted","exhausted"
end

function Operations:prepare_conversion(uid,snapshot)
  local drone,drone_err=Inventory.spendable_drone(snapshot,uid,self.archive_size)
  local princesses=Inventory.find(snapshot,function(bee)return bee.caste=="princess" and bee.active~=uid end)
  if not drone then return nil,"conversion preparation has no spendable source drone for "..uid..": "..tostring(drone_err),"exhausted" end
  if not princesses[1] then return nil,"conversion preparation has no alternate princess" end
  local converted,conversion_err,classification=self:convert_source(uid,princesses[1])
  if not converted then return nil,"conversion preparation did not complete: "..tostring(conversion_err),classification end
  return converted
end

local function breeding_attempt(value,err,step)
  if value==nil then return nil,"breeding route returned no safety attestation: "..tostring(err),"fatal" end
  local checked,check_err=result(value,"breeding")
  if not checked then return nil,check_err,"fatal" end
  if checked.uid~=step.uid then return nil,"breeding result target identity does not match "..step.uid,"fatal" end
  if checked.complete then return checked,nil,"complete" end
  if checked.route_failure=="deterministic" then return checked,checked.error or "route failed deterministically after safe storage","deterministic" end
  return checked,checked.error or "requested mutation was not observed after safe storage","miss"
end

local function route_attempt_key(step)
  return step.uid.."\0"..step.route.key
end

function Operations:complete(options)
  options=options or {}
  local recovered,recover_err=self:recover()
  if not recovered then return nil,recover_err end
  local startup,startup_err=self:reconcile(true)
  if not startup then return nil,startup_err end
  local catalog,catalog_err=self:catalog()
  if not catalog then return nil,catalog_err end
  local state=Planner.fixed_targets(Planner.reachable(catalog,Inventory.roles(startup)))
  local imprint_reports,blocked,exclusions,route_attempts={},{},{},{}
  local pending_imprints,pending_seen={},{}
  local labels={}
  for uid in pairs(state.targets)do labels[uid]=catalog:label(uid)end

  local function reconcile_archives()
    local snapshot,snapshot_err=self:reconcile(false)
    if not snapshot then return nil,snapshot_err end
    for uid in pairs(state.targets)do
      local count,count_err=archive_count(snapshot,uid);if not count then return nil,count_err end
      if count>=self.archive_size then state:complete(uid)else state:reopen(uid)end
    end
    return snapshot
  end

  local function queue_completed_imprints()
    if options.imprint=="none" then return true end
    for _,uid in ipairs(completed_uids(state)) do
      if not pending_seen[uid] then
        pending_seen[uid]=true
        pending_imprints[#pending_imprints+1]=uid
      end
    end
    return true
  end

  local function imprint_completed()
    queue_completed_imprints()
    for _,uid in ipairs(pending_imprints)do
      local value,imprint_err,safe_miss=self:optional_imprint(uid)
      if not value and safe_miss~=true then return nil,"optional imprint for "..uid.." became unsafe: "..tostring(imprint_err) end
      imprint_reports[#imprint_reports+1]={uid=uid,ok=value~=nil,safe=true,error=imprint_err}
    end
    return true
  end

  for _=1,self.limits.progress do
    local snapshot,snapshot_err=reconcile_archives()
    if not snapshot then return nil,snapshot_err end
    queue_completed_imprints()
    local missing=state:missing()
    if #missing==0 then
      local imprinted,imprint_err=imprint_completed()
      if not imprinted then return nil,imprint_err end
      return {operation="complete",success=true,recovered=#recovered,completed=completed_uids(state),missing={},labels=labels,imprints=imprint_reports}
    end
    local selected
    for _,item in ipairs(missing)do if not blocked[item.uid]then selected=item.uid;break end end
    if not selected then break end

    local before,before_err=archive_count(snapshot,selected);if not before then return nil,before_err end
    local roles=Inventory.roles(snapshot)
    local ok,action_err,archive_attempt
    if roles.population[selected] then
      archive_attempt=true
      ok,action_err=self:archive(selected)
      if not ok then blocked[selected]=true;state:fail(selected,tostring(action_err)) end
    else
      local steps,dependency_err=Planner.dependencies(catalog,selected,roles,exclusions)
      if not steps or #steps==0 then
        blocked[selected]=true
        state:fail(selected,tostring(dependency_err or "all deterministic routes were exhausted"))
      else
        local step=steps[1]
        if step.kind=="convert" then
          local classification
          ok,action_err,classification=self:prepare_conversion(step.uid,snapshot)
          if not ok then
            if classification=="deterministic" then exclusion(exclusions,step.uid,"conversion",action_err)
            elseif classification=="exhausted" then blocked[selected]=true;state:fail(selected,action_err)
            else return nil,action_err end
          end
        else
          local prepared,prepare_err=prepare_mutation_surplus(self,step,snapshot)
          if not prepared then return nil,prepare_err end
          self.safety_state="unknown"
          local produced,produce_err=self.adapter:produce_species(step,self.archive_size)
          local checked,classification
          checked,action_err,classification=breeding_attempt(produced,produce_err,step)
          if classification=="fatal" then return nil,action_err
          elseif classification=="complete" then ok=checked
          elseif classification=="deterministic" then exclusion(exclusions,step.uid,step.route.key,action_err)
          else
            local key=route_attempt_key(step)
            route_attempts[key]=(route_attempts[key] or 0)+1
            if route_attempts[key]>=self.limits.mutation_generations then
              exclusion(exclusions,step.uid,step.route.key,"safe mutation misses exhausted "..self.limits.mutation_generations.." configured generations: "..tostring(action_err))
            end
          end
        end
      end
    end

    if ok then
      local refreshed,refresh_err=self:reconcile(false)
      if not refreshed then return nil,refresh_err end
      local after_count,after_count_err=archive_count(refreshed,selected);if not after_count then return nil,after_count_err end
      if after_count>=self.archive_size then state:complete(selected)
      elseif archive_attempt and after_count<=before then
        blocked[selected]=true
        state:fail(selected,"archive cycle made no observable pure-drone progress")
      end
    end
  end
  local final_snapshot,final_snapshot_err=reconcile_archives()
  if not final_snapshot then return nil,final_snapshot_err end
  local missing=state:missing()
  if #missing==0 then
    local imprinted,imprint_err=imprint_completed()
    if not imprinted then return nil,imprint_err end
    return {operation="complete",success=true,recovered=#recovered,completed=completed_uids(state),missing={},labels=labels,imprints=imprint_reports}
  end
  return {operation="complete",success=false,recovered=#recovered,completed=completed_uids(state),missing=missing,labels=labels,imprints=imprint_reports,stopped="no safe progress remains",error="complete stopped with "..#missing.." reachable archive(s) still missing; see missing diagnostics"}
end

local function should_imprint(mode,is_target)if mode=="all"then return true elseif mode=="target"then return is_target elseif mode=="intermediate"then return not is_target end return false end

function Operations:breed(command)
  local recovered,recover_err=self:recover()
  if not recovered then return nil,recover_err end
  local snapshot,snapshot_err=self:reconcile(true)
  if not snapshot then return nil,snapshot_err end
  local catalog,catalog_err=self:catalog()
  if not catalog then return nil,catalog_err end
  local target,resolve_err=catalog:resolve(command.species)
  if not target then return nil,resolve_err end
  local protected_archives,protected_err=completed_archives(snapshot,self.archive_size)
  if not protected_archives then return nil,protected_err end
  local produced,produced_seen,imprints,exclusions,route_attempts={},{},{},{},{}
  local pending_imprints,pending_seen={},{}

  local function after_production(uid)
    if not produced_seen[uid] then
      produced_seen[uid]=true
      produced[#produced+1]=uid
      if should_imprint(command.imprint,uid==target) and not pending_seen[uid] then
        pending_seen[uid]=true
        pending_imprints[#pending_imprints+1]=uid
      end
      if command.pause then self.pause(uid,catalog:label(uid)) end
    end
    return true
  end

  local ready=false
  for _=1,self.limits.progress do
    snapshot,snapshot_err=self:reconcile(false)
    if not snapshot then return nil,snapshot_err end
    local roles=Inventory.roles(snapshot)
    if roles.population[target] then ready=true;break end
    local steps,route_err=Planner.dependencies(catalog,target,roles,exclusions)
    if not steps or #steps==0 then return nil,"breed "..target.." cannot continue: "..tostring(route_err) end
    local step=steps[1]
    local checked,check_err
    if step.kind=="convert" then
      local classification
      checked,check_err,classification=self:prepare_conversion(step.uid,snapshot)
      if not checked then
        if classification=="deterministic" then exclusion(exclusions,step.uid,"conversion",check_err)
        elseif classification=="exhausted" then return nil,"breed "..target.." cannot continue: "..tostring(check_err)
        else return nil,check_err end
      else
        local continued,continue_err=after_production(step.uid)
        if not continued then return nil,continue_err end
      end
    else
      local prepared,prepare_err=prepare_mutation_surplus(self,step,snapshot)
      if not prepared then return nil,prepare_err end
      self.safety_state="unknown"
      local value,err=self.adapter:produce_species(step,self.archive_size)
      local classification
      checked,check_err,classification=breeding_attempt(value,err,step)
      if classification=="fatal" then return nil,check_err
      elseif classification=="deterministic" then exclusion(exclusions,step.uid,step.route.key,check_err)
      elseif classification=="miss" then
        local key=route_attempt_key(step)
        route_attempts[key]=(route_attempts[key] or 0)+1
        if route_attempts[key]>=self.limits.mutation_generations then
          exclusion(exclusions,step.uid,step.route.key,"safe mutation misses exhausted "..self.limits.mutation_generations.." configured generations: "..tostring(check_err))
        end
      else
        local continued,continue_err=after_production(step.uid)
        if not continued then return nil,continue_err end
      end
    end
  end
  if not ready then
    snapshot,snapshot_err=self:reconcile(false)
    if not snapshot then return nil,snapshot_err end
    local roles=Inventory.roles(snapshot)
    if not roles.population[target] then return nil,"breed "..target.." reached its finite progress bound before full-genome-compatible physical target stock was ready" end
  end

  local archived,archive_err=self:archive(target)
  if not archived then return nil,"breed "..target.." produced stock but archive completion stopped: "..archive_err end
  for _,uid in ipairs(protected_archives)do
    local restored,restore_err=self:archive(uid)
    if not restored then return nil,"breed "..target.." could not restore protected archive "..uid..": "..tostring(restore_err)end
  end
  if should_imprint(command.imprint,true) and not pending_seen[target] then
    pending_seen[target]=true
    pending_imprints[#pending_imprints+1]=target
  end
  for _,uid in ipairs(pending_imprints)do
    local value,imprint_err,safe_miss=self:optional_imprint(uid)
    if not value and safe_miss~=true then return nil,"imprint for "..uid.." became unsafe: "..tostring(imprint_err) end
    imprints[#imprints+1]={uid=uid,ok=value~=nil,safe=true,error=imprint_err}
  end
  local failures={}
  for _,item in ipairs(imprints)do if not item.ok then failures[#failures+1]=item.uid..": "..tostring(item.error) end end
  return {operation="breed",success=#failures==0,uid=target,label=catalog:label(target),produced=produced,archive=archived,imprints=imprints,error=#failures>0 and ("requested imprint failed after safe storage: "..table.concat(failures,"; ")) or nil}
end

function Operations:convert(command)
  local recovered,recover_err=self:recover()
  if not recovered then return nil,recover_err end
  local snapshot,snapshot_err=self:reconcile(true)
  if not snapshot then return nil,snapshot_err end
  local catalog,catalog_err=self:catalog()
  if not catalog then return nil,catalog_err end
  local uid,resolve_err=catalog:resolve(command.species)
  if not uid then return nil,resolve_err end
  local requested=command.all and self.limits.conversion or command.count
  if not command.all and not util.finite_integer(requested,1) then return nil,"conversion count must be a finite positive integer" end
  local converted,reason=0,nil
  for _=1,self.limits.conversion do
    if not command.all and converted>=requested then break end
    snapshot,snapshot_err=self:reconcile(false)
    if not snapshot then return nil,snapshot_err end
    local princesses=Inventory.find(snapshot,function(bee)return bee.caste=="princess" and bee.active~=uid end)
    local drones=Inventory.find(snapshot,function(bee)return bee.caste=="drone" and bee.active==uid end)
    if not princesses[1] then reason="no eligible princesses remain";break end
    if not drones[1] then reason="source drones depleted";break end
    local value,err,classification=self:convert_source(uid,princesses[1])
    if not value then
      if classification=="fatal" then return nil,err end
      reason=err
      break
    end
    converted=converted+1
  end

  if command.all and reason==nil then
    snapshot,snapshot_err=self:reconcile(false)
    if not snapshot then return nil,snapshot_err end
    local princesses=Inventory.find(snapshot,function(bee)return bee.caste=="princess" and bee.active~=uid end)
    if not princesses[1] then reason="no eligible princesses remain" else reason="generation budget reached before every eligible princess was converted" end
  elseif not command.all and converted<requested and reason==nil then
    reason="generation budget reached before requested count"
  end
  local success=(command.all and reason=="no eligible princesses remain") or (not command.all and converted==requested)
  local requested_label=command.all and "all" or requested
  return {operation="convert",success=success,uid=uid,requested=requested_label,converted=converted,stopped=reason,error=not success and ("converted "..converted.." of "..tostring(requested_label)..": "..tostring(reason)) or nil}
end

function Operations:imprint(command)
  local recovered,recover_err=self:recover();if not recovered then return nil,recover_err end
  local snapshot,snapshot_err=self:reconcile(true);if not snapshot then return nil,snapshot_err end
  local template,template_err=Inventory.template(snapshot);if not template then return nil,"imprint rejected: "..template_err end
  local catalog,catalog_err=self:catalog();if not catalog then return nil,catalog_err end
  local targets={}
  if command.species then local uid,resolve_err=catalog:resolve(command.species);if not uid then return nil,resolve_err end targets[1]=uid
  else local seen={} for _,bee in ipairs(snapshot.bees)do if bee.slot~=snapshot.reserved_slot and bee.caste=="princess" and not seen[bee.active]then seen[bee.active]=true;targets[#targets+1]=bee.active end end table.sort(targets) end
  local results,failures={},{}
  for _,uid in ipairs(targets)do
    local value,err,safe_miss=self:optional_imprint(uid)
    if not value and safe_miss~=true then return nil,"imprint for "..uid.." became unsafe: "..tostring(err) end
    local item={uid=uid,ok=value~=nil,safe=true,error=err}
    results[#results+1]=item
    if not item.ok then failures[#failures+1]=uid..": "..tostring(err) end
  end
  return {operation="imprint",success=#failures==0,results=results,error=#failures>0 and ("requested imprint target(s) failed after safe storage: "..table.concat(failures,"; ")) or nil}
end

return Operations
