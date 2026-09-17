-- CC Enchantment Manager 1.2.5
-- Look-ahead planner + persistent manual jobs + safe intake sorting + automated anvil
-- Commands: enchant | enchant sort | enchant dispatch | enchant auto | enchant run

local INPUT = "minecraft:chest_0"

local STORAGE = {
    "minecraft:chest_1",
    "minecraft:chest_2",
    "minecraft:chest_3"
}

local OUTPUT = "minecraft:chest_4"
local REJECT_STORAGE = {
    "minecraft:chest_5",
    "minecraft:chest_8"
}

local DONOR_STORAGE = {
    "minecraft:chest_9",
    "minecraft:chest_10",
    "minecraft:chest_11"
}
local STAGING = "minecraft:chest_7"
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


local function isSiftingEnchantment(id)
    -- Different mods/API layers may expose Sifting under different namespaces.
    -- Treat any enchantment whose path is exactly "sifting" as the incompatible
    -- enchant, while avoiding accidental matches such as "advanced_sifting".
    return type(id) == "string" and (id == "sifting" or id:match(":sifting$") ~= nil)
end

local function firstSiftingId(enchants)
    for id in pairs(enchants or {}) do
        if isSiftingEnchantment(id) then
            return id
        end
    end
    return nil
end

local function applyMiningIncompatibilityPolicy(enchants, baseEnchants, donorEnchants)
    -- v1.2.5 production model for the mutually-exclusive mining enchants.
    --
    -- 1. Fortune is the production objective and ALWAYS dominates both Silk Touch
    --    and Sifting. automatedCombine() also puts the Fortune pick in the left/base
    --    anvil slot whenever only one input has Fortune.
    -- 2. With no Fortune present, Silk Touch and Sifting conflict with each other.
    --    Minecraft's anvil keeps the incompatible enchant already present on the
    --    left/base item and refuses the conflicting donor enchant. Model that exact
    --    orientation instead of pretending both survive.
    if (enchants["minecraft:fortune"] or 0) > 0 then
        enchants["minecraft:silk_touch"] = nil
        for id in pairs(enchants) do
            if isSiftingEnchantment(id) then
                enchants[id] = nil
            end
        end
        return enchants
    end

    local baseSilk = (baseEnchants["minecraft:silk_touch"] or 0) > 0
    local donorSilk = (donorEnchants["minecraft:silk_touch"] or 0) > 0
    local baseSifting = firstSiftingId(baseEnchants)
    local donorSifting = firstSiftingId(donorEnchants)

    if baseSifting and donorSilk then
        -- Observed live-server case: base Sifting survives; donor Silk Touch is lost.
        enchants["minecraft:silk_touch"] = nil
    elseif baseSilk and donorSifting then
        -- Symmetric anvil rule: base Silk Touch survives; donor Sifting is refused.
        for id in pairs(enchants) do
            if isSiftingEnchantment(id) then
                enchants[id] = nil
            end
        end
    end

    return enchants
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

    return applyMiningIncompatibilityPolicy(result, a.enchants, b.enchants)
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
            and enchantment ~= "minecraft:silk_touch"
            and not isSiftingEnchantment(enchantment)
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
-- SECONDARY PROGRESSION PLANNER (v1.2.5)
-- ============================================================

-- Fortune is always the first priority. Secondary mode is used only when the
-- maximum reachable Fortune already physically exists and has no Fortune step.
-- Priority within secondary mode is Efficiency, then Unbreaking. Reach and
-- other useful enchants are preserved/tie-broken by secondaryQuality().

local function secondaryVector(enchants)
    return {
        efficiency = enchants["minecraft:efficiency"] or 0,
        unbreaking = enchants["minecraft:unbreaking"] or 0
    }
end

local function vectorBetter(a, b)
    if a.efficiency ~= b.efficiency then
        return a.efficiency > b.efficiency
    end
    return a.unbreaking > b.unbreaking
end

