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

-- Owned info helper (cache from Core.lua)
local function GetOwnedRow(item_id)
    local t = _G.Bistooltip_char_equipment
    if not t then return nil end
    return t[item_id]
end

-- Background item preloader (small batch per tick)
local preloadFrame = CreateFrame("Frame")
preloadFrame:Hide()
local preloadQueue = {}
local preloadSeen = {}
local preloadCooldown = 0
local PRELOAD_BATCH = 12
local PRELOAD_INTERVAL = 0.12

local function QueuePreload(item_id)
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
        local item_id = table.remove(preloadQueue, 1)
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



local function createItemFrame(item_id, size, with_checkmark)
    if item_id < 0 then
        return AceGUI:Create("Label")
    end

    local item_frame = AceGUI:Create("Icon")
    item_frame:SetImageSize(size, size)

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
        QueuePreload(item_id)
        return item_frame
    end

    item_frame:SetImage(itemIcon)

    if with_checkmark then
        local checkMark = item_frame.frame:CreateTexture(nil, "OVERLAY")
        checkMark:SetWidth(28)
        checkMark:SetHeight(28)
        checkMark:SetPoint("CENTER", 6, -8)
        checkMark:SetTexture("Interface\\AddOns\\Bistooltip\\checkmark-16.tga")
        -- Color differs: equipped = green, bags = yellow
        if with_checkmark == "equipped" then
            checkMark:SetVertexColor(0.20, 1.00, 0.20, 0.95)
        else
            checkMark:SetVertexColor(1.00, 0.90, 0.10, 0.90)
        end
        table.insert(checkmarks, checkMark)
    end

    -- Small stack count overlay for bag copies
    if with_checkmark == "bags" then
        local countText = item_frame.frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        countText:SetPoint("BOTTOMRIGHT", -2, 2)
        countText:SetJustifyH("RIGHT")
        countText:SetTextColor(1, 1, 1, 1)
        countText:SetText("")
        countText._bt_item_id = item_id
        item_frame.frame._bt_countText = countText
    end

    if bindType == 2 then
        local boeMark = item_frame.frame:CreateTexture(nil, "OVERLAY")
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
        GameTooltip:SetOwner(item_frame.frame)
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

    -- Retrieve spell info directly using GetSpellInfo
    local name, rank, icon, castTime, minRange, maxRange = GetSpellInfo(spell_id)
    if not name then
        print("Failed to retrieve spell info for spell ID:", spell_id)
        return spell_frame
    end

    spell_frame:SetImage(icon)
    local link = GetSpellLink(spell_id)
    if not link then
        link = "\124cffffd000\124Hspell:" .. spell_id .. "\124h[" .. name .. "]\124h\124r"
    end

    -- Set callbacks for interactivity
    spell_frame:SetCallback("OnClick", function(button)
        SetItemRef(link, link, "LeftButton")
    end)
    spell_frame:SetCallback("OnEnter", function(widget)
        GameTooltip:SetOwner(spell_frame.frame)
        GameTooltip:SetPoint("TOPRIGHT", spell_frame.frame, "TOPRIGHT", 220, -13)
        GameTooltip:SetHyperlink(link)
    end)
    spell_frame:SetCallback("OnLeave", function(widget)
        GameTooltip:Hide()
    end)

    return spell_frame
end

local function createEnhancementsFrame(enhancements)
    local frame = AceGUI:Create("SimpleGroup")
    frame:SetLayout("Table")
    frame:SetWidth(40)
    frame:SetHeight(40)
    frame:SetUserData("table", {
        columns = {{
            weight = 14
        }, {
            width = 14
        }},
        spaceV = -10,
        spaceH = 0,
        align = "BOTTOMRIGHT"
    })
    frame:SetFullWidth(true)
    frame:SetFullHeight(true)
    frame:SetHeight(0)
    frame:SetAutoAdjustHeight(false)
    for i, enhancement in ipairs(enhancements) do
        local size = 16

        if enhancement.type == "none" then
            frame:AddChild(createItemFrame(-1, size))
        end
        if enhancement.type == "item" then
            frame:AddChild(createItemFrame(enhancement.id, size))
        end
        if enhancement.type == "spell" then
            frame:AddChild(createSpellFrame(enhancement.id, size))
        end
    end
    return frame
