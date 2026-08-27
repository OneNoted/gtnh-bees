local H = require("tests.harness")
local Adapter = require("gtnh_bees.hardware")
local util = require("gtnh_bees.util")

local function bee(scanned, size, uid, max_size)
  uid = uid or "a"
  return {
    caste="drone", active=uid, inactive=uid, scanned=scanned == true,
    size=size or 1, maxSize=max_size or 64, genome={marker=uid}
  }
end

local function fixture()
  local inventories = {
    [0]={size=6, slots={}}, [1]={size=6, slots={}},
    [2]={size=6, slots={}}, [3]={size=6, slots={}}
  }
  local observations, decoded_slots, transfers = {}, {}, 0
  local transposer = {}

  function transposer.getInventorySize(side)
    return inventories[side].size
  end

  function transposer.getStackInSlot(side, slot)
    observations[#observations + 1] = {side=side, slot=slot}
    return util.copy(inventories[side].slots[slot])
  end

  function transposer.transferItem(source_side, destination_side, count, source_slot, destination_slot)
    transfers = transfers + 1
    local source = inventories[source_side].slots[source_slot]
    if not source then return 0 end
    local moved = math.min(count, source.size)
    local destination = inventories[destination_side].slots[destination_slot]
    if destination then
      destination.size = destination.size + moved
    else
      destination = util.copy(source)
      destination.size = moved
      inventories[destination_side].slots[destination_slot] = destination
    end
    source.size = source.size - moved
    if source.size == 0 then inventories[source_side].slots[source_slot] = nil end
    return moved
  end

  local driver = {
    list_species=function() return {} end,
    list_mutations=function() return {} end,
    inspect_stack=function(raw, context)
      if context.role == "bee_storage" then decoded_slots[#decoded_slots + 1] = context.slot end
      if raw.unanalyzed then return nil, "unanalyzed bee cannot be decoded in storage" end
      if raw.non_bee then return nil, "not a bee" end
      return util.copy(raw)
    end,
    scan_generation=function() return nil, "unused" end,
    breed_generation=function() return nil, "unused" end,
    convert_generation=function() return nil, "unused" end,
    imprint_generation=function() return nil, "unused" end
  }
  local config = {roles={
    genetics={address="genetics"},
    bee_storage={address="transposer", side=0, reserved_slot=6},
    breeder={address="transposer", side=1, princess_slot=1, drone_slot=2, output_slots={3}},
    scanner={address="transposer", side=2, input_slot=1, output_slots={2}},
    recovery={address="transposer", side=3, output_slots={1}}
  }, limits={transfer=3, scanning=1, breeding=1, archive=1, conversion=1, imprint=1}}
  local runtime = {component={proxy=function(address)
    if address == "transposer" then return transposer end
    return {}
  end}}
  local adapter = assert(Adapter.new(config, driver, runtime))
  observations, decoded_slots = {}, {}
  return adapter, inventories, {
    observations=function() return observations end,
    decoded_slots=function() return decoded_slots end,
    transfers=function() return transfers end,
    reset=function() observations, decoded_slots = {}, {} end
  }
end

local function observed_storage_slots(observations)
  local seen = {}
  for _, observation in ipairs(observations) do
    if observation.side == 0 then seen[observation.slot] = true end
  end
  return seen
end

H.test("stacked scanner return skips only the occupied source remainder and reports its exact destination", function()
  local adapter, inventories, log = fixture()
  local source = bee(false, 6)
  source.unanalyzed = true
  inventories[0].slots[1] = source
  H.equal(assert(adapter:transfer_verified("bee_storage", 1, "scanner", 1, 1)), 1)
  H.equal(inventories[0].slots[1].size, 5)

  inventories[2].slots[1] = nil
  local analyzed = bee(true, 1)
  inventories[2].slots[2] = util.copy(analyzed)
  inventories[0].slots[3] = bee(true, 1, "witness")
  log.reset()

  local ok, evidence = adapter:return_output("scanner", 2, analyzed, {blocked_storage_slot=1})
  H.truthy(ok)
  H.equal(inventories[0].slots[1].size, 5)
  H.equal(inventories[0].slots[2].size, 1)
  H.falsy(inventories[2].slots[2])
  H.falsy(inventories[0].slots[6])
  H.equal(evidence.inventory, "bee_storage")
  H.equal(evidence.slot, 2)
  H.equal(evidence.locations, {{inventory="bee_storage", slot=2, count=1}})
  H.equal(log.decoded_slots(), {3})
  local observed = observed_storage_slots(log.observations())
  for slot = 1, 6 do H.truthy(observed[slot], "storage slot " .. slot .. " was not observed") end
end)

H.test("blocked return rejects empty absent reserved and malformed storage slots without transfer", function()
  local cases = {
    {slot=1, fragment="not physically occupied"},
    {slot=7, fragment="outside"},
    {slot=6, fragment="reserved"},
    {slot=0, fragment="positive integer"},
    {slot=1.5, fragment="positive integer"},
    {slot="1", fragment="positive integer"}
  }
  for _, case in ipairs(cases) do
    local adapter, inventories, log = fixture()
    inventories[2].slots[2] = bee(true, 1)
    local before = log.transfers()
    local ok, err = adapter:return_output("scanner", 2, nil, {blocked_storage_slot=case.slot})
    H.falsy(ok)
    H.contains(err, case.fragment)
    H.equal(log.transfers(), before)
    H.truthy(inventories[2].slots[2])
  end
end)

H.test("blocked return requires a finite positive physical remainder", function()
  local adapter, inventories, log = fixture()
  inventories[0].slots[1] = bee(false, 0)
  inventories[0].slots[1].unanalyzed = true
  inventories[2].slots[2] = bee(true, 1)
  local ok, err = adapter:return_output("scanner", 2, nil, {blocked_storage_slot=1})
  H.falsy(ok)
  H.contains(err, "finite positive physical count")
  H.equal(log.transfers(), 0)
end)

H.test("blocked return still fails closed on every other undecodable occupied slot", function()
  local adapter, inventories, log = fixture()
  inventories[0].slots[1] = bee(false, 5)
  inventories[0].slots[1].unanalyzed = true
  inventories[0].slots[3] = bee(false, 1, "hostile")
  inventories[0].slots[3].unanalyzed = true
  inventories[2].slots[2] = bee(true, 1)
  local ok, err = adapter:return_output("scanner", 2, nil, {blocked_storage_slot=1})
  H.falsy(ok)
  H.contains(err, "bee_storage slot 3")
  H.equal(log.decoded_slots(), {3})
  H.equal(log.transfers(), 0)
  H.truthy(inventories[2].slots[2])
end)

H.test("return planning observes non-bee storage occupancy as unavailable", function()
  local adapter, inventories = fixture()
  inventories[0].slots[1] = {name="foreign", size=1, maxSize=64, non_bee=true}
  inventories[2].slots[2] = bee(true, 1)
  local ok, evidence = adapter:return_output("scanner", 2)
  H.truthy(ok)
  H.equal(evidence.slot, 2)
  H.equal(inventories[0].slots[1].name, "foreign")
  H.equal(inventories[0].slots[2].size, 1)
end)

H.test("ordinary return remains supported and reports the exact merged destination", function()
  local adapter, inventories = fixture()
  inventories[0].slots[1] = bee(true, 4)
  inventories[2].slots[2] = bee(true, 1)
  local ok, evidence = adapter:return_output("scanner", 2)
  H.truthy(ok)
  H.equal(inventories[0].slots[1].size, 5)
  H.equal(evidence.active, "a")
  H.equal(evidence.inventory, "bee_storage")
  H.equal(evidence.slot, 1)
  H.equal(evidence.locations, {{inventory="bee_storage", slot=1, count=1}})
end)

H.test("split returns expose counted locations without claiming one exact slot", function()
  local adapter, inventories = fixture()
  inventories[2].slots[2] = bee(true, 3, "split", 2)
  local ok, evidence = adapter:return_output("scanner", 2)
  H.truthy(ok)
  H.equal(evidence.inventory, "bee_storage")
  H.falsy(evidence.slot)
  H.equal(evidence.locations, {
    {inventory="bee_storage", slot=1, count=2},
    {inventory="bee_storage", slot=2, count=1}
  })
  H.equal(inventories[0].slots[1].size, 2)
  H.equal(inventories[0].slots[2].size, 1)
end)

return true
