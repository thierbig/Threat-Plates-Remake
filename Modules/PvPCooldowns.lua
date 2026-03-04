----------------------------------------------------------------------
-- ThreatPlates Remake - PvP Cooldowns Module
-- Tracks offensive/defensive cooldown usage by enemy players and
-- displays remaining cooldown time as icons on their nameplate.
--
-- Approach: UNIT_SPELLCAST_SUCCEEDED fires with a nameplate unit token
-- (not a GUID), so we can track per-unit without GUID comparisons.
-- SpellID from the event may be a secret value in WoW 12.0 — we use
-- it as a table key (safe: unknown keys return nil, no error) and fall
-- back gracefully if spells can't be identified.
----------------------------------------------------------------------
local ADDON_NAME, TPR = ...
local Addon = TPR.Addon

-- Per-unit CD state: TPR.EnemyCooldowns[unitId] = { [spellId] = expiryTime, ... }
TPR.EnemyCooldowns = {}

----------------------------------------------------------------------
-- Cooldown data
-- duration : cooldown in seconds
-- cdType   : "offensive" or "defensive"
-- Pre-cache textures at load time (before any secrecy restrictions).
----------------------------------------------------------------------
local PVP_COOLDOWNS = {
    -- ── OFFENSIVE ──────────────────────────────────────────────────
    -- Death Knight
    [51271]  = { duration = 120, cdType = "offensive" }, -- Pillar of Frost
    [207289] = { duration = 60,  cdType = "offensive" }, -- Unholy Frenzy
    -- Demon Hunter
    [187827] = { duration = 240, cdType = "offensive" }, -- Metamorphosis
    -- Druid
    [106951] = { duration = 180, cdType = "offensive" }, -- Berserk
    [102543] = { duration = 180, cdType = "offensive" }, -- Incarnation: King of the Jungle
    -- Evoker
    [375087] = { duration = 120, cdType = "offensive" }, -- Dragonrage
    -- Hunter
    [288613] = { duration = 90,  cdType = "offensive" }, -- Trueshot
    [19574]  = { duration = 90,  cdType = "offensive" }, -- Bestial Wrath
    -- Mage
    [190319] = { duration = 120, cdType = "offensive" }, -- Combustion
    [12472]  = { duration = 120, cdType = "offensive" }, -- Icy Veins
    [55342]  = { duration = 120, cdType = "offensive" }, -- Mirror Image
    -- Monk
    [137639] = { duration = 90,  cdType = "offensive" }, -- Storm, Earth, and Fire
    [115080] = { duration = 180, cdType = "offensive" }, -- Touch of Death
    -- Paladin
    [31884]  = { duration = 120, cdType = "offensive" }, -- Avenging Wrath
    -- Priest
    [10060]  = { duration = 120, cdType = "offensive" }, -- Power Infusion
    [47585]  = { duration = 90,  cdType = "offensive" }, -- Dispersion
    -- Rogue
    [13750]  = { duration = 180, cdType = "offensive" }, -- Adrenaline Rush
    [79140]  = { duration = 120, cdType = "offensive" }, -- Vendetta
    [1856]   = { duration = 120, cdType = "offensive" }, -- Vanish
    -- Shaman
    [114051] = { duration = 180, cdType = "offensive" }, -- Ascendance
    -- Warlock
    [1122]   = { duration = 180, cdType = "offensive" }, -- Summon Infernal
    -- Warrior
    [1719]   = { duration = 90,  cdType = "offensive" }, -- Recklessness

    -- ── DEFENSIVE ──────────────────────────────────────────────────
    -- Death Knight
    [48707]  = { duration = 60,  cdType = "defensive" }, -- Anti-Magic Shell
    [49039]  = { duration = 120, cdType = "defensive" }, -- Lichborne
    [48792]  = { duration = 180, cdType = "defensive" }, -- Icebound Fortitude
    -- Demon Hunter
    [196718] = { duration = 180, cdType = "defensive" }, -- Darkness
    [188501] = { duration = 9,   cdType = "defensive" }, -- Spectral Sight (tracking)
    -- Druid
    [22812]  = { duration = 60,  cdType = "defensive" }, -- Barkskin
    [61336]  = { duration = 180, cdType = "defensive" }, -- Survival Instincts
    -- Hunter
    [186265] = { duration = 180, cdType = "defensive" }, -- Aspect of the Turtle
    -- Mage
    [45438]  = { duration = 240, cdType = "defensive" }, -- Ice Block
    [235219] = { duration = 25,  cdType = "defensive" }, -- Cold Snap
    -- Monk
    [115203] = { duration = 420, cdType = "defensive" }, -- Fortifying Brew
    -- Paladin
    [642]    = { duration = 300, cdType = "defensive" }, -- Divine Shield
    [633]    = { duration = 600, cdType = "defensive" }, -- Lay on Hands
    -- Priest
    [33206]  = { duration = 180, cdType = "defensive" }, -- Pain Suppression
    [47788]  = { duration = 180, cdType = "defensive" }, -- Guardian Spirit
    [19236]  = { duration = 90,  cdType = "defensive" }, -- Desperate Prayer
    -- Rogue
    [31224]  = { duration = 120, cdType = "defensive" }, -- Cloak of Shadows
    [5277]   = { duration = 120, cdType = "defensive" }, -- Evasion
    -- Shaman
    [108271] = { duration = 90,  cdType = "defensive" }, -- Astral Shift
    -- Warrior
    [871]    = { duration = 240, cdType = "defensive" }, -- Shield Wall
    [118038] = { duration = 120, cdType = "defensive" }, -- Die by the Sword
    -- Warlock
    [104773] = { duration = 180, cdType = "defensive" }, -- Unending Resolve
}

