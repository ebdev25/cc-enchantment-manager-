-- CC Enchantment Manager 0.6
-- Look-ahead Fortune planner
-- READ ONLY: never moves items.

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
-- ENCHANTMENTS
-- ============================================================

local function getEnchantments(detail)
    local result = {}

    if detail.enchantments then
        for _, enchant in ipairs(detail.enchantments) do
            result[enchant.name] = enchant.level
        end
    end

    return result
end


local function getLevel(pick, enchantment)
    return pick.enchants[enchantment] or 0
end


local function combineEnchantments(a, b)
    local result = {}

    for enchantment, level in pairs(a.enchants) do
        result[enchantment] = level
    end

    for enchantment, levelB in pairs(b.enchants) do
        local levelA = result[enchantment]

        if not levelA then
            result[enchantment] = levelB

        elseif levelA == levelB then
            result[enchantment] = levelA + 1

        elseif levelB > levelA then
            result[enchantment] = levelB
        end
    end

    return result
end


-- ============================================================
-- INVENTORY
-- ============================================================

local function scanInventory(name, location)
    local inventory = peripheral.wrap(name)

    if not inventory then
        error("Cannot find inventory: " .. name)
    end

    local picks = {}

    for slot, item in pairs(inventory.list()) do
        if item.name == "minecraft:diamond_pickaxe" then
            local detail = inventory.getItemDetail(slot)

            table.insert(picks, {
                chest = name,
                location = location,
                slot = slot,
                name = detail.displayName,
                enchants = getEnchantments(detail),

                -- Every physical pick gets a unique identity.
                id = name .. ":" .. slot
            })
        end
    end

    return picks
end


local function addAll(destination, source)
    for _, value in ipairs(source) do
        table.insert(destination, value)
    end
end


-- ============================================================
-- FORTUNE INVENTORY
-- ============================================================

local function getFortuneStats(picks)
    local stats = {
        counts = {},
        noFortune = 0,
        highest = 0
    }

    for _, pick in ipairs(picks) do
        local fortune = getLevel(pick, "minecraft:fortune")

        if fortune == 0 then
            stats.noFortune = stats.noFortune + 1
        else
            stats.counts[fortune] =
                (stats.counts[fortune] or 0) + 1

            stats.highest = math.max(
                stats.highest,
                fortune
            )
        end
    end

    return stats
end


-- Carry pairs upward exactly like binary addition.
local function calculateReachableFortune(stats)
    if stats.highest == 0 then
        return 0
    end

    local counts = {}

    for level, count in pairs(stats.counts) do
        counts[level] = count
    end

    local level = 1
    local highest = stats.highest

    while level <= highest do
        local count = counts[level] or 0
        local promoted = math.floor(count / 2)

        if promoted > 0 then
            counts[level + 1] =
                (counts[level + 1] or 0) + promoted

            highest = math.max(highest, level + 1)
        end

        level = level + 1
    end

    return highest
end


-- ============================================================
-- SECONDARY QUALITY
-- ============================================================

local function secondaryQuality(pick)
    local score = 0

    local efficiency =
        getLevel(pick, "minecraft:efficiency")

    local unbreaking =
        getLevel(pick, "minecraft:unbreaking")

    -- Fortune deliberately excluded here.
    score = score + efficiency * 100
    score = score + unbreaking * 50

    -- Small reward for retaining additional enchants.
    for enchantment, level in pairs(pick.enchants) do
        if enchantment ~= "minecraft:fortune"
            and enchantment ~= "minecraft:efficiency"
            and enchantment ~= "minecraft:unbreaking"
        then
            score = score + level * 5
        end
    end

    return score
end


local function pairSynergy(a, b)
    local score = 0

    for enchantment, levelA in pairs(a.enchants) do
        local levelB = b.enchants[enchantment]

        if levelB and levelA == levelB then
            if enchantment == "minecraft:efficiency" then
                score = score + 1000 + levelA * 100

            elseif enchantment == "minecraft:unbreaking" then
                score = score + 500 + levelA * 50

            elseif enchantment ~= "minecraft:fortune" then
                score = score + 50 + levelA * 5
            end
        end
    end

    return score
