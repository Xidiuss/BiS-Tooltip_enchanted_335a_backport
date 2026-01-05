local AceGUI = LibStub("AceGUI-3.0")

local class = nil
local spec = nil
local phase = nil
local class_index = nil
local spec_index = nil
local phase_index = nil

local class_options = {}
local class_options_to_class = {}

local spec_options = {}
local spec_options_to_spec = {}
local spec_frame = nil
local items = {}
local spells = {}
local main_frame = nil

local classDropdown = nil
local specDropdown = nil
local phaseDropDown = nil

local checkmarks = {}
local boemarks = {}

local isHorde = UnitFactionGroup("player") == "Horde"

-- forward declarations used before definitions
local QueuePreload
local TooltipSetItemByID
local ForceIconBright

-- IMPORTANT: forward declarations (used before local definitions)
local clearCheckMarks, clearBoeMarks
local DestroyChecklistPanel
local mainFrameUISpecialName

local drawTableHeader
local ClearSlotRowBackdrops

-- 3.3.5 safe: SetItemID may not exist
TooltipSetItemByID = function(tt, item_id)
    if not tt or not item_id or item_id <= 0 then return end
    tt:SetHyperlink("item:" .. item_id .. ":0:0:0:0:0:0:0")
end


-- ============================================================
-- Keybind friendliness:
-- Avoid capturing keyboard input (ENTER/chat, keybinds) while addon UI is open.
-- Use UISpecialFrames for ESC to close.
-- ============================================================
local function AddToUISpecialFrames(frameName, beforeName)
    if not frameName then return end
    _G.UISpecialFrames = _G.UISpecialFrames or {}
    for _, n in ipairs(_G.UISpecialFrames) do
        if n == frameName then return end
    end
    if beforeName then
        for i, n in ipairs(_G.UISpecialFrames) do
            if n == beforeName then
                table.insert(_G.UISpecialFrames, i, frameName)
                return
            end
        end
    end
    table.insert(_G.UISpecialFrames, frameName)
end

local function RemoveFromUISpecialFrames(frameName)
    if not frameName or not _G.UISpecialFrames then return end
    for i = #_G.UISpecialFrames, 1, -1 do
        if _G.UISpecialFrames[i] == frameName then
            table.remove(_G.UISpecialFrames, i)
        end
    end
end


-- Class colors (for nicer dropdown UI)
local CLASSNAME_TO_FILE = {
  Warrior = "WARRIOR",
  Paladin = "PALADIN",
  Hunter = "HUNTER",
  Rogue = "ROGUE",
  Priest = "PRIEST",
  DeathKnight = "DEATHKNIGHT",
  Shaman = "SHAMAN",
  Mage = "MAGE",
  Warlock = "WARLOCK",
  Druid = "DRUID",
}

local function ColorizeClassOption(className)
  local file = CLASSNAME_TO_FILE[className]
  local c = file and _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[file]
  if c and c.r then
    return string.format("|cff%02x%02x%02x%s|r", c.r*255, c.g*255, c.b*255, className)
  end
  return className
end


-- ============================================================
-- Premium UX additions:
--   - background item preloader (avoids "Reload spam" / server throttle feel)
--   - owned-state overlays (equipped vs bags + count)
--   - search filter
-- ============================================================

local searchText = ""
local searchTextLower = ""
local showOnlyMissing = false

local bisChecklistMode = false -- "BIS checklist" mode (hide completed BIS slots + show sources + targets summary)
local checklistSummaryLabel = nil

-- ============================================================
-- Spec table layouts (normal vs BIS checklist expanded view)
-- ============================================================
local SPEC_TABLE_DEFAULT = {
    columns = {
        { weight = 40 },
        { width = 44 },
        { width = 58 },
        { width = 58 },
        { width = 44 },
        { width = 44 },
        { width = 44 },
        { width = 44 },
    },
    space = 3,
    align = "middle",
}

local SPEC_TABLE_CHECKLIST = {
    columns = {
        { width = 80 },   -- Slot
        { weight = 40 },  -- Plan (Boss/Item)
        { width = 58 },   -- BIS
        { width = 58 },   -- BIS2
        { width = 44 },
        { width = 44 },
        { width = 44 },
        { width = 44 },
    },
    space = 3,
    align = "middle",
}

local function ApplySpecTable()
    if not spec_frame then return end
    spec_frame:SetUserData("table", bisChecklistMode and SPEC_TABLE_CHECKLIST or SPEC_TABLE_DEFAULT)
end

local function ComputeChecklistGemSpanWidth()
    local cols = SPEC_TABLE_CHECKLIST.columns
    local total = 0
    for i = 3, 8 do
        local c = cols[i]
        if type(c) == "table" then
            total = total + (c.width or 0)
        elseif type(c) == "number" then
            total = total + c
        end
    end
    return total + 16
end

local CHECKLIST_GEMSPAN_W = ComputeChecklistGemSpanWidth()
local drawSpecData -- forward declaration (called by preloader before definition)

-- Owned info helper (cache from Core.lua)
local function GetOwnedRow(item_id)
    local t = _G.Bistooltip_char_equipment
    if not t then return nil end
    return t[item_id]
end

-- Checklist-mode helpers

local function OwnedCount(item_id)
    local row = GetOwnedRow(item_id)
    if not row then return 0 end
    return (row.bags or 0) + (row.equipped or 0)
end

local function NormalizeItemID(original_item_id)
    if not original_item_id or original_item_id <= 0 then return nil end
    if _G.Bistooltip_horde_to_ali and _G.Bistooltip_horde_to_ali[original_item_id] then
        return _G.Bistooltip_horde_to_ali[original_item_id]
    end
    return original_item_id
end

local function IsDualSlot(slot, item_id)
    -- Prefer equipLoc when cached; fallback to slot name hints
    local equipLoc
    if item_id then
        local _, _, _, _, _, _, _, _, loc = GetItemInfo(item_id)
        equipLoc = loc
    end
    if equipLoc == "INVTYPE_TRINKET" or equipLoc == "INVTYPE_FINGER" then
        return true
    end
    local sn = slot and (slot.slot_name or slot.name)
    if sn then
        sn = tostring(sn):lower()
        if sn:find("trinket") or sn:find("ring") or sn:find("finger") then
            return true
        end
    end
    return false
end

local function GetRequiredBISItemsForSlot(slot)
    local req = {}
    local a = NormalizeItemID(slot and slot[1])
    if a then table.insert(req, a) end

    if a and IsDualSlot(slot, a) then
        local b = NormalizeItemID(slot and slot[2])
        if b and b ~= a then
            table.insert(req, b)
        else
            -- If BIS1 == BIS2 (or missing), pick the next distinct item from the row as BIS2.
            local found
            for i = 2, math.min(#slot, 6) do
                local cand = NormalizeItemID(slot[i])
                if cand and cand ~= a then
                    found = cand
                    break
                end
            end
            if found then
                table.insert(req, found)
            end
        end
    end
    return req
end

local function SlotBISCompleted(slot)
    local req = GetRequiredBISItemsForSlot(slot)
    if #req == 0 then return false end

    if #req == 1 then
        return OwnedCount(req[1]) >= 1
    end

    -- Dual-slot completion: need BOTH BIS items (distinct).
    -- If the row contains only one distinct BIS item, treat as single requirement.
    if req[1] == req[2] then
        return OwnedCount(req[1]) >= 1
    end
    return OwnedCount(req[1]) >= 1 and OwnedCount(req[2]) >= 1
end

local function GetSourceShort(item_id)
    -- Legacy compact helper (zone + boss)
    if not item_id or item_id <= 0 then return "" end
    if _G.BistooltipAddon and _G.BistooltipAddon.GetItemSourceInfo then
        local zone, boss = _G.BistooltipAddon:GetItemSourceInfo(item_id)
        if zone and boss then
            return "|cffcfcfcf" .. tostring(zone) .. "|r\n|cffffd000" .. tostring(boss) .. "|r"
        end
    end
    return ""
end


local function GetChecklistUnderItemText(item_id)
    -- Checklist mode: compact text under icons
    if not item_id or item_id <= 0 then return "" end

    local name, _, quality = GetItemInfo(item_id)
    if not name then
        if QueuePreload then QueuePreload(item_id) end
        name = "Item " .. tostring(item_id)
        quality = 1
    end

    local zone, boss = nil, nil
    if _G.BistooltipAddon and _G.BistooltipAddon.GetItemSourceInfo then
        zone, boss = _G.BistooltipAddon:GetItemSourceInfo(item_id)
    end

    -- Funkcja pomocnicza do bezpiecznego ucinania zbyt długich nazw
    local function smartTrunc(s, limit)
        if not s then return "" end
        if string.len(s) > limit then
            return string.sub(s, 1, limit) .. ".."
        end
        return s
    end

    -- 1. Nazwa przedmiotu (Kolor Jakości)
    local r, g, b = GetItemQualityColor(quality or 1)
    local hexColor = string.format("ff%02x%02x%02x", r*255, g*255, b*255)
    
    -- Ucinamy nazwę trochę mniej agresywnie (do 18 znaków), żeby zmieściła się w kolumnie
    local styledName = "|c" .. hexColor .. smartTrunc(name, 18) .. "|r"

    -- 2. Boss (Szary, mniejszy, pod spodem)
    local styledBoss = ""
    if boss and boss ~= "" then
        -- Bossów ucinamy mocniej, bo są mniej ważni w tym widoku
        styledBoss = "\n|cffaaaaaa" .. smartTrunc(boss, 15) .. "|r"
    end

    return styledName .. styledBoss
end

local function CleanupMainFrame()
    if clearCheckMarks then clearCheckMarks() end
    if clearBoeMarks then clearBoeMarks() end
    ClearSlotRowBackdrops()

    spec_frame = nil
    items = {}
    spells = {}

    DestroyChecklistPanel()

    if mainFrameUISpecialName then
        RemoveFromUISpecialFrames(mainFrameUISpecialName)
        mainFrameUISpecialName = nil
    end

    checklistSummaryLabel = nil
end

-- ============================================================
-- BIS checklist side panel (GRAPHICAL UI)
-- ============================================================
local checklistPanel = nil
local checklistContainer = nil -- Kontener na widgety
mainFrameUISpecialName = nil   -- 
local OpenChecklistExport = nil


local function EnsureChecklistPanel()
    if not main_frame or not main_frame.frame then return end
    if checklistPanel then return end

    -- Główne tło panelu
    checklistPanel = CreateFrame("Frame", "BistooltipChecklistPanel", main_frame.frame)
    checklistPanel:SetPoint("TOPLEFT", main_frame.frame, "TOPRIGHT", 5, 0)
    checklistPanel:SetPoint("BOTTOMLEFT", main_frame.frame, "BOTTOMRIGHT", 5, 0)
    checklistPanel:SetWidth(330) -- Szerokość panelu bocznego
    checklistPanel:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 24,
        insets = { left = 5, right = 5, top = 5, bottom = 5 }
    })
    checklistPanel:Hide()

    -- Tytuł
    local title = checklistPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    title:SetPoint("TOP", 0, -15)
    title:SetText("|cffffd100BIS CHECKLIST|r")


-- Make ESC close this panel before the main window (do not block keybinds / chat)
AddToUISpecialFrames("BistooltipChecklistPanel", mainFrameUISpecialName)

-- Export button (top-right)
local exportBtn = CreateFrame("Button", nil, checklistPanel, "UIPanelButtonTemplate")
exportBtn:SetPoint("TOPRIGHT", -18, -12)
exportBtn:SetSize(80, 22)
exportBtn:SetText("Export")
exportBtn:SetScript("OnClick", function()
    if OpenChecklistExport then OpenChecklistExport() end
end)

checklistPanel:SetScript("OnHide", function()
    if checklistContainer then
        checklistContainer:ReleaseChildren()
    end
end)

    
    -- ScrollFrame (Kontener przewijany)
    checklistContainer = AceGUI:Create("ScrollFrame")
    checklistContainer:SetLayout("List") -- Układ lista pod listą
    checklistContainer:SetWidth(310)
    checklistContainer:SetHeight(0) -- Dopasuje się
    
    -- Musimy ręcznie osadzić ramkę AceGUI w naszym panelu WoW
    checklistContainer.frame:SetParent(checklistPanel)
    checklistContainer.frame:SetPoint("TOPLEFT", 15, -45)
    checklistContainer.frame:SetPoint("BOTTOMRIGHT", -15, 15)
    checklistContainer.frame:Show()

    checklistPanel._container = checklistContainer
