local Calls = require("gtnh_bees.component_call")
local Inventory = require("gtnh_bees.inventory")
local util = require("gtnh_bees.util")

local Adapter = {}
Adapter.__index = Adapter

local function lazy_runtime(runtime)
  if runtime then return runtime end
  return {component=require("component"), computer=require("computer"), event=require("event")}
end

local function stack_size(stack)
  if type(stack) ~= "table" then return 0 end
  local value=tonumber(stack.size or stack.qty)
  return util.finite_integer(value,1)and value or nil
end

local function physical_count(stack)
  local count=type(stack)=="table" and tonumber(stack.size or stack.qty) or nil
  if not util.finite_integer(count,1) then return nil,"bee stack has no finite positive physical count" end
  return count
end

local function stack_identity(stack)
  if type(stack) ~= "table" then return nil end
  local copy = {}
  for key, value in pairs(stack) do if key ~= "size" and key ~= "qty" then copy[key] = value end end
  return util.canonical(copy)
end

local function integer(value)
  return util.finite_integer(value,1)
end

function Adapter.new(config, driver, runtime)
  assert(type(driver) == "table", "an official-API genetics driver is required")
  assert(type(config)=="table"and type(config.limits)=="table","finite hardware limits are required")
  for name,value in pairs(config.limits)do assert(util.finite_integer(value,1),"hardware limit '"..tostring(name).."' must be a finite positive integer")end
  local self = setmetatable({config=config, driver=driver, runtime=lazy_runtime(runtime), proxies={}, decoded={}, requires_mutation_surplus=true}, Adapter)
  local addresses = {}
  for _, role in pairs(config.roles) do
    addresses[role.address] = true
    if role.component_address then addresses[role.component_address] = true end
  end
  for address in pairs(addresses) do
    local ok, proxy = pcall(self.runtime.component.proxy, address)
    if not ok or not proxy then return nil, "component " .. tostring(address) .. " is unavailable" end
    self.proxies[address] = proxy
  end
  local ok, err = self:validate_topology()
  if not ok then return nil, err end
  return self
end

function Adapter:role(name)
  local role = self.config.roles[name]
  if not role then return nil, "hardware role '" .. name .. "' is not configured" end
  return role, self.proxies[role.address]
end

function Adapter:invoke(address, method, ...)
  local called, a, b, c, d = Calls.invoke(self.runtime.component, self.proxies[address], address, method, ...)
  if not called then return nil, a end
  return a, b, c, d
end

function Adapter:invoke_role(name, method, ...)
  local role, err = self:role(name)
  if not role then return nil, err end
  return self:invoke(role.component_address or role.address, method, ...)
end

function Adapter:wait_tick()
  if self.runtime.event and Calls.callable(self.runtime.event.pull) then self.runtime.event.pull(0.25) end
end

function Adapter:validate_topology()
  local storage = self.config.roles.bee_storage
  for _, name in ipairs({"bee_storage", "breeder", "scanner", "recovery"}) do
    local role, proxy = self:role(name)
    if not role then return nil, proxy end
    if not util.finite_integer(role.side,0,5)then return nil,"inventory role '"..name.."' side must be a finite integer from 0 through 5"end
    if role.address ~= storage.address then return nil, "inventory role '" .. name .. "' is not on the configured storage transposer" end
    for _, method in ipairs({"getInventorySize", "getStackInSlot", "transferItem"}) do
      if not Calls.exists(proxy, method) and not Calls.callable(self.runtime.component.invoke) then
        return nil, "component for '" .. name .. "' does not expose documented transposer callback '" .. method .. "'"
      end
    end
    local size, size_err = self:invoke(role.address, "getInventorySize", role.side)
    if not util.finite_integer(size,1) then return nil, "inventory role '" .. name .. "' is absent or ambiguous on side " .. tostring(role.side) .. ": " .. tostring(size_err) end
    if name == "bee_storage" and role.reserved_slot ~= size then return nil, "bee_storage reserved_slot must be its physical final slot " .. tostring(size) end
    for _, slot in ipairs(role.output_slots or {}) do
      if not integer(slot) or slot > size then return nil, name .. " output slot is outside its observed inventory" end
    end
    if role.input_slot and (not integer(role.input_slot) or role.input_slot > size) then return nil, name .. " input_slot is outside its observed inventory" end
    for _, field in ipairs({"princess_slot", "drone_slot"}) do
      if role[field] and (not integer(role[field]) or role[field] > size) then return nil, name .. " " .. field .. " is outside its observed inventory" end
    end
  end
  for role_name, methods in pairs(self.driver.component_methods or {}) do
    local role = self.config.roles[role_name]
    if not role then return nil, "genetics driver requires missing hardware role '" .. role_name .. "'" end
    local address = role.component_address or role.address
    local proxy = self.proxies[address]
    for _, method in ipairs(methods) do
      if not Calls.exists(proxy, method) then return nil, "component for '" .. role_name .. "' lacks documented callback '" .. method .. "'" end
    end
  end
  for _, method in ipairs({"list_species", "list_mutations", "inspect_stack", "scan_generation", "breed_generation", "convert_generation", "imprint_generation"}) do
    if type(self.driver[method]) ~= "function" then return nil, "genetics driver lacks required contract method '" .. method .. "'" end
  end
  return true
