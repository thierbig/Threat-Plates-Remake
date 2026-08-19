----------------------------------------------------------------------
-- ThreatPlates Remake - Core
-- Main addon bootstrap, nameplate driver, frame pool management
-- Updated for WoW Midnight (12.0) Secret Values API
----------------------------------------------------------------------
local ADDON_NAME, TPR = ...

-- Create Ace3 addon
local Addon = LibStub("AceAddon-3.0"):NewAddon(ADDON_NAME, "AceEvent-3.0", "AceConsole-3.0", "AceTimer-3.0", "AceSerializer-3.0")
TPR.Addon = Addon
TPR.Version = "1.1.0"

-- Shared namespace for modules
TPR.ActivePlates = {} -- [nameplate] = our custom frame
TPR.NameplatesByUnit = {} -- [unitId] = nameplate frame

-- Track current target via events (avoids secret value issues with UnitIsUnit in combat)
TPR.CurrentTarget = nil

-- Upvalues
local pairs, ipairs = pairs, ipairs
local UnitExists = UnitExists
local UnitIsUnit = UnitIsUnit
local GetNamePlateForUnit = C_NamePlate.GetNamePlateForUnit

----------------------------------------------------------------------
-- Addon Lifecycle
----------------------------------------------------------------------
function Addon:OnInitialize()
    -- Database is set up in Database.lua
    self:SetupDatabase()

    -- Config panel
    self:SetupConfig()

    -- Slash command
    self:RegisterChatCommand("tpr", "SlashCommand")
    self:RegisterChatCommand("threatplates", "SlashCommand")
end

function Addon:OnEnable()
    -- Nameplate events
    self:RegisterEvent("NAME_PLATE_CREATED", "OnNamePlateCreated")
    self:RegisterEvent("NAME_PLATE_UNIT_ADDED", "OnNamePlateUnitAdded")
    self:RegisterEvent("NAME_PLATE_UNIT_REMOVED", "OnNamePlateUnitRemoved")

    -- Combat & target events
    self:RegisterEvent("PLAYER_TARGET_CHANGED", "OnTargetChanged")
    self:RegisterEvent("PLAYER_REGEN_ENABLED", "OnCombatEnd")
    self:RegisterEvent("PLAYER_REGEN_DISABLED", "OnCombatStart")

    -- Unit events
    self:RegisterEvent("UNIT_HEALTH", "OnUnitHealth")
    self:RegisterEvent("UNIT_AURA", "OnUnitAura")
    self:RegisterEvent("UNIT_THREAT_LIST_UPDATE", "OnThreatUpdate")
    self:RegisterEvent("UNIT_NAME_UPDATE", "OnUnitNameUpdate")
    self:RegisterEvent("UNIT_FACTION", "OnUnitFaction")
    self:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED", "OnSpellSucceeded")
    self:RegisterEvent("UNIT_SPELLCAST_START", "OnCastStart")
    self:RegisterEvent("UNIT_SPELLCAST_STOP", "OnCastStop")
    self:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START", "OnChannelStart")
    self:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP", "OnChannelStop")
    self:RegisterEvent("UNIT_SPELLCAST_INTERRUPTIBLE", "OnCastInterruptible")
    self:RegisterEvent("UNIT_SPELLCAST_NOT_INTERRUPTIBLE", "OnCastNotInterruptible")

    -- Power events (combo points, holy power, chi, etc.)
    self:RegisterEvent("UNIT_POWER_UPDATE", "OnPowerUpdate")
    self:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED", "OnSpecChanged")

    -- Apply CVars for nameplate behavior
    self:ApplyCVars()

    -- 12.1: AuraContainers can't be created in combat — fill the pool now
    self:PreallocateAuraContainers()

    -- Periodic cast bar validation: clear bars whose unit stopped casting without
    -- firing a CHANNEL_STOP / CAST_STOP event (dies mid-channel, leaves range, etc.)
    self:ScheduleRepeatingTimer("ValidateCastBars", 0.5)

    -- Periodic CD timer refresh (updates countdown text on pvp cooldown icons)
    self:ScheduleRepeatingTimer("UpdateAllCooldownTimers", 1.0)

    -- Process any existing nameplates (reload scenario)
    for _, plate in ipairs(C_NamePlate.GetNamePlates()) do
        self:OnNamePlateCreated(nil, plate)
        local unit = plate.namePlateUnitToken
        if unit then
            self:OnNamePlateUnitAdded(nil, unit)
        end
    end

    self:Print("ThreatPlates Remake v" .. TPR.Version .. " loaded. Type /tpr to open config.")
    self:Print("For any issues / bugs contact: https://github.com/SheaGlass/Threat-Plates-Remake")