local function bestPhysicalFortuneTarget(allPicks, fortuneLevel)
    local best, bestVector, bestQuality = nil, nil, -math.huge

    for _, pick in ipairs(allPicks) do
        if getLevel(pick, "minecraft:fortune") == fortuneLevel then
            local v = secondaryVector(pick.enchants)
            local q = secondaryQuality(pick)
            if not best or vectorBetter(v, bestVector)
                or (not vectorBetter(bestVector, v) and q > bestQuality) then
                best, bestVector, bestQuality = pick, v, q
            end
        end
    end
    return best
end

local function donorCanImprove(targetEnchants, donorEnchants)
    local combined = combineEnchantments(
        { enchants = targetEnchants },
        { enchants = donorEnchants }
    )
    return vectorBetter(secondaryVector(combined), secondaryVector(targetEnchants)), combined
end

local function donorScore(node)
    local v = secondaryVector(node.enchants)
    return v.efficiency * 1000000 + v.unbreaking * 10000 + nodeQuality(node)
end

local function buildSecondaryPlan(allPicks, targetPick)
    local pool = {}

    -- Only Fortune-0 utility stock is expendable in secondary mode. Lower
    -- Fortune picks remain reserved for future Fortune progression.
    for _, pick in ipairs(allPicks) do
        if pick.id ~= targetPick.id and getLevel(pick, "minecraft:fortune") == 0 then
            if getLevel(pick, "minecraft:efficiency") > 0
                or getLevel(pick, "minecraft:unbreaking") > 0 then
                table.insert(pool, physicalNode(pick))
            end
        end
    end

    if #pool == 0 then return nil end

    -- Repeatedly look for a donor which directly improves the target. If none
    -- exists, manufacture better donors from productive equal-level pairings.
    for _ = 1, 12 do
        local bestDonor, bestProjected, bestScore = nil, nil, -math.huge

        for _, node in ipairs(pool) do
            local improves, projected = donorCanImprove(targetPick.enchants, node.enchants)
            if improves then
                local v = secondaryVector(projected)
                local score = v.efficiency * 100000000
                    + v.unbreaking * 1000000 + donorScore(node)
                if score > bestScore then
                    bestDonor, bestProjected, bestScore = node, projected, score
                end
            end
        end

        if bestDonor then
            local targetNode = physicalNode(targetPick)
            local finalNode = combineNodes(targetNode, bestDonor)
            local steps = {}
            addAll(steps, bestDonor.steps)
            table.insert(steps, {
                a = targetNode,
                b = bestDonor,
                resultFortune = getLevel(targetPick, "minecraft:fortune"),
                secondary = true
            })
            finalNode.steps = steps
            return {
                mode = "secondary",
                target = finalNode,
                reachable = getLevel(targetPick, "minecraft:fortune"),
                steps = steps,
                baseTarget = targetPick,
                projected = bestProjected
            }
        end

        if #pool < 2 then break end

        local candidates = {}
        for i = 1, #pool - 1 do
            for j = i + 1, #pool do
                local combined = combineNodes(pool[i], pool[j])
                local vc = secondaryVector(combined.enchants)
                local va = secondaryVector(pool[i].enchants)
                local vb = secondaryVector(pool[j].enchants)

                -- Only spend donors if the pair creates a strictly better
                -- Efficiency/Unbreaking donor than at least one input.
                if vectorBetter(vc, va) or vectorBetter(vc, vb) then
                    table.insert(candidates, {
                        i = i, j = j, node = combined,
                        score = donorScore(combined)
                            + pairSynergy(virtualPick(pool[i]), virtualPick(pool[j]))
                    })
                end
            end
        end

        if #candidates == 0 then break end
        table.sort(candidates, function(a, b) return a.score > b.score end)

        local used, nextPool = {}, {}
        for _, c in ipairs(candidates) do
            if not used[c.i] and not used[c.j] then
                used[c.i], used[c.j] = true, true
                table.insert(nextPool, c.node)
            end
        end
        for i, node in ipairs(pool) do
            if not used[i] then table.insert(nextPool, node) end
        end
        pool = nextPool
    end

    return nil
end

