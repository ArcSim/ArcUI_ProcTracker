-- ArcUI_PT_DREDeck.lua
-- Deeply Rooted Elements (DRE) Ascendance proc tracking.
-- DRE procs Ascendance from MSW spends — tracked via SPELL_UPDATE_COOLDOWN.
-- Target spellIDs to watch: 378270 (DRE CDPulse) and/or 114051 (Ascendance).
-- Debug logging confirms which spellID fires on proc so we can tune.
-- Deck: 2 procs per 333 MSW stacks.
-- No pcall. Zero polling.

local issecretvalue = issecretvalue

local function DREDbg(tag, detail)
    if PT.DRE and PT.DRE.OnDebug then PT.DRE.OnDebug(tag, detail) end
end

-- ── Constants ─────────────────────────────────────────────────────────────────
local DRE_SPELL_ID    = 378270   -- DRE CDPulse spellID (candidate for SPELL_UPDATE_COOLDOWN)
local ASC_SPELL_ID    = 114051   -- Ascendance buff spellID (also candidate)
local DRE_ICON        = 960689   -- IconID from DRE talent tooltip
local DECK_SIZE       = 333
local DECK_PROCS      = 2

-- DRE shares talent node with Ascendance (hard-cast) — different entryIDs
local DRE_NODE_ID     = 92219
local DRE_ENTRY_ID    = 101816   -- DRE specific entry (NOT 114291 which is Ascendance)

-- ── State ─────────────────────────────────────────────────────────────────────
local dreTotalStacks    = 0
local dreDeckNumber     = 1
local dreDeckProcs      = 0
local drePrevDeckProcs  = 0
local dreGainCount      = 0
local dreViolations     = 0
local dreEnabled        = false
local dreSnapTotal      = 0   -- pre-advance snapshot for rollover credit
local dreProcThisConsume= false
local dreLastProcTime   = 0

-- Track last MSW gain time for same-frame MSW GAINED check
local lastMSWGainTime   = 0

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function AdvanceDeck(n)
    local before = dreTotalStacks
    dreTotalStacks = dreTotalStacks + n
    local db = math.floor(before / DECK_SIZE)
    local da = math.floor(dreTotalStacks / DECK_SIZE)
    if da > db then
        drePrevDeckProcs = dreDeckProcs
        dreDeckProcs     = 0
        dreDeckNumber    = da + 1
        local violation  = drePrevDeckProcs ~= DECK_PROCS
        if violation then dreViolations = dreViolations + 1 end
        local prevStr = drePrevDeckProcs == DECK_PROCS and "clean" or ("VIOLATION#" .. dreViolations)
        DREDbg("DECK: DECK ROLLOVER", "deck#" .. dreDeckNumber .. " prevProcs=" .. drePrevDeckProcs .. "/" .. DECK_PROCS .. " " .. prevStr)
        if PT.DRE.OnDeckRollover then
            PT.DRE.OnDeckRollover(dreDeckNumber, drePrevDeckProcs, violation)
        end
    end
end

local function CreditProc()
    local now = GetTime()
    -- Same-frame dedup
    if now == dreLastProcTime then return end
    -- Already counted a proc for this MSW consume
    if dreProcThisConsume then return end
    dreProcThisConsume = true
    dreLastProcTime    = now
    dreGainCount       = dreGainCount + 1

    -- Rollover credit: use pre-advance snap vs current post-advance total
    local snapDeck   = math.floor(dreSnapTotal / DECK_SIZE)
    local currDeck   = math.floor(dreTotalStacks / DECK_SIZE)
    local rolledOver = currDeck > snapDeck
    local deckPos    = dreSnapTotal % DECK_SIZE

    if rolledOver and dreDeckNumber > 1 and drePrevDeckProcs < DECK_PROCS then
        -- Proc belongs to previous deck (arrived same frame as rollover)
        drePrevDeckProcs = drePrevDeckProcs + 1
        -- Retract premature violation if prev deck is now complete
        if drePrevDeckProcs == DECK_PROCS and dreViolations > 0 then
            dreViolations = dreViolations - 1
        end
        DREDbg("DECK: PROC CREDITED", "gain#" .. dreGainCount .. " creditedDeck#" .. (dreDeckNumber-1) .. " procs=" .. drePrevDeckProcs .. "/" .. DECK_PROCS .. " [rollover→prev]")
    else
        dreDeckProcs = dreDeckProcs + 1
        DREDbg("DECK: PROC CREDITED", "gain#" .. dreGainCount .. " creditedDeck#" .. dreDeckNumber .. " procs=" .. dreDeckProcs .. "/" .. DECK_PROCS)
    end

    if PT.DRE.OnProc then
        PT.DRE.OnProc(dreDeckNumber, dreDeckProcs, dreGainCount, deckPos)
    end
    PT.UpdateDeck("dre")
end

local function GetDeckPos()   return dreTotalStacks % DECK_SIZE end
local function GetProcs()     return dreDeckProcs end
local function GetViolations() return dreViolations end

local function Reset()
    dreTotalStacks     = 0
    dreDeckNumber      = 1
    dreDeckProcs       = 0
    drePrevDeckProcs   = 0
    dreGainCount       = 0
    dreViolations      = 0
    dreSnapTotal       = 0
    dreProcThisConsume = false
    dreLastProcTime    = 0
    lastMSWGainTime    = 0
    PT.UpdateDeck("dre")
end

-- ── MSW GAINED tracking ────────────────────────────────────────────────────────
local function OnMSWGained(instID, apps)
    lastMSWGainTime = GetTime()
end