end

function Addon:OnDisable()
    -- Restore default plates
    for plate, frame in pairs(TPR.ActivePlates) do
        self:ReleaseCustomFrame(plate)
    end
end

----------------------------------------------------------------------
-- CVar Management (Midnight: many CVars removed)
----------------------------------------------------------------------
function Addon:ApplyCVars()
    -- SetCVar is protected — can only be called out of combat and not from
    -- secure-frame callbacks. Use pcall to avoid ADDON_ACTION_BLOCKED errors.
    if InCombatLockdown() then return end

    local db = self.db.profile
    local friendly = db.general.friendlyPlates and 1 or 0
    pcall(C_CVar.SetCVar, "nameplateMaxDistance", db.general.nameplateRange or 60)
    pcall(C_CVar.SetCVar, "nameplateShowEnemies", 1)
    pcall(C_CVar.SetCVar, "nameplateShowFriendlyNPCs", friendly)

    -- Friendly PLAYER nameplates: "nameplateShowFriends" was removed in
    -- 12.0.5; "nameplateShowFriendlyPlayers" is the live CVar since then.
    pcall(C_CVar.SetCVar, "nameplateShowFriendlyPlayers", friendly)
end

----------------------------------------------------------------------
-- Slash Command
----------------------------------------------------------------------
function Addon:SlashCommand(input)
    if input == "reset" then
        self.db:ResetProfile()
        self:Print("Profile reset to defaults.")
    else
        LibStub("AceConfigDialog-3.0"):Open(ADDON_NAME)
    end
end

----------------------------------------------------------------------
-- Nameplate Lifecycle Events
----------------------------------------------------------------------
function Addon:OnNamePlateCreated(_, plate)
    if not plate or TPR.ActivePlates[plate] then return end
    local customFrame = self:CreateCustomFrame(plate)
    TPR.ActivePlates[plate] = customFrame

    -- Hook Blizzard frame early so it's suppressed from the start
    self:HookBlizzardFrame(plate)
end

function Addon:OnNamePlateUnitAdded(_, unitId, _isRetry)
    -- Retry paths (UNIT_FACTION fallback) can feed any unit token here, but
    -- only nameplate tokens can resolve to a plate — and since 12.1,
    -- GetNamePlateForUnit hard-errors on boss<n> tokens instead of
    -- returning nil. A unit that has a plate also fires unit events with
    -- its nameplateN token, so filtering loses nothing.
    if not unitId or not string.find(string.lower(unitId), "^nameplate%d") then return end

    local plate = GetNamePlateForUnit(unitId)
    if not plate then
        -- Plate frame may not be registered on the same tick (faction change, spawn after interaction).
        -- Schedule a single retry on the next frame.
        if not _isRetry then
            self:ScheduleTimer(function()
                if UnitExists(unitId) then
                    self:OnNamePlateUnitAdded(nil, unitId, true)
                end
            end, 0.05)
        end
        return
    end

    TPR.NameplatesByUnit[unitId] = plate

    local customFrame = TPR.ActivePlates[plate]
    if not customFrame then
        self:OnNamePlateCreated(nil, plate)
        customFrame = TPR.ActivePlates[plate]
    end

    if customFrame then
        -- Hide enemy pet nameplates entirely if option is enabled
        local db = self.db.profile
        if db.general.hideEnemyPets then
            local isPet = UnitIsOtherPlayersPet and UnitIsOtherPlayersPet(unitId)
            if isPet then
                self:HideBlizzardFrame(plate) -- suppress Blizzard frame too
                return
            end
        end

        customFrame.unitId = unitId
        self:ConfigureFrame(customFrame, unitId)
        customFrame:Show()

        -- Hide default Blizzard nameplate elements
        self:HideBlizzardFrame(plate)
    end