local function buildManagedPlan(allPicks)
    local fortunePlan = buildPlan(allPicks)
    if not fortunePlan then return nil end
    fortunePlan.mode = "fortune"

    -- Never sacrifice Fortune progress for a secondary upgrade.
    if findNextAction(fortunePlan.target) then return fortunePlan end

    local targetPick = bestPhysicalFortuneTarget(allPicks, fortunePlan.reachable)
    if not targetPick then return fortunePlan end

    local secondaryPlan = buildSecondaryPlan(allPicks, targetPick)
    if secondaryPlan then return secondaryPlan end
    return fortunePlan
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
-- AUTOMATED ANVIL (v1.1.0 - dedicated staging chest + closed-loop runner)
-- ============================================================

local firstStorageWithSpace
local scanWarehouse

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

-- v1.2.5: deterministic diagnostics + mining-enchantment incompatibility policy.
-- The preview remains authoritative and a mismatch is still a hard safety stop.
local function sortedEnchantIds(...)
    local seen = {}

    for i = 1, select("#", ...) do
        local enchants = select(i, ...)
        if type(enchants) == "table" then
            for id in pairs(enchants) do
                seen[id] = true
            end
        end
    end

    local ids = {}
    for id in pairs(seen) do
        table.insert(ids, id)
    end
    table.sort(ids)
    return ids
end

local function enchantLabel(id)
    if id == "minecraft:fortune" then return "Fortune" end
    if id == "minecraft:efficiency" then return "Efficiency" end
    if id == "minecraft:unbreaking" then return "Unbreaking" end
    return id
end

local function printEnchantSet(title, enchants)
    print(title)

    local ids = sortedEnchantIds(enchants)
    if #ids == 0 then
        print("  (none)")
        return
    end

    for _, id in ipairs(ids) do
        print("  " .. enchantLabel(id) .. " = " .. tostring(enchants[id]))
    end
end

