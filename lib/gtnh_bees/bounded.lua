local util = require("gtnh_bees.util")
local M = {}

function M.repeat_until(options, action, finished)
  options = options or {}
  local limit = assert(options.limit, "a finite step limit is required")
  if not util.finite_integer(limit, 1) then
    return nil, "step limit must be a finite positive integer"
  end
  for step = 1, limit do
    local ok, value, detail = action(step)
    if not ok then return nil, value or "bounded action failed", step end
    local done, result = finished(value, detail, step)
    if done then return result == nil and value or result, nil, step end
  end
  return nil, options.timeout_message or ("operation exceeded " .. limit .. " steps"), limit
end

function M.poll(options, observe, sleep)
  options = options or {}
  return M.repeat_until(options, function(step)
    local ok, state = pcall(observe, step)
    if not ok then return false, state end
    return true, state
  end, function(state, _, step)
    if options.accept(state) then return true, state end
    if step < options.limit and sleep then sleep(options.interval or 0) end
    return false
  end)
end

return M