-- ── MSW consume window ────────────────────────────────────────────────────────
local function OnMSWConsumed(stacksSpent, spenderID, ascActive)
    if not dreEnabled then return end
    -- DRE only procs when Ascendance is NOT active
    if ascActive then return end

    dreSnapTotal = dreTotalStacks  -- snapshot pre-advance for rollover credit
    AdvanceDeck(stacksSpent)
    dreProcThisConsume = false     -- reset per-consume proc guard
    DREDbg("DECK: MSW consume", "stacks=" .. stacksSpent
        .. " deckPos=" .. (dreTotalStacks % DECK_SIZE)
        .. " deck#" .. dreDeckNumber)

    -- Open window: listen for SPELL_UPDATE_COOLDOWN for DRE (378270) or Asc (114051)
    -- Also track if MSW GAINED fires same frame (consume-generated vs proc from elsewhere)
    local spellCDFired     = false
    local spellCDSpellID   = nil
    local consumeFrame     = GetTime()

    local spellCDWatchFrame = CreateFrame("Frame")
    spellCDWatchFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
    local consumeTime = GetTime()

    spellCDWatchFrame:SetScript("OnEvent", function(self, _, sid)
        if issecretvalue and issecretvalue(sid) then return end
        local id = tonumber(sid)
        if not id then return end
        local age = (GetTime() - consumeTime) * 1000
        -- Log ALL spell updates in window so we can identify the right spellID
        DREDbg("SPELL_UPDATE_CD " .. id, string.format("age=%.1fms", age))
        if age > 5 then return end
        if id == ASC_SPELL_ID then  -- 114051 confirmed; 378270 (DRE CDPulse) does not fire
            if not spellCDFired then
                spellCDFired   = true
                spellCDSpellID = id
            end
        end
    end)

    C_Timer.After(0.005, function()
        spellCDWatchFrame:UnregisterAllEvents()
        spellCDWatchFrame:SetScript("OnEvent", nil)
        if not dreEnabled then return end

        -- Check MSW GAINED same frame as SPELL_UPDATE (consume-generated proc signal)
        local mswGainedSameFrame = (lastMSWGainTime == consumeFrame)

        DREDbg("DECK: RULE1 check", "spellCD=" .. (spellCDFired and ("YES(" .. (spellCDSpellID or "?") .. ")") or "NO")
            .. " mswGainedSameFrame=" .. (mswGainedSameFrame and "YES" or "NO")
            .. " deckPos=" .. (dreTotalStacks % DECK_SIZE)
            .. " deck#" .. dreDeckNumber)

        if spellCDFired then
            DREDbg("DECK: RULE1 FIRE", "spellID=" .. (spellCDSpellID or "?"))
            CreditProc()
        else
            DREDbg("DECK: RULE1 NO PROC", "no SPELL_UPDATE_CD 114051")
            PT.UpdateDeck("dre")
        end
    end)
end

-- ── Talent check ──────────────────────────────────────────────────────────────
local function IsDRETalented()
    local configID = C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_ClassTalents.GetActiveConfigID()
    if not configID then return false end
    local ni = C_Traits and C_Traits.GetNodeInfo and C_Traits.GetNodeInfo(configID, DRE_NODE_ID)
    if not ni or (ni.activeRank or 0) == 0 then return false end
    local activeEntryID = ni.activeEntry and ni.activeEntry.entryID
    return activeEntryID == DRE_ENTRY_ID
end

-- ── Public API ────────────────────────────────────────────────────────────────
PT.DRE = {}
PT.DRE.OnProc         = nil
PT.DRE.OnDeckRollover = nil
PT.DRE.OnDebug        = nil

-- ── Register with Core ────────────────────────────────────────────────────────
local function TryRegisterDeck()
    if not IsDRETalented() then return end
    PT.RegisterDeck({
        id            = "dre",
        name          = "DRE Ascendance",
        deckSize      = DECK_SIZE,
        procs         = DECK_PROCS,
        defaultIcon   = DRE_ICON,
        noCDMWarn     = true,   -- no CDM frame for DRE, suppress yellow overlay
        GetDeckPos    = GetDeckPos,
        GetProcs      = GetProcs,
        GetViolations = GetViolations,
        OnReset       = Reset,
        OnEnable      = function()
            dreEnabled = true
            PT.MSW.Subscribe("OnConsumed", OnMSWConsumed)
            PT.MSW.Subscribe("OnGained",   OnMSWGained)
            PT.MSW.InitFromLive()
        end,
    })
end

local function ApplyTalentVisibility()
    local entry = PT and PT.GetDeck and PT.GetDeck("dre")
    if not entry then return end
    local configID = C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_ClassTalents.GetActiveConfigID()
    if not configID then return end
    local talented = IsDRETalented()
    if entry.widget then
        if talented then PT.ShowDeckIconIfEnabled("dre") else entry.widget:Hide() end
    end
    if PT.ApplyBarTalentVisibility then PT.ApplyBarTalentVisibility("dre", talented) end
    if not talented then
        dreEnabled = false
        PT.MSW.Unsubscribe("OnConsumed", OnMSWConsumed)
        PT.MSW.Unsubscribe("OnGained",   OnMSWGained)
    else
        dreEnabled = true
        PT.MSW.Subscribe("OnConsumed", OnMSWConsumed)
        PT.MSW.Subscribe("OnGained",   OnMSWGained)
        PT.MSW.InitFromLive()
    end
end

local dreTalentFrame = CreateFrame("Frame")
dreTalentFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
dreTalentFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
dreTalentFrame:RegisterEvent("ACTIVE_COMBAT_CONFIG_CHANGED")
dreTalentFrame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
dreTalentFrame:SetScript("OnEvent", function()
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