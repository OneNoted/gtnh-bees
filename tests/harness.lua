local util = require("gtnh_bees.util")
local H = {tests={}}

function H.test(name, fn) H.tests[#H.tests + 1] = {name=name, fn=fn} end
function H.truthy(value, message) if not value then error(message or "expected a truthy value", 2) end end
function H.falsy(value, message) if value then error(message or "expected a false value", 2) end end
function H.equal(actual, expected, message)
  if not util.deep_equal(actual, expected) then error((message or "values differ") .. "\nactual: " .. util.canonical(actual) .. "\nexpected: " .. util.canonical(expected), 2) end
end
function H.contains(value, fragment) if not tostring(value):find(fragment, 1, true) then error("'" .. tostring(value) .. "' does not contain '" .. fragment .. "'", 2) end end

function H.run()
  local failures = {}
  for _, item in ipairs(H.tests) do
    local ok, err = pcall(item.fn)
    if ok then io.write("ok - ", item.name, "\n") else failures[#failures + 1] = {name=item.name, err=err}; io.write("not ok - ", item.name, "\n") end
  end
  io.write(string.format("\n%d tests, %d passed, %d failed\n", #H.tests, #H.tests-#failures, #failures))
  for _, failure in ipairs(failures) do io.write("FAIL ", failure.name, ": ", tostring(failure.err), "\n") end
  return #failures == 0, #H.tests
end
return H
