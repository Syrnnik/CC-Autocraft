-- Update checker / installer.
--
-- The installed version is the commit SHA stored in data/version.json
-- (stamped by install.lua and after every successful update). The latest
-- version is the head commit of the release branch, fetched from the
-- GitHub API. When they differ, the user is offered Skip / Install.
-- Install downloads the latest install.lua and runs it in place, so the
-- file list always comes from the new version.

local Updater = {}

Updater.REPO = "Syrnnik/CC-Autocraft"
Updater.BRANCH = "dev"

local VERSION_PATH = "data/version.json"
local API_URL = "https://api.github.com/repos/"
  .. Updater.REPO
  .. "/commits/"
  .. Updater.BRANCH
local INSTALLER_URL = "https://raw.githubusercontent.com/"
  .. Updater.REPO
  .. "/"
  .. Updater.BRANCH
  .. "/install.lua"

local function readVersion()
  if not fs.exists(VERSION_PATH) then
    return {}
  end
  local f = fs.open(VERSION_PATH, "r")
  if not f then
    return {}
  end
  local content = f.readAll()
  f.close()
  return textutils.unserializeJSON(content) or {}
end

local function writeVersion(data)
  if not fs.exists("data") then
    fs.makeDir("data")
  end
  local f = fs.open(VERSION_PATH, "w")
  if not f then
    return
  end
  f.write(textutils.serializeJSON(data))
  f.close()
end

function Updater.shortSha(sha)
  if type(sha) ~= "string" or sha == "" then
    return "none"
  end
  return sha:sub(1, 7)
end

-- Fetches the latest commit SHA of the release branch, or nil + error.
function Updater.getRemoteSha()
  if not http then
    return nil, "http API is disabled"
  end
  local res, err =
    http.get(API_URL, { ["User-Agent"] = "cc-autocraft-updater" })
  if not res then
    return nil, err or "request failed"
  end
  local body = res.readAll()
  res.close()
  local data = textutils.unserializeJSON(body)
  if not data or type(data.sha) ~= "string" then
    return nil, "unexpected API response"
  end
  return data.sha
end

-- Compares local and remote versions.
-- Returns { hasUpdate, remoteSha, localSha, target } or nil + error.
-- `target` is "computer" or "crafter" (which file set to install).
function Updater.check(target)
  local remoteSha, err = Updater.getRemoteSha()
  if not remoteSha then
    return nil, err
  end
  local localSha = readVersion().sha
  return {
    hasUpdate = localSha ~= remoteSha,
    remoteSha = remoteSha,
    localSha = localSha,
    target = target,
  }
end

-- Downloads the latest install.lua and runs it for info.target into
-- installDir (the folder the running program lives in). On success the
-- new SHA is stamped into data/version.json. Returns true, or nil + error.
function Updater.install(info, installDir)
  if not http then
    return nil, "http API is disabled"
  end
  local res, err = http.get(INSTALLER_URL)
  if not res then
    return nil, err or "cannot download installer"
  end
  local content = res.readAll()
  res.close()

  local fn, loadErr = load(content, "install.lua", "t")
  if not fn then
    return nil, loadErr
  end

  local ok, result = pcall(fn, info.target, installDir or "")
  if not ok then
    return nil, tostring(result)
  end
  if result == false then
    return nil, "some files failed to download"
  end

  writeVersion({ sha = info.remoteSha, target = info.target })
  return true
end

-- Copies the freshly installed entry point over the running program when
-- they differ (the common setup renames monitor.lua/crafter.lua to
-- startup.lua for auto-start; without this the renamed copy would keep
-- running the old version after every update).
function Updater.syncEntry(installDir, entryName, runningPath)
  if not runningPath or runningPath == "" then
    return
  end
  local src = fs.combine(installDir or "", entryName)
  local dst = fs.combine(runningPath, "")
  if src == dst or not fs.exists(src) then
    return
  end
  fs.delete(dst)
  fs.copy(src, dst)
end

-- Terminal prompt (used on the crafter turtle): asks 0 = Skip, 1 = Install.
-- Returns true when the user picked Install.
function Updater.promptTerminal(info)
  print("CC:Autocraft update available!")
  print(
    "  "
      .. Updater.shortSha(info.localSha)
      .. " -> "
      .. Updater.shortSha(info.remoteSha)
  )
  while true do
    write("Install update? (0 = Skip, 1 = Install): ")
    local answer = read()
    if answer == "0" then
      return false
    end
    if answer == "1" then
      return true
    end
  end
end

-- Monitor prompt (used on the main computer): draws Skip / Install buttons
-- on the monitor and waits for a touch. The terminal keys 0/1 also work.
-- Falls back to the terminal prompt when the monitor is unavailable.
-- Returns true when the user picked Install.
function Updater.promptMonitor(monitorName, info)
  local mon = monitorName and peripheral.wrap(monitorName)
  if not mon then
    return Updater.promptTerminal(info)
  end

  mon.setBackgroundColor(colors.black)
  mon.clear()

  local function at(x, y, text, fg, bg)
    mon.setCursorPos(x, y)
    mon.setBackgroundColor(bg)
    mon.setTextColor(fg)
    mon.write(text)
  end

  at(2, 2, "CC:Autocraft update available!", colors.yellow, colors.black)
  at(
    2,
    4,
    "Installed: " .. Updater.shortSha(info.localSha),
    colors.lightGray,
    colors.black
  )
  at(
    2,
    5,
    "Latest:    " .. Updater.shortSha(info.remoteSha),
    colors.white,
    colors.black
  )

  local btnY = 7
  local skipLabel = " Skip "
  local installLabel = " Install "
  local skipX = 2
  local installX = skipX + #skipLabel + 2
  at(skipX, btnY, skipLabel, colors.white, colors.gray)
  at(installX, btnY, installLabel, colors.black, colors.green)

  print("Update available: use the monitor buttons (or press 0/1).")

  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "monitor_touch" and ev[2] == monitorName and ev[4] == btnY then
      local x = ev[3]
      if x >= skipX and x < skipX + #skipLabel then
        return false
      end
      if x >= installX and x < installX + #installLabel then
        at(2, btnY + 2, "Installing update...", colors.yellow, colors.black)
        return true
      end
    elseif ev[1] == "char" then
      if ev[2] == "0" then
        return false
      end
      if ev[2] == "1" then
        at(2, btnY + 2, "Installing update...", colors.yellow, colors.black)
        return true
      end
    end
  end
end

return Updater
