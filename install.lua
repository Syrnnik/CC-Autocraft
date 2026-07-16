-- CC:Autocraft Installer
-- Usage:
--   wget run https://raw.githubusercontent.com/Syrnnik/CC-Autocraft/dev/install.lua computer [dest]
--   wget run https://raw.githubusercontent.com/Syrnnik/CC-Autocraft/dev/install.lua crafter [dest]
--
-- dest: optional install folder (default: autocraft)

local args = { ... }
local TARGET = args[1]
local REPO = "Syrnnik/CC-Autocraft"
local BRANCH = "dev"
local BASE = "https://raw.githubusercontent.com/"
  .. REPO
  .. "/"
  .. BRANCH
  .. "/src/"
local DEST = args[2] or "autocraft"

local COMPUTER_FILES = {
  "lib/config.lua",
  "lib/crafting.lua",
  "lib/display_names.lua",
  "lib/fluids.lua",
  "lib/labels.lua",
  "lib/logger.lua",
  "lib/multi_inv.lua",
  "lib/network.lua",
  "lib/planner.lua",
  "lib/recipes.lua",
  "lib/roles.lua",
  "lib/screen.lua",
  "lib/stock.lua",
  "lib/ui.lua",
  "lib/updater.lua",
  "lib/utils.lua",
  "all_recipes.lua",
  "checklist.lua",
  "craft.lua",
  "delete_recipe.lua",
  "device_id.lua",
  "get_recipe.lua",
  "main.lua",
  "migrate_recipes.lua",
  "monitor.lua",
  "new_craft.lua",
  "scan_names.lua",
}

local CRAFTER_FILES = {
  "lib/config.lua",
  "lib/logger.lua",
  "lib/network.lua",
  "lib/screen.lua",
  "lib/updater.lua",
  "lib/utils.lua",
  "crafter.lua",
  "device_id.lua",
}

local FILES_BY_TARGET = {
  computer = COMPUTER_FILES,
  crafter = CRAFTER_FILES,
}

if not TARGET or not FILES_BY_TARGET[TARGET] then
  print("Usage: install.lua <computer|crafter>")
  return
end

local function download(path)
  local res = http.get(BASE .. path)
  if not res then
    return false, "request failed"
  end
  local content = res.readAll()
  res.close()

  local dest = DEST .. "/" .. path
  local dir = fs.getDir(dest)
  if not fs.exists(dir) then
    fs.makeDir(dir)
  end

  local f = fs.open(dest, "w")
  if not f then
    return false, "cannot write file"
  end
  f.write(content)
  f.close()
  return true
end

-- Fetches the head commit SHA of the release branch (for the update
-- checker). Best effort: nil when the API is unreachable.
local function fetchRemoteSha()
  local res = http.get(
    "https://api.github.com/repos/" .. REPO .. "/commits/" .. BRANCH,
    { ["User-Agent"] = "cc-autocraft-installer" }
  )
  if not res then
    return nil
  end
  local body = res.readAll()
  res.close()
  local data = textutils.unserializeJSON(body)
  return data and data.sha or nil
end

print("CC:Autocraft installer (" .. TARGET .. " -> " .. DEST .. ")")
print(string.rep("-", 40))

local failed = {}
for _, file in ipairs(FILES_BY_TARGET[TARGET]) do
  io.write("  " .. file .. "... ")
  local ok, err = download(file)
  if ok then
    print("ok")
  else
    print("FAILED (" .. (err or "?") .. ")")
    table.insert(failed, file)
  end
end

if not fs.exists(DEST .. "/data") then
  fs.makeDir(DEST .. "/data")
  print("  data/ ... ok")
end

-- Stamp the installed version so the startup update check has a baseline.
if #failed == 0 then
  local sha = fetchRemoteSha()
  if sha then
    local f = fs.open(DEST .. "/data/version.json", "w")
    if f then
      f.write(textutils.serializeJSON({ sha = sha, target = TARGET }))
      f.close()
      print("  data/version.json ... ok (" .. sha:sub(1, 7) .. ")")
    end
  end
end

print(string.rep("-", 40))
if #failed == 0 then
  print(
    "Done! Open the monitor and use the SETUP tab to configure peripherals."
  )
else
  print("Finished with errors:")
  for _, f in ipairs(failed) do
    print("  - " .. f)
  end
end

return #failed == 0
