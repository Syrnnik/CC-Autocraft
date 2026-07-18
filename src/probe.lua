-- Peripheral diagnostic: shows what CC actually sees in a peripheral.
-- Usage: probe <peripheral name or label>
local Labels = require("lib.labels")

local args = { ... }
if #args == 0 then
  print("Usage: probe <peripheral|label>")
  return
end

local port = Labels.resolvePort(table.concat(args, " "))
print("Port: " .. tostring(port))
if not port or not peripheral.isPresent(port) then
  print("NOT CONNECTED")
  return
end

print("Types: " .. table.concat({ peripheral.getType(port) }, ", "))

local methods = peripheral.getMethods(port) or {}
table.sort(methods)
print("Methods: " .. table.concat(methods, ", "))

local p = peripheral.wrap(port)

if type(p.size) == "function" then
  local ok, size = pcall(p.size)
  print("size(): " .. (ok and tostring(size) or ("ERROR: " .. tostring(size))))
else
  print("size(): <no method>")
end

if type(p.list) == "function" then
  local ok, listing = pcall(p.list)
  if not ok then
    print("list(): ERROR: " .. tostring(listing))
  else
    local occupied, shown = 0, 0
    for slot, item in pairs(listing or {}) do
      occupied = occupied + 1
      if shown < 10 then
        print(
          string.format(
            "  slot %s: %s x%d%s",
            tostring(slot),
            item.name,
            item.count,
            item.nbt and " (nbt)" or ""
          )
        )
        shown = shown + 1
      end
    end
    print("list(): " .. occupied .. " occupied slots")
  end
else
  print("list(): <no method>")
end

if type(p.tanks) == "function" then
  local ok, tanks = pcall(p.tanks)
  if ok and type(tanks) == "table" then
    local n = 0
    for i, tank in pairs(tanks) do
      n = n + 1
      print(
        string.format(
          "  tank %s: %s %dmB",
          tostring(i),
          tostring(tank.name or tank.fluid),
          tank.amount or 0
        )
      )
    end
    print("tanks(): " .. n .. " entries")
  else
    print("tanks(): ERROR: " .. tostring(tanks))
  end
end
