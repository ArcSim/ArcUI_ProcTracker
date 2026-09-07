local ADDON, PT = ...   -- private namespace, shared with Core (never the global PT)
-- ArcUI_PT_NaturesGuardian.lua
-- Nature's Guardian internal-cooldown tracker.
--
-- NOT A DECK. Every other tracker in this addon models a shuffled deck (a deck
-- size, a proc count, a position that advances as you spend). Nature's Guardian
-- is a flat internal cooldown: drop below 35% health, get healed, and it cannot
-- happen again for 45 seconds. So it registers with deckSize/procs stubbed at 1
-- and sets `isTimer`, which tells Core to skip every deck-shaped readout.
--
-- SECRET SAFETY: nothing secret is ever touched. Blizzard does not publish this
-- internal cooldown at all -- there is no duration object to ask for -- so the
-- only thing we take from the game is the TRIGGER (SPELL_UPDATE_COOLDOWN naming
-- our spell), and the 45 seconds is our own constant measured from GetTime().
-- Both numbers are ours, so the arithmetic and the SetCooldown push are safe in
-- the open world, in raids and in Mythic+ alike.
--
-- No pcall. Zero polling: one event to start the clock, one C_Timer to end it.

-- 31616 is the heal effect, and it is the ID whose cooldown event fires on the
-- proc -- confirmed by the working ArcUI custom timer, which keys off exactly
-- this ID with a 45s duration. The talent itself (30884) is a passive and is
-- NOT matched here: accepting it too would only add a false-trigger path.
local NG_EFFECT   = 31616
local NG_ICON     = 136060
local NG_NODE_ID  = 103613
local NG_ENTRY_ID = 127890

-- Natural Harmony (Farseer hero talent) shortens the internal cooldown. The
-- magnitude is NOT the same everywhere: Elemental gets 10 sec off and
-- Restoration 15, for the same spell and the same node. See NH_BY_SPEC below.
local NH_SPELL     = 443442
local NH_NODE_ID   = 94858
local NH_ENTRY_ID  = 117455
local NH_FALLBACK  = 10          -- 45 - 10 = 35s, if the spec is unknown

local ngEnabled = false
local ngOnCD    = false

local function NGDbg(tag, detail)
    if PT.NaturesGuardian and PT.NaturesGuardian.OnDebug then
        PT.NaturesGuardian.OnDebug(tag, detail)
    end
end

PT.NaturesGuardian = PT.NaturesGuardian or {}
local NG = PT.NaturesGuardian

-- ── Talent detection ─────────────────────────────────────────────────────────
-- Mirrors how the Tempest decks gate themselves: ask the trait tree, not the
-- spellbook, so it is correct the instant a talent swap lands.
local function HasNGTalent()
    local cfgID = C_ClassTalents and C_ClassTalents.GetActiveConfigID
                  and C_ClassTalents.GetActiveConfigID()
    if not cfgID then return false end
    local node = C_Traits and C_Traits.GetNodeInfo
                 and C_Traits.GetNodeInfo(cfgID, NG_NODE_ID)
    if not node then return false end
    if node.activeEntry and node.activeEntry.entryID == NG_ENTRY_ID then
        return (node.activeEntry.rank or 0) > 0
    end
    return false
end
NG.HasTalent = HasNGTalent

-- ── Cooldown state ───────────────────────────────────────────────────────────
-- WE RUN THE CLOCK, not Blizzard. There is no duration object for this: the
-- game never publishes Nature's Guardian's internal cooldown, so asking
-- C_Spell.GetSpellCooldownDuration for it returns nothing and the icon would
-- never light up. (That was the first cut of this file, and it is why the ArcUI
-- custom timer worked while this did not.)
--
-- What the game DOES give is the trigger: SPELL_UPDATE_COOLDOWN fires with the
-- spellID in arg1 (arg2 carries the base spell) the moment the proc puts the
-- effect on cooldown. So we watch for our spellID and start our own 45 second
-- timer from GetTime(). Both numbers are ours, never secrets, so the arithmetic
-- and the SetCooldown push are safe everywhere -- exactly the "scheduling needs
-- real numbers, so use GetTime plus locally tracked values" path.
local NG_ICD_BASE = 45

local ngExpiry   = 0
local ngDuration = NG_ICD_BASE   -- length of the CURRENTLY RUNNING cooldown

-- Is Natural Harmony actually picked?
local function HasNaturalHarmony()
    local cfgID = C_ClassTalents and C_ClassTalents.GetActiveConfigID
                  and C_ClassTalents.GetActiveConfigID()
    if not cfgID then return false end
    local node = C_Traits and C_Traits.GetNodeInfo
                 and C_Traits.GetNodeInfo(cfgID, NH_NODE_ID)
    if not node then return false end
    if node.activeEntry and node.activeEntry.entryID == NH_ENTRY_ID then
        return (node.activeEntry.rank or 0) > 0
    end
    return false
end

-- How much Natural Harmony takes off, per spec. Confirmed in game: Elemental
-- reads "by 10 sec" and Restoration "by 15 sec" for the same talent and the
-- same node. A table beats parsing the tooltip text: it is exact, and it cannot
-- break in a non-English client. Enhancement is absent on purpose -- Farseer is
-- an Elemental/Restoration hero tree, so Enhancement never has this talent and
-- HasNaturalHarmony already returns false there.
local NH_BY_SPEC = {
    [262] = 10,   -- Elemental   -> 35s
    [264] = 15,   -- Restoration -> 30s
}

