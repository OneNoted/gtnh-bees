local identity = require("gtnh_bees.identity")
local util = require("gtnh_bees.util")
local Catalog = {}
Catalog.__index = Catalog

local function values(collection, label)
  label = label or "API collection"
  if type(collection) ~= "table" then return nil, label .. " is not a Lua-visible table" end
  local numeric, mapped, maximum = 0, 0, 0
  local map_keys = {}
  for key in next, collection do
    if type(key) == "number" then
      if key ~= key or key == math.huge or key == -math.huge or key < 1 or key ~= math.floor(key) then
        return nil, label .. " has a non-positive, fractional, or non-finite numeric key"
      end
      numeric = numeric + 1
      if key > maximum then maximum = key end
    else
      if type(key) ~= "string" then return nil, label .. " map keys must be strings" end
      mapped = mapped + 1
      map_keys[#map_keys + 1] = key
    end
  end
  if numeric > 0 and mapped > 0 then return nil, label .. " mixes array and map keys" end

  local out = {}
  if numeric > 0 then
    if maximum ~= numeric then return nil, label .. " array is sparse or contains a hole" end
    for index = 1, maximum do
      local item = rawget(collection, index)
      if item == nil then return nil, label .. " array is sparse or contains a hole" end
      out[#out + 1] = item
    end
  else
    table.sort(map_keys)
    for _, key in ipairs(map_keys) do out[#out + 1] = rawget(collection, key) end
  end
  return out
end

local function chance_number(value)
  if value==nil then return nil end
  if type(value)~="number"then return nil,"mutation chance is present but not numeric"end
  if value~=value or value==math.huge or value==-math.huge then return nil,"mutation chance must be finite"end
  if value<0 or value>100 then return nil,"mutation chance must be in the official percentage range 0..100"end
  return value
end

local function mapped_condition(identity_value, mappings)
  if type(mappings)~="table" then return nil,"condition mappings are malformed" end
  local rule=rawget(mappings,identity_value)
  if rule==nil then return {identity=identity_value,description=identity_value,satisfied=false} end
  if type(rule)~="table" then return nil,"condition mapping for '"..identity_value.."' is malformed" end
  local policy=rawget(rule,"policy")
  if policy=="satisfied" then return {identity=identity_value,description=identity_value,satisfied=true} end
  if policy=="unmet" then return {identity=identity_value,description=identity_value,satisfied=false} end
  local foundation=rawget(rule,"foundation")
  if policy=="foundation" and type(foundation)=="string" then
    return {identity=identity_value,description=identity_value,satisfied=false,foundation=foundation}
  end
  return nil,"condition mapping for '"..identity_value.."' has no validated satisfaction policy"
end

local condition_fields={identity=true,description=true,satisfied=true,foundation=true,policy=true}

local function condition_identity(value)
  if type(value)~="table" then return nil,"mutation condition entry is malformed" end
  for key in next,value do
    if type(key)~="string" or not condition_fields[key] then
      return nil,"mutation condition table is ambiguous; it must contain only one identity and optional ignored policy-looking fields"
    end
  end
  local identity_value=rawget(value,"identity")
  if type(identity_value)~="string" or identity_value=="" then
    return nil,"mutation condition table must contain one nonempty exact string identity"
  end
  return identity_value
end

local function normalize_condition(value,mappings)
  local identity_value=value
  if type(value)=="table" then
    local err
    identity_value,err=condition_identity(value)
    if not identity_value then return nil,err end
  elseif type(value)~="string" then
    return nil,"mutation condition entry is malformed"
  end
  if identity_value=="" then return nil,"mutation condition identity must be a nonempty exact string" end
  return mapped_condition(identity_value,mappings)
end

local function normalize_conditions(value, mappings)
  if value == nil then return {} end
  if type(value) == "string" then
    local condition,err=normalize_condition(value,mappings)
    return condition and {condition} or nil,err
  end
  if type(value) ~= "table" then return nil, "mutation conditions have an unsupported representation" end
  if rawget(value,"identity")~=nil then
    local condition,err=normalize_condition(value,mappings)
    return condition and {condition} or nil,err
  end
  local out = {}
  local entries,entries_err=values(value,"mutation conditions")
  if not entries then return nil,entries_err end
  for _, item in ipairs(entries) do
    local condition,condition_err=normalize_condition(item,mappings)
    if not condition then return nil,condition_err end
    out[#out+1]=condition
  end
  return out
end

function Catalog.new(condition_mappings)
  if condition_mappings==nil then condition_mappings={} end
  return setmetatable({species={}, labels={}, routes={}, routes_by_result={},condition_mappings=condition_mappings}, Catalog)
end

function Catalog:add_species(raw)
  local uid, err = identity.uid(raw)
  if not uid then return nil, err end
  local label = identity.label(raw, uid)
  local existing = self.species[uid]
  if existing then
    if existing.label ~= label then return nil, "species " .. uid .. " has conflicting labels" end
    return existing
  end
  local record = {uid=uid, label=label, raw=raw}
  self.species[uid] = record
  local key = util.lower(label)
  self.labels[key] = self.labels[key] or {}
  self.labels[key][#self.labels[key] + 1] = uid
  table.sort(self.labels[key])
  return record
end

local function route_parents(raw)
  local parents=rawget(raw,"parents")
  local has_parents=parents~=nil
  local has_parent1=rawget(raw,"parent1")~=nil
  local has_parent2=rawget(raw,"parent2")~=nil
  local has_first=rawget(raw,"first")~=nil
  local has_second=rawget(raw,"second")~=nil
  local has_scalar=has_parent1 or has_parent2 or has_first or has_second

  if has_parents then
    if has_scalar then return nil,nil,"mutation supplies both parents and scalar parent representations" end
    if type(parents)~="table" then return nil,nil,"mutation parents must be an exact contiguous two-item array" end
    local count=0
    for key in next,parents do
      if type(key)~="number" or (key~=1 and key~=2) then
        return nil,nil,"mutation parents must be an exact contiguous two-item array with no extra keys"
      end
      count=count+1
    end
    if count~=2 or rawget(parents,1)==nil or rawget(parents,2)==nil then
      return nil,nil,"mutation parents must be an exact contiguous two-item array"
    end
    return rawget(parents,1),rawget(parents,2)
  end

  local canonical=has_parent1 or has_parent2
  local legacy=has_first or has_second
  if canonical and legacy then return nil,nil,"mutation supplies conflicting scalar parent representations" end
  if canonical then
    if not has_parent1 or not has_parent2 then return nil,nil,"mutation parent1 and parent2 must be supplied as a complete pair" end
    return rawget(raw,"parent1"),rawget(raw,"parent2")
  end
  if legacy then
    if not has_first or not has_second then return nil,nil,"mutation first and second parents must be supplied as a complete pair" end
    return rawget(raw,"first"),rawget(raw,"second")
  end
  return nil,nil,"mutation route has no complete parent representation"
end

function Catalog:add_route(raw)
  if type(raw) ~= "table" then return nil, "mutation route is not a table" end
  local result, err = identity.uid(raw.result or raw.offspring or raw.species)
  if not result then return nil, "mutation result: " .. err end
  local a,b,parent_err=route_parents(raw)
  if parent_err then return nil,parent_err end
  a, err = identity.uid(a)
  if not a then return nil, "first mutation parent: " .. err end
  b, err = identity.uid(b)
  if not b then return nil, "second mutation parent: " .. err end
  if not self.species[result] or not self.species[a] or not self.species[b] then
    return nil, "mutation references a species absent from the enumerated catalog"
  end
  if b < a then a, b = b, a end
  if rawget(raw,"conditions")~=nil and rawget(raw,"condition")~=nil then
    return nil,"mutation supplies both conditions and condition representations"
  end
  local condition_value=rawget(raw,"conditions")
  if condition_value==nil then condition_value=rawget(raw,"condition") end
  local conditions
  conditions, err = normalize_conditions(condition_value,self.condition_mappings)
  if not conditions then return nil, err end
  local chance
  chance,err=chance_number(raw.chance)
  if raw.chance~=nil and chance==nil then return nil,err end
  local route = {result=result, parents={a, b}, chance=chance, conditions=conditions, raw=raw}
  route.key = result .. "\0" .. a .. "\0" .. b .. "\0" .. tostring(route.chance) .. "\0" .. util.canonical(conditions)
  self.routes[#self.routes + 1] = route
  self.routes_by_result[result] = self.routes_by_result[result] or {}
  self.routes_by_result[result][#self.routes_by_result[result] + 1] = route
  return route
end

function Catalog.discover(adapter)
  local ok, species_or_error = pcall(function() return adapter:list_species() end)
  if not ok then return nil, "species discovery failed: " .. tostring(species_or_error) end
  local species, err = values(species_or_error)
  if not species then return nil, "species discovery failed: " .. err end
  if #species == 0 then return nil, "species discovery returned no species" end
  local candidate = Catalog.new(adapter.config and adapter.config.mutation_conditions)
  for index, raw in ipairs(species) do
    local added
    added, err = candidate:add_species(raw)
    if not added then return nil, "species entry " .. index .. ": " .. err end
  end
  local ok_routes, routes_or_error = pcall(function() return adapter:list_mutations() end)
  if not ok_routes then return nil, "mutation discovery failed: " .. tostring(routes_or_error) end
  local routes
  routes, err = values(routes_or_error)
  if not routes then return nil, "mutation discovery failed: " .. err end
  for index, raw in ipairs(routes) do
    local added
    added, err = candidate:add_route(raw)
    if not added then return nil, "mutation entry " .. index .. ": " .. err end
  end
  table.sort(candidate.routes, function(a, b) return a.key < b.key end)
  for _, group in pairs(candidate.routes_by_result) do table.sort(group, function(a, b) return a.key < b.key end) end
  return candidate
end

local function distance(a, b)
  local previous = {}
  for j = 0, #b do previous[j] = j end
  for i = 1, #a do
    local current = {[0]=i}
    for j = 1, #b do
      local cost = a:sub(i,i) == b:sub(j,j) and 0 or 1
      current[j] = math.min(current[j-1]+1, previous[j]+1, previous[j-1]+cost)
    end
    previous = current
  end
  return previous[#b]
end

function Catalog:resolve(text)
  if type(text) ~= "string" or util.trim(text) == "" then return nil, "species is required" end
  text = util.trim(text)
  if self.species[text] then return text end
  local matches = self.labels[util.lower(text)]
  if matches and #matches == 1 then return matches[1] end
  if matches then return nil, "label '" .. text .. "' is ambiguous; use one of: " .. table.concat(matches, ", ") end
  local scored = {}
  for uid, record in pairs(self.species) do scored[#scored + 1] = {uid=uid, label=record.label, score=distance(util.lower(text), util.lower(record.label))} end
  table.sort(scored, function(a,b) if a.score ~= b.score then return a.score < b.score end return a.uid < b.uid end)
  local suggestions = {}
  for i = 1, math.min(3, #scored) do suggestions[#suggestions + 1] = scored[i].label .. " (" .. scored[i].uid .. ")" end
  local suffix = #suggestions > 0 and "; nearest: " .. table.concat(suggestions, ", ") or ""
  return nil, "unknown species '" .. text .. "'" .. suffix
end

function Catalog:label(uid) return self.species[uid] and self.species[uid].label or uid end
return Catalog