end

DestroyChecklistPanel = function()
    if checklistPanel then
        checklistPanel:Hide()
        checklistPanel:SetParent(nil)
    end
    checklistPanel = nil
    checklistContainer = nil
end

local function TruncText(s, maxlen)
    s = s and tostring(s) or ""
    if maxlen and maxlen > 3 and string.len(s) > maxlen then
        return string.sub(s, 1, maxlen - 1) .. "…"
    end
    return s
end

local function ResetFrameDecor(fr)
    if not fr then return end
    if fr.SetBackdrop then
        fr:SetBackdrop(nil)
        if fr.SetBackdropColor then fr:SetBackdropColor(0,0,0,0) end
        if fr.SetBackdropBorderColor then fr:SetBackdropBorderColor(0,0,0,0) end
    end
    if fr.SetClipsChildren then
        fr:SetClipsChildren(false)
    end
end

local clearCheckMarks, clearBoeMarks

local function NewSimpleGroup()
    local g = AceGUI:Create("SimpleGroup")
    if g and g.frame then ResetFrameDecor(g.frame) end
    return g
end



-- ============================================================
-- Slot row backdrop (dark bg + blue border) for checklist mode
-- ============================================================

local slotRowLines = {}

local function ClearSlotRowLines()
    for i = #slotRowLines, 1, -1 do
        local fr = slotRowLines[i]
        if fr then fr:Hide(); fr:SetParent(nil) end
        slotRowLines[i] = nil
    end
end


local slotRowBackdrops = {}

ClearSlotRowBackdrops = function()
    for i = #slotRowBackdrops, 1, -1 do
        local fr = slotRowBackdrops[i]
        if fr then
            fr:Hide()
            fr:SetParent(nil)
        end
        slotRowBackdrops[i] = nil
    end
    ClearSlotRowLines()
end






local function ApplyBlueBoxBackdrop(fr)
    if not fr or not fr.SetBackdrop then return end
    fr:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    fr:SetBackdropColor(0, 0, 0, 0.35)
    fr:SetBackdropBorderColor(0.10, 0.55, 1.00, 0.65)
end

local function CreateSlotRowBackdrop(leftFrame, topBottomFrame, rightFrame)
    if not leftFrame or not rightFrame then return end
    local parent = leftFrame:GetParent()
    if not parent then return end

    local tb = topBottomFrame or rightFrame
    local bg = CreateFrame("Frame", nil, parent)

    bg:SetPoint("LEFT", leftFrame, "LEFT", -6, 0)
    bg:SetPoint("RIGHT", rightFrame, "RIGHT", 6, 0)
    bg:SetPoint("TOP", tb, "TOP", 0, 3)       -- było 6 (wchodziło pod header)
    bg:SetPoint("BOTTOM", tb, "BOTTOM", 0, -3)

    ApplyBlueBoxBackdrop(bg)

    -- FIX: strata taka sama jak wiersz + framelevel możliwie najniżej (ale nie niżej niż parent)
    local pLevel = parent:GetFrameLevel() or 0
    local minLv = nil
    if leftFrame.GetFrameLevel then minLv = leftFrame:GetFrameLevel() end
    if tb and tb.GetFrameLevel then
        local lv = tb:GetFrameLevel()
        minLv = (not minLv or lv < minLv) and lv or minLv
    end
    if rightFrame.GetFrameLevel then
        local lv = rightFrame:GetFrameLevel()
        minLv = (not minLv or lv < minLv) and lv or minLv
    end
    minLv = minLv or (pLevel + 1)

    local ps = (parent.GetFrameStrata and parent:GetFrameStrata()) or "DIALOG"
    local pl = (parent.GetFrameLevel and parent:GetFrameLevel()) or 0
    bg:SetFrameStrata(ps)
    bg:SetFrameLevel(pl + 1)
    bg:SetToplevel(false)
    bg:EnableMouse(false)

    table.insert(slotRowBackdrops, bg)
    return bg
end



local function CreateSlotRowLine(leftFrame, topBottomFrame, rightFrame)
    if not leftFrame or not rightFrame then return end
    local parent = leftFrame:GetParent()
    if not parent then return end

    local tb = topBottomFrame or rightFrame
    if not tb then return end

    local ln = CreateFrame("Frame", nil, parent)
    ln:SetPoint("LEFT", leftFrame, "LEFT", -4, 0)
    ln:SetPoint("RIGHT", rightFrame, "RIGHT", 4, 0)
    ln:SetPoint("TOP", tb, "BOTTOM", 0, -2)
    ln:SetHeight(1)

    local t = ln:CreateTexture(nil, "BACKGROUND")
    t:SetAllPoints()
    t:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
    t:SetVertexColor(0.10, 0.55, 1.00, 0.55)

    local ps = (parent.GetFrameStrata and parent:GetFrameStrata()) or "DIALOG"
    local pl = (parent.GetFrameLevel and parent:GetFrameLevel()) or 0
    ln:SetFrameStrata(ps)
    ln:SetFrameLevel(pl + 1)
    ln:EnableMouse(false)

    table.insert(slotRowLines, ln)
    return ln
end





-- ============================================================
-- Instance difficulty tag (25HM/10N) appended next to boss
-- ============================================================
local function ExtractInstanceDiffTag(zone, boss, diff)
    local src = (diff and diff ~= "" and tostring(diff)) or (tostring(zone or "") .. " " .. tostring(boss or ""))
    local l = string.lower(src)

    local p10 = l:find("10", 1, true)
    local p25 = l:find("25", 1, true)
    if not (p10 or p25) then return "" end

    local size
    if p10 and p25 then
        size = (p10 < p25) and 10 or 25
    else
        size = p25 and 25 or 10
    end

    local mode
    if l:find("heroic", 1, true) or l:find("hard", 1, true) or l:find("hm", 1, true)
       or l:match("10h") or l:match("25h") then
        mode = "HM"
    elseif l:find("normal", 1, true) or l:match("10n") or l:match("25n") then
        mode = "N"
    else
        mode = "N"
    end

    return tostring(size) .. mode -- ex: 25HM / 10N
end


local function _Trim(s)
    s = tostring(s or "")
    s = s:gsub("%s+", " ")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

local function _StripStandaloneSize(s)
    s = tostring(s or "")
    s = s:gsub("%f[%d]10%f[^%d]", " ")
    s = s:gsub("%f[%d]25%f[^%d]", " ")
    return s
end

local function _StripModeWords(s)
    s = tostring(s or "")
    s = s:gsub("[Hh]ard%s*[Mm]ode", " ")
    s = s:gsub("[Hh]eroic", " ")
    s = s:gsub("[Hh]ard", " ")
    s = s:gsub("%f[%a][Hh][Mm]%f[^%a]", " ")
    s = s:gsub("[Nn]ormal", " ")
    return _Trim(s)
end

local function _DetectMode(zone, boss, diff)
    local src = string.lower(tostring(diff or "") .. " " .. tostring(boss or "") .. " " .. tostring(zone or ""))
    if src:find("hard", 1, true) or src:find("heroic", 1, true) or src:find(" hm", 1, true) or src:match("%d+h") or src:find("hc", 1, true) then
        return "HM"
    end
    return "N"
end

local function NormalizeChecklistZone(zone, boss, diff)
    local tag = ExtractInstanceDiffTag(zone, boss, diff) or ""
    local size = tag:match("^(%d+)")
    local base = tostring(zone or "Unknown instance")
    base = base:gsub("%b()", " ")
    base = _StripStandaloneSize(base)
    base = _StripModeWords(base)
    base = _Trim(base)
    if size and size ~= "" then
        return (base ~= "" and (base .. " " .. size) or ("INSTANCE " .. size))
    end
    return (base ~= "" and base or "Unknown instance")
end

local function NormalizeChecklistBoss(zone, boss, diff)
    local mode = _DetectMode(zone, boss, diff)
    local b = tostring(boss or "Unknown boss")
    b = b:gsub("%b()", " ")
    b = _StripStandaloneSize(b)  -- nie rusza XT-002 itd., tylko gołe 10/25
    b = _StripModeWords(b)
    b = _Trim(b)
    if b == "" then b = "Unknown boss" end
    return b, mode
end



local function BuildChecklistGroups()
    -- groups[zoneKey][bossKey] = { boss=..., mode=..., items={} }
    local groups = {}
    local totalMissing = 0

    if not (class and spec and phase) then
        return groups, totalMissing
    end

    local slots = Bistooltip_bislists
        and Bistooltip_bislists[class]
        and Bistooltip_bislists[class][spec]
        and Bistooltip_bislists[class][spec][phase]

    if type(slots) ~= "table" then
        return groups, totalMissing
    end

    for _, slot in ipairs(slots) do
        local req = GetRequiredBISItemsForSlot(slot)
        for _, id in ipairs(req) do
            if id and id > 0 and OwnedCount(id) < 1 then
                totalMissing = totalMissing + 1

                local zone, boss, diff = nil, nil, nil
                if _G.BistooltipAddon and _G.BistooltipAddon.GetItemSourceInfo then
                    zone, boss, diff = _G.BistooltipAddon:GetItemSourceInfo(id)
                end

                local zoneKey = NormalizeChecklistZone(zone, boss, diff)
                local bossBase, mode = NormalizeChecklistBoss(zone, boss, diff)
                local bossKey = bossBase .. "|" .. mode

                groups[zoneKey] = groups[zoneKey] or {}
                groups[zoneKey][bossKey] = groups[zoneKey][bossKey] or { boss = bossBase, mode = mode, items = {} }

                local name = GetItemInfo(id)
                if not name then
                    if QueuePreload then QueuePreload(id) end
                    name = "Item " .. tostring(id)
                end

                table.insert(groups[zoneKey][bossKey].items, {
                    id = id,
                    name = name,
                    slot = slot.slot_name or "",
                })
            end
        end
    end

    -- sort itemów w obrębie bossa
    for _, bosses in pairs(groups) do
        for _, row in pairs(bosses) do
            if row and row.items then
                table.sort(row.items, function(a, b)
                    if a.slot ~= b.slot then return tostring(a.slot) < tostring(b.slot) end
                    return tostring(a.name) < tostring(b.name)
                end)
            end
        end
    end

    return groups, totalMissing
end



-- ============================================================
-- BIS checklist export (copy to clipboard / paste to chat/notes)
-- ============================================================
local exportWindow = nil

local function BuildChecklistExportText()
    local groups, totalMissing = BuildChecklistGroups()
    local className = tostring(class or "?")
    local specName = tostring(spec or "?")
    local phaseName = tostring(phase or "?")

    local lines = {}
    table.insert(lines, "Bis-Tooltip • BIS Checklist export")
    table.insert(lines, string.format("Class/Spec/Phase: %s / %s / %s", className, specName, phaseName))
    table.insert(lines, string.format("Items missing: %d", tonumber(totalMissing) or 0))
    table.insert(lines, " ")

    local zones = {}
    for zone in pairs(groups) do table.insert(zones, zone) end
    table.sort(zones, function(a, b) return tostring(a) < tostring(b) end)

    for _, zone in ipairs(zones) do
        table.insert(lines, tostring(zone))

        local bosses = {}
        for boss in pairs(groups[zone]) do table.insert(bosses, boss) end
        table.sort(bosses, function(a, b) return tostring(a) < tostring(b) end)

        for _, boss in ipairs(bosses) do
            table.insert(lines, "  - " .. tostring(boss))

            local row = groups[zone][boss]
            local its = (row and row.items) or {}

            table.sort(its, function(a, b)
                local sa, sb = tostring(a.slot or ""), tostring(b.slot or "")
                if sa ~= sb then return sa < sb end
                return tostring(a.name or a.id or "") < tostring(b.name or b.id or "")
            end)

            for _, it in ipairs(its) do
                local iid = it.id
                local link = select(2, GetItemInfo(iid))
                local name = link or it.name or ("item:" .. tostring(iid))
                local slot = it.slot and it.slot ~= "" and ("[" .. tostring(it.slot) .. "] ") or ""
                table.insert(lines, string.format("      %s%s (id:%s)", slot, name, tostring(iid)))
            end
        end
        table.insert(lines, " ")
    end

    return table.concat(lines, "\n")
end

