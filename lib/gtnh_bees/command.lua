local util = require("gtnh_bees.util")
local M = {}

local imprint_modes = {all=true, intermediate=true, target=true, none=true}

local summaries = {
  complete = "Complete every species archive reachable from present bee stock.",
  breed = "Produce the requested species and build its pure-drone archive.",
  convert = "Use matching drones to convert stored princesses.",
  imprint = "Apply the reserved scanned drone genome to eligible stock."
}

local help = [[Usage:
  bees
  bees complete
  bees breed <species> [--imprint=MODE] [--pause]
  bees convert <species> [--count=N | --all]
  bees imprint [species]
  bees help [command]

MODE is all, intermediate, target, or none.  Conversion defaults to one.]]

local command_help = {
  complete = "bees complete\n  Archive all species structurally reachable from current stock.",
  breed = "bees breed <species> [--imprint=all|intermediate|target|none] [--pause]",
  convert = "bees convert <species> [--count=POSITIVE_INTEGER | --all]",
  imprint = "bees imprint [species]",
  help = "bees help [complete|breed|convert|imprint]"
}

local function failure(message) return nil, message end

function M.parse(argv)
  argv = argv or {}
  if #argv == 0 then return {name="menu"} end
  local name = argv[1]
  if name == "help" or name == "--help" or name == "-h" then
    if #argv > 2 then return failure("help accepts at most one command name") end
    local topic = argv[2]
    if topic and not command_help[topic] then return failure("unknown help topic '" .. topic .. "'") end
    return {name="help", topic=topic}
  end
  if name == "complete" then
    if #argv ~= 1 then return failure("complete does not accept additional arguments") end
    return {name="complete"}
  end
  if name == "breed" then
    if not argv[2] or argv[2]:match("^%s*$") or argv[2]:sub(1, 2) == "--" then return failure("breed requires a species name or UID") end
    local cmd = {name="breed", species=argv[2], imprint="all", pause=false}
    for i = 3, #argv do
      local arg = argv[i]
      local mode = arg:match("^%-%-imprint=(.+)$")
      if mode then
        if not imprint_modes[mode] then return failure("invalid imprint mode '" .. mode .. "'") end
        cmd.imprint = mode
      elseif arg == "--pause" then cmd.pause = true
      else return failure("unknown breed option '" .. arg .. "'") end
    end
    return cmd
  end
  if name == "convert" then
    if not argv[2] or argv[2]:match("^%s*$") or argv[2]:sub(1, 2) == "--" then return failure("convert requires a species name or UID") end
    local cmd = {name="convert", species=argv[2], count=1, all=false}
    local count_seen, all_seen = false, false
    for i = 3, #argv do
      local arg = argv[i]
      local raw = arg:match("^%-%-count=(.+)$")
      if raw then
        if count_seen then return failure("conversion count was supplied more than once") end
        local count = tonumber(raw)
        if not util.finite_integer(count,1) then return failure("conversion count must be a finite positive integer") end
        cmd.count, count_seen = count, true
      elseif arg == "--all" then
        if all_seen then return failure("--all was supplied more than once") end
        cmd.all, all_seen = true, true
      else return failure("unknown convert option '" .. arg .. "'") end
    end
    if count_seen and all_seen then return failure("conversion accepts --count or --all, not both") end
    if all_seen then cmd.count = nil end
    return cmd
  end
  if name == "imprint" then
    if #argv > 2 then return failure("imprint accepts at most one species") end
    return {name="imprint", species=argv[2]}
  end
  return failure("unknown command '" .. tostring(name) .. "'; run 'bees help'")
end

function M.help(topic) return topic and command_help[topic] or help end
function M.summary(command) return summaries[command.name] or "" end
function M.equal(a, b)
  for _, key in ipairs({"name", "species", "imprint", "pause", "count", "all", "topic"}) do
    if a[key] ~= b[key] then return false end
  end
  return true
end

return M
