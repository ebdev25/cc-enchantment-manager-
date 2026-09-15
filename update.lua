local URL = "https://raw.githubusercontent.com/ebdev25/cc-enchantment-manager-/main/enchant.lua"
local TARGET = "enchant.lua"
local TEMP = "enchant.lua.tmp"

print("Enchantment Manager Updater")
print("Downloading latest version...")

-- Remove any leftover temporary download
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

-- Write new version to a temporary file first.
local file = fs.open(TEMP, "w")
file.write(code)
file.close()

-- Only replace the working version after a successful download.
if fs.exists(TARGET) then
    fs.delete(TARGET)
end

fs.move(TEMP, TARGET)

print("Update successful!")
print("Run 'enchant' to start.")
