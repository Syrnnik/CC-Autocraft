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

-- Roles that accept several peripherals at once. Their stored value is a
-- list; all assigned inventories are merged into one virtual storage.
Roles.MULTI = {
  stock_view = true,
  stock_in = true,
  stock_out = true,
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
-- For multi roles the stored value may be a list; callers that can handle
-- several values should use getList/getPorts instead.
function Roles.get(role)
  return load()[role]
end

-- Returns the stored values for a role as a list (labels or port names).
-- A legacy single-string value becomes a one-element list; unset -> {}.
-- Returns a copy, safe to mutate.
function Roles.getList(role)
  local value = load()[role]
  local list = {}
  if type(value) == "table" then
    for _, v in ipairs(value) do
      table.insert(list, v)
    end
  elseif value ~= nil then
    table.insert(list, value)
  end
  return list
end

-- Returns the resolved peripheral port names for a role (may be empty).
function Roles.getPorts(role)
  local ports = {}
  for _, value in ipairs(Roles.getList(role)) do
    table.insert(ports, Labels.resolvePort(value))
  end
  return ports
end

-- Returns the resolved peripheral port name for a role, or nil.
-- Handles both label-stored and port-stored values transparently.
-- For multi roles this is the first assigned port.
function Roles.getPort(role)
  return Roles.getPorts(role)[1]
end

function Roles.getAll()
  return load()
end

function Roles.set(role, peripheral)
  local data = load()
  data[role] = peripheral
  save(data)
end

-- Adds `value` to a multi role's list, or removes it when already present.
-- A legacy single-string value is converted to a list first.
function Roles.toggle(role, value)
  local data = load()
  local current = data[role]
  local list
  if type(current) == "table" then
    list = current
  elseif current ~= nil then
    list = { current }
  else
    list = {}
  end

  local removed = false
  for i, v in ipairs(list) do
    if v == value then
      table.remove(list, i)
      removed = true
      break
    end
  end
  if not removed then
    table.insert(list, value)
  end

  data[role] = (#list > 0) and list or nil
  save(data)
end

function Roles.clear(role)
  local data = load()
  data[role] = nil
  save(data)
end

return Roles