end

local function drawItemSlot(slot)
    local f = AceGUI:Create("Label")
    f:SetText(slot.slot_name)
    f:SetFont("Fonts\\FRIZQT__.TTF", 14, "")
    spec_frame:AddChild(f)
    spec_frame:AddChild(createEnhancementsFrame(slot.enhs))

    for i, original_item_id in ipairs(slot) do
        local item_id = original_item_id

        -- Check if Bistooltip_horde_to_ali is defined and use it for translation if available
        if isHorde and Bistooltip_horde_to_ali then
            local translated_item_id = Bistooltip_horde_to_ali[original_item_id]
            if translated_item_id then
                item_id = translated_item_id
            end
        end

        -- Owned overlays (equipped vs bags) from Core.lua cache
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

        -- Optional filter: show only missing items
        if showOnlyMissing and ownedState then
            -- Keep layout stable: show a placeholder label
            spec_frame:AddChild(AceGUI:Create("Label"))
        else
            local w = createItemFrame(item_id, 40, ownedState)
            -- Dimming for owned (visual hierarchy)
            if ownedState and w and w.frame then
                w.frame:SetAlpha(0.55)
                if ownedState == "equipped" then
                    w.frame:SetAlpha(0.70)
                end
                -- Update stack count if present
                if ownedState == "bags" and ownedCount > 1 and w.frame._bt_countText then
                    w.frame._bt_countText:SetText(ownedCount)
                elseif w.frame._bt_countText then
                    w.frame._bt_countText:SetText("")
                end
            end
            spec_frame:AddChild(w)
        end
    end
end

local function drawTableHeader(frame)
    local f = AceGUI:Create("Label")
    f:SetText("Slot")
    f:SetFont("Fonts\\FRIZQT__.TTF", 14, "")
    local color = 0.6
    f:SetColor(color, color, color)
    frame:AddChild(f)
    frame:AddChild(AceGUI:Create("Label"))
    for i = 1, 6 do
        f = AceGUI:Create("Label")
        f:SetText("Top " .. i)
        f:SetColor(color, color, color)
        frame:AddChild(f)
    end
end

local function saveData()
    BistooltipAddon.db.char.class_index = class_index
    BistooltipAddon.db.char.spec_index = spec_index
    BistooltipAddon.db.char.phase_index = phase_index
end

local function clearCheckMarks()
    for key, value in ipairs(checkmarks) do
        value:SetTexture(nil)
    end
    checkmarks = {}
end

local function clearBoeMarks()
    for key, value in ipairs(boemarks) do
        value:SetTexture(nil)
    end
    boemarks = {}
end

local function drawSpecData()
    clearCheckMarks()
    clearBoeMarks()
    saveData()
    items = {}
    spells = {}
    spec_frame:ReleaseChildren()
    drawTableHeader(spec_frame)
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
            drawItemSlot(slot)
        end
    end
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
    spec_index = BistooltipAddon.db.char.spec_index
    phase_index = BistooltipAddon.db.char.phase_index
    if class_index then
        if not class_index or not class_options[class_index] then class_index = 1 end
    class = class_options_to_class[class_options[class_index]].name
        buildSpecsDict(class_index)
    end
    if spec_index then
        if not spec_index or not spec_options[spec_index] then spec_index = 1 end
    spec = spec_options_to_spec[spec_options[spec_index]]
    end
    if phase_index then
        if not phase_index or not Bistooltip_phases[phase_index] then phase_index = 1 end
    phase = Bistooltip_phases[phase_index]
    end
end

