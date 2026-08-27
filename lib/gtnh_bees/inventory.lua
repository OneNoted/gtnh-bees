local identity = require("gtnh_bees.identity")
local util = require("gtnh_bees.util")
local Inventory = {}

local valid_castes = {princess=true, drone=true, queen=true}

function Inventory.bee(raw, location)
  if type(raw) ~= "table" then return nil, "bee item is not a table" end
  local caste = raw.caste and util.lower(raw.caste)
  if not valid_castes[caste] then return nil, "unknown bee caste '" .. tostring(raw.caste) .. "'" end
  local active, err = identity.uid(raw.active or raw.activeSpecies or raw.primary)
  if not active then return nil, "active species: " .. err end
  local inactive
  inactive, err = identity.uid(raw.inactive or raw.inactiveSpecies or raw.secondary)
  if not inactive then return nil, "inactive species: " .. err end
  local size = tonumber(raw.size or raw.stackSize or 1)
  if not util.finite_integer(size,1) then return nil, "invalid bee stack size" end
  local max_size=tonumber(raw.maxSize) or 64
  if not util.finite_integer(max_size,1) then return nil,"invalid bee maximum stack size"end
  local slot=location and location.slot or raw.slot
  if slot~=nil and not util.finite_integer(slot,1)then return nil,"invalid bee inventory slot"end
  return {
    caste=caste, active=active, inactive=inactive, genome=util.copy(raw.genome),
    scanned=raw.scanned == true, size=size, maxSize=max_size,
    inventory=location and location.inventory or raw.inventory,
    slot=slot,
    raw=raw
  }
end

function Inventory.is_pure_drone(bee) return bee.caste == "drone" and bee.active == bee.inactive end
function Inventory.genome_equal(a,b) return a.genome ~= nil and b.genome ~= nil and util.deep_equal(a.genome,b.genome) end
function Inventory.stack_compatible(a,b)
  return a and b and a.caste == b.caste and a.active == b.active and a.inactive == b.inactive
    and a.scanned == b.scanned and Inventory.genome_equal(a,b)
end

function Inventory.pure_drone_count(snapshot, uid)
  local count = 0
  for _, bee in ipairs(snapshot.bees or {}) do
    if bee.slot ~= snapshot.reserved_slot and Inventory.is_pure_drone(bee) and bee.active == uid then
      if not util.finite_integer(bee.size,1)then return nil,"archive bee count is not a finite positive integer"end
      count=count+bee.size
      if not util.finite_integer(count,0)then return nil,"archive count is not a finite integer"end
    end
  end
  return count
end

function Inventory.spendable_drone(snapshot, uid, archive_minimum)
  local drones=Inventory.find(snapshot,function(bee)return bee.caste=="drone"and bee.active==uid end)
  if not drones[1]then return nil,"no source drone for "..uid end
  if archive_minimum==nil then return drones[1]end
  if not util.finite_integer(archive_minimum,1)then return nil,"archive minimum is not a finite positive integer"end
  local pure_count,count_err=Inventory.pure_drone_count(snapshot,uid)
  if not pure_count then return nil,count_err end
  for _,drone in ipairs(drones)do
    if not Inventory.is_pure_drone(drone)or pure_count~=archive_minimum then return drone end
  end
  return nil,"pure-drone archive for "..uid.." is at its protected minimum with no surplus"
end