end

function Adapter:list_species()
  local role, proxy = self:role("genetics")
  return self.driver.list_species(proxy, role, self)
end
function Adapter:list_mutations()
  local role, proxy = self:role("genetics")
  return self.driver.list_mutations(proxy, role, self)
end

local function decoded_location(role_name, slot)
  if type(role_name) ~= "string" or not integer(slot) then return nil end
  return role_name .. "\0" .. tostring(slot)
end

local function observed_stack(raw)
  if type(raw) ~= "table" then return nil end
  local identity = stack_identity(raw)
  if not identity then return nil end
  return {identity=identity, count=stack_size(raw)}
end

function Adapter:forget_decoded(role_name, slot)
  local key = decoded_location(role_name, slot)
  if key then self.decoded[key] = nil end
end

function Adapter:decoded_at(role_name, slot, raw)
  local key = decoded_location(role_name, slot)
  local observed = observed_stack(raw)
  local entry = key and self.decoded[key] or nil
  if not entry then return nil end
  if not observed then
    self.decoded[key] = nil
    return nil
  end
  if entry.identity ~= observed.identity or entry.count ~= observed.count then
    self.decoded[key] = nil
    return nil
  end
  return util.copy(entry.value)
end

function Adapter:remember(role_name, slot, raw, decoded)
  local key = decoded_location(role_name, slot)
  local observed = observed_stack(raw)
  if not key or not observed or type(decoded) ~= "table" then return end
  self.decoded[key] = {identity=observed.identity, count=observed.count, value=util.copy(decoded)}
end

function Adapter:raw_stack(role_name, slot)
  if not integer(slot)then return nil,"inventory slot must be a finite positive integer"end
  local role, err = self:role(role_name)
  if not role then return nil, err end
  local stack, detail = self:invoke(role.address, "getStackInSlot", role.side, slot)
  if stack == nil and detail then
    self:forget_decoded(role_name, slot)
    return nil, "cannot inspect " .. role_name .. " slot " .. tostring(slot) .. ": " .. tostring(detail)
  end
  if not stack then
    self:forget_decoded(role_name, slot)
  else
    local count,count_err=physical_count(stack)
    if not count then self:forget_decoded(role_name,slot);return nil,role_name.." slot "..slot..": "..count_err end
    if stack.maxSize~=nil then
      local maximum=tonumber(stack.maxSize)
      if not util.finite_integer(maximum,1)then self:forget_decoded(role_name,slot);return nil,role_name.." slot "..slot..": stack maximum size is not a finite positive integer"end
    end
    self:decoded_at(role_name, slot, stack)
  end
  return stack
end

