local H = require("tests.harness")
local identity = require("gtnh_bees.identity")
local Catalog = require("gtnh_bees.catalog")
local Planner = require("gtnh_bees.planner")
local Inventory = require("gtnh_bees.inventory")
local bounded = require("gtnh_bees.bounded")

H.test("UID accepts a direct string", function() H.equal(identity.uid(" forestry.alpha "), "forestry.alpha") end)
H.test("UID accepts an allele-like field", function() H.equal(identity.uid({UID="forestry.beta"}), "forestry.beta") end)
H.test("UID accepts a bound method", function() H.equal(identity.uid({getUID=function() return "forestry.gamma" end}), "forestry.gamma") end)
H.test("UID accepts an unambiguous callable proxy", function()
  local value = setmetatable({}, {__call=function() return {uid="forestry.delta"} end})
  H.equal(identity.uid(value), "forestry.delta")
end)
H.test("UID accepts a callable function representation", function() H.equal(identity.uid(function() return {uid="forestry.epsilon"} end),"forestry.epsilon") end)
H.test("UID rejects conflicting representations", function()
  local uid, err = identity.uid({uid="one", getUID=function() return "two" end})
  H.falsy(uid); H.contains(err, "ambiguous")
end)
H.test("UID rejects malformed values", function() local uid, err = identity.uid({name="label only"}); H.falsy(uid); H.contains(err, "missing") end)

local function catalog_fixture(reverse)
  local species = {{uid="a", name="Twin"}, {uid="b", name="Twin"}, {uid="c", name="Child"}, {uid="d", name="Other"}}
  local routes = {
    {result="c", parents={"a","b"}, chance=20, conditions={"rain"}},
    {result="c", parents={"a","d"}, chance=40, conditions={}}
  }
  if reverse then routes[1],routes[2]=routes[2],routes[1] end
  local adapter = {list_species=function() return species end, list_mutations=function() return routes end}
  return assert(Catalog.discover(adapter))
end

H.test("duplicate labels remain distinct UIDs", function()
  local catalog = catalog_fixture(); H.truthy(catalog.species.a); H.truthy(catalog.species.b)
  local uid, err = catalog:resolve("Twin"); H.falsy(uid); H.contains(err, "a, b")
end)
H.test("UID disambiguates a duplicate label", function() H.equal(catalog_fixture():resolve("b"), "b") end)
H.test("unknown label gives suggestions", function() local uid, err = catalog_fixture():resolve("Chlid"); H.falsy(uid); H.contains(err, "Child") end)
H.test("malformed discovery never returns a partial catalog", function()
  local adapter={list_species=function() return {{uid="a",name="A"},{name="broken"}} end,list_mutations=function() return {} end}
  local catalog, err=Catalog.discover(adapter); H.falsy(catalog); H.contains(err,"species entry 2")
end)
H.test("failed mutation discovery aborts the graph", function()
  local adapter={list_species=function() return {{uid="a"}} end,list_mutations=function() error("bridge down") end}
  local catalog, err=Catalog.discover(adapter); H.falsy(catalog); H.contains(err,"bridge down")
end)

