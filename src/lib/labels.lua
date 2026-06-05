local Config = require("lib.config")

local Labels = {}

local path = Config.LABELS_PATH

local function load()
  if not fs.exists(path) then return {} end
  local f = fs.open(path, "r")
  local content = f.readAll()
  f.close()
  return textutils.unserializeJSON(content) or {}
end

local function save(data)
  if not fs.exists("data") then fs.makeDir("data") end
  local f = fs.open(path, "w")
  f.write(textutils.serializeJSON(data))
  f.close()
end

function Labels.getAll()
  return load()
end

function Labels.get(peripheral)
  return load()[peripheral]
end

function Labels.set(peripheral, label)
  local data = load()
  data[peripheral] = label
  save(data)
end

function Labels.delete(peripheral)
  local data = load()
  data[peripheral] = nil
  save(data)
end

-- Returns the peripheral port name that has the given label.
-- Prefers a currently connected port over a stale one.
function Labels.findPort(label)
  local data     = load()
  local fallback = nil
  for port, lbl in pairs(data) do
    if lbl == label then
      if peripheral.isPresent(port) then return port end
      fallback = port
    end
  end
  return fallback
end

-- Returns the peripheral port for a value that may be a label or already a port.
-- Tries the value as a port first; then reverse label lookup preferring connected ports.
function Labels.resolvePort(value)
  if not value then return nil end
  if peripheral.isPresent(value) then return value end
  return Labels.findPort(value) or value
end

return Labels
