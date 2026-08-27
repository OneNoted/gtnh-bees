local H = require("tests.harness")
local Adapter = require("gtnh_bees.hardware")
local Operations = require("gtnh_bees.operations")
local util = require("gtnh_bees.util")

local function decoded(caste, uid, size, genome)
  return {
    caste=caste, active=uid, inactive=uid, scanned=true,
    size=size or 1, maxSize=caste == "princess" and 1 or 64,
    genome=genome or {line=uid}
  }
end

local function fixture(driver, storage_size)
  storage_size = storage_size or 8
  local inventories = {}
  for side = 0, 3 do inventories[side] = {size=storage_size, slots={}} end
  local transfers = {}
  local transposer = {}

  function transposer.getInventorySize(side)
    return inventories[side].size
  end

  function transposer.getStackInSlot(side, slot)
    return util.copy(inventories[side].slots[slot])
  end

  function transposer.transferItem(source_side, destination_side, count, source_slot, destination_slot)
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
    transfers[#transfers + 1] = {
      from=source_side, from_slot=source_slot, to=destination_side,
      to_slot=destination_slot, count=moved
    }
    return moved
  end

  driver.list_species = driver.list_species or function() return {} end
  driver.list_mutations = driver.list_mutations or function() return {} end
  driver.inspect_stack = driver.inspect_stack or function(raw)
    if raw.decoded then return util.copy(raw.decoded) end
    return nil, "not a bee"
  end
  driver.scan_generation = driver.scan_generation or function() return nil, "unused" end
  driver.breed_generation = driver.breed_generation or function() return nil, "unused" end
  driver.convert_generation = driver.convert_generation or function() return nil, "unused" end
  driver.imprint_generation = driver.imprint_generation or function() return nil, "unused" end

  local config = {mutation_conditions={}, roles={
    genetics={address="genetics"},
    bee_storage={address="transposer", side=0, reserved_slot=storage_size},
    breeder={address="transposer", side=1, princess_slot=1, drone_slot=2, output_slots={3}},
    scanner={address="transposer", side=2, input_slot=1, output_slots={2}},
    recovery={address="transposer", side=3, output_slots={1}}
  }, limits={transfer=3, scanning=4, breeding=2, archive=2, conversion=2, imprint=2}}
  local runtime = {component={proxy=function(address)
    if address == "transposer" then return transposer end
    return {}
  end}, event={pull=function() end}}
  local adapter = assert(Adapter.new(config, driver, runtime))
  return adapter, inventories, transfers
end

