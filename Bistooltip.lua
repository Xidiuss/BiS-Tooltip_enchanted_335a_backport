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
    return "|cff00ff00BIS|r"
  end
  if rank.kind == "BIS2" then
    return "|cff009900BIS2|r"
  end
  if rank.kind == "ALT" then
    return string.format("|cffffa500[ALT %d]|r", rank.n or 0)
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


-- Display helper: in dual-slot contexts (rings/trinkets + Fury DW weapons),
-- treat ALT2 as BIS² in the phase string, using a darker green.
local function FormatPhasesString(itemId, className, specName, phasesStr)
  if not phasesStr then return phasesStr end
  -- If the item is BIS in any phase, it cannot be BIS2 (you can't equip two identical unique items).
  if phasesStr:find("BIS") then return phasesStr end
  local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(itemId)
  local isDual = (equipLoc == "INVTYPE_FINGER" or equipLoc == "INVTYPE_TRINKET")
  if not isDual and tostring(className) == "Warrior" and tostring(specName) == "Fury" then
    if equipLoc == "INVTYPE_WEAPON" or equipLoc == "INVTYPE_WEAPONMAINHAND" or equipLoc == "INVTYPE_WEAPONOFFHAND" then
      isDual = true
    end
  end
  if not isDual then return phasesStr end

  local bis2Token = "|cff009900BIS2|r"
  -- Replace ALT2 / alt 2 only (avoid ALT20 etc.)
  local out = phasesStr:gsub("[Aa][Ll][Tt]%s*2%f[%D]", bis2Token)
  return out
end

local function RankTag(rank)
  if not rank then return "|cffff3b3bNO BIS|r" end
  if rank.kind == "BIS" then return "|cff00ff00BIS|r" end
  if rank.kind == "BIS2" then return "|cff009900BIS2|r" end
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
    elseif BistooltipAddon.db.char.filter_specs[class_name] then
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

local function formatInstanceName(instance)
    if not instance then return nil end
    instance = tostring(instance)
    local tmpInstance = string.lower(instance)

    -- Normalize heroic labels to 25-man naming used in your data
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

local function findSourceInLootTable(itemId)
    local lt = rawget(_G, "lootTable")
    if type(lt) ~= "table" then
        -- some packs keep it as a plain global; also try local upvalue name
        lt = type(lootTable) == "table" and lootTable or nil
    end
    if type(lt) ~= "table" then
        return nil, nil
    end

    for zone, bosses in pairs(lt) do
        if type(bosses) == "table" then
            for boss, items in pairs(bosses) do
                if type(items) == "table" then
                    for k, v in pairs(items) do
                        if k == itemId or v == itemId then
                            return formatInstanceName(zone), boss
                        end
                    end
                end
            end
        end
    end

    return nil, nil
end

-- Public API used by Bislist (checklist/export): returns instance, boss.
function BistooltipAddon:GetItemSourceInfo(itemId)
    if not itemId then return nil, nil end

    self._sourceCache = self._sourceCache or {}
    local cached = self._sourceCache[itemId]
    if cached then
        return cached[1], cached[2]
    end

    local zone, boss = findSourceInLootTable(itemId)

    if not zone then
        local DataStore_Inventory = getDataStoreInventory()
        if DataStore_Inventory and DataStore_Inventory.GetSource then
            local Instance, Boss = DataStore_Inventory:GetSource(itemId)
            if Instance and Boss then
                zone, boss = formatInstanceName(Instance), Boss
            end
        end
    end

    self._sourceCache[itemId] = { zone, boss }
    return zone, boss
end

local function GetItemSource(itemId)
    if not (BistooltipAddon and BistooltipAddon.GetItemSourceInfo) then
        return nil
    end
    local zone, boss = BistooltipAddon:GetItemSourceInfo(itemId)
    if zone and boss then
        return "|cFFFFFFFFSource:|r |cFF00FF00[" .. tostring(zone) .. "] - " .. tostring(boss) .. "|r"
    end
    return nil
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
    local shiftMode = IsShiftKeyDown() and true or false
    local ctrlDown  = IsControlKeyDown() and true or false

    local _, link = tooltip:GetItem()
    if not link then return end

    local _, itemIdStr = strsplit(":", link)
    local itemId = tonumber(itemIdStr)
    if not itemId then return end

    -- Your specialization section (only for epic equippable items)
local showSpec = false
do
    local _, _, quality, _, _, _, _, _, equipLoc = GetItemInfo(link)
    if quality and quality >= 3 then
        if type(_G.IsEquippableItem) == "function" then
            local ok, eq = pcall(_G.IsEquippableItem, link)
            if ok and eq then showSpec = true end
        else
            if equipLoc and equipLoc ~= "" and equipLoc ~= "INVTYPE_NON_EQUIP" then
                showSpec = true
            end
        end
    end
end


    if showSpec then
        local pClass, pSpec = GetPlayerClassSpecKeys()
        if pClass and pSpec then
            tooltip:AddLine(" ", 1, 1, 0)
            tooltip:AddLine("Your specialization:", 1, 1, 1)

            local foundPhases = searchIDInBislistsClassSpec(Bistooltip_bislists, itemId, pClass, pSpec)
            local icon = GetSpecIcon(pClass, pSpec)
            local left = (icon and string.format("|T%s:16|t ", icon) or "")
                .. ColorizeByClass(pClass, pClass)
                .. " - "
                .. ColorizeByClass(pClass, tostring(pSpec))

            if foundPhases then
                local rank = NormalizeDualSlotRank(itemId, pClass, pSpec, ParseBestRankFromPhases(foundPhases))
                tooltip:AddDoubleLine(left, RankTagForSelf(rank), 1, 1, 1, 1, 1, 1)
                tooltip:AddDoubleLine("Where:", tostring(FormatPhasesString(itemId, pClass, pSpec, foundPhases)), 1, 1, 1, 1, 1, 0)
            else
                tooltip:AddDoubleLine(left, "|cffff3b3bNO BIS|r", 1, 1, 1, 1, 1, 1)
            end
            tooltip:AddLine(" ", 1, 1, 0)
        end
    end

    -- Collect all matching entries first (so we can sort / focus without losing data)
    local anyFound = false
    local entries = {}
    local classOrder = _G.Bistooltip_classes_indexes or {}

    for class, specs in caseInsensitivePairs(Bistooltip_spec_icons) do
        for spec, icon in pairs(specs) do
            if spec ~= "classIcon" then
                local foundPhases = searchIDInBislistsClassSpec(Bistooltip_bislists, itemId, class, spec)
                if foundPhases then
                    anyFound = true
                    local rank = ParseBestRankFromPhases(foundPhases)
                    local bisCount, bestAlt, earliestBisW, earliestAnyW, bestPhase = ParsePhaseStatsFromString(foundPhases)

                    table.insert(entries, {
                        class = class,
                        spec  = spec,
                        icon  = icon,
                        phases = foundPhases,
                        rank = rank,
                        bisCount = bisCount,
                        bestAlt  = bestAlt,
                        earliestBisW = earliestBisW,
                        earliestAnyW = earliestAnyW,
                        bestPhase = bestPhase,
                        classIdx = tonumber(classOrder[class]) or 999,
                    })
                end
            end
        end
    end

    -- Helper: rank allowlist for CTRL focus mode
    local function isFocusRank(r)
        if not r then return false end
        if r.kind == "BIS" or r.kind == "BIS2" then return true end
        if r.kind == "ALT" then
            local n = tonumber(r.n) or 99
            return n <= 2
        end
        return false
    end

    -- Always show the hint line once we have any results
    if anyFound then
        tooltip:AddLine("|cffaaaaaaHold SHIFT for summary \194\183 Hold CTRL for focus|r")
    end

    -- SHIFT summary (compact)
    if shiftMode and #entries > 0 then
        tooltip:AddLine(" ", 1, 1, 0)
        tooltip:AddLine("Summary (SHIFT):", 1, 1, 1)

        local groupedBis, groupedBis2, groupedNo = {}, {}, {}
        local altGroups = {}

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

        local function entrySort(a, b)
            if a.classIdx ~= b.classIdx then return a.classIdx < b.classIdx end
            if a.class ~= b.class then return tostring(a.class) < tostring(b.class) end
            return tostring(a.spec) < tostring(b.spec)
        end
        table.sort(groupedBis, entrySort)
        table.sort(groupedBis2, entrySort)
        table.sort(groupedNo, entrySort)
        for n, list in pairs(altGroups) do
            table.sort(list, entrySort)
        end

        local function addWrapped(label, list, sep)
            if #list == 0 then return end
            sep = sep or " / "
            local maxPerLine = 3
            local idx = 1
            local indent = string.rep(" ", 6)
            local first = true
            while idx <= #list do
                local chunk = {}
                for j = 1, maxPerLine do
                    local e = list[idx]
                    if not e then break end
                    chunk[#chunk + 1] = FormatShiftEntry(e)
                    idx = idx + 1
                end
                if #chunk > 0 then
                    if first then
                        tooltip:AddLine(label .. table.concat(chunk, sep))
                        first = false
                    else
                        tooltip:AddLine(indent .. table.concat(chunk, sep))
                    end
                end
            end
        end

        addWrapped("  |cff00ff00BIS:|r ", groupedBis, " / ")
        addWrapped("  |cff009900BIS2:|r ", groupedBis2, " / ")

        local alts = {}
        for n in pairs(altGroups) do table.insert(alts, n) end
        table.sort(alts)
        for _, n in ipairs(alts) do
            addWrapped(string.format("  |cffffa500ALT%d:|r ", n), altGroups[n], " > ")
        end

        addWrapped("  |cffff3b3bNO BIS:|r ", groupedNo, " / ")
        return true
    end

        -- Default view: full list (sorted) / CTRL focus view (filtered)
    local focusMode = (not shiftMode) and ctrlDown

    -- Rank ordering: BIS > BIS2 > ALT1 > ALT2 ... > NO BIS
    local function RankWeight(r)
        if not r then return 999 end
        if r.kind == "BIS" then return 0 end
        if r.kind == "BIS2" then return 1 end
        if r.kind == "ALT" then return 10 + (tonumber(r.n) or 99) end
        return 900
    end

    local buckets = {}
    local classes = {}

    for i = 1, #entries do
        local e = entries[i]
        e._normRank = NormalizeDualSlotRank(itemId, e.class, e.spec, e.rank)
        if (not focusMode) or isFocusRank(e._normRank) then
            local c = e.class
            local b = buckets[c]
            if not b then
                b = {
                    class = c,
                    classIdx = e.classIdx or 999,
                    bestW = 999,
                    bestPhaseW = 999,
                    entries = {},
                }
                buckets[c] = b
                table.insert(classes, b)
            end

            local w = RankWeight(e._normRank)
            local pW = PhaseWeight(e.bestPhase)
            if (w < b.bestW) or (w == b.bestW and pW < b.bestPhaseW) then
                b.bestW = w
                b.bestPhaseW = pW
            end

            table.insert(b.entries, e)
        end
    end

    -- Sort classes by best rank available for this item, then by earliest phase, then by natural class order
    table.sort(classes, function(a, b)
        if a.bestW ~= b.bestW then return a.bestW < b.bestW end
        if a.bestPhaseW ~= b.bestPhaseW then return a.bestPhaseW < b.bestPhaseW end
        if a.classIdx ~= b.classIdx then return a.classIdx < b.classIdx end
        return tostring(a.class) < tostring(b.class)
    end)

    -- Sort specs inside each class by rank, then phase, then name
    local function specSort(a, b)
        local wa, wb = RankWeight(a._normRank), RankWeight(b._normRank)
        if wa ~= wb then return wa < wb end
        local pa, pb = PhaseWeight(a.bestPhase), PhaseWeight(b.bestPhase)
        if pa ~= pb then return pa < pb end
        return tostring(a.spec) < tostring(b.spec)
    end
    for i = 1, #classes do
        table.sort(classes[i].entries, specSort)
    end

    if focusMode and #classes > 0 then
        tooltip:AddLine("|cffaaaaaaFocus mode: BIS / BIS2 / ALT1 / ALT2|r")
    end

    for i = 1, #classes do
        local b = classes[i]
        tooltip:AddLine(ColorizeByClass(b.class, b.class))
        for j = 1, #b.entries do
            local e = b.entries[j]
            local iconString = e.icon and string.format("|T%s:14|t ", e.icon) or ""
            local leftText = "   " .. iconString .. ColorizeByClass(b.class, e.spec)
            tooltip:AddDoubleLine(leftText, FormatPhasesString(itemId, e.class, e.spec, e.phases), 1, 1, 1, 1, 1, 0)
        end
    end

    -- Owned info (TUTAJ POWINIEN BYĆ DALSZY CIĄG)
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
        if anyFound and not getDataStoreInventory() and not BistooltipAddon._noDSNoteShown then
            BistooltipAddon._noDSNoteShown = true
            tooltip:AddLine(" ", 1, 1, 0)
            tooltip:AddLine("Bis-Tooltip is running without DataStore: bank items won't be shown.", 0.6, 0.6, 0.6)
        end
    end

    -- Item source
    local itemSource = GetItemSource(itemId)
    if itemSource then
        tooltip:AddLine(" ", 1, 1, 0)
        tooltip:AddLine(itemSource, 1, 1, 1)
        tooltip:AddLine(" ", 1, 1, 0)
    end
end

local function RefreshAnyTooltip(tt)
    if not tt or not tt.GetItem then return end
    local _, link = tt:GetItem()
    if not link then return end
    if BistooltipAddon._refreshing then return end
    BistooltipAddon._refreshing = true
    tt:ClearLines()
    tt:SetHyperlink(link)
    BistooltipAddon._refreshing = false
end

function BistooltipAddon:initBisTooltip()
    eventFrame:RegisterEvent("MODIFIER_STATE_CHANGED")
    eventFrame:SetScript("OnEvent", function(_, _, e_key)
        if e_key ~= "RCTRL" and e_key ~= "LCTRL" and e_key ~= "RSHIFT" and e_key ~= "LSHIFT" then
            return
        end
        if GameTooltip and GameTooltip:IsShown() then
            RefreshAnyTooltip(GameTooltip)
        end
        if ItemRefTooltip and ItemRefTooltip:IsShown() then
            RefreshAnyTooltip(ItemRefTooltip)
        end
    end)

    GameTooltip:HookScript("OnTooltipSetItem", OnGameTooltipSetItem)
    ItemRefTooltip:HookScript("OnTooltipSetItem", OnGameTooltipSetItem)
end