end

function Addon:OnNamePlateUnitRemoved(_, unitId)
    local plate = TPR.NameplatesByUnit[unitId]
    if plate then
        local customFrame = TPR.ActivePlates[plate]
        if customFrame then
            -- Clear cast state before hiding — frame may be recycled for another unit
            self:StopCastForFrame(customFrame)
            self:ResetAuraUnit(customFrame)
            customFrame:Hide()
            customFrame.unitId = nil
        end
        TPR.NameplatesByUnit[unitId] = nil
        self:ClearUnitCooldowns(unitId)
    end

    -- Restore Blizzard frame visibility
    if plate then
        self:ShowBlizzardFrame(plate)
    end
end

----------------------------------------------------------------------
-- Custom Frame Creation
----------------------------------------------------------------------
function Addon:CreateCustomFrame(plate)
    local db = self.db.profile

    local f = CreateFrame("Frame", nil, plate)
    f:SetAllPoints(plate)
    f:SetFrameStrata("LOW")
    f:SetFrameLevel(plate:GetFrameLevel() + 2)
    f:EnableMouse(false)
    f:SetMouseClickEnabled(false)
    f:SetMouseMotionEnabled(false)

    -- Main container - positions relative to nameplate anchor
    f.container = CreateFrame("Frame", nil, f)
    f.container:SetPoint("CENTER", f, "CENTER", 0, 0)

    -- Create sub-modules
    self:CreateHealthBar(f)
    self:CreateCastBar(f)
    self:CreateAuraFrame(f)
    self:CreateThreatGlow(f)
    self:CreateTargetHighlight(f)
    self:CreateComboPoints(f)
    self:CreateQuestIcon(f)
    self:CreateCooldownFrame(f)

    -- Name text (UnitName returns secret for NPCs in 12.0, but SetText accepts secrets)
    local nt = db.healthbar.nameText or {}
    f.name = f.container:CreateFontString(nil, "OVERLAY")
    f.name:SetFont(TPR.ResolveFont(nt.font), nt.fontSize or 10, nt.fontFlags or "OUTLINE")
    -- Initial position set by LayoutElements()
    local nc = nt.color or { r = 1, g = 1, b = 1, a = 1 }
    f.name:SetTextColor(nc.r, nc.g, nc.b, nc.a)

    -- Level text (inside health bar, right side — classic ThreatPlates style)
    f.level = f.healthbar:CreateFontString(nil, "OVERLAY")
    f.level:SetFont(TPR.ResolveFont(db.healthbar.font), 9, db.healthbar.fontFlags or "OUTLINE")
    f.level:SetPoint("RIGHT", f.healthbar, "RIGHT", -2, 0)
    f.level:SetTextColor(1, 1, 1, 1)

    -- Raid icon
    f.raidIcon = f.container:CreateTexture(nil, "OVERLAY")
    f.raidIcon:SetSize(20, 20)
    -- Initial position set by LayoutElements()
    f.raidIcon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
    f.raidIcon:Hide()

    f:Hide()
    return f
end

