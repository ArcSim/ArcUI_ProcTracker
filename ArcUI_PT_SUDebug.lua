local ADDON, PT = ...   -- private namespace, shared with Core (never the global PT)
-- ArcUI_PT_SUDebug.lua
-- Storm Unleashed (Crash Lightning reset) timeline debugger.
--
-- Purpose: identify which event reliably marks (a) a proc landing and (b) a
-- SECOND charge landing while one is already held. The buff is 20s and stacks
-- to 2, so a back-to-back proc arrives as a STACK change on the existing aura
-- instance, not as a new instance.
--
-- Candidate signals, all logged side by side so they can be compared:
--   CDM OnAuraInstanceInfoSet      new aura instance (fresh proc)
--   CDM OnUnitAuraUpdatedEvent     same instance changed (stack gain = 2nd charge)
--   CDM OnAuraInstanceInfoCleared  charges gone
--   SPELL_UPDATE_COOLDOWN payload  Crash Lightning's cooldown being wiped by the
--                                  proc is a plausible independent signal; the
--                                  full 5-arg payload is ring-buffered and dumped
--                                  at every gain so a signature can be spotted
--   GetPlayerAuraBySpellID         stack count, IF the aura is readable at all
--
-- Toggle: /pt sudebug          Export: /pt sudebug export
-- No pcall. Zero polling. Zero CPU when disabled.

local issecretvalue = issecretvalue

-- ── Constants ─────────────────────────────────────────────────────────────────
local SU_CDM_ID     = 175622
local SU_BUFF_ID    = 1262830
local CRASH_CAST_ID = 187874
local MSW_ID        = 344179

-- ── State ─────────────────────────────────────────────────────────────────────
local enabled      = false
local paused       = false
local log, rawLog  = {}, {}
local MAX_LOG      = 600
local logDirty     = false
local sessionStart = GetTime()
local mainFrame, logBox

local suFrame      = nil
local suPresent    = false
local windowIdx    = 0
local winStats     = nil
local pendingCount = 0
local lastSource   = "?"

local COLOR = {
    proc     = "00FF88",
    gain     = "44FFBB",
    cdm      = "FFAA44",
    crash    = "FF8844",
    msw      = "00FFFF",
    suc      = "8888FF",
    warn     = "FF8800",
    bad      = "FF4444",
    sep      = "444444",
    info     = "888888",
}

local function TS() return string.format("%07.3f", GetTime() - sessionStart) end

local function SafeVal(v)
    if v == nil then return "nil" end
    if issecretvalue and issecretvalue(v) then return "<secret>" end
    return tostring(v)
end

local function Push(tag, detail, colorKey)
    if not enabled or paused then return end
    local col = COLOR[colorKey] or "CCCCCC"
    local ts  = TS()
    table.insert(log, string.format("|cff%s[%s] %-34s|r %s", col, ts, tag, detail or ""))
    if #log > MAX_LOG then table.remove(log, 1) end
    table.insert(rawLog, string.format("[%s] %-34s %s", ts, tag, (detail or ""):gsub("|c%x%x%x%x%x%x%x%x",""):gsub("|r","")))
    if #rawLog > 10000 then table.remove(rawLog, 1) end
    logDirty = true
end

local function Sep(label) Push("──── "..(label or "").." ────", "", "sep") end

-- ── Live aura read ────────────────────────────────────────────────────────────
-- Reports BOTH whether the aura is readable at all and its stack count, because
-- by-spellID reads are whitelisted per aura -- MSW works, the Doom Winds buff
-- returned nil for entire windows. This tells us straight away which world we
-- are in for Storm Unleashed.
local function ReadBuff()
    local a = C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID
              and C_UnitAuras.GetPlayerAuraBySpellID(SU_BUFF_ID)
    if not a then return nil, nil, false end
    local apps
    if not (issecretvalue and issecretvalue(a.applications)) then
        apps = tonumber(a.applications)
    end
    return a, apps, true
end

-- ── Event trail ───────────────────────────────────────────────────────────────
-- Captures EVERY plausible proc-signal event, not just SPELL_UPDATE_COOLDOWN.
-- SPELL_UPDATE_COOLDOWN alone was the wrong net: the buff makes the next Crash
-- Lightning IGNORE its cooldown rather than reset it, so CL's cooldown data
-- never changes and 187874 never appeared once across five procs.
--
-- Just as importantly, the trail is dumped BOTH BACKWARD AND FORWARD around a
-- proc. A backward-only dump cannot see a signal that arrives in the same frame
-- after our hook runs, or a few ms later -- which is exactly where a proc event
-- would be expected to land.
local evtRing, EVT_MAX = {}, 160
local lastMSWConsumeT  = nil