end


-- ============================================================
-- PLANNING NODES
-- ============================================================

-- A planning node can represent either a real pickaxe or
-- a hypothetical result produced by combining two nodes.

local function physicalNode(pick)
    return {
        pick = pick,
        enchants = pick.enchants,
        fortune = getLevel(pick, "minecraft:fortune"),
        steps = {},
        leaves = { pick }
    }
end


local function virtualPick(node)
    return {
        enchants = node.enchants
    }
end


local function combineNodes(a, b)
    local pickA = virtualPick(a)
    local pickB = virtualPick(b)

    local enchants = combineEnchantments(pickA, pickB)

    local steps = {}

    addAll(steps, a.steps)
    addAll(steps, b.steps)

    table.insert(steps, {
        a = a,
        b = b,
        resultFortune =
            enchants["minecraft:fortune"] or 0
    })

    local leaves = {}

    addAll(leaves, a.leaves)
    addAll(leaves, b.leaves)

    return {
        enchants = enchants,
        fortune =
            enchants["minecraft:fortune"] or 0,
        steps = steps,
        leaves = leaves
    }
end


local function nodeQuality(node)
    return secondaryQuality({
        enchants = node.enchants
    })
end


-- ============================================================
-- LOOK-AHEAD PLANNER
-- ============================================================

local function buildPlan(allPicks)
    -- ========================================================
    -- 1. Group physical Fortune picks by level
    -- ========================================================

    local available = {}
    local counts = {}
    local currentHighest = 0

    for _, pick in ipairs(allPicks) do
        local fortune =
            getLevel(pick, "minecraft:fortune")

        if fortune > 0 then
            available[fortune] =
                available[fortune] or {}

            table.insert(
                available[fortune],
                physicalNode(pick)
            )

            counts[fortune] =
                (counts[fortune] or 0) + 1

            currentHighest =
                math.max(currentHighest, fortune)
        end
    end

    if currentHighest == 0 then
        return nil
    end


    -- ========================================================
    -- 2. Calculate maximum reachable Fortune
    --
    -- This is only used to determine the TARGET level.
    -- It does NOT actually build combinations.
    -- ========================================================

    local simCounts = {}

    for level, count in pairs(counts) do
        simCounts[level] = count
    end

    local reachable = currentHighest
    local level = 1

    while level <= reachable do
        local count =
            simCounts[level] or 0

        local promoted =
            math.floor(count / 2)

        if promoted > 0 then
            simCounts[level + 1] =
                (simCounts[level + 1] or 0)
                + promoted

            reachable =
                math.max(
                    reachable,
                    level + 1
                )
        end

        level = level + 1
    end


    -- ========================================================
    -- 3. Compare two candidate result nodes
    --
    -- Fortune is already guaranteed equal here.
    -- We therefore choose based on secondary quality.
    -- ========================================================

    local function resultScore(a, b)
        local combined =
            combineNodes(a, b)

        local score =
            nodeQuality(combined)

        -- Strongly reward simultaneous secondary upgrades.
        score =
            score +
            pairSynergy(
                virtualPick(a),
                virtualPick(b)
            )

        return score
    end


    -- ========================================================
    -- 4. Find best pair at one Fortune level
    -- ========================================================

    local function findBestPairAtLevel(nodes)
        if not nodes or #nodes < 2 then
            return nil, nil
        end

        local bestI = nil
        local bestJ = nil
        local bestScore = -math.huge

        for i = 1, #nodes - 1 do
            for j = i + 1, #nodes do
                local score =
                    resultScore(
                        nodes[i],
                        nodes[j]
                    )

                if score > bestScore then
                    bestScore = score
                    bestI = i
                    bestJ = j
                end
            end
        end

        return bestI, bestJ
    end


    -- ========================================================
    -- 5. Build ONLY enough nodes to create the target
    --
    -- ensureNode(L) means:
    --
    -- "Give me the best available Fortune-L node.
    --  If one doesn't exist, construct one from two L-1
    --  nodes."
    --
    -- Nodes are consumed as they're used, preventing the same
    -- physical pickaxe from appearing twice in the plan.
    -- ========================================================
    local function generateNode(targetLevel)
        if targetLevel <= 1 then
            return nil
        end

        local lowerLevel =
            targetLevel - 1

        available[lowerLevel] =
            available[lowerLevel] or {}

        -- Generate lower-level nodes until two exist.
        while #available[lowerLevel] < 2 do
            local generated =
                generateNode(lowerLevel)

            if not generated then
                return nil
            end

            table.insert(
                available[lowerLevel],
                generated
            )
        end

        local i, j =
            findBestPairAtLevel(
                available[lowerLevel]
            )

        if not i or not j then
            return nil
        end

        if i > j then
            i, j = j, i
        end

        local a =
            available[lowerLevel][i]

        local b =
            available[lowerLevel][j]

        -- Remove the higher index first so the lower index
        -- remains valid.
        table.remove(
            available[lowerLevel],
            j
        )

        table.remove(
            available[lowerLevel],
            i
        )

        return combineNodes(a, b)
    end

    local function ensureNode(targetLevel)
        available[targetLevel] =
            available[targetLevel] or {}

        -- Prefer the best existing pick/result at this level.
        if #available[targetLevel] > 0 then
            local bestIndex = 1
            local bestQuality =
                nodeQuality(
                    available[targetLevel][1]
                )

            for i = 2, #available[targetLevel] do
                local quality =
                    nodeQuality(
                        available[targetLevel][i]
                    )

                if quality > bestQuality then
                    bestQuality = quality
                    bestIndex = i
                end
            end

            return table.remove(
                available[targetLevel],
                bestIndex
            )
        end

        -- Otherwise manufacture one.
        return generateNode(targetLevel)
    end

    -- Build exactly one tree leading to the maximum reachable
    -- Fortune level. The target's steps therefore contain only
    -- combinations actually required for that target.
    local target = ensureNode(reachable)

    if not target then
        return nil
    end

    return {
        target = target,
        reachable = reachable,
        steps = target.steps
    }
