local ADDON_NAME = ...

local CompanionKeeper = CreateFrame("Frame")

local DEFAULTS = {
    enabled = true,
    petGUID = nil,
    petName = nil,
    useFavorites = false,
    delaySeconds = 2,
    suppressWhileMounted = true,
}

local pendingCheck = false
local scheduleToken = 0
local settingsCategory
local settingsPanel
local petListSelectionGUID
local RefreshSettingsPanel
local RefreshPetList
local collectedPetsCache

local function IsPetSummonable(petGUID)
    return petGUID and C_PetJournal.PetIsSummonable and C_PetJournal.PetIsSummonable(petGUID)
end

local function Print(message)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Companion Keeper:|r " .. message)
end

local function CopyDefaults(target, defaults)
    for key, value in pairs(defaults) do
        if target[key] == nil then
            target[key] = value
        end
    end
end

local function GetDB()
    if type(CompanionKeeperDB) ~= "table" then
        CompanionKeeperDB = {}
    end

    CopyDefaults(CompanionKeeperDB, DEFAULTS)
    return CompanionKeeperDB
end

local function NormalizeName(name)
    if not name or name == "" then
        return nil
    end

    return strlower(strtrim(name))
end

local function GetCurrentPetGUID()
    if not C_PetJournal or not C_PetJournal.GetSummonedPetGUID then
        return nil
    end

    return C_PetJournal.GetSummonedPetGUID()
end

local function GetPetName(petGUID)
    if not petGUID then
        return nil
    end

    local _, customName, _, _, _, _, _, speciesName = C_PetJournal.GetPetInfoByPetID(petGUID)
    return customName or speciesName
end

local function GetPetDisplayInfo(petGUID)
    if not petGUID then
        return nil
    end

    local speciesID, customName, level, xp, maxXp, displayID, favorite, speciesName, icon = C_PetJournal.GetPetInfoByPetID(petGUID)
    if not speciesID then
        return nil
    end

    return {
        speciesID = speciesID,
        customName = customName,
        level = level,
        xp = xp,
        maxXp = maxXp,
        displayID = displayID,
        favorite = favorite,
        speciesName = speciesName,
        icon = icon,
        displayName = customName or speciesName,
        isCurrent = (GetCurrentPetGUID() == petGUID),
        summonable = IsPetSummonable and IsPetSummonable(petGUID),
    }
end

local function SavePetJournalFilters()
    local saved = {
        search = nil,
        collected = true,
        source = {},
        petType = {},
        usingDefault = C_PetJournal.IsUsingDefaultFilters and C_PetJournal.IsUsingDefaultFilters() or nil,
    }

    if PetJournal and PetJournal.searchBox and PetJournal.searchBox.GetText then
        saved.search = PetJournal.searchBox:GetText()
    end

    if C_PetJournal.IsFilterChecked then
        saved.collected = C_PetJournal.IsFilterChecked(LE_PET_JOURNAL_FILTER_COLLECTED)
    end

    if C_PetJournal.GetNumPetSources and C_PetJournal.IsPetSourceChecked then
        for index = 1, C_PetJournal.GetNumPetSources() do
            saved.source[index] = C_PetJournal.IsPetSourceChecked(index)
        end
    end

    if C_PetJournal.GetNumPetTypes and C_PetJournal.IsPetTypeChecked then
        for index = 1, C_PetJournal.GetNumPetTypes() do
            saved.petType[index] = C_PetJournal.IsPetTypeChecked(index)
        end
    end

    return saved
end

