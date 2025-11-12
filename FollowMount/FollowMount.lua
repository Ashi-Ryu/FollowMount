-- FollowMount.lua
-- FollowMount addon - Bronzebeard-compatible version (Interface 30300)
-- Behavior:
--   Left-click: mount (if not mounted) then follow (target/party).
--   Right-click: dismount if mounted, otherwise follow (target/party).
-- SavedVariables: FollowMountDB

local ADDON_NAME = "FollowMount"
local initialized = false

-- Ensure DB defaults (do not overwrite saved table after ADDON_LOADED)
local function ensureDBDefaults()
    FollowMountDB = FollowMountDB or {}
    if FollowMountDB.mountName == nil then FollowMountDB.mountName = "Striped Nightsaber" end
    if FollowMountDB.companionIndex == nil then FollowMountDB.companionIndex = nil end
    if FollowMountDB.buttonPosition == nil then FollowMountDB.buttonPosition = nil end
end

-- Globals in this file
local button
local dropdown
local mountList = {}

-- Build list of mounts (works with companion API or spellbook fallback)
local function buildMountList()
    mountList = {}
    if type(GetNumCompanions) == "function" and type(GetCompanionInfo) == "function" then
        local num = GetNumCompanions("MOUNT") or 0
        for i = 1, num do
            local creatureID, creatureName = GetCompanionInfo("MOUNT", i)
            if creatureName then
                table.insert(mountList, { name = creatureName, index = i })
            end
        end
    else
        -- Fallback scanning spellbook (may include non-mount spells; user can set manual)
        if type(GetNumSpellTabs) == "function" and type(GetSpellBookItemName) == "function" then
            local numTabs = GetNumSpellTabs() or 0
            local total = 0
            for t = 1, numTabs do
                local _, _, offset, numSlots = GetSpellTabInfo(t)
                total = total + (numSlots or 0)
            end
            for i = 1, total do
                local spellName = GetSpellBookItemName(i, BOOKTYPE_SPELL)
                if spellName then
                    table.insert(mountList, { name = spellName, index = nil })
                end
            end
        end
    end
end

-- Summon by name (tries companion API then CastSpellByName)
local function summonMountByName(name)
    if not name or name == "" then return false end
    if type(GetNumCompanions) == "function" and type(GetCompanionInfo) == "function" and type(CallCompanion) == "function" then
        local num = GetNumCompanions("MOUNT") or 0
        for i = 1, num do
            local creatureID, creatureName = GetCompanionInfo("MOUNT", i)
            if creatureName == name then
                CallCompanion("MOUNT", i)
                return true
            end
        end
    end
    if type(CastSpellByName) == "function" then
        -- This may attempt to cast a spell with that name (works for spellbook mounts).
        CastSpellByName(name)
        return true
    end
    return false
end

-- Summon by companion index (if available)
local function summonMountByIndex(index)
    if type(CallCompanion) == "function" and index then
        CallCompanion("MOUNT", index)
        return true
    end
    return false
end

-- Utility: follow best candidate: target if in party/raid, else first party member
local function DoFollowFallback()
    -- If target is a valid follow target (in party or raid), follow it
    if UnitExists("target") then
        if UnitInParty("target") or (type(UnitInRaid) == "function" and UnitInRaid("target")) then
            FollowUnit("target")
            return true
        end
    end

    -- If not, follow first party member found
    local numGroup = GetNumGroupMembers and GetNumGroupMembers() or 0
    -- In classic-style servers, GetNumGroupMembers can be nil; we still loop up to 4 party slots as before
    for i = 1, 4 do
        local u = "party"..i
        if UnitExists(u) then
            FollowUnit(u)
            return true
        end
    end
    -- No follow target found
    return false
end

-- Dropdown click handler
local function dropdown_OnClick(self)
    local v = self.value
    if not v then return end
    FollowMountDB.mountName = v.name
    FollowMountDB.companionIndex = v.index
    if dropdown and UIDropDownMenu_SetSelectedName then
        UIDropDownMenu_SetSelectedName(dropdown, v.name)
    end
end

-- Populate dropdown menu
local function populateDropdown()
    buildMountList()
    if not dropdown then return end

    local function init(self, level)
        -- Clear previous buttons are handled by UIDropDownMenu system
        for _, v in ipairs(mountList) do
            local entry = UIDropDownMenu_CreateInfo()
            entry.text = v.name
            entry.value = v
            entry.func = dropdown_OnClick
            entry.checked = (FollowMountDB.mountName == v.name)
            UIDropDownMenu_AddButton(entry, level)
        end

        local manual = UIDropDownMenu_CreateInfo()
        manual.text = "Manual entry..."
        manual.func = function()
            if not StaticPopupDialogs["FOLLOWMOUNT_MANUAL"] then
                StaticPopupDialogs["FOLLOWMOUNT_MANUAL"] = {
                    text = "Type mount name to use:",
                    button1 = "OK",
                    button2 = "Cancel",
                    hasEditBox = true,
                    timeout = 0,
                    whileDead = true,
                    hideOnEscape = true,
                    OnAccept = function(self)
                        local text = self.editBox:GetText()
                        if text and text ~= "" then
                            FollowMountDB.mountName = text
                            FollowMountDB.companionIndex = nil
                            if dropdown and UIDropDownMenu_SetSelectedName then
                                UIDropDownMenu_SetSelectedName(dropdown, text)
                            end
                        end
                    end,
                }
            end
            StaticPopup_Show("FOLLOWMOUNT_MANUAL")
        end
        UIDropDownMenu_AddButton(manual, level)
    end

    UIDropDownMenu_Initialize(dropdown, init)
    if UIDropDownMenu_SetWidth then UIDropDownMenu_SetWidth(dropdown, 220) end
    if FollowMountDB.mountName and UIDropDownMenu_SetSelectedName then
        UIDropDownMenu_SetSelectedName(dropdown, FollowMountDB.mountName)
    end