-- Pre-cache textures at load time (before combat/secrecy restrictions)
for spellId, data in pairs(PVP_COOLDOWNS) do
    local ok, tex = pcall(function()
        return C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(spellId)
            or GetSpellTexture and GetSpellTexture(spellId)
    end)
    data.texture = (ok and tex) or "Interface\\Icons\\INV_Misc_QuestionMark"
end

local MAX_CD_ICONS = 6

----------------------------------------------------------------------
-- Create Cooldown Icon Frame (pool of icons below the health bar)
----------------------------------------------------------------------
function Addon:CreateCooldownFrame(frame)
    local db = self.db.profile
    local iconSize = db.pvpCooldowns.iconSize or 18

    local cdFrame = CreateFrame("Frame", nil, frame.container)
    cdFrame:SetSize(db.healthbar.width or 120, iconSize)
    cdFrame:SetFrameLevel(frame.container:GetFrameLevel() + 5)

    cdFrame.icons = {}
    for i = 1, MAX_CD_ICONS do
        local icon = CreateFrame("Frame", nil, cdFrame)
        icon:SetSize(iconSize, iconSize)

        icon.border = icon:CreateTexture(nil, "BACKGROUND")
        icon.border:SetPoint("TOPLEFT", icon, "TOPLEFT", -1, 1)
        icon.border:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
        icon.border:SetColorTexture(0, 0, 0, 1)

        icon.texture = icon:CreateTexture(nil, "ARTWORK")
        icon.texture:SetAllPoints(icon)
        icon.texture:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        icon.texture:SetVertexColor(0.6, 0.6, 0.6, 1) -- dimmed to indicate "on cooldown"

        icon.timer = icon:CreateFontString(nil, "OVERLAY")
        icon.timer:SetFont(TPR.ResolveFont(db.auras.font), db.pvpCooldowns.fontSize or 7, "OUTLINE")
        icon.timer:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
        icon.timer:SetTextColor(1, 1, 0, 1)

        -- Type indicator: thin colored bar at bottom (red = offensive, blue = defensive)
        icon.typeBar = icon:CreateTexture(nil, "OVERLAY")
        icon.typeBar:SetHeight(2)
        icon.typeBar:SetPoint("BOTTOMLEFT", icon, "BOTTOMLEFT", 0, 0)
        icon.typeBar:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 0, 0)

        icon:Hide()
        cdFrame.icons[i] = icon
    end

    cdFrame:Hide()
    frame.cdFrame = cdFrame
end

----------------------------------------------------------------------
-- Spell cast event — record CD usage for a nameplate unit
----------------------------------------------------------------------
function Addon:OnSpellSucceeded(_, unitId, castGUID, spellId)
    if not unitId or not TPR.NameplatesByUnit[unitId] then return end

    local db = self.db.profile
    if not db.pvpCooldowns.enabled then return end

    -- Table key lookup with a secret spellId returns nil (no error).
    -- If spellId is recognisable the lookup succeeds; otherwise we skip.
    local cdData = PVP_COOLDOWNS[spellId]
    if not cdData then return end

    -- Filter by type
    if cdData.cdType == "offensive" and not db.pvpCooldowns.showOffensive then return end
    if cdData.cdType == "defensive" and not db.pvpCooldowns.showDefensive then return end

    if not TPR.EnemyCooldowns[unitId] then
        TPR.EnemyCooldowns[unitId] = {}
    end
    TPR.EnemyCooldowns[unitId][spellId] = GetTime() + cdData.duration

    -- Refresh display
    local plate = TPR.NameplatesByUnit[unitId]
    local frame = plate and TPR.ActivePlates[plate]
    if frame and frame.unitId == unitId then
        self:UpdateCooldowns(frame, unitId)
    end