local function printPreviewMismatch(expected, actual)
    print("PREVIEW MISMATCH")
    printEnchantSet("Planner expected:", expected)
    printEnchantSet("Real anvil preview:", actual)
    print("Differences:")

    local differences = 0
    for _, id in ipairs(sortedEnchantIds(expected, actual)) do
        local expectedLevel = expected[id]
        local actualLevel = actual[id]

        if expectedLevel ~= actualLevel then
            differences = differences + 1
            print(
                "  " .. enchantLabel(id) ..
                ": expected " .. tostring(expectedLevel or "(absent)") ..
                ", real " .. tostring(actualLevel or "(absent)")
            )
        end
    end

    if differences == 0 then
        print("  (none detected after normalization)")
    end
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

    -- v1.2.5: when only one input carries Fortune, it MUST be the left/base
    -- anvil input. This makes the real anvil resolve incompatible donor enchants
    -- (notably Sifting and Silk Touch) in favour of Fortune.
    local fortuneA = getLevel(action.a.pick, "minecraft:fortune")
    local fortuneB = getLevel(action.b.pick, "minecraft:fortune")
    if fortuneA == 0 and fortuneB > 0 then
        action.a, action.b = action.b, action.a
    end

    local a = action.a.pick
    local b = action.b.pick
    local expectedNode = combineNodes(action.a, action.b)
    local expectedFortune = expectedNode.enchants["minecraft:fortune"] or 0

    local anvil, anvilError = getAnvilPeripheral()
    if not anvil then
        return false, anvilError
    end

    -- Automated operations use a dedicated ordinary SINGLE vanilla chest.
    -- OUTPUT remains the user's double chest and is reserved for manual dispatch.
    local invA = peripheral.wrap(a.chest)
    local invB = peripheral.wrap(b.chest)
    local staging = peripheral.wrap(STAGING)

    if not invA or not invB or not staging then
        return false, "Auto staging failed because a required inventory disappeared."
    end

    if next(staging.list()) ~= nil then
        return false,
            "Auto staging chest is not empty (" .. STAGING ..
            "). Empty it before running enchant auto."
    end

    local movedA = invA.pushItems(STAGING, a.slot, 1, 1)
    if movedA ~= 1 then
        return false, "Auto staging could not move pick A to staging slot 1."
    end

    -- If A and B came from the same chest, moving A may alter nothing about
    -- B's numbered slot in a chest, but re-check it anyway before moving it.
    local okBAfter, reasonBAfter = verifyPhysicalPick(action.b)
    if not okBAfter then
        staging.pushItems(a.chest, 1, 1, a.slot)
        return false, "Auto staging aborted after moving A: " .. reasonBAfter
    end

    local movedB = invB.pushItems(STAGING, b.slot, 1, 2)
    if movedB ~= 1 then
        staging.pushItems(a.chest, 1, 1, a.slot)
        return false, "Auto staging could not move pick B to staging slot 2; attempted rollback of A."
    end

    local function rollbackStagedPair()
        -- Best effort only. Use original slots when possible.
        local staged = peripheral.wrap(STAGING)
        if not staged then return end
        staged.pushItems(a.chest, 1, 1, a.slot)
        staged.pushItems(b.chest, 2, 1, b.slot)
    end

    -- Preview the isolated staging chest. This uses Minecraft's real anvil path
    -- and is authoritative for this exact pair on the installed modpack.
    local previewOK, preview = pcall(
        anvil.inspectCombination,
        STAGING, 1,
        STAGING, 2
    )

    if not previewOK then
        rollbackStagedPair()
        return false, "Auto preview failed after staging; rollback attempted: " .. tostring(preview)
    end

    if type(preview) ~= "table" then
        rollbackStagedPair()
        return false, "Auto preview returned an unexpected value; rollback attempted."
    end

    if preview.valid ~= true then
        rollbackStagedPair()
        return false, "Real anvil rejected the staged pair; rollback attempted."
    end

    local actualPreviewEnchants = previewEnchantments(preview)
    local previewFortune = actualPreviewEnchants["minecraft:fortune"] or 0

    -- Hard production invariant: a Fortune result may never retain Sifting or
    -- Silk Touch. If the real anvil ever disagrees, stop rather than weakening
    -- the safety check or committing an unexpected combination.
    if previewFortune > 0 then
        local incompatible = actualPreviewEnchants["minecraft:silk_touch"] ~= nil
        local incompatibleName = incompatible and "minecraft:silk_touch" or nil
        if not incompatible then
            for id in pairs(actualPreviewEnchants) do
                if isSiftingEnchantment(id) then
                    incompatible = true
                    incompatibleName = id
                    break
                end
            end
        end
        if incompatible then
            rollbackStagedPair()
            return false,
                "Fortune-dominance safety stop: real anvil preview retained incompatible " ..
                tostring(incompatibleName) .. ". No combination was committed; staged picks were rolled back."
        end
    end

    if previewFortune ~= expectedFortune then
        rollbackStagedPair()
        return false,
            "Auto preview Fortune mismatch: planner expected F" .. expectedFortune ..
            " but the real anvil preview gives F" .. previewFortune ..
            ". Staged picks were rolled back where possible."
    end

    -- v1.2 depends on secondary enchantments too. The Minecraft-backed preview
    -- is authoritative, so require the entire predicted enchantment set to match.
    if not sameEnchantments(actualPreviewEnchants, expectedNode.enchants) then
        -- Print the exact disagreement before rollback so the operator can see
        -- which planner assumption differs from Minecraft's real anvil result.
        printPreviewMismatch(expectedNode.enchants, actualPreviewEnchants)
        rollbackStagedPair()
        return false,
            "Auto preview enchantment mismatch. No combination was committed; " ..
            "staged picks were rolled back where possible. See diagnostics above."
    end

    -- Confirm the staging slots still contain exactly the picks we intended.
    local stagedA = staging.getItemDetail(1)
    local stagedB = staging.getItemDetail(2)
    if not stagedA or not stagedB
        or stagedA.name ~= "minecraft:diamond_pickaxe"
        or stagedB.name ~= "minecraft:diamond_pickaxe"
        or not sameEnchantments(getEnchantments(stagedA), a.enchants)
        or not sameEnchantments(getEnchantments(stagedB), b.enchants) then
        rollbackStagedPair()
        return false, "Staged picks changed after preview; rollback attempted."
    end

    local combineOK, result = pcall(
        anvil.combine,
        STAGING, 1,
        STAGING, 2
    )

    if not combineOK then
        -- The Java peripheral is transactional for ordinary failures, but do
        -- not assume anything after an exception: leave Output untouched for
        -- manual inspection rather than moving potentially changed items.
        return false,
            "Automated combine raised an error. STOP and inspect staging slots 1/2: " ..
            tostring(result)
    end

    if type(result) ~= "table" or result.combined ~= true then
        return false,
            "Automated combine did not report success. STOP and inspect staging: " ..
            textutils.serialize(result)
    end

    local destination = result.destination or {}
    local destinationInventory = destination.inventory or STAGING
    local destinationSlot = destination.slot or 1
    local resultInventory = peripheral.wrap(destinationInventory)

    if not resultInventory then
        return false,
            "Combine reported success, but destination inventory cannot be found: " ..
            tostring(destinationInventory)
    end

    local detail = resultInventory.getItemDetail(destinationSlot)

    if not detail or detail.name ~= "minecraft:diamond_pickaxe" then
        return false,
            "Combine reported success, but the result pickaxe was not found at " ..
            tostring(destinationInventory) .. " / Slot " .. tostring(destinationSlot)
    end

    local resultEnchants = getEnchantments(detail)
    local resultFortune = resultEnchants["minecraft:fortune"] or 0

    if resultFortune ~= expectedFortune then
        return false,
            "POST-COMBINE WARNING: result exists in staging, but Fortune is F" ..
            resultFortune .. " instead of expected F" .. expectedFortune ..
            ". Stop automation and inspect it."
    end

    if not sameEnchantments(resultEnchants, expectedNode.enchants) then
        return false,
            "POST-COMBINE WARNING: result enchantments differ from the validated " ..
            "planner result. Leave it in staging and inspect it."
    end

    -- Only after the actual result has been validated do we return it to the
    -- managed storage pool. The next invocation/rescan replans from reality.
    local storageName, storageError = firstStorageWithSpace()
    if storageError then
        return false,
            "Combination succeeded and result is safe in staging, but storage lookup failed: " ..
            storageError
    end

    if not storageName then
        return false,
            "Combination succeeded and result is safe in staging, but all Storage chests are full."
    end

    local movedResult = resultInventory.pushItems(storageName, destinationSlot, 1)
    if movedResult ~= 1 then
        return false,
            "Combination succeeded and result is safe in staging, but it could not be returned to Storage."
    end

    return true, {
        destinationInventory = storageName,
        destinationSlot = nil,
        enchants = resultEnchants,
        levelCost = preview.levelCost,
        expectedFortune = expectedFortune
    }