----------------------------------------------------------------------
-- Frame Configuration (called when unit is assigned)
----------------------------------------------------------------------
function Addon:ConfigureFrame(frame, unitId)
    if not UnitExists(unitId) then return end

    -- Always clear stale cast state when (re)assigning a unit to a frame
    self:StopCastForFrame(frame)

    local db = self.db.profile

    -- Sizing
    local width = db.healthbar.width or 120
    local height = db.healthbar.height or 12
    frame.container:SetSize(width, height + 40) -- Extra space for name + castbar

    -- Name text appearance (uses separate nameText settings)
    local nt = db.healthbar.nameText or {}
    frame.name:SetFont(TPR.ResolveFont(nt.font), nt.fontSize or 10, nt.fontFlags or "OUTLINE")
    -- Position set by LayoutElements() at end of ConfigureFrame
    local nc = nt.color or { r = 1, g = 1, b = 1, a = 1 }
    frame.name:SetTextColor(nc.r, nc.g, nc.b, nc.a)

    -- Name (SetText accepts secret strings from UnitName in 12.0)
    local name = UnitName(unitId)
    if nt.show ~= false and name then
        frame.name:SetText(name)
        frame.name:Show()
    else
        frame.name:SetText("")
        frame.name:Hide()
    end

    -- Level
    if db.healthbar.showLevel then
        local effectiveLevel = UnitEffectiveLevel(unitId)
        if effectiveLevel and effectiveLevel == -1 then
            frame.level:SetText("??")
            frame.level:SetTextColor(1, 0, 0)
        elseif effectiveLevel then
            frame.level:SetText(tostring(effectiveLevel))
            local color = GetCreatureDifficultyColor(effectiveLevel)
            if color then
                frame.level:SetTextColor(color.r, color.g, color.b)
            end
        end
        frame.level:Show()
    else
        frame.level:SetText("")
        frame.level:Hide()
    end

    -- Color the health bar (class colors for players, reaction colors for NPCs)
    local isPlayer = UnitIsPlayer(unitId)
    local isEnemy = UnitCanAttack("player", unitId)  -- true for BG enemies, training dummies, etc.
    local wantClassColor = isPlayer and (isEnemy and db.healthbar.pvpClassColors or (not isEnemy and db.healthbar.classColor))
    local classColorApplied = false
    if wantClassColor then
        local _, class = UnitClass(unitId)
        if class then
            -- 12.1: UnitClass returns a secret token for identity-hidden
            -- players (arena/BG), and indexing a table with a secret key
            -- now raises an error (12.0 returned nil). Route secret tokens
            -- through C_ClassColor.GetClassColor, which is C-level and
            -- accepts secrets; its ColorMixin fields (possibly secret) go
            -- straight to the widget, which accepts them.
            if issecretvalue and issecretvalue(class) then
                if C_ClassColor and C_ClassColor.GetClassColor then
                    local ok, cm = pcall(C_ClassColor.GetClassColor, class)
                    if ok and cm then
                        classColorApplied = pcall(frame.healthbar.SetStatusBarColor,
                            frame.healthbar, cm.r, cm.g, cm.b, 1)
                    end
                end
            else
                local directColor = RAID_CLASS_COLORS[class]
                if directColor then
                    frame.healthbar:SetStatusBarColor(directColor.r, directColor.g, directColor.b, 1)
                    classColorApplied = true
                end
            end
        end
    end
    if not classColorApplied then
        if db.healthbar.reactionColor then
            -- Use UnitSelectionColor like Plater (returns proper reaction colors)
            if UnitSelectionColor then
                local r, g, b = UnitSelectionColor(unitId)
                if r then
                    frame.healthbar:SetStatusBarColor(r, g, b, 1)
                end
            else
                local reaction = UnitReaction(unitId, "player") or 4
                if reaction >= 5 then
                    frame.healthbar:SetStatusBarColor(0, 0.8, 0, 1)
                elseif reaction == 4 then
                    frame.healthbar:SetStatusBarColor(1, 1, 0, 1)
                else
                    frame.healthbar:SetStatusBarColor(1, 0, 0, 1)
                end
            end
        else
            -- Custom fixed colors from config
            local reaction = UnitReaction(unitId, "player") or 4
            if reaction >= 5 then
                local c = db.healthbar.customFriendly
                frame.healthbar:SetStatusBarColor(c.r, c.g, c.b, 1)
            elseif reaction == 4 then
                local c = db.healthbar.customNeutral
                frame.healthbar:SetStatusBarColor(c.r, c.g, c.b, 1)
            else
                local c = db.healthbar.customHostile
                frame.healthbar:SetStatusBarColor(c.r, c.g, c.b, 1)
            end
        end
    end

    -- Update bar appearance (texture, size, font) from current settings
    self:UpdateHealthBarAppearance(frame)

    -- Health (secret-safe: pass directly to StatusBar)
    self:UpdateHealth(frame, unitId)

    -- Raid target icon
    local raidIndex = GetRaidTargetIndex(unitId)
    if raidIndex then
        SetRaidTargetIconTexture(frame.raidIcon, raidIndex)
        frame.raidIcon:Show()
    else
        frame.raidIcon:Hide()
    end

    -- Auras
    self:UpdateAuras(frame, unitId)

    -- Threat
    self:UpdateThreat(frame, unitId)

    -- Target highlight
    self:UpdateTargetHighlight(frame, unitId)

    -- Combo points
    self:UpdateComboPoints(frame, unitId)

    -- Quest icon
    self:UpdateQuestIcon(frame, unitId)

    -- PvP cooldown tracker
    self:UpdateCooldowns(frame, unitId)

    -- Auto-stack layout so elements don't overlap
    self:LayoutElements(frame)
