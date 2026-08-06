-- ArcUI_PT_DWDebug.lua
-- Doom Winds deck timeline debugger.
-- Watches CDM frame aura hooks, MSW consumes, hard-cast buffer,
-- proc gains, deck state, and rehook events.
-- Toggle: /pt dwdebug
-- No pcall. Zero polling. Zero CPU when hidden.

local issecretvalue = issecretvalue

-- ── Constants ─────────────────────────────────────────────────────────────────
local DW_CDM_ID   = 82621    -- CDM cooldownID for DW buff
local DW_CAST_ID  = 384352   -- Doom Winds hard-cast spellID
local DW_BUFF_ID  = 466772   -- Doom Winds buff spellID
local MSW_ID      = 344179

-- ── State ─────────────────────────────────────────────────────────────────────
local enabled      = false
local paused       = false
local log          = {}
local rawLog       = {}
local MAX_LOG      = 600
local logDirty     = false
local sessionStart = GetTime()
local mainFrame    = nil
local logBox       = nil

local dwFrame        = nil   -- CDM frame for DW buff
local dwKnownInstIDs = {}  -- set of auraInstanceIDs confirmed as DW buff

-- Forward declarations — defined in the Helpers section below, but the window
-- model closes over them.
local Push, Sep, SafeVal

-- ── Ground-truth window model ─────────────────────────────────────────────────
-- The DW buff's PRESENCE is fully non-secret (GetPlayerAuraBySpellID returns
-- nil or a struct; the nil-check never throws and is never secret). One
-- absent->present flip = one guaranteed real proc. Everything that happens
-- while present is either a back-to-back proc (the buff's end time moves) or
-- noise. Each window records what PT counted vs what actually happened.
local dwPresent      = false
local windowIdx      = 0
local winStats       = nil
local pendingCounted = 0     -- procs counted before the window officially opened
local lastSource     = "?"   -- source tag of the most recent accepted attempt

-- CDM FLAP HANDLING (live 12.0.x). CDM clears and re-sets its aura slot for an
-- aura that never actually left -- observed twice in a single frame. A naive
-- presence model treats each flap as a buff ending and a new one starting, which
-- both invents windows and poisons the baseline with zero-length ones. When the
-- instance id is READABLE we therefore key the window on the aura's IDENTITY:
-- the same id coming back means the same buff, so we resume the window we just
-- closed instead of opening a new one.
local windowAuraID = nil   -- readable instance id this window belongs to
local pendingClose = nil   -- { idx, s, endT, id } awaiting its deferred summary
local flapCount    = 0

local function ReadableAuraID()
    local f = dwFrame
    if not f then return nil end
    local id = f.auraInstanceID
    if id == nil then return nil end
    if issecretvalue and issecretvalue(id) then return nil end
    return id
end

-- Ground truth is the CDM frame's own aura slot, NOT GetPlayerAuraBySpellID:
-- the tracked aura's spellID is not necessarily DW_BUFF_ID (it can be an
-- override or a linked spell), and the by-spellID read came back nil for the
-- entire window on 12.1. `frame.auraInstanceID ~= nil` is a plain nil-check,
-- which is never secret, and it tracked the window exactly in both logs.
local function DWFrameHasAura()
    return dwFrame ~= nil and dwFrame.auraInstanceID ~= nil
end

-- Shortest window seen this session = the buff's un-refreshed duration. Any
-- window longer than that was re-timed, which is the only NON-SECRET proof a
-- back-to-back proc happened (the cooldown args are secret, so nothing numeric
-- about the duration itself is readable).
local baseWindowLen = nil
local LEN_EPS       = 1.5   -- margin before calling a window re-timed

-- DW refresh model, derived from four PTR windows and accurate to ~15ms:
--   fresh application  -> 10.0s
--   proc while active  -> min(remaining + 10.0, 12.0)   (pandemic, 20% overcap)
-- The 12s ceiling is why DW never shows more than 12s no matter how many
-- back-to-backs land. Predicting the end from the counted procs turns the
-- window summary into an exact oracle: predict too EARLY and a refresh was
-- missed, too LATE and one was invented.
local DW_BASE_DUR = 10.0
local DW_MAX_DUR  = 12.0

local function NewStats()
    return { set=0, cleared=0, added=0, updated=0, pushes=0, pushFromRefresh=0,
             refreshes=0, counted=0, extended=0, startT=GetTime(), lastProcT=nil }
end

local function DumpWindowSummary(idx, s, endT)
    if not s then return end
    local len = endT - s.startT
    -- Only a CLEAN window teaches us the un-refreshed duration: one counted proc
    -- and no refresh signal. Seeding from any window (as the first version did)
    -- lets a re-timed first window become the baseline and then fail its own
    -- comparison.
    -- A window must be plausibly a real buff before it can define the baseline.
    -- A CDM flap can produce a sub-second fragment, and adopting that as the
    -- un-refreshed duration makes every later window read as RE-TIMED.
    -- Take the LONGEST clean single-proc window as the un-refreshed duration.
    -- Nothing can lengthen a single-proc window, but plenty can cut one short
    -- (combat ending, the buff being overwritten, logging started mid-window),
    -- so the minimum is the wrong statistic -- it latches onto a truncated
    -- fragment and then every later window reads as RE-TIMED.
    local clean = s.counted <= 1 and s.updated == 0 and len >= 1.0
    if clean and (not baseWindowLen or len > baseWindowLen) then
        baseWindowLen = len
    end
    if not baseWindowLen then
        Push("WINDOW #"..idx.." SUMMARY",
            string.format("length %.2fs  |  PT COUNTED %d  |  no clean window seen yet, "
                .."so the un-refreshed duration is unknown — no verdict", len, s.counted), "info")
        return
    end
    local retimed = (len - baseWindowLen) > LEN_EPS

    -- Without a re-timing the window is worth exactly 1 proc. With one, it is
    -- worth at least 2 -- but the buff's end time only records the LAST
    -- re-timing, so the exact number of back-to-backs is not recoverable.
    local truthMin = retimed and 2 or 1
    local standalone = s.pushes - (s.pushFromRefresh or 0)

    local verdict
    if s.counted < truthMin then
        verdict = "violation"
    elseif not retimed and s.counted > 1 then
        verdict = "violation"
    else
        verdict = "deck"
    end

    Push("WINDOW #"..idx.." SUMMARY",
        string.format("length %.2fs (base %.2fs)%s  |  GROUND TRUTH %s proc(s)  |  PT COUNTED %d  |  "
            .."signals: set=%d cleared=%d added=%d updated=%d refreshData=%d  "
            .."cdPush=%d (%d from RefreshData, %d standalone)",
            len, baseWindowLen, retimed and "  RE-TIMED" or "",
            retimed and (">= "..truthMin) or "1",
            s.counted, s.set, s.cleared, s.added, s.updated,
            s.refreshes, s.pushes, s.pushFromRefresh or 0, standalone),
        verdict)

    -- The sharpest check available: a DW window's end is fully determined by its
    -- LAST proc. Measured on PTR across three windows, a refresh puts the end at
    -- refresh + 12.00s (within 7ms), and an un-refreshed window runs 10.00s. So
    -- if this number is a consistent constant across windows, every refresh was
    -- counted; an odd one out means a proc was missed (too long) or invented
    -- (too short).
    -- Exact check: does the observed end match what the counted procs predict?
    if s.predEnd then
        local err = endT - s.predEnd
        local verdictTxt, col
        if math.abs(err) <= 0.30 then
            verdictTxt = "MATCHES — every proc in this window was counted"
            col = "deck"
        elseif err > 0 then
            verdictTxt = string.format("buff outlived the prediction by %.2fs — a refresh was MISSED", err)
            col = "violation"
        else
            verdictTxt = string.format("buff died %.2fs early — a proc was counted that did not happen", -err)
            col = "violation"
        end
        Push("  ^ duration check", string.format(
            "%d proc(s) predict end at +%.2fs, observed +%.2fs  |  %s",
            s.counted, s.predEnd - s.startT, len, verdictTxt), col)
    end

    if retimed then
        -- How much the refresh added. NOTE: do not read this as "end == last
        -- refresh + base duration" — that assumes a refresh resets to full, and
        -- the observed data fits "each refresh adds a fixed amount" just as
        -- well. Report the overrun and let repeated samples settle the model.
        Push("  ^ RE-TIMED", string.format(
            "window ran %.2fs longer than the un-refreshed %.2fs — the buff WAS re-timed, "
            .."so >= 1 back-to-back proc happened",
            len - baseWindowLen, baseWindowLen), "dw_gain")
    end
    if standalone > 0 then
        Push("  ^ standalone push", standalone.." cooldown push(es) NOT caused by a RefreshData", "dw_gain")
    end
    if verdict == "violation" then
        Push("  ^ MISCOUNT", string.format("PT counted %d, expected %s",
            s.counted, retimed and (">= "..truthMin) or "exactly 1"), "violation")
    end