end

-- ============================================================
-- CLOSED-LOOP RUNNER (v1.1.0)
-- ============================================================

-- Conservative guard against a planner/peripheral fault causing an unexpectedly
-- long unattended run. A legitimate larger batch can raise this later.
local MAX_RUN_COMBINATIONS = 64

-- Forward declaration: runClosedLoop is defined before the display section.
local drawDashboard
local resultText

local function runClosedLoop(initialAllPicks, initialInputPicks, initialStorageCounts)
    local allPicks = initialAllPicks
    local inputPicks = initialInputPicks
    local storageCounts = initialStorageCounts

    local startStats = getFortuneStats(allPicks)
    local startFortune = startStats.highest
    local completed = 0

    while true do
        -- Reality is authoritative on every iteration.
        local stats = getFortuneStats(allPicks)
        local plan = buildManagedPlan(allPicks)
        local action = plan and findNextAction(plan.target) or nil

        drawDashboard(
            #inputPicks,
            storageCounts,
            allPicks,
            stats,
            plan
        )

        if not plan then
            return true, {
                completed = completed,
                startFortune = startFortune,
                finalFortune = stats.highest,
                reason = "No Fortune plan is available."
            }
        end

        if not action then
            return true, {
                completed = completed,
                startFortune = startFortune,
                finalFortune = stats.highest,
                reason = "Reachable target exists; no further combination is required."
            }
        end

        if completed >= MAX_RUN_COMBINATIONS then
            return false,
                "RUN SAFETY STOP: reached the maximum of " ..
                MAX_RUN_COMBINATIONS ..
                " combinations. No additional combination was attempted."
        end

        local fortuneA = getLevel(action.a.pick, "minecraft:fortune")
        local fortuneB = getLevel(action.b.pick, "minecraft:fortune")
        local expected = combineNodes(action.a, action.b)
        local expectedFortune = expected.enchants["minecraft:fortune"] or 0

        print(
            "RUN step " .. (completed + 1) .. ": F" ..
            fortuneA .. " + F" .. fortuneB ..
            " -> expected F" .. expectedFortune
        )

        -- Reuse the already real-server-tested v1.0.2 transaction. It verifies
        -- physical inputs, stages them, asks the real anvil for a preview,
        -- checks planner-vs-preview Fortune, combines, verifies the result, and
        -- only then returns the result to managed Storage.
        local ok, result = automatedCombine(plan)

        if not ok then
            return false,
                "RUN STOPPED after " .. completed ..
                " successful combination(s): " .. tostring(result)
        end

        completed = completed + 1

        print(
            "  Completed: " .. resultText(result.enchants) ..
            " -> " .. tostring(result.destinationInventory)
        )

        if result.levelCost ~= nil then
            print(
                "  Vanilla level cost (informational): " ..
                tostring(result.levelCost)
            )
        end

        -- Critical closed-loop rule: discard every old slot/plan assumption.
        allPicks, inputPicks, storageCounts = scanWarehouse()

        local afterStats = getFortuneStats(allPicks)
        print(
            "  Rescan: highest F" .. afterStats.highest ..
            ", managed picks " .. #allPicks
        )
    end