end

----------------------------------------------------------------------
-- Update Cooldown Display for a frame
----------------------------------------------------------------------
function Addon:UpdateCooldowns(frame, unitId)
    if not frame or not frame.cdFrame then return end

    local db = self.db.profile
    if not db.pvpCooldowns.enabled then
        self:HideCooldownFrame(frame)
        return
    end

    local unitCDs = TPR.EnemyCooldowns[unitId]
    if not unitCDs then
        self:HideCooldownFrame(frame)
        return
    end

    local now = GetTime()
    local iconSize = db.pvpCooldowns.iconSize or 18
    local spacing = 2

    -- Collect active (unexpired) CDs matching current filter
    local activeCDs = {}
    for spellId, expiryTime in pairs(unitCDs) do
        local remaining = expiryTime - now
        if remaining > 0 then
            local cdData = PVP_COOLDOWNS[spellId]
            if cdData then
                local show = (cdData.cdType == "offensive" and db.pvpCooldowns.showOffensive)
                          or (cdData.cdType == "defensive" and db.pvpCooldowns.showDefensive)
                if show then
                    activeCDs[#activeCDs + 1] = { spellId = spellId, remaining = remaining, data = cdData }
                end
            end
        else
            unitCDs[spellId] = nil -- expired, remove
        end
    end

    -- Sort by remaining time (longest first, so important CDs stay left)
    table.sort(activeCDs, function(a, b) return a.remaining > b.remaining end)

    local count = math.min(#activeCDs, MAX_CD_ICONS)
    if count == 0 then
        self:HideCooldownFrame(frame)
        return
    end

    local totalWidth = count * iconSize + (count - 1) * spacing
    local startX = -totalWidth / 2

    for i = 1, MAX_CD_ICONS do
        local icon = frame.cdFrame.icons[i]
        if i <= count then
            local cd = activeCDs[i]
            icon.texture:SetTexture(cd.data.texture)
            icon:SetSize(iconSize, iconSize)
            icon:ClearAllPoints()
            icon:SetPoint("LEFT", frame.cdFrame, "CENTER", startX + (i - 1) * (iconSize + spacing), 0)

            -- Timer text
            local rem = cd.remaining
            if rem >= 60 then
                icon.timer:SetText(string.format("%dm", math.floor(rem / 60)))
            else
                icon.timer:SetText(string.format("%d", math.ceil(rem)))
            end

            -- Type indicator color
            if cd.data.cdType == "offensive" then
                icon.typeBar:SetColorTexture(1, 0.2, 0.2, 1)
            else
                icon.typeBar:SetColorTexture(0.2, 0.5, 1, 1)
            end

            icon:Show()
        else
            icon:Hide()
        end
    end

    frame.cdFrame:Show()
    self:LayoutElements(frame)
end

function Addon:HideCooldownFrame(frame)
    if not frame or not frame.cdFrame then return end
    for i = 1, MAX_CD_ICONS do
        frame.cdFrame.icons[i]:Hide()
    end
    frame.cdFrame:Hide()
end

----------------------------------------------------------------------
-- Clear tracked CDs when a unit leaves (nameplate removed or reassigned)
----------------------------------------------------------------------
function Addon:ClearUnitCooldowns(unitId)
    TPR.EnemyCooldowns[unitId] = nil
end

----------------------------------------------------------------------
-- Periodic timer: refresh CD timers and evict expired entries
----------------------------------------------------------------------
function Addon:UpdateAllCooldownTimers()
    local db = self.db.profile
    if not db.pvpCooldowns.enabled then return end

    for unitId, _ in pairs(TPR.EnemyCooldowns) do
        local plate = TPR.NameplatesByUnit[unitId]
        local frame = plate and TPR.ActivePlates[plate]
        if frame and frame.unitId == unitId then
            self:UpdateCooldowns(frame, unitId)
        else
            -- Unit no longer on a nameplate; clean up
            TPR.EnemyCooldowns[unitId] = nil
        end
    end
end