local function EnsureExportWindow()
    if exportWindow then
        exportWindow:Show()
        return
    end

    exportWindow = AceGUI:Create("Frame")
    exportWindow:SetTitle("BIS Checklist • Export")
    exportWindow:SetWidth(620)
    exportWindow:SetHeight(460)
    exportWindow:EnableResize(false)
    exportWindow:SetLayout("Fill")

    local exportName = exportWindow.frame and exportWindow.frame.GetName and exportWindow.frame:GetName() or nil
    AddToUISpecialFrames(exportName)

    exportWindow:SetCallback("OnClose", function(widget)
        RemoveFromUISpecialFrames(exportName)
        AceGUI:Release(widget)
        exportWindow = nil
    end)

    local edit = AceGUI:Create("MultiLineEditBox")
    edit:SetLabel("Ctrl+A then Ctrl+C to copy.")
    edit:SetFullWidth(true)
    edit:SetFullHeight(true)
    if edit.DisableButton then edit:DisableButton(true) end
    exportWindow:AddChild(edit)

    exportWindow._edit = edit
end

OpenChecklistExport = function()
    local txt = BuildChecklistExportText()
    EnsureExportWindow()
    if exportWindow and exportWindow._edit then
        exportWindow._edit:SetText(txt or "")
        local eb = exportWindow._edit.editBox
            or (exportWindow._edit.frame and exportWindow._edit.frame.editBox)
            or (exportWindow._edit.frame and exportWindow._edit.frame.scrollFrame and exportWindow._edit.frame.scrollFrame.editBox)
        if eb and eb.SetFocus then
            eb:SetFocus()
            if eb.HighlightText then eb:HighlightText() end
        end
    end
end



-- ============================================================
-- GRAPHICAL CHECKLIST RENDERERS (Modern UI)
-- ============================================================


local function DrawZoneHeaderGUI(container, zoneName)
    local group = NewSimpleGroup()
    group:SetLayout("Flow")
    group:SetFullWidth(true)

    local label = AceGUI:Create("Label")
    label:SetFont("Fonts\\FRIZQT__.TTF", 15, "OUTLINE")
    label:SetText("\n|cffffd100" .. tostring(zoneName or ""):upper() .. "|r")
    label:SetJustifyH("CENTER")
    label:SetFullWidth(true)

    group:AddChild(label)
    container:AddChild(group)
end


-- Rysuje nagłówek bossa (Czerwony, duży, wyśrodkowany)
local function DrawBossHeaderGUI(container, bossName, modeTag)
    local group = NewSimpleGroup()
    group:SetLayout("Flow")
    group:SetFullWidth(true)

    local bossLine = "|cffef5350" .. tostring(bossName or ""):upper() .. "|r"
    if modeTag and modeTag ~= "" then
        bossLine = bossLine .. " |cff90a4ae" .. tostring(modeTag) .. "|r"
    end

    local label = AceGUI:Create("Label")
    label:SetFont("Fonts\\FRIZQT__.TTF", 13, "OUTLINE")
    label:SetText("\n" .. bossLine)
    label:SetJustifyH("CENTER")
    label:SetFullWidth(true)

    group:AddChild(label)
    container:AddChild(group)
end



-- Rysuje wiersz przedmiotu (Ikona po lewej, Schludny tekst po prawej)
local function DrawItemRowGUI(container, item_id, slot_name)
    local row = NewSimpleGroup()
    row:SetLayout("Flow") -- Pozwala układać elementy obok siebie
    row:SetFullWidth(true)
    
    -- 1. Ikona (Duża, wyraźna)
    local icon = AceGUI:Create("Icon")
    icon:SetImageSize(28, 28) -- Zwiększony rozmiar ikony
    icon:SetWidth(34)
    local _, link, quality, _, _, _, _, _, _, texture = GetItemInfo(item_id)
    
    if not texture then
        texture = "Interface\\Icons\\Inv_misc_questionmark"
        if QueuePreload then QueuePreload(item_id) end
    end

    icon:SetImage(texture)
    ForceIconBright(icon)
    
    -- Interakcja: Kliknięcie ikony linkuje przedmiot w czacie
    icon:SetCallback("OnClick", function()
        if link then ChatEdit_InsertLink(link) end
    end)
    -- Tooltip po najechaniu
    icon:SetCallback("OnEnter", function(widget)
        GameTooltip:SetOwner(widget.frame, "ANCHOR_TOPRIGHT")
        if link then
            GameTooltip:SetHyperlink(link)
        else
            TooltipSetItemByID(GameTooltip, item_id)
        end

        GameTooltip:Show()
    end)
    icon:SetCallback("OnLeave", function() GameTooltip:Hide() end)
    
    -- 2. Tekst (Slot na niebiesko, Nazwa w kolorze jakości, ID na szaro)
    -- Używamy InteractiveLabel dla pewności klikalności
    local label = AceGUI:Create("InteractiveLabel") 
    label:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
    
    local itemName = GetItemInfo(item_id) or ("loading " .. item_id)
    
    -- POPRAWKA KOLORÓW: Generujemy hex ręcznie, aby uniknąć błędu "|c|c..."
    local r, g, b = GetItemQualityColor(quality or 1)
    local colorHex = string.format("ff%02x%02x%02x", r * 255, g * 255, b * 255)
    
    -- Formatowanie HTML-like (AceGUI to obsługuje)
    -- Linia 1: [SLOT] (Cyan)
    -- Linia 2: Nazwa Przedmiotu (Kolor Rarity)
    local text = string.format("|cff00ccff[%s]|r\n|c%s%s|r", 
        tostring(slot_name or "?"):upper(),
        colorHex, itemName
    )
    
    label:SetText(text)
    label:SetWidth(240) -- Reszta szerokości dla tekstu
    
    -- Interakcja na tekście też (dla wygody)
    label:SetCallback("OnClick", function() if link then ChatEdit_InsertLink(link) end end)
    label:SetCallback("OnEnter", function(widget)
        GameTooltip:SetOwner(widget.frame, "ANCHOR_TOPRIGHT")
    if link then
        GameTooltip:SetHyperlink(link)
    else
        TooltipSetItemByID(GameTooltip, item_id)
    end

        GameTooltip:Show()
    end)
    label:SetCallback("OnLeave", function() GameTooltip:Hide() end)

    row:AddChild(icon)
    row:AddChild(label)
    
    container:AddChild(row)
end

local function UpdateChecklistPanel()
    if not bisChecklistMode then
        if checklistPanel then checklistPanel:Hide() end
        return
    end
    if not main_frame or not main_frame.frame or not main_frame.frame:IsShown() then return end

    EnsureChecklistPanel()
    if not checklistPanel or not checklistPanel._container then return end
    checklistPanel:Show()
    
    -- Czyścimy stare elementy (ważne przy odświeżaniu!)
    checklistPanel._container:ReleaseChildren()

    local groups, totalMissing = BuildChecklistGroups()

    -- 1. Nagłówek "Missing Items"
    local headerGroup = NewSimpleGroup()
    headerGroup:SetFullWidth(true)
    local headerLbl = AceGUI:Create("Label")
    headerLbl:SetText(string.format("Items Missing: |cffffd100%d|r", totalMissing))
    headerLbl:SetFont("Fonts\\FRIZQT__.TTF", 12)
    headerLbl:SetColor(1,1,1)
    headerLbl:SetJustifyH("CENTER")
    headerGroup:AddChild(headerLbl)
    checklistPanel._container:AddChild(headerGroup)

    local zones = {}
    for z in pairs(groups or {}) do table.insert(zones, z) end
    table.sort(zones)

    for _, z in ipairs(zones) do
    DrawZoneHeaderGUI(checklistPanel._container, z)

    local bossKeys = {}
    for k in pairs(groups[z]) do table.insert(bossKeys, k) end
    table.sort(bossKeys, function(a, b)
        -- HM przed N, potem alfabetycznie po bossie
        local an, am = a:match("^(.-)|(.+)$")
        local bn, bm = b:match("^(.-)|(.+)$")
        if am ~= bm then return am == "HM" end
        return tostring(an) < tostring(bn)
    end)

    for _, bk in ipairs(bossKeys) do
        local row = groups[z][bk]
        DrawBossHeaderGUI(checklistPanel._container, row.boss, row.mode)

        if row and row.items then
            for _, it in ipairs(row.items) do
                DrawItemRowGUI(checklistPanel._container, it.id, it.slot)
            end
        end
    end
end
end

-- Background item preloader (small batch per tick)
local preloadFrame = CreateFrame("Frame")
preloadFrame:Hide()
local preloadQueue = {}
local preloadSeen = {}
local preloadCooldown = 0
local PRELOAD_BATCH = 12
local PRELOAD_INTERVAL = 0.12

QueuePreload = function(item_id)
    if not item_id or item_id <= 0 then return end
    if preloadSeen[item_id] then return end
    preloadSeen[item_id] = true
    table.insert(preloadQueue, item_id)
    preloadFrame:Show()
end

preloadFrame:SetScript("OnUpdate", function(self, elapsed)
    preloadCooldown = (preloadCooldown or 0) - (elapsed or 0)
    if preloadCooldown > 0 then return end
    preloadCooldown = PRELOAD_INTERVAL

    if #preloadQueue == 0 then
        self:Hide()
        return
    end

    -- Use a hidden scanner tooltip to trigger client cache fill in small batches
    if not BistooltipAddon._preloadScanner then
        local tt = CreateFrame("GameTooltip", "BistooltipPreloadScanner", UIParent, "GameTooltipTemplate")
        tt:SetOwner(UIParent, "ANCHOR_NONE")
        tt:Hide()
        BistooltipAddon._preloadScanner = tt
    end
    local scanTT = BistooltipAddon._preloadScanner

    for i = 1, PRELOAD_BATCH do
        local item_id = table.remove(preloadQueue)
        if not item_id then break end
        if not GetItemInfo(item_id) then
            scanTT:SetHyperlink("item:" .. item_id .. ":0:0:0:0:0:0:0")
            scanTT:Hide()
        end
    end

    -- If UI is open, refresh visible rows once cache likely improved
    if main_frame and spec_frame and main_frame.frame:IsShown() then
        drawSpecData()
    end
end)



local function ResetIconFrame(fr)
    if not fr then return end

    if fr._bt_owned_border then fr._bt_owned_border:Hide(); fr._bt_owned_border:SetTexture(nil); fr._bt_owned_border = nil end
    if fr._bt_owned_shadow then fr._bt_owned_shadow:Hide(); fr._bt_owned_shadow:SetTexture(nil); fr._bt_owned_shadow = nil end
    if fr._bt_owned_mark then fr._bt_owned_mark:Hide(); fr._bt_owned_mark:SetTexture(nil); fr._bt_owned_mark = nil end

    if fr._bt_boeMark then fr._bt_boeMark:Hide(); fr._bt_boeMark:SetTexture(nil); fr._bt_boeMark = nil end

    if fr._bt_countText then fr._bt_countText:SetText(""); fr._bt_countText:Hide(); fr._bt_countText = nil end

    -- jeśli gdziekolwiek indziej używasz bazowej ramki:
    if fr._bt_baseBorder then fr._bt_baseBorder:Hide(); fr._bt_baseBorder:SetTexture(nil); fr._bt_baseBorder = nil end
end

-- ============================================================
-- ICON BRIGHTNESS FIX (strata/level + usuwanie tekstur Buttona)
-- ============================================================

local function StripButtonTextures(btn)
    if not btn then return end
    if btn.SetNormalTexture   then btn:SetNormalTexture(nil) end
    if btn.SetPushedTexture   then btn:SetPushedTexture(nil) end
    if btn.SetHighlightTexture then btn:SetHighlightTexture(nil) end
    if btn.SetDisabledTexture then btn:SetDisabledTexture(nil) end
    if btn.SetCheckedTexture  then btn:SetCheckedTexture(nil) end
end

local function RaiseAboveBackdrops(fr)
    if not fr or not fr.GetParent then return end
    local p = fr:GetParent()
    if not p then return end

    local ps = (p.GetFrameStrata and p:GetFrameStrata()) or "DIALOG"
    local pl = (p.GetFrameLevel and p:GetFrameLevel()) or 0

    -- klucz: ikona MUSI mieć tę samą stratę co parent (AceGUI czasem zostawia MEDIUM)
    if fr.SetFrameStrata then fr:SetFrameStrata(ps) end
    if fr.SetFrameLevel  then fr:SetFrameLevel(pl + 60) end -- wysoko ponad boxy/linie
    if fr.SetAlpha       then fr:SetAlpha(1) end
end