end

-- ============================================================
-- INTAKE SORTER
-- ============================================================

local function firstPoolWithSpace(pool, label)
    for _, chestName in ipairs(pool) do
        local inventory = peripheral.wrap(chestName)
        if not inventory then return nil, "Cannot find " .. label .. ": " .. chestName end
        local occupied = 0
        for _ in pairs(inventory.list()) do occupied = occupied + 1 end
        if occupied < inventory.size() then return chestName end
    end
    return nil
end

firstStorageWithSpace = function()
    return firstPoolWithSpace(STORAGE, "Fortune storage")
end

local function firstDonorStorageWithSpace()
    return firstPoolWithSpace(DONOR_STORAGE, "donor storage")
end

local function firstRejectStorageWithSpace()
    return firstPoolWithSpace(REJECT_STORAGE, "reject storage")
end

local function isUsefulDonor(pick)
    return getLevel(pick, "minecraft:efficiency") > 0
        or getLevel(pick, "minecraft:unbreaking") > 0
        or getLevel(pick, "enchantment.ie.reach") > 0
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
    if stateError then return false, stateError end
    if pending then
        return false, "Cannot sort while an anvil job is pending. Return and validate the result first."
    end

    local input = peripheral.wrap(INPUT)
    if not input then return false, "Cannot find Input chest: " .. INPUT end

    -- Fail before moving anything if a configured destination chest is offline.
    for _, pool in ipairs({ STORAGE, DONOR_STORAGE, REJECT_STORAGE }) do
        for _, chestName in ipairs(pool) do
            if not peripheral.wrap(chestName) then
                return false, "Cannot find configured sorter inventory: " .. chestName
            end
        end
    end

    local picks = scanInventory(INPUT, "Input")
    table.sort(picks, function(x, y) return x.slot < y.slot end)

    local fortuneStored, donorsStored, rejected, remaining = 0, 0, 0, 0

    for _, pick in ipairs(picks) do
        local verified, reason = verifyInputPick(pick.slot, pick)
        if not verified then return false, reason end

        local destination, storageError, category
        if getLevel(pick, "minecraft:fortune") > 0 then
            destination, storageError = firstStorageWithSpace()
            category = "fortune"
        elseif isUsefulDonor(pick) then
            destination, storageError = firstDonorStorageWithSpace()
            category = "donor"
        else
            destination, storageError = firstRejectStorageWithSpace()
            category = "reject"
        end

        if storageError then return false, storageError end

        if not destination then
            -- Never spill a pick into the wrong category just because its pool is full.
            remaining = remaining + 1
        else
            local moved = input.pushItems(destination, pick.slot, 1)
            if moved ~= 1 then
                return false, "Failed moving " .. category .. " pick from Input / Slot " .. pick.slot
            end
            if category == "fortune" then fortuneStored = fortuneStored + 1
            elseif category == "donor" then donorsStored = donorsStored + 1
            else rejected = rejected + 1 end
        end
    end

    return true, {
        stored = fortuneStored,
        donors = donorsStored,
        rejected = rejected,
        remaining = remaining
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


resultText = function(enchants)
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


drawDashboard = function(
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

        if plan.mode == "secondary" then
            writeAt(right, 9, "Mode: SECONDARY - Efficiency > Unbreaking", colors.orange)
        end
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
        "v1.2.5 - MINING CONFLICT MODEL",
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

if command ~= "status" and command ~= "dispatch" and command ~= "sort" and command ~= "auto" and command ~= "run" then
    print("Usage: enchant [sort|dispatch|auto|run]")
    print("  enchant          Scan/validate and update dashboard")
    print("  enchant sort     Sort Input: Fortune -> Storage, useful donors -> Donor, others -> Reject")
    print("  enchant dispatch Move the recommended pair to Output (manual fallback)")
    print("  enchant auto     Preview + combine ONE recommended pair automatically")
    print("  enchant run      Closed loop: combine safely until target/no next action")
    return
end

print("Enchantment Manager 1.2.5")
print("Scanning warehouse...")

scanWarehouse = function()
    local all = {}
    local input = scanInventory(INPUT, "Input")
    addAll(all, input)

    local counts = {}

    for i, chest in ipairs(STORAGE) do
        local picks = scanInventory(chest, "Storage " .. i)
        counts[i] = #picks
        addAll(all, picks)
    end

    -- Keep utility donors in the managed scan now, ready for the v1.2 planner.
    -- The current Fortune planner naturally ignores donors with Fortune 0.
    for i, chest in ipairs(DONOR_STORAGE) do
        local picks = scanInventory(chest, "Donor " .. i)
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
    print("Stored utility donors: " .. result.donors)
    print("Rejected unusable picks: " .. result.rejected)
    print("Left safely in Input: " .. result.remaining)

    allPicks, inputPicks, storageCounts = scanWarehouse()
end

local stats = getFortuneStats(allPicks)

print("Building Fortune-first managed plan...")

local plan = buildManagedPlan(allPicks)

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
    print("Planner mode: " .. (plan.mode == "secondary" and "SECONDARY" or "FORTUNE"))
end

if command == "run" then
    print("Closed-loop automation requested...")
    print("Safety policy: rescan + replan after EVERY successful combination.")
    print("Hard cap: " .. MAX_RUN_COMBINATIONS .. " combinations this invocation.")

    local ok, result = runClosedLoop(allPicks, inputPicks, storageCounts)

    if not ok then
        print(tostring(result))

        -- Do not attempt clever recovery. Refresh the managed-inventory view
        -- and leave any deliberately stranded staging item for inspection.
        allPicks, inputPicks, storageCounts = scanWarehouse()
        stats = getFortuneStats(allPicks)
        plan = buildManagedPlan(allPicks)

        drawDashboard(
            #inputPicks,
            storageCounts,
            allPicks,
            stats,
            plan
        )
        return
    end

    print("Closed-loop run complete.")
    print("  Combinations completed: " .. result.completed)
    print("  Starting Fortune: " .. result.startFortune)
    print("  Final Fortune: " .. result.finalFortune)
    print("  Stop reason: " .. result.reason)

    allPicks, inputPicks, storageCounts = scanWarehouse()
    stats = getFortuneStats(allPicks)
    plan = buildManagedPlan(allPicks)

    drawDashboard(
        #inputPicks,
        storageCounts,
        allPicks,
        stats,
        plan
    )

elseif command == "auto" then
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
    plan = buildManagedPlan(allPicks)

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
        print("Run 'enchant run' for closed-loop automation with rescan/replan each step.")
        print("Or run 'enchant dispatch' for the manual Output-chest fallback.")
    end
end