function Adapter:decode(raw, context)
  local role_name = type(context) == "table" and context.role or nil
  local slot = type(context) == "table" and context.slot or nil
  local remembered = self:decoded_at(role_name, slot, raw)
  if remembered then
    local value = remembered; value.size = stack_size(raw)
    local maximum=raw.maxSize~=nil and tonumber(raw.maxSize)or value.maxSize
    if not util.finite_integer(value.size,1)or not util.finite_integer(maximum,1)then return nil,"remembered bee stack has invalid finite sizes"end
    value.maxSize = maximum
    return value
  end
  local decoded, err = self.driver.inspect_stack(raw, context, self)
  if decoded then self:remember(role_name, slot, raw, decoded) end
  return decoded, err
end

local function reserved(role, slot)
  return role and role.reserved_slot and slot == role.reserved_slot
end

function Adapter:transfer_verified(source_name, source_slot, destination_name, destination_slot, requested)
  requested = tonumber(requested)
  if not integer(requested) then return nil, "transfer count must be a positive integer" end
  if not integer(source_slot)or not integer(destination_slot)then return nil,"transfer slots must be finite positive integers"end
  if not util.finite_integer(self.config.limits.transfer,1)then return nil,"transfer retry limit must be a finite positive integer"end
  local source, source_proxy = self:role(source_name)
  local destination, destination_proxy = self:role(destination_name)
  if not source then return nil, source_proxy end
  if not destination then return nil, destination_proxy end
  if reserved(source, source_slot) or reserved(destination, destination_slot) then
    return nil, "transfer involving the reserved bee-storage template slot is forbidden"
  end
  if source.address ~= destination.address then return nil, "transfer endpoints are not on one transposer" end
  local initial_source, err = self:raw_stack(source_name, source_slot)
  if not initial_source then return nil, err or (source_name .. " source slot is empty") end
  local identity = stack_identity(initial_source)
  local moved_total = 0
  for attempt = 1, self.config.limits.transfer do
    local remaining = requested - moved_total
    if remaining <= 0 then return moved_total end
    local before_source, source_err = self:raw_stack(source_name, source_slot)
    if source_err then return nil, source_err end
    local before_destination, destination_err = self:raw_stack(destination_name, destination_slot)
    if destination_err then return nil, destination_err end
    if before_source and stack_identity(before_source) ~= identity then return nil, "source identity changed during transfer; run stopped safely" end
    if before_destination and stack_identity(before_destination) ~= identity then return nil, "destination contains an incompatible item; no transfer was attempted" end
    local source_evidence = self:decoded_at(source_name, source_slot, before_source)
    local destination_evidence = before_destination and self:decoded_at(destination_name, destination_slot, before_destination) or nil
    self:forget_decoded(source_name, source_slot)
    self:forget_decoded(destination_name, destination_slot)
    local callback_result, callback_err = self:invoke(source.address, "transferItem", source.side, destination.side, remaining, source_slot, destination_slot)
    if callback_result == nil and callback_err then return nil, "transfer callback failed: " .. tostring(callback_err) end
    local after_source, after_source_err = self:raw_stack(source_name, source_slot)
    if after_source_err then return nil, after_source_err end
    local after_destination, after_destination_err = self:raw_stack(destination_name, destination_slot)
    if after_destination_err then return nil, after_destination_err end
    local before_source_size,after_source_size=stack_size(before_source),stack_size(after_source)
    local before_destination_size,after_destination_size=stack_size(before_destination),stack_size(after_destination)
    if not before_source_size or not after_source_size or not before_destination_size or not after_destination_size then return nil,"transfer observation contains a non-finite stack count"end
    local drained = before_source_size - after_source_size
    local gained = after_destination_size - before_destination_size
    if after_destination and stack_identity(after_destination) ~= identity then return nil, "destination identity changed ambiguously; no retry was attempted" end
    if drained < 0 or gained < 0 or drained ~= gained or drained > remaining then return nil, "transfer observation is ambiguous; no retry was attempted" end
    if drained == 0 then
      if attempt == self.config.limits.transfer then return nil, "blocked transfer reached its retry limit without draining extra items" end
    else
      if after_source and source_evidence then self:remember(source_name, source_slot, after_source, source_evidence) end
      if after_destination and source_evidence and
          (not before_destination or (destination_evidence and Inventory.stack_compatible(source_evidence, destination_evidence))) then
        self:remember(destination_name, destination_slot, after_destination, source_evidence)
      end
      moved_total = moved_total + drained
    end
  end
  return moved_total == requested and moved_total or nil, "transfer did not complete"