function Inventory.roles(snapshot)
  local roles = {princess={}, drone={}, convertible={}, population={}}
  local princesses, drones = {}, {}
  for _, bee in ipairs(snapshot.bees or {}) do
    if bee.slot ~= snapshot.reserved_slot then
      if bee.caste == "princess" then
        roles.princess[bee.active] = true
        princesses[bee.active] = princesses[bee.active] or {}
        princesses[bee.active][#princesses[bee.active] + 1] = bee
      elseif bee.caste == "drone" then
        roles.drone[bee.active], roles.convertible[bee.active] = true, true
        drones[bee.active] = drones[bee.active] or {}
        drones[bee.active][#drones[bee.active] + 1] = bee
      end
    end
  end
  for uid, candidates in pairs(princesses) do
    for _, princess in ipairs(candidates) do
      for _, drone in ipairs(drones[uid] or {}) do
        if Inventory.genome_equal(princess, drone) then roles.population[uid] = true; break end
      end
      if roles.population[uid] then break end
    end
  end
  return roles
end

function Inventory.population_pair(snapshot, uid)
  local princesses, drones = {}, {}
  for _, bee in ipairs(snapshot.bees or {}) do
    if bee.slot ~= snapshot.reserved_slot and bee.active == uid then
      if bee.caste == "princess" then princesses[#princesses + 1] = bee end
      if bee.caste == "drone" then drones[#drones + 1] = bee end
    end
  end
  table.sort(princesses, function(a,b) return a.slot < b.slot end)
  table.sort(drones, function(a,b) return a.slot < b.slot end)
  for _, princess in ipairs(princesses) do
    for _, drone in ipairs(drones) do if Inventory.genome_equal(princess,drone) then return princess,drone end end
  end
  return nil, "no full-genome-equivalent princess and drone pair for " .. uid
end

function Inventory.template(snapshot)
  for _, bee in ipairs(snapshot.bees or {}) do
    if bee.slot == snapshot.reserved_slot then
      if bee.caste ~= "drone" then return nil, "reserved slot does not contain a drone" end
      if not bee.scanned then return nil, "reserved template drone is not scanned" end
      return bee
    end
  end
  return nil, "reserved template slot is empty"
end

function Inventory.destinations(snapshot, bee, amount)
  amount = amount or bee.size
  if type(snapshot)~="table"or not util.finite_integer(snapshot.size,1)then return nil,"inventory size must be a finite positive integer"end
  if snapshot.reserved_slot~=nil and not util.finite_integer(snapshot.reserved_slot,1,snapshot.size)then return nil,"reserved inventory slot is invalid"end
  if type(bee)~="table"or not util.finite_integer(bee.size,1)or not util.finite_integer(bee.maxSize,1)then return nil,"bee stack sizes must be finite positive integers"end
  if not util.finite_integer(amount,1)then return nil,"destination amount must be a finite positive integer"end
  local by_slot = {}
  for _, stored in ipairs(snapshot.bees or {}) do
    if not util.finite_integer(stored.slot,1,snapshot.size)or not util.finite_integer(stored.size,1)or not util.finite_integer(stored.maxSize,1)or stored.size>stored.maxSize then return nil,"stored bee has invalid finite slot or stack sizes"end
    by_slot[stored.slot] = stored
  end
  local plan, remaining = {}, amount
  for slot = 1, snapshot.size do
    local stored = by_slot[slot]
    if slot ~= snapshot.reserved_slot and stored and Inventory.stack_compatible(stored,bee) then
      local room = stored.maxSize - stored.size
      local count = math.min(room, remaining)
      if count > 0 then plan[#plan + 1] = {slot=slot, merge=true, count=count}; remaining = remaining - count end
      if remaining == 0 then return plan end
    end
  end
  for slot = 1, snapshot.size do
    if slot ~= snapshot.reserved_slot and not by_slot[slot] then
      local count = math.min(bee.maxSize or amount, remaining)
      plan[#plan + 1] = {slot=slot, merge=false, count=count}; remaining = remaining - count
      if remaining == 0 then return plan end
    end
  end
  return nil, "ordinary bee storage is full; reserved template slot was not used"
end

function Inventory.destination(snapshot, bee, amount)
  local plan, err = Inventory.destinations(snapshot, bee, amount)
  if not plan then return nil, err end
  return plan[1]
end

function Inventory.find(snapshot, predicate)
  local out = {}
  for _, bee in ipairs(snapshot.bees or {}) do if bee.slot ~= snapshot.reserved_slot and predicate(bee) then out[#out + 1] = bee end end
  table.sort(out, function(a,b) return a.slot < b.slot end)
  return out
end

return Inventory