end

-- Create UI: main button and interface options panel
local function createUI()
    if FollowMountButton then return end

    -- Main button
    button = CreateFrame("Button", "FollowMountButton", UIParent, "UIPanelButtonTemplate")
    button:SetSize(64, 64)

    if FollowMountDB.buttonPosition and type(FollowMountDB.buttonPosition) == "table" then
        local pt, rpt, x, y = FollowMountDB.buttonPosition[1], FollowMountDB.buttonPosition[2], FollowMountDB.buttonPosition[3], FollowMountDB.buttonPosition[4]
        pcall(function() button:SetPoint(pt or "CENTER", UIParent, rpt or "CENTER", x or 0, y or 0) end)
    else
        button:SetPoint("CENTER", UIParent, "CENTER")
    end

    button:SetText("Follow")

    -- Accept left and right clicks
    if button.RegisterForClicks then
        button:RegisterForClicks("AnyUp")
    end

    -- Dragging/moving
    button:RegisterForDrag("LeftButton")
    button:SetMovable(true)
    button:EnableMouse(true)
    button:SetScript("OnDragStart", function(self) self:StartMoving() end)
    button:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        -- Save position
        FollowMountDB.buttonPosition = { point or "CENTER", relPoint or "CENTER", x or 0, y or 0 }
    end)

    -- OnClick: handle left and right behavior
    button:SetScript("OnClick", function(self, buttonClicked, ...)
        if buttonClicked == "RightButton" then
            if IsMounted() then
                -- Dismount
                if type(Dismount) == "function" then
                    Dismount()
                end
                return
            else
                -- Not mounted -> perform follow
                DoFollowFallback()
                return
            end
        end

        -- Left click: try to mount (by index or name) then follow
        if not IsMounted() then
            if FollowMountDB.companionIndex then
                if summonMountByIndex(FollowMountDB.companionIndex) then
                    -- mounted (or attempted); we still try to follow afterwards
                end
            end
            if not IsMounted() and FollowMountDB.mountName and FollowMountDB.mountName ~= "" then
                summonMountByName(FollowMountDB.mountName)
            end
        end

        -- After attempting to mount (or if already mounted), perform follow behaviour
        DoFollowFallback()
    end)

    -- Tooltip: show functionality and current mount
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:ClearLines()
        GameTooltip:SetText("FollowMount", 1, 1, 1)
        -- current mount line
        if FollowMountDB.mountName and FollowMountDB.mountName ~= "" then
            GameTooltip:AddLine("Current mount: " .. FollowMountDB.mountName, 0.8, 0.8, 0.8, true)
        else
            GameTooltip:AddLine("Current mount: (none)", 0.8, 0.8, 0.8, true)
        end
        GameTooltip:AddLine("Left-click: Mount (if not mounted) then follow.", 1, 1, 1, true)
        GameTooltip:AddLine("Right-click: Dismount (if mounted) or Follow (if not mounted).", 1, 1, 1, true)
        GameTooltip:AddLine("Drag: move the button.", 0.6, 0.6, 0.6, true)
        GameTooltip:AddLine("Options: Interface -> AddOns -> FollowMount", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Options panel for Interface options
    if not FollowMountOptionsPanel then
        local panel = CreateFrame("Frame", "FollowMountOptionsPanel", UIParent)
        panel.name = "FollowMount"

        local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetPoint("TOPLEFT", 16, -16)
        title:SetText("FollowMount Options (Bronzebeard-compatible)")

        -- Dropdown
        dropdown = CreateFrame("Frame", "FollowMountDropdown", panel, "UIDropDownMenuTemplate")
        dropdown:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -16)

        panel:SetScript("OnShow", function() populateDropdown() end)

        InterfaceOptions_AddCategory(panel)
    end
end

-- Event frame: handle saved vars and UI creation
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        ensureDBDefaults()
        initialized = true
    elseif event == "PLAYER_LOGIN" then
        if not initialized then ensureDBDefaults() end
        -- Build mounts and create the button
        pcall(buildMountList)
        -- If DB missing mountName, pick first available
        if not FollowMountDB.mountName and mountList[1] then
            FollowMountDB.mountName = mountList[1].name
            FollowMountDB.companionIndex = mountList[1].index
        end
        createUI()
    end
end)

-- Also try to build mount list right away if possible
pcall(buildMountList)