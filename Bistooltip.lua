local eventFrame = CreateFrame("Frame", nil, UIParent)
Bistooltip_phases_string = ""


-- ============================================================
--  UX helpers: class colors, spec detection, rank parsing
-- ============================================================

local FALLBACK_CLASS_HEX = {
  DEATHKNIGHT = "ffc41f3b",
  DRUID      = "ffff7d0a",
  HUNTER     = "ffabd473",
  MAGE       = "ff69ccf0",
  PALADIN    = "fff58cba",
  PRIEST     = "ffffffff",
  ROGUE      = "fffff569",
  SHAMAN     = "ff0070de",
  WARLOCK    = "ff9482c9",
  WARRIOR    = "ffc79c6e",
}

local CLASSFILE_TO_DATASET = {
  DEATHKNIGHT = "Death knight",
  DRUID      = "Druid",
  HUNTER     = "Hunter",
  MAGE       = "Mage",
  PALADIN    = "Paladin",
  PRIEST     = "Priest",
  ROGUE      = "Rogue",
  SHAMAN     = "Shaman",
  WARLOCK    = "Warlock",
  WARRIOR    = "Warrior",
}

-- reverse map for coloring (dataset name -> class file token)
local DATASET_TO_CLASSFILE = {}
for file, ds in pairs(CLASSFILE_TO_DATASET) do
  DATASET_TO_CLASSFILE[ds] = file
end

local SPEC_BY_CLASSFILE_TAB = {
  DEATHKNIGHT = { [1] = "Blood tank", [2] = "Frost", [3] = "Unholy" }, -- some lists also use "Blood dps"
  DRUID       = { [1] = "Balance", [2] = "Feral tank", [3] = "Restoration" }, -- cat/bear ambiguity handled below
  HUNTER      = { [1] = "Beast mastery", [2] = "Marksmanship", [3] = "Survival" },
  MAGE        = { [1] = "Arcane", [2] = "Fire", [3] = "Frost" },
  PALADIN     = { [1] = "Holy", [2] = "Protection", [3] = "Retribution" },
  PRIEST      = { [1] = "Discipline", [2] = "Holy", [3] = "Shadow" },
  ROGUE       = { [1] = "Assassination", [2] = "Combat", [3] = "Subtlety" },
  SHAMAN      = { [1] = "Elemental", [2] = "Enhancement", [3] = "Restoration" },
  WARLOCK     = { [1] = "Affliction", [2] = "Demonology", [3] = "Destruction" },
  WARRIOR     = { [1] = "Arms", [2] = "Fury", [3] = "Protection" },
}

local function NormalizeClassFileToken(classNameOrToken)
  if not classNameOrToken then return nil end
  local t = tostring(classNameOrToken)
  local up = string.upper(t):gsub("%s+", "")
  if up == "DEATHKNIGHT" or up == "DEATH_KNIGHT" or up == "DEATHKNIGHTS" or up == "DEATHKNIGHTCLASS" or up == "DEATHKNIGHT" then
    return "DEATHKNIGHT"
  end
  -- if already a class file token
  if FALLBACK_CLASS_HEX[up] then return up end
  -- localized names -> token via UnitClass lookups (cheap fallback)
  local _, file = UnitClass("player")
  if file and t == UnitClass("player") then return file end
  return up
end

local function GetClassFileFromDatasetName(datasetClass)
  if not datasetClass then return nil end
  return DATASET_TO_CLASSFILE[tostring(datasetClass)]
end

local function ColorizeByClass(datasetClass, text)
  local file = GetClassFileFromDatasetName(datasetClass) or NormalizeClassFileToken(datasetClass)
  local c = file and _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[file]
  if c and c.r and c.g and c.b then
    return string.format("|cff%02x%02x%02x%s|r", c.r * 255, c.g * 255, c.b * 255, tostring(text))
  end
  local hx = file and FALLBACK_CLASS_HEX[file]
  if hx then return "|c" .. hx .. tostring(text) .. "|r" end
  return tostring(text)
end

local function ColorizeClassName(className)
  local file = NormalizeClassFileToken(className)
  local c = file and _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[file]
  if c and c.r and c.g and c.b then
    return string.format("|cff%02x%02x%02x%s|r", c.r * 255, c.g * 255, c.b * 255, tostring(className))
  end
  local hx = file and FALLBACK_CLASS_HEX[file]
  if hx then return "|c" .. hx .. tostring(className) .. "|r" end
  return tostring(className)