ForceIconBright = function(widget)
    if not widget then return end
    local fr = widget.frame

    if fr then
        StripButtonTextures(fr)
        RaiseAboveBackdrops(fr)
    end

    local function fixTex(t)
        if not t then return end
        if t.SetDesaturated then t:SetDesaturated(false) end
        if t.SetVertexColor then t:SetVertexColor(1, 1, 1, 1) end
        if t.SetAlpha then t:SetAlpha(1) end
    end

    -- AceGUI Icon texture
    fixTex(widget.image)

    -- różne backporty / różne pola
    if fr then
        fixTex(fr.icon); fixTex(fr.image); fixTex(fr.Icon); fixTex(fr.texture)
        if fr.GetNormalTexture   then fixTex(fr:GetNormalTexture()) end
        if fr.GetPushedTexture   then fixTex(fr:GetPushedTexture()) end
        if fr.GetDisabledTexture then fixTex(fr:GetDisabledTexture()) end
        if fr.GetHighlightTexture then fixTex(fr:GetHighlightTexture()) end
    end
end



local function createItemFrame(item_id, size, with_checkmark)
    if item_id < 0 then
        return AceGUI:Create("Label")
    end

    local item_frame = AceGUI:Create("Icon")
    item_frame:SetImageSize(size, size)
    ResetIconFrame(item_frame.frame)
    RaiseAboveBackdrops(item_frame.frame)


    if item_frame.frame and item_frame.frame.SetNormalTexture then
    item_frame.frame:SetNormalTexture(nil)
    end
    if item_frame.frame and item_frame.frame.SetPushedTexture then
        item_frame.frame:SetPushedTexture(nil)
    end


    local aliItemID
    if Bistooltip_horde_to_ali then
        aliItemID = Bistooltip_horde_to_ali[item_id]
    end

    if aliItemID then
        item_id = aliItemID
    end

    local itemName, itemLink, _, _, _, _, _, _, _, itemIcon, _, itemType, _, bindType = GetItemInfo(item_id)

    if not itemName then
    item_frame:SetImage("Interface\\Icons\\INV_Misc_QuestionMark")
    ForceIconBright(item_frame)
    QueuePreload(item_id)
    return item_frame
    end

    item_frame:SetImage(itemIcon)
    ForceIconBright(item_frame)
    


if with_checkmark then
    local texCheck  = "Interface\\RaidFrame\\ReadyCheck-Ready"
    local texBorder = "Interface\\Buttons\\UI-ActionButton-Border"
    local markSize  = math.max(18, math.floor(size * 0.60))
    local borderSize = math.floor(size * 1.6)

    local border = item_frame.frame:CreateTexture(nil, "OVERLAY")
    border:SetTexture(texBorder)
    border:SetBlendMode("ADD")
    border:SetPoint("CENTER", item_frame.frame, "CENTER", 0, 0)
    border:SetWidth(borderSize)
    border:SetHeight(borderSize)
    border:SetTexCoord(0.13, 0.87, 0.13, 0.87)

    local shadow = item_frame.frame:CreateTexture(nil, "OVERLAY")
    shadow:SetTexture(texCheck)
    shadow:SetWidth(markSize)
    shadow:SetHeight(markSize)
    shadow:SetPoint("BOTTOMRIGHT", -2, 2)
    shadow:SetVertexColor(0, 0, 0, 0.75)

    local mark = item_frame.frame:CreateTexture(nil, "OVERLAY")
    mark:SetTexture(texCheck)
    mark:SetWidth(markSize)
    mark:SetHeight(markSize)
    mark:SetPoint("BOTTOMRIGHT", -3, 3)

    if with_checkmark == "equipped" then
        mark:SetVertexColor(0.20, 1.00, 0.20, 1.00)
        border:SetVertexColor(0.20, 1.00, 0.20, 0.85)
    else
        mark:SetVertexColor(1.00, 0.85, 0.15, 1.00)
        border:SetVertexColor(1.00, 0.85, 0.15, 0.85)
    end

    -- now store references for ResetIconFrame cleanup
    item_frame.frame._bt_owned_border = border
    item_frame.frame._bt_owned_shadow = shadow
    item_frame.frame._bt_owned_mark   = mark

    table.insert(checkmarks, border)
    table.insert(checkmarks, shadow)
    table.insert(checkmarks, mark)
end



    -- Small stack count overlay for bag copies
    if with_checkmark == "bags" then
        local countText = item_frame.frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        item_frame.frame._bt_countText = countText
        countText:SetPoint("BOTTOMRIGHT", -2, 2)
        countText:SetJustifyH("RIGHT")
        countText:SetTextColor(1, 1, 1, 1)
        countText:SetText("")
        countText._bt_item_id = item_id
        item_frame.frame._bt_countText = countText
    end

    if bindType == 2 then
        local boeMark = item_frame.frame:CreateTexture(nil, "OVERLAY")
        item_frame.frame._bt_boeMark = boeMark
        boeMark:SetWidth(12)
        boeMark:SetHeight(12)
        boeMark:SetPoint("TOPLEFT", 2, -5)
        boeMark:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
        table.insert(boemarks, boeMark)
    end

    item_frame:SetCallback("OnClick", function(button)
        SetItemRef(itemLink, itemLink, "LeftButton")
    end)
    item_frame:SetCallback("OnEnter", function(widget)
        GameTooltip:SetOwner(item_frame.frame, "ANCHOR_NONE")
        GameTooltip:ClearAllPoints()
        GameTooltip:SetPoint("TOPRIGHT", item_frame.frame, "TOPRIGHT", 220, -13)
        GameTooltip:SetHyperlink(itemLink)
    end)
    item_frame:SetCallback("OnLeave", function(widget)
        GameTooltip:Hide()
    end)

    return item_frame
end

local function createSpellFrame(spell_id, size)
    if spell_id < 0 then
        local f = AceGUI:Create("Label")
        return f
    end

    local spell_frame = AceGUI:Create("Icon")
    spell_frame:SetImageSize(size, size)
    RaiseAboveBackdrops(spell_frame.frame)
    

    -- Retrieve spell info directly using GetSpellInfo
    local name, rank, icon, castTime, minRange, maxRange = GetSpellInfo(spell_id)
    if not name then
        print("Failed to retrieve spell info for spell ID:", spell_id)
        return spell_frame
    end

    spell_frame:SetImage(icon)
    ForceIconBright(spell_frame)
    local link = GetSpellLink(spell_id)
    if not link then
        link = "\124cffffd000\124Hspell:" .. spell_id .. "\124h[" .. name .. "]\124h\124r"
    end

    -- Set callbacks for interactivity
    spell_frame:SetCallback("OnClick", function(button)
        SetItemRef(link, link, "LeftButton")
    end)
spell_frame:SetCallback("OnEnter", function(widget)
    GameTooltip:SetOwner(spell_frame.frame, "ANCHOR_NONE")
    GameTooltip:ClearAllPoints()
    GameTooltip:SetPoint("TOPRIGHT", spell_frame.frame, "TOPRIGHT", 220, -13)
    GameTooltip:SetHyperlink(link)
end)

    spell_frame:SetCallback("OnLeave", function(widget)
        GameTooltip:Hide()
    end)

    return spell_frame
end


-- ============================================================
-- Checklist (expanded view) - gem plan extraction (no hardcoding)
-- ============================================================
local ITEM_CLASS_GEM_LOCAL = _G.ITEM_CLASS_GEM or "Gem"
local ITEM_SUBCLASS_GEM_META_LOCAL = _G.ITEM_SUBCLASS_GEM_META or "Meta"

local STAT_MAP = {}
local function _AddStatMap(k, abbr)
    if k and abbr then STAT_MAP[k] = abbr end
end

do
    -- Keys + localized labels
    if _G.ITEM_MOD_SPELL_POWER_SHORT then _AddStatMap("ITEM_MOD_SPELL_POWER_SHORT", "SP"); _AddStatMap(_G.ITEM_MOD_SPELL_POWER_SHORT, "SP") end
    if _G.ITEM_MOD_SPELL_DAMAGE_DONE_SHORT then _AddStatMap("ITEM_MOD_SPELL_DAMAGE_DONE_SHORT", "SP"); _AddStatMap(_G.ITEM_MOD_SPELL_DAMAGE_DONE_SHORT, "SP") end
    if _G.ITEM_MOD_ATTACK_POWER_SHORT then _AddStatMap("ITEM_MOD_ATTACK_POWER_SHORT", "AP"); _AddStatMap(_G.ITEM_MOD_ATTACK_POWER_SHORT, "AP") end
    if _G.ITEM_MOD_CRIT_RATING_SHORT then _AddStatMap("ITEM_MOD_CRIT_RATING_SHORT", "CRIT"); _AddStatMap(_G.ITEM_MOD_CRIT_RATING_SHORT, "CRIT") end
    if _G.ITEM_MOD_HASTE_RATING_SHORT then _AddStatMap("ITEM_MOD_HASTE_RATING_SHORT", "HASTE"); _AddStatMap(_G.ITEM_MOD_HASTE_RATING_SHORT, "HASTE") end
    if _G.ITEM_MOD_HIT_RATING_SHORT then _AddStatMap("ITEM_MOD_HIT_RATING_SHORT", "HIT"); _AddStatMap(_G.ITEM_MOD_HIT_RATING_SHORT, "HIT") end
    if _G.ITEM_MOD_EXPERTISE_RATING_SHORT then _AddStatMap("ITEM_MOD_EXPERTISE_RATING_SHORT", "EXP"); _AddStatMap(_G.ITEM_MOD_EXPERTISE_RATING_SHORT, "EXP") end
    if _G.ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT then _AddStatMap("ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT", "ARP"); _AddStatMap(_G.ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT, "ARP") end
    if _G.ITEM_MOD_STRENGTH_SHORT then _AddStatMap("ITEM_MOD_STRENGTH_SHORT", "STR"); _AddStatMap(_G.ITEM_MOD_STRENGTH_SHORT, "STR") end
    if _G.ITEM_MOD_AGILITY_SHORT then _AddStatMap("ITEM_MOD_AGILITY_SHORT", "AGI"); _AddStatMap(_G.ITEM_MOD_AGILITY_SHORT, "AGI") end
    if _G.ITEM_MOD_INTELLECT_SHORT then _AddStatMap("ITEM_MOD_INTELLECT_SHORT", "INT"); _AddStatMap(_G.ITEM_MOD_INTELLECT_SHORT, "INT") end
    if _G.ITEM_MOD_SPIRIT_SHORT then _AddStatMap("ITEM_MOD_SPIRIT_SHORT", "SPI"); _AddStatMap(_G.ITEM_MOD_SPIRIT_SHORT, "SPI") end
    if _G.ITEM_MOD_STAMINA_SHORT then _AddStatMap("ITEM_MOD_STAMINA_SHORT", "STA"); _AddStatMap(_G.ITEM_MOD_STAMINA_SHORT, "STA") end
    if _G.ITEM_MOD_DEFENSE_SKILL_RATING_SHORT then _AddStatMap("ITEM_MOD_DEFENSE_SKILL_RATING_SHORT", "DEF"); _AddStatMap(_G.ITEM_MOD_DEFENSE_SKILL_RATING_SHORT, "DEF") end
    if _G.ITEM_MOD_DODGE_RATING_SHORT then _AddStatMap("ITEM_MOD_DODGE_RATING_SHORT", "DODGE"); _AddStatMap(_G.ITEM_MOD_DODGE_RATING_SHORT, "DODGE") end
    if _G.ITEM_MOD_PARRY_RATING_SHORT then _AddStatMap("ITEM_MOD_PARRY_RATING_SHORT", "PARRY"); _AddStatMap(_G.ITEM_MOD_PARRY_RATING_SHORT, "PARRY") end
    if _G.ITEM_MOD_BLOCK_RATING_SHORT then _AddStatMap("ITEM_MOD_BLOCK_RATING_SHORT", "BLOCK"); _AddStatMap(_G.ITEM_MOD_BLOCK_RATING_SHORT, "BLOCK") end
    if _G.ITEM_MOD_RESILIENCE_RATING_SHORT then _AddStatMap("ITEM_MOD_RESILIENCE_RATING_SHORT", "RES"); _AddStatMap(_G.ITEM_MOD_RESILIENCE_RATING_SHORT, "RES") end
    if _G.ITEM_MOD_MANA_REGENERATION_SHORT then _AddStatMap("ITEM_MOD_MANA_REGENERATION_SHORT", "MP5"); _AddStatMap(_G.ITEM_MOD_MANA_REGENERATION_SHORT, "MP5") end

    -- Fallback English labels (some servers/locales return these)
    STAT_MAP["Stamina"] = "STA"; STAT_MAP["Intellect"] = "INT"; STAT_MAP["Strength"] = "STR"
    STAT_MAP["Agility"] = "AGI"; STAT_MAP["Spirit"] = "SPI"; STAT_MAP["Spell Power"] = "SP"
    STAT_MAP["Attack Power"] = "AP"; STAT_MAP["Critical Strike Rating"] = "CRIT"; STAT_MAP["Haste Rating"] = "HASTE"
    STAT_MAP["Armor Penetration Rating"] = "ARP"; STAT_MAP["Hit Rating"] = "HIT"; STAT_MAP["Expertise Rating"] = "EXP"
    STAT_MAP["Defense Rating"] = "DEF"
    STAT_MAP["Dodge Rating"] = "DODGE"; STAT_MAP["Parry Rating"] = "PARRY"; STAT_MAP["Block Rating"] = "BLOCK"