local function HarmonyReduction()
    local idx = GetSpecialization and GetSpecialization()
    local specID = idx and GetSpecializationInfo and GetSpecializationInfo(idx)
    return (specID and NH_BY_SPEC[specID]) or NH_FALLBACK
end

-- The cooldown length RIGHT NOW, for a proc starting this instant.
local function CurrentICD()
    if not HasNaturalHarmony() then return NG_ICD_BASE end
    return NG_ICD_BASE - HarmonyReduction()
end
NG.CurrentICD = CurrentICD

-- A bulk SPELL_UPDATE_COOLDOWN broadcast carries no spellID at all. Matching a
-- nil would start the timer on every unrelated cooldown tick, so ignore those
-- and only accept our exact ID.
local function SafeSpellID(v)
    if issecretvalue and issecretvalue(v) then return nil end
    local n = tonumber(v)
    return (n and n > 0) and n or nil
end

-- Blizzard sends a burst of cooldown updates on load and on every zone change.
-- Without a short suppression window the timer fires spuriously on zone-in --
-- the same guard the ArcUI timer engine needs for its cooldown trigger.
local ngSuppressUntil = 0
local NG_SUPPRESS_SECONDS = 2

local function Push()
    local entry = PT.GetDeck and PT.GetDeck("ng")
    local w = entry and entry.widget
    if not w or not w._ngCooldown then return end
    local remain = ngExpiry - GetTime()
    if remain > 0 then
        -- draw with the duration this cooldown STARTED with, not the current
        -- one: a talent swap mid-cooldown must not rescale a running sweep
        w._ngCooldown:SetCooldown(ngExpiry - ngDuration, ngDuration)
    else
        w._ngCooldown:Clear()
    end
end

local function Refresh()
    if not ngEnabled then return end
    local wasOnCD = ngOnCD
    ngOnCD = (ngExpiry - GetTime()) > 0
    Push()
    if ngOnCD ~= wasOnCD then
        NGDbg("STATE", ngOnCD and "on cooldown" or "ready")
    end
    PT.UpdateDeck("ng")
end
NG.Refresh = Refresh

local function StartICD()
    ngDuration = CurrentICD()
    ngExpiry   = GetTime() + ngDuration
    NGDbg("PROC", "internal cooldown started, " .. ngDuration .. "s"
        .. (HasNaturalHarmony() and " (Natural Harmony)" or ""))
    Refresh()
    -- one timer to flip back to ready; no polling in between
    C_Timer.After(ngDuration + 0.1, function()
        if (ngExpiry - GetTime()) <= 0 then Refresh() end
    end)
end
NG.StartICD = StartICD

function NG.IsOnCooldown() return ngOnCD end
function NG.Remaining() return math.max(0, ngExpiry - GetTime()) end

-- ── Events ───────────────────────────────────────────────────────────────────
local ngFrame = CreateFrame("Frame")
ngFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
ngFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
ngFrame:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "PLAYER_ENTERING_WORLD" then
        ngSuppressUntil = GetTime() + NG_SUPPRESS_SECONDS
        Refresh()
        return
    end
    if not ngEnabled then return end
    if GetTime() < ngSuppressUntil then return end
    local id = SafeSpellID(arg1) or SafeSpellID(arg2)
    if id ~= NG_EFFECT then return end
    -- a refire while already counting means the proc happened again; the ICD
    -- restarts rather than extending, so just reset the clock
    StartICD()
end)

-- ── Talent visibility ────────────────────────────────────────────────────────
local function ApplyTalentVisibility()
    local entry = PT.GetDeck and PT.GetDeck("ng")
    local w = entry and entry.widget
    if not w then return end
    local db = PT.GetIconDB and PT.GetIconDB("ng")
    local want = HasNGTalent() and (not db or db.deckEnabled ~= false)
    if want then w:Show() else w:Hide() end
    NGDbg("TALENT", want and "talented" or "not talented")
end
NG.ApplyTalentVisibility = ApplyTalentVisibility

local ngTalentFrame = CreateFrame("Frame")
ngTalentFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
ngTalentFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
ngTalentFrame:RegisterEvent("ACTIVE_COMBAT_CONFIG_CHANGED")
ngTalentFrame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
ngTalentFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
ngTalentFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
ngTalentFrame:SetScript("OnEvent", function()
    ApplyTalentVisibility()
    Refresh()
end)

-- ── Registration ─────────────────────────────────────────────────────────────
local function Reset()
    ngOnCD     = false
    ngExpiry   = 0
    ngDuration = CurrentICD()
    Refresh()
end

local function GetDeckPos() return 0 end
local function GetProcs()   return 0 end

PT.RegisterDeck({
    id          = "ng",
    name        = "Nature's Guardian",
    -- stubs: RegisterDeck requires them, isTimer tells Core to ignore them
    deckSize    = 1,
    procs       = 1,
    isTimer     = true,
    -- MEDIUM rather than the shared HIGH default: this is a passive safety-net
    -- readout, so it should sit with the UI rather than on top of everything.
    -- MEDIUM strata, and desaturated while the ICD runs -- the way the game
    -- itself greys a spell on cooldown. Set as an ENTRY default rather than a
    -- shared one, so no existing icon's look changes.
    iconDefaults = { frameStrata = "MEDIUM", cdDesat = true, swipeEdge = true },
    defaultIcon = NG_ICON,
    noCDMWarn   = true,   -- nothing to cross-check against the Cooldown Manager
    GetDeckPos  = GetDeckPos,
    GetProcs    = GetProcs,
    OnReset     = Reset,
    OnEnable    = function()
        ngEnabled = true
        ApplyTalentVisibility()
        Refresh()
    end,
    ns          = NG,
})