end

local function GetSpecIcon(className, specName)
  if _G.Bistooltip_spec_icons and _G.Bistooltip_spec_icons[className] then
    return _G.Bistooltip_spec_icons[className][specName]
  end
  return nil
end

local function ParseBestRankFromPhases(phasesText)
  if not phasesText or phasesText == "" then return nil end
  local s = tostring(phasesText)
  if s:find("BIS") then
    return { kind = "BIS" }
  end
  local bestAlt
  for n in s:gmatch("alt%s*(%d+)") do
    n = tonumber(n)
    if n and (not bestAlt or n < bestAlt) then bestAlt = n end
  end
  if bestAlt then
    return { kind = "ALT", n = bestAlt }
  end
  return { kind = "FOUND" }
end


-- ============================================================
--  Phase-aware stats (for SHIFT compact view & better sorting)
-- ============================================================

local PHASE_WEIGHT = {
  ["PR"] = 0, ["PreRaid"] = 0, ["Pre-Raid"] = 0,
  ["T7"] = 1, ["T7.5"] = 2,
  ["T8"] = 3, ["Ulduar"] = 3,
  ["T9"] = 4, ["TOC"] = 4,
  ["T10"] = 5, ["ICC"] = 5,
  ["RS"] = 6, ["Ruby Sanctum"] = 6,
}

local function PhaseWeight(phase)
  if not phase then return 999 end
  phase = tostring(phase)
  return PHASE_WEIGHT[phase] or tonumber(phase:match("T(%d+)")) or 999
end

-- Parse "T8 BIS / T9 alt 2" => phaseStats + bestPhase label for bestRank
local function ParsePhaseStatsFromString(phasesText)
  local bisCount, bestAlt = 0, nil
  local earliestBisW, earliestAnyW = 999, 999
  local bestRankKind, bestRankN = nil, nil
  local bestRankPhase, bestRankPhaseW = nil, 999

  if type(phasesText) ~= "string" or phasesText == "" then
    return 0, nil, 999, 999, nil
  end

  for token in phasesText:gmatch("([^/]+)") do
    local s = token:gsub("^%s+", ""):gsub("%s+$", "")
    local phase = s:match("^([^%s]+)") or s
    local w = PhaseWeight(phase)
    if w < earliestAnyW then earliestAnyW = w end

    local isBis = s:find("BIS") ~= nil
    local altN = s:match("alt%s*(%d+)")
    altN = altN and tonumber(altN) or nil

    if isBis then
      bisCount = bisCount + 1
      if w < earliestBisW then earliestBisW = w end
      -- best rank is always BIS
      if bestRankKind ~= "BIS" or w < bestRankPhaseW then
        bestRankKind, bestRankN = "BIS", nil
        bestRankPhase, bestRankPhaseW = phase, w
      end
    elseif altN then
      if not bestAlt or altN < bestAlt then bestAlt = altN end
      if bestRankKind ~= "BIS" then
        if (bestRankKind ~= "ALT") or (not bestRankN) or (altN < bestRankN) or (altN == bestRankN and w < bestRankPhaseW) then
          bestRankKind, bestRankN = "ALT", altN
          bestRankPhase, bestRankPhaseW = phase, w
        end
      end
    end
  end

  return bisCount, bestAlt, earliestBisW, earliestAnyW, bestRankPhase
end

