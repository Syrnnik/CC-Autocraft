local Roles = require("lib.roles")
local UI    = require("lib.ui")

local function findMonitor()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name, "monitor") then return name end
  end
end

UI.run(Roles.get("monitor") or findMonitor())
