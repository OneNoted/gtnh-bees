local M = {}

local function callable(value)
  if type(value) == "function" then return true end
  local kind = type(value)
  if kind ~= "table" and kind ~= "userdata" then return false end
  local ok, mt = pcall(getmetatable, value)
  return ok and type(mt) == "table" and type(mt.__call) == "function"
end

function M.exists(proxy, method)
  if not proxy or type(method) ~= "string" or method == "" then return false end
  local ok, member = pcall(function() return proxy[method] end)
  return ok and member ~= nil and callable(member)
end

function M.invoke(component, proxy, address, method, ...)
  if type(method) ~= "string" or method == "" then return nil, "component method name is required" end
  if component and callable(component.invoke) then
    local ok, a, b, c, d = pcall(component.invoke, address, method, ...)
    if not ok then return nil, tostring(a) end
    return true, a, b, c, d
  end
  local ok_member, member = pcall(function() return proxy and proxy[method] end)
  if not ok_member or not callable(member) then return nil, "component method '" .. method .. "' is unavailable" end
  local ok, a, b, c, d = pcall(member, ...)
  if not ok then return nil, tostring(a) end
  return true, a, b, c, d
end

M.callable = callable
return M