-- Compact SHIFT entry: Class (colored) + spec icon + [T#]
local function FormatShiftEntry(e)
  local classColored = ColorizeByClass(e.class, e.class)
  local iconString = e.icon and string.format("|T%s:14|t", e.icon) or ""

  -- Build phase range like [PR–RS] or [T8–T9]
  local phases = {}
  if type(e.phases) == "string" and e.phases ~= "" then
    for token in e.phases:gmatch("([^/]+)") do
      local s = token:gsub("^%s+", ""):gsub("%s+$", "")
      local phase = s:match("^([^%s]+)")
      if phase then
        phases[phase] = true
      end
    end
  end
  local ordered = {}
  for phase in pairs(phases) do
    table.insert(ordered, phase)
  end
  table.sort(ordered, function(a,b)
    local wa, wb = PhaseWeight(a), PhaseWeight(b)
    if wa ~= wb then return wa < wb end
    return tostring(a) < tostring(b)
  end)

  local phaseTag = ""
  if #ordered == 1 then
    phaseTag = "|cffaaaaaa[" .. ordered[1] .. "]|r"
  elseif #ordered > 1 then
    phaseTag = "|cffaaaaaa[" .. ordered[1] .. "–" .. ordered[#ordered] .. "]|r"
  end

  return string.format("%s%s%s%s",
    classColored,
    iconString ~= "" and (" " .. iconString) or "",
    phaseTag ~= "" and " " or "",
    phaseTag
  )
end

-- For "Your specialization" header we want a clearer status:
-- - BIS (green)
-- - NO BIS (red) + [ALT N] (orange) if an alt exists
local function RankTagForSelf(rank)
  if not rank then
    return "|cffff3b3bNO BIS|r"
  end
  if rank.kind == "BIS" then
    return "|cff13f53bBIS|r"
  end
  if rank.kind == "ALT" then
    return string.format("|cffff3b3bNO BIS|r |cffffa500[ALT %d]|r", rank.n or 0)
  end
  return "|cffff3b3bNO BIS|r"
end

-- Robust points extraction across API variations.
local function ExtractTalentPoints(...)
  local best
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if type(v) == "number" and v >= 0 and v <= 71 then
      if not best or v > best then best = v end
    end
  end
  return best
end


-- Promote ALT2 to BIS2 for dual-slot items (rings/trinkets) and Fury DW weapons.
local function NormalizeDualSlotRank(itemId, className, specName, rank)
  if not rank or rank.kind ~= "ALT" or tonumber(rank.n) ~= 2 then
    return rank
  end
  local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(itemId)
  if equipLoc == "INVTYPE_FINGER" or equipLoc == "INVTYPE_TRINKET" then
    return { kind = "BIS2" }
  end
  if tostring(className) == "Warrior" and tostring(specName) == "Fury" then
    if equipLoc == "INVTYPE_WEAPON" or equipLoc == "INVTYPE_WEAPONMAINHAND" or equipLoc == "INVTYPE_WEAPONOFFHAND" then
      return { kind = "BIS2" }
    end
  end
  return rank
end

local function RankTag(rank)
  if not rank then return "|cffff3b3bNO BIS|r" end
  if rank.kind == "BIS" then return "|cff13f53bBIS|r" end
  if rank.kind == "ALT" then return string.format("|cffffa500ALT %d|r", rank.n or 0) end
  return "|cffffff00FOUND|r"
end

local function GetPlayerClassSpecKeys()
  local _, classFile = UnitClass("player")
  if not classFile then return nil end
  local classKey = CLASSFILE_TO_DATASET[classFile] or UnitClass("player")
  -- active talent group (dual spec)
  local group = 1
  -- Dual spec: some clients expose GetActiveTalentGroup(), some don't; some accept args, some don't.
  if type(_G.GetActiveTalentGroup) == "function" then
    local ok, g = pcall(_G.GetActiveTalentGroup, false, false)
    if (not ok) then ok, g = pcall(_G.GetActiveTalentGroup) end
    if ok and type(g) == "number" and g >= 1 then group = g end
  end
  local bestTab, bestPts = 1, -1
  local tabs = _G.GetNumTalentTabs and _G.GetNumTalentTabs(false, false) or 3
  for tab = 1, tabs do
    local points
    do
      local ok, r1,r2,r3,r4,r5,r6,r7,r8 = pcall(_G.GetTalentTabInfo, tab, false, false, group)
      if ok then
        points = ExtractTalentPoints(r1,r2,r3,r4,r5,r6,r7,r8)
      end
      if points == nil then
        local ok2, a1,a2,a3,a4,a5,a6,a7,a8 = pcall(_G.GetTalentTabInfo, tab, false, false)
        if ok2 then points = ExtractTalentPoints(a1,a2,a3,a4,a5,a6,a7,a8) end
      end
    end
    if points and points > bestPts then
      bestPts, bestTab = points, tab
    end
  end

  -- Druid edge: tab 2 can be cat or bear; if lists split, prefer based on stance if possible
  local specName = (SPEC_BY_CLASSFILE_TAB[classFile] and SPEC_BY_CLASSFILE_TAB[classFile][bestTab]) or nil
  if classFile == "DRUID" and bestTab == 2 then
    -- Try to guess bear/cat by current form
    local form = GetShapeshiftForm and GetShapeshiftForm() or 0
    -- 1 bear, 3 cat on WotLK typically
    if form == 1 then specName = "Feral tank"
    elseif form == 3 then specName = "Feral dps"
    else specName = "Feral tank" end
  end
  if classFile == "DEATHKNIGHT" and bestTab == 1 then
    -- some lists differentiate blood tank vs blood dps; we default to blood tank
    specName = "Blood tank"
  end
  return classKey, specName
end

local function specHighlighted(class_name, spec_name)
    return (BistooltipAddon.db.char.highlight_spec.spec_name == spec_name and
               BistooltipAddon.db.char.highlight_spec.class_name == class_name)
end

local function specFiltered(class_name, spec_name)
    if specHighlighted(class_name, spec_name) then
        return false
    end
    if IsAltKeyDown() then
        return false
    end
    if BistooltipAddon.db.char.filter_specs[class_name] then
        return not BistooltipAddon.db.char.filter_specs[class_name][spec_name]
    end
    return false
end

local function classNamesFiltered()
    if BistooltipAddon.db.char.filter_class_names then
        return true
    end
end

local function getFilteredItem(item)
    local filtered_item = {}

    for ki, spec in ipairs(item) do
        local class_name = spec.class_name
        local spec_name = spec.spec_name
        if (not specFiltered(class_name, spec_name)) then
            table.insert(filtered_item, spec)
        end
    end
    return filtered_item
end

local function printSpecLine(tooltip, slot, class_name, spec_name)
    local slot_name = slot.name
    local slot_ranks = slot.ranks
    local prefix = "   "
    if BistooltipAddon.db.char.filter_class_names then
        prefix = ""
    end
    local left_text = prefix .. "|T" .. Bistooltip_spec_icons[class_name][spec_name] .. ":14|t " .. ColorizeByClass(class_name, spec_name)
    if (slot_name == "Off hand" or slot_name == "Weapon" or slot_name == "Weapon 1h" or slot_name == "Weapon 2h") then
        left_text = left_text .. " (" .. slot_name .. ")"
    end
    tooltip:AddDoubleLine(left_text, slot_ranks)
end

local function printClassName(tooltip, class_name)
    tooltip:AddLine(ColorizeByClass(class_name, class_name))
end

-- Define your search function without debug prints
function searchIDInBislistsClassSpec(structure, id, class, spec)
    local paths = {}
    local seen = {} -- To track unique phase labels

    -- Sort phases according to Bistooltip_wowtbc_phases order
    local sortedPhases = {}
    for _, phase in ipairs(Bistooltip_wowtbc_phases) do
        if structure[class] and structure[class][spec] and structure[class][spec][phase] then
            table.insert(sortedPhases, phase)
        end
    end

    -- Iterate over sorted phases
    for _, phase in ipairs(sortedPhases) do
        local items = structure[class][spec][phase]

        for index, itemData in pairs(items) do
            if type(itemData) == "table" and itemData[1] then
                for i, itemId in ipairs(itemData) do
                    if i ~= "slot_name" and i ~= "enhs" and itemId == id then
                        -- Determine the phase label based on the value of i
                        local phaseLabel
                        if i == 1 then
                            phaseLabel = phase .. " BIS"
                        else
                            phaseLabel = phase .. " alt " .. i
                        end

                        -- Add phase label to paths if not already seen
                        if not seen[phaseLabel] then
                            table.insert(paths, phaseLabel)
                            seen[phaseLabel] = true
                        end
                    end
                end
            end
        end
    end

    if #paths > 0 then
        return table.concat(paths, " / ")
    else
        return nil
    end
end

local function caseInsensitivePairs(t)
    local keys = {}
    for k in pairs(t) do
        table.insert(keys, k)
    end
    table.sort(keys, function(a, b)
        return a:lower() < b:lower()
    end)
    local i = 0
    return function()
        i = i + 1
        local k = keys[i]
        if k then
            return k, t[k]
        end
    end
end

-- Function to calculate the length of a string without color codes
local function getStringLength(str)
    return string.len(string.gsub(str, "|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

function table.contains(table, element)
    for _, value in pairs(table) do
        if value == element then
            return true
        end
    end
    return false
end

-- Optional dependency: DataStore_Inventory
-- In some setups (like yours), DataStore can be disabled. Tooltip must not error.
local function getDataStoreInventory()
    if _G.DataStore_Inventory then
        return _G.DataStore_Inventory
    end
    -- Try AceAddon lookup if DataStore is an AceAddon (safe = true)
    local ok, AceAddon = pcall(LibStub, "AceAddon-3.0")
    if ok and AceAddon and AceAddon.GetAddon then
        local ds = AceAddon:GetAddon("DataStore_Inventory", true)
        if ds then return ds end
    end
    return nil
end

local function GetItemSource(itemId)
    local source

    -- Function to replace specific instance names
    local function formatInstanceName(instance)
        -- Normalize instance name for comparison (if needed)
        local tmpInstance = string.lower(instance)

        -- Replace "The Obsidian Sanctum(Heroic)" with "The Obsidian Sanctum(25)"

        if tmpInstance == "the obsidian sanctum (heroic)" then
            instance = "The Obsidian Sanctum(25)"
        elseif tmpInstance == "the eye of eternity (heroic)" then
            instance = "The Eye Of Eternity (25)"
        elseif tmpInstance == "naxxramas (heroic)" then
            instance = "Naxxramas (25)"
        elseif tmpInstance == "ulduar (heroic)" then
            instance = "Ulduar (25)"
        end

        return instance
    end

    -- First, check the lootTable (assuming lootTable is defined somewhere)
    for zone, bosses in pairs(lootTable) do
        for boss, items in pairs(bosses) do
            if table.contains(items, itemId) then
                local formattedZone = formatInstanceName(zone)
                source = "|cFFFFFFFFSource:|r |cFF00FF00[" .. formattedZone .. "] - " .. boss .. "|r"
                break
            end
        end
        if source then
            break
        end
    end

    -- If not found in lootTable, fallback to DataStore_Inventory (optional)
    if not source then
        local DataStore_Inventory = getDataStoreInventory()
        if not DataStore_Inventory or not DataStore_Inventory.GetSource then
            return nil
        end

        local Instance, Boss = DataStore_Inventory:GetSource(itemId)
        if Instance and Boss then
            local formattedInstance = formatInstanceName(Instance)
            source = "|cFFFFFFFFSource:|r |cFF00FF00[" .. formattedInstance .. "] - " .. Boss .. "|r"
        else
            return nil
        end
    end

    return source
end

-- Owned-item helper (cache from Core.lua)
local function GetOwnedInfo(itemId)
    if not itemId then return 0, 0 end
    local t = _G.Bistooltip_char_equipment
    if not t then return 0, 0 end
    local row = t[itemId]
    if not row then return 0, 0 end
    local bags = row.bags or 0
    local equipped = row.equipped or 0
    return bags, equipped
end

-- Function to handle item tooltip
local function OnGameTooltipSetItem(tooltip)
    -- print("Debug: OnGameTooltipSetItem called")
    local ctrlDown  = IsControlKeyDown() and true or false
    local shiftDown = IsShiftKeyDown() and true or false
    -- If user enabled "show only with CTRL", still allow SHIFT summary view.
    if BistooltipAddon.db.char.tooltip_with_ctrl and (not ctrlDown) and (not shiftDown) then
        return
    end

    local _, link = tooltip:GetItem()
    if not link then
        return
    end

    local _, itemId, _, _, _, _, _, _, _, _, _, _, _, _ = strsplit(":", link)
    itemId = tonumber(itemId)

    if not itemId then
        return
    end

    

    -- Your specialization first (fast read)
    local pClass, pSpec = GetPlayerClassSpecKeys()
    if pClass and pSpec then
        tooltip:AddLine(" ", 1, 1, 0)
        tooltip:AddLine("Your specialization:", 1, 1, 1)

        local foundPhases = searchIDInBislistsClassSpec(Bistooltip_bislists, itemId, pClass, pSpec)
        local icon = GetSpecIcon(pClass, pSpec)
        local left = (icon and string.format("|T%s:16|t ", icon) or "") .. ColorizeByClass(pClass, pClass) .. " - " .. ColorizeByClass(pClass, tostring(pSpec))

        if foundPhases then
            local rank = ParseBestRankFromPhases(foundPhases)
            tooltip:AddDoubleLine(left, RankTagForSelf(rank), 1, 1, 1, 1, 1, 1)
            tooltip:AddDoubleLine("Where:", tostring(foundPhases), 1, 1, 1, 1, 1, 0)
        else
            tooltip:AddDoubleLine(left, "|cffff3b3bNO BIS|r", 1, 1, 1, 1, 1, 1)
        end
        tooltip:AddLine(" ", 1, 1, 0)
    end
-- tooltip:AddDoubleLine("Spec Name", "Phase", 1, 1, 1, 1, 1, 1)

    local anyFound = false
    local entries = {}
    local classOrder = _G.Bistooltip_classes_indexes or {}

    -- Collect all matching entries first (so we can sort / focus without hiding data by default).
    for class, specs in caseInsensitivePairs(Bistooltip_spec_icons) do
        for spec, icon in pairs(specs) do
            if spec ~= "classIcon" then
                local foundPhases = searchIDInBislistsClassSpec(Bistooltip_bislists, itemId, class, spec)
                if foundPhases then
                    anyFound = true
                    local rank = ParseBestRankFromPhases(foundPhases)
                    table.insert(entries, {
                        class = class,
                        spec  = spec,
                        icon  = icon,
                        phases = foundPhases,
                        rank = rank,
                        -- phase-aware stats (for better sort and SHIFT summary)
                        bisCount = (select(1, ParsePhaseStatsFromString(foundPhases))),
                        bestAlt  = (select(2, ParsePhaseStatsFromString(foundPhases))),
                        earliestBisW = (select(3, ParsePhaseStatsFromString(foundPhases))),
                        earliestAnyW = (select(4, ParsePhaseStatsFromString(foundPhases))),
                        bestPhase = (select(5, ParsePhaseStatsFromString(foundPhases))),
                        classIdx = tonumber(classOrder[class]) or 999,
                    })
                end
            end
        end
    end

    -- Sort entries (QoL): BIS first, then ALT1/ALT2..., then other matches; earlier phase first; class order next.
    local function _rankWeight(r)
        if not r then return 4, 99 end
        if r.kind == "BIS" then return 0, 0 end
        if r.kind == "ALT" then return 1, (tonumber(r.n) or 99) end
        return 2, 99
    end

    table.sort(entries, function(a, b)
        local wa, na = _rankWeight(a.rank)
        local wb, nb = _rankWeight(b.rank)
        if wa ~= wb then return wa < wb end
        if na ~= nb then return na < nb end

        local pa = (a.rank and a.rank.kind == "BIS") and (a.earliestBisW or 999) or (a.earliestAnyW or 999)
        local pb = (b.rank and b.rank.kind == "BIS") and (b.earliestBisW or 999) or (b.earliestAnyW or 999)
        if pa ~= pb then return pa < pb end

        if (a.classIdx or 999) ~= (b.classIdx or 999) then return (a.classIdx or 999) < (b.classIdx or 999) end
        if tostring(a.class) ~= tostring(b.class) then return tostring(a.class) < tostring(b.class) end
        return tostring(a.spec) < tostring(b.spec)
    end)

    local shiftMode = IsShiftKeyDown() and true or false
    if shiftMode then
        tooltip:AddLine(" ", 1, 1, 0)
        tooltip:AddLine("Summary (SHIFT):", 1, 1, 1)

        -- Group entries by their best rank; keep full list logic elsewhere unchanged.
        local groupedBis, groupedBis2, groupedNo = {}, {}, {}
        local altGroups = {} -- [n] = { ... }

        for i = 1, #entries do
            local e = entries[i]
            local r = NormalizeDualSlotRank(itemId, e.class, e.spec, e.rank)
            e._normRank = r

            if r and r.kind == "BIS" then
                table.insert(groupedBis, e)
            elseif r and r.kind == "BIS2" then
                table.insert(groupedBis2, e)
            elseif r and r.kind == "ALT" and r.n then
                local n = tonumber(r.n) or 99
                altGroups[n] = altGroups[n] or {}
                table.insert(altGroups[n], e)
            else
                table.insert(groupedNo, e)
            end
        end

        local function addWrapped(label, list, sep)
            if #list == 0 then return end
            sep = sep or " / "
            local maxPerLine = 3
            local idx = 1
            local first = true
            local indent = string.rep(" ", 6)

            while idx <= #list do
                local chunk = {}
                for j = 1, maxPerLine do
                    local e = list[idx]
                    if not e then break end
                    chunk[#chunk + 1] = FormatShiftEntry(e)
                    idx = idx + 1
                end
                if #chunk > 0 then
                    tooltip:AddLine((first and label or indent) .. table.concat(chunk, sep))
                    first = false
                end
            end
        end

        -- BIS: prioritize specs that are BIS in multiple phases (already handled in entries sort via bisCount)
        addWrapped("  |cff00ff00BIS:|r ", groupedBis, " / ")
        addWrapped("  |cff00cc00BIS²:|r ", groupedBis2, " / ")

        local alts = {}
        for n in pairs(altGroups) do table.insert(alts, n) end
        table.sort(alts)
        for _, n in ipairs(alts) do
            addWrapped(string.format("  |cffffa500ALT%d:|r ", n), altGroups[n], " > ")
        end

        addWrapped("  |cffff3b3bNO BIS:|r ", groupedNo, " / ")

        return true
    end

    -- CTRL focus mode: show "My spec + alternatives" (BIS / ALT1 / ALT2) without touching defaults.
    local focusMode = (not shiftMode) and ctrlDown
    if focusMode then
        tooltip:AddLine(" ", 1, 1, 0)
        tooltip:AddLine("Best for group (CTRL):", 1, 1, 1)
    end

    if not shiftMode then
    for i = 1, #entries do
        local e = entries[i]
        if (not focusMode)
           or (e.rank and (e.rank.kind == "BIS" or (e.rank.kind == "ALT" and (e.rank.n or 99) <= 2))) then
            local iconString = e.icon and string.format("|T%s:18|t", e.icon) or ""
            local classColored = ColorizeByClass(e.class, e.class)
            local specColored  = ColorizeByClass(e.class, e.spec)
            local lineText = string.format("%s %s - %s", iconString, classColored, specColored)
            tooltip:AddDoubleLine(lineText, e.phases)
        end
    end

    end

    -- if Bistooltip_char_equipment and Bistooltip_char_equipment[itemId] ~= nil then
    local bags, equipped = GetOwnedInfo(itemId)
    if (bags > 0) or (equipped > 0) then
        tooltip:AddLine(" ", 1, 1, 0)
        if equipped > 0 then
            tooltip:AddLine("You have this item equipped", 0.074, 0.964, 0.129)
        else
            if bags > 1 then
                tooltip:AddLine("You have this item in your bags (x" .. bags .. ")", 0.074, 0.964, 0.129)
            else
                tooltip:AddLine("You have this item in your bags", 0.074, 0.964, 0.129)
            end
        end
    else
        -- If DataStore is missing, show a gentle note ONCE per session.
        -- We do not scan bank/alt containers in this mode.
        if anyFound and not getDataStoreInventory() and not BistooltipAddon._noDSNoteShown then
            BistooltipAddon._noDSNoteShown = true
            tooltip:AddLine(" ", 1, 1, 0)
            tooltip:AddLine("Bis-Tooltip is running without DataStore: bank items won't be shown.", 0.6, 0.6, 0.6)
        end
    end

    -- tooltip:AddLine(" ", 1, 1, 0)
    -- tooltip:AddLine("Hold ALT to disable spec filtering", 0.6, 0.6, 0.6)

    -- Fetch item source information
    local itemSource = GetItemSource(itemId)

    -- Add item source information to tooltip if available
    if itemSource then
        tooltip:AddLine(" ", 1, 1, 0)
        tooltip:AddLine(itemSource, 1, 1, 1)
        tooltip:AddLine(" ", 1, 1, 0)
    end
end

function BistooltipAddon:initBisTooltip()
    eventFrame:RegisterEvent("MODIFIER_STATE_CHANGED")
    eventFrame:SetScript("OnEvent", function(_, _, e_key)
        -- We only care about modifier keys.
        if e_key ~= "RALT" and e_key ~= "LALT" and e_key ~= "RCTRL" and e_key ~= "LCTRL" and e_key ~= "RSHIFT" and e_key ~= "LSHIFT" then
            return
        end

        local function refreshTooltip(tt)
            if not tt or not tt.IsShown or not tt:IsShown() then return end
            local _, link = tt:GetItem()
            if not link then return end
            if BistooltipAddon._refreshing then return end
            BistooltipAddon._refreshing = true
            tt:ClearLines()
            tt:SetHyperlink(link)
            BistooltipAddon._refreshing = false
        end

        refreshTooltip(GameTooltip)
        refreshTooltip(ItemRefTooltip)
    end)

    GameTooltip:HookScript("OnTooltipSetItem", OnGameTooltipSetItem)
    ItemRefTooltip:HookScript("OnTooltipSetItem", OnGameTooltipSetItem)
end