end

-- ── Duration-object extension detector ────────────────────────────────────────
-- The only non-secret way to know whether a cooldown push RESTARTED the DW
-- window or merely re-fed the same remaining time: mirror each pushed durObj
-- into its own shadow Cooldown and compare when they finish. A re-parse ends at
-- the same moment as the push before it; a real back-to-back proc ends later by
-- exactly the amount it extended the buff.
local shadowPool   = {}
local pushIdx      = 0
local pushTime     = {}
local endTime      = {}
local pushStats    = {}   -- [idx] = the winStats table this push belongs to
local comparable   = {}   -- [idx] = was the previous push part of the same window?
local chainBreak   = 0    -- last push index of the window that just ended
local shadowWarned = false
local EXTEND_EPS   = 0.10   -- seconds; re-parses land within one frame

local function ClassifyPush(idx)
    local e = endTime[idx]
    if not e then return end
    -- Never compare across windows. Comparability is decided AT PUSH TIME —
    -- classification runs after the window has closed, by which point the live
    -- chain-break marker has already moved past this push.
    local pe = comparable[idx] and endTime[idx-1] or nil
    if not pe then
        Push("cdPush #"..idx.." classify",
            string.format("ended %.2fs after the push (first push of this window)",
                e - (pushTime[idx] or e)), "dw_cdm")
        return
    end
    local delta = e - pe
    if delta > EXTEND_EPS then
        -- Credit the window this push belonged to, not whatever window is open
        -- now: extensions only resolve once the window has already closed.
        local st = pushStats[idx]
        if st then st.extended = st.extended + 1 end
        Push("cdPush #"..idx.." = REAL PROC",
            string.format("window END MOVED +%.2fs — back-to-back proc", delta), "dw_gain")
    else
        Push("cdPush #"..idx.." = re-parse",
            string.format("end unchanged (%+.3fs) — NOT a proc", delta), "info")
    end
end

local function ShadowDone(sh)
    sh._free = true
    local idx = sh._idx
    if not idx then return end
    endTime[idx] = GetTime()
    if not enabled then return end
    C_Timer.After(0.05, function() ClassifyPush(idx) end)
end

