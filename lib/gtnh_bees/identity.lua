local util = require("gtnh_bees.util")
local M = {}

local uid_fields = {"uid", "UID", "identifier", "speciesUid", "speciesUID"}
local uid_methods = {"getUID", "getUid", "getIdentifier"}

local function add_candidate(candidates, value)
  if type(value) == "string" then
    value = util.trim(value)
    if value ~= "" then candidates[value] = true end
  end
end

local function protected_member(value, key)
  local ok, member = pcall(function() return value[key] end)
  if ok then return member end
  return nil
end

local function inspect(value, candidates, visited, depth)
  if depth > 5 then return end
  local kind = type(value)
  if kind == "string" then add_candidate(candidates, value); return end
  if kind == "function" then
    local ok, result = pcall(value)
    if ok then inspect(result, candidates, visited, depth + 1) end
    return
  end
  if kind ~= "table" and kind ~= "userdata" then return end
  if visited[value] then return end
  visited[value] = true

  for _, key in ipairs(uid_fields) do add_candidate(candidates, protected_member(value, key)) end
  for _, key in ipairs(uid_methods) do
    local method = protected_member(value, key)
    if type(method) == "function" then
      local ok, result = pcall(method, value)
      if not ok then ok, result = pcall(method) end
      if ok then inspect(result, candidates, visited, depth + 1) end
    end
  end

  if kind == "table" then
    local mt = getmetatable(value)
    if mt and type(mt.__call) == "function" then
      local ok, result = pcall(value)
      if ok then inspect(result, candidates, visited, depth + 1) end
    end
    if #value == 1 then inspect(value[1], candidates, visited, depth + 1) end
  end
end

function M.uid(value)
  local candidates = {}
  inspect(value, candidates, {}, 0)
  local keys = util.sorted_keys(candidates)
  if #keys == 1 then return keys[1] end
  if #keys == 0 then return nil, "species UID is missing or has an unsupported representation" end
  return nil, "species UID is ambiguous: " .. table.concat(keys, ", ")
end

function M.label(value, fallback)
  if type(value) == "string" and util.trim(value) ~= "" then return util.trim(value) end
  if type(value) == "table" or type(value) == "userdata" then
    for _, key in ipairs({"displayName", "label", "name"}) do
      local candidate = protected_member(value, key)
      if type(candidate) == "string" and util.trim(candidate) ~= "" then return util.trim(candidate) end
    end
    for _, key in ipairs({"getName", "getDisplayName"}) do
      local method = protected_member(value, key)
      if type(method) == "function" then
        local ok, candidate = pcall(method, value)
        if ok and type(candidate) == "string" and util.trim(candidate) ~= "" then return util.trim(candidate) end
      end
    end
  end
  return fallback
end

return M