local function RestorePetJournalFilters(saved)
    if not saved then
        return
    end

    if saved.usingDefault == false then
        if saved.collected ~= nil and C_PetJournal.SetFilterChecked then
            C_PetJournal.SetFilterChecked(LE_PET_JOURNAL_FILTER_COLLECTED, saved.collected)
        end
        if C_PetJournal.SetPetSourceChecked then
            for index, value in pairs(saved.source) do
                C_PetJournal.SetPetSourceChecked(index, value)
            end
        end
        if C_PetJournal.SetPetTypeFilter then
            for index, value in pairs(saved.petType) do
                C_PetJournal.SetPetTypeFilter(index, value)
            end
        end
    elseif C_PetJournal.SetDefaultFilters then
        C_PetJournal.SetDefaultFilters()
    end

    if saved.search and saved.search ~= "" and C_PetJournal.SetSearchFilter then
        C_PetJournal.SetSearchFilter(saved.search)
    elseif C_PetJournal.ClearSearchFilter then
        C_PetJournal.ClearSearchFilter()
    end
end

local function GetCollectedPets()
    local pets = {}
    local savedFilters = SavePetJournalFilters()

    if C_PetJournal.SetDefaultFilters then
        C_PetJournal.SetDefaultFilters()
    end
    if C_PetJournal.SetFilterChecked then
        C_PetJournal.SetFilterChecked(LE_PET_JOURNAL_FILTER_COLLECTED, true)
    end
    if C_PetJournal.ClearSearchFilter then
        C_PetJournal.ClearSearchFilter()
    end

    local _, numOwned = C_PetJournal.GetNumPets()

    for index = 1, numOwned do
        local petGUID, speciesID, owned, customName, _, favorite, isRevoked, speciesName = C_PetJournal.GetPetInfoByIndex(index)
        if owned and petGUID and not isRevoked then
            pets[#pets + 1] = {
                petGUID = petGUID,
                speciesID = speciesID,
                customName = customName,
                speciesName = speciesName,
                favorite = favorite,
            }
        end
    end

    RestorePetJournalFilters(savedFilters)

    return pets
end

local function RefreshCollectedPetsCache()
    collectedPetsCache = GetCollectedPets()
end

local function FindPetByName(name)
    local wanted = NormalizeName(name)
    if not wanted then
        return nil
    end

    local partialMatch

    for _, pet in ipairs(GetCollectedPets()) do
        local displayName = pet.customName or pet.speciesName
        local normalizedDisplayName = NormalizeName(displayName)
        if normalizedDisplayName == wanted then
            return pet.petGUID, displayName
        end

        if not partialMatch and normalizedDisplayName and strfind(normalizedDisplayName, wanted, 1, true) then
            partialMatch = { pet.petGUID, displayName }
        end
    end

    if partialMatch then
        return partialMatch[1], partialMatch[2]
    end

    return nil
end

