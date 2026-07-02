local Labels = require("lib.labels")

local Roles = {}

-- Ordered list of roles (used for UI display)
Roles.LIST = {
  "stock_view",
  "stock_in",
  "stock_out",
  "crafter",
  "recipe_interface",
  "monitor",
  "materials_out",
}

Roles.DISPLAY = {
  stock_view = "Stock View",
  stock_in = "Stock In",
  stock_out = "Stock Out",
  crafter = "Crafter",
  recipe_interface = "New Recipes",
  monitor = "Monitor",
  materials_out = "Materials Out",
}

local path = "data/roles.json"
local _cache = nil -- in-memory cache; nil means not loaded yet

local function load()
  if _cache then
    return _cache
  end
  if not fs.exists(path) then
    _cache = {}
    return _cache
  end
  local f = fs.open(path, "r")
  local content = f.readAll()
  f.close()
  _cache = textutils.unserializeJSON(content) or {}
  return _cache
end

local function save(data)
  _cache = data
  if not fs.exists("data") then
    fs.makeDir("data")
  end
  local f = fs.open(path, "w")
  f.write(textutils.serializeJSON(data))
  f.close()
end

-- Returns the stored value for a role (may be a label or port name), or nil.
function Roles.get(role)
  return load()[role]
end

-- Returns the resolved peripheral port name for a role, or nil.
-- Handles both label-stored and port-stored values transparently.
function Roles.getPort(role)
  local value = load()[role]
  if not value then
    return nil
  end
  return Labels.resolvePort(value)
end

function Roles.getAll()
  return load()
end

function Roles.set(role, peripheral)
  local data = load()
  data[role] = peripheral
  save(data)
end

function Roles.clear(role)
  local data = load()
  data[role] = nil
  save(data)
end

return Roles