end

local function storage_snapshot(self, blocked_storage_slot, protect_non_bees)
  local role = assert(self.config.roles.bee_storage)
  local size, size_err = self:invoke(role.address, "getInventorySize", role.side)
  if not util.finite_integer(size,1) then return nil, size_err or"bee_storage inventory size is not a finite positive integer" end
  if blocked_storage_slot then
    if blocked_storage_slot > size then return nil, "blocked_storage_slot is outside the observed bee_storage inventory" end
    if blocked_storage_slot == role.reserved_slot then return nil, "blocked_storage_slot cannot be the reserved bee-storage template slot" end
  end

  local snapshot = {size=size, reserved_slot=role.reserved_slot, bees={}}
  for slot = 1, size do
    local raw, err = self:raw_stack("bee_storage", slot)
    if err then return nil, err end
    if slot == blocked_storage_slot then
      if not raw then return nil, "blocked_storage_slot " .. slot .. " is not physically occupied" end
      local count, count_err = physical_count(raw)
      if not count then return nil, "blocked_storage_slot " .. slot .. ": " .. count_err end
      snapshot.bees[#snapshot.bees + 1] = {slot=slot, size=count, maxSize=count, unavailable=true}
    elseif raw then
      local decoded, decode_err = self:decode(raw, {role="bee_storage", slot=slot})
      if decoded then
        local bee, bee_err = Inventory.bee(decoded, {inventory="bee_storage", slot=slot})
        if not bee then return nil, "bee_storage slot " .. slot .. ": " .. bee_err end
        snapshot.bees[#snapshot.bees + 1] = bee
      elseif decode_err == "not a bee" then
        if protect_non_bees then
          snapshot.bees[#snapshot.bees + 1] = {slot=slot, size=stack_size(raw), maxSize=stack_size(raw), unavailable=true}
        end
      else
        return nil, "bee_storage slot " .. slot .. ": " .. tostring(decode_err)
      end
    end
  end
  return snapshot
end

function Adapter:snapshot_storage()
  return storage_snapshot(self)
end

local function return_options(options)
  if options == nil then return {} end
  if type(options) ~= "table" then return nil, "return options must be a table" end
  for key in pairs(options) do
    if key ~= "blocked_storage_slot" then return nil, "unsupported return option '" .. tostring(key) .. "'" end
  end
  if options.blocked_storage_slot ~= nil and not integer(options.blocked_storage_slot) then
    return nil, "blocked_storage_slot must be a positive integer"
  end
  return options
end

function Adapter:return_output(role_name, slot, decoded_override, options)
  local option_err
  options, option_err = return_options(options)
  if not options then return nil, option_err end
  local raw, err = self:raw_stack(role_name, slot)
  if err then return nil, err end
  if not raw then return true end

  local count, count_err = physical_count(raw)
  if not count then return nil, role_name .. " slot " .. slot .. ": " .. count_err end
  local decoded, decode_err
  if decoded_override ~= nil then decoded = util.copy(decoded_override) else decoded, decode_err = self:decode(raw, {role=role_name, slot=slot}) end
  if not decoded then return nil, role_name .. " slot " .. slot .. " cannot be recovered automatically: " .. tostring(decode_err) end
  decoded.size = count
  local decoded_max=tonumber(raw.maxSize)or decoded.maxSize
  if not util.finite_integer(decoded_max,1)then return nil,role_name.." slot "..slot.." has an invalid finite maximum stack size"end
  decoded.maxSize = decoded_max
  self:remember(role_name, slot, raw, decoded)
  local bee, bee_err = Inventory.bee(decoded, {inventory=role_name, slot=slot})
  if not bee then return nil, bee_err end

  local snapshot, snapshot_err = storage_snapshot(self, options.blocked_storage_slot, true)
  if not snapshot then return nil, snapshot_err end
  local destinations, destination_err = Inventory.destinations(snapshot, bee, bee.size)
  if not destinations then return nil, destination_err .. "; bee remains in " .. role_name .. " slot " .. slot end
  for _, destination in ipairs(destinations) do
    local moved, move_err = self:transfer_verified(role_name, slot, "bee_storage", destination.slot, destination.count)
    if not moved then return nil, move_err .. "; remaining output stays in " .. role_name .. " slot " .. slot end
  end

  for _, destination in ipairs(destinations) do
    local stored, stored_err = self:raw_stack("bee_storage", destination.slot)
    if stored_err then return nil, stored_err .. "; returned output is in bee_storage slot " .. destination.slot end
    if not stored then return nil, "returned output disappeared from bee_storage slot " .. destination.slot end
    self:remember("bee_storage", destination.slot, stored, decoded)
  end

  local evidence = util.copy(bee)
  evidence.inventory = "bee_storage"
  evidence.slot = #destinations == 1 and destinations[1].slot or nil
  evidence.locations = {}
  for _, destination in ipairs(destinations) do
    evidence.locations[#evidence.locations + 1] = {inventory="bee_storage", slot=destination.slot, count=destination.count}
  end
  return true, evidence
end

local function role_slots(role)
  local slots, seen = {}, {}
  for _, slot in ipairs(role.output_slots or {}) do
    if not seen[slot] then slots[#slots + 1], seen[slot] = slot, true end
  end
  for _, field in ipairs({"input_slot", "princess_slot", "drone_slot"}) do
    local slot = role[field]
    if slot and not seen[slot] then slots[#slots + 1], seen[slot] = slot, true end
  end
  return slots
end

local identifiable_castes = {princess=true, drone=true, queen=true}

function Adapter:return_raw_one(role_name, slot)
  local source_location = role_name .. " slot " .. slot
  local raw, raw_err = self:raw_stack(role_name, slot)
  if raw_err then return nil, raw_err, source_location end
  if not raw then return true end
  local count, count_err = physical_count(raw)
  if not count then return nil, count_err, source_location end
  if type(self.driver.identify_stack) ~= "function" then
    return nil, "driver cannot identify an unanalyzed retained item without guessing", source_location
  end
  local transport, identify_err = self.driver.identify_stack(raw, {role=role_name, slot=slot}, self)
  if type(transport) ~= "table" or not identifiable_castes[util.lower(transport.caste or "")] or
      transport.inventory ~= role_name or transport.slot ~= slot then
    return nil, identify_err or "retained item is not an identifiable configured bee at its observed machine location",
      source_location
  end

  local storage = self.config.roles.bee_storage
  local size, size_err = self:invoke(storage.address, "getInventorySize", storage.side)
  if not integer(size) then
    return nil, "cannot observe bee_storage while recovering raw bee: " .. tostring(size_err), source_location
  end
  for destination = 1, size do
    if destination ~= storage.reserved_slot then
      local occupied, occupied_err = self:raw_stack("bee_storage", destination)
      if occupied_err then return nil, occupied_err, source_location end
      if not occupied then
        local moved, move_err = self:transfer_verified(role_name, slot, "bee_storage", destination, 1)
        if not moved then
          return nil, tostring(move_err), source_location .. " or bee_storage slot " .. destination
        end
        local evidence = util.copy(transport)
        evidence.inventory, evidence.slot = "bee_storage", destination
        evidence.size, evidence.scanned, evidence.analysis_required = 1, false, true
        evidence.raw = nil
        return true, evidence
      end
    end
  end
  return nil, "no empty ordinary bee_storage slot is available", source_location
end

local function recovered_location_list(recovered, current)
  local locations, seen = {}, {}
  local function add(value)
    if value and not seen[value] then
      locations[#locations + 1], seen[value] = value, true
    end
  end
  for _, evidence in ipairs(recovered) do
    if type(evidence) == "table" then
      if evidence.inventory and evidence.slot then
        add(evidence.inventory .. " slot " .. evidence.slot)
      end
      for _, location in ipairs(evidence.locations or {}) do
        if location.inventory and location.slot then add(location.inventory .. " slot " .. location.slot) end
      end
    end
  end
  add(current)
  return table.concat(locations, ", ")
end

function Adapter:recover_pending()
  local recovered = {}
  for _, name in ipairs({"scanner", "breeder", "recovery"}) do
    local role = self.config.roles[name]
    for _, slot in ipairs(role_slots(role)) do
      local initial, initial_err = self:raw_stack(name, slot)
      if initial_err then return nil, initial_err end
      if initial then
        local budget, count_err = physical_count(initial)
        if not budget then return nil, name .. " slot " .. slot .. ": " .. count_err end
        for _ = 1, budget do
          local raw, raw_err = self:raw_stack(name, slot)
          if raw_err then return nil, raw_err end
          if not raw then break end
          local decoded, decode_err = self:decode(raw, {role=name, slot=slot})
          local ok, value, known_locations
          if decoded then
            ok, value = self:return_output(name, slot, decoded)
          elseif decode_err == "not a bee" then
            ok, value, known_locations = nil, decode_err, name .. " slot " .. slot
          else
            ok, value, known_locations = self:return_raw_one(name, slot)
          end
          if not ok then
            known_locations = known_locations or
              (name .. " slot " .. slot .. " and any verified ordinary bee_storage returns")
            known_locations = recovered_location_list(recovered, known_locations)
            return nil, "recovery stopped safely after " .. #recovered .. " return(s); known recovery location(s): " ..
              known_locations .. ": " .. tostring(value or decode_err)
          end
          recovered[#recovered + 1] = value
        end
        local remaining, remaining_err = self:raw_stack(name, slot)
        if remaining_err then return nil, remaining_err end
        if remaining then
          return nil, "recovery reached the initial physical-bee bound; known recovery location(s): " ..
            recovered_location_list(recovered, name .. " slot " .. slot)
        end
      end
    end
  end
  return recovered
end

function Adapter:prepare_storage()
  local role = self.config.roles.bee_storage
  local size, size_err = self:invoke(role.address, "getInventorySize", role.side)
  if not integer(size) then return nil, "cannot observe bee_storage size: " .. tostring(size_err) end

  local function pending_state()
    local pending,selected=0,nil
    for slot=1,size do
      local raw,err=self:raw_stack("bee_storage",slot)
      if err then return nil,nil,err end
      if raw then
        local decoded,decode_err=self:decode(raw,{role="bee_storage",slot=slot})
        if slot==role.reserved_slot then
          if not decoded then return nil,nil,"reserved template cannot be verified in place: "..tostring(decode_err) end
        elseif decoded and not decoded.scanned then
          local count,count_err=physical_count(raw)
          if not count then return nil,nil,"bee_storage slot "..slot..": "..count_err end
          pending=pending+count
          if not util.finite_integer(pending,0)then return nil,nil,"pending storage analysis count is not a finite integer"end
          if not selected then
            local bee,bee_err=Inventory.bee(decoded,{inventory="bee_storage",slot=slot})
            if not bee then return nil,nil,"bee_storage slot "..slot..": "..bee_err end
            selected=bee
          end
        elseif not decoded and decode_err~="not a bee" then
          if type(self.driver.identify_stack)~="function" then return nil,nil,"bee_storage slot "..slot..": "..tostring(decode_err) end
          local transport,identify_err=self.driver.identify_stack(raw,{role="bee_storage",slot=slot},self)
          if not transport then return nil,nil,"bee_storage slot "..slot..": "..tostring(identify_err or decode_err) end
          local count,count_err=physical_count(raw)
          if not count then return nil,nil,"bee_storage slot "..slot..": "..count_err end
          pending=pending+count
          if not util.finite_integer(pending,0)then return nil,nil,"pending storage analysis count is not a finite integer"end
          if not selected then selected=transport end
        end
      end
    end
    return pending,selected
  end

  local initial,selected,state_err=pending_state()
  if not initial then return nil,state_err end
  if initial==0 then return true end
  for _=1,initial do
    local before=initial
    local scanned,scan_err=self:scan_bee(selected)
    if not scanned then return nil,scan_err end
    if scanned.safe~=true or scanned.complete~=true or scanned.scanned~=true or scanned.location~="bee_storage" then
      return nil,scanned.error or "storage analysis did not complete with every bee in known storage"
    end
    local after,next_selected,after_err=pending_state()
    if not after then return nil,after_err end
    if after>=before then return nil,"storage analysis made no verified physical-bee progress; every observed bee remains in known storage" end
    if after==0 then return true end
    initial,selected=after,next_selected
  end
  return nil,"storage analysis did not converge within the finite startup physical-bee bound"
end

function Adapter:scan_bee(bee)
  local result, err = self.driver.scan_generation(self, bee, self.config.limits.scanning)
  if not result then return nil, "scan failed for bee in " .. tostring(bee.inventory) .. " slot " .. tostring(bee.slot) .. ": " .. tostring(err) end
  if type(result)=="table"and type(result.identity)=="table"and bee.active and(result.identity.caste~=bee.caste or result.identity.active~=bee.active or result.identity.inactive~=bee.inactive)then
    return nil,"scanner output identity does not match its input; reported location: "..tostring(result.location or"unknown")
  end
  return result
end

local function preflight_attestation(self, step, diagnostic, route_failure)
  for _, name in ipairs({"scanner", "breeder", "recovery"}) do
    local role = self.config.roles[name]
    for _, slot in ipairs(role_slots(role)) do
      local raw, read_err = self:raw_stack(name, slot)
      if read_err then
        return nil, diagnostic .. "; cannot prove preflight storage state: " .. tostring(read_err)
      end
      if raw then
        return nil, diagnostic .. "; cannot claim safe preflight rejection while a bee may remain in " .. name .. " slot " .. slot
      end
    end
  end
  return {
    operation="breeding", safe=true, complete=false, uid=step.uid,
    location="bee_storage", outputs={}, route_failure=route_failure or "deterministic",
    error=diagnostic, diagnostic=diagnostic
  }
end

function Adapter:produce_species(step, archive_minimum)
  local foundations, foundation_list = {}, {}
  for _, condition in ipairs(step.route.conditions or {}) do
    if not condition.satisfied then
      local description = tostring(condition.description or condition.identity or "unknown mutation condition")
      if not condition.foundation or not self.foundation then
        return preflight_attestation(self, step, "unmet mutation condition: " .. description)
      end
      if type(condition.foundation) ~= "string" or condition.foundation == "" then
        return preflight_attestation(self, step, "foundation mutation condition has no exact block identity: " .. description)
      end
      if not foundations[condition.foundation] then
        foundations[condition.foundation] = true
        foundation_list[#foundation_list + 1] = condition.foundation
      end
    end
  end
  table.sort(foundation_list)
  if #foundation_list > 1 then
    return preflight_attestation(self, step, "conflicting foundation mutation conditions require different blocks: " .. table.concat(foundation_list, ", "))
  end
  if foundation_list[1] then
    local ok, err, failure = self.foundation:request(foundation_list[1])
    if not ok then
      local classification=failure=="transient"and"transient"or"deterministic"
      return preflight_attestation(self, step, "foundation mutation condition failed: " .. tostring(err),classification)
    end
  end
  local snapshot, snapshot_err = self:snapshot_storage()
  if not snapshot then return nil, snapshot_err end
  local princesses = Inventory.find(snapshot, function(bee) return bee.caste == "princess" and bee.active == step.orientation.princess end)
  if not princesses[1] then return nil, "selected mutation princess is no longer in known storage" end
  local drone,drone_err=Inventory.spendable_drone(snapshot,step.orientation.drone,archive_minimum)
  if not drone then return preflight_attestation(self,step,"selected mutation drone is unavailable: "..tostring(drone_err))end
  step.princess, step.drone = princesses[1], drone
  return self.driver.breed_generation(self, step, self.config.limits.breeding)
end

function Adapter:expand_archive(uid, target, princess, drone)
  return self.driver.breed_generation(self, {uid=uid, archive_uid=uid, target=target, princess=princess, drone=drone}, self.config.limits.archive)
end
function Adapter:convert_one(uid, princess, drone)
  return self.driver.convert_generation(self, uid, princess, drone, self.config.limits.conversion)
end
function Adapter:imprint_one(uid, template, princess, donor)
  return self.driver.imprint_generation(self, uid, template, self.config.limits.imprint, princess, donor)
end

return Adapter
