local ADDON, PT = ...   -- private namespace, shared with Core (never the global PT)
-- ArcUI_PT_RestoDREDebug.lua
-- RESTORATION Deeply Rooted Elements research probe.
--
-- ANSWERED (2026-09-07, three shamans over three keys, 61 gaps): NEITHER.
-- It is an ESCALATING CHANCE, about +1.1% per Riptide, resetting on a proc.
-- That beats flat RNG by ~7e9 to 1 and the best deck shape by ~600 to 1.
-- This probe stays as the live cross-check against that model.
--
-- Distinct from ArcUI_PT_DREDeck / DREDebug, which track the ENHANCEMENT
-- version (DRE off Maelstrom Weapon spends, 2 procs per 333 stacks). Resto
-- procs off Riptide CASTS, so the draw counter is completely different.
--
-- WHAT DISCRIMINATES THE MODELS: not the average, which is ~7-9% under all of
-- them, but the GAP DISTRIBUTION. A deck of P procs in N cards cannot go dry for
-- more than 2*(N-P)+1 draws -- the last proc of one deck can sit as early as
-- position P, the first of the next as late as N-P+1. An escalating chance has
-- no hard ceiling but still crushes long droughts. Flat RNG has neither.
--     1 in 14  -> 27 draws      2 in 21  -> 39 draws
--     1 in 16  -> 31 draws      2 in 28  -> 53 draws
-- THE +1 MATTERS: using 2*(N-P) is what wrongly kept 1-in-14 alive and produced
-- the first, incorrect "it is a 1-in-14 deck" verdict.
--
-- PRIMAL TIDE CORE is the trap. "Every 4 casts of Riptide also applies Riptide
-- to another friendly target", and those extra Riptides CAN proc DRE, so they
-- are draws. But they are not CASTS, so counting UNIT_SPELLCAST_SUCCEEDED alone
-- undercounts draws by 25% and would wrongly rule out deck shapes. It is
-- DETERMINISTIC (every 4th), so the extras are computed rather than tracked --
-- no aura scanning on other players, and CLEU is protected in 12.x anyway.
-- Both counts are reported side by side so the pattern can be checked against
-- each.
--
-- Toggle: /pt restodre        Export: /pt restodre export
-- No pcall. Zero polling. Zero CPU when disabled.

local RIPTIDE_ID  = 61295     -- the cast that draws a card
local DRE_SPELL   = 378270    -- DRE; a CANDIDATE proc signal, not confirmed
-- ASCENDANCE IS SPEC-SPECIFIC. 114050 Elemental, 114051 Enhancement,
-- 114052 RESTORATION. The first cut of this probe watched 114051 and saw
-- nothing, because a Resto proc puts 114052 on cooldown. Proven empirically:
-- across 22 Riptide casts only the proc cast produced 114052 (and 294020);
-- every cast produces 61295, 53390, 207400, 395192 and 381931 as noise.
local ASC_SPELL   = 114052    -- Ascendance (Restoration) -- THE proc signal
local ASC_OTHER   = { [114050] = "Asc(Ele)", [114051] = "Asc(Enh)" }
-- 294020 is Restorative Mists, the Restoration Ascendance healing effect. It
-- fires on every proc -- a 43 cast run showed it on exactly the two proc casts
-- and nowhere else -- but it also fires on a HAND-PRESSED Ascendance, so it
-- confirms that Ascendance became active and can never identify a proc on its
-- own. Useful only as a redundant co-signal alongside 114052.
local NOISE_294020 = 294020
local PTC_SPELL    = 382045    -- Primal Tide Core
local PTC_NODE_ID  = 80976     -- confirmed from the talent tooltip
local PTC_ENTRY_ID = 101842
local PTC_EVERY    = 4         -- every 4th cast adds one extra Riptide

local enabled  = false
local log      = {}
local MAX_LOG  = 500
local mainFrame, logBox
local Refresh            -- forward declaration; defined with the window

