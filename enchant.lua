-- CC Enchantment Manager 1.0
-- Look-ahead planner + persistent manual jobs + safe intake sorting + automated anvil
-- Commands: enchant | enchant sort | enchant dispatch | enchant auto

local INPUT = "minecraft:chest_0"

local STORAGE = {
    "minecraft:chest_1",
    "minecraft:chest_2",
    "minecraft:chest_3"
}

local OUTPUT = "minecraft:chest_4"
local REJECT = "minecraft:chest_5"
local MONITOR = "monitor_0"
local STATE_FILE = ".enchant_pending"
local ANVIL_TYPE = "anvil_interface"

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
                itemName = detail.name or item.name,
                nbt = detail.nbt or item.nbt,
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
-- PERSISTENT JOB STATE
-- ============================================================

local function savePendingJob(job)
    local handle = fs.open(STATE_FILE, "w")

    if not handle then
        return false, "Could not open " .. STATE_FILE .. " for writing."
    end

    handle.write(textutils.serialize(job))
    handle.close()

    return true
end


local function loadPendingJob()
    if not fs.exists(STATE_FILE) then
        return nil
    end

    local handle = fs.open(STATE_FILE, "r")

    if not handle then
        return nil, "Could not open " .. STATE_FILE .. " for reading."
    end

    local contents = handle.readAll()
    handle.close()

    local job = textutils.unserialize(contents)

    if type(job) ~= "table" then
        return nil, "Pending job file is invalid."
    end

    return job
end


local function clearPendingJob()
    if fs.exists(STATE_FILE) then
        fs.delete(STATE_FILE)
    end
end


local function copyEnchantments(enchants)
    local result = {}

    for id, level in pairs(enchants) do
        result[id] = level
    end

    return result
end


local function makePendingJob(action)
    local combined = combineNodes(action.a, action.b)

    return {
        version = 1,
        expected = copyEnchantments(combined.enchants),
        sourceA = {
            location = action.a.pick.location,
            enchants = copyEnchantments(action.a.pick.enchants)
        },
        sourceB = {
            location = action.b.pick.location,
            enchants = copyEnchantments(action.b.pick.enchants)
        }
    }
end


-- ============================================================
-- SAFE DISPATCH
-- ============================================================

local function outputIsEmpty()
    local output = peripheral.wrap(OUTPUT)

    if not output then
        return false, "Cannot find Output chest: " .. OUTPUT
    end

    if next(output.list()) ~= nil then
        return false, "Output chest is not empty."
    end

    return true
end


local function sameEnchantments(a, b)
    for id, level in pairs(a) do
        if b[id] ~= level then
            return false
        end
    end

    for id, level in pairs(b) do
        if a[id] ~= level then
            return false
        end
    end

    return true
end


local function findExpectedResult(picks, expected)
    for _, pick in ipairs(picks) do
        if sameEnchantments(pick.enchants, expected) then
            return pick
        end
    end

    return nil
end



local function verifyPhysicalPick(node)
    if not node or not node.pick then
        return false, "Planner node is not a physical pickaxe."
    end

    local pick = node.pick
    local inventory = peripheral.wrap(pick.chest)

    if not inventory then
        return false, "Cannot find source inventory: " .. pick.chest
    end

    local detail = inventory.getItemDetail(pick.slot)

    if not detail then
        return false, pick.location .. " / Slot " .. pick.slot .. " is now empty."
    end

    if detail.name ~= "minecraft:diamond_pickaxe" then
        return false, pick.location .. " / Slot " .. pick.slot .. " is no longer a diamond pickaxe."
    end

    local currentEnchants = getEnchantments(detail)

    if not sameEnchantments(currentEnchants, pick.enchants) then
        return false, pick.location .. " / Slot " .. pick.slot .. " enchantments changed."
    end

    -- When CC:Tweaked supplies an NBT fingerprint, require it to match too.
    if pick.nbt and detail.nbt and pick.nbt ~= detail.nbt then
        return false, pick.location .. " / Slot " .. pick.slot .. " NBT changed."
    end

    return true
end


