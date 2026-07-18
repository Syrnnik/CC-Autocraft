local Utils = {}

-- Wraps a peripheral by name, raising a clear error if not found.
-- Already-wrapped inventories (tables, e.g. a virtual multi-inventory)
-- pass through unchanged, so code can hand either form around.
function Utils.wrapPeripheral(name)
  if type(name) == "table" then
    return name
  end
  if not name then
    error("Peripheral name is nil", 2)
  end
  local p = peripheral.wrap(name)
  if not p then
    error("Peripheral '" .. name .. "' not found or not connected", 2)
  end
  return p
end

-- Human-readable name for a value that may be a port name or an
-- already-wrapped inventory table (used in log/error messages).
function Utils.portLabel(v)
  if type(v) == "table" then
    return v.virtualName or "virtual-inventory"
  end
  return tostring(v)
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

-- Pretty fallback name from an id: "create:molten_iron" -> "Molten Iron".
-- Dotted ids ("item.avaritia.dur_singularity") keep only the last segment.
function Utils.prettifyId(name)
  local s = Utils.stripMod(name)
  s = s:match("([^.]+)$") or s
  s = s:gsub("_", " ")
  return (
    s:gsub("(%a)(%w*)", function(head, tail)
      return head:upper() .. tail
    end)
  )
end

-- Friendly name from an optional displayName + id. A leaked raw translation
-- key ("item.avaritia.x", no spaces but dots/underscores) is prettified.
function Utils.friendlyName(displayName, name)
  local dn = displayName
  if dn and dn ~= "" then
    if dn:find(" ", 1, true) then
      return dn
    end
    if dn:find(".", 1, true) or dn:find("_", 1, true) then
      return Utils.prettifyId(dn)
    end
    return dn
  end
  return Utils.prettifyId(name or "?")
end

-- Same-id NBT variants are tracked in plan/stock accounting under a
-- composite key "name\0nbt"; items without nbt keep their plain name.
function Utils.variantKey(name, nbt)
  if nbt then
    return name .. "\0" .. nbt
  end
  return name
end

function Utils.variantBase(key)
  return key:match("^([^\0]+)") or key
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