local function AcquireShadow()
    for _, sh in ipairs(shadowPool) do
        if sh._free then sh._free = false; return sh end
    end
    if #shadowPool >= 24 then
        if not shadowWarned then
            shadowWarned = true
            Push("SHADOW POOL EXHAUSTED", "too many concurrent pushes — extension detection degraded", "warn")
        end
        return nil
    end
    local sh = CreateFrame("Cooldown", nil, UIParent, "CooldownFrameTemplate")
    sh:SetSize(1, 1)
    sh:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", -100, -100)
    sh:SetAlpha(0)
    sh:EnableMouse(false)
    sh:SetHideCountdownNumbers(true)
    sh:SetScript("OnCooldownDone", function(self) ShadowDone(self) end)
    sh._free = false
    shadowPool[#shadowPool+1] = sh
    return sh
end

local function TrackPush(durObj)
    pushIdx = pushIdx + 1
    local idx = pushIdx
    pushTime[idx]   = GetTime()
    pushStats[idx]  = winStats
    comparable[idx] = (idx - 1) > chainBreak
    local old = idx - 64
    if old > 0 then
        pushTime[old] = nil; endTime[old] = nil
        pushStats[old] = nil; comparable[old] = nil
    end
    if winStats then winStats.pushes = winStats.pushes + 1 end
    if not durObj then
        Push("DW_CD.DurObjPush #"..idx, "nil durObj", "dw_cdm")
        return
    end
    local sh = AcquireShadow()
    if not sh then return end
    sh._idx = idx
    sh:SetCooldownFromDurationObject(durObj, true)
    if not sh:IsShown() then
        -- Zero-span push: nothing to time, and it means no window is running —
        -- break the comparison chain so it can't be read as an end time.
        sh._free = true
        chainBreak = idx
        Push("DW_CD.DurObjPush #"..idx, "zero-span (buff not running)", "dw_cdm")
        return
    end
    Push("DW_CD.DurObjPush #"..idx, "cooldown re-fed — classification pending", "dw_cdm")
end

-- ── SetCooldown extension detector (the real path) ────────────────────────────
-- CDM does NOT feed this frame a duration object. CooldownViewer.lua drives the
-- swipe with CooldownFrame_Set(cooldownFrame, startTime, duration, ...) which
-- lands on Cooldown:SetCooldown. Those args are computed inside Blizzard's
-- SECURE execution, so they normally arrive here as real numbers even on 12.1
-- (checked with issecretvalue anyway — if they are secret we say so instead of
-- guessing, and SetCooldown must never be fed a secret).
local lastEndTime   = nil
local pendingPushAt = nil   -- GetTime() of a push waiting to be paired with a RefreshData

local function TrackSetCooldown(start, duration)
    pushIdx = pushIdx + 1
    local idx = pushIdx
    if winStats then winStats.pushes = winStats.pushes + 1 end

    if issecretvalue and (issecretvalue(start) or issecretvalue(duration)) then
        -- Confirmed on 12.1: the args arrive SECRET, so no numeric compare is
        -- possible. The CALL is still a non-secret signal. RefreshCooldownInfo
        -- pushes the swipe on every RefreshData, and RefreshData is rare on this
        -- frame (it ignores override updates for other base spells), so a SECOND
        -- push inside one window is a strong back-to-back candidate.
        -- A push on its own means nothing: RefreshCooldownInfo re-pushes the
        -- swipe on EVERY RefreshData while the aura is up, so pushes track
        -- RefreshData one-for-one. Only a push with no RefreshData in the same
        -- frame is a genuine re-timing. Pair them up in NoteRefreshData.
        pendingPushAt = GetTime()
        local n = winStats and winStats.pushes or 0
        Push("DW_CD.SetCooldown #"..idx,
            "args SECRET (no numeric classify)  hasAura="..tostring(DWFrameHasAura())
            .."  pushInWindow="..n, "dw_cdm")
        return
    end

    start    = tonumber(start)
    duration = tonumber(duration)
    if not start or not duration or duration <= 0 then
        lastEndTime = nil
        Push("DW_CD.SetCooldown #"..idx,
            "zero/cleared (start="..tostring(start).." dur="..tostring(duration)..")", "dw_cdm")
        return
    end

    local newEnd = start + duration
    if not lastEndTime then
        lastEndTime = newEnd
        Push("DW_CD.SetCooldown #"..idx,
            string.format("window START  dur=%.2fs  ends in %.2fs", duration, newEnd - GetTime()),
            "dw_cdm")
        return
    end

    local delta = newEnd - lastEndTime
    lastEndTime = newEnd
    if delta > EXTEND_EPS then
        if winStats then winStats.extended = winStats.extended + 1 end
        Push("DW_CD.SetCooldown #"..idx.." = REAL PROC",
            string.format("end MOVED +%.2fs (dur=%.2fs) — back-to-back proc", delta, duration),
            "dw_gain")
    else
        Push("DW_CD.SetCooldown #"..idx.." = re-parse",
            string.format("end unchanged (%+.3fs) — NOT a proc", delta), "info")
    end
end

-- ── SPELL_UPDATE_COOLDOWN trail ───────────────────────────────────────────────
-- 12.0 gave SPELL_UPDATE_COOLDOWN a (spellID, baseSpellID, category,
-- startRecoveryCategory, itemID) payload, and that payload is how the Fire Nova
-- investigation detected a completely silent hidden proc. If a DW proc has its
-- own spell-update signature, it will be in the few events immediately before
-- the aura appears. Ring-buffer them all, dump the recent ones at the moment a
-- proc is confirmed, and let the log say whether a signature exists.
local sucRing, SUC_MAX = {}, 40

local HuntNote   -- forward declaration; defined in the marker-hunt block below

local function NoteSpellUpdate(spellID, baseSpellID, category, startRecovery, itemID)
    HuntNote(spellID)
    sucRing[#sucRing+1] = {
        t = GetTime(), s = spellID, b = baseSpellID,
        c = category, r = startRecovery, i = itemID,
    }
    if #sucRing > SUC_MAX then table.remove(sucRing, 1) end
end

local function DumpSpellUpdateTrail(window)
    local now, shown = GetTime(), 0
    for i = #sucRing, 1, -1 do
        local e = sucRing[i]
        if now - e.t > (window or 1.0) then break end
        shown = shown + 1
    end
    if shown == 0 then
        Push("  spell-update trail", "no SPELL_UPDATE_COOLDOWN in the last "
            ..string.format("%.1fs", window or 1.0), "info")
        return
    end
    for i = #sucRing - shown + 1, #sucRing do
        local e = sucRing[i]
        Push(string.format("  SUC -%.3fs", now - e.t),
            "spellID="..SafeVal(e.s).."  base="..SafeVal(e.b)
            .."  cat="..SafeVal(e.c).."  startRec="..SafeVal(e.r)
            .."  item="..SafeVal(e.i), "rehook")
    end
end

-- ── MARKER HUNT: spend-window ID capture + automatic set diff ────────────────
-- How 1252413 was found for Storm Unleashed: on a spend that procced, the
-- SPELL_UPDATE_COOLDOWN payload carried one extra spellID that never appeared on
-- a spend that did not proc. That ID turned out to be a hidden 3s dummy aura
-- stamped at proc time -- a pure GAIN signal, unlike the visible buff whose
-- cooldown updates on every state change and cannot tell direction.
--
-- This does the same diff for Doom Winds, but computes it instead of leaving it
-- to the eye: every ID seen inside a spend window is tallied against whether
-- that window procced. A marker shows up as present in EVERY proc window and
-- NO non-proc window. Ground truth for "did it proc" is the DW deck's existing
-- CDM path, which is what we are trying to replace -- fine as a reference here
-- precisely because it is independent of the thing being measured.
local HUNT_CAPTURE = 0.25   -- collect IDs for this long after the spend
local HUNT_VERDICT = 0.50   -- then decide proc/no-proc (CDM can lag the spend)

local huntOpenUntil   = 0
local huntIDs         = nil   -- set of spellIDs seen in the open window
local huntProcT       = 0     -- GetTime() of the last accepted DW gain
local huntProcWins    = 0
local huntNoProcWins  = 0
local huntSeenProc    = {}    -- id -> count of PROC windows it appeared in
local huntSeenNoProc  = {}    -- id -> count of NO-PROC windows it appeared in

function HuntNote(spellID)
    if not huntIDs then return end
    if GetTime() > huntOpenUntil then return end
    if issecretvalue and issecretvalue(spellID) then return end
    local id = tonumber(spellID)
    if id then huntIDs[id] = true end
end

local function HuntReport()
    Sep("MARKER CANDIDATES")
    Push("windows sampled", "proc="..huntProcWins.."  no-proc="..huntNoProcWins, "info")
    if huntProcWins == 0 then
        Push("  nothing yet", "need at least one PROC window -- keep fighting", "warn")
        return
    end
    -- RANK, do not filter. Requiring "absent from every no-proc window" throws
    -- away the true marker the moment CDM mislabels one window -- and CDM is the
    -- fallible thing we are trying to replace. Score each ID by how much more
    -- often it shows up on procs than on non-procs, and show the top of the
    -- list; a near-miss with one stray no-proc hit stays visible instead of
    -- silently vanishing.
    local rows = {}
    for id, n in pairs(huntSeenProc) do
        local no    = huntSeenNoProc[id] or 0
        local pRate = n / huntProcWins
        local nRate = huntNoProcWins > 0 and (no / huntNoProcWins) or 0
        rows[#rows+1] = { id = id, p = n, n = no, score = pRate - nRate }
    end
    table.sort(rows, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.id < b.id
    end)

    local perfect = 0
    for i = 1, math.min(#rows, 12) do
        local r = rows[i]
        local isPerfect = (r.p == huntProcWins and r.n == 0)
        if isPerfect then perfect = perfect + 1 end
        local nm = C_Spell.GetSpellName and C_Spell.GetSpellName(r.id)
        Push(string.format("  %s%d", isPerfect and ">>> " or "    ", r.id),
            string.format("proc %d/%d  no-proc %d/%d  score %+.2f  %s%s",
                r.p, huntProcWins, r.n, huntNoProcWins, r.score,
                nm and ('"'..nm..'"') or "(unnamed)",
                isPerfect and "   <<< CLEAN" or ""),
            isPerfect and "dw_gain" or "info")
    end
    if perfect == 0 then
        Push("  no clean candidate yet", "nothing is in every proc window AND absent "
            .."from all no-proc windows -- judge by score above; a high score with "
            .."one stray no-proc hit is still a strong lead", "warn")
    end
    Push("  reminder", "Doom Winds summons a Feral Spirit via Rolling Thunder (node "
        .."94889) or Feral Spirit (node 109194), so wolf IDs 148988 / 469332 / "
        .."224127 are a CONSEQUENCE of a proc, not noise -- but they are "
        .."talent-gated, so only usable when one of those nodes is taken", "info")
end

local function HuntOpen()
    huntIDs       = {}
    huntOpenUntil = GetTime() + HUNT_CAPTURE
    local opened  = GetTime()
    C_Timer.After(HUNT_VERDICT, function()
        if not enabled then huntIDs = nil; return end
        local ids = huntIDs
        huntIDs   = nil
        if not ids then return end
        local isProc = huntProcT >= opened - 0.10
        local tally  = isProc and huntSeenProc or huntSeenNoProc
        if isProc then huntProcWins = huntProcWins + 1
        else huntNoProcWins = huntNoProcWins + 1 end

        local list, n = {}, 0
        for id in pairs(ids) do
            tally[id] = (tally[id] or 0) + 1
            n = n + 1
            list[#list+1] = id
        end
        table.sort(list)
        local shown = {}
        for i = 1, math.min(#list, 40) do shown[i] = tostring(list[i]) end
        Push("HUNT WINDOW ["..(isProc and "PROC" or "no proc").."]",
            n.." ids: "..table.concat(shown, " ")..(#list > 40 and " ..." or ""),
            isProc and "dw_gain" or "info")

        -- Re-report the running diff every few proc windows so the answer
        -- surfaces without having to ask for it.
        if isProc and huntProcWins % 3 == 0 then HuntReport() end
    end)
end

-- ── RefreshData storm counter ─────────────────────────────────────────────────
-- Enh's Lightning Bolt <-> Tempest override churn makes CDM run RefreshData on
-- every frame constantly. Logging each one would bury the timeline, so count
-- them and report per second / per window instead.
local rdBucket, rdBucketCount, rdLastLog = 0, 0, 0

local function NoteRefreshData()
    if winStats then winStats.refreshes = winStats.refreshes + 1 end
    local now = GetTime()
    -- Our RefreshData hook runs AFTER the method body, so any push it caused
    -- has already been logged this frame. Pair them so the summary can tell
    -- routine re-pushes apart from a genuine re-timing.
    if pendingPushAt == now then
        if winStats then winStats.pushFromRefresh = (winStats.pushFromRefresh or 0) + 1 end
        pendingPushAt = nil
    end
    local sec = math.floor(now)
    if sec ~= rdBucket then
        if rdBucketCount > 5 then
            Push("RefreshData storm", rdBucketCount.." calls on the DW frame in 1s", "warn")
        end
        rdBucket = sec
        rdBucketCount = 0
    end
    rdBucketCount = rdBucketCount + 1
    -- Throttled sample. RefreshData -> RefreshCooldownInfo -> CooldownFrame_Set
    -- -> Cooldown:SetCooldown, so a RefreshData while the frame HOLDS AN AURA
    -- that produces no SetCooldown line means the swipe is being driven through
    -- some other widget/path than frame.Cooldown.
    if now - rdLastLog >= 0.5 then
        rdLastLog = now
        Push("DW_CDM.RefreshData", "hasAura="..tostring(DWFrameHasAura()), "info")
    end
end

local function CheckDWPresence()
    local present = DWFrameHasAura()
    if present == dwPresent then return end
    dwPresent = present
    if present then
        -- Same aura identity returning right after a close = CDM flap, not a new
        -- buff. Resume the window we just closed and cancel its summary.
        local id = ReadableAuraID()
        if id ~= nil and pendingClose ~= nil and pendingClose.id == id then
            flapCount = flapCount + 1
            Push("CDM FLAP #"..flapCount,
                "aura "..tostring(id).." was cleared and re-set — SAME instance, the buff "
                .."never left. Window #"..pendingClose.idx.." resumes; any proc counted off "
                .."that Set is PHANTOM.", "violation")
            winStats     = pendingClose.s
            windowIdx    = pendingClose.idx
            pendingClose = nil     -- cancels the deferred summary
            return
        end
        windowIdx    = windowIdx + 1
        windowAuraID = id
        winStats = NewStats()
        winStats.counted = pendingCounted
        pendingCounted = 0
        -- The fresh proc that opened this window is counted before the window
        -- exists (the Set hook fires first), so seed the prediction here.
        winStats.predEnd = winStats.startT + DW_BASE_DUR
        local secret = (issecretvalue and issecretvalue(dwFrame.auraInstanceID)) and "SECRET" or "readable"
        Sep("DW WINDOW #"..windowIdx.." OPEN")
        Push("DW PRESENT (ground truth)",
            "CDM frame holds an aura = 1 guaranteed real proc   aid="..secret
            .."  auraSpellID="..SafeVal(dwFrame.auraSpellID), "dw_gain")
        DumpSpellUpdateTrail(1.0)
    else
        local idx, s = windowIdx, winStats
        winStats    = nil
        chainBreak  = pushIdx   -- nothing after this compares to this window
        lastEndTime = nil
        local endT = GetTime()
        -- Hold the close open briefly: if the SAME aura id comes straight back
        -- it was a CDM flap and this window is not actually over.
        pendingClose = { idx = idx, s = s, endT = endT, id = windowAuraID }
        Push("DW ABSENT (ground truth)", "aura slot cleared (id="..tostring(windowAuraID)
            ..") — window #"..idx.." closing, pending flap check", "dw_cast")
        C_Timer.After(0.3, function()
            if not enabled then return end
            if not pendingClose or pendingClose.idx ~= idx then return end  -- flapped and resumed
            pendingClose = nil
            DumpWindowSummary(idx, s, endT)
        end)
    end
end

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function TS()
    return string.format("%07.3f", GetTime() - sessionStart)
end

function SafeVal(v)
    if v == nil then return "nil" end
    if issecretvalue and issecretvalue(v) then return "<secret>" end
    return tostring(v)
end

local COLOR = {
    msw_consume  = "00FFFF",
    msw_gain     = "44FFBB",
    dw_gain      = "FF6600",
    dw_cast      = "FF4400",
    dw_cdm       = "FFAA44",
    rehook       = "88CCFF",
    invalidate   = "FF88FF",
    deck         = "00FFCC",
    rollover     = "FFFF44",
    violation    = "FF4444",
    separator    = "444444",
    info         = "888888",
    warn         = "FF8800",
}

function Push(tag, detail, colorKey)
    if not enabled or paused then return end
    local col = (type(colorKey) == "string" and #colorKey == 6 and colorKey:match("^%x+$"))
                and colorKey
                or (COLOR[colorKey] or "CCCCCC")
    local ts  = TS()
    local line = string.format("|cff%s[%s] %-38s|r %s", col, ts, tag, detail or "")
    table.insert(log, line)
    if #log > MAX_LOG then table.remove(log, 1) end
    table.insert(rawLog, string.format("[%s] %-38s %s", ts, tag, (detail or ""):gsub("|c%x%x%x%x%x%x%x%x",""):gsub("|r","")))
    if #rawLog > 10000 then table.remove(rawLog, 1) end
    logDirty = true
end

function Sep(label)
    Push("──── " .. (label or "") .. " ────", "", "separator")
end

-- ── CDM frame finder ──────────────────────────────────────────────────────────
-- Scan every viewer, not just the icon one: DW may be laid out as a CDM BAR.
local CDM_VIEWERS = {
    "BuffIconCooldownViewer",
    "BuffBarCooldownViewer",
    "EssentialCooldownViewer",
    "UtilityCooldownViewer",
}

local function FindDWCDMFrame()
    for _, viewerName in ipairs(CDM_VIEWERS) do
        local viewer = _G[viewerName]
        if viewer and viewer.itemFramePool then
            for frame in viewer.itemFramePool:EnumerateActive() do
                if frame.cooldownID == DW_CDM_ID then return frame, viewerName end
            end
        end
    end
    return nil
end

-- ── Hook CDM frame ────────────────────────────────────────────────────────────
local function HookDWCDMFrame(frame)
    if not frame or frame._arcPTDWDbgHooked then return end
    frame._arcPTDWDbgHooked = true

    if frame.OnAuraInstanceInfoSet then
        hooksecurefunc(frame, "OnAuraInstanceInfoSet", function(self)
            if not enabled then return end
            -- Blizzard only calls this when ITS OWN compare in SetAuraInstanceInfo
            -- saw a genuinely different instance/spell, so the firing itself is a
            -- non-secret "the aura instance changed" signal.
            Push("DW_CDM.OnAuraInstanceInfoSet",
                "instID="..SafeVal(self.auraInstanceID)
                .."  auraSpellID="..SafeVal(self.auraSpellID)
                .."  dwPresentBefore="..tostring(dwPresent)
                .." tracking="..tostring(PT.DW and PT.DW.IsCDMTracking and PT.DW.IsCDMTracking()), "dw_cdm")
            -- After CheckDWPresence: a Set that OPENS a window must be counted
            -- into the window it opened, not into the previous (nil) one.
            CheckDWPresence()   -- exact window boundary, don't wait for UNIT_AURA
            if winStats then winStats.set = winStats.set + 1 end
        end)
    end

    if frame.OnAuraInstanceInfoCleared then
        hooksecurefunc(frame, "OnAuraInstanceInfoCleared", function(self)
            if not enabled then return end
            if winStats then winStats.cleared = winStats.cleared + 1 end
            -- A Cleared while the buff is still PRESENT means CDM lost track of
            -- the aura and will re-Set it — that pair fakes a "new instance".
            Push("DW_CDM.OnAuraInstanceInfoCleared",
                "prev="..SafeVal(self.auraInstanceID), "dw_cdm")
            CheckDWPresence()   -- exact window boundary
        end)
    end

    if frame.OnUnitAuraAddedEvent then
        hooksecurefunc(frame, "OnUnitAuraAddedEvent", function(self)
            if not enabled then return end
            if winStats then winStats.added = winStats.added + 1 end
            -- CooldownViewer.lua calls this on EVERY active item frame for ANY
            -- added-aura batch (Blizzard filters inside via NeedsAddedAuraUpdate).
            -- So a fire while the DW buff is already up is unrelated noise.
            Push("DW_CDM.OnUnitAuraAddedEvent",
                "instID="..SafeVal(self.auraInstanceID)
                ..(dwPresent and "  |cffFF8800(DW already up — batch is NOT a DW proc)|r" or ""), "dw_cdm")
        end)
    end

    if frame.OnUnitAuraUpdatedEvent then
        hooksecurefunc(frame, "OnUnitAuraUpdatedEvent", function(self)
            if not enabled then return end
            local instID = self.auraInstanceID
            if not instID then return end
            if winStats then winStats.updated = winStats.updated + 1 end
            -- Dispatched only for frames mapped to this specific aura instance.
            Push("DW_CDM.OnUnitAuraUpdatedEvent",
                "instID="..SafeVal(instID), "dw_cdm")
        end)
    end

    if frame.RefreshData and not frame._arcPTDWDbgRDHooked then
        frame._arcPTDWDbgRDHooked = true
        hooksecurefunc(frame, "RefreshData", function()
            if not enabled then return end
            NoteRefreshData()
        end)
    end

    -- 12.1 DISCRIMINATOR HUNT: a REAL proc (fresh OR back-to-back refresh) must
    -- re-push fresh timing into the frame's Cooldown to restart the 10s swipe.
    -- The push itself is a hookable, NON-SECRET event -- candidate replacement
    -- for the aid==aid refresh check that dies on secret ids. We also mirror
    -- every pushed durObj into a shadow Cooldown: its OnCooldownDone stamps the
    -- TRUE buff end, which validates the 10s-per-proc timing model in the log.
    -- Open question the log answers: do full-update re-parses re-push too?
    local cd = frame.Cooldown
    if cd and not cd._arcPTDWDbgCDHooked then
        cd._arcPTDWDbgCDHooked = true
        -- The path CDM actually uses (CooldownFrame_Set -> SetCooldown).
        hooksecurefunc(cd, "SetCooldown", function(_, start, duration)
            if not enabled then return end
            TrackSetCooldown(start, duration)
        end)
        -- Kept as a fallback in case anything ever feeds this frame a durObj.
        hooksecurefunc(cd, "SetCooldownFromDurationObject", function(_, durObj)
            if not enabled then return end
            TrackPush(durObj)
        end)
        hooksecurefunc(cd, "Clear", function()
            if not enabled then return end
            chainBreak  = pushIdx   -- window torn down; later pushes start fresh
            lastEndTime = nil
            Push("DW_CD.Clear", "cooldown cleared", "dw_cdm")
        end)
    end

    Push("DW_CDM["..DW_CDM_ID.."] HOOKED", "frame="..tostring(frame:GetName() or tostring(frame)), "dw_cdm")
end

local function ScanAndHookFrames()
    local f, viewerName = FindDWCDMFrame()
    if f and f ~= dwFrame then
        dwFrame = f
        Push("DW_CDM frame located", "viewer="..tostring(viewerName)
            .."  Cooldown="..tostring(f.Cooldown ~= nil)
            .."  Bar="..tostring(f.Bar ~= nil), "rehook")
        HookDWCDMFrame(f)
    end
end

-- ── SetCooldownID / ClearCooldownID hooks ─────────────────────────────────────
local function InstallSetCDIDHook()
    if not CooldownViewerItemDataMixin then return end
    if CooldownViewerItemDataMixin._arcPTDWDbgSetCDIDHooked then return end
    CooldownViewerItemDataMixin._arcPTDWDbgSetCDIDHooked = true

    hooksecurefunc(CooldownViewerItemDataMixin, "SetCooldownID", function(self, cooldownID)
        if not enabled then return end
        local frameStr = tostring(self:GetName() or tostring(self))
        local tracking = PT.DW and PT.DW.IsCDMTracking and PT.DW.IsCDMTracking()
        if cooldownID == DW_CDM_ID then
            Push("SetCooldownID DW_CDM["..DW_CDM_ID.."]",
                "frame="..frameStr.." isNewFrame="..tostring(self ~= dwFrame)
                .." tracking="..tostring(tracking), "rehook")
            if self ~= dwFrame then
                dwFrame = self
                HookDWCDMFrame(self)
            end
        end
    end)

    if CooldownViewerItemDataMixin.ClearCooldownID then
        hooksecurefunc(CooldownViewerItemDataMixin, "ClearCooldownID", function(self)
            if not enabled then return end
            local tracking = PT.DW and PT.DW.IsCDMTracking and PT.DW.IsCDMTracking()
            Push("ClearCooldownID",
                "frame="..tostring(self:GetName() or tostring(self))
                .." trackingAfter="..tostring(tracking), "invalidate")
        end)
    end
end

-- ── MSW consume subscriber ────────────────────────────────────────────────────
local function OnMSWConsumedDbg(stacksSpent, spenderID, ascActive)
    if not enabled then return end
    local sname = spenderID and (C_Spell.GetSpellName(spenderID) or tostring(spenderID)) or "?"
    -- Read totals live from PT.MSW (authoritative source, counts all consumes)
    local tot    = PT.MSW.GetTotalConsumed and PT.MSW.GetTotalConsumed() or "?"
    local totStk = PT.MSW.GetTotalStacksAll and PT.MSW.GetTotalStacksAll() or "?"
    local noAsc  = PT.MSW.GetTotalConsumedNoAsc and PT.MSW.GetTotalConsumedNoAsc() or "?"
    local noAscS = PT.MSW.GetTotalStacksNoAsc and PT.MSW.GetTotalStacksNoAsc() or "?"
    Push("MSW_CONSUMED",
        "stacks="..tostring(stacksSpent)
        .." spender="..tostring(spenderID).."("..sname..")"
        ..(ascActive and " [ASC]" or "")
        .."  |cff888888total="..tostring(tot).." stk="..tostring(totStk)
        .." noASC="..tostring(noAsc).." noASCstk="..tostring(noAscS).."|r",
        "msw_consume")
    HuntOpen()
end

-- ── Wire DW deck debug callbacks ──────────────────────────────────────────────
local function WireDeckDebug()
    if not (PT and PT.DW) then return end

    -- Every gain ATTEMPT, accepted or rejected, with the guard that killed it.
    -- This is what exposes an over-count: the accepted source tells you which
    -- hook path fed it, and the ground-truth window says whether it was real.
    PT.DW.OnAttempt = function(source, accepted, reason)
        if not enabled then return end
        if accepted then
            lastSource = tostring(source)
            huntProcT  = GetTime()   -- marks the open spend window as a PROC
            if winStats then
                local now = GetTime()
                winStats.counted   = winStats.counted + 1
                winStats.lastProcT = now
                -- Advance the predicted end by the refresh model -- but ONLY for
                -- the second proc onward. The proc that OPENED this window is
                -- already baked into predEnd (set to startT + DW_BASE_DUR at
                -- open), so extending on the first counted proc double-applied
                -- it and made every correct single-proc window report
                -- "predict +12.25s, observed +10.00s -- buff died 2.25s early".
                -- Only a genuine back-to-back refreshes the duration.
                if winStats.predEnd and winStats.counted > 1 then
                    local remaining = winStats.predEnd - now
                    if remaining < 0 then remaining = 0 end
                    winStats.predEnd = now + math.min(remaining + DW_BASE_DUR, DW_MAX_DUR)
                end
            else
                pendingCounted = pendingCounted + 1
            end
        else
            Push("attempt REJECTED",
                "src="..tostring(source).."  reason="..tostring(reason)
                .."  dwPresent="..tostring(dwPresent), "info")
        end
    end

    PT.DW.OnProc = function(deckNum, deckProcs, totalGain, deckPos)
        if not enabled then return end
        Push("PROC COUNTED",
            "src="..lastSource.."  deck#"..tostring(deckNum).." procs="..tostring(deckProcs).."/3"
            .." total#"..tostring(totalGain).." pos="..tostring(deckPos)
            ..(dwPresent and "  |cffFF8800(DW buff ALREADY up — must be a back-to-back to be real)|r" or ""),
            "dw_gain")
    end

    PT.DW.OnDeckRollover = function(newDeckNum, prevProcs, violation)
        if not enabled then return end
        local col = violation and "violation" or "rollover"
        Push("DECK ROLLOVER",
            "newDeck#"..tostring(newDeckNum)
            .." prevProcs="..tostring(prevProcs).."/3"
            ..(violation and " *** VIOLATION ***" or " clean"), col)
    end
end

local function UnwireDeckDebug()
    if not (PT and PT.DW) then return end
    PT.DW.OnProc        = nil
    PT.DW.OnDeckRollover = nil
    PT.DW.OnAttempt     = nil
end

-- ── Event listener ────────────────────────────────────────────────────────────
local dbgFrame = CreateFrame("Frame")

dbgFrame:SetScript("OnEvent", function(_, event, a1, a2, a3, a4, a5)
    if not enabled then return end

    if event == "SPELL_UPDATE_COOLDOWN" then
        -- Buffered only, never logged inline: this fires on every GCD.
        NoteSpellUpdate(a1, a2, a3, a4, a5)
        return
    end

    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        if a1 ~= "player" then return end
        if not a3 or (issecretvalue and issecretvalue(a3)) then return end
        local sid = tonumber(a3)
        if not sid then return end
        if sid == DW_CAST_ID then
            Push("SPELLCAST  DoomWinds (hard-cast)", "spellID="..sid.." — suppressing first proc", "dw_cast")
        end
        return
    end

    if event == "UNIT_AURA" then
        if a1 ~= "player" then return end
        -- Payload-free ground truth FIRST — this path never throws and never
        -- goes secret, so it works identically in the open world and in a key.
        CheckDWPresence()
        local info = a2
        -- A FULL UPDATE makes the viewer call RefreshLayout() and return, which
        -- skips OnUnitAuraUpdatedEvent entirely -- so a buff refresh arriving in
        -- a full-update batch would be invisible to our back-to-back path. Log
        -- them while the window is open so a missed refresh can be pinned.
        -- Only the cases that TELL us something. isFullUpdate reads <secret> on
        -- every 12.1 batch, so logging that was pure noise; a nil payload or a
        -- readable true still matter, because either means the viewer took the
        -- RefreshLayout early-out and skipped every per-instance callback.
        if dwPresent then
            if not info then
                Push("UNIT_AURA (window)", "no payload = FULL UPDATE — updated events SKIPPED", "warn")
            elseif not (issecretvalue and issecretvalue(info.isFullUpdate)) and info.isFullUpdate then
                Push("UNIT_AURA (window)", "isFullUpdate=true — updated events SKIPPED this batch", "warn")
            end
        end
        if not info then return end
        -- 12.1: payload vectors are SECRET in restricted content (ipairs on
        -- them THROWS, and their ids poison table keys) -- skip debug parsing
        if issecretvalue and issecretvalue(info.isFullUpdate) then return end
        if info.addedAuras then
            for _, aura in ipairs(info.addedAuras) do
                local sid = not (issecretvalue and issecretvalue(aura.spellId)) and tonumber(aura.spellId) or nil
                if sid == MSW_ID then
                    local apps = not (issecretvalue and issecretvalue(aura.applications)) and tonumber(aura.applications) or "?"
                    Push("UNIT_AURA  MSW GAINED", "instID="..SafeVal(aura.auraInstanceID).." apps="..tostring(apps), "msw_gain")
                elseif sid == DW_BUFF_ID then
                    local instID = aura.auraInstanceID
                    dwKnownInstIDs[instID] = true
                    -- Also check via spell ID API in case instID from addedAuras is secret
                    local live = C_UnitAuras.GetPlayerAuraBySpellID(DW_BUFF_ID)
                    local liveInstID = live and live.auraInstanceID or nil
                    Push("UNIT_AURA  DW BUFF GAINED", "instID="..SafeVal(instID).." spellIDapi="..SafeVal(liveInstID), "dw_gain")
                    if liveInstID then dwKnownInstIDs[liveInstID] = true end
                end
            end
        end
        if info.removedAuraInstanceIDs then
            for _, instID in ipairs(info.removedAuraInstanceIDs) do
                if dwKnownInstIDs[instID] then
                    dwKnownInstIDs[instID] = nil
                    Push("UNIT_AURA  DW BUFF FADED", "instID="..SafeVal(instID), "dw_cast")
                end
            end
        end
        return
    end

    if event == "COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED" then
        local base = a1
        local baseStr = not (issecretvalue and issecretvalue(base)) and tostring(tonumber(base)) or "<secret>"
        Push("CDM_OVERRIDE_UPDATED", "base="..baseStr, "rehook")
        ScanAndHookFrames()
        return
    end
end)

-- ── UI ────────────────────────────────────────────────────────────────────────
local function DoExport()
    if #rawLog == 0 then print("|cffFF4444PT DWDebug:|r No log."); return end
    local ef = CreateFrame("Frame", nil, UIParent, "BasicFrameTemplateWithInset")
    ef:SetSize(720, 520); ef:SetPoint("CENTER"); ef:SetFrameStrata("DIALOG")
    ef:SetMovable(true); ef:EnableMouse(true); ef:RegisterForDrag("LeftButton")
    ef:SetScript("OnDragStart", ef.StartMoving); ef:SetScript("OnDragStop", ef.StopMovingOrSizing)
    local sf2 = CreateFrame("ScrollFrame", nil, ef, "UIPanelScrollFrameTemplate")
    sf2:SetPoint("TOPLEFT", ef, "TOPLEFT", 8, -28); sf2:SetPoint("BOTTOMRIGHT", ef, "BOTTOMRIGHT", -28, 8)
    local eb2 = CreateFrame("EditBox", nil, sf2)
    eb2:SetMultiLine(true); eb2:SetFontObject("ChatFontNormal"); eb2:SetWidth(680)
    eb2:SetAutoFocus(true); eb2:SetScript("OnEscapePressed", function() ef:Hide() end)
    sf2:SetScrollChild(eb2)
    eb2:SetText("=== PT_DW_LOG ===\n" .. table.concat(rawLog, "\n") .. "\n=== END ===")
    eb2:HighlightText(); ef:Show()
end

local function BuildUI()
    if mainFrame then mainFrame:Show(); return end

    local W, H = 700, 560
    local f = CreateFrame("Frame", "ArcUI_PT_DWDebugFrame", UIParent, "BackdropTemplate")
    f:SetSize(W, H)
    f:SetPoint("CENTER")
    f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetFrameStrata("DIALOG")
    f:SetBackdrop({
        bgFile   = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile=true, tileSize=16, edgeSize=14,
        insets   = {left=4,right=4,top=4,bottom=4},
    })
    f:SetBackdropColor(0.06, 0.03, 0.01, 0.97)
    f:SetBackdropBorderColor(1.0, 0.4, 0.0, 0.9)
    mainFrame = f

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -10)
    title:SetText("|cffFF6600ProcTracker|r Doom Winds Debug")

    local sub = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sub:SetPoint("TOP", title, "BOTTOM", 0, -2)
    sub:SetText("|cff888888DW_CDM="..DW_CDM_ID.."  DW_buff="..DW_BUFF_ID.."  DW_cast="..DW_CAST_ID.."  /pt dwdebug to close|r")

    local legend = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    legend:SetPoint("TOP", sub, "BOTTOM", 0, -2)
    legend:SetText(
        "|cff00FFFF■|r MSW consume  "..
        "|cff44FFBB■|r MSW gain  "..
        "|cffFF6600■|r DW proc  "..
        "|cffFF4400■|r DW cast  "..
        "|cffFFAA44■|r CDM hook  "..
        "|cff88CCFF■|r rehook  "..
        "|cffFF88FF■|r invalidate  "..
        "|cffFF4444■|r violation"
    )

    local function Btn(lbl, px, fn)
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetSize(94, 22)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", px, -72)
        b:SetText(lbl)
        b:SetScript("OnClick", fn)
        return b
    end

    Btn("Clear", 10, function()
        log = {}; rawLog = {}; logDirty = true
        if logBox then logBox:SetText("") end
    end)

    local pb = Btn("Pause", 110, nil)
    pb:SetScript("OnClick", function(self)
        paused = not paused
        self:SetText(paused and "|cffFF4444Resume|r" or "Pause")
    end)

    Btn("Candidates", 510, function()
        HuntReport()
    end)

    Btn("Scan Frames", 210, function()
        ScanAndHookFrames()
        Sep("MANUAL SCAN")
        Push("DW_CDM frame", dwFrame and "found cooldownID="..DW_CDM_ID or "NOT FOUND", dwFrame and "dw_cdm" or "warn")
        if dwFrame then
            Push("DW_CDM instID", SafeVal(dwFrame.auraInstanceID)
                .."  auraSpellID="..SafeVal(dwFrame.auraSpellID)
                .."  hasAura="..tostring(DWFrameHasAura())
                .."  Cooldown="..tostring(dwFrame.Cooldown ~= nil), "dw_cdm")
        end
        local tracking = PT.DW and PT.DW.IsCDMTracking and PT.DW.IsCDMTracking()
        Push("IsCDMTracking", tostring(tracking), tracking and "dw_cdm" or "warn")
        local dw = C_UnitAuras.GetPlayerAuraBySpellID(DW_BUFF_ID)
        Push("DW buff live", dw and "instID="..SafeVal(dw.auraInstanceID) or "not active", dw and "dw_gain" or "info")
        local msw = C_UnitAuras.GetPlayerAuraBySpellID(MSW_ID)
        Push("MSW live", msw and "apps="..SafeVal(msw.applications) or "not active", msw and "msw_gain" or "info")
    end)

    Btn("Stats", 310, function()
        Sep("DW DECK STATE")
        local e = PT and PT.GetDeck and PT.GetDeck("dw")
        if not e then Push("deck", "not registered", "warn"); return end
        Push("DeckPos",    tostring(e.GetDeckPos and e.GetDeckPos()), "info")
        Push("Procs",      tostring(e.GetProcs and e.GetProcs()).."/3", "info")
        Push("Violations", tostring(e.GetViolations and e.GetViolations()), "info")
        Push("IsCDMTracking", tostring(PT.DW and PT.DW.IsCDMTracking and PT.DW.IsCDMTracking()), "info")
        Sep("MSW TOTALS (from PT.MSW)")
        local tot    = PT.MSW.GetTotalConsumed and PT.MSW.GetTotalConsumed() or 0
        local totStk = PT.MSW.GetTotalStacksAll and PT.MSW.GetTotalStacksAll() or 0
        local noAsc  = PT.MSW.GetTotalConsumedNoAsc and PT.MSW.GetTotalConsumedNoAsc() or 0
        local noAscS = PT.MSW.GetTotalStacksNoAsc and PT.MSW.GetTotalStacksNoAsc() or 0
        Push("All consumes",  "count="..tot.."  stacks="..totStk, "info")
        Push("Excl ASC",      "count="..noAsc.."  stacks="..noAscS, "info")
        Push("ASC consumes",  "count="..(tot-noAsc).."  stacks="..(totStk-noAscS), "info")
    end)

    Btn("Export", 410, DoExport)

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    local sf = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT",     f, "TOPLEFT",   8, -98)
    sf:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -26, 8)

    local eb = CreateFrame("EditBox", nil, sf)
    eb:SetSize(W - 40, 8000)
    eb:SetPoint("TOPLEFT")
    eb:SetMultiLine(true)
    eb:SetFontObject("GameFontHighlightSmall")
    eb:SetAutoFocus(false)
    eb:EnableMouse(true)
    eb:SetTextInsets(4, 4, 4, 4)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnMouseDown",     function(self) self:SetFocus() end)
    sf:SetScrollChild(eb)
    logBox = eb

    local flushFrame = CreateFrame("Frame")
    flushFrame:SetScript("OnUpdate", function()
        if not logDirty or not mainFrame or not mainFrame:IsShown() then return end
        logBox:SetText(table.concat(log, "\n"))
        logDirty = false
    end)

    f:Show()
end

-- ── Enable / Disable ──────────────────────────────────────────────────────────
local function Enable()
    enabled      = true
    sessionStart = GetTime()
    log = {}; rawLog = {}
    -- Reset the ground-truth window model
    dwPresent      = false   -- seeded by the first CheckDWPresence below
    windowIdx      = 0
    winStats       = nil
    pendingCounted = 0
    -- Reset the marker hunt; carrying tallies across toggles would pollute the diff
    huntIDs        = nil
    huntOpenUntil  = 0
    huntProcT      = 0
    huntProcWins   = 0
    huntNoProcWins = 0
    wipe(huntSeenProc)
    wipe(huntSeenNoProc)
    pushIdx        = 0
    pushTime       = {}
    endTime        = {}
    pushStats      = {}
    comparable     = {}
    chainBreak     = 0
    lastEndTime    = nil
    baseWindowLen  = nil
    windowAuraID   = nil
    pendingClose   = nil
    flapCount      = 0
    lastSource     = "?"
    dbgFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    dbgFrame:RegisterEvent("UNIT_AURA")
    dbgFrame:RegisterEvent("COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED")
    dbgFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
    sucRing = {}
    BuildUI()
    InstallSetCDIDHook()
    ScanAndHookFrames()
    if PT and PT.MSW and PT.MSW.Subscribe then
        PT.MSW.Subscribe("OnConsumed", OnMSWConsumedDbg)
    end
    WireDeckDebug()
    Sep("SESSION START")
    Push("INFO", "DW_CDM="..DW_CDM_ID.."  DW_buff="..DW_BUFF_ID.."  DW_cast="..DW_CAST_ID, "info")
    local msw = C_UnitAuras.GetPlayerAuraBySpellID(MSW_ID)
    Push("INIT MSW", msw and "instID="..SafeVal(msw.auraInstanceID).." apps="..SafeVal(msw.applications) or "not active", msw and "msw_gain" or "info")
    local dw = C_UnitAuras.GetPlayerAuraBySpellID(DW_BUFF_ID)
    Push("INIT DW buff", dw and "instID="..SafeVal(dw.auraInstanceID) or "not active", dw and "dw_gain" or "info")
    Push("HOW TO READ",
        "each window prints GROUND TRUTH (1 fresh + N end-time extensions) vs what PT COUNTED; "
        .."a MISCOUNT line means the deck is wrong", "info")
    Push("DW_CDM frame", dwFrame and "found" or "NOT FOUND — use Scan Frames after DW procs", dwFrame and "dw_cdm" or "warn")
    Push("IsCDMTracking", tostring(PT.DW and PT.DW.IsCDMTracking and PT.DW.IsCDMTracking()), "info")
end

local function Disable()
    enabled = false
    dbgFrame:UnregisterAllEvents()
    if PT and PT.MSW and PT.MSW.Unsubscribe then
        PT.MSW.Unsubscribe("OnConsumed", OnMSWConsumedDbg)
    end
    UnwireDeckDebug()
    if mainFrame then mainFrame:Hide() end
end

-- ── Public API (registered via PT slash in Core) ──────────────────────────────
ArcUI_PT_DWDebug = {
    Toggle    = function() if enabled then Disable() else Enable() end end,
    Export    = DoExport,
    IsEnabled = function() return enabled end,
}