end


-- ============================================================
-- NEXT PHYSICAL ACTION
-- ============================================================

-- Find the first step in the plan whose two inputs are
-- both real pickaxes currently present.

local function findNextAction(node)
    if not node or not node.steps then
        return nil
    end

    for _, step in ipairs(node.steps) do
        if step.a.pick and step.b.pick then
            return step
        end
    end

    return nil
end


-- ============================================================
-- DISPLAY
-- ============================================================

local function writeAt(x, y, text, color)
    if color then
        monitor.setTextColor(color)
    else
        monitor.setTextColor(colors.white)
    end

    monitor.setCursorPos(x, y)
    monitor.write(text)
end


local function clearMonitor()
    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
    monitor.clear()
end


local function line(y)
    local width = monitor.getSize()

    monitor.setTextColor(colors.gray)
    monitor.setCursorPos(1, y)
    monitor.write(string.rep("-", width))
end


local function shortEnchant(id)
    if id == "minecraft:fortune" then
        return "Fortune"
    elseif id == "minecraft:efficiency" then
        return "Efficiency"
    elseif id == "minecraft:unbreaking" then
        return "Unbreaking"
    end

    return id:match(":(.+)$") or id
end


local function drawPhysicalPick(x, y, label, node)
    local pick = node.pick

    writeAt(
        x,
        y,
        label .. ": " ..
        pick.location ..
        " / Slot " ..
        pick.slot,
        colors.yellow
    )

    local order = {
        "minecraft:fortune",
        "minecraft:efficiency",
        "minecraft:unbreaking"
    }

    local row = y + 1
    local shown = {}

    for _, id in ipairs(order) do
        local level = pick.enchants[id]

        if level then
            writeAt(
                x + 2,
                row,
                shortEnchant(id) .. " " .. level
            )

            shown[id] = true
            row = row + 1
        end
    end

    for id, level in pairs(pick.enchants) do
        if not shown[id] and row <= y + 4 then
            writeAt(
                x + 2,
                row,
                shortEnchant(id) .. " " .. level,
                colors.lightGray
            )

            row = row + 1
        end
    end
end


