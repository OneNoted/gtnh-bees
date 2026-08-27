local M={}
local pinned={
  ["bin/bees"]={size=158,sha256="d3c9a3b47497f3f560ca14c164d4a3beb723306cd3a9147ea50a10862ae1a62b"},
  ["bin/bees-robot"]={size=164,sha256="01262337e521434542e3d8a9d56b774366aa85008e370dc7cb058a4fc5bca8c6"},
  ["lib/gtnh_bees/application.lua"]={size=4016,sha256="486b56d26781f87dafae28bbcb017540084b12c837714c153cec91545c072219"},
  ["lib/gtnh_bees/bounded.lua"]={size=1117,sha256="a2a8369a94906e01cf32b4bda8b502115d7d13741d532fff545208f8c268fb9c"},
  ["lib/gtnh_bees/catalog.lua"]={size=11997,sha256="0c4ba7aac86d72646e34d4969b66d9ef797e6b585024eee3685734aace0494b7"},
  ["lib/gtnh_bees/command.lua"]={size=4040,sha256="991370243b5e8b2ee39a3d8572272d0301fd4dd84fb25ac743de5aca239b1b98"},
  ["lib/gtnh_bees/component_call.lua"]={size=1258,sha256="a5e5be25631e3e96791d7042646dde8488a5d16f8cc49608d813f38077599f09"},
  ["lib/gtnh_bees/config.lua"]={size=14306,sha256="6b2708e90e7b476cc5f83eeb34e150b7d6ae8f5ab7fc30c07baf570237e19e14"},
  ["lib/gtnh_bees/foundation.lua"]={size=7360,sha256="8e1ca2fd251ab6bfb98a100d6edeaa30c89a0ac011339b2da2e81191b50a3904"},
  ["lib/gtnh_bees/hardware.lua"]={size=31291,sha256="9544d232526e8ad2603bf5ea95d5a9d460c60e72d34471eb332537c41e028ede"},
  ["lib/gtnh_bees/identity.lua"]={size=2820,sha256="7c2d571640b7025ba6c40348f11fd985f5a37db6a7d814dd01777b75b13a0613"},
  ["lib/gtnh_bees/inventory.lua"]={size=7623,sha256="094b604c5fc91ce2efa3045b360349ee06b04ede476a48c6e042e8966a205aeb"},
  ["lib/gtnh_bees/main.lua"]={size=2504,sha256="e4809b34cba2f19ba68294515846b0f2e9e6b373c6427276dc5d7e06666c32a5"},
  ["lib/gtnh_bees/menu.lua"]={size=4142,sha256="8f4019c8be61ccb1a6368f5ccbc64a7af9f4a0e40affc14bd9397cee190a2422"},
  ["lib/gtnh_bees/official_driver.lua"]={size=28474,sha256="06c7583c9877ef1e7723ae6ba548f3374a2cd8d1bcfeed64f3403826dc17503d"},
  ["lib/gtnh_bees/operations.lua"]={size=31982,sha256="49131b369ec4297cdc890a3a0f03a8bbddd8bce7e2f070626d7ec7cce00ba9be"},
  ["lib/gtnh_bees/planner.lua"]={size=7789,sha256="4d043d5fa9a6a89a00533ff4e460c8eb60143f64db1dbaae97aa0562d43c2e17"},
  ["lib/gtnh_bees/robot_main.lua"]={size=4182,sha256="115a473753f63edd73914a55b87eae3cd5163011956e28f8c63a63c94d57c7c6"},
  ["lib/gtnh_bees/robot_service.lua"]={size=27728,sha256="6691f7238b41a78f75dba9f7dfadec0b47e9f02cf40461d85ed11c4be911c943"},
  ["lib/gtnh_bees/transaction.lua"]={size=17999,sha256="60f5965fcf55bd0ef981ad333b6f86be40502fcd051cfd4939a2028d3856f74a"},
  ["lib/gtnh_bees/util.lua"]={size=2120,sha256="1ca3a14769012fed5e62235828406aaafaab3586095e666ee5724a7ffbd47836"}
}
local shared={"util.lua","identity.lua","bounded.lua","component_call.lua","inventory.lua","foundation.lua"}
local computer={"catalog.lua","planner.lua","command.lua","menu.lua","config.lua","transaction.lua","hardware.lua","operations.lua","application.lua","official_driver.lua","main.lua"}
local robot={"robot_service.lua","robot_main.lua"}
local function entry(base,source,destination)
  local pin=assert(pinned[source],"release manifest pin missing for "..source)
  return {url=base..source,path=destination,size=pin.size,sha256=pin.sha256}
end
local function build(base,executable,modules)
  local source="bin/"..executable;local manifest={entry(base,source,"usr/bin/"..executable)}
  for _,name in ipairs(modules)do source="lib/gtnh_bees/"..name;manifest[#manifest+1]=entry(base,source,"usr/lib/gtnh_bees/"..name)end
  return manifest
end
function M.computer(base)local modules={}for _,name in ipairs(shared)do modules[#modules+1]=name end for _,name in ipairs(computer)do modules[#modules+1]=name end return build(base,"bees",modules)end
function M.robot(base)local modules={}for _,name in ipairs(shared)do modules[#modules+1]=name end for _,name in ipairs(robot)do modules[#modules+1]=name end return build(base,"bees-robot",modules)end
return M
