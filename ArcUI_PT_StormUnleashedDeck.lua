local ADDON, PT = ...   -- private namespace, shared with Core (never the global PT)
-- ArcUI_PT_StormUnleashedDeck.lua
-- Storm Unleashed (Crash Lightning reset) deck tracking.
--
-- Deck: 5 procs per 250 Maelstrom Weapon spent (2% per stack spent).
--   Confirmed against SimC: rng_obj.storm_unleashed is a 250-card / 5-success
--   deck rolled once per MSW stack spent, with at most ONE success per spend
--   event (assert(!success)), granting buff.storm_unleashed (spell 1262830).
--
-- DETECTION: SPELL_UPDATE_COOLDOWN for spell 1252413 -- "Storm Unleashed", the
--   PROC SPELL itself, not the 1262830 buff aura it applies. Same shape as the
--   DRE deck, which watches the spell its proc IS (Ascendance) rather than the
--   talent. Gated by a short window opened on each MSW spend, since the deck
--   only rolls on a spend.
--
--   WHY THE PROC SPELL AND NOT THE BUFF. 1262830's cooldown update fires on
--   every CHANGE -- gain, expiry, and each Crash Lightning that consumes a
--   charge -- so it cannot tell direction. Watching it counted consumptions as
--   procs and finished a 250-card deck at 6/5. A "was Crash cast in this frame"
--   guard patched that but was structurally wrong: Crash also spends Maelstrom
--   (observed repeatedly as spender=187874), so a single frame can legitimately
--   hold a Crash cast, a spend, a proc and a deck rollover at once. The guard
--   rejected exactly that and lost a proc (deck finished 4/5).
--
--   1252413 fires ONLY on a gain. Across four sessions: 19/19 real procs
--   including back-to-backs and both collision variants, and zero false
--   positives on consumptions or expiries. That makes the Crash guard
--   unnecessary, so it is gone -- one signal, no direction inference.
--
--   No CDM dependency. CDM was evaluated and rejected: OnUnitAuraUpdatedEvent
--   fires identically for a stack GAIN (a real back-to-back) and a stack LOSS
--   (a Crash Lightning cast), and stack counts are unreadable for this aura
--   (GetPlayerAuraBySpellID returns nil), so it credited a proc for spending a
--   charge. It is also Blizzard UI internals, where this event is not.
--
-- No pcall. Zero polling.

local issecretvalue = issecretvalue

-- ── Constants ─────────────────────────────────────────────────────────────────
local SU_GAIN_ID    = 1252413   -- "Storm Unleashed" -- the PROC SPELL. See below.
local SU_DEFAULT_ICON = 7636566 -- IconID of the buff
local DECK_SIZE     = 250
local DECK_PROCS    = 5

-- Talent identity (read off the tooltip via Arc_IDs).
-- Storm Unleashed is a MULTI-RANK talent (seen at 2/4), NOT a choice node:
--   Rank 1  "Each Maelstrom Weapon spent has a 2% chance..."  <- THIS is the deck
--   Rank 2  MSW spenders deal more damage
--   Rank 3  Crash Lightning electrocutes / auto-attack speed
-- So the deck exists at ANY rank >= 1, and the 2% never changes with rank --
-- which is exactly the 5/250 this file models. There is no sibling entry to
-- disambiguate from, so an entryID equality test buys nothing and actively
-- breaks: the live tooltip reports 136970 while this file had 136969, which
-- made IsSUTalented() return false and the deck never register.
local SU_NODE_ID    = 110401    -- TraitNodeID
local SU_TALENT_ID  = 1262713   -- the passive talent spell (NOT the buff)

-- Measured: the update arrives at +0ms, in the same frame as the spend. 50ms is
-- generous for safety and far tighter than the gap to anything unrelated.
local PROC_WINDOW   = 0.05

-- ── State ─────────────────────────────────────────────────────────────────────
local suTotalStacks    = 0
local suDeckNumber     = 1
local suDeckProcs      = 0
local suPrevProcs      = 0
local suViolations     = 0
local suGainCount      = 0
local suSnapTotal      = 0
local suProcThisConsume= false
local suLastProcTime   = 0
local suEnabled        = false

local sucWatchUntil    = 0      -- spend window is open while GetTime() <= this
local sucGainFired     = false

-- ── Deck advancement ──────────────────────────────────────────────────────────
local function AdvanceDeck(n)
    local before = suTotalStacks
    suTotalStacks = suTotalStacks + n
    local db = math.floor(before / DECK_SIZE)
    local da = math.floor(suTotalStacks / DECK_SIZE)
    if da > db then
        suPrevProcs  = suDeckProcs
        suDeckProcs  = 0
        suDeckNumber = da + 1
        local violation = suPrevProcs ~= DECK_PROCS
        if violation then suViolations = suViolations + 1 end
        if PT.StormUnleashed.OnDeckRollover then
            PT.StormUnleashed.OnDeckRollover(suDeckNumber, suPrevProcs, violation)
        end
    end
