local Calls = require("gtnh_bees.component_call")
local identity = require("gtnh_bees.identity")
local Inventory = require("gtnh_bees.inventory")
local util = require("gtnh_bees.util")

local M = {}
local COLLECTION_LIMIT = 4096
M.component_methods = {
  genetics={"listAllSpecies", "getBeeBreedingData"},
  scanner={"getIndividualOnDisplay"}
}

-- Temporary local predicate: this branch predates util.finite_integer.
local function finite_integer(value, minimum)
  return type(value)=="number" and value==value and value~=math.huge and value~=-math.huge
    and value==math.floor(value) and (minimum==nil or value>=minimum)
end

local function positive_integer(value)
  return finite_integer(value,1)
end

local function values(value)
  if type(value) ~= "table" or Calls.callable(value) then
    return nil, "official collection is not an OpenComputers-converted array or map"
  end
  local numeric,mapped,maximum=0,0,0
  local map_keys={}
  for key in next,value do
    if type(key)=="number" then
      if not positive_integer(key) then
        return nil,"official collection has a non-positive, fractional, or non-finite numeric key"
      end
      numeric=numeric+1
      if numeric>COLLECTION_LIMIT or key>COLLECTION_LIMIT then
        return nil,"official collection exceeded its finite item bound"
      end
      if key>maximum then maximum=key end
    else
      if type(key)~="string" then return nil,"official collection map keys must be strings" end
      mapped=mapped+1
      if mapped>COLLECTION_LIMIT then return nil,"official collection exceeded its finite item bound" end
      map_keys[#map_keys+1]=key
    end
  end
  if numeric>0 and mapped>0 then return nil,"official collection mixes array and map fields ambiguously" end

  local out={}
  if numeric>0 then
    if maximum~=numeric then return nil,"official collection array is sparse or contains a hole" end
    for index=1,maximum do
      local item=rawget(value,index)
      if item==nil then return nil,"official collection array is sparse or contains a hole" end
      out[#out+1]=item
    end
  else
    table.sort(map_keys)
    for _,key in ipairs(map_keys) do out[#out+1]=rawget(value,key) end
  end
  return out
end

M.normalize_collection = values

local function invoke(adapter, role, method, ...)
  local value, detail = adapter:invoke(role.component_address or role.address, method, ...)
  if value == nil then return nil, detail or (method .. " returned no value") end
  return value, detail
end

function M.list_species(_, role, adapter)
  local raw, err = invoke(adapter, role, "listAllSpecies")
  if not raw then error("official species enumeration failed: " .. tostring(err)) end
  local list, list_err = values(raw)
  if not list then error("official species enumeration failed: " .. list_err) end
  adapter._official_species = list
  return list
end

function M.list_mutations(_, role, adapter)
  local raw, err = invoke(adapter, role, "getBeeBreedingData")
  if not raw then error("official mutation enumeration failed: " .. tostring(err)) end
  local list, list_err = values(raw)
  if not list then error("official mutation enumeration failed: " .. list_err) end
  local species = adapter._official_species or M.list_species(nil, role, adapter)
  local exact_uids, lookup = {}, {}
  local function index(reference, uid)
    if type(reference)~="string" then return end
    local key=util.lower(reference)
    lookup[key]=lookup[key] or {}
    lookup[key][uid]=true
  end
  for _,item in ipairs(species) do
    local uid = type(item)=="table" and item.uid
    local name = type(item)=="table" and item.name
    if type(uid)=="string" then
      exact_uids[uid]=true
      index(uid,uid)
      index(name,uid)
    end
  end
  local function resolve(reference, field, entry)
    if type(reference)=="table" or type(reference)=="userdata" then
      local uid,uid_err=identity.uid(reference)
      if uid and exact_uids[uid] then return uid end
      return nil,"official mutation entry "..entry.." "..field.." explicit UID is absent from the enumerated species: "..tostring(uid_err or uid)
    end
    if type(reference)~="string" then return nil,"official mutation entry "..entry.." "..field.." has no supported species reference" end
    local bucket=lookup[util.lower(reference)] or {}
    local candidates=util.sorted_keys(bucket)
    if #candidates==1 then return candidates[1] end
    if #candidates>1 then
      return nil,"official mutation entry "..entry.." "..field.." reference '"..reference.."' is ambiguous across stable UIDs: "..table.concat(candidates,", ")
    end
    return nil,"official mutation entry "..entry.." "..field.." does not map to an enumerated stable UID"
  end
  local normalized = {}
  for index,item in ipairs(list) do
    if type(item) ~= "table" then error("official mutation entry " .. index .. " is malformed") end
    local a,a_err=resolve(item.allele1,"allele1",index)
    if not a then error(a_err) end
    local b,b_err=resolve(item.allele2,"allele2",index)
    if not b then error(b_err) end
    local result,result_err=resolve(item.result,"result",index)
    if not result then error(result_err) end
    normalized[#normalized+1] = {result=result, parents={a,b}, chance=item.chance, conditions=item.specialConditions}
  end
  return normalized
end

local function configured_caste(raw, context, adapter)
  if context and type(context.caste)=="string" then return util.lower(context.caste) end
  local storage = adapter.config.roles.bee_storage
  local map = storage and storage.caste_items or {}
  return type(raw.name)=="string" and map[raw.name] or nil
end

local function individual_shape(raw)
  if type(raw) ~= "table" then return nil end
  if type(raw.individual)=="table" then return raw.individual end
  if raw.type=="bee" or raw.active or raw.inactive then return raw end
  return nil
end

local function stack_measure(raw,field,default,label)
  local supplied=rawget(raw,field)
  if supplied==nil then return default end
  local value=tonumber(supplied)
  if not positive_integer(value) then return nil,label.." must be a finite positive integer" end
  return value
end

function M.inspect_stack(raw, context, adapter)
  if type(raw) ~= "table" then return nil, "not a bee" end
  local individual = individual_shape(raw)
  if not individual then
    if configured_caste(raw, context, adapter) then return nil, "bee analysis is required" end
    return nil, "item is not in bee_storage.caste_items; dedicated bee storage is required"
  end
  if individual.type and individual.type ~= "bee" then return nil, "not a bee" end
  local caste = configured_caste(raw, context, adapter)
  if not caste then return nil, "bee caste cannot be determined from the configured item mapping" end
  local active, inactive = individual.active, individual.inactive
  if type(active) ~= "table" or type(inactive) ~= "table" or active.species == nil or inactive.species == nil then
    return nil, "analyzed Forestry bee is missing active/inactive species genome fields"
  end
  local active_uid, active_err = identity.uid(active.species)
  if not active_uid then return nil, "analyzed Forestry active species is malformed: " .. tostring(active_err) end
  local inactive_uid, inactive_err = identity.uid(inactive.species)
  if not inactive_uid then return nil, "analyzed Forestry inactive species is malformed: " .. tostring(inactive_err) end
  local size,size_err=stack_measure(raw,"size",1,"bee stack size")
  if not size then return nil,size_err end
  local max_size,max_size_err=stack_measure(raw,"maxSize",64,"bee maximum stack size")
  if not max_size then return nil,max_size_err end
  return {
    caste=caste, active=active_uid, inactive=inactive_uid,
    genome={active=util.copy(active), inactive=util.copy(inactive)},
    scanned=individual.isAnalyzed == true,
    size=size, maxSize=max_size
  }
end

function M.identify_stack(raw, context, adapter)
  if type(raw) ~= "table" then return nil, "not a bee" end
  local caste = configured_caste(raw, context, adapter)
  if not caste then return nil, "item is not in bee_storage.caste_items" end
  local size,size_err=stack_measure(raw,"size",1,"bee stack size")
  if not size then return nil,size_err end
  local max_size,max_size_err=stack_measure(raw,"maxSize",64,"bee maximum stack size")
  if not max_size then return nil,max_size_err end
  if not context or type(context.role)~="string" or not positive_integer(context.slot) then
    return nil,"bee machine location must contain an explicit role and finite positive slot"
  end
  return {caste=caste, size=size, maxSize=max_size,
    inventory=context.role, slot=context.slot, raw=raw}
end

local function unique_slots(role)
  local result, seen = {}, {}
  for _,field in ipairs({"input_slot","princess_slot","drone_slot"}) do local slot=role[field]; if slot and not seen[slot] then result[#result+1],seen[slot]=slot,true end end
  for _,slot in ipairs(role.output_slots or {}) do if not seen[slot] then result[#result+1],seen[slot]=slot,true end end
  return result
end

local function physical_count(raw)
  local count=type(raw)=="table" and tonumber(raw.size or raw.qty) or nil
  if not positive_integer(count) then return nil,"bee stack has no finite positive physical count" end
  return count
end

local function return_raw_one(adapter,role_name,slot,options)
  local raw,read_err=adapter:raw_stack(role_name,slot)
  if read_err then return nil,read_err end
  if not raw then return true end
  local transport,identify_err=M.identify_stack(raw,{role=role_name,slot=slot},adapter)
  if not transport then return nil,identify_err or "item is not an identifiable configured bee" end
  local storage=adapter.config.roles.bee_storage
  local size,size_err=adapter:invoke(storage.address,"getInventorySize",storage.side)
  if not positive_integer(size) then return nil,"cannot observe finite positive bee_storage size while recovering raw bee: "..tostring(size_err) end
  for destination=1,size do
    if destination~=storage.reserved_slot and destination~=(options and options.blocked_storage_slot) then
      local occupied,occupied_err=adapter:raw_stack("bee_storage",destination)
      if occupied_err then return nil,occupied_err end
      if not occupied then
        local moved,move_err=adapter:transfer_verified(role_name,slot,"bee_storage",destination,1)
        if not moved then return nil,move_err end
        return true
      end
    end
  end
  return nil,"no empty ordinary bee_storage slot is available for an unanalyzed retained bee"
end

local function recover_slot(adapter,role_name,slot)
  local raw,read_err=adapter:raw_stack(role_name,slot)
  if read_err then return nil,read_err end
  if not raw then return true end
  local budget,count_err=physical_count(raw)
  if not budget then return nil,count_err end
  for _=1,budget do
    raw,read_err=adapter:raw_stack(role_name,slot)
    if read_err then return nil,read_err end
    if not raw then return true end
    local decoded
    if type(adapter.decode)=="function" then decoded=adapter:decode(raw,{role=role_name,slot=slot}) end
    local ok,err
    if decoded then ok,err=adapter:return_output(role_name,slot,decoded)
    elseif type(adapter.decode)~="function" then ok,err=adapter:return_output(role_name,slot)
    else ok,err=return_raw_one(adapter,role_name,slot) end
    if not ok then return nil,err end
  end
  raw,read_err=adapter:raw_stack(role_name,slot)
  if read_err then return nil,read_err end
  if raw then return nil,"slot did not empty within its observed physical bee count" end
  return true
end

local function restore(adapter, role_name)
  local role = adapter.config.roles[role_name]
  local unresolved = {}
  for _,slot in ipairs(unique_slots(role)) do
    local raw, read_err = adapter:raw_stack(role_name, slot)
    if read_err then unresolved[#unresolved+1]=role_name.." slot "..slot..": "..read_err
    elseif raw then
      local ok, err = recover_slot(adapter,role_name,slot)
      if not ok then unresolved[#unresolved+1]=role_name.." slot "..slot..": "..tostring(err) end
    end
  end
  if #unresolved>0 then return nil, table.concat(unresolved,"; ") end
  return true
end

local function restore_scan_input(adapter, bee, options)
  local role=adapter.config.roles.scanner
  local occupied={}
  for _,slot in ipairs(unique_slots(role)) do
    local raw,read_err=adapter:raw_stack("scanner",slot)
    if read_err then return nil,"scanner slot "..slot..": "..read_err end
    if raw then
      local size,size_err=physical_count(raw)
      if not size then return nil,"scanner slot "..slot..": "..size_err end
      occupied[#occupied+1]={slot=slot,size=size}
    end
  end
  if #occupied~=1 or occupied[1].size~=1 then return nil,"scanner retained an unexpected number of physical outputs" end
  local item=occupied[1]
  if options and options.blocked_storage_slot then
    local returned,return_err=return_raw_one(adapter,"scanner",item.slot,options)
    if not returned then return nil,"scanner slot "..item.slot..": "..tostring(return_err) end
    return true,"bee_storage"
  end
  local moved,move_err=adapter:transfer_verified("scanner",item.slot,bee.inventory or "bee_storage",bee.slot,1)
  if not moved then return nil,"scanner slot "..item.slot..": "..tostring(move_err) end
  local remaining,remaining_err=adapter:raw_stack("scanner",item.slot)
  if remaining_err then return nil,"scanner slot "..item.slot..": "..remaining_err end
  if remaining then return nil,"scanner slot "..item.slot.." was not emptied by safe return" end
  return true,"bee_storage"
end

function M.scan_generation(adapter, bee, limit, options)
  options=options or {}
  if not positive_integer(limit) then return nil,"scanner limit must be a finite positive integer" end
  if type(bee)~="table" or type(bee.inventory)~="string" or not positive_integer(bee.slot) then
    return nil,"scanner request lacks an explicit finite physical source slot"
  end
  local bee_size=tonumber(bee.size or 1)
  if not positive_integer(bee_size) then return nil,"scanner request bee size must be a finite positive integer" end
  if options.blocked_storage_slot~=nil and not positive_integer(options.blocked_storage_slot) then
    return nil,"blocked storage slot must be a finite positive integer"
  end
  if not options.blocked_storage_slot and bee.inventory=="bee_storage" and bee_size>1 then
    options={blocked_storage_slot=bee.slot}
  end
  local role = adapter.config.roles.scanner
  if not role.input_slot or not role.component_address then
    return nil, "scanner needs explicit input_slot, output_slots, and official forestry_analyzer component_address"
  end
  for _,slot in ipairs(unique_slots(role)) do
    local raw, err = adapter:raw_stack("scanner",slot)
    if err then return nil, err end
    if raw then return nil, "scanner slot "..slot.." is occupied; recover it before scanning" end
  end
  local moved, move_err = adapter:transfer_verified(bee.inventory or "bee_storage",bee.slot,"scanner",role.input_slot,1)
  if not moved then return nil, move_err end
  for _=1,limit do
    local individual, invoke_err = adapter:invoke(role.component_address,"getIndividualOnDisplay")
    if invoke_err then
      local safe, location=restore_scan_input(adapter,bee,options)
      if not safe then return {operation="scanning",safe=false,complete=false,error=invoke_err,location=location} end
      return {operation="scanning",safe=true,complete=false,error=invoke_err,identity={caste=bee.caste,active=bee.active,inactive=bee.inactive},location="bee_storage",scanned=false}
    end
    if type(individual)=="table" and individual.isAnalyzed==true then
      for _,slot in ipairs(role.output_slots) do
        local raw, raw_err = adapter:raw_stack("scanner",slot)
        if raw_err then
          local safe, location=restore_scan_input(adapter,bee,options)
          if not safe then return {operation="scanning",safe=false,complete=false,error=raw_err,location=location} end
          return {operation="scanning",safe=true,complete=false,error=raw_err,identity={caste=bee.caste,active=bee.active,inactive=bee.inactive},location="bee_storage",scanned=false}
        end
        if raw then
          local merged=util.copy(raw); merged.individual=individual
          local decoded, decode_err=M.inspect_stack(merged,{role="scanner",slot=slot,caste=bee.caste},adapter)
          if not decoded then
            local safe, location=restore_scan_input(adapter,bee,options)
            if not safe then return {operation="scanning",safe=false,complete=false,error=decode_err,location=location} end
            return {operation="scanning",safe=true,complete=false,error=decode_err,identity={caste=bee.caste,active=bee.active,inactive=bee.inactive},location="bee_storage",scanned=false}
          end
          local returned, stored_or_err=adapter:return_output("scanner",slot,decoded,options)
          if not returned then return {operation="scanning",safe=false,complete=false,error=stored_or_err,location="scanner slot "..slot} end
          return {operation="scanning",safe=true,complete=true,bee=type(stored_or_err)=="table" and stored_or_err or decoded,identity={caste=decoded.caste,active=decoded.active,inactive=decoded.inactive},location="bee_storage",scanned=true}
        end
      end
    end
    adapter:wait_tick()
  end
  local safe, location=restore_scan_input(adapter,bee,options)
  if not safe then return {operation="scanning",safe=false,complete=false,error="scanner limit reached",location=location} end
  return {operation="scanning",safe=true,complete=false,error="scanner limit reached",identity={caste=bee.caste,active=bee.active,inactive=bee.inactive},location="bee_storage",scanned=false}
end

local function machine_cycle(adapter, princess, drone, limit)
  if not positive_integer(limit) then return nil,"breeder limit must be a finite positive integer" end
  if type(princess)~="table" or type(princess.inventory)~="string" or not positive_integer(princess.slot)
    or type(drone)~="table" or type(drone.inventory)~="string" or not positive_integer(drone.slot) then
    return nil,"breeder request lacks finite physical parent slots"
  end
  local princess_size=tonumber(princess.size or 1)
  local drone_size=tonumber(drone.size or 1)
  if not positive_integer(princess_size) or not positive_integer(drone_size) then
    return nil,"breeder request parent counts must be finite positive integers"
  end
  local role=adapter.config.roles.breeder
  if not role.princess_slot or not role.drone_slot or type(role.output_slots)~="table" or #role.output_slots==0 then
    return nil,"breeder needs explicit princess_slot, drone_slot, and output_slots"
  end
  local stable_required=role.terminal_stable_polls or 2
  if not positive_integer(stable_required) then return nil,"breeder terminal stability count is not a finite positive integer" end
  for _,slot in ipairs(unique_slots(role)) do
    local raw, read_err=adapter:raw_stack("breeder",slot)
    if read_err then return nil,read_err end
    if raw then return nil,"breeder slot "..slot.." is occupied; recover it before breeding" end
  end
  local first,first_err=adapter:transfer_verified(princess.inventory,princess.slot,"breeder",role.princess_slot,1)
  if not first then return nil,first_err end

  local function recover_cycle(reason,outputs)
    local safe,location=restore(adapter,"breeder")
    if not safe then return {safe=false,complete=false,error=tostring(reason),location=location,outputs=outputs or {}} end
    return {safe=true,complete=false,error=tostring(reason),location="bee_storage",outputs=outputs or {}}
  end

  local second,second_err=adapter:transfer_verified(drone.inventory,drone.slot,"breeder",role.drone_slot,1)
  if not second then return recover_cycle(second_err) end
  local ready,terminal_counts=false,nil
  local previous_signature,stable=nil,0
  for _=1,limit do
    local observed,poll_err,inputs_empty=0,nil,true
    for _,slot in ipairs({role.princess_slot,role.drone_slot}) do
      local raw,read_err=adapter:raw_stack("breeder",slot)
      if read_err then poll_err=read_err;break end
      if raw then inputs_empty=false end
    end
    local signature,counts={},{}
    for _,slot in ipairs(role.output_slots) do
      local raw,read_err=adapter:raw_stack("breeder",slot)
      if read_err then poll_err=read_err;break end
      if raw then
        local count,count_err=physical_count(raw)
        if not count then poll_err=count_err;break end
        local fingerprint_ok,fingerprint=pcall(util.canonical,raw)
        if not fingerprint_ok then poll_err="breeder output cannot be fingerprinted safely";break end
        observed=observed+count
        counts[slot]=count
        signature[#signature+1]=tostring(slot).."="..fingerprint
      else signature[#signature+1]=tostring(slot).."=empty" end
    end
    if poll_err then return recover_cycle(poll_err) end
    signature=table.concat(signature,"|")
    if inputs_empty and observed>0 then
      if signature==previous_signature then stable=stable+1 else previous_signature,stable=signature,1 end
      if stable>=stable_required then ready,terminal_counts=true,counts;break end
    else previous_signature,stable=nil,0 end
    adapter:wait_tick()
  end
  if not ready then return recover_cycle("breeder limit reached before a stable terminal state with consumed inputs and physical outputs") end

  local outputs={}
  for _,slot in ipairs(role.output_slots) do
    local budget=terminal_counts[slot] or 0
    for _=1,budget do
      local raw,read_err=adapter:raw_stack("breeder",slot)
      if read_err then return recover_cycle(read_err,outputs) end
      if not raw then break end
      local decoded=adapter:decode(raw,{role="breeder",slot=slot})
      if not decoded then
        local transport=M.identify_stack(raw,{role="breeder",slot=slot},adapter)
        if transport then
          local scan_options={}
          if transport.inventory=="bee_storage" then scan_options.blocked_storage_slot=transport.slot end
          local scanned=M.scan_generation(adapter,transport,adapter.config.limits.scanning,scan_options)
          if type(scanned)~="table" or scanned.safe~=true or scanned.complete~=true then
            local reason=(type(scanned)=="table" and scanned.error) or "output scanning returned no safety attestation"
            local recovered=recover_cycle(reason,outputs)
            if type(scanned)=="table" and scanned.safe==false then
              recovered.safe=false
              recovered.location=scanned.location or recovered.location or "unknown"
            end
            return recovered
          end
          decoded=scanned.bee
        else
          return recover_cycle("breeder output cannot be identified as a configured bee item",outputs)
        end
      else
        local returned,stored_or_err=adapter:return_output("breeder",slot,decoded)
        if not returned then return recover_cycle(stored_or_err,outputs) end
        decoded=type(stored_or_err)=="table" and stored_or_err or decoded
      end
      outputs[#outputs+1]=decoded
    end
    local remaining,remaining_err=adapter:raw_stack("breeder",slot)
    if remaining_err then return recover_cycle(remaining_err,outputs) end
    if remaining then return recover_cycle("breeder output slot "..slot.." did not drain within its stable observed physical count",outputs) end
  end
  local safe,location=restore(adapter,"breeder")
  if not safe then return {safe=false,complete=false,error="not every retained bee reached storage",location=location,outputs=outputs} end
  for observation=1,stable_required do
    for _,slot in ipairs(unique_slots(role)) do
      local raw,read_err=adapter:raw_stack("breeder",slot)
      if read_err then return recover_cycle(read_err,outputs) end
      if raw then return recover_cycle("breeder produced a late or unsettled item after output collection",outputs) end
    end
    if observation<stable_required then adapter:wait_tick() end
  end
  return {safe=true,complete=true,location="bee_storage",outputs=outputs}
end

function M.breed_generation(adapter, step, limit)
  local uid = step.uid or step.archive_uid
  if not step.princess or not step.drone or type(uid)~="string" then return nil,"breeding request lacks physical parents or target UID" end
  local result,err=machine_cycle(adapter,step.princess,step.drone,limit)
  if not result then return nil,err end
  result.uid=uid
  if step.archive_uid then
    result.operation="archive"
  else
    result.operation="breeding"
    local observed=false
    for _,bee in ipairs(result.outputs or {}) do if bee.active==uid then observed=true;break end end
    if result.complete and not observed then
      result.complete=false
      result.error="finished breeding cycle did not produce the requested active species UID"
    end
  end
  return result
end

function M.convert_generation(adapter,uid,princess,drone,limit)
  local result,err=machine_cycle(adapter,princess,drone,limit)
  if not result then return nil,err end
  result.operation,result.uid="conversion",uid
  result.princess_identity=princess.active
  local princess_outputs={}
  for _,bee in ipairs(result.outputs or {}) do if bee.caste=="princess" then princess_outputs[#princess_outputs+1]=bee end end
  if #princess_outputs==1 then result.retained_princess=util.copy(princess_outputs[1]) end
  local retained=result.retained_princess
  local exact_retained=retained and retained.inventory=="bee_storage" and positive_integer(retained.slot) and retained.size==1
  result.converted=#princess_outputs==1 and princess_outputs[1].active==uid and Inventory.genome_equal(princess_outputs[1],drone)
  result.complete=result.complete==true and result.converted
  if not exact_retained then
    result.complete=false
    result.error="conversion output lacks exact final bee_storage slot evidence for one retained princess"
  elseif not result.complete and not result.error then
    if #princess_outputs~=1 then result.error="conversion output did not identify exactly one retained princess lineage"
    elseif princess_outputs[1].active~=uid then result.error="finished conversion generation did not produce the requested target princess"
    else result.error="target-active conversion princess is not full-genome-compatible with the source drone" end
  end
  return result
end

function M.imprint_generation(adapter,uid,template,limit,princess,donor)
  local reserved_slot=adapter.config.roles.bee_storage.reserved_slot
  local template_proven=type(template)=="table" and template.caste=="drone" and template.scanned==true
    and template.inventory=="bee_storage" and positive_integer(template.slot) and template.slot==reserved_slot
    and template.size==1 and template.genome~=nil
  if not template_proven then
    return nil,"imprint request lacks the verified singleton drone template in the reserved bee_storage slot"
  end
  if type(uid)~="string" or not princess or princess.caste~="princess" or princess.inventory~="bee_storage"
    or not positive_integer(princess.slot) or princess.slot==reserved_slot or princess.size~=1 then
    return nil,"imprint request lacks an explicit eligible ordinary target princess for "..tostring(uid)
  end
  if not donor or donor.caste~="drone" or donor.inventory~="bee_storage" or not positive_integer(donor.slot)
    or donor.slot==reserved_slot or not Inventory.genome_equal(donor,template) then
    return {operation="imprint",safe=true,complete=false,scanned=false,uid=uid,template_retained=true,location="bee_storage",error="imprint needs an ordinary template-equivalent drone and target princess; reserved slot was not moved"}
  end
  local result,cycle_err=machine_cycle(adapter,princess,donor,limit)
  if not result then return nil,cycle_err end
  result.operation,result.uid,result.template_retained="imprint",uid,true
  local princess_outputs={}
  for _,bee in ipairs(result.outputs or {}) do if bee.caste=="princess" then princess_outputs[#princess_outputs+1]=bee end end
  local target=princess_outputs[1]
  if target then result.retained_princess=util.copy(target) end
  local matched=#princess_outputs==1 and target.scanned==true and Inventory.genome_equal(target,template)
  result.scanned=matched
  result.complete=result.complete==true and matched
  if not result.complete and not result.error then
    result.error=#princess_outputs==1 and "target princess lineage did not match the reserved template genome after scanning" or "imprint output did not identify exactly one target princess lineage"
  end
  return result
end

return M