local function dispatchPlan(plan)
    local existing, stateError = loadPendingJob()

    if stateError then
        return false, stateError
    end

    if existing then
        return false, "A dispatched anvil job is already pending."
    end

    if not plan then
        return false, "No Fortune plan is available."
    end

    local action = findNextAction(plan.target)

    if not action then
        return false, "Target already exists; there is nothing to dispatch."
    end

    local empty, reason = outputIsEmpty()

    if not empty then
        return false, reason
    end

    local okA, reasonA = verifyPhysicalPick(action.a)

    if not okA then
        return false, "Dispatch aborted: " .. reasonA
    end

    local okB, reasonB = verifyPhysicalPick(action.b)

    if not okB then
        return false, "Dispatch aborted: " .. reasonB
    end

    local a = action.a.pick
    local b = action.b.pick

    local invA = peripheral.wrap(a.chest)
    local invB = peripheral.wrap(b.chest)

    local movedA = invA.pushItems(OUTPUT, a.slot, 1)

    if movedA ~= 1 then
        return false, "Could not move pick A to Output."
    end

    -- Re-verify B after moving A. This is especially important if both
    -- picks originate in the same inventory.
    local okBAfter, reasonBAfter = verifyPhysicalPick(action.b)

    if not okBAfter then
        -- Best-effort rollback of A from Output to its original inventory.
        local output = peripheral.wrap(OUTPUT)
        output.pushItems(a.chest, 1, 1, a.slot)
        return false, "Dispatch aborted after moving A: " .. reasonBAfter
    end

    local movedB = invB.pushItems(OUTPUT, b.slot, 1)

    if movedB ~= 1 then
        -- Best-effort rollback of A. We deliberately stop rather than
        -- leaving a half-dispatched pair silently.
        local output = peripheral.wrap(OUTPUT)
        output.pushItems(a.chest, 1, 1, a.slot)
        return false, "Could not move pick B to Output; attempted rollback of A."
    end

    local job = makePendingJob(action)
    local saved, saveError = savePendingJob(job)

    if not saved then
        return false,
            "Pair dispatched, but WARNING: persistent job state could not be saved: "
            .. saveError
    end

    return true, "Dispatched recommended pair to Output chest; pending job saved."
end


-- ============================================================
-- AUTOMATED ANVIL (v1.0)
-- ============================================================

local function getAnvilPeripheral()
    local anvil = peripheral.find(ANVIL_TYPE)

    if not anvil then
        return nil, "Cannot find an automated anvil peripheral (" .. ANVIL_TYPE .. ")."
    end

    if type(anvil.inspectCombination) ~= "function" or type(anvil.combine) ~= "function" then
        return nil, "Anvil peripheral is missing inspectCombination/combine methods."
    end

    return anvil
end

-- The Java peripheral currently returns enchantments as an id -> level table.
-- Accept array-shaped entries too so Lua remains tolerant of future API changes.
local function normalizePeripheralEnchantments(raw)
    local result = {}

    if type(raw) ~= "table" then
        return result
    end

    for key, value in pairs(raw) do
        if type(key) == "string" and type(value) == "number" then
            result[key] = value
        elseif type(value) == "table" then
            local id = value.name or value.id
            local level = value.level
            if type(id) == "string" and type(level) == "number" then
                result[id] = level
            end
        end
    end

    return result
end

local function previewEnchantments(preview)
    if type(preview) ~= "table" or type(preview.result) ~= "table" then
        return {}
    end

    return normalizePeripheralEnchantments(preview.result.enchantments)
end

