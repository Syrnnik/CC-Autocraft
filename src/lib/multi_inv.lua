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

-- Per-port slot-count cache: static sizes live for the session, synthetic
-- (listing-derived) sizes for a few seconds. See MultiInv.wrap.
local sizeCache = {}

-- Per-port "which item ids does this storage hold" cache, used by
-- pullItemsPreferring to route deposits to the member already holding the
-- item (a drawer bank) instead of the first member in role order.
local holdsCache = {}
local HOLDS_TTL_MS = 5000

local function memberHolds(member, itemName)
  local cached = holdsCache[member.port]
  local now = os.epoch("utc")
  if not cached or now - cached.at >= HOLDS_TTL_MS then
    local names = {}
    local lister = member.p.stock or member.p.list
    if lister then
      local ok, listing = pcall(lister)
      if ok and type(listing) == "table" then
        for _, item in pairs(listing) do
          if item.name then
            names[item.name] = true
          end
        end
      end
    end
    cached = { at = now, names = names }
    holdsCache[member.port] = cached
  end
  return cached.names[itemName] == true
end

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
    local size
    local cached = sizeCache[port]
    if p.size then
      -- A peripheral's slot count never changes while it exists, so one
      -- size() call per port per session is enough. Re-wrapping happens on
      -- every stock operation; without the cache that was N peripheral
      -- calls per wrap.
      if cached and cached.static then
        size = cached.size
      else
        size = p.size()
        sizeCache[port] = { size = size, static = true }
      end
    else
      -- Listing-only peripherals (custom stock views with
      -- stock()/getStockItemDetail but no size(), e.g. a Create stock
      -- ticker) join with a synthetic slot space spanning their current
      -- listing. That listing may be expensive, so the synthetic size is
      -- cached for a few seconds.
      local now = os.epoch("utc")
      if cached and not cached.static and now - cached.at < 5000 then
        size = cached.size
      else
        local lister = p.stock or p.list
        if not lister then
          error(
            "Peripheral '"
              .. port
              .. "' has no size()/list()/stock(); cannot join a"
              .. " multi-inventory",
            0
          )
        end
        size = 0
        for slot in pairs(lister() or {}) do
          if type(slot) == "number" and slot > size then
            size = slot
          end
        end
        sizeCache[port] = { size = size, static = false, at = now }
      end
    end
    members[i] = { port = port, p = p, size = size }
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

  -- Members without pushItems/pullItems (listing-only peripherals) simply
  -- move nothing: transfers skip them the same way a full or drained
  -- member is skipped.
  function inv.pushItems(toName, fromSlot, limit, toSlot)
    local m, s = resolve(fromSlot)
    if not m or not m.p.pushItems then
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
      if not m or not m.p.pullItems then
        return 0
      end
      return m.p.pullItems(fromName, fromSlot, limit, s)
    end
    -- No target slot: fill members in order until the request is
    -- satisfied. A full member returns 0 and the loop moves on; once
    -- items HAVE moved and a member pulls nothing, the source slot is
    -- drained -- stop instead of asking every remaining member.
    local moved = 0
    for _, m in ipairs(members) do
      local remaining = limit and (limit - moved) or nil
      if remaining and remaining <= 0 then
        break
      end
      if m.p.pullItems then
        local n = m.p.pullItems(fromName, fromSlot, remaining)
        moved = moved + n
        if n == 0 and moved > 0 then
          break
        end
      end
    end
    return moved
  end

  -- Like pullItems without a target slot, but members that ALREADY hold
  -- `itemName` are tried first: their own insertion logic tops up the
  -- existing stacks (drawers, chests), so items land next to their kin
  -- instead of in whatever member comes first in role order. Falls back
  -- to the remaining members for any leftovers.
  function inv.pullItemsPreferring(itemName, fromName, fromSlot, limit)
    local moved = 0
    local function pullInto(m)
      local remaining = limit and (limit - moved) or nil
      if remaining and remaining <= 0 then
        return true
      end
      if m.p.pullItems then
        local n = m.p.pullItems(fromName, fromSlot, remaining)
        moved = moved + n
        if n == 0 and moved > 0 then
          return true -- source drained
        end
      end
      return false
    end

    for _, m in ipairs(members) do
      if memberHolds(m, itemName) and pullInto(m) then
        return moved
      end
    end
    for _, m in ipairs(members) do
      if not memberHolds(m, itemName) and pullInto(m) then
        return moved
      end
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
