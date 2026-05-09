local Utils = {}

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