H.test("hardware preflight rejection is a complete deterministic attestation and operations try the alternate route", function()
  local breed_calls, foundation_calls = {}, 0
  local driver = {
    list_species=function() return {{uid="a"},{uid="b"},{uid="c"},{uid="d"}} end,
    list_mutations=function()
      return {
        {result="c", parents={"a","b"}, chance=90, conditions="blocked installation"},
        {result="c", parents={"a","d"}, chance=80, conditions="foundation installation"}
      }
    end,
    inspect_stack=function(raw) return util.copy(raw.decoded) end,
    breed_generation=function(adapter, step)
      breed_calls[#breed_calls + 1] = table.concat(step.route.parents, "+")
      adapter._test_inventories[0].slots[7] = {name="p-c", size=1, decoded=decoded("princess", "c", 1)}
      adapter._test_inventories[0].slots[8] = {name="d-c", size=32, decoded=decoded("drone", "c", 32)}
      return {operation="breeding", safe=true, complete=true, uid=step.uid,
        location="bee_storage", outputs={}}
    end
  }
  local adapter, inventories, transfers = fixture(driver, 10)
  adapter._test_inventories = inventories
  adapter.config.mutation_conditions = {
    ["blocked installation"]={policy="unmet"},
    ["foundation installation"]={policy="foundation", foundation="minecraft:stone"}
  }
  adapter.foundation = {request=function(_, block)
    foundation_calls = foundation_calls + 1
    H.equal(block, "minecraft:stone")
    return true
  end}
  local stocks = {
    decoded("princess", "a", 1), decoded("drone", "a", 33),
    decoded("princess", "b", 1), decoded("drone", "b", 33),
    decoded("princess", "d", 1), decoded("drone", "d", 33)
  }
  for slot, bee in ipairs(stocks) do inventories[0].slots[slot] = {name="bee-" .. slot, size=bee.size, decoded=bee} end

  local rejected = assert(adapter:produce_species({uid="c", route={conditions={{
    satisfied=false, description="blocked installation"
  }}}}))
  H.equal(rejected.operation, "breeding")
  H.truthy(rejected.safe)
  H.falsy(rejected.complete)
  H.equal(rejected.uid, "c")
  H.equal(rejected.location, "bee_storage")
  H.equal(rejected.outputs, {})
  H.equal(rejected.route_failure, "deterministic")
  H.contains(rejected.diagnostic, "blocked installation")
  H.equal(#transfers, 0)

  local outcome = assert(Operations.new(adapter, {limits={progress=8, mutation_generations=2}}):complete({imprint="none"}))
  H.truthy(outcome.success)
  H.equal(outcome.missing, {})
  H.equal(breed_calls, {"a+d"})
  H.equal(foundation_calls, 1)
  H.equal(#transfers, 0)
end)

H.test("failed foundation request is preflight-safe only while every machine slot is empty", function()
  local adapter, inventories = fixture({})
  adapter.foundation = {request=function() return nil, "controller rejected request" end}
  local step = {uid="exact.uid", route={conditions={{
    satisfied=false, description="foundation installation", foundation="minecraft:stone"
  }}}}
  local rejected = assert(adapter:produce_species(step))
  H.truthy(rejected.safe)
  H.equal(rejected.uid, "exact.uid")
  H.equal(rejected.location, "bee_storage")
  H.equal(rejected.route_failure, "deterministic")
  H.contains(rejected.error, "controller rejected request")

  adapter.foundation = {request=function() return nil, "foundation robot did not reply", "transient" end}
  rejected = assert(adapter:produce_species(step))
  H.truthy(rejected.safe);H.equal(rejected.route_failure,"transient")
  H.contains(rejected.error,"did not reply")

  inventories[2].slots[1] = {name="raw-bee", size=1}
  local value, err = adapter:produce_species(step)
  H.falsy(value)
  H.contains(err, "scanner slot 1")
end)

H.test("conflicting foundation blocks are rejected before any request or breeding action", function()
  local adapter = assert(fixture({}))
  local requests = 0
  adapter.foundation = {request=function() requests = requests + 1; return true end}
  local step = {uid="exact.uid", route={conditions={
    {satisfied=false, description="stone foundation", foundation="minecraft:stone"},
    {satisfied=false, description="sand foundation", foundation="minecraft:sand"}
  }}}
  local rejected = assert(adapter:produce_species(step))
  H.truthy(rejected.safe);H.falsy(rejected.complete);H.equal(rejected.route_failure,"deterministic")
  H.contains(rejected.error,"conflicting foundation mutation conditions")
  H.contains(rejected.error,"minecraft:sand");H.contains(rejected.error,"minecraft:stone")
  H.equal(requests,0)
end)

H.test("restart recovery returns identifiable raw scanner output one at a time for later storage analysis", function()
  local scans = 0
  local driver = {}
  function driver.inspect_stack(raw)
    if raw.name == "raw-drone" then return nil, "bee analysis is required" end
    if raw.name == "analyzed-drone" then return decoded("drone", raw.uid, raw.size) end
    return nil, "not a bee"
  end
  function driver.identify_stack(raw, context)
    if raw.name ~= "raw-drone" then return nil, "not a configured bee" end
    return {caste="drone", size=raw.size, maxSize=64, inventory=context.role, slot=context.slot}
  end
  function driver.scan_generation(adapter, transport)
    scans = scans + 1
    local raw = adapter._test_inventories[0].slots[transport.slot]
    H.equal(raw.name, "raw-drone")
    adapter._test_inventories[0].slots[transport.slot] = {
      name="analyzed-drone", uid="analyzed-" .. transport.slot, size=1
    }
    return {operation="scanning", safe=true, complete=true, scanned=true,
      identity={caste="drone", active="analyzed-" .. transport.slot, inactive="analyzed-" .. transport.slot},
      location="bee_storage"}
  end
  local adapter, inventories, transfers = fixture(driver, 6)
  adapter._test_inventories = inventories
  inventories[2].slots[2] = {name="raw-drone", size=2, maxSize=64}

  local recovered = assert(adapter:recover_pending())
  H.equal(#recovered, 2)
  H.equal(recovered[1].inventory, "bee_storage")
  H.equal(recovered[1].slot, 1)
  H.truthy(recovered[1].analysis_required)
  H.equal(recovered[2].slot, 2)
  H.falsy(inventories[2].slots[2])
  H.falsy(inventories[0].slots[6])
  H.equal(transfers[1].count, 1)
  H.equal(transfers[2].count, 1)
  H.truthy(adapter:prepare_storage())
  H.equal(scans, 2)
  H.equal(assert(adapter:snapshot_storage()).bees[1].active, "analyzed-1")
end)

H.test("raw restart recovery covers configured scanner breeder and recovery slots", function()
  local cases = {
    {role="scanner", side=2, slot=1},
    {role="scanner", side=2, slot=2},
    {role="breeder", side=1, slot=1},
    {role="breeder", side=1, slot=2},
    {role="breeder", side=1, slot=3},
    {role="recovery", side=3, slot=1}
  }
  for _, case in ipairs(cases) do
    local driver = {
      inspect_stack=function() return nil, "bee analysis is required" end,
      identify_stack=function(raw, context)
        H.equal(context.role, case.role)
        H.equal(context.slot, case.slot)
        return {caste="drone", size=raw.size, maxSize=64, inventory=context.role, slot=context.slot}
      end
    }
    local adapter, inventories, transfers = fixture(driver, 6)
    inventories[case.side].slots[case.slot] = {name="raw-drone", size=1, maxSize=64}
    local recovered = assert(adapter:recover_pending())
    H.equal(#recovered, 1)
    H.equal(recovered[1].inventory, "bee_storage")
    H.equal(recovered[1].slot, 1)
    H.falsy(inventories[case.side].slots[case.slot])
    H.falsy(inventories[0].slots[6])
    H.equal(#transfers, 1)
  end
end)

H.test("restart recovery never guesses a non-bee and preserves its observed location", function()
  local identifies = 0
  local driver = {
    inspect_stack=function() return nil, "not a bee" end,
    identify_stack=function()
      identifies = identifies + 1
      return {caste="drone", inventory="scanner", slot=2}
    end
  }
  local adapter, inventories, transfers = fixture(driver, 6)
  inventories[2].slots[2] = {name="hostile-item", size=1}
  local recovered, err = adapter:recover_pending()
  H.falsy(recovered)
  H.contains(err, "scanner slot 2")
  H.contains(err, "known recovery location")
  H.truthy(inventories[2].slots[2])
  H.equal(#transfers, 0)
  H.equal(identifies, 0)
end)

H.test("bounded raw recovery reports every returned and retained location when storage fills", function()
  local driver = {
    inspect_stack=function(raw)
      if raw.name == "raw-drone" then return nil, "bee analysis is required" end
      if raw.decoded then return util.copy(raw.decoded) end
      return nil, "not a bee"
    end,
    identify_stack=function(raw, context)
      if raw.name ~= "raw-drone" then return nil, "not a configured bee" end
      return {caste="drone", size=raw.size, maxSize=64, inventory=context.role, slot=context.slot}
    end
  }
  local adapter, inventories, transfers = fixture(driver, 3)
  inventories[0].slots[2] = {name="resident", size=1, decoded=decoded("drone", "resident", 1)}
  inventories[2].slots[2] = {name="raw-drone", size=2, maxSize=64}

  local recovered, err = adapter:recover_pending()
  H.falsy(recovered)
  H.contains(err, "bee_storage slot 1")
  H.contains(err, "scanner slot 2")
  H.equal(inventories[0].slots[1].size, 1)
  H.equal(inventories[2].slots[2].size, 1)
  H.falsy(inventories[0].slots[3])
  H.equal(#transfers, 1)
end)

local function opaque_driver(hidden, inspections)
  return {
    inspect_stack=function(_, context)
      local key = context.role .. ":" .. context.slot
      inspections[key] = (inspections[key] or 0) + 1
      local uid = assert(hidden[key], "missing hidden genome for " .. key)
      return decoded("drone", uid, 1, {hidden=uid})
    end
  }
end

H.test("identical raw descriptors decode independently at exact physical locations", function()
  local hidden = { ["bee_storage:1"]="alpha", ["bee_storage:2"]="beta" }
  local inspections = {}
  local adapter, inventories = fixture(opaque_driver(hidden, inspections), 6)
  local opaque = {name="opaque-drone", damage=0, size=1, maxSize=64}
  inventories[0].slots[1] = util.copy(opaque)
  inventories[0].slots[2] = util.copy(opaque)

  local snapshot = assert(adapter:snapshot_storage())
  H.equal(snapshot.bees[1].active, "alpha")
  H.equal(snapshot.bees[2].active, "beta")
  H.equal(inspections["bee_storage:1"], 1)
  H.equal(inspections["bee_storage:2"], 1)
  assert(adapter:snapshot_storage())
  H.equal(inspections["bee_storage:1"], 1)
  H.equal(inspections["bee_storage:2"], 1)
end)

H.test("decoded evidence migrates on verified splits and invalidates on automatic moves and hostile merges", function()
  local hidden = {
    ["bee_storage:1"]="alpha", ["scanner:1"]="wrong-input",
    ["scanner:2"]="beta", ["bee_storage:3"]="wrong-destination",
    ["bee_storage:4"]="gamma"
  }
  local inspections = {}
  local adapter, inventories = fixture(opaque_driver(hidden, inspections), 6)
  inventories[0].slots[1] = {name="opaque-drone", damage=0, size=2, maxSize=64}

  local source = assert(adapter:raw_stack("bee_storage", 1))
  H.equal(assert(adapter:decode(source, {role="bee_storage", slot=1})).active, "alpha")
  H.equal(assert(adapter:transfer_verified("bee_storage", 1, "scanner", 1, 1)), 1)
  H.equal(assert(adapter:decode(assert(adapter:raw_stack("bee_storage", 1)), {role="bee_storage", slot=1})).active, "alpha")
  H.equal(assert(adapter:decode(assert(adapter:raw_stack("scanner", 1)), {role="scanner", slot=1})).active, "alpha")
  H.falsy(inspections["scanner:1"])

  inventories[2].slots[1] = nil
  inventories[2].slots[2] = {name="opaque-drone", damage=0, size=1, maxSize=64}
  H.falsy(adapter:raw_stack("scanner", 1))
  H.equal(assert(adapter:decode(assert(adapter:raw_stack("scanner", 2)), {role="scanner", slot=2})).active, "beta")
  H.equal(assert(adapter:transfer_verified("scanner", 2, "bee_storage", 3, 1)), 1)
  H.equal(assert(adapter:decode(assert(adapter:raw_stack("bee_storage", 3)), {role="bee_storage", slot=3})).active, "beta")
  H.falsy(inspections["bee_storage:3"])

  inventories[0].slots[4] = {name="opaque-drone", damage=0, size=1, maxSize=64}
  H.equal(assert(adapter:decode(assert(adapter:raw_stack("bee_storage", 4)), {role="bee_storage", slot=4})).active, "gamma")
  hidden["bee_storage:3"] = "merged-observation"
  H.equal(assert(adapter:transfer_verified("bee_storage", 4, "bee_storage", 3, 1)), 1)
  H.equal(assert(adapter:decode(assert(adapter:raw_stack("bee_storage", 3)), {role="bee_storage", slot=3})).active, "merged-observation")
  H.equal(inspections["bee_storage:3"], 1)
end)

H.test("analyzer-return evidence is bound only to its exact final storage destination", function()
  local hidden = {
    ["bee_storage:1"]="resident", ["bee_storage:2"]="hostile-if-redecoded",
    ["scanner:2"]="hostile-source"
  }
  local inspections = {}
  local adapter, inventories = fixture(opaque_driver(hidden, inspections), 6)
  local opaque = {name="opaque-drone", damage=0, size=1, maxSize=64}
  inventories[0].slots[1] = util.copy(opaque)
  inventories[2].slots[2] = util.copy(opaque)
  local analyzer = decoded("drone", "analyzer-genome", 1, {hidden="analyzer-genome"})

  local ok, evidence = adapter:return_output("scanner", 2, analyzer)
  H.truthy(ok)
  H.equal(evidence.slot, 2)
  H.equal(assert(adapter:decode(assert(adapter:raw_stack("bee_storage", 1)), {role="bee_storage", slot=1})).active, "resident")
  H.equal(assert(adapter:decode(assert(adapter:raw_stack("bee_storage", 2)), {role="bee_storage", slot=2})).active, "analyzer-genome")
  H.falsy(inspections["bee_storage:2"])
  H.falsy(inventories[2].slots[2])
  H.falsy(inventories[0].slots[6])
end)

return true