H.test("reachability uses cross-species role stock", function()
  local catalog=catalog_fixture()
  local reached=Planner.reachable(catalog,{princess={a=true},drone={b=true}})
  H.truthy(reached.targets.c); H.truthy(reached.roles.princess.c); H.truthy(reached.roles.drone.c)
end)
H.test("a same-role pair does not unlock a mutation", function()
  local catalog=catalog_fixture(); local reached=Planner.reachable(catalog,{princess={a=true,b=true},drone={}})
  H.falsy(reached.targets.c)
end)
H.test("convertible drone stock grants princess capability", function()
  local catalog=catalog_fixture(); local reached=Planner.reachable(catalog,{princess={a=true},drone={d=true},convertible={d=true}})
  H.truthy(reached.roles.princess.d)
end)
H.test("route ranking is independent of insertion order", function()
  local roles={princess={a=true},drone={b=true,d=true}}
  local one=Planner.rank_routes(catalog_fixture(false).routes_by_result.c,roles)[1]
  local two=Planner.rank_routes(catalog_fixture(true).routes_by_result.c,roles)[1]
  H.equal(one.key,two.key); H.equal(one.parents,{"a","d"})
end)
H.test("condition identities are mapped for route scoring", function()
  local catalog=Catalog.new({Arid={policy="unmet"},Stone={policy="foundation",foundation="minecraft:stone"}}); assert(catalog:add_species({uid="a"})); assert(catalog:add_species({uid="b"})); assert(catalog:add_species({uid="c"}))
  local route=assert(catalog:add_route({result="c",parents={"a","b"},conditions={climate="Arid",foundation={identity="Stone",satisfied=true,foundation="evil:bypass"}}}))
  H.equal(#route.conditions,2);H.falsy(route.conditions[2].satisfied);H.equal(route.conditions[2].foundation,"minecraft:stone")
end)
H.test("currently feasible route outranks higher chance infeasible route", function()
  local catalog=catalog_fixture(); local ranked=Planner.rank_routes(catalog.routes_by_result.c,{princess={a=true},drone={b=true}})
  H.equal(ranked[1].parents,{"a","b"})
end)
H.test("fixed targets remain missing after failure", function()
  local state=Planner.fixed_targets({targets={a=true,b=true}}); state:fail("a","route failed"); state:complete("b")
  H.equal(state:missing(),{{uid="a",reason="route failed"}})
end)

local function bee(caste, active, inactive, genome, slot, size)
  return assert(Inventory.bee({caste=caste,active=active,inactive=inactive,genome=genome,scanned=true,size=size or 1,maxSize=64},{inventory="bee_storage",slot=slot}))
end
H.test("pure drone count excludes mixed drones and reserved slot", function()
  local snapshot={size=4,reserved_slot=4,bees={bee("drone","a","a",{x=1},1,20),bee("drone","a","b",{x=1},2,40),bee("drone","a","a",{x=1},4,64)}}
  H.equal(Inventory.pure_drone_count(snapshot,"a"),20)
end)
H.test("population pair requires complete genome equivalence", function()
  local snapshot={reserved_slot=4,bees={bee("princess","a","a",{speed="fast",life=2},1),bee("drone","a","a",{speed="slow",life=2},2)}}
  local pair,err=Inventory.population_pair(snapshot,"a"); H.falsy(pair); H.contains(err,"full-genome")
end)
H.test("population pair accepts equal full genomes", function()
  local snapshot={reserved_slot=4,bees={bee("princess","a","a",{speed="fast"},1),bee("drone","a","a",{speed="fast"},2)}}
  local princess,drone=Inventory.population_pair(snapshot,"a"); H.equal(princess.slot,1); H.equal(drone.slot,2)
end)
H.test("destination merges before an empty slot", function()
  local stored=bee("drone","a","a",{x=1},2,20); local incoming=bee("drone","a","a",{x=1},9,3)
  local destination=assert(Inventory.destination({size=5,reserved_slot=5,bees={stored}},incoming)); H.equal(destination,{slot=2,merge=true,count=3})
end)
H.test("destination fills a compatible stack before an empty slot", function()
  local stored=bee("drone","a","a",{x=1},1,63); local incoming=bee("drone","a","a",{x=1},9,3)
  local plan=assert(Inventory.destinations({size=4,reserved_slot=4,bees={stored}},incoming)); H.equal(plan,{{slot=1,merge=true,count=1},{slot=2,merge=false,count=2}})
end)
H.test("full ordinary storage never allocates reserved slot", function()
  local stored={}; for slot=1,3 do stored[#stored+1]=bee("drone",tostring(slot),tostring(slot),{x=slot},slot,64) end
  local destination,err=Inventory.destination({size=4,reserved_slot=4,bees=stored},bee("drone","z","z",{x=9},9)); H.falsy(destination); H.contains(err,"reserved")
end)
H.test("template validation requires a scanned drone", function()
  local snapshot={reserved_slot=4,bees={bee("princess","a","a",{},4)}}; local value,err=Inventory.template(snapshot); H.falsy(value); H.contains(err,"drone")
end)

H.test("bounded polling terminates under permanent failure", function()
  local calls=0; local value,err,steps=bounded.poll({limit=3,accept=function() return false end,timeout_message="done waiting"},function() calls=calls+1; return false end)
  H.falsy(value); H.equal(calls,3); H.equal(steps,3); H.contains(err,"done waiting")
end)
