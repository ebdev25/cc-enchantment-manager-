local INPUT = "minecraft:chest_0"

local input = peripheral.wrap(INPUT)

function getEnchantments(detail)
    local enchants = {}

    if detail.enchantments then
        for _, enchant in ipairs(detail.enchantments) do
            enchants[enchant.name] = enchant.level
        end
    end

    return enchants
end

function scanPickaxes(inventory, inventoryName)
    local pickaxes = {}

    for slot, item in pairs(inventory.list()) do
        local detail = inventory.getItemDetail(slot)

        if detail.name == "minecraft:diamond_pickaxe" then
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

function printPickaxe(pick)
    print("Slot " .. pick.slot .. ": " .. pick.name)

    for enchant, level in pairs(pick.enchants) do
        print("  " .. enchant .. " = " .. level)
    end

    print()
end


print("=== Enchantment Manager 0.2 ===")
print()

local pickaxes = scanPickaxes(input, INPUT)

print("Found " .. #pickaxes .. " diamond pickaxes.")
print()

for _, pick in ipairs(pickaxes) do
    printPickaxe(pick)
end
