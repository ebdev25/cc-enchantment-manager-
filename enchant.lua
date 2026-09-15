-- CC Enchantment Manager 0.4
-- Warehouse scanner + monitor dashboard
-- READ ONLY: this version never moves items.

local INPUT = "minecraft:chest_0"

local STORAGE = {
    "minecraft:chest_1",
    "minecraft:chest_2",
    "minecraft:chest_3"
}

local OUTPUT = "minecraft:chest_4"
local REJECT = "minecraft:chest_5"
local MONITOR = "monitor_0"


-- ============================================================
-- Peripheral setup
-- ============================================================

local monitor = peripheral.wrap(MONITOR)

if not monitor then
    error("Cannot find monitor: " .. MONITOR)
end

-- Smaller number = more text fits on screen.
monitor.setTextScale(0.5)


-- ============================================================
-- Pickaxe scanning
-- ============================================================

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


-- ============================================================
-- Statistics
-- ============================================================

local function getFortuneStats(pickaxes)
    local stats = {
        counts = {},
        noFortune = 0,
        highest = 0,
        totalFortune = 0
    }

    for _, pick in ipairs(pickaxes) do
        local fortune = getLevel(pick, "minecraft:fortune")

        if fortune == 0 then
            stats.noFortune = stats.noFortune + 1
        else
            stats.counts[fortune] =
                (stats.counts[fortune] or 0) + 1

            stats.totalFortune = stats.totalFortune + 1

            if fortune > stats.highest then
                stats.highest = fortune
            end
        end
    end

    return stats
end


-- ============================================================
-- Monitor drawing helpers
-- ============================================================

local function writeAt(x, y, text, textColor, backgroundColor)
    if textColor then
        monitor.setTextColor(textColor)
    end

    if backgroundColor then
        monitor.setBackgroundColor(backgroundColor)
    end

    monitor.setCursorPos(x, y)
    monitor.write(text)
end


local function clearMonitor()
    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
    monitor.clear()
    monitor.setCursorPos(1, 1)
end


local function horizontalLine(y)
    local width = monitor.getSize()

    monitor.setCursorPos(1, y)
    monitor.setTextColor(colors.gray)
    monitor.write(string.rep("-", width))
end


-- ============================================================
-- Dashboard
-- ============================================================

local function drawDashboard(
    inputCount,
    storageCounts,
    allPickaxes,
    fortuneStats
)
    clearMonitor()

    local width, height = monitor.getSize()

    -- Header
    writeAt(
        2,
        1,
        "ENCHANTMENT MANAGER",
        colors.yellow
    )

    writeAt(
        width - 10,
        1,
        "ONLINE",
        colors.lime
    )

    horizontalLine(2)

    -- Warehouse section
    writeAt(2, 4, "WAREHOUSE", colors.cyan)

    writeAt(
        2,
        6,
        "Input:      " .. inputCount,
        colors.white
    )

    for i, count in ipairs(storageCounts) do
        writeAt(
            2,
            6 + i,
            "Storage " .. i .. ":  " .. count,
            colors.white
        )
    end

    writeAt(
        2,
        11,
        "TOTAL:      " .. #allPickaxes,
        colors.yellow
    )

    -- Fortune section
    local fortuneX = math.floor(width / 2)

    writeAt(
        fortuneX,
        4,
        "FORTUNE INVENTORY",
        colors.cyan
    )

    local y = 6

    if fortuneStats.highest == 0 then
        writeAt(
            fortuneX,
            y,
            "No Fortune pickaxes",
            colors.red
        )

        y = y + 1
    else
        for level = 1, fortuneStats.highest do
            local count = fortuneStats.counts[level]

            if count then
                writeAt(
                    fortuneX,
                    y,
                    "Fortune " .. level .. ": " .. count,
                    colors.white
                )

                y = y + 1
            end
        end
    end

    writeAt(
        fortuneX,
        y + 1,
        "No Fortune: " .. fortuneStats.noFortune,
        colors.lightGray
    )

    if fortuneStats.highest > 0 then
        writeAt(
            fortuneX,
            y + 3,
            "Highest: Fortune " .. fortuneStats.highest,
            colors.yellow
        )
    end

    horizontalLine(14)

    -- Status section
    writeAt(2, 16, "STATUS", colors.cyan)

    writeAt(
        2,
        18,
        "Warehouse scan complete.",
        colors.lime
    )

    writeAt(
        2,
        19,
        "System is READ ONLY.",
        colors.orange
    )

    writeAt(
        2,
        21,
        "No items will be moved.",
        colors.lightGray
    )

    horizontalLine(height - 2)

    writeAt(
        2,
        height - 1,
        "CC Enchantment Manager v0.4",
        colors.gray
    )
end


-- ============================================================
-- Main
-- ============================================================

print("Enchantment Manager 0.4")
print("Scanning warehouse...")

local allPickaxes = {}

-- Input
local inputPicks = scanInventory(INPUT)
addAll(allPickaxes, inputPicks)

-- Storage
local storageCounts = {}

for i, chestName in ipairs(STORAGE) do
    local picks = scanInventory(chestName)

    storageCounts[i] = #picks
    addAll(allPickaxes, picks)
end

-- Statistics
local fortuneStats = getFortuneStats(allPickaxes)

-- Draw monitor
drawDashboard(
    #inputPicks,
    storageCounts,
    allPickaxes,
    fortuneStats
)

-- Keep terminal output short and useful.
print("Scan complete.")
print("Found " .. #allPickaxes .. " pickaxes.")
print("Dashboard displayed on " .. MONITOR .. ".")