local Roles = require("lib.roles")
local Utils = require("lib.utils")

-- Virtual inventory that merges several peripherals into one.
--
-- The slot space is the concatenation of the member slot spaces (member 1
-- first) -- the same scheme Create: Connected's Inventory Bridge uses, but
-- without its two-inventory limit. All the inventory methods the rest of
-- the code relies on (list/size/getItemDetail/pushItems/pullItems) accept
-- and return these virtual slot numbers.
local MultiInv = {}

-- Wraps a list of peripheral port names as one inventory.
-- Returns inv, name:
--   * one port  -> the raw wrapped peripheral and its port name (zero
--     overhead, full original method set -- custom stock peripherals keep
--     working exactly as before);
--   * 2+ ports  -> the virtual inventory and its virtual name. Pushing to
--     the virtual name moves items between member slots (slot compaction).
-- Returns nil when `ports` is empty.
function MultiInv.wrap(ports)
  if #ports == 0 then
    return nil
  end
  if #ports == 1 then
    return Utils.wrapPeripheral(ports[1]), ports[1]
  end

  local members = {}
  for i, port in ipairs(ports) do
    local p = Utils.wrapPeripheral(port)
    if not p.size then
      error(
        "Peripheral '"
          .. port
          .. "' has no size(); cannot join a multi-inventory",
        0
      )
    end
    members[i] = { port = port, p = p, size = p.size() }
  end

  local inv = {}
  inv.virtualName = "multi:" .. table.concat(ports, "+")

  -- Virtual slot -> member + member-local slot.
  local function resolve(slot)
    for _, m in ipairs(members) do
      if slot <= m.size then
        return m, slot
      end
      slot = slot - m.size
    end
    return nil
  end

  function inv.size()
    local total = 0
    for _, m in ipairs(members) do
      total = total + m.size
    end
    return total
  end

  function inv.list()
    -- Listings run concurrently (one peripheral call each), then merge
    -- with per-member slot offsets.
    local listings = {}
    local tasks = {}
    for i, m in ipairs(members) do
      tasks[i] = function()
        listings[i] = m.p.stock and m.p.stock() or m.p.list()
      end
    end
    Utils.runParallel(tasks)

    local merged = {}
    local offset = 0
    for i, m in ipairs(members) do
      for slot, item in pairs(listings[i] or {}) do
        merged[offset + slot] = item
      end
      offset = offset + m.size
    end
    return merged
  end

  function inv.getItemDetail(slot)
    local m, s = resolve(slot)
    if not m then
      return nil
    end
    if m.p.getStockItemDetail then
      return m.p.getStockItemDetail(s)
    end
    return m.p.getItemDetail(s)
  end

  function inv.pushItems(toName, fromSlot, limit, toSlot)
    local m, s = resolve(fromSlot)
    if not m then
      return 0
    end
    if toName == inv.virtualName then
      -- Self-directed move (slot compaction): resolve both ends and move
      -- directly between the member peripherals.
      local dm, ds = resolve(toSlot)
      if not dm then
        return 0
      end
      return m.p.pushItems(dm.port, s, limit, ds)
    end
    return m.p.pushItems(toName, s, limit, toSlot)
  end

  function inv.pullItems(fromName, fromSlot, limit, toSlot)
    if toSlot then
      local m, s = resolve(toSlot)
      if not m then
        return 0
      end
      return m.p.pullItems(fromName, fromSlot, limit, s)
    end
    -- No target slot: fill members in order until the request is
    -- satisfied. A drained source or a full member just returns 0 and the
    -- loop moves on, so no state has to be tracked between calls.
    local moved = 0
    for _, m in ipairs(members) do
      local remaining = limit and (limit - moved) or nil
      if remaining and remaining <= 0 then
        break
      end
      moved = moved + m.p.pullItems(fromName, fromSlot, remaining)
    end
    return moved
  end

  return inv, inv.virtualName
end

-- Wraps every peripheral assigned to a role as one inventory.
-- Returns nil when the role is not configured.
function MultiInv.forRole(role)
  return MultiInv.wrap(Roles.getPorts(role))
end

return MultiInv