local function resultText(enchants)
    local parts = {}

    local fortune =
        enchants["minecraft:fortune"]

    local efficiency =
        enchants["minecraft:efficiency"]

    local unbreaking =
        enchants["minecraft:unbreaking"]

    if fortune then
        table.insert(parts, "Fortune " .. fortune)
    end

    if efficiency then
        table.insert(parts, "Efficiency " .. efficiency)
    end

    if unbreaking then
        table.insert(parts, "Unbreaking " .. unbreaking)
    end

    return table.concat(parts, "  ")
end


local function drawDashboard(
    inputCount,
    storageCounts,
    allPicks,
    stats,
    plan
)
    clearMonitor()

    local width, height = monitor.getSize()

    writeAt(2, 1, "ENCHANTMENT MANAGER", colors.yellow)
    writeAt(width - 10, 1, "ONLINE", colors.lime)

    line(2)

    -- Warehouse
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
        "TOTAL:      " .. #allPicks,
        colors.yellow
    )

    -- Fortune summary
    local right = math.floor(width / 2)

    writeAt(
        right,
        4,
        "FORTUNE PLAN",
        colors.cyan
    )

    writeAt(
        right,
        6,
        "Current highest: Fortune " ..
        stats.highest
    )

    if plan then
        writeAt(
            right,
            7,
            "Reachable:       Fortune " ..
            plan.reachable,
            colors.lime
        )

        writeAt(
            right,
            8,
            "Steps required:  " ..
            #plan.steps
        )
    else
        writeAt(
            right,
            7,
            "No Fortune plan available",
            colors.orange
        )
    end

    writeAt(
        right,
        10,
        "Fortune picks:"
    )

    local summary = ""
    for level = 1, stats.highest do
        local count = stats.counts[level]

        if count then
            summary =
                summary ..
                "F" .. level ..
                "=" .. count .. "  "
        end
    end

    writeAt(
        right,
        11,
        summary,
        colors.lightGray
    )

    line(14)

    -- Next action
    writeAt(
        2,
        16,
        "NEXT PLANNED COMBINATION",
        colors.cyan
    )

    if not plan then
        writeAt(
            2,
            18,
            "No usable Fortune donors.",
            colors.orange
        )
    else
        local nextAction =
            findNextAction(plan.target)

        if nextAction then
            drawPhysicalPick(
                2,
                18,
                "A",
                nextAction.a
            )

            drawPhysicalPick(
                right,
                18,
                "B",
                nextAction.b
            )

            local combined =
                combineNodes(
                    nextAction.a,
                    nextAction.b
                )

            writeAt(
                2,
                24,
                "NEXT RESULT",
                colors.cyan
            )

            writeAt(
                2,
                25,
                resultText(combined.enchants),
                colors.lime
            )
        else
            writeAt(
                2,
                18,
                "Target already exists.",
                colors.lime
            )
        end

        writeAt(
            2,
            28,
            "FINAL TARGET",
            colors.cyan
        )

        writeAt(
            2,
            29,
            resultText(plan.target.enchants),
            colors.yellow
        )
    end

    line(height - 2)

    writeAt(
        2,
        height - 1,
        "v0.6 - LOOK-AHEAD - READ ONLY",
        colors.gray
    )
end


-- ============================================================
-- MAIN
-- ============================================================

print("Enchantment Manager 0.6")
print("Scanning warehouse...")

local allPicks = {}

local inputPicks =
    scanInventory(INPUT, "Input")

addAll(allPicks, inputPicks)

local storageCounts = {}

for i, chest in ipairs(STORAGE) do
    local picks =
        scanInventory(
            chest,
            "Storage " .. i
        )

    storageCounts[i] = #picks
    addAll(allPicks, picks)
end

local stats = getFortuneStats(allPicks)

print("Building Fortune combination plan...")

local plan = buildPlan(allPicks)

drawDashboard(
    #inputPicks,
    storageCounts,
    allPicks,
    stats,
    plan
)

print("Found " .. #allPicks .. " pickaxes.")

if plan then
    print(
        "Current Fortune: " ..
        stats.highest
    )

    print(
        "Reachable Fortune: " ..
        plan.reachable
    )

    print(
        "Planned combinations: " ..
        #plan.steps
    )
end

print("Dashboard updated.")