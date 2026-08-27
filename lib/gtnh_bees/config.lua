local util = require("gtnh_bees.util")
local Config = {}

Config.default_path = "/etc/gtnh-bees.cfg"
Config.defaults = {
  archive_size=32,
  complete_imprint="all",
  limits={breeding=128, archive=256, scanning=40, conversion=128, conversion_generations=8, imprint=128, mutation_generations=8, transfer=8, robot_attempts=3, robot_timeout=8},
  network={foundation_port=24193}
}

local function positive_integer_array(value)
  if type(value) ~= "table" then return nil, "must be a table" end
  local count, maximum = 0, 0
  for key in next, value do
    if not util.finite_integer(key,1) then return nil, "must be a contiguous array" end
    count = count + 1
    if key > maximum then maximum = key end
  end
  if count == 0 then return nil, "must not be empty" end
  if maximum ~= count then return nil, "must be a contiguous array without holes" end
  for index = 1, maximum do
    if rawget(value, index) == nil then return nil, "must be a contiguous array without holes" end
  end
  return count
end

local function quote(value) return string.format("%q", value) end
local function serialize(value, depth)
  depth = depth or 0
  local kind = type(value)
  if kind == "string" then return quote(value) end
  if kind == "number" or kind == "boolean" then return tostring(value) end
  if kind ~= "table" then error("configuration contains unsupported " .. kind) end
  local indent, child = string.rep("  ", depth), string.rep("  ", depth + 1)
  local parts = {"{"}
  for _, key in ipairs(util.sorted_keys(value)) do
    local rendered_key = type(key) == "string" and key:match("^[%a_][%w_]*$") and key or "[" .. serialize(key, depth + 1) .. "]"
    parts[#parts + 1] = "\n" .. child .. rendered_key .. "=" .. serialize(value[key], depth + 1) .. ","
  end
  parts[#parts + 1] = "\n" .. indent .. "}"
  return table.concat(parts)
end

function Config.validate(config)
  if type(config) ~= "table" then return nil, "configuration must be a table" end
  if config.limits~=nil and type(config.limits)~="table" then return nil,"configuration limits must be a table"end
  if config.network~=nil and type(config.network)~="table" then return nil,"configuration network must be a table"end
  local network=config.network or {}
  local foundation_port=network.foundation_port
  if foundation_port==nil then foundation_port=Config.defaults.network.foundation_port end
  if not util.finite_integer(foundation_port,1,65535) then
    return nil,"network.foundation_port must be a finite integer from 1 through 65535"
  end
  local driver_module=config.driver_module or "gtnh_bees.official_driver"
  if type(driver_module)~="string" or driver_module=="" then return nil,"driver_module must name a Lua module" end
  local complete_imprint=config.complete_imprint
  if complete_imprint==nil then complete_imprint=Config.defaults.complete_imprint end
  if complete_imprint~="none" and complete_imprint~="all" then return nil,"complete_imprint must be 'none' or 'all'" end
  local official=driver_module=="gtnh_bees.official_driver"
  if type(config.roles) ~= "table" then return nil, "configuration has no hardware roles" end
  local required = {"genetics", "bee_storage", "breeder", "scanner", "recovery"}
  for _, name in ipairs(required) do if type(config.roles[name]) ~= "table" then return nil, "missing hardware role '" .. name .. "'" end end
  local endpoints = {}
  for role, value in pairs(config.roles) do
    if type(value) ~= "table" or type(value.address) ~= "string" or value.address == "" then return nil, "role '" .. role .. "' needs a component address" end
    if role ~= "genetics" and role ~= "foundation_modem" and role ~= "foundation_data" then
      if not util.finite_integer(value.side,0,5) then
        return nil, "role '" .. role .. "' needs an integer transposer side from 0 through 5"
      end
      local key = value.address .. ":" .. tostring(value.side)
      if endpoints[key] and endpoints[key] ~= role then return nil, "roles '" .. endpoints[key] .. "' and '" .. role .. "' ambiguously share an endpoint" end
      endpoints[key] = role
    end
  end
  if not util.finite_integer(config.archive_size,32) then return nil,"archive_size must be a finite integer of at least 32" end
  local storage = config.roles.bee_storage
  if not util.finite_integer(storage.reserved_slot,1) then return nil, "bee_storage needs its final reserved_slot" end
  if official then
    if type(storage.caste_items)~="table" or next(storage.caste_items)==nil then return nil,"bee_storage needs an exact item-name to caste mapping for the official driver" end
    local castes = {}
    for item_name, caste in pairs(storage.caste_items) do
      if type(item_name) ~= "string" or item_name == "" or not ({princess=true, drone=true, queen=true})[caste] then
        return nil, "bee_storage.caste_items must map exact item names to princess, drone, or queen"
      end
      castes[caste] = true
    end
    if not castes.princess or not castes.drone or not castes.queen then return nil, "bee_storage.caste_items needs princess, drone, and queen item names" end
    for _, field in ipairs({"species_method","mutations_method","inspect_method","scan_method","breed_method","convert_method","imprint_method"}) do
      if config.roles.genetics[field] ~= nil then return nil, "genetics." .. field .. " is obsolete for the official fixed-callback driver" end
    end
    local scanner = config.roles.scanner
    if type(scanner.component_address)~="string"or scanner.component_address==""or not util.finite_integer(scanner.input_slot,1)then return nil,"scanner needs official analyzer component_address and input_slot"end
    local breeder = config.roles.breeder
    if not util.finite_integer(breeder.princess_slot,1) or not util.finite_integer(breeder.drone_slot,1) or breeder.princess_slot == breeder.drone_slot then return nil,"breeder needs distinct positive princess_slot and drone_slot values"end
    if breeder.terminal_stable_polls~=nil and not util.finite_integer(breeder.terminal_stable_polls,2) then return nil,"breeder.terminal_stable_polls must be a finite integer of at least 2"end
    for _, role_name in ipairs({"scanner", "breeder", "recovery"}) do
      local role = config.roles[role_name]
      local output_count = positive_integer_array(role.output_slots)
      if not output_count then return nil, role_name .. " needs explicit recoverable output_slots as a contiguous array" end
      local seen = {}
      for index = 1, output_count do
        local slot = role.output_slots[index]
        if not util.finite_integer(slot,1) then return nil, role_name .. " output_slots must contain finite positive integers" end
        if seen[slot] then return nil, role_name .. " output_slots contains a duplicate slot" end
        seen[slot] = true
      end
    end
    for _, slot in ipairs(breeder.output_slots) do
      if slot == breeder.princess_slot or slot == breeder.drone_slot then
        return nil, "breeder output_slots must be distinct from princess_slot and drone_slot"
      end
    end
    for _,slot in ipairs(scanner.output_slots)do
      if slot==scanner.input_slot then return nil,"scanner output_slots must be distinct from input_slot"end
    end
    if breeder.minimum_outputs ~= nil and not util.finite_integer(breeder.minimum_outputs,1,#breeder.output_slots) then
      return nil, "breeder.minimum_outputs must be a positive integer no larger than output_slots"
    end
  end
  for key, value in pairs(config.limits or {}) do
    if not util.finite_integer(value,1) then return nil, "limit '" .. key .. "' must be a finite positive integer" end
  end
  if config.roles.foundation_modem then
    if type(network.robot_address)~="string"or network.robot_address==""then return nil,"foundation network needs pinned robot_address"end
    if type(network.shared_secret)~="string"or #network.shared_secret<16 then return nil,"foundation network shared_secret must contain at least 16 bytes"end
    if type(network.replay_epoch)~="string"or #network.replay_epoch<16 or network.replay_epoch:find("|",1,true)then return nil,"foundation network replay_epoch must contain at least 16 bytes and no '|'"end
    if type(config.roles.foundation_data)~="table"or type(config.roles.foundation_data.address)~="string"then return nil,"foundation authentication needs a tier-2-or-better data-card role"end
  end
  if config.mutation_conditions~=nil and type(config.mutation_conditions)~="table" then return nil,"mutation_conditions must map exact observed strings to policies"end
  local needs_foundation=false
  for condition,rule in pairs(config.mutation_conditions or {}) do
    if type(condition)~="string" or condition=="" or type(rule)~="table" then return nil,"mutation_conditions must map nonempty exact strings to policy tables"end
    if rule.policy~="satisfied" and rule.policy~="unmet" and rule.policy~="foundation" then return nil,"mutation condition '"..condition.."' has an invalid satisfaction policy"end
    if rule.policy=="foundation" then
      if type(rule.foundation)~="string" or not rule.foundation:match("^[%w_.-]+:[%w_./-]+$") then return nil,"mutation condition '"..condition.."' needs an exact namespaced foundation block ID"end
      needs_foundation=true
    elseif rule.foundation~=nil then return nil,"mutation condition '"..condition.."' may name a foundation only with policy='foundation'" end
  end
  if needs_foundation and not config.roles.foundation_modem then return nil,"foundation condition mappings need configured foundation_modem and foundation_data roles"end
  return true
end

function Config.load(path)
  path = path or Config.default_path
  local loader, err = loadfile(path)
  if not loader then return nil, err end
  local ok, data = pcall(loader)
  if not ok then return nil, "cannot evaluate configuration: " .. tostring(data) end
  if type(data)~="table" then return nil,"configuration must be a table"end
  if data.limits~=nil and type(data.limits)~="table" then return nil,"configuration limits must be a table"end
  if data.network~=nil and type(data.network)~="table" then return nil,"configuration network must be a table"end
  data = util.merge(Config.defaults, data)
  data.limits = util.merge(Config.defaults.limits, data.limits)
  data.network = util.merge(Config.defaults.network, data.network)
  local valid, validation = Config.validate(data)
  if not valid then return nil, validation end
  return data
end

function Config.save(config, path, filesystem)
  path, filesystem = path or Config.default_path, filesystem or require("filesystem")
  local valid, err = Config.validate(config)
  if not valid then return nil, err end
  local temporary = path .. ".new"
  local handle, open_err = io.open(temporary, "w")
  if not handle then return nil, open_err end
  local ok, write_err = handle:write("return ", serialize(config), "\n")
  if ok then ok,write_err=handle:flush() end
  local closed,close_err=handle:close()
  if not ok or closed==nil then filesystem.remove(temporary); return nil, write_err or close_err or "configuration flush/close failed" end
  if filesystem.exists(path) then
    filesystem.remove(path .. ".previous")
    local moved, move_err = filesystem.rename(path, path .. ".previous")
    if not moved then filesystem.remove(temporary); return nil, move_err end
  end
  local installed, install_err = filesystem.rename(temporary, path)
  if not installed then
    local previous=path..".previous"
    if filesystem.exists(previous) then
      local restored,restore_err=filesystem.rename(previous,path)
      if not restored then
        return nil,"new configuration install failed: "..tostring(install_err).."; previous configuration restore failed: "..tostring(restore_err).."; retained previous="..previous.."; retained new="..temporary
      end
    end
    return nil, install_err
  end
  return true
end

function Config.wizard(input, output, component, path, filesystem)
  input, output = input or io.read, output or print
  output("gtnh-bees first-run topology. Enter exact component addresses and numeric sides.")
  local roles = {}
  local function slots(text)
    text = util.trim(text)
    if text == "" then return nil end
    local result, seen = {}, {}
    local position = 1
    while true do
      local comma = text:find(",", position, true)
      local token = util.trim(text:sub(position, comma and comma - 1 or #text))
      if not token:match("^%d+$") then return nil end
      local value = tonumber(token)
      if not util.finite_integer(value,1) or seen[value] then return nil end
      seen[value] = true
      result[#result + 1] = value
      if not comma then break end
      position = comma + 1
    end
    return result
  end
  local function ask(role, side, reserved, outputs)
    output(role .. " component address:")
    local address = util.trim(input())
    local value = {address=address}
    if side then output(role .. " transposer side (0-5):"); value.side = tonumber(input()) end
    if reserved then output("bee_storage final reserved slot number:"); value.reserved_slot = tonumber(input()) end
    if outputs then output(role .. " recoverable output slots (comma separated):"); value.output_slots = slots(input()) end
    roles[role] = value
  end
  ask("genetics", false)
  ask("bee_storage", true, true)
  output("Comma-separated exact item registry names for princess, drone, queen:")
  local caste_names={} for value in tostring(input()):gmatch("[^,%s]+")do caste_names[#caste_names+1]=value end
  if #caste_names==3 then roles.bee_storage.caste_items={[caste_names[1]]="princess",[caste_names[2]]="drone",[caste_names[3]]="queen"}else roles.bee_storage.caste_items={}end
  ask("breeder", true, false, true)
  output("breeder princess input slot:");roles.breeder.princess_slot=tonumber(input())
  output("breeder drone input slot:");roles.breeder.drone_slot=tonumber(input())
  ask("scanner", true, false, true)
  output("official forestry_analyzer component address:");roles.scanner.component_address=util.trim(input())
  output("scanner input slot:");roles.scanner.input_slot=tonumber(input())
  ask("recovery", true, false, true)
  local config = util.merge(Config.defaults, {roles=roles})
  local ok, err = Config.save(config, path, filesystem)
  if not ok then return nil, "configuration was not saved: " .. err end
  return config
end

return Config
