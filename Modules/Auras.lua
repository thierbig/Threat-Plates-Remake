----------------------------------------------------------------------
-- ThreatPlates Remake - Auras Module
-- Debuff & buff tracking on nameplates
-- 12.1+ (Midnight "Curse of Ula'tek"): uses the AuraContainer/AuraButton
-- system. The index/slot/instanceID getters in C_UnitAuras now raise Lua
-- errors while auras are secret (combat, dungeons, PvP), so the engine
-- must own aura enumeration; the addon only styles the buttons.
-- Pre-12.1 clients fall back to the old UNIT_AURA scanning path.
----------------------------------------------------------------------
local ADDON_NAME, TPR = ...
local Addon = TPR.Addon

local MAX_AURA_ICONS = 10 -- hard cap for icon pool

local HAS_AURA_CONTAINERS = C_XMLUtil and C_XMLUtil.GetTemplateInfo
    and C_XMLUtil.GetTemplateInfo("CustomAuraContainerTemplate") and true or false
TPR.HasAuraContainers = HAS_AURA_CONTAINERS

local function AurasAreSecret()
    return C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret()
end

----------------------------------------------------------------------
-- AuraContainer pool
-- Containers cannot be created during combat, but nameplate frames can
-- appear mid-combat, so a pool is filled while out of combat and drawn
-- from when a plate needs one.
----------------------------------------------------------------------
local containerPool = {}
local POOL_TARGET = 12

local function CreatePooledContainer()
    local c = CreateFrame("AuraContainer", nil, UIParent, "CustomAuraContainerTemplate")
    c:Hide()
    return c
end

function Addon:PreallocateAuraContainers()
    if not HAS_AURA_CONTAINERS or InCombatLockdown() then return end
    while #containerPool < POOL_TARGET do
        containerPool[#containerPool + 1] = CreatePooledContainer()
    end
end

local function AcquireAuraContainer()
    local c = table.remove(containerPool)
    if not c and not InCombatLockdown() then
        c = CreatePooledContainer()
    end
    return c -- nil when in combat with an empty pool
end

----------------------------------------------------------------------
-- AuraButton styling
-- Buttons are created by the engine; the addon supplies child regions
-- through the Set* registration APIs and the engine writes into them.
----------------------------------------------------------------------
local trackedButtons = setmetatable({}, { __mode = "k" })

-- SetFont fails (returns false) on an invalid font path and can leave the
-- font string font-less — and the engine SetText()s into registered regions,
-- which errors on a font-less FontString. Always land on a valid font.
local function SafeSetFont(fs, path, size, flags)
    if not fs:SetFont(path, size, flags) then
        fs:SetFont([[Fonts\FRIZQT__.TTF]], size, flags)
    end
end

local function StyleAuraButton(btn)
    local db = Addon.db.profile.auras
    local fontPath = TPR.ResolveFont(db.font)

    if not btn.tprIcon then
        -- Create and FULLY initialize each region before registering it:
        -- the engine writes into a region synchronously during the Set*
        -- registration call, so e.g. a font string registered without a
        -- font errors with "SetText(): Font not set".
        btn.tprBorder = btn:CreateTexture(nil, "BACKGROUND")
        btn.tprBorder:SetPoint("TOPLEFT", btn, "TOPLEFT", -1, 1)
        btn.tprBorder:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 1, -1)

        btn.tprIcon = btn:CreateTexture(nil, "ARTWORK")
        btn.tprIcon:SetAllPoints(btn)
        btn.tprIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

        -- Cooldown swipe; countdown numbers stay off — duration is shown
        -- through the engine-driven duration font string below.
        btn.tprCooldown = CreateFrame("Cooldown", nil, btn, "CooldownFrameTemplate")
        btn.tprCooldown:SetAllPoints(btn)
        btn.tprCooldown:SetDrawEdge(false)
        btn.tprCooldown:SetHideCountdownNumbers(true)

        btn.tprDuration = btn:CreateFontString(nil, "OVERLAY")
        btn.tprDuration:SetPoint("TOPRIGHT", btn, "TOPRIGHT", 2, 2)
        SafeSetFont(btn.tprDuration, fontPath, db.durationFontSize or 8, "OUTLINE")

        btn.tprStacks = btn:CreateFontString(nil, "OVERLAY")
        btn.tprStacks:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 1, -1)
        SafeSetFont(btn.tprStacks, fontPath, db.fontSize or 8, "OUTLINE")

        btn:SetIcon(btn.tprIcon)
        btn:SetDurationCooldown(btn.tprCooldown)
        btn:SetDurationText(btn.tprDuration)
        btn:SetApplicationCount(btn.tprStacks)
        btn:SetMouseMotionEnabled(false)
    end

    local size = db.iconSize or 20
    btn:SetSize(size, size)

    local bc = db.borderColor or { r = 0, g = 0, b = 0, a = 1 }
    btn.tprBorder:SetColorTexture(bc.r, bc.g, bc.b, bc.a)

    btn.tprCooldown:SetDrawSwipe(db.showCooldownSpiral and true or false)

    SafeSetFont(btn.tprDuration, fontPath, db.durationFontSize or 8, "OUTLINE")
    btn.tprDuration:SetTextColor(1, 1, 1, 1)
    -- The engine manages Show/Hide of registered regions; alpha implements
    -- the user toggles without fighting it.
    btn.tprDuration:SetAlpha(db.showDuration and 1 or 0)

    SafeSetFont(btn.tprStacks, fontPath, db.fontSize or 8, "OUTLINE")
    btn.tprStacks:SetTextColor(1, 1, 1, 1)
    btn.tprStacks:SetAlpha(db.showStacks and 1 or 0)
