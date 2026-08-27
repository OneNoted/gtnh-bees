local Command = require("gtnh_bees.command")
local Menu = {}

Menu.entries = {
  {label="Complete the collection", name="complete"},
  {label="Breed a species", name="breed"},
  {label="Convert princesses", name="convert"},
  {label="Imprint a genome", name="imprint"},
  {label="Exit", name="exit"}
}

function Menu.command_for(name, answers)
  answers = answers or {}
  if name == "complete" then return {name="complete"} end
  if name == "breed" then
    local args = {"breed", answers.species or "", "--imprint=" .. (answers.imprint or "all")}
    if answers.pause then args[#args + 1] = "--pause" end
    return Command.parse(args)
  end
  if name == "convert" then
    local args = {"convert", answers.species or ""}
    if answers.all then args[#args + 1] = "--all"
    elseif answers.count ~= nil then args[#args + 1] = "--count=" .. tostring(answers.count) end
    return Command.parse(args)
  end
  if name == "imprint" then
    local args = {"imprint"}; if answers.species and answers.species ~= "" then args[2] = answers.species end
    return Command.parse(args)
  end
  return nil, "menu choice has no command"
end

local function read_line(prompt)
  io.write(prompt); return io.read()
end

local function collect(name)
  if name == "complete" then return {} end
  if name == "breed" then
    local species = read_line("Species label or UID: ")
    local imprint = read_line("Imprint mode [all/intermediate/target/none] (all): ")
    local pause = read_line("Pause after each new species? [y/N]: ")
    return {species=species, imprint=imprint ~= "" and imprint or "all", pause=pause:lower():sub(1,1) == "y"}
  end
  if name == "convert" then
    local species = read_line("Drone species label or UID: ")
    local amount = read_line("Princess count, or 'all' (1): ")
    if amount:lower() == "all" then return {species=species, all=true} end
    return {species=species, count=amount ~= "" and amount or nil}
  end
  if name == "imprint" then return {species=read_line("Species label or UID; blank means all: ")} end
end

local function draw(term, selected)
  term.clear()
  print("gtnh-bees")
  print("Use Up/Down, Enter, or Q/Escape to leave.\n")
  for index, entry in ipairs(Menu.entries) do print((index == selected and "> " or "  ") .. entry.label) end
end

function Menu.run(execute, runtime)
  runtime = runtime or {event=require("event"), term=require("term"), keyboard=require("keyboard")}
  local selected = 1
  while true do
    draw(runtime.term, selected)
    local _, _, _, code = runtime.event.pull("key_down")
    local keys = runtime.keyboard.keys
    if code == keys.up then selected = selected == 1 and #Menu.entries or selected - 1
    elseif code == keys.down then selected = selected == #Menu.entries and 1 or selected + 1
    elseif code == keys.q or code == keys.esc or code == keys.back then return true
    elseif code == keys.enter then
      local entry = Menu.entries[selected]
      if entry.name == "exit" then return true end
      runtime.term.clear()
      local command, err = Menu.command_for(entry.name, collect(entry.name))
      if not command then print("Input error: " .. tostring(err)); read_line("Press Enter to return.")
      else
        print(Command.summary(command)); local answer = read_line("Proceed? [y/N]: ")
        if answer:lower():sub(1,1) == "y" then
          local ok,run_err,metadata=execute(command)
          if not ok then
            local state=type(metadata)=="table" and metadata.safety_state or "unknown"
            if state=="not_started" then
              print("Operation did not start; no physical movement began: "..tostring(run_err))
            elseif state=="known_safe" then
              print("Operation did not complete; physical state is known safe: "..tostring(run_err))
            else
              print("PHYSICAL STATE UNPROVEN: "..tostring(run_err))
              print("Menu locked; reconcile the hardware physically before restarting gtnh-bees.")
              return nil,run_err,{safety_state="unknown"}
            end
          end
          read_line("Press Enter to return.")
        end
      end
    end
  end
end

return Menu