end


-- ============================================================
-- HARDCODE: Gem name -> short token (WotLK)
-- (Twoja rozpiska; klucze po EN nazwie gema)
-- ============================================================
local GEM_TOKEN_BY_NAME = {


  -- META (Twoja lista)
  ["chaotic skyflare diamond"] = "21 Crit / 3% Crit Dmg",
  ["relentless earthsiege diamond"] = "21 AGI / 3% Crit Dmg",
  ["austere earthsiege diamond"] = "32 STAM / 2% Armor",
  ["insightful earthsiege diamond"] = "21 INT / Mana Proc",
  ["revitalizing skyflare diamond"] = "11 MP5 / 3% Crit Heal",
  ["ember skyflare diamond"] = "25 SP / 2% INT",
  ["eternal earthsiege diamond"] = "21 Def / 5% Block Val",
  ["trenchant earthsiege diamond"] = "25 SP / -10% Stun",
  ["forlorn skyflare diamond"] = "25 SP / -10% Silence",
  ["enigmatic skyflare diamond"] = "21 Crit / -10% Snare",
  ["destructive skyflare diamond"] = "25 Crit / 1% Reflect",
  ["thundering skyflare diamond"] = "Haste Proc",


  -- RED
  ["bold scarlet ruby"] = "16 STR",
  ["bold cardinal ruby"] = "20 STR",
  ["delicate scarlet ruby"] = "16 AGI",
  ["delicate cardinal ruby"] = "20 AGI",
  ["runed scarlet ruby"] = "19 SP",
  ["runed cardinal ruby"] = "23 SP",
  ["bright scarlet ruby"] = "32 AP",
  ["bright cardinal ruby"] = "40 AP",
  ["fractured scarlet ruby"] = "16 ArP",
  ["fractured cardinal ruby"] = "20 ArP",
  ["precise scarlet ruby"] = "16 Exp",
  ["precise cardinal ruby"] = "20 Exp",
  ["flashing scarlet ruby"] = "16 Parry",
  ["flashing cardinal ruby"] = "20 Parry",

  -- YELLOW
  ["brilliant autumn's glow"] = "16 INT",
  ["brilliant king's amber"] = "20 INT",
  ["rigid autumn's glow"] = "16 Hit",
  ["rigid king's amber"] = "20 Hit",
  ["smooth autumn's glow"] = "16 Crit",
  ["smooth king's amber"] = "20 Crit",
  ["quick autumn's glow"] = "16 Haste",
  ["quick king's amber"] = "20 Haste",
  ["thick autumn's glow"] = "16 Def",
  ["thick king's amber"] = "20 Def",
  ["mystic autumn's glow"] = "16 Resi",
  ["mystic king's amber"] = "20 Resi",

  -- BLUE
  ["solid sky sapphire"] = "24 STAM",
  ["solid majestic zircon"] = "30 STAM",
  ["sparkling sky sapphire"] = "16 SPI",
  ["sparkling majestic zircon"] = "20 SPI",
  ["stormy sky sapphire"] = "20 SpellPen",
  ["stormy majestic zircon"] = "25 SpellPen",

  -- ORANGE
  ["inscribed monarch topaz"] = "8 STR / 8 Crit",
  ["inscribed ametrine"] = "10 STR / 10 Crit",
  ["etched monarch topaz"] = "8 STR / 8 Hit",
  ["etched ametrine"] = "10 STR / 10 Hit",
  ["champion's monarch topaz"] = "8 STR / 8 Def",
  ["champion's ametrine"] = "10 STR / 10 Def",
  ["fierce monarch topaz"] = "8 STR / 8 Haste",
  ["fierce ametrine"] = "10 STR / 10 Haste",
  ["deadly monarch topaz"] = "8 AGI / 8 Crit",
  ["deadly ametrine"] = "10 AGI / 10 Crit",
  ["deft monarch topaz"] = "8 AGI / 8 Haste",
  ["deft ametrine"] = "10 AGI / 10 Haste",
  ["glinting monarch topaz"] = "8 AGI / 8 Hit",
  ["glinting ametrine"] = "10 AGI / 10 Hit",
  ["potent monarch topaz"] = "9 SP / 8 Crit",
  ["potent ametrine"] = "12 SP / 10 Crit",
  ["reckless monarch topaz"] = "9 SP / 8 Haste",
  ["reckless ametrine"] = "12 SP / 10 Haste",
  ["veiled monarch topaz"] = "9 SP / 8 Hit",
  ["veiled ametrine"] = "12 SP / 10 Hit",
  ["luminous monarch topaz"] = "9 SP / 8 INT",
  ["luminous ametrine"] = "12 SP / 10 INT",
  ["durability monarch topaz"] = "9 SP / 8 Resi",
  ["durability ametrine"] = "12 SP / 10 Resi",

  -- PURPLE
  ["sovereign twilight opal"] = "8 STR / 12 STAM",
  ["sovereign dreadstone"] = "10 STR / 15 STAM",
  ["shifting twilight opal"] = "8 AGI / 12 STAM",
  ["shifting dreadstone"] = "10 AGI / 15 STAM",
  ["glowing twilight opal"] = "9 SP / 12 STAM",
  ["glowing dreadstone"] = "12 SP / 15 STAM",
  ["purified twilight opal"] = "9 SP / 8 SPI",
  ["purified dreadstone"] = "12 SP / 10 SPI",
  ["royal twilight opal"] = "9 SP / 4 MP5",
  ["royal dreadstone"] = "12 SP / 5 MP5",
  ["guardian's twilight opal"] = "8 Exp / 12 STAM",
  ["guardian's dreadstone"] = "10 Exp / 15 STAM",
  ["defender's twilight opal"] = "8 Parry / 12 STAM",
  ["defender's dreadstone"] = "10 Parry / 15 STAM",

  -- GREEN
  ["jagged forest emerald"] = "8 Crit / 12 STAM",
  ["jagged eye of zul"] = "10 Crit / 15 STAM",
  ["vivid forest emerald"] = "8 Hit / 12 STAM",
  ["vivid eye of zul"] = "10 Hit / 15 STAM",
  ["enduring forest emerald"] = "8 Def / 12 STAM",
  ["enduring eye of zul"] = "10 Def / 15 STAM",
  ["steady forest emerald"] = "8 Resi / 12 STAM",
  ["steady eye of zul"] = "10 Resi / 15 STAM",
  ["seer's forest emerald"] = "8 INT / 8 SPI",
  ["seer's eye of zul"] = "10 INT / 10 SPI",
  ["dazzling forest emerald"] = "8 INT / 4 MP5",
  ["dazzling eye of zul"] = "10 INT / 5 MP5",
}

local function GetHardcodedGemTokenByName(name)
  if not name or name == "" then return nil end
  local k = tostring(name)
  k = k:gsub("’", "'")              -- normalize apostrophes
  k = k:gsub("\194\160", " ")       -- NBSP
  k = k:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  k = string.lower(k)
  return GEM_TOKEN_BY_NAME[k]
end




local GEM_TOKEN_CACHE = {}

local function _GetGemScanner()
    if _G.BistooltipAddon and _G.BistooltipAddon._btGemScanner then
        return _G.BistooltipAddon._btGemScanner
    end
    local tt = CreateFrame("GameTooltip", "BistooltipGemScanner", UIParent, "GameTooltipTemplate")
    tt:SetOwner(UIParent, "ANCHOR_NONE")
    tt:Hide()
    if _G.BistooltipAddon then
        _G.BistooltipAddon._btGemScanner = tt
    end
    return tt
end

local function _CleanLine(line)
    if not line then return "" end
    line = tostring(line)
    line = line:gsub("|c%x%x%x%x%x%x%x%x", "")
    line = line:gsub("|r", "")
    line = line:gsub("\194\160", " ")
    line = line:gsub("%s+", " ")
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    return line
end

local function _ScanGemExtraText(item_id)
    local name, link = GetItemInfo(item_id)
    if not name then return nil end

    local tt = _GetGemScanner()
    tt:ClearLines()
    tt:SetHyperlink(link or ("item:" .. tostring(item_id) .. ":0:0:0:0:0:0:0"))

    local extras = {}
    local n = tt:NumLines() or 0
    for i = 2, n do
        local fs = _G["BistooltipGemScannerTextLeft" .. i]
        local line = fs and fs.GetText and fs:GetText()
        line = _CleanLine(line)
        if line and line ~= "" then
            local l = string.lower(line)
            local pct = string.match(line, "([%+%-]?%d+)%%")
            if pct then
                if string.find(l, "armor", 1, true) or string.find(l, "pancer", 1, true) or (ARMOR and string.find(l, string.lower(ARMOR), 1, true)) then
                    table.insert(extras, tostring(pct) .. "%ARM")
                end
            end
        end
    end
    if #extras > 0 then
        return table.concat(extras, " ")
    end
    return nil
end

-- Parse numeric gem stats from tooltip lines (fallback when GetItemStats is unavailable)
-- Parse numeric gem stats from tooltip lines (fallback when GetItemStats is unavailable)
local function _ParseGemStatsFromTooltip(item_id)
    if not item_id or item_id <= 0 then return nil end
    local name = GetItemInfo(item_id)
    if not name then
        if QueuePreload then QueuePreload(item_id) end
        return nil
    end

    local tt = _GetGemScanner()
    tt:ClearLines()
    tt:SetHyperlink("item:" .. tostring(item_id) .. ":0:0:0:0:0:0:0")

    local acc = {}
    local n = tt:NumLines() or 0

    local function addStat(stat, v)
        if not stat or not v then return false end
        stat = tostring(stat)

        -- normalize
        stat = stat:gsub("[%(%)]", " ")
        stat = stat:gsub("[%,;%.]", " ")
        stat = stat:gsub("^%s+", ""):gsub("%s+$", "")
        stat = stat:gsub("^and%s+", ""):gsub("^i%s+", "")
        stat = stat:gsub("^your%s+", "")
        stat = stat:gsub("^increases%s+your%s+", "")
        stat = stat:gsub("^increases%s+", "")
        stat = stat:gsub("^improves%s+your%s+", "")
        stat = stat:gsub("^improves%s+", "")
        stat = stat:gsub("^equip:%s*", "")
        stat = stat:gsub("^use:%s*", "")
        stat = stat:gsub("%s+and$", ""):gsub("%s+i$", "")
        stat = stat:gsub("^%s+", ""):gsub("%s+$", "")

        local ab = STAT_MAP[stat]
        if not ab then
            local s2 = stat:gsub("%s+[Rr]ating$", "")
            if s2 ~= stat then ab = STAT_MAP[s2] end
        end
        if ab then
            acc[ab] = (acc[ab] or 0) + v
            return true
        end
        return false
    end

    for i = 2, n do
        local fs = _G["BistooltipGemScannerTextLeft" .. i]
        local line = fs and fs.GetText and fs:GetText()
        line = _CleanLine(line)

        if line and line ~= "" then
            local foundInLine = false

            -- Pattern A: "+10 Strength and +10 Critical Strike Rating"
            for num, stat in line:gmatch("([%+%-]%d+)%s*([^%+%-]+)") do
                local v = tonumber(num)
                if v and addStat(stat, v) then
                    foundInLine = true
                end
            end

            -- Pattern B: "... by 10" (EN) lub "... o 10" (PL)
            if not foundInLine then
                if line:find("by%s+%d+") then
                    for stat, num in line:gmatch("([^%d]+)%s+by%s+(%d+)") do
                        local v = tonumber(num)
                        if v and addStat(stat, v) then
                            foundInLine = true
                        end
                    end
                end

                if (not foundInLine) and (line:find("%so%s+%d+") or line:find("^o%s+%d+")) then
                    for stat, num in line:gmatch("([^%d]+)%s+o%s+(%d+)") do
                        local v = tonumber(num)
                        if v and addStat(stat, v) then
                            foundInLine = true
                        end
                    end
                end
            end
        end -- <- zamyka: if line and line ~= ""
    end -- <- zamyka: for i = 2, n do

    local order = {
        META = 1,
        STR = 2, AGI = 3, INT = 4, SPI = 5, STA = 6,
        SP = 7, AP = 8,
        HIT = 9, CRIT = 10, HASTE = 11, EXP = 12, ARP = 13,
        DEF = 14, DODGE = 15, PARRY = 16, BLOCK = 17,
        MP5 = 18, RES = 19,
    }

    local tmp = {}
    for ab, v in pairs(acc) do
        if v and v ~= 0 then
            table.insert(tmp, { abbr = ab, val = v })
        end
    end

    if #tmp == 0 then
        return nil
    end

    table.sort(tmp, function(a, b)
        return (order[a.abbr] or 99) < (order[b.abbr] or 99)
    end)

    return tmp
