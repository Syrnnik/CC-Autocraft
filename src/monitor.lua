local Roles = require("lib.roles")
local UI = require("lib.ui")

local function findMonitor()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name, "monitor") then
      return name
    end
  end
end

local monName = Roles.getPort("monitor")
if not monName or not peripheral.isPresent(monName) then
  monName = findMonitor()
end
UI.run(monName)