local function automatedCombine(plan)
    local pending, stateError = loadPendingJob()

    if stateError then
        return false, stateError
    end

    if pending then
        return false,
            "A manual anvil job is pending. Finish/validate it before using enchant auto."
    end

    if not plan then
        return false, "No Fortune plan is available."
    end

    local action = findNextAction(plan.target)

    if not action then
        return false, "Target already exists; there is nothing to automate."
    end

    local okA, reasonA = verifyPhysicalPick(action.a)
    if not okA then
        return false, "Auto aborted: " .. reasonA
    end

    local okB, reasonB = verifyPhysicalPick(action.b)
    if not okB then
        return false, "Auto aborted: " .. reasonB
    end

    local a = action.a.pick
    local b = action.b.pick
    local expectedNode = combineNodes(action.a, action.b)
    local expectedFortune = expectedNode.enchants["minecraft:fortune"] or 0

    local anvil, anvilError = getAnvilPeripheral()
    if not anvil then
        return false, anvilError
    end

    -- Preview uses Minecraft's real anvil path. It is authoritative for whether
    -- this exact pair can be combined on the installed modpack.
    local previewOK, preview = pcall(
        anvil.inspectCombination,
        a.chest, a.slot,
        b.chest, b.slot
    )

    if not previewOK then
        return false, "Auto preview failed: " .. tostring(preview)
    end

    if type(preview) ~= "table" then
        return false, "Auto preview returned an unexpected value."
    end

    if preview.valid ~= true then
        return false, "Real anvil rejected the planned pair; no items were changed."
    end

    local actualPreviewEnchants = previewEnchantments(preview)
    local previewFortune = actualPreviewEnchants["minecraft:fortune"] or 0

    -- The planner's simplified merge model is NOT allowed to overrule the real
    -- anvil. For Fortune progression, however, a mismatch means our plan is no
    -- longer describing reality, so stop safely before committing.
    if previewFortune ~= expectedFortune then
        return false,
            "Auto preview Fortune mismatch: planner expected F" .. expectedFortune ..
            " but the real anvil preview gives F" .. previewFortune .. ". No items changed."
    end

    -- Re-verify immediately before the mutating call. The Java peripheral also
    -- performs its own transactional checks, but this catches ordinary CC-side
    -- changes with a clearer message.
    okA, reasonA = verifyPhysicalPick(action.a)
    if not okA then
        return false, "Auto aborted after preview: " .. reasonA
    end

    okB, reasonB = verifyPhysicalPick(action.b)
    if not okB then
        return false, "Auto aborted after preview: " .. reasonB
    end

    local combineOK, result = pcall(
        anvil.combine,
        a.chest, a.slot,
        b.chest, b.slot
    )

    if not combineOK then
        return false, "Automated combine failed: " .. tostring(result)
    end

    if type(result) ~= "table" or result.combined ~= true then
        return false, "Automated combine did not report success: " .. textutils.serialize(result)
    end

    local destination = result.destination or {}
    local destinationInventory = destination.inventory or a.chest
    local destinationSlot = destination.slot or a.slot
    local inventory = peripheral.wrap(destinationInventory)

    if not inventory then
        return false,
            "Combine reported success, but destination inventory cannot be found: " ..
            tostring(destinationInventory)
    end

    local detail = inventory.getItemDetail(destinationSlot)

    if not detail or detail.name ~= "minecraft:diamond_pickaxe" then
        return false,
            "Combine reported success, but the result pickaxe was not found at " ..
            tostring(destinationInventory) .. " / Slot " .. tostring(destinationSlot)
    end

    local resultEnchants = getEnchantments(detail)
    local resultFortune = resultEnchants["minecraft:fortune"] or 0

    if resultFortune ~= expectedFortune then
        return false,
            "POST-COMBINE WARNING: result exists, but Fortune is F" .. resultFortune ..
            " instead of expected F" .. expectedFortune .. ". Stop automation and inspect it."
    end

    return true, {
        destinationInventory = destinationInventory,
        destinationSlot = destinationSlot,
        enchants = resultEnchants,
        levelCost = preview.levelCost,
        expectedFortune = expectedFortune
    }
end


-- ============================================================
-- INTAKE SORTER
-- ============================================================

local function firstStorageWithSpace()
    for _, chestName in ipairs(STORAGE) do
        local inventory = peripheral.wrap(chestName)

        if not inventory then
            return nil, "Cannot find storage inventory: " .. chestName
        end

        local size = inventory.size()
        local listed = inventory.list()
        local occupied = 0

        for _ in pairs(listed) do
            occupied = occupied + 1
        end

        if occupied < size then
            return chestName
        end
    end

    return nil
end


local function verifyInputPick(slot, expected)
    local inventory = peripheral.wrap(INPUT)

    if not inventory then
        return false, "Cannot find Input chest."
    end

    local detail = inventory.getItemDetail(slot)

    if not detail or detail.name ~= "minecraft:diamond_pickaxe" then
        return false, "Input / Slot " .. slot .. " changed before sorting."
    end

    if not sameEnchantments(getEnchantments(detail), expected.enchants) then
        return false, "Input / Slot " .. slot .. " enchantments changed before sorting."
    end

    if expected.nbt and detail.nbt and expected.nbt ~= detail.nbt then
        return false, "Input / Slot " .. slot .. " NBT changed before sorting."
    end

    return true