-- counters
local casts, procs = 0, 0
local castsAtLastProc = 0
local gaps = {}               -- draws between consecutive procs
local maxGap = 0
-- Riptide cast events closer together than a GCD. Declared HERE with the other
-- counters, NOT down in the events section: Summary() is defined above that and
-- would read a nil global instead. luac accepts it and the upvalue checker only
-- inspects CALLS, so this class of mistake only shows up at runtime.
local subGCD = 0
-- Stray 114052 cooldown events landing OUTSIDE the proc window. The risk a fast
-- clicker raises: if Ascendance going on or off cooldown fires its own event,
-- one could coincidentally land within the 0.5s window of a cast and be counted
-- as a proc. Existing logs show no such blip at the 6s expiry -- a cast 1.3s
-- before an expiry logged no 114052 -- but that is two short runs, not proof.
-- Counted rather than guarded against: an invented guard could suppress real
-- procs, whereas a count says whether the problem exists at all.
local ascOutside = 0
-- BLOCKED DRAWS. Ascendance runs exactly 6.000s and no proc has ever been seen
-- landing during an active one, so a Riptide cast inside that window is not a
-- real draw: either it cannot proc or the proc is unlogged. Counting it deletes
-- short gaps and manufactures long ones -- exactly the pattern that separates
-- structure from flat RNG, i.e. it would fake the answer.
--
-- Measured rather than assumed: the probe knows when it saw a proc, so it knows
-- the window. Excluding these here means the CLICK CADENCE no longer matters. A
-- fast clicker fires the moment a charge is up (~5-6s) and would otherwise put
-- most post-proc casts inside the window.
local ASC_DURATION = 6.0
local ascUntil     = 0
local blockedDraws = 0
-- Draws that actually rolled. Tracked separately from `casts` because a blocked
-- cast is still a cast; it just is not a draw.
local liveDraws    = 0
-- Same reason: Summary() reads this and is defined above the events section.
local ascCasts = 0
local sessionStart = GetTime()
local lastProcAt = 0

-- Ask the TRAIT TREE, not the spellbook. IsSpellKnownOrOverridesKnown reported
-- false for a talent that was actually taken, which silently undercounted draws
-- by 25% and would have skewed every deck verdict.
local function HasPTC()
    local cfgID = C_ClassTalents and C_ClassTalents.GetActiveConfigID
                  and C_ClassTalents.GetActiveConfigID()
    if not cfgID then return false end
    local node = C_Traits and C_Traits.GetNodeInfo
                 and C_Traits.GetNodeInfo(cfgID, PTC_NODE_ID)
    if not node then return false end
    if node.activeEntry and node.activeEntry.entryID == PTC_ENTRY_ID then
        return (node.activeEntry.rank or 0) > 0
    end
    return false
end

-- There is deliberately NO DrawsFor() helper any more. `liveDraws` is the one
-- definition of a draw -- casts that actually rolled, PTC extras included,
-- Ascendance-blocked casts excluded. A second way to compute draws is how this
-- file ended up with two copies of the drought ceiling that disagreed.