end

-- ── Debug attempt reporting (nil unless the debugger is open) ────────────────
local function Attempt(source, accepted, reason)
    local fn = PT.StormUnleashed and PT.StormUnleashed.OnAttempt
    if fn then fn(source, accepted, reason) end
end

-- ── Proc confirmed ────────────────────────────────────────────────────────────
local function OnSUGain(source)
    if not suEnabled then return end
    local now = GetTime()
    if now == suLastProcTime then Attempt(source, false, "same-frame dedup"); return end
    if suProcThisConsume then Attempt(source, false, "already counted this MSW consume"); return end

    suProcThisConsume = true
    suGainCount       = suGainCount + 1
    suLastProcTime    = now

    local snapDeck   = math.floor(suSnapTotal / DECK_SIZE)
    local currDeck   = math.floor(suTotalStacks / DECK_SIZE)
    local rolledOver = currDeck > snapDeck
    local deckPos    = suSnapTotal % DECK_SIZE

    if rolledOver and suDeckNumber > 1 and suPrevProcs < DECK_PROCS then
        -- The spend that crossed the deck boundary is also the spend that
        -- procced, so the proc belongs to the deck that just closed, not the
        -- new one. OnDeckRollover has already fired and reported a short deck;
        -- tell anyone listening that it was repaired.
        suPrevProcs = suPrevProcs + 1
        if suPrevProcs == DECK_PROCS and suViolations > 0 then
            suViolations = suViolations - 1
        end
        if PT.StormUnleashed.OnBackCredit then
            PT.StormUnleashed.OnBackCredit(suDeckNumber - 1, suPrevProcs, DECK_PROCS)
        end
    else
        suDeckProcs = suDeckProcs + 1
    end

    Attempt(source, true, nil)
    if PT.StormUnleashed.OnProc then
        PT.StormUnleashed.OnProc(suDeckNumber, suDeckProcs, suGainCount, deckPos)
    end
    PT.UpdateDeck("stormunleashed")
end

-- ── Proc spell watcher ────────────────────────────────────────────────────────
-- One persistent frame with an "is a window open" check, rather than creating
-- and destroying a frame per spend: this event fires constantly, so the check
-- is a single comparison on the hot path and there is no frame churn.
local sucWatch = CreateFrame("Frame")
sucWatch:RegisterEvent("SPELL_UPDATE_COOLDOWN")
sucWatch:SetScript("OnEvent", function(_, _, sid)
    if GetTime() > sucWatchUntil then return end
    if sucGainFired then return end
    if issecretvalue and issecretvalue(sid) then return end
    if tonumber(sid) ~= SU_GAIN_ID then return end
    sucGainFired = true
end)

-- ── MSW consume: opens the detection window ───────────────────────────────────
local function OnMSWConsumed(stacksSpent, spenderID, ascActive)
    if not suEnabled then return end
    -- NOTE: unlike Doom Winds, Storm Unleashed is NOT suppressed during
    -- Ascendance -- SimC rolls it on every MSW spend regardless.
    suSnapTotal = suTotalStacks
    AdvanceDeck(stacksSpent)
    suProcThisConsume = false

    sucGainFired  = false
    sucWatchUntil = GetTime() + PROC_WINDOW

    C_Timer.After(PROC_WINDOW, function()
        sucWatchUntil = 0
        if not suEnabled then return end
        if sucGainFired then
            OnSUGain("SUC_1252413")
        else
            Attempt("SUC_1252413", false, "no Storm Unleashed proc inside the spend window")
            PT.UpdateDeck("stormunleashed")
        end
    end)
end

-- ── Public API ────────────────────────────────────────────────────────────────
PT.StormUnleashed = {}
PT.StormUnleashed.OnProc         = nil
PT.StormUnleashed.OnDeckRollover = nil
PT.StormUnleashed.OnAttempt      = nil
PT.StormUnleashed.OnBackCredit   = nil

-- ── State accessors ───────────────────────────────────────────────────────────
local function GetDeckPos()    return suTotalStacks % DECK_SIZE end
local function GetProcs()      return suDeckProcs end

-- ── Proc chance for the next spender ──────────────────────────────────────────
-- Same shape as Doom Winds: this deck advances by Maelstrom Weapon stacks
-- spent, so a spender draws its stack count as cards. The math is shared
-- (PT.DeckChance in Core) and the assumed spend comes from the Spender
-- Maelstrom Cost slider, defaulting to a full 10-stack spender.
local function GetChanceValue()
    local db = PT.GetIconDB and PT.GetIconDB("stormunleashed")
    return PT.DeckChance(DECK_SIZE, DECK_PROCS,
        suTotalStacks % DECK_SIZE, suDeckProcs, (db and db.chanceSpend) or 10)