end

----------------------------------------------------------------------
-- Layout Engine — auto-stacks elements so nothing overlaps
-- Above health bar (bottom-up): combo points → name → auras
-- Below health bar (top-down): cast bar → combo points (if BOTTOM)
----------------------------------------------------------------------
function Addon:LayoutElements(frame)
    if not frame or not frame.healthbarBg then return end
    local db = self.db.profile

    -- Pick layout state: "casting" when cast bar is visible, "default" otherwise
    local isCasting = frame.castbarBg and frame.castbarBg:IsShown()
    local layoutTable = db.layout or {}
    local L = isCasting and (layoutTable.casting or layoutTable.default) or (layoutTable.default or layoutTable)

    -- All elements positioned absolutely from the nameplate container center.
    -- Each element has its own x,y offset — fully independent, no stacking.
    local anchor = frame.container

    -- Health bar
    local hb = L.healthbar or { x = 0, y = 0 }
    frame.healthbarBg:ClearAllPoints()
    frame.healthbarBg:SetPoint("CENTER", anchor, "CENTER", hb.x, hb.y)

    -- Name text — always pre-position, even when hidden.
    -- If we skip this when hidden, a late UnitName arrival can show the text
    -- at position 0,0 (same as the health bar) before LayoutElements re-runs.
    local nt = db.healthbar.nameText or {}
    if frame.name then
        local nt_l = L.nameText or { x = 0, y = 12 }
        frame.name:ClearAllPoints()
        frame.name:SetPoint("CENTER", anchor, "CENTER", nt_l.x, nt_l.y)
    end

    -- Raid icon (always follows name text position, offset above it)
    if frame.raidIcon and frame.raidIcon:IsShown() then
        local nt_l = L.nameText or { x = 0, y = 12 }
        frame.raidIcon:ClearAllPoints()
        frame.raidIcon:SetPoint("BOTTOM", anchor, "CENTER", nt_l.x, nt_l.y + (nt.fontSize or 10))
    end

    -- Auras
    if frame.auraFrame and db.auras.enabled then
        local a_l = L.auras or { x = 0, y = 26 }
        frame.auraFrame:ClearAllPoints()
        frame.auraFrame:SetPoint("CENTER", anchor, "CENTER", a_l.x, a_l.y)
    end

    -- Cast bar
    if frame.castbarBg and frame.castbarBg:IsShown() then
        local cb_l = L.castbar or { x = 0, y = -12 }
        frame.castbarBg:ClearAllPoints()
        frame.castbarBg:SetPoint("CENTER", anchor, "CENTER", cb_l.x, cb_l.y)
    end

    -- Combo points
    if frame.comboPoints and frame.comboPoints:IsShown() then
        local cp_l = L.comboPoints or { x = 0, y = -26 }
        frame.comboPoints:ClearAllPoints()
        frame.comboPoints:SetPoint("CENTER", anchor, "CENTER", cp_l.x, cp_l.y)
    end

    -- PvP cooldown icons (below health bar)
    if frame.cdFrame and frame.cdFrame:IsShown() then
        local db = self.db.profile
        local yOff = db.pvpCooldowns and db.pvpCooldowns.yOffset or -28
        frame.cdFrame:ClearAllPoints()
        frame.cdFrame:SetPoint("CENTER", anchor, "CENTER", 0, yOff)
    end

end

