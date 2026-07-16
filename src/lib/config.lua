local Config = {}

-- Defaults below can be overridden from the SETUP > Settings tab; user
-- values are stored in data/settings.json and survive code updates.
Config.IS_DEBUG_MODE = true

Config.CLEAR_CRAFTER_BEFORE_CRAFT = false

Config.CRAFTER_NETWORK_ID = 5

Config.MONITOR_TEXT_SCALE = 1.0

Config.CRAFT_TIMEOUT = 30
Config.MACHINE_CRAFT_TIMEOUT = 30

Config.PATTERN_SIZE = 3
Config.CRAFTER_ROW_SIZE = 4
Config.NEW_RECIPE_INTERFACE_ROW_SIZE = 9
Config.PATTERN_START = 4

Config.RECIPES_PATH = "data/recipes.json"
Config.LABELS_PATH = "data/labels.json"
Config.ROLES_PATH = "data/roles.json"
Config.DISPLAY_NAMES_PATH = "data/display_names.json"
Config.SETTINGS_PATH = "data/settings.json"

Config.NETWORK_EVENTS = {
  CRAFT = "craft",
}

Config.BG_COLOR_DEFAULT = colors.black
Config.TEXT_COLOR_DEFAULT = colors.white
Config.TEXT_COLOR_DEBUG = colors.cyan
Config.TEXT_COLOR_INFO = colors.lightBlue
Config.TEXT_COLOR_WARN = colors.orange
Config.TEXT_COLOR_SUCCESS = colors.green
Config.BG_COLOR_ERROR = colors.red
-- Config.TEXT_COLOR_ERROR = colors.white
Config.TEXT_COLOR_ERROR = colors.red

-- ── User-editable settings ──────────────────────────────────
-- Shown on SETUP > Settings. `type` drives the editor: boolean values get
-- a true/false picker, numbers are typed on the keyboard.
Config.EDITABLE = {
  { key = "IS_DEBUG_MODE", label = "Debug Mode", type = "boolean" },
  {
    key = "CLEAR_CRAFTER_BEFORE_CRAFT",
    label = "Clear Crafter",
    type = "boolean",
  },
  { key = "CRAFTER_NETWORK_ID", label = "Crafter Net ID", type = "number" },
  { key = "MONITOR_TEXT_SCALE", label = "Text Scale", type = "number" },
  { key = "CRAFT_TIMEOUT", label = "Craft Timeout", type = "number" },
  { key = "MACHINE_CRAFT_TIMEOUT", label = "Machine Timeout", type = "number" },
  { key = "PATTERN_SIZE", label = "Pattern Size", type = "number" },
  { key = "CRAFTER_ROW_SIZE", label = "Crafter Rows", type = "number" },
  {
    key = "NEW_RECIPE_INTERFACE_ROW_SIZE",
    label = "Iface Rows",
    type = "number",
  },
  { key = "PATTERN_START", label = "Pattern Start", type = "number" },
}

local editableType = {}
for _, setting in ipairs(Config.EDITABLE) do
  editableType[setting.key] = setting.type
end

local function loadOverrides()
  if not fs.exists(Config.SETTINGS_PATH) then
    return {}
  end
  local f = fs.open(Config.SETTINGS_PATH, "r")
  if not f then
    return {}
  end
  local content = f.readAll()
  f.close()
  return textutils.unserializeJSON(content) or {}
end

-- Values from data/settings.json; only known keys with the right type are
-- applied, so a stale/corrupt file can never break startup.
local overrides = loadOverrides()
for key, value in pairs(overrides) do
  if editableType[key] == type(value) then
    Config[key] = value
  end
end

-- Persists one setting and applies it immediately.
function Config.set(key, value)
  if editableType[key] ~= type(value) then
    error("Invalid value for " .. key)
  end
  overrides[key] = value
  Config[key] = value
  if not fs.exists("data") then
    fs.makeDir("data")
  end
  local f = fs.open(Config.SETTINGS_PATH, "w")
  if not f then
    error("Cannot write " .. Config.SETTINGS_PATH)
  end
  f.write(textutils.serializeJSON(overrides))
  f.close()
end

return Config