end



local function _BuildGemToken(item_id)
    if not item_id or item_id <= 0 then return nil end
    if GEM_TOKEN_CACHE[item_id] ~= nil then return GEM_TOKEN_CACHE[item_id] end

    local name, link, _, _, _, class, subclass = GetItemInfo(item_id)

    -- 0) HARD-CODE: jeśli gem jest na liście, nie skanuj tooltipów
local hard = GetHardcodedGemTokenByName(name)
if hard then
    local token = hard
    if class == ITEM_CLASS_GEM_LOCAL and subclass == ITEM_SUBCLASS_GEM_META_LOCAL then
        token = "META " .. token
    end
    GEM_TOKEN_CACHE[item_id] = token
    return token
end

    if not name then
        if QueuePreload then QueuePreload(item_id) end
        return nil
    end

    local acc = {}

    -- Primary: GetItemStats (fast, locale-independent keys)
    if _G.GetItemStats then
        local stats = GetItemStats(link or ("item:" .. tostring(item_id) .. ":0:0:0:0:0:0:0"))
        if type(stats) == "table" then
            for k, v in pairs(stats) do
                if v and v ~= 0 then
                    local ab = STAT_MAP[k]
                    if not ab and type(k) == "string" then
                        local g = _G[k]
                        if type(g) == "string" then
                            ab = STAT_MAP[g]
                        end
                    end
                    if ab then
                        acc[ab] = (acc[ab] or 0) + v
                    end
                end
            end
        end
    end

    -- Fallback: parse tooltip numeric lines when stats table is empty/unavailable
    if not next(acc) then
        local tmp = _ParseGemStatsFromTooltip(item_id)
        if tmp then
            for _, x in ipairs(tmp) do
                acc[x.abbr] = (acc[x.abbr] or 0) + (x.val or 0)
            end
        end
    end

    -- Build ordered parts
    local parts = {}
    if next(acc) then
        local order = {
            STR = 1, AGI = 2, STA = 3, INT = 4, SPI = 5,
            SP = 6, AP = 7,
            HIT = 8, CRIT = 9, HASTE = 10, EXP = 11, ARP = 12,
            DEF = 13, DODGE = 14, PARRY = 15, BLOCK = 16,
            MP5 = 17, RES = 18,
        }
        local tmp = {}
        for ab, v in pairs(acc) do
            if v and v ~= 0 then
                table.insert(tmp, { abbr = ab, val = v })
            end
        end
        table.sort(tmp, function(a, b)
            return (order[a.abbr] or 99) < (order[b.abbr] or 99)
        end)
        for _, x in ipairs(tmp) do
            -- ensure integer-ish formatting
            local vv = x.val
            if type(vv) == "number" and vv == math.floor(vv) then
                table.insert(parts, tostring(vv) .. x.abbr)
            else
                table.insert(parts, string.format("%s %s", tostring(vv), x.abbr))
            end
        end
    end

    -- Extra percent-style meta effects (e.g. +2% armor)
    local extra = _ScanGemExtraText(item_id)
    if extra and extra ~= "" then
        table.insert(parts, extra)
    end

local token = table.concat(parts, "/")
if token == "" then
    -- fallback: zamiast "?" pokaż krótką nazwę gema
    local short = tostring(name or "")
    short = short:gsub("%b()", " ")
    short = short:gsub("%s+[Gg]em$", "")
    short = short:gsub("%s+", " ")
    short = short:gsub("^%s+", ""):gsub("%s+$", "")
    short = TruncText(short, 14)
    token = (short ~= "" and short) or "?"
end

if class == ITEM_CLASS_GEM_LOCAL and subclass == ITEM_SUBCLASS_GEM_META_LOCAL then
    token = "META " .. token
end


    GEM_TOKEN_CACHE[item_id] = token
    return token
end

local function CollectGemIdsFromEnhancements(enhs)
    local out = {}
    if type(enhs) ~= "table" then return out end

    for _, e in ipairs(enhs) do
        if e and e.type == "item" and e.id and e.id > 0 then
            local name, _, _, _, _, class = GetItemInfo(e.id)
            if not name then
                if QueuePreload then QueuePreload(e.id) end
                -- Keep a placeholder candidate; will resolve once cached
                table.insert(out, e.id)
            elseif class == ITEM_CLASS_GEM_LOCAL then
                table.insert(out, e.id)
            end
        end
    end

    -- Filter non-gems once cached (second pass)
    local filtered = {}
    for _, id in ipairs(out) do
        local name, _, _, _, _, class = GetItemInfo(id)
        if not name then
            table.insert(filtered, id)
        elseif class == ITEM_CLASS_GEM_LOCAL then
            table.insert(filtered, id)
        end
    end

    while #filtered > 3 do table.remove(filtered) end
    return filtered
end

local function BuildGemPlanText(gemIds)
    if not gemIds or #gemIds == 0 then return "" end

    local tokens = {}
    for _, id in ipairs(gemIds) do
        local t = _BuildGemToken(id)
        if not t or t == "" then t = "..." end
        if t ~= "" then
            table.insert(tokens, t)
        end
    end

    if #tokens == 0 then return "" end
    return table.concat(tokens, " · " )
end

local function createGemGridFrame(gemIds)
    local g = NewSimpleGroup()
    g:SetLayout("Table")
    g:SetWidth(30)
    g:SetHeight(40)
    g:SetAutoAdjustHeight(false)
    g:SetUserData("table", {
        columns = { { width = 14 }, { width = 14 } },
        spaceV = -6,
        spaceH = 0,
        align = "TOPLEFT",
    })

    for i = 1, 4 do
        local id = gemIds and gemIds[i]
        if id then
            g:AddChild(createItemFrame(id, 14))
        else
            g:AddChild(AceGUI:Create("Label"))
        end
    end

    return g
end

local function createItemWithGemsFrame(item_id, gemIds, ownedState, ownedCount)
    local grp = NewSimpleGroup()
    grp:SetLayout("Table")
    grp:SetWidth(104)
    grp:SetHeight(40)
    grp:SetAutoAdjustHeight(false)
    grp:SetUserData("table", {
        columns = { { width = 40 }, { width = 32 } },
        spaceH = 2,
        spaceV = 0,
        align = "middle",
    })

    local w = createItemFrame(item_id, 40, ownedState)
    if w and w.frame and w.frame._bt_countText then
        if ownedState == "bags" and ownedCount and ownedCount > 1 then
            w.frame._bt_countText:SetText(ownedCount)
        else
            w.frame._bt_countText:SetText("")
        end
    end

    grp:AddChild(w)
    grp:AddChild(createGemGridFrame(gemIds))
    return grp
end

local function createGemStripFrame(gemIds)
    local g = NewSimpleGroup()
    g:SetLayout("Table")
    g:SetAutoAdjustHeight(false)
    g:SetHeight(18)
    g:SetWidth(56)
    g:SetUserData("table", {
        columns = { { width = 18 }, { width = 18 }, { width = 18 } },
        spaceH = 1,
        spaceV = 0,
        align = "LEFT",
    })

    for i = 1, 3 do
        local id = gemIds and gemIds[i]
        if id then
            g:AddChild(createItemFrame(id, 16))
        else
            local l = AceGUI:Create("Label")
            l:SetText(" ")
            g:AddChild(l)
        end
    end
    return g
end


local function DrawGemPlanRow(gemIds)
    if not gemIds or #gemIds == 0 then return end

    -- tekst robimy krótki (żeby nie rozjeżdżało wiersza)
    local txt = BuildGemPlanText(gemIds)
    if txt and txt ~= "" then
        txt = TruncText(txt, 64)
    else
        txt = ""
    end

    -- kol 1-2: puste (wyrównanie do tabeli)
    local e1 = AceGUI:Create("Label"); e1:SetText(" ")
    local e2 = AceGUI:Create("Label"); e2:SetText(" ")
    spec_frame:AddChild(e1)
    spec_frame:AddChild(e2)

    -- kol 3-8: gem plan (colspan 6)
    local box = NewSimpleGroup()
    box:SetLayout("Table")
    box:SetAutoAdjustHeight(false)
    box:SetHeight(24)
    box:SetUserData("cell", { colspan = 6 })
    box:SetUserData("table", {
        columns = { { width = 62 }, { weight = 1 } },
        spaceH = 6,
        spaceV = 0,
        align = "middle",
    })

    -- delikatne tło + niebieski border (lżejszy niż boxy slotów)
    box.frame:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    box.frame:SetBackdropColor(0, 0, 0, 0.22)
    box.frame:SetBackdropBorderColor(0.10, 0.55, 1.00, 0.45)

    -- ikonki gemów
    local gems = createGemStripFrame(gemIds)
    box:AddChild(gems)

    -- krótki opis
    local lbl = AceGUI:Create("Label")
    lbl:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    lbl:SetJustifyH("LEFT")
    lbl:SetText(txt ~= "" and ("|cff55aaffGems:|r " .. txt) or "|cff55aaffGems:|r")
    if lbl.label and lbl.label.SetWordWrap then
        lbl.label:SetWordWrap(false)
    end
    box:AddChild(lbl)

    -- cleanup (żeby nie zostawały backdroppy)
    do
        local orig = box.OnRelease
        box.OnRelease = function(w)
            if w and w.frame then ResetFrameDecor(w.frame) end
            if orig then orig(w) end
        end
    end

    spec_frame:AddChild(box)
end