----------------------------------------------------------------------
-- Health Updates (Midnight secret-safe)
----------------------------------------------------------------------
function Addon:UpdateHealth(frame, unitId)
    if not frame or not unitId or not UnitExists(unitId) then return end

    -- In 12.0, UnitHealth/UnitHealthMax return secret values.
    -- Pass Enum.StatusBarInterpolation to make the StatusBar accept them (Plater pattern).
    local maxHealth = UnitHealthMax(unitId)
    local health = UnitHealth(unitId)

    if Enum and Enum.StatusBarInterpolation then
        frame.healthbar:SetMinMaxValues(0, maxHealth, Enum.StatusBarInterpolation.Immediate)
        frame.healthbar:SetValue(health, Enum.StatusBarInterpolation.Immediate)
    else
        frame.healthbar:SetMinMaxValues(0, maxHealth)
        frame.healthbar:SetValue(health)
    end

    -- Health text using secret-safe formatting
    self:UpdateHealthText(frame, unitId)
end

function Addon:OnUnitHealth(_, unitId)
    local plate = TPR.NameplatesByUnit[unitId]
    if not plate then return end
    local frame = TPR.ActivePlates[plate]
    if frame and frame.unitId == unitId then
        self:UpdateHealth(frame, unitId)
    end
end

function Addon:OnUnitNameUpdate(_, unitId)
    -- Fires when a unit's name becomes available (late for freshly-spawned NPCs)
    local plate = TPR.NameplatesByUnit[unitId]
    if not plate then return end
    local frame = TPR.ActivePlates[plate]
    if not frame or frame.unitId ~= unitId then return end

    local db = self.db.profile
    local nt = db.healthbar.nameText or {}
    local name = UnitName(unitId)
    if nt.show ~= false and name then
        frame.name:SetText(name)
        frame.name:Show()
        self:LayoutElements(frame)
    end
end

function Addon:OnUnitFaction(_, unitId)
    -- Fires when a unit's faction/reaction changes (e.g. Apothecary Hummel becoming hostile)
    if not unitId then return end
    local plate = TPR.NameplatesByUnit[unitId]
    if plate then
        -- Unit already tracked — re-configure with new reaction color etc.
        local frame = TPR.ActivePlates[plate]
        if frame and frame.unitId == unitId then
            self:ConfigureFrame(frame, unitId)
        end
    else
        -- Not yet tracked — the nameplate might exist but we missed UNIT_ADDED
        -- (can happen when a unit goes from a no-nameplate state to having one)
        self:OnNamePlateUnitAdded(nil, unitId)
    end
end

----------------------------------------------------------------------
-- Target Tracking
----------------------------------------------------------------------
function Addon:OnTargetChanged()
    -- Track target via events to avoid secret value issues
    TPR.CurrentTarget = UnitExists("target") and "target" or nil

    for plate, frame in pairs(TPR.ActivePlates) do
        if frame.unitId then
            self:UpdateTargetHighlight(frame, frame.unitId)
            self:UpdateComboPoints(frame, frame.unitId)
            self:LayoutElements(frame)
        end
    end
end

function Addon:OnPowerUpdate(_, unitId)
    if unitId == "player" then
        self:UpdateAllComboPoints()
    end
end

function Addon:OnSpecChanged()
    self:RefreshPowerType()
end

----------------------------------------------------------------------
-- Combat Events
----------------------------------------------------------------------
function Addon:OnCombatStart()
    -- Could trigger visual updates
end

function Addon:OnCombatEnd()
    -- Reset threat visuals
    for plate, frame in pairs(TPR.ActivePlates) do
        if frame.unitId then
            self:UpdateThreat(frame, frame.unitId)
        end
    end

    -- 12.1 auras: refill container pool, attach deferred containers,
    -- apply config changes that were blocked during combat
    self:OnAuraCombatEnd()
end

----------------------------------------------------------------------
-- Threat Events (forwarded to Threat module)
----------------------------------------------------------------------
function Addon:OnThreatUpdate(_, unitId)
    local plate = TPR.NameplatesByUnit[unitId]
    if not plate then return end
    local frame = TPR.ActivePlates[plate]
    if frame and frame.unitId == unitId then
        self:UpdateThreat(frame, unitId)
    end
end

