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

return Labels
