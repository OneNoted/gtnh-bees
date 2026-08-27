local Service=require("gtnh_bees.robot_service")
local Protocol=require("gtnh_bees.foundation")
local util=require("gtnh_bees.util")
local M={}
local function load_config(path)
  local loader,err=loadfile(path);if not loader then return nil,err end
  local ok,value=pcall(loader);if not ok or type(value)~="table"then return nil,"robot configuration must return a table"end
  return value
end
local function validate_config(value)
  for _,field in ipairs({"controller_address","modem_address","data_address","shared_secret","replay_epoch","replay_journal"})do if type(value[field])~="string"or value[field]==""then return nil,"robot configuration needs "..field end end
  if value.replay_journal:sub(1,1)~="/"then return nil,"robot replay_journal must be an absolute path"end
  if #value.shared_secret<16 then return nil,"robot shared_secret must contain at least 16 bytes"end
  if not Protocol.valid_epoch(value.replay_epoch)then return nil,"robot replay_epoch must contain at least 16 bytes and no '|'"end
  if type(value.block_items)~="table"then return nil,"robot configuration needs block_items exact world-block to inventory-item mappings"end
  local mappings=0
  for block,item in pairs(value.block_items)do
    if type(block)~="string"or block==""or block:find("|",1,true)or type(item)~="string"or item==""then return nil,"robot block_items mappings must use exact non-empty string identifiers"end
    mappings=mappings+1
  end
  if mappings==0 then return nil,"robot block_items must contain at least one exact mapping"end
  value.max_replay_entries=value.max_replay_entries or 64
  if not util.finite_integer(value.max_replay_entries,1,1024)then return nil,"robot max_replay_entries must be a finite integer from 1 to 1024"end
  return value
end
function M.run(argv,dependencies)
  argv,dependencies=argv or{},dependencies or{}
  local options,once,config_path={},false,"/etc/gtnh-bees-robot.cfg"
  for _,arg in ipairs(argv)do
    if arg=="--once"then once=true
    elseif arg:match("^%-%-config=")then config_path=arg:match("=(.+)$")
    elseif arg=="--help"or arg=="-h"then(dependencies.output or print)("Usage: bees-robot [--once] [--config=/etc/gtnh-bees-robot.cfg]");return true
    else return nil,"unknown robot option '"..arg.."'"end
  end
  local config,config_err=(dependencies.load_config or load_config)(config_path);if not config then return nil,"robot configuration failed: "..tostring(config_err)end
  if type(config)~="table"then return nil,"robot configuration failed: configuration must be a table"end
  if not util.finite_integer(config.port,1,65535)then return nil,"robot port must be a finite integer from 1 to 65535"end
  if not util.finite_integer(config.side,0,5)then return nil,"robot side must be a finite integer from 0 to 5"end
  local valid,validation_err=validate_config(config);if not valid then return nil,"robot configuration failed: "..validation_err end
  options.port,options.side=config.port,config.side;options.peer_address,options.local_address=config.controller_address,config.modem_address
  options.epoch,options.journal_path,options.max_cache,options.block_items=config.replay_epoch,config.replay_journal,config.max_replay_entries,config.block_items
  local runtime=dependencies.runtime
  if not runtime then
    local component=require("component")
    local modem=component.proxy(config.modem_address);local data=component.proxy(config.data_address)
    local auth,auth_err=Protocol.data_auth(data,config.shared_secret);if not auth then return nil,auth_err end
    options.auth=auth
    runtime={sides=require("sides"),event=require("event"),robot=require("robot"),filesystem=require("filesystem"),open=io.open,component={modem=modem,inventory_controller=component.inventory_controller,geolyzer=component.geolyzer}}
  else
    options.auth=assert(dependencies.auth,"test/runtime authenticator is required")
    runtime.filesystem=runtime.filesystem or dependencies.filesystem
    runtime.open=runtime.open or dependencies.open
  end
  local service,service_err=Service.new(options,runtime);if not service then return nil,"robot service initialization failed: "..tostring(service_err)end
  return service:run(once)
end
return M