----------------------------------------------------------------------
-- Aura Events (forwarded to Aura module)
----------------------------------------------------------------------
function Addon:OnUnitAura(_, unitId)
    local plate = TPR.NameplatesByUnit[unitId]
    if not plate then return end
    local frame = TPR.ActivePlates[plate]
    if frame and frame.unitId == unitId then
        self:UpdateAuras(frame, unitId)
    end
end

----------------------------------------------------------------------
-- Utility
----------------------------------------------------------------------
function Addon:ReleaseCustomFrame(plate)
    local frame = TPR.ActivePlates[plate]
    if frame then
        self:ResetAuraUnit(frame)
        frame:Hide()
        frame.unitId = nil
    end
    self:ShowBlizzardFrame(plate)
end

----------------------------------------------------------------------
-- Hide/Show Blizzard Default Nameplate Elements
-- Blizzard's CompactUnitFrame code continuously re-shows the default
-- UnitFrame via internal hooks. A single :Hide() call is not enough.
-- We hook Show() and SetAlpha() on each Blizzard UnitFrame to
-- suppress it every time WoW tries to display it.
-- Approach adapted from Plater's proven technique.
----------------------------------------------------------------------

-- Track which plates we've already hooked and which are TPR-managed
local hookedPlates = {}
local managedPlates = {} -- [UnitFrame string key] = true when TPR is active

local function SuppressBlizzardFrame(self)
    if self:IsForbidden() then return end
    if not managedPlates[tostring(self)] then return end

    -- For protected frames: detach them entirely
    if self:IsProtected() then
        self:ClearAllPoints()
        self:SetParent(nil)
        if self.HealthBarsContainer then
            self.HealthBarsContainer:ClearAllPoints()
        end
        if not self:IsProtected() then
            self:Hide()
        end
    else
        self:SetAlpha(0)
    end

    -- Hide the Blizzard cast bar visually but keep it processing events.
    -- The castbar runs in untainted Blizzard code, which CAN read secret
    -- values. It stores the result as a plain boolean in self.notInterruptible.
    -- Our addon then reads that plain boolean.
    if self.castBar then
        self.castBar:SetAlpha(0)
    end
end

function Addon:HookBlizzardFrame(plate)
    if not plate or not plate.UnitFrame then return end
    if hookedPlates[plate] then return end

    local unitFrame = plate.UnitFrame

    -- Hook Show(): suppress Blizzard frame every time it tries to show
    hooksecurefunc(unitFrame, "Show", SuppressBlizzardFrame)

    -- Hook SetAlpha(): force alpha to 0 whenever Blizzard tries to change it
    local locked = false
    hooksecurefunc(unitFrame, "SetAlpha", function(self)
        if locked or self:IsForbidden() then return end
        if not managedPlates[tostring(self)] then return end
        locked = true
        self:SetAlpha(0)
        locked = false
    end)

    hookedPlates[plate] = true
end

function Addon:HideBlizzardFrame(plate)
    if not plate then return end

    -- Install persistent hooks (only once per plate)
    self:HookBlizzardFrame(plate)

    local unitFrame = plate.UnitFrame
    if unitFrame then
        -- Mark this Blizzard frame as managed by TPR
        managedPlates[tostring(unitFrame)] = true

        -- Immediately suppress
        SuppressBlizzardFrame(unitFrame)
    end

    -- Midnight 12.0: disable simplified nameplate mode
    if C_NamePlateManager and C_NamePlateManager.SetNamePlateSimplified then
        local customFrame = TPR.ActivePlates[plate]
        if customFrame and customFrame.unitId then
            C_NamePlateManager.SetNamePlateSimplified(customFrame.unitId, false)
        end
    end
end

function Addon:ShowBlizzardFrame(plate)
    if not plate then return end

    local unitFrame = plate.UnitFrame
    if unitFrame then
        -- Unmark so hooks stop suppressing
        managedPlates[tostring(unitFrame)] = nil

        unitFrame:SetAlpha(1)
        if unitFrame.castBar then
            unitFrame.castBar:SetAlpha(1)
        end
        if not unitFrame:IsForbidden() then
            unitFrame:Show()
        end
    end
end

-- Expose addon-wide
_G["ThreatPlatesRemake"] = Addon
