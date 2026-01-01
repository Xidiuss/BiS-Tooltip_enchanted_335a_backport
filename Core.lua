BistooltipAddon = LibStub("AceAddon-3.0"):NewAddon("Bis-Tooltip")

--[[
  Performance notes (3.3.5a):
  Previous versions were rebuilding huge BIS itemID lists and calling GetItemCount() for thousands of IDs
  on every BAG_UPDATE. That causes micro-stutters when moving/splitting/sorting items.

  This core now keeps a lightweight cache of *current character*:
    - bags (0..NUM_BAG_SLOTS)
    - equipped slots (1..19)

  Bank visibility:
    - We do NOT scan bank containers every time (expensive and often empty/unavailable).
    - If DataStore is enabled you can extend this later for alts/bank, but by default we keep it fast.
]]

-- Public cache: itemId -> { bags = n, equipped = n }
Bistooltip_char_equipment = Bistooltip_char_equipment or {}

-- ------------------------------------------------------------
-- Helpers
-- ------------------------------------------------------------
local function GetItemIDFromLink(link)
    if not link then return nil end
    local id = link:match("item:(%d+):")
    if id then return tonumber(id) end
    return nil
end

-- ------------------------------------------------------------
-- Equipment / bags cache (debounced)
-- ------------------------------------------------------------
function BistooltipAddon:ScanEquipment(force)
    -- Build fresh table to avoid stale entries.
    local collection = {}

    -- Bags only (0..NUM_BAG_SLOTS). This is tiny and safe.
    for bag = 0, NUM_BAG_SLOTS do
        local numSlots = GetContainerNumSlots(bag) or 0
        for slot = 1, numSlots do
            local id
            if GetContainerItemID then
                id = GetContainerItemID(bag, slot)
            else
                id = GetItemIDFromLink(GetContainerItemLink(bag, slot))
            end
            if id then
                local row = collection[id]
                if not row then
                    row = { bags = 0, equipped = 0 }
                    collection[id] = row
                end
                row.bags = (row.bags or 0) + 1
            end
        end
    end

    -- Equipped items (1..19).
    for i = 1, 19 do
        local id = GetInventoryItemID("player", i)
        if id then
            local row = collection[id]
            if not row then
                row = { bags = 0, equipped = 0 }
                collection[id] = row
            end
            row.equipped = (row.equipped or 0) + 1
        end
    end

    Bistooltip_char_equipment = collection
    self.char_equipment = collection
    self.last_scan = GetTime()
end

local function createEquipmentWatcher()
    local frame = CreateFrame("Frame")
    frame:Hide()

    local pending = false
    local delayLeft = 0
    local DEBOUNCE = 0.25

    local function scheduleScan()
        pending = true
        delayLeft = DEBOUNCE
        frame:Show()
    end

    frame:SetScript("OnEvent", function(_, event)
        -- BAG_UPDATE_DELAYED triggers once after a burst of changes (better than BAG_UPDATE spam)
        scheduleScan()
    end)

    -- Use BAG_UPDATE_DELAYED if available; fallback to BAG_UPDATE.
    if _G.BAG_UPDATE_DELAYED then
        frame:RegisterEvent("BAG_UPDATE_DELAYED")
    else
        frame:RegisterEvent("BAG_UPDATE")
    end
    frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")

    frame:SetScript("OnUpdate", function(self, elapsed)
        if not pending then
            self:Hide()
            return
        end
        delayLeft = delayLeft - (elapsed or 0)
        if delayLeft <= 0 then
            pending = false
            self:Hide()
            if BistooltipAddon and BistooltipAddon.ScanEquipment then
                BistooltipAddon:ScanEquipment(false)
            end
        end
    end)

    -- Initial scan as soon as possible
    scheduleScan()
end

function BistooltipAddon:OnInitialize()
    createEquipmentWatcher()

    -- DataStore is optional. We only *use* it in tooltip source lookups; bank/alt inventory is optional.
    self.hasDataStore = not not (_G.DataStore_Inventory)
    if not self.hasDataStore then
        -- One-time info message (English as requested)
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd000Bis-Tooltip:|r running without DataStore. Bank/alt inventory features may be unavailable.")
    end

    BistooltipAddon.AceAddonName = "Bis-Tooltip"
    BistooltipAddon.AddonNameAndVersion = "Bis-Tooltip 3.3.5a backport by Silver [DisruptionAuras]"
    BistooltipAddon:initConfig()
    BistooltipAddon:addMapIcon()
    BistooltipAddon:initBislists()
    BistooltipAddon:initBisTooltip()

    -- Ensure we have an initial cache for "You have this item" lines.
    BistooltipAddon:ScanEquipment(true)
end
