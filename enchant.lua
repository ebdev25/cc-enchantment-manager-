-- CC Enchantment Manager 0.5
-- Warehouse scanner + monitor dashboard + pair optimizer
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

local monitor = peripheral.wrap(MONITOR)

if not monitor then
    error("Cannot find monitor: " .. MONITOR)
end

monitor.setTextScale(0.5)


-- ============================================================
-- ENCHANTMENT DATA
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


local function getLevel(pick, enchantment)
    return pick.enchants[enchantment] or 0
end


-- ============================================================
-- INVENTORY SCANNING
-- ============================================================

local function scanInventory(inventoryName, locationName)
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
                location = locationName,
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


-- ============================================================
-- FORTUNE STATISTICS
-- ============================================================

local function getFortuneStats(pickaxes)
    local stats = {
        counts = {},
        noFortune = 0,
        highest = 0
    }

    for _, pick in ipairs(pickaxes) do
        local fortune = getLevel(pick, "minecraft:fortune")

        if fortune == 0 then
            stats.noFortune = stats.noFortune + 1
        else
            stats.counts[fortune] =
                (stats.counts[fortune] or 0) + 1

            if fortune > stats.highest then
                stats.highest = fortune
            end
        end
    end

    return stats
end


-- ============================================================
-- COMBINATION SIMULATION
-- ============================================================

local function combineEnchantments(a, b)
    local result = {}

    -- Start with A's enchantments.
    for enchantment, level in pairs(a.enchants) do
        result[enchantment] = level
    end

    -- Merge B into the result.
    for enchantment, levelB in pairs(b.enchants) do
        local levelA = result[enchantment]

        if not levelA then
            result[enchantment] = levelB

        elseif levelA == levelB then
            -- Assumption for our over-level enchanting setup:
            -- equal levels upgrade by one.
            result[enchantment] = levelA + 1

        elseif levelB > levelA then
            result[enchantment] = levelB
        end
    end

    return result
end


-- ============================================================
-- PAIR SCORING
-- ============================================================

local function scorePair(a, b)
    local score = 0
    local upgrades = {}

    local fortuneA = getLevel(a, "minecraft:fortune")
    local fortuneB = getLevel(b, "minecraft:fortune")

    local efficiencyA = getLevel(a, "minecraft:efficiency")
    local efficiencyB = getLevel(b, "minecraft:efficiency")

    local unbreakingA = getLevel(a, "minecraft:unbreaking")
    local unbreakingB = getLevel(b, "minecraft:unbreaking")

    -- Fortune is overwhelmingly our primary objective.
    if fortuneA > 0 and fortuneA == fortuneB then
        score = score + 100000 + (fortuneA * 10000)

        table.insert(
            upgrades,
            "Fortune " .. fortuneA ..
            " -> " .. (fortuneA + 1)
        )
    end

    -- Matching Efficiency.
    if efficiencyA > 0 and efficiencyA == efficiencyB then
        score = score + 2000 + (efficiencyA * 200)

        table.insert(
            upgrades,
            "Efficiency " .. efficiencyA ..
            " -> " .. (efficiencyA + 1)
        )
    end

    -- Matching Unbreaking.
    if unbreakingA > 0 and unbreakingA == unbreakingB then
        score = score + 1000 + (unbreakingA * 100)

        table.insert(
            upgrades,
            "Unbreaking " .. unbreakingA ..
            " -> " .. (unbreakingA + 1)
        )
    end

    -- Reward matching modded/other enchantments too.
    for enchantment, levelA in pairs(a.enchants) do
        local levelB = b.enchants[enchantment]

        if levelB
            and levelA == levelB
            and enchantment ~= "minecraft:fortune"
            and enchantment ~= "minecraft:efficiency"
            and enchantment ~= "minecraft:unbreaking"
        then
            score = score + 100 + (levelA * 10)

            table.insert(
                upgrades,
                enchantment .. " " ..
                levelA .. " -> " .. (levelA + 1)
            )
        end
    end

    return score, upgrades
end


local function findBestPair(pickaxes)
    local best = nil

    for i = 1, #pickaxes - 1 do
        for j = i + 1, #pickaxes do
            local a = pickaxes[i]
            local b = pickaxes[j]

            local score, upgrades = scorePair(a, b)

            if score > 0 then
                if not best or score > best.score then
                    best = {
                        a = a,
                        b = b,
                        score = score,
                        upgrades = upgrades,
                        result = combineEnchantments(a, b)
                    }
                end
            end
        end
    end

    return best
end


-- ============================================================
-- DISPLAY HELPERS
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
end


local function horizontalLine(y)
    local width = monitor.getSize()

    monitor.setCursorPos(1, y)
    monitor.setTextColor(colors.gray)
    monitor.write(string.rep("-", width))
end


local function shortEnchantName(id)
    if id == "minecraft:fortune" then
        return "Fortune"
    elseif id == "minecraft:efficiency" then
        return "Efficiency"
    elseif id == "minecraft:unbreaking" then
        return "Unbreaking"
    end

    -- Remove namespace for modded enchantments.
    local short = id:match(":(.+)$")

    return short or id
end