local function drawDropdowns()
    local dropDownGroup = AceGUI:Create("SimpleGroup")

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
    frame:SetUserData("table", {
        columns = {{
            weight = 40
        }, {
            width = 44
        }, {
            width = 44
        }, {
            width = 44
        }, {
            width = 44
        }, {
            width = 44
        }, {
            width = 44
        }, {
            width = 44
        }},
        space = 1,
        align = "middle"
    })
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
    if main_frame then
        BistooltipAddon:closeMainFrame()
        return
    end

    main_frame = AceGUI:Create("Frame")
    main_frame:SetWidth(450)
    main_frame:SetHeight(550) -- Adjust the height here as needed
    main_frame.frame:SetMinResize(450, 300)
    main_frame.frame:SetMaxResize(800, 600)

    main_frame:SetCallback("OnClose", function(widget)
        clearCheckMarks()
        clearBoeMarks()
        spec_frame = nil
        items = {}
        spells = {}
        AceGUI:Release(widget)
        main_frame = nil
    end)
    main_frame:SetLayout("List")
    main_frame:SetTitle(BistooltipAddon.AddonNameAndVersion)
    main_frame:SetStatusText(Bistooltip_source_to_url[BistooltipAddon.db.char["data_source"]])

    drawDropdowns()
    createSpecFrame()
    drawSpecData()
    -- Search + filters (premium UX)
    local searchGroup = AceGUI:Create("SimpleGroup")
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

    main_frame:AddChild(searchGroup)


    -- Create a container to hold the button and the note label
    local buttonContainer = AceGUI:Create("SimpleGroup")
    buttonContainer:SetFullWidth(true)
    buttonContainer:SetLayout("Flow")

    -- Create the reload button
    local reloadButton = AceGUI:Create("Button")
    reloadButton:SetText("Reload Data")
    reloadButton:SetWidth(120) -- Set a reasonable width for the button
    reloadButton:SetCallback("OnClick", function()
        BistooltipAddon:reloadData()
    end)

    -- Add the button to the container first
    buttonContainer:AddChild(reloadButton)

    -- Create the Discord button
    local discordButton = AceGUI:Create("Button")
    discordButton:SetText("Join our Discord")
    discordButton:SetWidth(140)
    discordButton:SetCallback("OnClick", function()
        BistooltipAddon:OpenDiscordLink()
    end)
    buttonContainer:AddChild(discordButton)

    -- Create the status label
    local noteLabel = AceGUI:Create("Label")
    noteLabel:SetText("")
    noteLabel:SetWidth(250) -- Adjust width to fit the note text

    -- Set font size and font type
    noteLabel:SetFont(GameFontNormal:GetFont(), 9)

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

    -- Keep status updated while frame is open
    local statusFrame = CreateFrame("Frame", nil, main_frame.frame)
    statusFrame:SetScript("OnUpdate", function(_, e)
        UpdateStatusText()
    end)

    -- Create a spacer label to act as left margin
    local spacerLabel = AceGUI:Create("Label")
    spacerLabel:SetWidth(20) -- This sets the margin between button and label
    buttonContainer:AddChild(spacerLabel)

    -- Add the status label to the container
    buttonContainer:AddChild(noteLabel)

    -- Set the height of the noteLabel and align its text to the bottom
    noteLabel:SetHeight(reloadButton.frame:GetHeight())
    noteLabel:SetFullWidth(false)
    -- noteLabel:SetJustifyH("LEFT")

    -- Adjust the noteLabel's text frame to position it at the bottom
    noteLabel.label:SetPoint("BOTTOM")

    -- Add some space before the container to ensure it's at the bottom
    local spacer = AceGUI:Create("Label")
    spacer:SetFullWidth(true)
    spacer:SetText(" ")

    -- Add the spacer and button container to the main frame
    main_frame:AddChild(spacer)
    main_frame:AddChild(buttonContainer)
end

function BistooltipAddon:closeMainFrame()
    if main_frame then
        AceGUI:Release(main_frame)
        main_frame = nil
        classDropdown = nil
        specDropdown = nil
        phaseDropDown = nil
    end
end