local function CreateBossItemInfoFrame(slot)
    local group = NewSimpleGroup()
    group:SetLayout("List")
    group:SetAutoAdjustHeight(false)
    group:SetHeight(34)

    local item_id = slot and slot[1]
    local bossText = ""
    local itemName = ""

    if item_id and item_id > 0 then
        local name = GetItemInfo(item_id)
        if not name then
            if QueuePreload then QueuePreload(item_id) end
            name = "Item " .. tostring(item_id)
        end
        itemName = TruncText(name, 24)

        if _G.BistooltipAddon and _G.BistooltipAddon.GetItemSourceInfo then
            local zone, b, diff = _G.BistooltipAddon:GetItemSourceInfo(item_id)
            if b and b ~= "" then
                local tag = ExtractInstanceDiffTag(zone, b, diff)
                if tag ~= "" then
                    local maxLen = 18
                    local keep = maxLen - (#tag) - 1
                    if keep < 4 then keep = 4 end
                    bossText = "|cffffd200" .. TruncText(b, keep) .. "|r |cff90a4ae" .. tag .. "|r"
                else
                    bossText = "|cffffd200" .. TruncText(b, 18) .. "|r"
                end
            end
        end
    end

    local bossLbl = AceGUI:Create("Label")
    bossLbl:SetFullWidth(true)
    bossLbl:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
    bossLbl:SetJustifyH("LEFT")
    bossLbl:SetText(bossText ~= "" and bossText or " ")
    group:AddChild(bossLbl)

    local itemLbl = AceGUI:Create("Label")
    itemLbl:SetFullWidth(true)
    itemLbl:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
    itemLbl:SetJustifyH("LEFT")
    itemLbl:SetText(itemName ~= "" and ("|cffff4040" .. itemName .. "|r") or " ")
    group:AddChild(itemLbl)

    return group
end





local function createEnhancementsFrame(enhancements)
    -- Compact 2x3 grid (6 slots) that never overflows its cell
    local frame = NewSimpleGroup()
    frame:SetLayout("Table")
    frame:SetWidth(40)
    frame:SetHeight(40)
    frame:SetAutoAdjustHeight(false)
    frame:SetUserData("table", {
        columns = { { width = 16 }, { width = 16 } },
        spaceV = -6,
        spaceH = 0,
        align = "TOPLEFT",
    })

    local count = 0
    if type(enhancements) == "table" then
        for _, enhancement in ipairs(enhancements) do
            local size = 16
            if enhancement and enhancement.type == "none" then
                frame:AddChild(createItemFrame(-1, size))
            elseif enhancement and enhancement.type == "item" then
                frame:AddChild(createItemFrame(enhancement.id, size))
            elseif enhancement and enhancement.type == "spell" then
                frame:AddChild(createSpellFrame(enhancement.id, size))
            else
                frame:AddChild(AceGUI:Create("Label"))
            end
            count = count + 1
            if count >= 6 then break end
        end
    end

    -- Fill remaining cells so height stays stable
    for _ = count + 1, 6 do
        frame:AddChild(AceGUI:Create("Label"))
    end

    return frame
end


local function drawItemSlot(slot)
    -- col 1: Slot name
    local slotLbl = AceGUI:Create("Label")
    slotLbl:SetText(slot.slot_name)
    slotLbl:SetFont("Fonts\\FRIZQT__.TTF", 14, "")
    spec_frame:AddChild(slotLbl)

    local rowLeftFrame = slotLbl.frame
    local rowTopBottomFrame = nil
    local rowRightFrame = nil

    local gemIds = nil

    -- col 2: Plan (checklist) OR enhancements (normal)
    if bisChecklistMode then
        local plan = CreateBossItemInfoFrame(slot)
        spec_frame:AddChild(plan)
        gemIds = CollectGemIdsFromEnhancements(slot.enhs) -- zostaje (jakbyś chciał przywrócić Gems row)
    else
        local enh = createEnhancementsFrame(slot.enhs)
        spec_frame:AddChild(enh)
    end

    -- cols 3-8: Top items (always exactly 6 cells)
    for i = 1, 6 do
        local original_item_id = slot[i]
        local w

        if not original_item_id then
            w = AceGUI:Create("Label")
            w:SetText(" ")
            spec_frame:AddChild(w)
        else
            local item_id = original_item_id
            if isHorde and Bistooltip_horde_to_ali then
                local translated_item_id = Bistooltip_horde_to_ali[original_item_id]
                if translated_item_id then item_id = translated_item_id end
            end

            local owned = GetOwnedRow(item_id)
            local ownedState = nil
            local ownedCount = 0
            if owned then
                local bags = owned.bags or 0
                local eq = owned.equipped or 0
                if eq > 0 then
                    ownedState = "equipped"
                elseif bags > 0 then
                    ownedState = "bags"
                    ownedCount = bags
                end
            end

            if showOnlyMissing and ownedState then
                w = AceGUI:Create("Label")
                w:SetText(" ")
                spec_frame:AddChild(w)
            else
                w = createItemFrame(item_id, 40, ownedState)
                if w and w.frame and w.frame._bt_countText then
                    if ownedState == "bags" and ownedCount and ownedCount > 1 then
                        w.frame._bt_countText:SetText(ownedCount)
                    else
                        w.frame._bt_countText:SetText("")
                    end
                end
                spec_frame:AddChild(w)
            end
        end

        if w and w.frame then
            if not rowTopBottomFrame then rowTopBottomFrame = w.frame end -- bierzemy wysokość ikon
            rowRightFrame = w.frame
        end
    end

    -- Checklist: frame around the whole slot row (instead of extra "Gems:" row)
if bisChecklistMode then
    CreateSlotRowBackdrop(rowLeftFrame, rowTopBottomFrame, rowRightFrame)
    DrawGemPlanRow(gemIds) -- PRZYWRÓCONE: gem plan pod itemami
else
    -- zawsze 1 niebieska linia pod rzędem (pomoc wizualna)
    CreateSlotRowLine(rowLeftFrame, rowTopBottomFrame, rowRightFrame)
end
end


local function saveData()
    BistooltipAddon.db.char.class_index = class_index
    BistooltipAddon.db.char.spec_index = spec_index
    BistooltipAddon.db.char.phase_index = phase_index
end

clearCheckMarks = function()
    for _, value in ipairs(checkmarks) do
        if value and value.SetTexture then value:SetTexture(nil) end
    end
    checkmarks = {}
end

clearBoeMarks = function()
    for _, value in ipairs(boemarks) do
        if value and value.SetTexture then value:SetTexture(nil) end
    end
    boemarks = {}
end


-- ============================================================
-- Table header (was missing -> caused nil call)
-- ============================================================
drawTableHeader = _G.drawTableHeader -- if something else already provided it

if not drawTableHeader then
    drawTableHeader = function(container)
        if not container or not container.AddChild then return end

        local function Header(text, fontSize, justify)
            local lbl = AceGUI:Create("Label")
            lbl:SetText(text or " ")
            lbl:SetFont("Fonts\\FRIZQT__.TTF", fontSize or 12, "OUTLINE")
            lbl:SetColor(1, 0.82, 0, 1) -- gold-ish
            lbl:SetJustifyH(justify or "CENTER")
            lbl:SetJustifyV("MIDDLE")
            if lbl.label and lbl.label.SetWordWrap then
                lbl.label:SetWordWrap(false)
            end
            return lbl
        end

        local col2 = bisChecklistMode and "Plan" or "Enhs"
        local headers = { "Slot", col2, "BIS", "BIS2", "ALT", "ALT2", "ALT3", "ALT4" }

        -- 8 columns exactly (matches SPEC_TABLE_* layouts)
        for i = 1, 8 do
            local h = Header(headers[i], (i == 2 and not bisChecklistMode) and 10 or 12, i == 1 and "LEFT" or "CENTER")
            container:AddChild(h)
        end
    end

    -- keep compatibility with older code expecting global
    _G.drawTableHeader = drawTableHeader
end


local function AddHeaderBreathingRoom(container)
    if not container or not container.AddChild then return end
    for i = 1, 8 do
        local l = AceGUI:Create("Label")
        l:SetText(" ")
        if l.frame then l.frame:SetHeight(10) end
        container:AddChild(l)
    end
end



drawSpecData = function()
    clearCheckMarks()
    clearBoeMarks()
    ClearSlotRowBackdrops() 
    saveData()
    items = {}
    spells = {}
    spec_frame:ReleaseChildren()
    ApplySpecTable()
    drawTableHeader(spec_frame)
    AddHeaderBreathingRoom(spec_frame)

    if not spec or not phase then
        return
    end
    local slots = Bistooltip_bislists[class][spec][phase]
    if not slots then return end

    local function rowMatches(slot)
        if not searchTextLower or searchTextLower == "" then return true end
        -- match slot name
        if slot.slot_name and string.find(string.lower(slot.slot_name), searchTextLower, 1, true) then
            return true
        end
        -- match item id or cached item names
        for _, iid in ipairs(slot) do
            local id = iid
            if isHorde and Bistooltip_horde_to_ali and Bistooltip_horde_to_ali[iid] then
                id = Bistooltip_horde_to_ali[iid]
            end
            if tostring(id) == searchTextLower then
                return true
            end
            local name = GetItemInfo(id)
            if name and string.find(string.lower(name), searchTextLower, 1, true) then
                return true
            elseif not name then
                QueuePreload(id)
            end
        end
        return false
    end

    for i, slot in ipairs(slots) do
        if rowMatches(slot) then
            if bisChecklistMode and SlotBISCompleted(slot) then
                -- Slot is already completed (BIS owned) -> hide the whole line in checklist mode
            else
                drawItemSlot(slot)

                -- Build "targets to snipe" summary (missing BIS items only)
                if bisChecklistMode and checklistSummaryLabel then
                    checklistSummaryLabel._bt_targets = checklistSummaryLabel._bt_targets or {}
                    checklistSummaryLabel._bt_unknown = checklistSummaryLabel._bt_unknown or {}

                    local function addTarget(item_id)
                        if not item_id or item_id <= 0 then return end
                        if _G.BistooltipAddon and _G.BistooltipAddon.GetItemSourceInfo then
                            local zone, boss = _G.BistooltipAddon:GetItemSourceInfo(item_id)
                            if zone and boss then
                                local tz = checklistSummaryLabel._bt_targets
                                tz[zone] = tz[zone] or {}
                                local tb = tz[zone][boss]
                                if not tb then
                                    tb = { count = 0 }
                                    tz[zone][boss] = tb
                                end
                                tb.count = (tb.count or 0) + 1
                                return
                            end
                        end
                        checklistSummaryLabel._bt_unknown[item_id] = true
                    end

                    local req = GetRequiredBISItemsForSlot(slot)
                    if #req == 1 then
                        if OwnedCount(req[1]) < 1 then addTarget(req[1]) end
                    elseif #req >= 2 then
                        if req[1] == req[2] then
                            if OwnedCount(req[1]) < 2 then addTarget(req[1]) end
                        else
                            if OwnedCount(req[1]) < 1 then addTarget(req[1]) end
                            if OwnedCount(req[2]) < 1 then addTarget(req[2]) end
                        end
                    end
                end
            end
        end
    end

    -- Render checklist hint (full detail is in side panel)
    if checklistSummaryLabel then
        if not bisChecklistMode then
            checklistSummaryLabel:SetText("")
        else
            checklistSummaryLabel:SetText("|cffffff00BIS checklist|r: Boss/Item + gem plan are shown in the table. Full missing list is on the right panel.")
        end
        checklistSummaryLabel._bt_targets = nil
        checklistSummaryLabel._bt_unknown = nil
    end

    -- Update checklist side panel
    UpdateChecklistPanel()
end




local function buildClassDict()
    class_options = {}
    class_options_to_class = {}

    -- Prefer explicit Bistooltip_classes (if present & populated)
    if Bistooltip_classes and type(Bistooltip_classes) == "table" and #Bistooltip_classes > 0 then
        for ci, class in ipairs(Bistooltip_classes) do
            local option_name = ColorizeClassOption(class.name)
            table.insert(class_options, option_name)
            class_options_to_class[option_name] = { name = class.name, i = ci }
        end
        return
    end

    -- Fallback: build from spec icons + optional index order
    local ordered = {}
    if Bistooltip_classes_indexes then
        for cname, idx in pairs(Bistooltip_classes_indexes) do ordered[idx] = cname end
    end
    if #ordered == 0 and Bistooltip_spec_icons then
        for cname, _ in pairs(Bistooltip_spec_icons) do table.insert(ordered, cname) end
        table.sort(ordered)
    end

    local ci = 1
    for _, cname in ipairs(ordered) do
        local option_name = ColorizeClassOption(cname)
        table.insert(class_options, option_name)
        class_options_to_class[option_name] = { name = cname, i = ci }
        ci = ci + 1
    end
end



local function buildSpecsDict(class_i)
    spec_options = {}
    spec_options_to_spec = {}

    -- If we have Bistooltip_classes, use its spec ordering (preferred)
    if Bistooltip_classes and type(Bistooltip_classes) == "table" and #Bistooltip_classes > 0 then
        local cls = Bistooltip_classes[class_i]
        if not cls or not cls.specs then return end

        for _, specName in ipairs(cls.specs) do
            local icon = nil
            if Bistooltip_spec_icons and Bistooltip_spec_icons[cls.name] then
                icon = Bistooltip_spec_icons[cls.name][specName]
            end

            local option_name = icon and ("|T" .. icon .. ":14|t " .. specName) or specName
            table.insert(spec_options, option_name)
            spec_options_to_spec[option_name] = specName
        end
        return
    end

    -- Fallback: build from bislists keys (alphabetical)
    local clsName = class_options_to_class[class_options[class_i]] and class_options_to_class[class_options[class_i]].name
    if not clsName or not Bistooltip_wowtbc_bislists or not Bistooltip_wowtbc_bislists[clsName] then return end

    local specs = {}
    for sname, _ in pairs(Bistooltip_wowtbc_bislists[clsName]) do
        table.insert(specs, sname)
    end
    table.sort(specs)

    for _, sname in ipairs(specs) do
        table.insert(spec_options, sname)
        spec_options_to_spec[sname] = sname
    end
end

local function loadData()
    class_index = BistooltipAddon.db.char.class_index
    spec_index  = BistooltipAddon.db.char.spec_index
    phase_index = BistooltipAddon.db.char.phase_index

    if not class_index or not class_options[class_index] then class_index = 1 end
    class = class_options_to_class[class_options[class_index]].name
    buildSpecsDict(class_index)

    if not spec_index or not spec_options[spec_index] then spec_index = 1 end
    spec = spec_options_to_spec[spec_options[spec_index]]

    if not phase_index or not Bistooltip_phases[phase_index] then phase_index = 1 end
    phase = Bistooltip_phases[phase_index]
end


local function drawDropdowns()
    local dropDownGroup = NewSimpleGroup()

    dropDownGroup:SetLayout("Table")
    dropDownGroup:SetUserData("table", {
        columns = {110, 180, 70},
        space = 1,
        align = "BOTTOMRIGHT"
    })
    main_frame:AddChild(dropDownGroup)

    classDropdown = AceGUI:Create("Dropdown")
    specDropdown = AceGUI:Create("Dropdown")
    phaseDropDown = AceGUI:Create("Dropdown")
    specDropdown:SetDisabled(true)

    phaseDropDown:SetCallback("OnValueChanged", function(_, _, key)
        phase_index = key
        phase = Bistooltip_phases[key]
        drawSpecData()
    end)

    specDropdown:SetCallback("OnValueChanged", function(_, _, key)
        spec_index = key
        spec = spec_options_to_spec[spec_options[key]]
        drawSpecData()
    end)

    classDropdown:SetCallback("OnValueChanged", function(_, _, key)
        class_index = key
        class = class_options_to_class[class_options[key]].name

        specDropdown:SetDisabled(false)
        buildSpecsDict(key)
        specDropdown:SetList(spec_options)
        specDropdown:SetValue(1)
        spec_index = 1
        spec = spec_options_to_spec[spec_options[1]]
        drawSpecData()
    end)

    classDropdown:SetList(class_options)
    phaseDropDown:SetList(Bistooltip_phases)

    dropDownGroup:AddChild(classDropdown)
    dropDownGroup:AddChild(specDropdown)
    dropDownGroup:AddChild(phaseDropDown)

    local fillerFrame = AceGUI:Create("Label")
    fillerFrame:SetText(" ")
    main_frame:AddChild(fillerFrame)

    classDropdown:SetValue(class_index)
    if (class_index) then
        buildSpecsDict(class_index)
        specDropdown:SetList(spec_options)
        specDropdown:SetDisabled(false)
    end
    specDropdown:SetValue(spec_index)
    phaseDropDown:SetValue(phase_index)
end

local function createSpecFrame()
    local frame = AceGUI:Create("ScrollFrame")
    frame:SetLayout("Table")
    frame:SetUserData("table", bisChecklistMode and SPEC_TABLE_CHECKLIST or SPEC_TABLE_DEFAULT)
    frame:SetFullWidth(true)
    frame:SetHeight(370)
    frame:SetAutoAdjustHeight(false)
    main_frame:AddChild(frame)
    spec_frame = frame
end

function BistooltipAddon:reloadData()
    buildClassDict()
    class_index = BistooltipAddon.db.char.class_index
    spec_index = BistooltipAddon.db.char.spec_index
    phase_index = BistooltipAddon.db.char.phase_index

    if not class_index or not class_options[class_index] then class_index = 1 end
    class = class_options_to_class[class_options[class_index]].name
    buildSpecsDict(class_index)
    if not spec_index or not spec_options[spec_index] then spec_index = 1 end
    spec = spec_options_to_spec[spec_options[spec_index]]
    if not phase_index or not Bistooltip_phases[phase_index] then phase_index = 1 end
    phase = Bistooltip_phases[phase_index]

    if main_frame then
        phaseDropDown:SetList(Bistooltip_phases)
        classDropdown:SetList(class_options)
        specDropdown:SetList(spec_options)

        classDropdown:SetValue(class_index)
        specDropdown:SetValue(spec_index)
        phaseDropDown:SetValue(phase_index)

        drawSpecData()
        main_frame:SetStatusText(Bistooltip_source_to_url[BistooltipAddon.db.char["data_source"]])
    end

    -- Refresh owned-item cache once (do NOT trigger continuous scans)
    if BistooltipAddon.ScanEquipment then
        BistooltipAddon:ScanEquipment(true)
    end
end

function BistooltipAddon:OpenDiscordLink()
    BistooltipAddon:closeMainFrame()
    StaticPopup_Show("DISCORD_LINK_DIALOG")
    StaticPopupDialogs["DISCORD_LINK_DIALOG"].preferredIndex = 4
end

StaticPopupDialogs["DISCORD_LINK_DIALOG"] = {
    text = "Join our Discord",
    button1 = "Copy Link",
    button2 = "Close",
    OnShow = function(self)
        self.editBox:SetText("https://discord.gg/Xk8BKqSapd")
        self.editBox:SetFocus()
        self.editBox:HighlightText()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 4,
    hasEditBox = true,
    EditBoxOnEscapePressed = function(self)
        self:GetParent():Hide()
    end,
    EditBoxOnEnterPressed = function(self)
        self:GetParent().button1:Click()
    end,
    OnHide = function(self)
        self.data = nil
    end,
    EditBoxOnTextChanged = function(self, userInput)
        if userInput then
            self:SetText(self.data)
            self:HighlightText()
        end
    end,
    OnAccept = function(self)
        -- On 3.3.5, EditBox:CopyText() may not exist. Keep text highlighted for Ctrl+C.
        self.editBox:SetFocus()
        self.editBox:HighlightText()
    end,
    OnCancel = function(self)
        self:Hide()
    end
}

function BistooltipAddon:initBislists()
    buildClassDict()
    loadData()
    LibStub("AceConsole-3.0"):RegisterChatCommand("bistooltip", function()
        BistooltipAddon:createMainFrame()
    end, persist)
end



function BistooltipAddon:createMainFrame()
    -- Toggle behavior:
    --  - if window exists but is hidden (e.g. closed via ESC), show it again
    --  - otherwise, close (release) it
    if main_frame then
        if main_frame.frame and not main_frame.frame:IsShown() then
            main_frame.frame:Show()
            -- If checklist mode is enabled, refresh the right panel
            if BistooltipAddon and BistooltipAddon.db and BistooltipAddon.db.char and BistooltipAddon.db.char.bis_checklist then
                UpdateChecklistPanel()
            end
            return
        end
        BistooltipAddon:closeMainFrame()
        return
    end

    -- Restore UI modes from saved variables (if present)
    if BistooltipAddon and BistooltipAddon.db and BistooltipAddon.db.char then
        if BistooltipAddon.db.char.bis_checklist ~= nil then
            bisChecklistMode = BistooltipAddon.db.char.bis_checklist and true or false
        end
    end

    main_frame = AceGUI:Create("Frame")
    main_frame:SetWidth(520)
    main_frame:SetHeight(640)

    main_frame.frame:SetMinResize(480, 360)
    main_frame.frame:SetMaxResize(1000, 800)


-- Allow ESC to close without stealing ENTER/chat or keybinds.
-- Checklist panel is also added to UISpecialFrames (and placed before the main window).
mainFrameUISpecialName = main_frame.frame and main_frame.frame.GetName and main_frame.frame:GetName() or nil
AddToUISpecialFrames(mainFrameUISpecialName)


    local statusFrame = nil

    main_frame:SetCallback("OnClose", function(widget)
        if statusFrame then
            statusFrame:SetScript("OnUpdate", nil)
            statusFrame = nil
        end

        CleanupMainFrame()
        AceGUI:Release(widget)
        main_frame = nil
    end)

    main_frame:SetLayout("List")
    main_frame:SetTitle(BistooltipAddon.AddonNameAndVersion)
    main_frame:SetStatusText(Bistooltip_source_to_url[BistooltipAddon.db.char["data_source"]])

    drawDropdowns()
    createSpecFrame()

    -- Search + filters
    local searchGroup = NewSimpleGroup()
    searchGroup:SetFullWidth(true)
    searchGroup:SetLayout("Flow")

    local searchBox = AceGUI:Create("EditBox")
    searchBox:SetLabel("Search")
    searchBox:SetWidth(220)
    searchBox:SetCallback("OnTextChanged", function(_, _, txt)
        searchText = txt or ""
        searchTextLower = string.lower(searchText)
        drawSpecData()
    end)
    searchGroup:AddChild(searchBox)

    local missingToggle = AceGUI:Create("CheckBox")
    missingToggle:SetLabel("Only missing")
    missingToggle:SetWidth(120)
    missingToggle:SetValue(showOnlyMissing and true or false)
    missingToggle:SetCallback("OnValueChanged", function(_, _, val)
        showOnlyMissing = val and true or false
        drawSpecData()
    end)
    searchGroup:AddChild(missingToggle)

    local checklistToggle = AceGUI:Create("CheckBox")
    checklistToggle:SetLabel("BIS checklist")
    checklistToggle:SetWidth(120)
    checklistToggle:SetValue(bisChecklistMode and true or false)
    checklistToggle:SetCallback("OnValueChanged", function(_, _, val)
        bisChecklistMode = val and true or false

        -- Persist
        if BistooltipAddon and BistooltipAddon.db and BistooltipAddon.db.char then
            BistooltipAddon.db.char.bis_checklist = bisChecklistMode
        end

        -- Checklist mode takes priority over "Only missing" (mutual exclusion)
        if bisChecklistMode then
            showOnlyMissing = false
            missingToggle:SetValue(false)
            missingToggle:SetDisabled(true)
        else
            missingToggle:SetDisabled(false)
            DestroyChecklistPanel()
        end

        ApplySpecTable()

        drawSpecData()
    end)
    searchGroup:AddChild(checklistToggle)

    if bisChecklistMode then
        missingToggle:SetDisabled(true)
        missingToggle:SetValue(false)
        showOnlyMissing = false
    end

    main_frame:AddChild(searchGroup)

    -- Compact checklist hint (full details are in the right panel)
    local checklistGroup = NewSimpleGroup()
    checklistGroup:SetFullWidth(true)
    checklistGroup:SetLayout("Fill")

    checklistSummaryLabel = AceGUI:Create("Label")
    checklistSummaryLabel:SetFullWidth(true)
    checklistSummaryLabel:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
    checklistSummaryLabel:SetText("")
    checklistGroup:AddChild(checklistSummaryLabel)
    main_frame:AddChild(checklistGroup)

    -- Buttons container
    local buttonContainer = NewSimpleGroup()
    buttonContainer:SetFullWidth(true)
    buttonContainer:SetLayout("Flow")

    local reloadButton = AceGUI:Create("Button")
    reloadButton:SetText("Reload Data")
    reloadButton:SetWidth(120)
    reloadButton:SetCallback("OnClick", function()
        BistooltipAddon:reloadData()
    end)
    buttonContainer:AddChild(reloadButton)

    local discordButton = AceGUI:Create("Button")
    discordButton:SetText("Join our Discord")
    discordButton:SetWidth(140)
    discordButton:SetCallback("OnClick", function()
        BistooltipAddon:OpenDiscordLink()
    end)
    buttonContainer:AddChild(discordButton)

    local noteLabel = AceGUI:Create("Label")
    noteLabel:SetText("")
    noteLabel:SetWidth(250)
    noteLabel:SetFont(GameFontNormal:GetFont(), 9)

    local spacerLabel = AceGUI:Create("Label")
    spacerLabel:SetWidth(20)
    buttonContainer:AddChild(spacerLabel)
    buttonContainer:AddChild(noteLabel)

    noteLabel:SetHeight(reloadButton.frame:GetHeight())
    noteLabel:SetFullWidth(false)
    if noteLabel.label and noteLabel.label.SetPoint then
        noteLabel.label:SetPoint("BOTTOM")
    end

    local function UpdateStatusText()
        local ds = (_G.DataStore_Inventory and "ON") or "OFF"
        local q = #preloadQueue
        local s = "DataStore: " .. ds
        if q > 0 then
            s = s .. "  •  Loading item info: " .. q
        end
        if searchTextLower and searchTextLower ~= "" then
            s = s .. "  •  Filter: " .. searchText
        end
        noteLabel:SetText(s)
    end

    statusFrame = CreateFrame("Frame", nil, main_frame.frame)
    statusFrame:SetScript("OnUpdate", function()
        UpdateStatusText()
    end)

    local spacer = AceGUI:Create("Label")
    spacer:SetFullWidth(true)
    spacer:SetText(" ")
    main_frame:AddChild(spacer)
    main_frame:AddChild(buttonContainer)

    -- Initial draw (after UI elements exist)
    drawSpecData()
end

function BistooltipAddon:closeMainFrame()
    if main_frame then
        CleanupMainFrame()
        AceGUI:Release(main_frame)
        main_frame = nil
        classDropdown = nil
        specDropdown = nil
        phaseDropDown = nil
    end
end