end

local function InitializeAuraButton(btn)
    trackedButtons[btn] = true
    local ok, err = pcall(StyleAuraButton, btn)
    if not ok then geterrorhandler()(err) end
end

function Addon:RestyleAuraButtons()
    if InCombatLockdown() or AurasAreSecret() then return end
    for btn in pairs(trackedButtons) do
        local ok, err = pcall(StyleAuraButton, btn)
        if not ok then geterrorhandler()(err) end
    end
end

----------------------------------------------------------------------
-- Container configuration (groups + filters from the profile)
----------------------------------------------------------------------
local auraConfigEpoch = 1

local function SpellMapToArray(map)
    local arr = {}
    for spellId in pairs(map) do
        -- Container candidate filters accept spell IDs only
        if type(spellId) == "number" then
            arr[#arr + 1] = spellId
        end
    end
    return arr
end

local function BuildCandidateFilters(db)
    if db.filterMode == "WHITELIST" and next(db.whitelist) ~= nil then
        return { includeSpellIDs = SpellMapToArray(db.whitelist) }
    elseif db.filterMode == "BLACKLIST" and next(db.blacklist) ~= nil then
        return { excludeSpellIDs = SpellMapToArray(db.blacklist) }
    end
    return {}
end

local function DesiredAuraGroups(db)
    local suffix = db.onlyMine and "|PLAYER" or ""
    local groups = {}
    if db.showDebuffs then groups.debuffs = "HARMFUL" .. suffix end
    if db.showBuffs then groups.buffs = "HELPFUL" .. suffix end
    return groups
end

-- Deterministic row order: debuffs left of buffs
local GROUP_LAYOUT_INDEX = { debuffs = 1, buffs = 2 }

function Addon:ConfigureAuraContainer(container)
    local db = self.db.profile.auras
    local desired = DesiredAuraGroups(db)
    local filters = BuildCandidateFilters(db)
    local maxShow = math.min(db.maxAuras or 5, MAX_AURA_ICONS)

    container._groups = container._groups or {}

    for key, filterString in pairs(desired) do
        -- Layout keys per Blizzard_CustomAuraContainer.lua (12.1.0).
        -- elementWidth/Height feed the engine's spacing math so it always
        -- matches the visual button size set in StyleAuraButton; the
        -- container then auto-sizes to the row, and its CENTER anchor on
        -- auraFrame keeps the row centered like the old manual layout.
        local iconSize = db.iconSize or 20
        local spacing = db.iconSpacing or 2
        local layout = {
            elementSpacing = spacing,
            groupSpacing = spacing,
            elementWidth = iconSize,
            elementHeight = iconSize,
            layoutIndex = GROUP_LAYOUT_INDEX[key],
        }
        if container._groups[key] then
            container:SetAuraGroupFilterString(key, filterString)
            container:SetAuraGroupCandidateFilters(key, filters)
            container:SetAuraGroupMaxFrameCount(key, maxShow)
            container:SetAuraGroupLayout(key, layout)
        else
            container:AddAuraGroup(key, filterString, {
                maxFrameCount = maxShow,
                candidateFilters = filters,
                initializeFrame = InitializeAuraButton,
                layout = layout,
            })
            container._groups[key] = true
        end
    end

    -- Groups cannot be removed once added; zero frames is the off switch
    for key in pairs(container._groups) do
        if not desired[key] then
            container:SetAuraGroupMaxFrameCount(key, 0)
        end
    end
end

-- Called from RefreshAllPlates whenever settings may have changed
function Addon:AuraConfigChanged()
    if not HAS_AURA_CONTAINERS then return end
    auraConfigEpoch = auraConfigEpoch + 1
    self:RestyleAuraButtons()
end

----------------------------------------------------------------------
-- Attach a container to a nameplate custom frame
----------------------------------------------------------------------
local function AttachAuraContainer(frame)
    local container = AcquireAuraContainer()
    if not container then
        frame.auraContainerPending = true
        return nil
    end
    frame.auraContainerPending = nil
    container:SetParent(frame.auraFrame)
    container:ClearAllPoints()
    container:SetPoint("CENTER", frame.auraFrame, "CENTER", 0, 0)
    container:Show()
    frame.auraContainer = container
    return container
end

----------------------------------------------------------------------
-- Create Aura Container
----------------------------------------------------------------------
function Addon:CreateAuraFrame(frame)
    local db = self.db.profile

    local auraFrame = CreateFrame("Frame", nil, frame.container)
    auraFrame:SetSize(db.healthbar.width or 120, db.auras.iconSize or 20)
    -- Initial position set by LayoutElements() in Core.lua
    auraFrame:SetFrameLevel(frame.container:GetFrameLevel() + 5)
    frame.auraFrame = auraFrame

    if HAS_AURA_CONTAINERS then
        -- May defer to combat end when the pool is dry
        AttachAuraContainer(frame)
        return
    end

    -- Legacy: pre-create icon pool
    auraFrame.icons = {}
    for i = 1, MAX_AURA_ICONS do
        auraFrame.icons[i] = self:CreateAuraIcon(auraFrame, i)
    end
end

----------------------------------------------------------------------
-- Update Auras (12.1 container path)
----------------------------------------------------------------------
function Addon:UpdateAurasContainer(frame, unitId)
    local db = self.db.profile.auras
    local container = frame.auraContainer
    if not container then
        container = AttachAuraContainer(frame)
        if not container then return end -- attached after combat instead
    end

    if not db.enabled then
        container:SetEnabled(false)
        return
    end

    if container._configEpoch ~= auraConfigEpoch then
        if InCombatLockdown() or AurasAreSecret() then
            container._configDirty = true
        else
            self:ConfigureAuraContainer(container)
            container._configEpoch = auraConfigEpoch
            container._configDirty = nil
        end
    end

    if container._unit ~= unitId then
        container:SetUnit(unitId)
        container._unit = unitId
    end
    container:SetEnabled(true)
end

-- Called when a nameplate frame is released: the same unit token can come
-- back holding a different unit, so force the next UpdateAuras to SetUnit.
function Addon:ResetAuraUnit(frame)
    if frame and frame.auraContainer then
        frame.auraContainer._unit = nil
        frame.auraContainer:SetEnabled(false)
    end
end

-- Called from Core's OnCombatEnd: refill the pool, attach containers to
-- plates that appeared mid-combat, and apply deferred config changes.
function Addon:OnAuraCombatEnd()
    if not HAS_AURA_CONTAINERS then return end
    self:PreallocateAuraContainers()

    local retry = false
    for _, frame in pairs(TPR.ActivePlates) do
        if frame.unitId and (frame.auraContainerPending
            or (frame.auraContainer and frame.auraContainer._configDirty)) then
            if AurasAreSecret() then
                retry = true
            else
                self:UpdateAuras(frame, frame.unitId)
            end
        end
    end
    self:RestyleAuraButtons()

    -- Aura secrecy can outlast combat briefly; try again shortly
    if retry then
        C_Timer.After(2, function()
            if not InCombatLockdown() then
                Addon:OnAuraCombatEnd()
            end
        end)
    end
end

----------------------------------------------------------------------
-- Create Individual Aura Icon (legacy pre-12.1 path)
----------------------------------------------------------------------
function Addon:CreateAuraIcon(parent, index)
    local db = self.db.profile
    local size = db.auras.iconSize or 20

    local icon = CreateFrame("Frame", nil, parent)
    icon:SetSize(size, size)

    -- Border texture (1px behind the icon art)
    icon.border = icon:CreateTexture(nil, "BACKGROUND")
    icon.border:SetPoint("TOPLEFT", icon, "TOPLEFT", -1, 1)
    icon.border:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
    icon.border:SetColorTexture(0, 0, 0, 1)

    -- Texture (inset slightly so border shows)
    icon.texture = icon:CreateTexture(nil, "ARTWORK")
    icon.texture:SetAllPoints(icon)
    icon.texture:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    -- Cooldown spiral (hidden — clean look, just show duration number)
    icon.cooldown = CreateFrame("Cooldown", nil, icon, "CooldownFrameTemplate")
    icon.cooldown:SetAllPoints(icon)
    icon.cooldown:SetDrawEdge(false)
    icon.cooldown:SetDrawSwipe(false)
    icon.cooldown:SetHideCountdownNumbers(true)

    -- Duration text — small number at top-right of icon
    icon.duration = icon:CreateFontString(nil, "OVERLAY")
    local dfs = db.auras.durationFontSize or 8
    icon.duration:SetFont(TPR.ResolveFont(db.auras.font), dfs, "OUTLINE")
    icon.duration:SetPoint("TOPRIGHT", icon, "TOPRIGHT", 2, 2)
    icon.duration:SetTextColor(1, 1, 1, 1)
    icon.duration:Hide()

    -- Stack count
    icon.stacks = icon:CreateFontString(nil, "OVERLAY")
    icon.stacks:SetFont(TPR.ResolveFont(db.auras.font), db.auras.fontSize or 8, "OUTLINE")
    icon.stacks:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
    icon.stacks:SetTextColor(1, 1, 1, 1)

    icon:Hide()
    return icon
end

----------------------------------------------------------------------
-- Update Auras for a Unit
-- 12.1+: engine-driven AuraContainer. Pre-12.1: manual scan.
----------------------------------------------------------------------
function Addon:UpdateAuras(frame, unitId)
    if not frame or not frame.auraFrame or not unitId then return end

    if HAS_AURA_CONTAINERS then
        return self:UpdateAurasContainer(frame, unitId)
    end

    local db = self.db.profile
    if not db.auras.enabled then
        for i = 1, MAX_AURA_ICONS do
            frame.auraFrame.icons[i]:Hide()
        end
        return
    end

    local auras = {}

    -- Build filter strings. In 12.0, use the "|PLAYER" flag at the API level
    -- to only get player-applied auras (bypasses secret value filtering issues).
    local playerSuffix = db.auras.onlyMine and "|PLAYER" or ""

    if db.auras.showDebuffs then
        self:CollectAuras(unitId, "HARMFUL" .. playerSuffix, auras, db)
    end

    if db.auras.showBuffs then
        self:CollectAuras(unitId, "HELPFUL" .. playerSuffix, auras, db)
    end

    -- In 12.0, expirationTime may be secret so we can't sort by it.
    -- Display auras in the order received instead.

    -- Display
    local maxShow = math.min(db.auras.maxAuras or 5, MAX_AURA_ICONS, #auras)
    local iconSize = db.auras.iconSize or 20
    local spacing = db.auras.iconSpacing or 2
    local totalWidth = (maxShow * iconSize) + ((maxShow - 1) * spacing)
    local startX = -totalWidth / 2

    for i = 1, MAX_AURA_ICONS do
        local iconFrame = frame.auraFrame.icons[i]
        if i <= maxShow then
            local aura = auras[i]
            self:SetAuraIcon(iconFrame, aura, db, unitId)

            iconFrame:SetSize(iconSize, iconSize)
            iconFrame:ClearAllPoints()
            iconFrame:SetPoint("LEFT", frame.auraFrame, "CENTER", startX + (i - 1) * (iconSize + spacing), 0)
            iconFrame:Show()
        else
            iconFrame:Hide()
            iconFrame:SetScript("OnUpdate", nil)
            if iconFrame.duration then iconFrame.duration:Hide() end
        end
    end
end

----------------------------------------------------------------------
-- Collect Auras (legacy pre-12.1 path)
-- Uses GetUnitAuraInstanceIDs() if available, falls back to
-- GetAuraDataBySlot or ForEachAura.
----------------------------------------------------------------------
function Addon:CollectAuras(unitId, filter, auras, db)
    local function ProcessAura(aura)
        if not aura then return end

        -- In 12.0, "only mine" filtering is handled by the "|PLAYER" flag
        -- in the API filter string, so we don't need to check sourceUnit here.

        local isSecret = issecretvalue or function() return false end

        -- Whitelist/blacklist filtering (skipped when spell IDs are secret)
        if db.auras.filterMode == "WHITELIST" and next(db.auras.whitelist) ~= nil then
            local spellId = aura.spellId
            if spellId and not isSecret(spellId) then
                if not db.auras.whitelist[spellId] then
                    return
                end
            end
        elseif db.auras.filterMode == "BLACKLIST" then
            local spellId = aura.spellId
            if spellId and not isSecret(spellId) then
                if db.auras.blacklist[spellId] then
                    return
                end
            end
        end

        -- Use filter string to determine harmful since isHarmful may be secret
        -- filter may be "HARMFUL|PLAYER" so check with string.find
        table.insert(auras, {
            name = aura.name,
            icon = aura.icon,
            stacks = aura.applications,
            duration = aura.duration,
            expirationTime = aura.expirationTime,
            spellId = aura.spellId,
            isHarmful = (string.find(filter, "HARMFUL") ~= nil),
            dispelType = aura.dispelName,
            auraInstanceID = aura.auraInstanceID,
        })
    end

    -- Method 1: GetUnitAuraInstanceIDs (new in 12.0, preferred)
    if C_UnitAuras and C_UnitAuras.GetUnitAuraInstanceIDs then
        local instanceIDs = C_UnitAuras.GetUnitAuraInstanceIDs(unitId, filter)
        if instanceIDs then
            for _, instanceID in ipairs(instanceIDs) do
                local aura = C_UnitAuras.GetAuraDataByAuraInstanceID(unitId, instanceID)
                if aura then
                    ProcessAura(aura)
                end
            end
            return
        end
    end

    -- Method 2: GetAuraDataBySlot (TWW+)
    if C_UnitAuras and C_UnitAuras.GetAuraDataBySlot then
        local slot = 1
        local found = false
        while slot <= 80 do
            local aura = C_UnitAuras.GetAuraDataBySlot(unitId, slot)
            if not aura then break end
            found = true

            local isHarmful = aura.isHarmful
            local wantHarmful = (string.find(filter, "HARMFUL") ~= nil)
            if (wantHarmful and isHarmful) or (not wantHarmful and not isHarmful) then
                ProcessAura(aura)
            end
            slot = slot + 1
        end
        if found then return end
    end

    -- Method 3: ForEachAura fallback
    if AuraUtil and AuraUtil.ForEachAura then
        AuraUtil.ForEachAura(unitId, filter, nil, function(aura)
            ProcessAura(aura)
        end, true)
    end
end

----------------------------------------------------------------------
-- Apply Aura Data to Icon Frame (legacy pre-12.1 path)
-- Secret values are passed directly to widget APIs (SetTexture,
-- SetText, SetCooldown) which accept them.
----------------------------------------------------------------------
function Addon:SetAuraIcon(iconFrame, aura, db, unitId)
    if not aura then
        iconFrame:Hide()
        return
    end

    -- Texture (SetTexture accepts secret texture paths)
    iconFrame.texture:SetTexture(aura.icon)

    -- Border color (keep thin black border — clean look)
    if iconFrame.border then
        iconFrame.border:SetColorTexture(0, 0, 0, 1)
    end

    -- Stack count — only show if stacks > 1
    -- In 12.0, applications is a secret value. Lua cannot coerce it to string
    -- (so SetText(secret) silently shows nothing). SetFormattedText does the
    -- format in C-space and handles secret values correctly.
    if db.auras.showStacks and aura.stacks then
        local ok, gt1 = pcall(function() return aura.stacks > 1 end)
        local showStacks = (not ok) or gt1  -- secret = show; known >1 = show; known <=1 = hide
        if showStacks then
            -- string.format works for plain numbers; SetFormattedText works for secrets
            local textOk = pcall(function()
                iconFrame.stacks:SetText(string.format("%d", aura.stacks))
            end)
            if not textOk then
                pcall(function()
                    iconFrame.stacks:SetFormattedText("%d", aura.stacks)
                end)
            end
            iconFrame.stacks:Show()
        else
            iconFrame.stacks:Hide()
        end
    else
        iconFrame.stacks:Hide()
    end

    -- In Midnight (12.0), aura duration/expirationTime are secret values.
    -- Use C_UnitAuras.GetAuraDuration() which returns a DurationObject,
    -- then use SetCooldownFromDurationObject() and GetRemainingDuration().
    local durationObj
    if C_UnitAuras and C_UnitAuras.GetAuraDuration and unitId and aura.auraInstanceID then
        durationObj = C_UnitAuras.GetAuraDuration(unitId, aura.auraInstanceID)
    end

    -- Cooldown spiral
    if db.auras.showCooldownSpiral then
        if durationObj and iconFrame.cooldown.SetCooldownFromDurationObject then
            -- Midnight path: use DurationObject directly
            iconFrame.cooldown:SetCooldownFromDurationObject(durationObj)
            iconFrame.cooldown:Show()
        elseif aura.duration and aura.expirationTime then
            -- Fallback: try arithmetic (may fail with secrets)
            pcall(function()
                iconFrame.cooldown:SetCooldown(aura.expirationTime - aura.duration, aura.duration)
            end)
            iconFrame.cooldown:Show()
        else
            iconFrame.cooldown:Hide()
        end
    else
        iconFrame.cooldown:Hide()
    end

    -- Custom duration text on icon
    if db.auras.showDuration and iconFrame.duration then
        iconFrame.durationObject = durationObj
        iconFrame.expirationTime = aura.expirationTime
        if durationObj or aura.expirationTime then
            iconFrame.duration:Show()
            -- Set up OnUpdate to tick the duration text
            iconFrame:SetScript("OnUpdate", function(self, elapsed)
                self._elapsed = (self._elapsed or 0) + elapsed
                if self._elapsed < 0.1 then return end
                self._elapsed = 0
                if self.durationObject and self.durationObject.GetRemainingDuration then
                    -- GetRemainingDuration returns a secret — pass directly to format
                    self.duration:SetText(string.format("%.0f", self.durationObject:GetRemainingDuration()))
                else
                    self.duration:SetText("")
                end
            end)
        else
            iconFrame.duration:Hide()
            iconFrame:SetScript("OnUpdate", nil)
        end
    elseif iconFrame.duration then
        iconFrame.duration:Hide()
        iconFrame:SetScript("OnUpdate", nil)
    end
end

----------------------------------------------------------------------
-- Format Duration (e.g. 5.1, 1:23, 5m)
----------------------------------------------------------------------
function Addon:FormatDuration(seconds)
    if seconds < 10 then
        return string.format("%.1f", seconds)
    elseif seconds < 60 then
        return string.format("%d", math.floor(seconds))
    elseif seconds < 3600 then
        return string.format("%dm", math.floor(seconds / 60))
    else
        return string.format("%dh", math.floor(seconds / 3600))
    end
end