end

local function GetChanceText()
    local db = PT.GetIconDB and PT.GetIconDB("stormunleashed")
    return PT.FormatChance(GetChanceValue(), db and db.chanceDecimals)
end
local function GetViolations() return suViolations end

local function Reset()
    suTotalStacks     = 0
    suDeckNumber      = 1
    suDeckProcs       = 0
    suPrevProcs       = 0
    suViolations      = 0
    suGainCount       = 0
    suSnapTotal       = 0
    suProcThisConsume = false
    suLastProcTime    = 0
    sucGainFired      = false
    sucWatchUntil     = 0
    PT.UpdateDeck("stormunleashed")
end

-- ── Talent gate ──────────────────────────────────────────────────────────────
local function IsSUTalented()
    local specIndex = GetSpecialization()
    local specID    = specIndex and select(1, GetSpecializationInfo(specIndex)) or nil
    if specID ~= 263 then return false end   -- Enhancement only

    if SU_NODE_ID then
        local configID = C_ClassTalents and C_ClassTalents.GetActiveConfigID
                         and C_ClassTalents.GetActiveConfigID()
        if not configID then return false end
        local ni = C_Traits and C_Traits.GetNodeInfo and C_Traits.GetNodeInfo(configID, SU_NODE_ID)
        -- ANY rank >= 1 grants the 2%-per-stack effect this deck tracks. No
        -- entryID test -- see the constants block for why that was wrong.
        if not ni or (ni.activeRank or 0) == 0 then return false end
        if ni.subTreeID then return ni.subTreeActive == true end
        return true
    end

    -- Fallback uses the TALENT spell, never the buff: an aura like 1262830 is
    -- not a "player spell", so checking it always returned false.
    return IsPlayerSpell and IsPlayerSpell(SU_TALENT_ID) == true
end

local function ApplyTalentVisibility()
    local entry = PT and PT.GetDeck and PT.GetDeck("stormunleashed")
    if not entry then return end
    local configID = C_ClassTalents and C_ClassTalents.GetActiveConfigID
                     and C_ClassTalents.GetActiveConfigID()
    if not configID then return end
    local talented = IsSUTalented()
    if entry.widget then
        if talented then
            PT.ShowDeckIconIfEnabled("stormunleashed")
        else
            entry.widget:Hide()
        end
    end
    if PT.ApplyBarTalentVisibility then
        PT.ApplyBarTalentVisibility("stormunleashed", talented)
    end
    if not talented then
        suEnabled = false
        PT.MSW.Unsubscribe("OnConsumed", OnMSWConsumed)
    else
        suEnabled = true
        PT.MSW.Subscribe("OnConsumed", OnMSWConsumed)
        PT.MSW.InitFromLive()
    end
end

-- ── Register with ProcTracker Core ────────────────────────────────────────────
local function TryRegisterDeck()
    if not IsSUTalented() then return end
    PT.RegisterDeck({
        id            = "stormunleashed",
        name          = "Storm Unleashed",
        ns            = PT.StormUnleashed,
        deckSize      = DECK_SIZE,
        procs         = DECK_PROCS,
        defaultIcon   = SU_DEFAULT_ICON,
        noCDMWarn     = true,   -- detection does not use CDM; suppress the overlay
        GetDeckPos    = GetDeckPos,
        GetProcs      = GetProcs,
        -- opt-in: Core only offers the Proc Chance Text section to decks that
        -- can compute one, and only offers the fixed-spend slider to decks
        -- whose spend size does not vary
        GetChanceText  = GetChanceText,
        GetChanceValue = GetChanceValue,
        chanceSpendSlider = true,
        GetViolations = GetViolations,
        OnReset       = Reset,
        OnEnable      = function()
            suEnabled = true
            PT.MSW.Subscribe("OnConsumed", OnMSWConsumed)
            PT.MSW.InitFromLive()
        end,
    })
end

local suTalentFrame = CreateFrame("Frame")
suTalentFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
suTalentFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
suTalentFrame:RegisterEvent("ACTIVE_COMBAT_CONFIG_CHANGED")
suTalentFrame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
suTalentFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
suTalentFrame:SetScript("OnEvent", function()
    TryRegisterDeck()
    ApplyTalentVisibility()
end)

PT.OnEnterWorld[#PT.OnEnterWorld+1] = function()
    TryRegisterDeck()
    ApplyTalentVisibility()
end

TryRegisterDeck()
C_Timer.After(0.2, ApplyTalentVisibility)
C_Timer.After(1.0, ApplyTalentVisibility)
