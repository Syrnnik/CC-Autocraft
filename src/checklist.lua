local Network = require("lib.network")
local Stock   = require("lib.stock")

Network.prepareModem("bottom", false)

print("Reading clipboard...")
local items = Stock.getChecklistStatus()

if items == nil then
  print("No clipboard found (create:clipboard)")
  return
end

if #items == 0 then
  print("Checklist is empty")
  return
end

local counts = { done = 0, in_stock = 0, to_craft = 0, missing = 0 }
for _, item in ipairs(items) do
  counts[item.status] = (counts[item.status] or 0) + 1
  local prefix = item.status == "done"     and "[done]    "
              or item.status == "in_stock" and "[in stock]"
              or item.status == "to_craft" and "[to craft]"
              or "[missing] "
  local line = prefix .. " " .. item.name
  if item.status ~= "done" then line = line .. " x" .. item.needed end
  print(line)
end

print(string.format("\nDone:%d  In stock:%d  To craft:%d  Missing:%d",
  counts.done, counts.in_stock, counts.to_craft, counts.missing))

if counts.in_stock > 0 then
  print("\nTransferring in-stock items to materials_out...")
  local ok, transferred, notFound = pcall(Stock.transferChecklistItems)
  if not ok then
    print("Error: " .. tostring(transferred))
  else
    print("Moved " .. #transferred .. " type(s)" ..
      (#notFound > 0 and (", " .. #notFound .. " not found") or ""))
  end
end
