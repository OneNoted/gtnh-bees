local Command = require("gtnh_bees.command")
local Application = require("gtnh_bees.application")
local Config = require("gtnh_bees.config")

local Main = {}

local function factory()
  local config, err = Config.load()
  if not config then
    local filesystem = require("filesystem")
    if not filesystem.exists(Config.default_path) then config, err = Config.wizard(nil, nil, nil, nil, filesystem) end
  end
  if not config then return nil, "configuration failed before any bee moved: " .. tostring(err) end
  local driver_name = config.driver_module or "gtnh_bees.official_driver"
  local ok, driver = pcall(require, driver_name)
  if not ok then return nil, "cannot load genetics driver '" .. driver_name .. "': " .. tostring(driver) end
  local Adapter = require("gtnh_bees.hardware")
  local adapter, adapter_err = Adapter.new(config, driver)
  if not adapter then return nil, "hardware topology failed before any bee moved: " .. tostring(adapter_err) end
  if config.roles.foundation_modem then
    local foundation = require("gtnh_bees.foundation")
    local component, event = require("component"), require("event")
    local modem = component.proxy(config.roles.foundation_modem.address)
    local data=component.proxy(config.roles.foundation_data.address)
    local auth,auth_err=foundation.data_auth(data,config.network.shared_secret)
    if not auth then return nil,"foundation authentication setup failed: "..auth_err end
    local function nonce()
      local raw=data.random(16)
      return (raw:gsub(".",function(c)return string.format("%02x",string.byte(c))end))
    end
    adapter.foundation = foundation.Controller.new(modem, event, {port=config.network.foundation_port, attempts=config.limits.robot_attempts, timeout=config.limits.robot_timeout,peer_address=config.network.robot_address,local_address=config.roles.foundation_modem.address,auth=auth,nonce=nonce,epoch=config.network.replay_epoch})
  end
  return adapter, config
end

function Main.run(argv, dependencies)
  dependencies = dependencies or {}
  local command, err = Command.parse(argv)
  if not command then (dependencies.output or print)("Argument error: " .. err); return nil, err end
  local app = Application.new(dependencies.factory or factory, dependencies.output, dependencies.pause)
  if command.name == "menu" then
    local Menu = require("gtnh_bees.menu")
    return Menu.run(function(choice) return app:execute(choice) end, dependencies.menu_runtime)
  end
  return app:execute(command)
end

return Main
