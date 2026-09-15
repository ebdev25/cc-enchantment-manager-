-- CC Enchantment Manager 0.3
-- Read-only warehouse scanner

local INPUT = "minecraft:chest_0"

local STORAGE = {
    "minecraft:chest_1",
    "minecraft:chest_2",
    "minecraft:chest_3"
}

local OUTPUT = "minecraft:chest_4"
local REJECT = "minecraft:chest_5"


local function getEnchantments(detail)
    local enchants = {}

    if detail.enchantments then
        for _, enchant in ipairs(detail.enchantments) do
            enchants[enchant.name] = enchant.level
        end
    end

    return enchants
end


local function scanInventory(inventoryName)
    local inventory = peripheral.wrap(inventoryName)
    local pickaxes = {}

    if not inventory then
        error("Cannot find inventory: " .. inventoryName)
    end

    for slot, item in pairs(inventory.list()) do
        if item.name == "minecraft:diamond_pickaxe" then
            local detail = inventory.getItemDetail(slot)

            table.insert(pickaxes, {
                chest = inventoryName,
                slot = slot,
                name = detail.displayName,
                enchants = getEnchantments(detail)
            })
        end
    end

    return pickaxes
end


local function addAll(destination, source)
    for _, item in ipairs(source) do
        table.insert(destination, item)
    end
end


local function getLevel(pick, enchantment)
    return pick.enchants[enchantment] or 0
end


local function printSummary(pickaxes)
    local fortuneCounts = {}
    local noFortune = 0
    local highestFortune = 0

    for _, pick in ipairs(pickaxes) do
        local fortune = getLevel(pick, "minecraft:fortune")

        if fortune == 0 then
            noFortune = noFortune + 1
        else
            fortuneCounts[fortune] = (fortuneCounts[fortune] or 0) + 1

            if fortune > highestFortune then
                highestFortune = fortune
            end
        end
    end

    print("=== Fortune Summary ===")

    if highestFortune == 0 then
        print("No Fortune pickaxes found.")
    else
        for level = 1, highestFortune do
            if fortuneCounts[level] then
                print(
                    "Fortune " .. level ..
                    ": " .. fortuneCounts[level]
                )
            end
        end
    end

    print("No Fortune: " .. noFortune)
end


local function printPickaxe(pick)
    print(pick.chest .. " slot " .. pick.slot)

    for enchantment, level in pairs(pick.enchants) do
        print("  " .. enchantment .. " = " .. level)
    end

    print()
end


print("=== Enchantment Manager 0.3 ===")
print("Read-only warehouse scan")
print()

local allPickaxes = {}

local inputPicks = scanInventory(INPUT)
addAll(allPickaxes, inputPicks)

print("Input: " .. #inputPicks .. " pickaxes")

local storageTotal = 0

for _, chestName in ipairs(STORAGE) do
    local picks = scanInventory(chestName)

    addAll(allPickaxes, picks)
    storageTotal = storageTotal + #picks

    print(chestName .. ": " .. #picks .. " pickaxes")
end

print()
print("Storage: " .. storageTotal .. " pickaxes")
print("TOTAL: " .. #allPickaxes .. " pickaxes")
print()

printSummary(allPickaxes)

print()
print("=== All Pickaxes ===")
print()

for _, pick in ipairs(allPickaxes) do
    printPickaxe(pick)
end