end


local function sortInput()
    local pending, stateError = loadPendingJob()

    if stateError then
        return false, stateError
    end

    if pending then
        return false,
            "Cannot sort while an anvil job is pending. Return and validate the result first."
    end

    local input = peripheral.wrap(INPUT)
    local reject = peripheral.wrap(REJECT)

    if not input then
        return false, "Cannot find Input chest: " .. INPUT
    end

    if not reject then
        return false, "Cannot find Reject chest: " .. REJECT
    end

    -- Snapshot only diamond pickaxes. Other items in Input are deliberately untouched.
    local picks = scanInventory(INPUT, "Input")
    table.sort(picks, function(a, b) return a.slot < b.slot end)

    local kept = 0
    local rejected = 0
    local leftInInput = 0

    for _, pick in ipairs(picks) do
        local verified, reason = verifyInputPick(pick.slot, pick)

        if not verified then
            return false, reason
        end

        local fortune = getLevel(pick, "minecraft:fortune")

        if fortune > 0 then
            local destination, storageError = firstStorageWithSpace()

            if storageError then
                return false, storageError
            end

            if not destination then
                -- Never destroy or reject a useful donor merely because storage is full.
                leftInInput = leftInInput + 1
            else
                local moved = input.pushItems(destination, pick.slot, 1)

                if moved ~= 1 then
                    return false,
                        "Failed moving useful pick from Input / Slot " .. pick.slot
                end

                kept = kept + 1
            end
        else
            local moved = input.pushItems(REJECT, pick.slot, 1)

            if moved ~= 1 then
                -- Reject may be full. Leave the pick safely in Input.
                leftInInput = leftInInput + 1
            else
                rejected = rejected + 1
            end
        end
    end

    return true, {
        stored = kept,
        rejected = rejected,
        remaining = leftInInput
    }
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
        "v1.0 - AUTOMATED ANVIL",
        colors.gray
    )
end


