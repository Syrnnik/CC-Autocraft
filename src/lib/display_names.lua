local Config = require("lib.config")
local Utils = require("lib.utils")

-- Persistent store mapping item id (e.g. "minecraft:oak_log") -> displayName
-- (e.g. "Oak Log"). Populated by scan_names.lua (from Stock View) and when a
-- recipe is saved. The UI reads it to show friendly names instead of ids.
local DisplayNames = {}

local path = Config.DISPLAY_NAMES_PATH
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

function DisplayNames.getAll()
  return load()
end

-- Returns the stored displayName for an item id, or nil.
function DisplayNames.get(name)
  return load()[name]
end

function DisplayNames.set(name, displayName)
  if not name or not displayName then
    return
  end
  -- Names the terminal cannot draw (localized clients hand out non-ASCII
  -- displayNames) never enter the store: the UI would show them as "???".
  if not Utils.isRenderable(displayName) then
    return
  end
  local data = load()
  if data[name] == displayName then
    return
  end
  data[name] = displayName
  save(data)
end

-- Merges a { [id] = displayName } map into the store. Writes only when at least
-- one entry actually changes. Returns true if the store was updated.
function DisplayNames.setMany(map)
  local data = load()
  local changed = false
  for name, displayName in pairs(map) do
    if
      displayName
      and Utils.isRenderable(displayName)
      and data[name] ~= displayName
    then
      data[name] = displayName
      changed = true
    end
  end
  if changed then
    save(data)
  end
  return changed
end

return DisplayNames