local TRACKED_EVENTS = {
    "SPELL_UPDATE_COOLDOWN",
    "SPELL_UPDATE_USABLE",
    "SPELL_UPDATE_CHARGES",
    "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW",
    "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE",
    "ACTIONBAR_UPDATE_USABLE",
}

local TRACKED_SET = {}
for _, ev in ipairs(TRACKED_EVENTS) do TRACKED_SET[ev] = true end

-- Declared HERE, above every function that touches it. Declaring it lower down
-- would make the earlier references resolve to a nil global instead of this
-- local, and the PROC tagging would silently never happen.
local consumeWin = nil
local lastProcT  = nil   -- when a proc was last credited, for the lookback above

-- ── THREE PARALLEL DETECTORS ─────────────────────────────────────────────────
-- Method 1 (CDM) is the one the DECK actually counts -- it is untouched and
-- stays authoritative. Methods 2 and 3 are shadow detectors that count nothing
-- real; they exist purely so a disagreement shows up in the log.
--
--   M1  CDM OnAuraInstanceInfoSet / OnUnitAuraUpdatedEvent
--   M2  SPELL_UPDATE_COOLDOWN for the Storm Unleashed buff (1262830)
--       -- the DRE pattern: watch the spell the proc GRANTS
--   M3  SPELL_ACTIVATION_OVERLAY_GLOW_SHOW for Crash Lightning (187874)
--       -- the proc glow on the action button
--   M4  SPELL_UPDATE_COOLDOWN for 1252413 -- UNVALIDATED CANDIDATE.
--       This ID rode along with all 8 real procs across two sessions and with
--       zero charge consumptions, so it may be a gain-EXCLUSIVE marker, which
--       would make it a strictly better primary than 1262830. It has no cast or
--       aura entry in the combat log, so it could not be identified by name --
--       hence it is only being measured here, not counted. If it stays perfect
--       across a run that includes consumptions, it is worth promoting.
--
-- Detections that land close together are grouped into one CLUSTER, and the
-- cluster reports which methods saw it. The interesting rows are the ones where
-- the methods disagree -- especially on a BACK-TO-BACK (a charge gained while
-- one is already held), which is where a method is most likely to fail.
local METHOD_NAME = { [1]="M1 DECK", [2]="M2 SUC:1262830", [3]="M3 GLOW:187874",
                      [4]="M4 SUC:1252413" }
local NMETHOD = 4
local SU_ALT_ID = 1252413      -- the unvalidated candidate above
local CLUSTER_WINDOW = 0.25

local MSW_NEAR   = 0.30        -- a proc must sit this close to an MSW spend
local CRASH_NEAR = 0.10        -- a Crash cast this close means a charge was SPENT
local mHits    = { 0,0,0,0 }   -- clusters each method saw
local mMissed  = { 0,0,0,0 }   -- clusters each method missed
local mFalse   = { 0,0,0,0 }   -- fired where a proc was impossible
local lastCrashCastT = nil
local clusterN = 0
local cluster  = nil           -- { t, hit={}, backToBack, idx }

