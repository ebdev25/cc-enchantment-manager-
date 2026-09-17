local URL = "https://raw.githubusercontent.com/ebdev25/cc-enchantment-manager-/main/enchant.lua"
local TARGET = "enchant.lua"
local TEMP = "enchant.lua.tmp"

local function extractVersion(code)
    -- Expected header:
    -- -- CC Enchantment Manager 1.1.0
    return code:match("%-%- CC Enchantment Manager%s+([%w%.%-]+)")
end

local function readVersion(path)
    if not fs.exists(path) then
        return nil
    end

    local file = fs.open(path, "r")
    if not file then
        return nil
    end

    local code = file.readAll()
    file.close()

    return extractVersion(code)
end

print("Enchantment Manager Updater")

local oldVersion = readVersion(TARGET)

if oldVersion then
    print("Installed version: v" .. oldVersion)
else
    print("Installed version: unknown")
end

print("Downloading latest version...")

-- Remove any leftover temporary download.
if fs.exists(TEMP) then
    fs.delete(TEMP)
end

local response, err = http.get(URL)

if not response then
    printError("Download failed:")
    printError(err or "Unknown HTTP error")
    return
end

local code = response.readAll()
response.close()

if not code or code == "" then
    printError("Download failed: GitHub returned an empty file.")
    return
end

local newVersion = extractVersion(code)

if not newVersion then
    printError("Update aborted.")
    printError("Downloaded enchant.lua has no recognisable version header.")
    printError("Expected: -- CC Enchantment Manager x.y.z")
    return
end

print("Downloaded version: v" .. newVersion)

-- Write to a temporary file first.
local file = fs.open(TEMP, "w")

if not file then
    printError("Could not open temporary file for writing.")
    return
end

file.write(code)
file.close()

-- Only replace the working version after a successful, versioned download.
if fs.exists(TARGET) then
    fs.delete(TARGET)
end

fs.move(TEMP, TARGET)

print("")
print("Update successful!")

if oldVersion then
    if oldVersion == newVersion then
        print("Version: v" .. newVersion .. " (already latest)")
    else
        print("Updated: v" .. oldVersion .. " -> v" .. newVersion)
    end
else
    print("Installed: v" .. newVersion)
end

print("Run 'enchant' to start.")