local function GetRandomFavoritePet()
    local favorites = {}

    for _, pet in ipairs(GetCollectedPets()) do
        if pet.favorite and IsPetSummonable(pet.petGUID) then
            favorites[#favorites + 1] = pet
        end
    end

    if #favorites == 0 then
        return nil, nil
    end

    local choice = favorites[random(#favorites)]
    return choice.petGUID, choice.customName or choice.speciesName
end

local function ResolveConfiguredPet()
    local db = GetDB()

    if db.petGUID and IsPetSummonable(db.petGUID) then
        return db.petGUID, db.petName or GetPetName(db.petGUID), true
    end

    if db.petGUID and not IsPetSummonable(db.petGUID) then
        db.petName = GetPetName(db.petGUID) or db.petName
    end

    if db.petName and not db.useFavorites then
        local petGUID, petName = FindPetByName(db.petName)
        if petGUID and IsPetSummonable(petGUID) then
            db.petGUID = petGUID
            db.petName = petName
            return petGUID, petName, true
        end
    end

    if db.useFavorites or db.petName or db.petGUID then
        local petGUID, petName = GetRandomFavoritePet()
        if petGUID then
            return petGUID, petName, false
        end
    end

    return nil, nil, false
end

local function CanAttemptSummon()
    if not GetDB().enabled then
        return false
    end

    if InCombatLockdown() or UnitAffectingCombat("player") then
        return false
    end

    if UnitIsDeadOrGhost("player") or UnitInVehicle("player") then
        return false
    end

    if C_PetBattles and C_PetBattles.IsInBattle and C_PetBattles.IsInBattle() then
        return false
    end

    if GetDB().suppressWhileMounted and (IsMounted() or UnitOnTaxi("player")) then
        return false
    end

    return true
end

local function AttemptSummon(reason)
    pendingCheck = false

    local petGUID, petName, replaceWrongPet = ResolveConfiguredPet()
    if not petGUID then
        return
    end

    local currentPetGUID = GetCurrentPetGUID()
    if currentPetGUID and currentPetGUID == petGUID then
        return
    end

    if currentPetGUID and not replaceWrongPet then
        return
    end

    if not CanAttemptSummon() then
        pendingCheck = true
        return
    end

    if not currentPetGUID and not replaceWrongPet and C_PetJournal.SummonRandomPet then
        C_PetJournal.SummonRandomPet(true)
    else
        C_PetJournal.SummonPetByGUID(petGUID)
    end

    if CompanionKeeper.lastSummonGUID ~= petGUID or CompanionKeeper.lastReason ~= reason then
        CompanionKeeper.lastSummonGUID = petGUID
        CompanionKeeper.lastReason = reason
        Print(("Summoning %s."):format(petName or "your companion pet"))
    end
end

local function ScheduleCheck(delaySeconds, reason)
    scheduleToken = scheduleToken + 1
    local token = scheduleToken
    local delay = tonumber(delaySeconds) or GetDB().delaySeconds or DEFAULTS.delaySeconds

    C_Timer.After(delay, function()
        if token ~= scheduleToken then
            return
        end

        AttemptSummon(reason or "scheduled check")
    end)
end

local function SetCurrentPet()
    local currentGUID = GetCurrentPetGUID()
    if not currentGUID then
        Print("No companion pet is currently summoned.")
        return
    end

    local db = GetDB()
    db.petGUID = currentGUID
    db.petName = GetPetName(currentGUID)
    db.useFavorites = false

    Print(("Saved %s as your companion pet."):format(db.petName or "the current companion pet"))
end

local function SetPetByName(name)
    name = strtrim(name or "")
    if name == "" then
        local db = GetDB()
        db.petGUID = nil
        db.petName = nil
        db.useFavorites = false
        Print("Cleared saved companion pet.")
        return true
    end

    local petGUID, petName = FindPetByName(name)
    if not petGUID then
        Print(("Couldn't find a collected companion pet matching \"%s\"."):format(name))
        return false
    end

    local db = GetDB()
    db.petGUID = petGUID
    db.petName = petName
    db.useFavorites = false

    Print(("Saved %s as your companion pet."):format(petName))
    ScheduleCheck(0.2, "manual set")
    return true
end

local function SetFavoritesMode()
    local petGUID, petName = GetRandomFavoritePet()
    if not petGUID then
        Print("You do not have any summonable favorite companion pets.")
        return false
    end

    local db = GetDB()
    db.petGUID = nil
    db.petName = nil
    db.useFavorites = true

    Print(("Favorites mode enabled. Next summon will pick one of your favorites, starting with %s if needed."):format(petName))
    ScheduleCheck(0.2, "favorites mode")
    return true
end

local function CreateLabel(parent, text, template, x, y)
    local label = parent:CreateFontString(nil, "ARTWORK", template or "GameFontHighlight")
    label:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    label:SetJustifyH("LEFT")
    label:SetText(text)
    return label
end

local function BuildPetList(searchText)
    local pets = collectedPetsCache or GetCollectedPets()
    local rows = {}
    local normalizedSearch = NormalizeName(searchText or "")

    table.sort(pets, function(left, right)
        local leftName = left.customName or left.speciesName or ""
        local rightName = right.customName or right.speciesName or ""
        return leftName < rightName
    end)

    for _, pet in ipairs(pets) do
        local displayName = pet.customName or pet.speciesName or ""
        local speciesName = pet.speciesName or displayName
        local haystack = NormalizeName(displayName .. " " .. speciesName)
        if not normalizedSearch or (haystack and strfind(haystack, normalizedSearch, 1, true)) then
            rows[#rows + 1] = {
                petGUID = pet.petGUID,
                displayName = displayName,
                speciesName = speciesName,
                favorite = pet.favorite,
                summonable = IsPetSummonable(pet.petGUID),
                isCurrent = (GetCurrentPetGUID() == pet.petGUID),
            }
        end
    end

    return rows
end

local function ScrollPetList(delta)
    if not settingsPanel or not settingsPanel.scrollFrame or not settingsPanel.petRows then
        return
    end

    local totalRows = settingsPanel.petListData and #settingsPanel.petListData or 0
    local visibleRows = #settingsPanel.petRows
    local maxOffset = math.max(0, totalRows - visibleRows)
    local currentOffset = FauxScrollFrame_GetOffset(settingsPanel.scrollFrame)
    local newOffset = math.max(0, math.min(maxOffset, currentOffset - delta))

    if newOffset ~= currentOffset then
        FauxScrollFrame_SetOffset(settingsPanel.scrollFrame, newOffset)
        RefreshPetList()
    end
end

local function SelectPetFromList(petGUID)
    petListSelectionGUID = petGUID
    if settingsPanel then
        RefreshSettingsPanel()
    end
end

RefreshPetList = function()
    if not settingsPanel or not settingsPanel.petRows then
        return
    end

    local rows = BuildPetList(settingsPanel.searchBox and settingsPanel.searchBox:GetText() or "")
    settingsPanel.petListData = rows
    local scrollOffset = FauxScrollFrame_GetOffset(settingsPanel.scrollFrame)

    if petListSelectionGUID then
        local foundSelection = false
        for _, row in ipairs(rows) do
            if row.petGUID == petListSelectionGUID then
                foundSelection = true
                break
            end
        end
        if not foundSelection then
            petListSelectionGUID = nil
        end
    end

    if not petListSelectionGUID then
        local db = GetDB()
        petListSelectionGUID = db.petGUID
    end

    FauxScrollFrame_Update(settingsPanel.scrollFrame, #rows, #settingsPanel.petRows, 24)
    scrollOffset = FauxScrollFrame_GetOffset(settingsPanel.scrollFrame)

    for index, button in ipairs(settingsPanel.petRows) do
        local dataIndex = index + scrollOffset
        local row = rows[dataIndex]
        if row then
            local iconText = row.favorite and "|TInterface\\COMMON\\ReputationStar:14:14:0:0|t " or ""
            local statusBits = {}
            if row.isCurrent then
                statusBits[#statusBits + 1] = "Current"
            end
            if not row.summonable then
                statusBits[#statusBits + 1] = "Unavailable"
            end
            local suffix = #statusBits > 0 and (" |cff888888(" .. table.concat(statusBits, ", ") .. ")|r") or ""
            button.name:SetText(iconText .. row.displayName .. suffix)

            if row.displayName ~= row.speciesName then
                button.subName:SetText(row.speciesName)
                button.subName:Show()
            else
                button.subName:Hide()
            end

            button.petGUID = row.petGUID
            button:Show()
            if row.petGUID == petListSelectionGUID then
                button.bg:SetColorTexture(0.2, 0.45, 0.75, 0.35)
            else
                button.bg:SetColorTexture(0.1, 0.1, 0.1, dataIndex % 2 == 0 and 0.18 or 0.1)
            end
        else
            button.petGUID = nil
            button:Hide()
        end
    end

    settingsPanel.emptyText:SetShown(#rows == 0)
end

function RefreshSettingsPanel()
    if not settingsPanel then
        return
    end

    local db = GetDB()
    settingsPanel.enabled:SetChecked(db.enabled)
    settingsPanel.favorites:SetChecked(db.useFavorites)
    settingsPanel.mounted:SetChecked(db.suppressWhileMounted)
    settingsPanel.petNameBox:SetText(db.petName or "")
    settingsPanel.useSelectedButton:SetEnabled(not db.useFavorites and petListSelectionGUID ~= nil)

    if db.useFavorites then
        settingsPanel.status:SetText("Mode: Random favorite companion")
    else
        settingsPanel.status:SetText(("Mode: Specific companion: %s"):format(db.petName or "none"))
    end

    RefreshPetList()

    local previewGUID = petListSelectionGUID or db.petGUID
    local info = GetPetDisplayInfo(previewGUID)
    if not info and settingsPanel.petListData then
        for _, row in ipairs(settingsPanel.petListData) do
            if row.petGUID == previewGUID then
                info = {
                    displayName = row.displayName,
                    speciesName = row.speciesName,
                    favorite = row.favorite,
                    isCurrent = row.isCurrent,
                    summonable = row.summonable,
                    icon = select(9, C_PetJournal.GetPetInfoByPetID(row.petGUID)) or 132599,
                }
                break
            end
        end
    end
    if info then
        settingsPanel.previewIcon:SetTexture(info.icon or 132599)
        settingsPanel.previewIcon:SetDesaturated(not info.summonable)
        settingsPanel.previewName:SetText(info.displayName or "Unknown Companion")

        local details = {}
        if info.displayName ~= info.speciesName then
            details[#details + 1] = info.speciesName
        end
        if info.favorite then
            details[#details + 1] = "Favorite"
        end
        if info.isCurrent then
            details[#details + 1] = "Currently Summoned"
        end
        if not info.summonable then
            details[#details + 1] = "Unavailable"
        end
        if info.level and tonumber(info.level) and info.level > 0 then
            details[#details + 1] = ("Level %d"):format(info.level)
        end

        settingsPanel.previewDetails:SetText(#details > 0 and table.concat(details, " | ") or "Collected companion pet")
        settingsPanel.previewFrame:Show()
        settingsPanel.previewEmpty:Hide()
    else
        settingsPanel.previewIcon:SetTexture(132599)
        settingsPanel.previewIcon:SetDesaturated(false)
        settingsPanel.previewName:SetText("No Preview Available")
        settingsPanel.previewDetails:SetText("Select a companion pet to preview it here.")
        settingsPanel.previewFrame:Show()
        settingsPanel.previewEmpty:Show()
    end
end

local function CreateSettingsPanel()
    if settingsPanel then
        return settingsPanel
    end

    local frame = CreateFrame("Frame")
    frame.name = "Companion Keeper"

    local title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Companion Keeper")

    local subtitle = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    subtitle:SetWidth(620)
    subtitle:SetJustifyH("LEFT")
    subtitle:SetText("Keeps a vanity companion pet out by re-summoning it after flight paths, mounting, zoning, and similar interruptions. Blizzard-safe because it uses companion-pet journal APIs and waits for out-of-combat conditions.")

    frame.enabled = CreateFrame("CheckButton", nil, frame, "InterfaceOptionsCheckButtonTemplate")
    frame.enabled:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -18)
    frame.enabled.Text:SetText("Enable Companion Keeper")
    frame.enabled:SetScript("OnClick", function(self)
        GetDB().enabled = self:GetChecked() and true or false
        RefreshSettingsPanel()
        if GetDB().enabled then
            ScheduleCheck(0.2, "settings enabled")
        end
    end)

    frame.favorites = CreateFrame("CheckButton", nil, frame, "InterfaceOptionsCheckButtonTemplate")
    frame.favorites:SetPoint("TOPLEFT", frame.enabled, "BOTTOMLEFT", 0, -12)
    frame.favorites.Text:SetText("Use random favorite instead of a specific pet")
    frame.favorites:SetScript("OnClick", function(self)
        if self:GetChecked() then
            if not SetFavoritesMode() then
                self:SetChecked(false)
            end
        else
            GetDB().useFavorites = false
        end
        RefreshSettingsPanel()
    end)

    frame.mounted = CreateFrame("CheckButton", nil, frame, "InterfaceOptionsCheckButtonTemplate")
    frame.mounted:SetPoint("TOPLEFT", frame.favorites, "BOTTOMLEFT", 0, -12)
    frame.mounted.Text:SetText("Do not summon while mounted or on a taxi")
    frame.mounted:SetScript("OnClick", function(self)
        GetDB().suppressWhileMounted = self:GetChecked() and true or false
        RefreshSettingsPanel()
    end)

    local petNameLabel = CreateLabel(frame, "Specific pet name", "GameFontNormal", 16, -180)
    petNameLabel:SetWidth(240)

    frame.petNameBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    frame.petNameBox:SetSize(220, 30)
    frame.petNameBox:SetPoint("TOPLEFT", petNameLabel, "BOTTOMLEFT", 0, -10)
    frame.petNameBox:SetAutoFocus(false)
    frame.petNameBox:SetScript("OnEnterPressed", function(self)
        local success = SetPetByName(self:GetText())
        if success then
            self:ClearFocus()
        end
        RefreshSettingsPanel()
    end)
    frame.petNameBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        RefreshSettingsPanel()
    end)

    frame.applyButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.applyButton:SetSize(100, 24)
    frame.applyButton:SetPoint("LEFT", frame.petNameBox, "RIGHT", 10, 0)
    frame.applyButton:SetText("Save Pet")
    frame.applyButton:SetScript("OnClick", function()
        SetPetByName(frame.petNameBox:GetText())
        RefreshSettingsPanel()
    end)

    local searchLabel = CreateLabel(frame, "Search collected pets", "GameFontNormal", 380, -180)
    searchLabel:SetWidth(260)

    frame.searchBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    frame.searchBox:SetSize(260, 30)
    frame.searchBox:SetPoint("TOPLEFT", searchLabel, "BOTTOMLEFT", 0, -10)
    frame.searchBox:SetAutoFocus(false)
    frame.searchBox:SetScript("OnTextChanged", function()
        FauxScrollFrame_SetOffset(frame.scrollFrame, 0)
        RefreshPetList()
    end)
    frame.searchBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)

    frame.listBackdrop = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    frame.listBackdrop:SetPoint("TOPLEFT", frame.searchBox, "BOTTOMLEFT", -4, -8)
    frame.listBackdrop:SetSize(270, 300)
    frame.listBackdrop:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame.listBackdrop:EnableMouseWheel(true)
    frame.listBackdrop:SetScript("OnMouseWheel", function(_, delta)
        ScrollPetList(delta)
    end)

    frame.scrollFrame = CreateFrame("ScrollFrame", "CompanionKeeperPetListScrollFrame", frame.listBackdrop, "FauxScrollFrameTemplate")
    frame.scrollFrame:SetPoint("TOPRIGHT", -26, -8)
    frame.scrollFrame:SetPoint("BOTTOMRIGHT", -8, 8)
    frame.scrollFrame:EnableMouseWheel(true)
    frame.scrollFrame:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, 24, RefreshPetList)
    end)
    frame.scrollFrame:SetScript("OnMouseWheel", function(_, delta)
        ScrollPetList(delta)
    end)

    frame.petRows = {}
    for index = 1, 11 do
        local row = CreateFrame("Button", nil, frame.listBackdrop)
        row:SetSize(234, 24)
        row:SetPoint("TOPLEFT", 8, -8 - ((index - 1) * 24))
        row:RegisterForClicks("LeftButtonUp")
        row:EnableMouseWheel(true)

        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()

        row.name = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        row.name:SetPoint("TOPLEFT", 6, -3)
        row.name:SetPoint("RIGHT", -4, 0)
        row.name:SetJustifyH("LEFT")

        row.subName = row:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
        row.subName:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -1)
        row.subName:SetPoint("RIGHT", -4, 0)
        row.subName:SetJustifyH("LEFT")

        row:SetScript("OnClick", function(self)
            if self.petGUID then
                SelectPetFromList(self.petGUID)
                local petName = GetPetName(self.petGUID)
                if petName then
                    frame.petNameBox:SetText(petName)
                end
            end
        end)
        row:SetScript("OnMouseWheel", function(_, delta)
            ScrollPetList(delta)
        end)

        frame.petRows[index] = row
    end

    frame.emptyText = frame.listBackdrop:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    frame.emptyText:SetPoint("CENTER")
    frame.emptyText:SetText("No matching companion pets found.")
    frame.emptyText:Hide()

    frame.currentButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.currentButton:SetSize(160, 24)
    frame.currentButton:SetPoint("TOPLEFT", frame.petNameBox, "BOTTOMLEFT", 0, -12)
    frame.currentButton:SetText("Use Current Pet")
    frame.currentButton:SetScript("OnClick", function()
        SetCurrentPet()
        petListSelectionGUID = GetDB().petGUID
        RefreshCollectedPetsCache()
        RefreshSettingsPanel()
    end)

    frame.clearButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.clearButton:SetSize(120, 24)
    frame.clearButton:SetPoint("LEFT", frame.currentButton, "RIGHT", 10, 0)
    frame.clearButton:SetText("Clear")
    frame.clearButton:SetScript("OnClick", function()
        SetPetByName("")
        RefreshSettingsPanel()
    end)

    frame.useSelectedButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.useSelectedButton:SetSize(160, 24)
    frame.useSelectedButton:SetPoint("TOPLEFT", frame.listBackdrop, "BOTTOMLEFT", 0, -10)
    frame.useSelectedButton:SetText("Use Selected Pet")
    frame.useSelectedButton:SetScript("OnClick", function()
        if not petListSelectionGUID then
            return
        end
        local petName = GetPetName(petListSelectionGUID)
        if petName then
            frame.petNameBox:SetText(petName)
            SetPetByName(petName)
            RefreshCollectedPetsCache()
            RefreshSettingsPanel()
        end
    end)

    local help = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    help:SetPoint("TOPLEFT", frame.currentButton, "BOTTOMLEFT", 0, -12)
    help:SetWidth(290)
    help:SetJustifyH("LEFT")
    help:SetText("Use the list to pick one of your collected companion pets, or type a name manually if you prefer. If the named pet cannot be found and favorites mode is enabled, the addon will fall back to a random favorite.")

    frame.status = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    frame.status:SetPoint("TOPLEFT", help, "BOTTOMLEFT", 0, -16)
    frame.status:SetWidth(620)
    frame.status:SetJustifyH("LEFT")

    frame.refreshButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.refreshButton:SetSize(120, 24)
    frame.refreshButton:SetPoint("TOPLEFT", frame.status, "BOTTOMLEFT", 0, -12)
    frame.refreshButton:SetText("Summon Now")
    frame.refreshButton:SetScript("OnClick", function()
        AttemptSummon("settings summon")
        RefreshSettingsPanel()
    end)

    frame.previewFrame = CreateFrame("Frame", nil, frame)
    frame.previewFrame:SetPoint("TOPLEFT", frame.refreshButton, "BOTTOMLEFT", 0, -12)
    frame.previewFrame:SetSize(340, 148)

    frame.previewIcon = frame.previewFrame:CreateTexture(nil, "ARTWORK")
    frame.previewIcon:SetSize(frame.refreshButton:GetWidth(), frame.refreshButton:GetWidth())
    frame.previewIcon:SetPoint("TOPLEFT", 0, -2)

    frame.previewName = frame.previewFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    frame.previewName:SetPoint("TOPLEFT", frame.previewIcon, "TOPRIGHT", 12, -2)
    frame.previewName:SetPoint("RIGHT", 0, 0)
    frame.previewName:SetJustifyH("LEFT")

    frame.previewDetails = frame.previewFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    frame.previewDetails:SetPoint("TOPLEFT", frame.previewName, "BOTTOMLEFT", 0, -6)
    frame.previewDetails:SetPoint("RIGHT", 0, 0)
    frame.previewDetails:SetJustifyH("LEFT")
    frame.previewDetails:SetJustifyV("TOP")

    frame.previewEmpty = frame:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    frame.previewEmpty:SetPoint("TOPLEFT", frame.previewIcon, "BOTTOMLEFT", 0, -8)
    frame.previewEmpty:SetWidth(300)
    frame.previewEmpty:SetJustifyH("LEFT")
    frame.previewEmpty:SetText("Select a companion pet to preview it here.")

    frame:SetScript("OnShow", function()
        RefreshCollectedPetsCache()
        RefreshSettingsPanel()
    end)

    settingsPanel = frame
    return frame
end

local function RegisterSettingsPanel()
    if settingsCategory or not Settings or not Settings.RegisterCanvasLayoutCategory then
        return
    end

    local frame = CreateSettingsPanel()
    settingsCategory = Settings.RegisterCanvasLayoutCategory(frame, frame.name, frame.name)
    Settings.RegisterAddOnCategory(settingsCategory)
end

local function PrintStatus()
    local db = GetDB()
    local currentPet = GetCurrentPetGUID()
    local currentName = GetPetName(currentPet)
    local mode = db.useFavorites and "favorites" or "specific pet"
    local targetName = db.useFavorites and "random favorite" or (db.petName or "none")

    Print(("Enabled: %s. Mode: %s. Target: %s. Current companion: %s."):format(
        db.enabled and "yes" or "no",
        mode,
        targetName,
        currentName or "none"
    ))
end

local function HandleSlashCommand(message)
    local command, rest = strsplit(" ", message or "", 2)
    command = NormalizeName(command or "")
    rest = strtrim(rest or "")

    if not command or command == "" or command == "status" then
        PrintStatus()
        Print("Commands: /companionkeeper set <pet name>, /companionkeeper current, /companionkeeper favorites, /companionkeeper summon, /companionkeeper on, /companionkeeper off.")
        return
    end

    if command == "set" then
        if rest == "" then
            Print("Usage: /companionkeeper set <pet name>")
            return
        end

        SetPetByName(rest)
        return
    end

    if command == "current" then
        SetCurrentPet()
        return
    end

    if command == "favorites" then
        SetFavoritesMode()
        return
    end

    if command == "summon" then
        AttemptSummon("manual summon")
        return
    end

    if command == "on" or command == "enable" then
        GetDB().enabled = true
        Print("Enabled.")
        ScheduleCheck(0.2, "enabled")
        return
    end

    if command == "off" or command == "disable" then
        GetDB().enabled = false
        Print("Disabled.")
        return
    end

    if command == "clear" then
        local db = GetDB()
        db.petGUID = nil
        db.petName = nil
        db.useFavorites = false
        Print("Cleared saved companion pet.")
        return
    end

    Print(("Unknown command \"%s\"."):format(command))
end

function CompanionKeeper:OnEvent(event)
    if event == "PLAYER_LOGIN" then
        GetDB()
        RegisterSettingsPanel()
        self:RegisterEvent("PLAYER_ENTERING_WORLD")
        self:RegisterEvent("PLAYER_CONTROL_GAINED")
        self:RegisterEvent("PLAYER_MOUNT_DISPLAY_CHANGED")
        self:RegisterEvent("PLAYER_REGEN_ENABLED")
        self:RegisterEvent("PLAYER_ALIVE")
        self:RegisterEvent("ZONE_CHANGED_NEW_AREA")
        self:RegisterEvent("UPDATE_SUMMONPETS_ACTION")
        ScheduleCheck(3, "login")
        return
    end

    if pendingCheck or event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_CONTROL_GAINED" or event == "PLAYER_MOUNT_DISPLAY_CHANGED" or event == "PLAYER_REGEN_ENABLED" or event == "PLAYER_ALIVE" or event == "ZONE_CHANGED_NEW_AREA" or event == "UPDATE_SUMMONPETS_ACTION" then
        ScheduleCheck(GetDB().delaySeconds, event)
    end

    RefreshSettingsPanel()
end

CompanionKeeper:RegisterEvent("PLAYER_LOGIN")
CompanionKeeper:SetScript("OnEvent", CompanionKeeper.OnEvent)

SLASH_COMPANIONKEEPER1 = "/companionkeeper"
SLASH_COMPANIONKEEPER2 = "/ck"
SlashCmdList.COMPANIONKEEPER = HandleSlashCommand