local function CloseCluster()
    local c = cluster
    cluster = nil
    if not c or not enabled then return end
    -- Re-check: MSW_CONSUMED is dispatched after CDM's aura callbacks within the
    -- same frame, so at cluster-open time the spend may not have arrived yet.
    if not c.nearMSW and lastMSWConsumeT and math.abs(lastMSWConsumeT - c.t) <= MSW_NEAR then
        c.nearMSW = true
    end
    -- Same late-arrival problem for the Crash cast, which lands 2-3ms AFTER the
    -- spender inside the same frame.
    -- A Crash cast alone does NOT prove a consumption: a spend can proc at the
    -- same instant Crash is weaved, and the new charge is eaten immediately.
    -- M4 fires only on a GAIN, so it overrides the Crash heuristic.
    if lastCrashCastT and math.abs(lastCrashCastT - c.t) <= CRASH_NEAR
       and not c.hit[4] then
        c.consumption = true
    end

    -- Build the display WITHOUT scoring. Scoring happens only after we know
    -- whether this cluster could have been a proc at all -- otherwise a false
    -- positive would also charge a "miss" against the methods that correctly
    -- ignored it.
    local parts, allAgree = {}, true
    for i = 1, NMETHOD do
        if c.hit[i] then
            parts[#parts+1] = METHOD_NAME[i]..":YES"
        else
            parts[#parts+1] = METHOD_NAME[i]..":|cffFF4444NO|r"
            allAgree = false
        end
    end

    local kind = c.backToBack and "BACK-TO-BACK" or "fresh charge"
    if not c.nearMSW then
        kind = "NOT NEAR A SPEND"
    elseif c.consumption then
        kind = "CHARGE CONSUMED (Crash cast)"
    end

    Push("PROC CLUSTER #"..c.idx.." ("..kind..")",
        table.concat(parts, "   ")..(allAgree and "   all agree" or "   *** DISAGREEMENT ***"),
        allAgree and "proc" or "bad")

    -- The deck only rolls on an MSW spend, so a cluster with no spend nearby
    -- CANNOT be a proc. Any method firing there is producing a FALSE POSITIVE,
    -- not the others missing one -- e.g. SPELL_UPDATE_COOLDOWN on the buff fires
    -- when the buff is LOST as well as gained. Gating on the spend is exactly
    -- what the DRE deck's window does and why it does not suffer from this.
    if not c.nearMSW then
        for i = 1, NMETHOD do
            if c.hit[i] then
                mFalse[i] = mFalse[i] + 1
                Push("  ^ FALSE POSITIVE by "..METHOD_NAME[i],
                    "fired with no MSW spend within "..MSW_NEAR.."s -- cannot be a proc "
                    .."(buff expiry / consumption looks like this)", "bad")
            end
        end
        return   -- do not score misses against a cluster that was never a proc
    end

    -- A Crash cast in the same frame means a charge was SPENT here. The buff's
    -- cooldown update fires identically for a loss, so any method that reports a
    -- proc on this cluster is producing a false positive. This is the case the
    -- spend window alone cannot separate, and it is what the deck's CAST_GRACE
    -- guard now rejects.
    if c.consumption then
        for i = 1, NMETHOD do
            if c.hit[i] then
                mFalse[i] = mFalse[i] + 1
                Push("  ^ FALSE POSITIVE by "..METHOD_NAME[i],
                    "Crash Lightning cast within "..CRASH_NEAR.."s -- this is a charge being "
                    .."CONSUMED, not gained", "bad")
            end
        end
        return
    end

    -- Real proc opportunity: score it.
    for i = 1, NMETHOD do
        if c.hit[i] then mHits[i] = mHits[i] + 1 else mMissed[i] = mMissed[i] + 1 end
    end

    if not allAgree then
        for i = 1, NMETHOD do
            if not c.hit[i] then
                Push("  ^ MISSED by "..METHOD_NAME[i],
                    c.backToBack
                        and "failed on a BACK-TO-BACK -- this is the case that matters"
                        or  "failed on a fresh charge", "bad")
            end
        end
    end
end

local function RecordDetect(method)
    if not enabled then return end
    if not cluster then
        clusterN = clusterN + 1
        -- suPresent is still the PRE-proc state here for M2/M3, and for M1 the
        -- CDM hook has not yet flipped it either, so this correctly classifies
        -- whether a charge was already held.
        local now = GetTime()
        cluster = {
            t = now, hit = {}, backToBack = suPresent, idx = clusterN,
            -- Captured at cluster OPEN. The consume can arrive a moment later in
            -- the same frame, so CloseCluster re-checks this before scoring.
            nearMSW = lastMSWConsumeT ~= nil and math.abs(now - lastMSWConsumeT) <= MSW_NEAR,
        }
        C_Timer.After(CLUSTER_WINDOW, CloseCluster)
    end
    if not cluster.hit[method] then
        cluster.hit[method] = true
        Push("DETECT "..METHOD_NAME[method],
            string.format("cluster #%d  +%.3fs into cluster", cluster.idx, GetTime() - cluster.t),
            "gain")
    end
end

local function NoteEvent(ev, a1, a2, a3, a4, a5)
    local now = GetTime()
    evtRing[#evtRing+1] = { t=now, ev=ev, s=a1, b=a2, c=a3, r=a4, i=a5 }
    if #evtRing > EVT_MAX then table.remove(evtRing, 1) end
    if consumeWin then
        consumeWin.events[#consumeWin.events+1] = { ev=ev, s=a1, age=now - consumeWin.t }
    end
end

local function ShortEv(ev)
    if ev == "SPELL_UPDATE_COOLDOWN"              then return "CD"    end
    if ev == "SPELL_UPDATE_USABLE"                then return "USABLE" end
    if ev == "SPELL_UPDATE_CHARGES"               then return "CHARGE" end
    if ev == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" then return "GLOW+"  end
    if ev == "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" then return "GLOW-"  end
    if ev == "ACTIONBAR_UPDATE_USABLE"            then return "ABUSE"  end
    return ev
end

-- Print every buffered event whose timestamp falls in [fromT, toT].
local function DumpTrail(fromT, toT, label)
    local shown = 0
    for i = 1, #evtRing do
        local e = evtRing[i]
        if e.t >= fromT and e.t <= toT then
            shown = shown + 1
            local isCrash = (not (issecretvalue and issecretvalue(e.s)))
                            and tonumber(e.s) == CRASH_CAST_ID
            -- Distance to the MSW spend: the deck only rolls on a spend, so a
            -- genuine proc signal must sit right on top of one.
            local dMSW = lastMSWConsumeT and string.format("%+.3f", e.t - lastMSWConsumeT) or "?"
            Push(string.format("  %s %s%+.3fs", label, ShortEv(e.ev), e.t - toT),
                "spellID="..SafeVal(e.s).."  base="..SafeVal(e.b)
                .."  cat="..SafeVal(e.c).."  startRec="..SafeVal(e.r)
                .."  dMSW="..dMSW
                ..(isCrash and "   <<< CRASH LIGHTNING" or ""),
                isCrash and "crash" or "suc")
        end
    end
    if shown == 0 then
        Push("  "..label.." trail", "no events in this window", "info")
    end
end

-- Dump the run-up to a proc, then schedule a second dump for anything that
-- arrives AFTER it. Without the second half a signal that fires just after the
-- CDM callback is invisible.
local function DumpAroundProc(back, forward)
    local now = GetTime()
    DumpTrail(now - back, now, "BEFORE")
    C_Timer.After(forward + 0.05, function()
        if not enabled then return end
        Push("  AFTER window", string.format("events in the %.2fs following the proc:", forward), "info")
        DumpTrail(now + 0.0001, now + forward, "AFTER")
    end)
end

-- ── Window model ──────────────────────────────────────────────────────────────
local function NewStats()
    return { set=0, cleared=0, added=0, updated=0, counted=0,
             maxStack=0, startT=GetTime() }
end

local function DumpSummary(idx, s, endT)
    if not s then return end
    Push("WINDOW #"..idx.." SUMMARY", string.format(
        "length %.2fs  |  PT COUNTED %d  |  peak stacks %s  |  "
        .."signals: set=%d cleared=%d added=%d updated=%d",
        endT - s.startT, s.counted,
        s.maxStack > 0 and tostring(s.maxStack) or "unreadable",
        s.set, s.cleared, s.added, s.updated), "info")
    Push("  ^ how to read", "a SECOND charge should appear as updated>=1 (same aura "
        .."instance) or a peak stack of 2. If neither ever moves, the stack gain "
        .."is invisible to CDM and we need the spell-update route.", "info")
end

local function FrameHasAura()
    return suFrame ~= nil and suFrame.auraInstanceID ~= nil
end

local function CheckPresence()
    local present = FrameHasAura()
    if present == suPresent then return end
    suPresent = present
    if present then
        windowIdx = windowIdx + 1
        winStats  = NewStats()
        winStats.counted = pendingCount
        pendingCount = 0
        local a, apps, readable = ReadBuff()
        local secret = (issecretvalue and issecretvalue(suFrame.auraInstanceID)) and "SECRET" or "readable"
        Sep("SU WINDOW #"..windowIdx.." OPEN")
        Push("SU PRESENT (ground truth)",
            "charge gained   aid="..secret
            .."   bySpellID="..(readable and "READABLE" or "nil (not whitelisted)")
            .."   stacks="..(apps and tostring(apps) or "?"), "gain")
        if apps then winStats.maxStack = math.max(winStats.maxStack, apps) end
        DumpAroundProc(1.0, 0.5)
    else
        local idx, s, endT = windowIdx, winStats, GetTime()
        winStats = nil
        Push("SU ABSENT (ground truth)", "all charges gone — window #"..idx.." closed", "cdm")
        C_Timer.After(0.3, function()
            if enabled then DumpSummary(idx, s, endT) end
        end)
    end
end

-- ── CDM frame hooks ───────────────────────────────────────────────────────────
local CDM_VIEWERS = {
    "BuffIconCooldownViewer", "BuffBarCooldownViewer",
    "EssentialCooldownViewer", "UtilityCooldownViewer",
}

local function FindFrame()
    for _, name in ipairs(CDM_VIEWERS) do
        local v = _G[name]
        if v and v.itemFramePool then
            for f in v.itemFramePool:EnumerateActive() do
                if f.cooldownID == SU_CDM_ID then return f, name end
            end
        end
    end
    return nil
end

local function HookFrame(frame)
    if not frame or frame._arcPTSUDbgHooked then return end
    frame._arcPTSUDbgHooked = true

    if frame.OnAuraInstanceInfoSet then
        hooksecurefunc(frame, "OnAuraInstanceInfoSet", function(self)
            if not enabled then return end
            local _, apps = ReadBuff()
            Push("SU_CDM.OnAuraInstanceInfoSet",
                "instID="..SafeVal(self.auraInstanceID)
                .."  stacks="..(apps and tostring(apps) or "?")
                .."  presentBefore="..tostring(suPresent), "cdm")
            CheckPresence()
            if winStats then
                winStats.set = winStats.set + 1
                if apps then winStats.maxStack = math.max(winStats.maxStack, apps) end
            end
        end)
    end

    if frame.OnAuraInstanceInfoCleared then
        hooksecurefunc(frame, "OnAuraInstanceInfoCleared", function(self)
            if not enabled then return end
            if winStats then winStats.cleared = winStats.cleared + 1 end
            Push("SU_CDM.OnAuraInstanceInfoCleared", "prev="..SafeVal(self.auraInstanceID), "cdm")
            CheckPresence()
        end)
    end

    if frame.OnUnitAuraUpdatedEvent then
        hooksecurefunc(frame, "OnUnitAuraUpdatedEvent", function(self)
            if not enabled then return end
            local instID = self.auraInstanceID
            if not instID then return end
            local _, apps = ReadBuff()
            if winStats then
                winStats.updated = winStats.updated + 1
                if apps then winStats.maxStack = math.max(winStats.maxStack, apps) end
            end
            -- THE key line for back-to-back detection.
            Push("SU_CDM.OnUnitAuraUpdatedEvent",
                "instID="..SafeVal(instID).."  stacks="..(apps and tostring(apps) or "?")
                .."   <<< candidate SECOND CHARGE", "proc")
            DumpAroundProc(0.6, 0.5)
        end)
    end

    if frame.OnUnitAuraAddedEvent then
        hooksecurefunc(frame, "OnUnitAuraAddedEvent", function(self)
            if not enabled then return end
            if winStats then winStats.added = winStats.added + 1 end
            -- Fires on EVERY item frame for ANY added-aura batch: noise, logged
            -- only so its volume is visible next to the real signals.
            Push("SU_CDM.OnUnitAuraAddedEvent",
                "instID="..SafeVal(self.auraInstanceID)
                ..(suPresent and "  (charge already held — batch is NOT a proc)" or ""), "info")
        end)
    end

    Push("SU_CDM["..SU_CDM_ID.."] HOOKED", "frame="..tostring(frame:GetName() or tostring(frame)), "cdm")
end

local function ScanAndHook()
    local f, viewer = FindFrame()
    if f and f ~= suFrame then
        suFrame = f
        Push("SU_CDM frame located", "viewer="..tostring(viewer)
            .."  Cooldown="..tostring(f.Cooldown ~= nil)
            .."  Bar="..tostring(f.Bar ~= nil), "cdm")
        HookFrame(f)
    end
end

local function InstallSetCDIDHook()
    if not CooldownViewerItemDataMixin then return end
    if CooldownViewerItemDataMixin._arcPTSUDbgHooked then return end
    CooldownViewerItemDataMixin._arcPTSUDbgHooked = true
    hooksecurefunc(CooldownViewerItemDataMixin, "SetCooldownID", function(self, cooldownID)
        if not enabled then return end
        if cooldownID ~= SU_CDM_ID then return end
        if self ~= suFrame then
            suFrame = self
            Push("SetCooldownID SU_CDM", "rebound to a new frame", "cdm")
            HookFrame(self)
        end
    end)
end

-- ── Deck callbacks ────────────────────────────────────────────────────────────
local function WireDeck()
    if not (PT and PT.StormUnleashed) then return end
    PT.StormUnleashed.OnAttempt = function(source, accepted, reason)
        if not enabled then return end
        if accepted then
            lastSource = tostring(source)
            -- Tag the open MSW window so its spell-update list is filed under
            -- PROC. This is what makes the comparison possible.
            lastProcT = GetTime()
            RecordDetect(1)   -- Method 1: what the deck actually counts
            if consumeWin then consumeWin.procced = true end
            if winStats then winStats.counted = winStats.counted + 1
            else pendingCount = pendingCount + 1 end
        else
            Push("attempt REJECTED", "src="..tostring(source).."  reason="..tostring(reason), "info")
        end
    end
    PT.StormUnleashed.OnProc = function(deckNum, deckProcs, totalGain, deckPos)
        if not enabled then return end
        Push("PROC COUNTED", "src="..lastSource.."  deck#"..tostring(deckNum)
            .." procs="..tostring(deckProcs).."/5 total#"..tostring(totalGain)
            .." pos="..tostring(deckPos), "proc")
    end
    PT.StormUnleashed.OnDeckRollover = function(newDeck, prevProcs, violation)
        if not enabled then return end
        -- Rollover fires BEFORE the spend's proc is assessed, so a deck that is
        -- about to be back-credited reports short here. OnBackCredit below
        -- retracts it -- do not read this line as final.
        Push("DECK ROLLOVER", "newDeck#"..tostring(newDeck).." prevProcs="
            ..tostring(prevProcs).."/5"
            ..(violation and "  *** VIOLATION (provisional -- a proc on this same "
                          .."spend can still back-credit it) ***" or "  clean"),
            violation and "bad" or "proc")
    end
    PT.StormUnleashed.OnBackCredit = function(deckNum, prevProcs, target)
        if not enabled then return end
        Push("ROLLOVER CORRECTED", "deck#"..tostring(deckNum).." was short, the proc on the "
            .."rolling spend belongs to it -- now "..tostring(prevProcs).."/"..tostring(target)
            ..(prevProcs == target and "  (violation retracted)" or ""), "proc")
    end
end

local function UnwireDeck()
    if not (PT and PT.StormUnleashed) then return end
    PT.StormUnleashed.OnAttempt = nil
    PT.StormUnleashed.OnProc = nil
    PT.StormUnleashed.OnDeckRollover = nil
    PT.StormUnleashed.OnBackCredit = nil
end

-- ── MSW-consume window (the DRE discovery method) ────────────────────────────
-- This is how the DRE deck's signal was found: open a window on EVERY MSW spend
-- and log every spell update inside it, then look for the id that appears only
-- when a proc actually landed. DRE's answer was 114051 -- the spell the proc
-- GRANTS (Ascendance), not the talent. The equivalent candidate here is the
-- Storm Unleashed buff, 1262830.
--
-- The essential part is the NEGATIVE samples. Dumping only at procs, as this
-- debugger did before, cannot distinguish a proc signal from routine Enh churn
-- because there is nothing to compare against. Every spend now produces a line
-- tagged PROC or no-proc, so a discriminating id can be read straight off.
local MSW_WINDOW = 0.20   -- generous; DRE's real rule ended up at 5ms

local function CloseConsumeWindow()
    local w = consumeWin
    consumeWin = nil
    if not w or not enabled then return end
    -- A proc can be credited BEFORE this window opens: CDM's aura callbacks run
    -- ahead of MSW_CONSUMED within the same frame, so the CDM_SET fires, counts,
    -- and only then does the consume arrive and open the window. Without this
    -- lookback every genuine proc window was mislabelled [no proc].
    if not w.procced and lastProcT and math.abs(lastProcT - w.t) <= 0.05 then
        w.procced = true
    end
    local parts = {}
    for _, e in ipairs(w.events) do
        parts[#parts+1] = string.format("%s:%s@%.0fms", ShortEv(e.ev), SafeVal(e.s), e.age * 1000)
    end
    local body = (#parts > 0) and table.concat(parts, "  ") or "(no spell updates in window)"
    Push(w.procced and "MSW WINDOW [PROC]" or "MSW WINDOW [no proc]",
        string.format("spent=%d  %s", w.stacks, body),
        w.procced and "proc" or "info")
end

local function OnMSWConsumedDbg(stacksSpent, spenderID)
    if not enabled then return end
    lastMSWConsumeT = GetTime()
    local nm = spenderID and (C_Spell.GetSpellName(spenderID) or tostring(spenderID)) or "?"
    Push("MSW_CONSUMED", "stacks="..tostring(stacksSpent)
        .." spender="..tostring(spenderID).."("..nm..")", "msw")

    CloseConsumeWindow()   -- flush any window still open from a previous spend
    consumeWin = { t = GetTime(), stacks = stacksSpent or 0, events = {}, procced = false }
    C_Timer.After(MSW_WINDOW, CloseConsumeWindow)
end

-- ── Events ────────────────────────────────────────────────────────────────────
local dbg = CreateFrame("Frame")
dbg:SetScript("OnEvent", function(_, event, a1, a2, a3, a4, a5)
    if not enabled then return end

    if TRACKED_SET[event] then
        NoteEvent(event, a1, a2, a3, a4, a5)
        -- Shadow detectors. Neither counts anything real; they only feed the
        -- cluster comparison so a method that misses a proc is visible.
        if not (issecretvalue and issecretvalue(a1)) then
            local sid = tonumber(a1)
            if sid == SU_BUFF_ID and event == "SPELL_UPDATE_COOLDOWN" then
                RecordDetect(2)
            elseif sid == CRASH_CAST_ID and event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" then
                RecordDetect(3)
            elseif sid == SU_ALT_ID and event == "SPELL_UPDATE_COOLDOWN" then
                RecordDetect(4)
            end
        end
        return
    end

    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        if a1 ~= "player" then return end
        if not a3 or (issecretvalue and issecretvalue(a3)) then return end
        local sid = tonumber(a3)
        if sid == CRASH_CAST_ID then
            -- Classification happens in CloseCluster, once M4 has had a chance to
            -- arrive -- deciding here would lock in "consumption" before the
            -- gain marker could override it.
            lastCrashCastT = GetTime()
            local _, apps = ReadBuff()
            Push("SPELLCAST Crash Lightning",
                "spellID="..sid.."  stacksAfter="..(apps and tostring(apps) or "?")
                .."  (a charge should be consumed here)", "crash")
        end
        return
    end

    if event == "UNIT_AURA" then
        if a1 ~= "player" then return end
        CheckPresence()
        return
    end
end)

-- ── UI ────────────────────────────────────────────────────────────────────────
local DoExport

local function BuildUI()
    if mainFrame then mainFrame:Show(); return end
    local W, H = 720, 560
    local f = CreateFrame("Frame", "ArcUI_PT_SUDebugFrame", UIParent, "BackdropTemplate")
    f:SetSize(W, H); f:SetPoint("CENTER")
    f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetFrameStrata("DIALOG")
    f:SetBackdrop({
        bgFile   = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile=true, tileSize=16, edgeSize=14,
        insets   = {left=4,right=4,top=4,bottom=4},
    })
    f:SetBackdropColor(0.02, 0.06, 0.04, 0.97)
    f:SetBackdropBorderColor(0.0, 1.0, 0.55, 0.9)
    mainFrame = f

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -10)
    title:SetText("|cff00FF88ProcTracker|r Storm Unleashed Debug")

    local sub = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sub:SetPoint("TOP", title, "BOTTOM", 0, -2)
    sub:SetText("|cff888888SU_CDM="..SU_CDM_ID.."  buff="..SU_BUFF_ID
        .."  crash="..CRASH_CAST_ID.."  deck 5/250  |  /pt sudebug to close|r")

    local function Btn(lbl, px, fn)
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetSize(100, 22); b:SetPoint("TOPLEFT", f, "TOPLEFT", px, -60)
        b:SetText(lbl); b:SetScript("OnClick", fn); return b
    end

    Btn("Clear", 10, function()
        log, rawLog = {}, {}; logDirty = true
        if logBox then logBox:SetText("") end
    end)
    local pb = Btn("Pause", 116, nil)
    pb:SetScript("OnClick", function(self)
        paused = not paused
        self:SetText(paused and "|cffFF4444Resume|r" or "Pause")
    end)
    Btn("Scan", 222, function()
        ScanAndHook()
        Sep("MANUAL SCAN")
        Push("SU_CDM frame", suFrame and "found" or "NOT FOUND", suFrame and "cdm" or "warn")
        if suFrame then
            Push("SU_CDM instID", SafeVal(suFrame.auraInstanceID), "cdm")
        end
        local a, apps, readable = ReadBuff()
        Push("buff by spellID", readable and ("READABLE  stacks="..(apps and tostring(apps) or "<secret>"))
            or "nil (aura not whitelisted for by-spellID reads)", readable and "gain" or "warn")
        Push("deck registered", tostring(PT.GetDeck and PT.GetDeck("stormunleashed") ~= nil), "info")
    end)
    Btn("Methods", 328, function()
        Sep("METHOD SCOREBOARD")
        for i = 1, NMETHOD do
            local total = mHits[i] + mMissed[i]
            local pct = total > 0 and (mHits[i] / total * 100) or 0
            local clean = (mMissed[i] == 0 and mFalse[i] == 0 and total > 0)
            Push(METHOD_NAME[i], string.format(
                "saw %d / %d real procs  (%.0f%%)  missed %d  FALSE POSITIVES %d",
                mHits[i], total, pct, mMissed[i], mFalse[i]),
                clean and "proc" or (total == 0 and "info" or "bad"))
        end
        Push("read this as", "a viable replacement for CDM needs BOTH 0 missed AND 0 false "
            .."positives. A false positive means it fired with no MSW spend nearby, which "
            .."cannot be a proc -- buff expiry and consumption look like that.", "info")
    end)
    Btn("Export", 434, function() DoExport() end)

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function() f:Hide() end)

    local sf = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -88)
    sf:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -26, 8)
    local eb = CreateFrame("EditBox", nil, sf)
    eb:SetSize(W - 40, 8000); eb:SetPoint("TOPLEFT")
    eb:SetMultiLine(true); eb:SetFontObject("GameFontHighlightSmall")
    eb:SetAutoFocus(false); eb:EnableMouse(true); eb:SetTextInsets(4, 4, 4, 4)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnMouseDown", function(self) self:SetFocus() end)
    sf:SetScrollChild(eb)
    logBox = eb

    local flush = CreateFrame("Frame")
    flush:SetScript("OnUpdate", function()
        if not logDirty or not mainFrame or not mainFrame:IsShown() then return end
        logBox:SetText(table.concat(log, "\n"))
        logDirty = false
    end)
    f:Show()
end

DoExport = function()
    if #rawLog == 0 then print("|cffFF4444PT SUDebug:|r No log."); return end
    local ef = CreateFrame("Frame", nil, UIParent, "BasicFrameTemplateWithInset")
    ef:SetSize(720, 520); ef:SetPoint("CENTER"); ef:SetFrameStrata("DIALOG")
    ef:SetMovable(true); ef:EnableMouse(true); ef:RegisterForDrag("LeftButton")
    ef:SetScript("OnDragStart", ef.StartMoving); ef:SetScript("OnDragStop", ef.StopMovingOrSizing)
    local sf2 = CreateFrame("ScrollFrame", nil, ef, "UIPanelScrollFrameTemplate")
    sf2:SetPoint("TOPLEFT", ef, "TOPLEFT", 8, -28)
    sf2:SetPoint("BOTTOMRIGHT", ef, "BOTTOMRIGHT", -28, 8)
    local eb2 = CreateFrame("EditBox", nil, sf2)
    eb2:SetMultiLine(true); eb2:SetFontObject("ChatFontNormal"); eb2:SetWidth(680)
    eb2:SetAutoFocus(true); eb2:SetScript("OnEscapePressed", function() ef:Hide() end)
    sf2:SetScrollChild(eb2)
    eb2:SetText("=== PT_SU_LOG ===\n"..table.concat(rawLog, "\n").."\n=== END ===")
    eb2:HighlightText(); ef:Show()
end

-- ── Enable / Disable ──────────────────────────────────────────────────────────
local function Enable()
    enabled = true
    sessionStart = GetTime()
    log, rawLog, evtRing = {}, {}, {}
    windowIdx, winStats, pendingCount = 0, nil, 0
    suPresent = false
    lastMSWConsumeT = nil
    lastProcT = nil
    mHits, mMissed, mFalse = { 0,0,0,0 }, { 0,0,0,0 }, { 0,0,0,0 }
    lastCrashCastT = nil
    clusterN, cluster = 0, nil
    for _, ev in ipairs(TRACKED_EVENTS) do dbg:RegisterEvent(ev) end
    dbg:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    dbg:RegisterUnitEvent("UNIT_AURA", "player")
    BuildUI()
    InstallSetCDIDHook()
    ScanAndHook()
    if PT and PT.MSW and PT.MSW.Subscribe then
        PT.MSW.Subscribe("OnConsumed", OnMSWConsumedDbg)
    end
    WireDeck()
    Sep("SESSION START")
    Push("INFO", "SU_CDM="..SU_CDM_ID.."  buff="..SU_BUFF_ID.."  crash="..CRASH_CAST_ID, "info")
    local a, apps, readable = ReadBuff()
    Push("INIT buff", readable and ("active  stacks="..(apps and tostring(apps) or "<secret>"))
        or "not active / not readable by spellID", "info")
    Push("SU_CDM frame", suFrame and "found" or "NOT FOUND — proc once then hit Scan",
        suFrame and "cdm" or "warn")
    Push("deck registered", tostring(PT.GetDeck and PT.GetDeck("stormunleashed") ~= nil), "info")
    suPresent = FrameHasAura()
end

local function Disable()
    enabled = false
    dbg:UnregisterAllEvents()
    if PT and PT.MSW and PT.MSW.Unsubscribe then
        PT.MSW.Unsubscribe("OnConsumed", OnMSWConsumedDbg)
    end
    UnwireDeck()
    if mainFrame then mainFrame:Hide() end
end

ArcUI_PT_SUDebug = {
    Toggle    = function() if enabled then Disable() else Enable() end end,
    Export    = DoExport,
    IsEnabled = function() return enabled end,
}
