local M = {}

function M.finite_integer(value, minimum, maximum)
  if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge or value ~= math.floor(value) then
    return false
  end
  if minimum ~= nil and value < minimum then return false end
  if maximum ~= nil and value > maximum then return false end
  return true
end

function M.sorted_keys(t)
  local keys = {}
  for key in pairs(t or {}) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  return keys
end

function M.copy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local out = {}
  seen[value] = out
  for key, item in pairs(value) do out[M.copy(key, seen)] = M.copy(item, seen) end
  return out
end

local function scalar(value)
  local kind = type(value)
  if kind == "nil" then return "nil" end
  if kind == "boolean" or kind == "number" then return tostring(value) end
  if kind == "string" then return string.format("%q", value) end
  return "<" .. kind .. ":" .. tostring(value) .. ">"
end

function M.canonical(value, seen)
  if type(value) ~= "table" then return scalar(value) end
  seen = seen or {}
  if seen[value] then return "<cycle>" end
  seen[value] = true
  local pieces = {}
  for _, key in ipairs(M.sorted_keys(value)) do
    pieces[#pieces + 1] = M.canonical(key, seen) .. "=" .. M.canonical(value[key], seen)
  end
  seen[value] = nil
  return "{" .. table.concat(pieces, ",") .. "}"
end

function M.deep_equal(a, b)
  return M.canonical(a) == M.canonical(b)
end

function M.trim(s)
  return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.lower(s) return string.lower(M.trim(s)) end

function M.set(list)
  local result = {}
  for _, value in ipairs(list or {}) do result[value] = true end
  return result
end

function M.count(t)
  local n = 0
  for _ in pairs(t or {}) do n = n + 1 end
  return n
end

function M.merge(a, b)
  local out = M.copy(a or {})
  for key, value in pairs(b or {}) do out[key] = M.copy(value) end
  return out
end

return M