local function drawWaitingDashboard(job, inputCount, storageCounts, allPicks)
    clearMonitor()

    local width, height = monitor.getSize()

    writeAt(2, 1, "ENCHANTMENT MANAGER", colors.yellow)
    writeAt(width - 10, 1, "ONLINE", colors.lime)
    line(2)

    writeAt(2, 4, "ANVIL JOB", colors.cyan)
    writeAt(2, 6, "AWAITING ANVIL RESULT", colors.orange)

    writeAt(2, 8, "Expected:", colors.cyan)

    local row = 9
    local ordered = {
        "minecraft:fortune",
        "minecraft:efficiency",
        "minecraft:unbreaking"
    }
    local shown = {}

    for _, id in ipairs(ordered) do
        local level = job.expected[id]

        if level then
            writeAt(4, row, shortEnchant(id) .. " " .. level, colors.lime)
            shown[id] = true
            row = row + 1
        end
    end

    for id, level in pairs(job.expected) do
        if not shown[id] then
            writeAt(4, row, shortEnchant(id) .. " " .. level, colors.lightGray)
            row = row + 1
        end
    end

    writeAt(2, row + 1, "Combine the two picks in OUTPUT.", colors.white)
    writeAt(2, row + 2, "Return the result to INPUT.", colors.white)
    writeAt(2, row + 4, "The next 'enchant' will validate it.", colors.yellow)

    local right = math.floor(width / 2)
    writeAt(right, 4, "WAREHOUSE", colors.cyan)
    writeAt(right, 6, "Input: " .. inputCount)

    for i, count in ipairs(storageCounts) do
        writeAt(right, 6 + i, "Storage " .. i .. ": " .. count)
    end

    writeAt(right, 11, "TOTAL: " .. #allPicks, colors.yellow)

    line(height - 2)
    writeAt(2, height - 1, "v1.0 - PERSISTENT MANUAL JOB", colors.gray)
end


-- ============================================================
-- MAIN
-- ============================================================

local args = { ... }
local command = args[1] or "status"

if command ~= "status" and command ~= "dispatch" and command ~= "sort" and command ~= "auto" then
    print("Usage: enchant [sort|dispatch|auto]")
    print("  enchant          Scan/validate and update dashboard")
    print("  enchant sort     Sort Input: Fortune -> Storage, others -> Reject")
    print("  enchant dispatch Move the recommended pair to Output (manual fallback)")
    print("  enchant auto     Preview + combine ONE recommended pair automatically")
    return
end

print("Enchantment Manager 1.0")
print("Scanning warehouse...")

local function scanWarehouse()
    local all = {}
    local input = scanInventory(INPUT, "Input")
    addAll(all, input)

    local counts = {}

    for i, chest in ipairs(STORAGE) do
        local picks = scanInventory(chest, "Storage " .. i)
        counts[i] = #picks
        addAll(all, picks)
    end

    return all, input, counts
end

local allPicks, inputPicks, storageCounts = scanWarehouse()

-- Pending anvil results are ALWAYS handled before any sorting/planning action.
local pending, stateError = loadPendingJob()

if stateError then
    print("STATE ERROR: " .. stateError)
    return
end

if pending then
    local returned = findExpectedResult(inputPicks, pending.expected)

    if returned then
        print("Validated returned anvil result:")
        print("  " .. returned.location .. " / Slot " .. returned.slot)
        print("  " .. resultText(returned.enchants))
        clearPendingJob()
        print("Pending job completed and cleared.")
        pending = nil

        -- Keep the returned result in Input for this invocation. If the user
        -- requested 'sort', it can now safely be routed to Storage below.
    else
        print("A dispatched anvil job is still pending.")
        print("Expected: " .. resultText(pending.expected))
        print("Combine the Output pair and return the result to Input.")

        drawWaitingDashboard(
            pending,
            #inputPicks,
            storageCounts,
            allPicks
        )
        return
    end
end

if command == "sort" then
    print("Sorting Input...")

    local ok, result = sortInput()

    if not ok then
        print("SORT ABORTED: " .. result)
        return
    end

    print("Stored Fortune picks: " .. result.stored)
    print("Rejected non-Fortune picks: " .. result.rejected)
    print("Left safely in Input: " .. result.remaining)

    allPicks, inputPicks, storageCounts = scanWarehouse()
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

print("Found " .. #allPicks .. " managed pickaxes.")

if plan then
    print("Current Fortune: " .. stats.highest)
    print("Reachable Fortune: " .. plan.reachable)
    print("Planned combinations: " .. #plan.steps)
end

if command == "auto" then
    print("Automated anvil requested...")
    print("Safety mode: one combination per invocation.")

    local ok, result = automatedCombine(plan)

    if not ok then
        print("AUTO ABORTED: " .. tostring(result))
        return
    end

    print("Automated combination complete.")
    print("  Result: " .. tostring(result.destinationInventory) ..
          " / Slot " .. tostring(result.destinationSlot))
    print("  " .. resultText(result.enchants))

    if result.levelCost ~= nil then
        print("  Vanilla level cost (informational): " .. tostring(result.levelCost))
    end

    -- Reality is authoritative: throw away the old hypothetical plan, rescan
    -- every managed inventory, and build the next plan from the actual result.
    allPicks, inputPicks, storageCounts = scanWarehouse()
    stats = getFortuneStats(allPicks)
    plan = buildPlan(allPicks)

    drawDashboard(
        #inputPicks,
        storageCounts,
        allPicks,
        stats,
        plan
    )

    if plan and findNextAction(plan.target) then
        print("Next combination is ready. Run 'enchant auto' again after checking the dashboard.")
    else
        print("No further combination is currently required for the reachable target.")
    end

elseif command == "dispatch" then
    print("Dispatch requested...")

    local ok, message = dispatchPlan(plan)
    print(message)

    if ok then
        local job = loadPendingJob()

        allPicks, inputPicks, storageCounts = scanWarehouse()

        if job then
            drawWaitingDashboard(
                job,
                #inputPicks,
                storageCounts,
                allPicks
            )
        end

        print("Combine the two Output pickaxes in the anvil.")
        print("Put the resulting pickaxe back into Input.")
        print("Then run 'enchant' to validate the result.")
    end
elseif command == "sort" then
    print("Sort complete. Dashboard updated.")
else
    print("Dashboard updated.")
    print("Run 'enchant sort' to process new Input picks.")

    if plan and findNextAction(plan.target) then
        print("Run 'enchant auto' to safely automate ONE recommended combination.")
        print("Or run 'enchant dispatch' for the manual Output-chest fallback.")
    end
end