local function Push(tag, detail)
    -- 3 decimals: at 0.1s the gap between a Riptide and its proc was unreadable
    log[#log + 1] = string.format("[%9.3f] %-14s %s", GetTime() - sessionStart, tag, detail or "")
    if #log > MAX_LOG then table.remove(log, 1) end
    if logBox and mainFrame and mainFrame:IsShown() then
        logBox:SetText(table.concat(log, "\n"))
    end
end

-- ── Candidate deck shapes ────────────────────────────────────────────────────
-- All ~7% per draw, so the AVERAGE cannot separate them. Two bounds can,
-- and both are hard facts about a deck rather than statistics:
--
--   DROUGHT CEILING   a P-in-N deck cannot go dry for more than 2*(N-P) draws.
--                     Worst case is all procs at the front of one deck and all
--                     at the back of the next.
--   DENSITY CEILING   it cannot produce more than 2*P procs in any N draws,
--                     the mirror case with the procs bunched at a boundary.
--
-- Exceed either and that shape is IMPOSSIBLE, no sample size argument needed.
-- Flat RNG has neither ceiling, so if everything dies, flat is what is left.
-- Shortlist: only shapes that survive the hard constraints against the pooled
-- logs. Killed there and not listed here: every 1-in-N up to 15 (drought), every
-- 2-in-N up to 22 and every 3-in-N up to 30 (starvation).
local CANDIDATES = {
    { p = 2,  n = 23  },   -- best surviving deck in the pooled fit
    { p = 1,  n = 16  },   -- smallest surviving 1-in-N
    { p = 2,  n = 26  },   -- rate-matched
    { p = 3,  n = 43  },
    { p = 7,  n = 100 },
}

-- THE ONE ceiling. It existed in two copies -- CandidateLines and Summary --
-- and fixing only one left the summary reporting rule-outs from the old
-- off-by-one against a hardcoded shape list that no longer matched CANDIDATES.
-- Every drought test goes through here.
local function DroughtCeiling(p, n)
    return 2 * (n - p) + 1
end

-- Most procs a P-in-N deck can fit into any N consecutive draws: one deck's
-- procs bunched at its end, the next deck's at its start.
local function DensityCeiling(p)
    return 2 * p
end

-- THE STARVATION FLOOR, the third hard constraint and the one the probe was
-- missing. Any 2*N consecutive draws must fully contain at least one complete
-- deck, so they must hold at least P procs. This is what catches a shape that
-- is too GENEROUS for the observed dry stretches, where the drought ceiling
-- only catches one that is too stingy.
--
-- It needs no knowledge of where the real deck starts, which is why it is
-- usable at all: our own deck boundary is arbitrary, so a tracker wrapping past
-- position N having delivered fewer than P procs proves nothing on its own.
local function StarvationFail(p, n, totalDraws, procDraws)
    local w = 2 * n
    if totalDraws < w then return false end          -- no complete window yet
    for start = 1, totalDraws - w + 1 do
        local stop, seen = start + w - 1, 0
        for _, d in ipairs(procDraws) do
            if d >= start and d <= stop then seen = seen + 1 end
        end
        if seen < p then return true, start, stop, seen end
    end
    return false
end

-- draw index of every proc, for the density test
local procDraws = {}

-- ── Overnight persistence ────────────────────────────────────────────────────
-- An unattended run has to survive a /reload or a disconnect, so the counters
-- live in SavedVariables as well as in locals. WoW only flushes SavedVariables
-- to disk on logout/reload/disconnect, so mirroring more often than that buys
-- nothing against a hard crash -- what matters is that the table is CURRENT
-- whenever the client exits cleanly. Mirrored on every proc (rare) and every
-- few casts, plus once on logout.
local SV_KEY = "restodreRun"

local function SaveRun()
    ArcUI_ProcTrackerDB = ArcUI_ProcTrackerDB or {}
    local g, d = {}, {}
    for i = 1, #gaps do g[i] = gaps[i] end
    for i = 1, #procDraws do d[i] = procDraws[i] end
    ArcUI_ProcTrackerDB[SV_KEY] = {
        casts = casts, procs = procs, castsAtLastProc = castsAtLastProc,
        maxGap = maxGap, gaps = g, procDraws = d,
        liveDraws = liveDraws, blockedDraws = blockedDraws,
        ptc = HasPTC(), stamp = time and time() or 0,
    }
end

-- Returns true if a run was restored, so the caller can say so rather than
-- silently continuing someone else's numbers.
local function LoadRun()
    local r = ArcUI_ProcTrackerDB and ArcUI_ProcTrackerDB[SV_KEY]
    if not r or not r.gaps then return false end
    casts           = r.casts or 0
    procs           = r.procs or 0
    castsAtLastProc = r.castsAtLastProc or 0
    maxGap          = r.maxGap or 0
    liveDraws       = r.liveDraws or 0
    blockedDraws    = r.blockedDraws or 0
    wipe(gaps); wipe(procDraws)
    for i = 1, #r.gaps do gaps[i] = r.gaps[i] end
    for i = 1, #(r.procDraws or {}) do procDraws[i] = r.procDraws[i] end
    return casts > 0
end

-- ── Hazard curve ─────────────────────────────────────────────────────────────
-- THE DIRECT MEASUREMENT, and the reason a long run is worth more than a longer
-- argument. For each attempt index i: of all the times we reached attempt i
-- without proccing, what fraction procced exactly there?
--   flat RNG      -> a horizontal line
--   escalating    -> a straight rising line, slope = the increment
--   a cap         -> rises then plateaus
-- No model fitting, no likelihood ratios: it either rises or it does not.
--
-- reached(i) counts the in-progress run too. A stretch that has reached attempt
-- i without proccing is real evidence about the hazard at i, and dropping it
-- would bias the estimate upward at exactly the large-i end that matters most.
local function HazardBands(width)
    width = width or 5
    local reached, procAt = {}, {}
    local top = 0
    local function note(g, procced)
        if g > top then top = g end
        for i = 1, g do reached[i] = (reached[i] or 0) + 1 end
        if procced then procAt[g] = (procAt[g] or 0) + 1 end
    end
    for _, g in ipairs(gaps) do note(g, true) end
    -- censored tail: draws since the last proc, still running
    local since = liveDraws - castsAtLastProc
    if procs > 0 and since > 0 then note(since, false) end

    local out = {}
    local lo = 1
    while lo <= top do
        local hi = lo + width - 1
        local atRisk, hits = 0, 0
        for i = lo, hi do
            atRisk = atRisk + (reached[i] or 0)
            hits   = hits + (procAt[i] or 0)
        end
        if atRisk > 0 then
            out[#out + 1] = { lo = lo, hi = hi, atRisk = atRisk, hits = hits,
                              rate = hits / atRisk * 100 }
        end
        lo = hi + 1
    end
    return out
end

-- Most procs seen in any window of `n` consecutive draws.
local function MaxInWindow(n)
    local best = 0
    for i = 1, #procDraws do
        local c = 0
        for j = i, #procDraws do
            if procDraws[j] - procDraws[i] < n then c = c + 1 else break end
        end
        if c > best then best = c end
    end
    return best
end

local function CandidateLines()
    local out = {}
    local draws = liveDraws
    for _, c in ipairs(CANDIDATES) do
        local droughtMax = DroughtCeiling(c.p, c.n)
        local densityMax = DensityCeiling(c.p)
        local seen = MaxInWindow(c.n)
        local why
        local starved, sFrom, sTo, sSeen =
            StarvationFail(c.p, c.n, draws, procDraws)
        if maxGap > droughtMax then
            why = string.format("DEAD  drought %d > %d", maxGap, droughtMax)
        elseif seen > densityMax then
            why = string.format("DEAD  %d procs in %d draws > %d", seen, c.n, densityMax)
        elseif starved then
            why = string.format("DEAD  only %d procs in draws %d-%d (needs %d)",
                sSeen, sFrom, sTo, c.p)
        else
            local expect = draws * c.p / c.n
            why = string.format("alive  expect %.1f procs by now, saw %d", expect, procs)
        end
        out[#out + 1] = string.format("  %2d in %3d (%.2f%%)  %s",
            c.p, c.n, c.p / c.n * 100, why)
    end
    -- Returns the LINES, not a joined block. Summary has to know how many lines
    -- it renders so the window can lay itself out around them; folding these
    -- into one string made the summary silently taller than its reserved space.
    return out
end

local function Summary()
    local draws = liveDraws
    local rateC = (casts > 0) and (procs / casts * 100) or 0
    local rateD = (draws > 0) and (procs / draws * 100) or 0
    local out = {}
    out[#out + 1] = string.format("casts=%d  draws=%d (PTC %s)  procs=%d  ascCastsByHand=%d",
        casts, draws, HasPTC() and "on" or "off", procs, ascCasts)
    out[#out + 1] = string.format(
        "blocked draws: %d  (cast inside an active Ascendance, excluded --"
        .. " this is why click speed does not matter)", blockedDraws)
    out[#out + 1] = string.format(
        "stray 114052 outside the window: %d  %s", ascOutside,
        (ascOutside > 0)
            and "<- CHECK THESE: if many, some may be landing inside the window"
                .. " and inflating the proc count"
            or  "<- none: no false-proc source, fast clicking is safe here")
    out[#out + 1] = string.format(
        "sub-GCD Riptide events: %d   %s", subGCD,
        (subGCD > 0)
            and "<- the PTC extra DOES fire a cast event; draws are countable directly"
            or  "<- none: the PTC extra fires NO cast event, so draws must be computed")
    out[#out + 1] = string.format("rate: %.2f%% per cast   %.2f%% per draw", rateC, rateD)
    out[#out + 1] = string.format("longest drought: %d draws", maxGap)
    -- Which shapes are already dead. Driven by CANDIDATES and the shared
    -- ceiling, so this can never disagree with the candidate table below it.
    local dead = {}
    for _, c in ipairs(CANDIDATES) do
        if maxGap > DroughtCeiling(c.p, c.n) then
            dead[#dead + 1] = string.format("%d/%d (drought)", c.p, c.n)
        elseif MaxInWindow(c.n) > DensityCeiling(c.p) then
            dead[#dead + 1] = string.format("%d/%d (density)", c.p, c.n)
        elseif StarvationFail(c.p, c.n, draws, procDraws) then
            dead[#dead + 1] = string.format("%d/%d (starved)", c.p, c.n)
        end
    end
    out[#out + 1] = (#dead > 0)
        and ("RULED OUT by drought: " .. table.concat(dead, ", "))
        or  "no deck shape ruled out yet"
    out[#out + 1] = "candidate decks:"
    for _, line in ipairs(CandidateLines()) do out[#out + 1] = line end
    if #gaps > 0 then
        local g = {}
        for i = math.max(1, #gaps - 25), #gaps do g[#g + 1] = tostring(gaps[i]) end
        out[#out + 1] = "recent gaps (draws): " .. table.concat(g, " ")
    end
    -- The measurement, not a fit. A flat line means flat RNG; a rising line
    -- means escalating chance and its slope IS the increment.
    if #gaps >= 5 then
        out[#out + 1] = "hazard curve (chance to proc at attempt N since last proc):"
        for _, b in ipairs(HazardBands(5)) do
            local bar = string.rep("#", math.min(30, math.floor(b.rate / 2 + 0.5)))
            out[#out + 1] = string.format("  %3d-%-3d  %5.1f%%  (%d/%d)  %s",
                b.lo, b.hi, b.rate, b.hits, b.atRisk, bar)
        end
    end
    -- Second return is the line count. The window reserves space from it rather
    -- than from a fixed offset, which is what let the summary overrun the log.
    return table.concat(out, "\n"), #out
end

-- ── Events ───────────────────────────────────────────────────────────────────
-- SIGNALS USED HERE: SPELL_UPDATE_COOLDOWN, cast success, and CDM frame hooks.
-- Deliberately NO aura reads. Every other deck in this addon avoids them for
-- the same reason, and a probe that finds a signal the shipped deck cannot use
-- is worse than useless.
--
-- The first cut filtered SPELL_UPDATE_COOLDOWN on arg1 being 378270 or 114051
-- and missed a real proc. A BULK cooldown broadcast carries NO spellID at all,
-- so that filter rejected exactly the event that may have been carrying it.
-- Now nothing is filtered: every cooldown payload inside a window after a
-- Riptide is logged in full, nils included, and the candidate IDs are logged
-- GLOBALLY too in case the proc signal lands outside the window.
--
-- Ascendance's CDM icon is hooked as a third candidate, the same way the Storm
-- Unleashed probe hooks its buff frame.
-- PROC WINDOW. Same idea as the Elemental Tempest deck, which counts a
-- SPELL_UPDATE_COOLDOWN as a proc only within 5ms of the spend. A window this
-- tight is self-guarding: the global cooldown makes it impossible for a manual
-- Ascendance to be cast within a few hundred ms of a Riptide, so a hit inside
-- the window cannot be a hand press and needs no cast tracking to prove it.
--
-- Not set to 5ms yet because the observed latency is unknown: the log prints at
-- 0.1s resolution and one proc showed Riptide 256.9 / cooldown 257.0, i.e.
-- anywhere from 1ms to 100ms. PROC_WINDOW starts generous and every hit logs
-- its true age in ms, so it can be tightened to the measured maximum.
-- WINDOW SIZE, learned the hard way. Most procs report age=0.0ms (same frame
-- as the cast), and 50ms was set from that. It then MISSED a real proc at
-- 99ms: the whole event batch had slipped, not just the proc -- the unrelated
-- 207400 arrived at 99ms on that cast too. A frame hitch delays everything.
--
-- The safe upper bound is the GCD FLOOR of 750ms: two player casts can never
-- be closer together than that, so any window under it physically cannot
-- contain a hand-pressed Ascendance. 500ms sits 5x above the worst observed
-- latency and still 250ms clear of the floor.
--
-- Erring small is the expensive direction: a missed proc silently lengthens a
-- drought and biases the deck research toward larger decks.
local PROC_WINDOW = 0.5
local LOG_WINDOW  = 2.0       -- seconds of cooldown traffic to keep logging

local CDM_VIEWERS = {
    "BuffIconCooldownViewer", "BuffBarCooldownViewer",
    "EssentialCooldownViewer", "UtilityCooldownViewer",
}

local evFrame     = CreateFrame("Frame")
local windowUntil   = 0
local windowCast    = 0
local lastRiptideAt = 0     -- when the last Riptide landed, for the tight window
local lastAscCastAt = 0     -- when Ascendance was last CAST BY HAND (logging only)

-- Ascendance is a real, castable 2 minute cooldown. Pressing it fires exactly
-- the same SPELL_UPDATE_COOLDOWN for 114052 that a DRE proc does, so the id
-- alone is NOT a proc signal -- it would count every manual press as a proc.
--
-- The discriminator: a manual Ascendance is a CAST and shows up in
-- UNIT_SPELLCAST_SUCCEEDED. A DRE proc activates it passively and never does.
-- So a cooldown event is only a proc when no Ascendance cast just happened AND
-- it lands inside a Riptide window, which is the only thing that can proc it.
local ASC_CAST_GRACE = 1.5

local function ShowVal(v)
    if v == nil then return "nil" end
    if issecretvalue and issecretvalue(v) then return "<secret>" end
    return tostring(v)
end

-- Called by whichever signal turns out to mark the proc. Nothing calls it
-- automatically yet: that is the question this probe exists to answer.
local function CountProc(source)
    local now = GetTime()
    -- A manual and a Primal Tide Core Riptide can proc in the SAME millisecond;
    -- that is one proc at double duration, not two.
    if now - lastProcAt < 0.1 then
        Push("PROC (dupe)", string.format("%s within %.3fs, not counted", source, now - lastProcAt))
        return
    end
    lastProcAt = now
    ascUntil = now + ASC_DURATION      -- draws until here are not real draws
    procs = procs + 1
    local gap = liveDraws - castsAtLastProc
    castsAtLastProc = liveDraws
    -- draw index of this proc, for the density ceiling test. Recorded for the
    -- FIRST proc too: unlike the gap, an absolute position is not censored.
    procDraws[#procDraws + 1] = liveDraws
    SaveRun()          -- a proc is the expensive thing to lose; persist at once
    -- THE FIRST GAP IS CENSORED, and must not be treated as a real one. The
    -- deck was already part-consumed when the probe started, so "22 draws to
    -- the first proc" is a LOWER BOUND on that gap, not its value. Counting it
    -- would drag the average down and could wrongly rule a deck shape in.
    -- Only gaps BETWEEN two observed procs are real measurements.
    if procs == 1 then
        Push("PROC", string.format("%s  proc #1  after %d draws (CENSORED: deck"
            .. " state unknown at start, not counted as a gap)", source, gap))
    else
        gaps[#gaps + 1] = gap
        if gap > maxGap then maxGap = gap end
        Push("PROC", string.format("%s  proc #%d  gap=%d draws  (longest %d)",
            source, procs, gap, maxGap))
    end
    if mainFrame and mainFrame:IsShown() then Refresh() end
end
-- exposed so a proc can be marked by hand while the signal is still unknown
ArcUI_PT_RestoDRE_MarkProc = function() CountProc("MANUAL /pt restodre proc") end

local function OnEvent(_, event, arg1, arg2, arg3, arg4, arg5)
    if not enabled then return end

    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        if arg1 ~= "player" then return end
        local id = arg3
        if issecretvalue and issecretvalue(id) then return end
        id = tonumber(id)
        -- a manual Ascendance: remember it so its cooldown event is not
        -- mistaken for a proc
        if id == ASC_SPELL then
            lastAscCastAt = GetTime()
            ascCasts = ascCasts + 1
            Push("ASC CAST", "Ascendance cast BY HAND -- its cooldown event is not a proc")
            return
        end
        if id ~= RIPTIDE_ID then
            -- EVERY OTHER CAST SUCCESS inside the window, logged with its id and
            -- name. Filtering to Riptide's own id would hide a Primal Tide Core
            -- extra that fires under a DIFFERENT spell id, which is exactly the
            -- thing being tested here.
            if GetTime() <= windowUntil and id then
                local nm = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)
                Push("  cast-in-window", string.format("id=%d %s  [after cast #%d]",
                    id, nm and ("(" .. nm .. ")") or "", windowCast))
            end
            return
        end
        local now = GetTime()
        -- IS THE PRIMAL TIDE CORE RIPTIDE A CAST? If the extra Riptide fired
        -- its own UNIT_SPELLCAST_SUCCEEDED we would see two cast events closer
        -- together than the GCD floor (750ms), which a hand press cannot do.
        -- Flag those instead of counting them as a draw, so the count stays
        -- honest either way and the answer shows up in the log.
        local since = (lastRiptideAt > 0) and (now - lastRiptideAt) or nil
        if since and since < 0.7 then
            subGCD = subGCD + 1
            Push("RIPTIDE *SUB-GCD*", string.format(
                "%.0fms after cast #%d -- too fast to be a hand press."
                .. " PTC extra firing a cast event? (not counted as a draw)",
                since * 1000, casts))
            lastRiptideAt = now
            windowUntil = now + LOG_WINDOW
            return
        end
        casts = casts + 1
        lastRiptideAt = now
        windowUntil = now + LOG_WINDOW
        windowCast  = casts
        -- Inside an active Ascendance? Then it is not a draw. Logged either way
        -- so the exclusion is visible rather than silent.
        if now < ascUntil then
            blockedDraws = blockedDraws + 1
            Push("RIPTIDE (blocked)", string.format(
                "cast #%d landed %.1fs into an active Ascendance -- NOT counted"
                .. " as a draw (a proc here would be invisible)",
                casts, ASC_DURATION - (ascUntil - now)))
            if casts % 10 == 0 then SaveRun() end
            return
        end
        liveDraws = liveDraws + 1
        if HasPTC() and casts % PTC_EVERY == 0 then
            liveDraws = liveDraws + 1     -- the Primal Tide Core extra
        end
        -- every 4th cast is when Primal Tide Core should add its extra Riptide
        -- Only meaningful when the talent is actually taken. Printing it with
        -- PTC untalented claimed an extra Riptide that does not exist, on a run
        -- deliberately made clean by dropping the talent.
        local due = (HasPTC() and casts % PTC_EVERY == 0)
            and "  <- PTC DUE (4th cast)" or ""
        Push("RIPTIDE", string.format("cast #%d  (draw #%d)%s",
            casts, liveDraws, due))
        if casts % 10 == 0 then SaveRun() end
        return
    end

    if event == "SPELL_UPDATE_COOLDOWN" then
        local raw = arg1
        local id  = (issecretvalue and issecretvalue(raw)) and nil or tonumber(raw)
        local inWindow = GetTime() <= windowUntil
        -- ALWAYS log the candidate ids, window or not: if the proc signal lands
        -- late it must not be silently dropped a second time.
        -- Resto Ascendance went on cooldown. A hit inside the tight window
        -- after a Riptide is a proc; the GCD means a hand press cannot land
        -- there, so no cast tracking is needed to tell them apart. Ages are
        -- logged in ms either way, so the window can be tuned from real data.
        if id == ASC_SPELL then
            if lastRiptideAt == 0 then
                Push("  CD asc (no riptide yet)",
                    "114052 before any Riptide this session -- NOT a proc")
                return
            end
            local age = (GetTime() - lastRiptideAt) * 1000
            if age <= PROC_WINDOW * 1000 then
                Push("  CD *ASCENDANCE*", string.format(
                    "114052 age=%.1fms after cast #%d -> PROC", age, windowCast))
                CountProc(string.format("Asc cooldown %.0fms after cast #%d", age, windowCast))
            else
                ascOutside = ascOutside + 1
                Push("  CD asc (outside)", string.format(
                    "114052 age=%.1fms (window %.0fms) -- NOT a proc, hand press or unrelated",
                    age, PROC_WINDOW * 1000))
            end
            return
        end
        local isCandidate = (id == DRE_SPELL or ASC_OTHER[id])
        if not inWindow and not isCandidate then return end
        -- Name the id. Reading a wall of bare numbers is how 1267089 sat in the
        -- log looking like a Primal Tide Core signal; named, it is Stormstream
        -- Totem and fires on totem casts, nothing to do with PTC. 294020 is
        -- Restorative Mists, the Resto Ascendance healing effect: it fires on
        -- every proc but on hand-pressed Ascendance too, so it confirms a proc
        -- and can never identify one on its own.
        local nm = id and C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)
        Push(isCandidate and "  CD *CANDIDATE*" or "  cd-in-window",
            string.format("a1=%s%s a2=%s a3=%s a4=%s a5=%s%s",
                ShowVal(arg1), nm and (" (" .. nm .. ")") or "",
                ShowVal(arg2), ShowVal(arg3),
                ShowVal(arg4), ShowVal(arg5),
                inWindow and ("  [after cast #" .. windowCast .. "]") or "  [outside window]"))
        return
    end
end

-- ── CDM hooks ────────────────────────────────────────────────────────────────
-- Third candidate signal: Ascendance's own Cooldown Manager icon. Same approach
-- the Storm Unleashed probe uses. Reads frame fields only, never CDM methods,
-- so it cannot hand Blizzard code our taint.
local function HookCDM()
    for _, name in ipairs(CDM_VIEWERS) do
        local v = _G[name]
        if v and v.itemFramePool then
            for f in v.itemFramePool:EnumerateActive() do
                local cd = f.cooldownID
                if cd and not f._arcPTRestoDbgHooked then
                    if f.OnCooldownDone or f.OnCooldownSet or f.RefreshData then
                        f._arcPTRestoDbgHooked = true
                        if f.OnCooldownSet then
                            hooksecurefunc(f, "OnCooldownSet", function(self)
                                if not enabled then return end
                                if GetTime() > windowUntil then return end
                                Push("  CDM.OnCooldownSet",
                                    "cooldownID=" .. ShowVal(self.cooldownID))
                            end)
                        end
                    end
                end
            end
        end
    end
end

-- ── Window ───────────────────────────────────────────────────────────────────
local function BuildWindow()
    if mainFrame then return mainFrame end
    local f = CreateFrame("Frame", "ArcUI_PT_RestoDREWin", UIParent, "BackdropTemplate")
    f:SetSize(720, 600)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8",
                    edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    f:SetBackdropColor(0.043, 0.059, 0.102, 1)
    f:SetBackdropBorderColor(0.165, 0.231, 0.341, 1)

    local title = f:CreateFontString(nil, "OVERLAY")
    title:SetFont(STANDARD_TEXT_FONT, 14, "")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText("|cff3fc9f2Resto DRE|r|cffd5e2f2 research|r")

    local stats = f:CreateFontString(nil, "OVERLAY")
    stats:SetFont(STANDARD_TEXT_FONT, 11, "")
    stats:SetPoint("TOPLEFT", 12, -32)
    stats:SetPoint("TOPRIGHT", -12, -32)
    stats:SetJustifyH("LEFT")
    stats:SetTextColor(0.95, 0.97, 1)
    f._stats = stats

    local close = CreateFrame("Button", nil, f)
    close:SetSize(24, 24); close:SetPoint("TOPRIGHT", -4, -6)
    local cx = close:CreateFontString(nil, "OVERLAY")
    cx:SetFont(STANDARD_TEXT_FONT, 14, ""); cx:SetPoint("CENTER"); cx:SetText("x")
    cx:SetTextColor(0.7, 0.78, 0.88)
    close:SetScript("OnClick", function() f:Hide() end)

    local scroll = CreateFrame("ScrollFrame", "ArcUI_PT_RestoDREScroll", f,
        "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -110)
    scroll:SetPoint("BOTTOMRIGHT", -30, 12)
    local eb = CreateFrame("EditBox", nil, scroll)
    eb:SetMultiLine(true); eb:SetAutoFocus(false)
    eb:SetFontObject(ChatFontNormal)
    eb:SetWidth(660)
    eb:SetScript("OnEscapePressed", function() eb:ClearFocus() end)
    scroll:SetScrollChild(eb)
    logBox = eb

    local hint = f:CreateFontString(nil, "OVERLAY")
    hint:SetFont(STANDARD_TEXT_FONT, 10, "")
    hint:SetTextColor(0.55, 0.65, 0.78)
    hint:SetText("Click the log and press Ctrl+A then Ctrl+C to copy.  /pt restodre export refreshes.")
    f._hint = hint
    f._scroll = scroll

    mainFrame = f
    return f
end

local STATS_TOP  = 32    -- where the summary starts
local STATS_LINE = 14    -- rendered height of one 11pt line

-- The summary grows a line per candidate deck and per gap history, so the log
-- below it cannot sit at a fixed offset: it has to start under wherever the
-- summary actually ended. Reserving from the line count instead of measuring
-- avoids depending on GetStringHeight being current in the same frame.
local function Relayout(nlines)
    local below = STATS_TOP + (nlines or 1) * STATS_LINE + 6
    mainFrame._hint:ClearAllPoints()
    mainFrame._hint:SetPoint("TOPLEFT", 12, -below)
    mainFrame._scroll:ClearAllPoints()
    mainFrame._scroll:SetPoint("TOPLEFT", 12, -(below + 16))
    mainFrame._scroll:SetPoint("BOTTOMRIGHT", -30, 12)
end

-- Everything an offline analyser needs, at the TOP of the copy box so Ctrl+A
-- Ctrl+C always captures it. The rolling text log keeps only the last 500 lines
-- -- about one percent of an overnight run -- so the gap sequence has to be
-- exported as data, not reconstructed from log lines.
local function RawBlock()
    local NL = string.char(10)
    local g, d = {}, {}
    for i = 1, #gaps do g[i] = tostring(gaps[i]) end
    for i = 1, #procDraws do d[i] = tostring(procDraws[i]) end
    return table.concat({
        "=== RAW (paste this) ===",
        string.format("casts=%d draws=%d blocked=%d procs=%d ptc=%s",
            casts, liveDraws, blockedDraws, procs, HasPTC() and "on" or "off"),
        "gaps=" .. table.concat(g, ","),
        "procDraws=" .. table.concat(d, ","),
        "=== end raw ===",
        "",
    }, NL)
end

function Refresh()
    if not mainFrame then return end
    local text, nlines = Summary()
    mainFrame._stats:SetText(text)
    Relayout(nlines)
    if logBox then logBox:SetText(RawBlock() .. table.concat(log, "\n")) end
end

-- ── Public ───────────────────────────────────────────────────────────────────
ArcUI_PT_RestoDREDebug = {
    Toggle = function()
        enabled = not enabled
        if enabled then
            sessionStart = GetTime()
            evFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
            evFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
            evFrame:SetScript("OnEvent", OnEvent)
            HookCDM()
            local resumed = LoadRun()
            Push("START", string.format("Riptide=%d  DRE=%d  Asc=%d  PTC=%s",
                RIPTIDE_ID, DRE_SPELL, ASC_SPELL, HasPTC() and "talented" or "no"))
            if resumed then
                Push("RESUMED", string.format(
                    "continuing a saved run: %d casts, %d procs, %d gaps."
                    .. "  /pt restodre reset to start fresh", casts, procs, #gaps))
            end
            BuildWindow():Show()
            Refresh()
            print("|cff33ff99ProcTracker:|r Resto DRE research ON")
        else
            evFrame:UnregisterAllEvents()
            evFrame:SetScript("OnEvent", nil)

            if mainFrame then mainFrame:Hide() end
            print("|cff33ff99ProcTracker:|r Resto DRE research OFF")
        end
    end,
    Export = function()
        BuildWindow():Show()
        Refresh()
    end,
    Reset = function()
        casts, procs, castsAtLastProc = 0, 0, 0
        gaps, maxGap, lastProcAt = {}, 0, 0
        lastAscCastAt, ascCasts, lastRiptideAt = 0, 0, 0
        subGCD, liveDraws, blockedDraws, ascUntil = 0, 0, 0, 0
        ascOutside = 0
        wipe(procDraws)
        wipe(log)
        sessionStart = GetTime()
        if ArcUI_ProcTrackerDB then ArcUI_ProcTrackerDB[SV_KEY] = nil end
        Push("RESET", "counters cleared (saved run discarded)")
        Refresh()
    end,
}
