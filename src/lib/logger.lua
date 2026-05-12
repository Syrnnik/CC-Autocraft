local Config = require("lib.config")
local Utils = require("lib.utils")

local isDebugMode = Config.IS_DEBUG_MODE

local textColorDebug = Config.TEXT_COLOR_DEBUG
local textColorInfo = Config.TEXT_COLOR_INFO
local textColorWarn = Config.TEXT_COLOR_WARN
local textColorSuccess = Config.TEXT_COLOR_SUCCESS
local bgColorError = Config.BG_COLOR_ERROR
local textColorError = Config.TEXT_COLOR_ERROR

local function valueToString(value)
  if type(value) == "table" then
    return Utils.serializeTable(value)
  end

  return tostring(value)
end

local function _print(textColor, bgColor, ...)
  local lines = {}

  for i = 1, select("#", ...) do
    lines[i] = valueToString(select(i, ...))
  end

  local currentBgColor = term.getBackgroundColor()
  local currentTextColor = term.getTextColor()
  bgColor = bgColor or currentBgColor
  textColor = textColor or currentTextColor

  term.setBackgroundColor(bgColor)
  term.setTextColor(textColor)
  print(table.concat(lines, "\n"))
  term.setBackgroundColor(currentBgColor)
  term.setTextColor(currentTextColor)
end

local Logger = {}

-- Keeps track of the last printed error so raiseError() can propagate it
-- even when called without arguments (after a manual Logger.printError call).
local lastErrorMsg = nil

function Logger.printError(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[i] = valueToString(select(i, ...))
  end
  lastErrorMsg = table.concat(parts, " ")
  _print(textColorError, nil, ...)
end

function Logger.raiseError(msg, ...)
  if msg ~= nil then
    Logger.printError(msg, ...)
  end
  error(lastErrorMsg or "error", 0)
end

function Logger.printWarning(...)
  _print(textColorWarn, nil, ...)
end

function Logger.printDebug(...)
  if isDebugMode then
    _print(textColorDebug, nil, ...)
  end
end

function Logger.printInfo(...)
  _print(textColorInfo, nil, ...)
end

function Logger.printSuccess(...)
  _print(textColorSuccess, nil, ...)
end

return Logger