local function drawPickaxe(x, y, label, pick)
    writeAt(
        x,
        y,
        label .. ": " .. pick.location ..
        " / Slot " .. pick.slot,
        colors.yellow
    )

    local line = y + 1

    -- Important enchants first.
    local important = {
        "minecraft:fortune",
        "minecraft:efficiency",
        "minecraft:unbreaking"
    }

    local printed = {}

    for _, enchantment in ipairs(important) do
        local level = pick.enchants[enchantment]

        if level then
            writeAt(
                x + 2,
                line,
                shortEnchantName(enchantment) ..
                " " .. level,
                colors.white
            )

            printed[enchantment] = true
            line = line + 1
        end
    end

    -- Then modded/other enchants.
    for enchantment, level in pairs(pick.enchants) do
        if not printed[enchantment] then
            writeAt(
                x + 2,
                line,
                shortEnchantName(enchantment) ..
                " " .. level,
                colors.lightGray
            )

            line = line + 1

            -- Avoid overflowing this section.
            if line > y + 5 then
                break
            end
        end
    end
end


-- ============================================================
-- DASHBOARD
-- ============================================================

local function drawDashboard(
    inputCount,
    storageCounts,
    allPickaxes,
    fortuneStats,
    bestPair
)
    clearMonitor()

    local width, height = monitor.getSize()

    writeAt(2, 1, "ENCHANTMENT MANAGER", colors.yellow)
    writeAt(width - 10, 1, "ONLINE", colors.lime)

    horizontalLine(2)

    -- Warehouse summary.
    writeAt(2, 4, "WAREHOUSE", colors.cyan)
    writeAt(2, 6, "Input:      " .. inputCount)

    for i, count in ipairs(storageCounts) do
        writeAt(
            2,
            6 + i,
            "Storage " .. i .. ":  " .. count
        )
    end

    writeAt(
        2,
        11,
        "TOTAL:      " .. #allPickaxes,
        colors.yellow
    )

    -- Fortune summary.
    local fortuneX = math.floor(width / 2)

    writeAt(
        fortuneX,
        4,
        "FORTUNE INVENTORY",
        colors.cyan
    )

    local y = 6

    for level = 1, fortuneStats.highest do
        local count = fortuneStats.counts[level]

        if count then
            writeAt(
                fortuneX,
                y,
                "Fortune " .. level .. ": " .. count
            )

            y = y + 1
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
            "Highest: Fortune " ..
            fortuneStats.highest,
            colors.yellow
        )
    end

    horizontalLine(14)

    -- Optimizer section.
    writeAt(2, 16, "BEST NEXT COMBINATION", colors.cyan)

    if not bestPair then
        writeAt(
            2,
            18,
            "No useful matching pair found.",
            colors.orange
        )
    else
        local rightX = math.floor(width / 2)

        drawPickaxe(
            2,
            18,
            "A",
            bestPair.a
        )

        drawPickaxe(
            rightX,
            18,
            "B",
            bestPair.b
        )

        local resultY = 25

        writeAt(
            2,
            resultY,
            "EXPECTED RESULT",
            colors.cyan
        )

        local fortune =
            bestPair.result["minecraft:fortune"]

        local efficiency =
            bestPair.result["minecraft:efficiency"]

        local unbreaking =
            bestPair.result["minecraft:unbreaking"]

        local resultText = ""

        if fortune then
            resultText =
                resultText .. "Fortune " .. fortune .. "  "
        end

        if efficiency then
            resultText =
                resultText ..
                "Efficiency " .. efficiency .. "  "
        end

        if unbreaking then
            resultText =
                resultText ..
                "Unbreaking " .. unbreaking
        end

        writeAt(
            2,
            resultY + 2,
            resultText,
            colors.lime
        )

        writeAt(
            2,
            resultY + 4,
            "Optimizer score: " .. bestPair.score,
            colors.gray
        )
    end

    horizontalLine(height - 2)

    writeAt(
        2,
        height - 1,
        "v0.5 - READ ONLY - no items moved",
        colors.gray
    )
end


-- ============================================================
-- MAIN
-- ============================================================

print("Enchantment Manager 0.5")
print("Scanning warehouse...")

local allPickaxes = {}

local inputPicks =
    scanInventory(INPUT, "Input")

addAll(allPickaxes, inputPicks)

local storageCounts = {}

for i, chestName in ipairs(STORAGE) do
    local picks =
        scanInventory(
            chestName,
            "Storage " .. i
        )

    storageCounts[i] = #picks
    addAll(allPickaxes, picks)
end

local fortuneStats =
    getFortuneStats(allPickaxes)

local bestPair =
    findBestPair(allPickaxes)

drawDashboard(
    #inputPicks,
    storageCounts,
    allPickaxes,
    fortuneStats,
    bestPair
)

print("Scan complete.")
print("Found " .. #allPickaxes .. " pickaxes.")

if bestPair then
    print(
        "Best pair: " ..
        bestPair.a.location .. ":" ..
        bestPair.a.slot ..
        " + " ..
        bestPair.b.location .. ":" ..
        bestPair.b.slot
    )

    print("Score: " .. bestPair.score)
else
    print("No useful matching pair found.")
end

print("Dashboard updated.")