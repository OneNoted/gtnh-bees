local Command = require("gtnh_bees.command")
local Operations = require("gtnh_bees.operations")
local Application = {}
Application.__index = Application

function Application.new(adapter_factory, output, pause)
  return setmetatable({factory=adapter_factory, output=output or print, pause=pause}, Application)
end

local function describe(result, output)
  if result.operation == "complete" then
    output("Completed archives:")
    for _, uid in ipairs(result.completed) do output("  " .. uid .. " — " .. tostring(result.labels and result.labels[uid] or uid)) end
    if #result.missing > 0 then
      output("Missing archives:")
      for _, item in ipairs(result.missing) do output("  " .. item.uid .. " — " .. tostring(result.labels and result.labels[item.uid] or item.uid) .. ": " .. tostring(item.reason or "no safe route remains")) end
    end
    for _,item in ipairs(result.imprints or {}) do output((item.ok and "Imprinted " or "Could not imprint ")..item.uid..(item.error and ": "..item.error or "")) end
  elseif result.operation == "breed" then
    output("Archived " .. result.label .. " (" .. result.uid .. ") with " .. result.archive.count .. " pure drones.")
    for _,item in ipairs(result.imprints or {}) do output((item.ok and "Imprinted " or "Could not imprint ")..item.uid..(item.error and ": "..item.error or "")) end
  elseif result.operation == "convert" then output("Converted " .. result.converted .. " princess(es) to " .. result.uid .. (result.stopped and "; stopped: " .. result.stopped or "."))
  elseif result.operation == "imprint" then
    for _, item in ipairs(result.results) do output((item.ok and "Imprinted " or "Could not imprint ") .. item.uid .. (item.error and ": " .. item.error or "")) end
  end
end

local safety_states = {not_started=true, known_safe=true, unknown=true}

local function safety(state)
  return {safety_state=state}
end

local function explicit_safety(proof,fallback)
  if type(proof)=="table" and safety_states[proof.safety_state] then return proof.safety_state end
  if safety_states[fallback] then return fallback end
  return "unknown"
end

function Application:execute(command)
  if command.name == "help" then
    local result={operation="help",safety_state="not_started"}
    self.output(Command.help(command.topic))
    return true,result
  end
  if command.name~="complete" and command.name~="breed" and command.name~="convert" and command.name~="imprint" then
    return nil,"application cannot execute '"..tostring(command.name).."'",safety("not_started")
  end

  local constructed,adapter,config_or_error=pcall(self.factory)
  if not constructed then return nil,"adapter construction failed: "..tostring(adapter),safety("not_started") end
  if not adapter then return nil,config_or_error,safety("not_started") end
  local config=config_or_error or {}
  local initialized,operations=pcall(Operations.new,adapter,{
    archive_size=config.archive_size,
    limits=config.limits,
    pause=self.pause or function(uid,label)io.write("Stored "..label.." ("..uid.."). Press Enter after quest turn-in.");io.read()end,
    notify=self.output
  })
  if not initialized then return nil,"operation setup failed: "..tostring(operations),safety("not_started") end

  local called,result,err,proof=pcall(function()
    if command.name=="complete" then return operations:complete({imprint=config.complete_imprint or "all"}) end
    if command.name=="breed" then return operations:breed(command) end
    if command.name=="convert" then return operations:convert(command) end
    return operations:imprint(command)
  end)
  if not called then return nil,"operation execution failed: "..tostring(result),safety("unknown") end
  if not result then return nil,err,safety(explicit_safety(proof,operations.safety_state)) end

  result.safety_state="known_safe"
  describe(result,self.output)
  if result.success==false then return nil,result.error or "operation did not fulfill every requested target",result end
  return true,result
end

return Application
