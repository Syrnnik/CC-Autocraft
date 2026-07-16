local Labels = require("lib.labels")

-- Fluid storage built on top of labeled peripherals.
--
-- A peripheral counts as a fluid tank when it is labeled (LABELS tab), is
-- currently connected, exposes the fluid_storage API (tanks/pushFluid) and is
-- NOT an item inventory. The inventory check keeps machines with internal
-- tanks (mixers, basins and the like) out of the shared pool: they are
-- processors, not storage, and draining them would steal recipe inputs.
--
-- All labeled tanks together form one shared pool. Amounts are in mB.
local Fluids = {}

-- Prefix used by the planner to keep fluid amounts separate from item counts
-- in the shared virtual-stock tables ("fluid:minecraft:lava").
Fluids.PREFIX = "fluid:"

function Fluids.isFluidName(name)
  return name:sub(1, #Fluids.PREFIX) == Fluids.PREFIX
end

function Fluids.stripPrefix(name)
  if Fluids.isFluidName(name) then
    return name:sub(#Fluids.PREFIX + 1)
  end
  return name
end

-- True when the peripheral can hold fluids (has the fluid_storage API).
local function hasFluidApi(port)
  if peripheral.hasType(port, "fluid_storage") then
    return true
  end
  local p = peripheral.wrap(port)
  return p ~= nil and type(p.tanks) == "function"
end

-- True when `port` should be part of the fluid storage pool.
function Fluids.isTank(port)
  if not peripheral.isPresent(port) then
    return false
  end
  if not hasFluidApi(port) then
    return false
  end
  -- Machines expose an item inventory next to their tanks; pure tanks don't.
  return not peripheral.hasType(port, "inventory")
end

-- Labeled peripherals that act as fluid storage, sorted by port name.
function Fluids.getTankPorts()
  local ports = {}
  for port in pairs(Labels.getAll()) do
    if Fluids.isTank(port) then
      table.insert(ports, port)
    end
  end
  table.sort(ports)
  return ports
end

-- Fluid levels of a single peripheral: { [fluidName] = mB }. Works for pool
-- tanks and machines alike; a peripheral without tanks yields {}.
function Fluids.tankLevels(port)
  local levels = {}
  local p = peripheral.wrap(port)
  if not p or type(p.tanks) ~= "function" then
    return levels
  end
  local ok, tanks = pcall(p.tanks)
  if not ok or type(tanks) ~= "table" then
    return levels
  end
  for _, tank in pairs(tanks) do
    local name = tank.name or tank.fluid
    local amount = tank.amount or 0
    if name and amount > 0 then
      levels[name] = (levels[name] or 0) + amount
    end
  end
  return levels
end

-- Total mB per fluid across the whole pool: { [fluidName] = mB }.
function Fluids.getTotals()
  local totals = {}
  for _, port in ipairs(Fluids.getTankPorts()) do
    for name, amount in pairs(Fluids.tankLevels(port)) do
      totals[name] = (totals[name] or 0) + amount
    end
  end
  return totals
end

-- Pool total of one fluid in mB.
function Fluids.count(fluidName)
  return Fluids.getTotals()[fluidName] or 0
end

-- Moves up to `mb` of `fluidName` between two peripherals on the wired
-- network. Tries pushFluid from the source, then pullFluid from the target
-- (mods differ in which side they implement). Returns mB actually moved.
local function moveFluid(fromPort, toPort, fluidName, mb)
  if mb <= 0 then
    return 0
  end
  local from = peripheral.wrap(fromPort)
  if from and type(from.pushFluid) == "function" then
    local ok, moved = pcall(from.pushFluid, toPort, mb, fluidName)
    if ok and moved and moved > 0 then
      return moved
    end
  end
  local to = peripheral.wrap(toPort)
  if to and type(to.pullFluid) == "function" then
    local ok, moved = pcall(to.pullFluid, fromPort, mb, fluidName)
    if ok and moved then
      return moved
    end
  end
  return 0
end

Fluids.move = moveFluid

-- Extracts `mb` of `fluidName` from the pool into `targetPort` (a machine).
-- Drains tanks one by one until the request is satisfied. Returns mB moved.
function Fluids.extractTo(targetPort, fluidName, mb)
  local remaining = mb
  local moved = 0
  for _, port in ipairs(Fluids.getTankPorts()) do
    if remaining <= 0 then
      break
    end
    local available = Fluids.tankLevels(port)[fluidName] or 0
    if available > 0 then
      local n =
        moveFluid(port, targetPort, fluidName, math.min(remaining, available))
      moved = moved + n
      remaining = remaining - n
    end
  end
  return moved
end

-- Returns fluid from `fromPort` (a machine) back into the pool. When
-- `fluidName` is nil every fluid found in the source is deposited; `mb`
-- limits the amount per fluid (nil = everything). Returns total mB moved.
function Fluids.depositFrom(fromPort, fluidName, mb)
  local names = {}
  if fluidName then
    table.insert(names, fluidName)
  else
    for name in pairs(Fluids.tankLevels(fromPort)) do
      table.insert(names, name)
    end
  end

  local totalMoved = 0
  local pool = Fluids.getTankPorts()
  for _, name in ipairs(names) do
    local remaining = mb or math.huge
    for _, port in ipairs(pool) do
      if remaining <= 0 then
        break
      end
      -- A tank that rejects the fluid (full or fluid-locked) moves 0 and the
      -- loop just tries the next one.
      local chunk = remaining == math.huge and 1000000000 or remaining
      local n = moveFluid(fromPort, port, name, chunk)
      totalMoved = totalMoved + n
      remaining = remaining - n
    end
  end
  return totalMoved
end

return Fluids
