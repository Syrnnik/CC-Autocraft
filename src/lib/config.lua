local Config = {}

-- Config.IS_DEBUG_MODE = true
Config.IS_DEBUG_MODE = false

Config.STOCK_NAME = "create:item_vault_1"
Config.NEW_RECIPE_INTERFACE_NAME = "minecraft:barrel_0"
Config.CRAFTER_NAME = "turtle_2"
Config.CRAFTER_NETWORK_ID = 5

Config.PATTERN_SIZE = 3
Config.CRAFTER_ROW_SIZE = 4
Config.NEW_RECIPE_INTERFACE_ROW_SIZE = 9
Config.PATTERN_START = 4

Config.RECIPES_PATH = "data/recipes.json"

Config.NETWORK_EVENTS = {
  CRAFT = "craft",
}

Config.CRAFT_TIMEOUT = 30
Config.CLEAR_CRAFTER_BEFORE_CRAFT = true

Config.BG_COLOR_DEFAULT = colors.black
Config.TEXT_COLOR_DEFAULT = colors.white
Config.TEXT_COLOR_DEBUG = colors.cyan
Config.TEXT_COLOR_INFO = colors.lightBlue
Config.TEXT_COLOR_WARN = colors.orange
Config.TEXT_COLOR_SUCCESS = colors.green
Config.BG_COLOR_ERROR = colors.red
-- Config.TEXT_COLOR_ERROR = colors.white
Config.TEXT_COLOR_ERROR = colors.red

return Config
