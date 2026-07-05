local Utils = {}

-- Wraps a peripheral by name, raising a clear error if not found.
function Utils.wrapPeripheral(name)
  if not name then
    error("Peripheral name is nil", 2)
  end
  local p = peripheral.wrap(name)
  if not p then
    error("Peripheral '" .. name .. "' not found or not connected", 2)
  end
  return p
end

-- Runs a list of functions concurrently via parallel.waitForAll. Peripheral
-- transfers cost ~1 game tick each; run in parallel coroutines they overlap
-- instead of paying that tick sequentially, so e.g. filling a 3x3 crafting
-- grid takes ~1 tick instead of ~9.
function Utils.runParallel(fns)
  if #fns == 0 then
    return
  end
  if #fns == 1 then
    fns[1]()
    return
  end
  parallel.waitForAll(table.unpack(fns))
end

function Utils.stripMod(name)
  return name:match("^[^:]+:(.+)") or name
end

function Utils.getMod(name)
  return name:match("^([^:]+):") or "other"
end

function Utils.serializeTable(tbl)
  local serialized = textutils.serialize(tbl)
  return serialized
end

function Utils.serializeJson(tbl)
  local serialized = textutils.serializeJSON(tbl)
  return serialized
end

function Utils.unserializeJson(content)
  local unserialized = textutils.unserializeJSON(content)
  return unserialized
end

function Utils.printInterfaceMethods(interfaceName)
  local methods = peripheral.getMethods(interfaceName)
  local formatted_methods = Utils.serializeTable(methods)
  print(string.format("Methods of '%s':", interfaceName))
  print(formatted_methods)
end

return Utils
