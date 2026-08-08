-- ArcUI_PT_SBDebug.lua
-- Soulburst (Devourer MID2 2pc) timeline debugger + hazard analysis.
--
-- Purpose: settle two questions the deck module cannot answer on its own.
--
-- 1. IS IT ACTUALLY A RAMP, OR A DECK?
--    A deck's hazard function MUST reach 1.0 -- once the failures are drawn the
--    next success is guaranteed. The escalating-chance model caps at 39.49% and
--    never guarantees. So measure the empirical hazard
--        h(k) = procs landing on attempt k / streaks that reached k
--    and compare it to the model column:
--        climbs toward 100%  -> deck
--        flattens near 40%   -> escalating chance
--    SimC's three constants are commented "Fitted from PTR logs", not spell
--    data, and a 3-parameter fit is under-determined at the tail. This is the
--    part their fit could not see, so it is genuinely additive.
--
-- 2. IS THE 4-FRAGMENT GATE REAL AND ARE WE APPLYING IT RIGHT?
--    Harvests below the threshold neither roll nor advance the counter. Every
--    streak is therefore recorded twice, gated and raw. Whichever column tracks
--    the model better is the correct gate -- if raw fits, sub-4 harvests never
--    happen in practice; if gated fits, they do and the gate is load-bearing.
--    Counting the gate wrong flattens the measured curve, so a wrong gate is
--    visible in the data rather than silent.
--
-- Every line stamps the restriction context. "forced=00000 inst=none" is an
-- UNRESTRICTED read and proves nothing about M+ regardless of the combat flag:
-- combat is not the gate for aura secrecy, instance context is.
--
-- Toggle: /pt sbdebug          Export: /pt sbdebug export
-- No pcall. Zero polling. Zero CPU when disabled.

local MAX_LINES = 500
local MAX_K     = 16

local enabled  = false
local frame, editBox, statusText
local lines    = {}

-- MID2 Devourer set pieces (simc item_set_bonus_ptr.inc, set 1296615).
-- Informational only: difficulty variants may carry IDs this list lacks, so a
-- low count is never treated as "no tier".
local SET_ITEMS = {
    [271540] = true, [271538] = true, [271537] = true,
    [271536] = true, [271535] = true,
}
local SET_SLOTS = { 1, 3, 5, 7, 10 }   -- head, shoulder, chest, legs, hands

local RESTRICTION_CVARS = {
    "addonCombatRestrictionsForced", "addonChallengeModeRestrictionsForced",
    "addonEncounterRestrictionsForced", "addonMapRestrictionsForced",
    "addonPvPMatchRestrictionsForced",
}

-- ── helpers ──────────────────────────────────────────────────────────────────
local function ForcedString()
    local get = C_CVar and C_CVar.GetCVar
    if not get then return "?????" end
    local s = ""
    for i = 1, #RESTRICTION_CVARS do s = s .. (get(RESTRICTION_CVARS[i]) or "?") end
    return s
end

local function Context()
    local inInst, instType = IsInInstance()
    local diff = select(3, GetInstanceInfo())
    return string.format("forced=%s inst=%s%s combat=%s",
        ForcedString(),
        (inInst and instType) or "none",
        (inInst and diff and (":" .. tostring(diff))) or "",
        InCombatLockdown() and "1" or "0")
end

local function AllForced()
    local get = C_CVar and C_CVar.GetCVar
    if not get then return false end
    for i = 1, #RESTRICTION_CVARS do
        if get(RESTRICTION_CVARS[i]) ~= "1" then return false end
    end
    return true
end

-- Sets the five forced-restriction CVars, then READS THEM BACK. If a set does
-- not take (protected CVar, renamed key, whatever), the read-back is what tells
-- us -- we never claim success on the strength of having called SetCVar.
local function SetForced(on)
    local set, get = C_CVar and C_CVar.SetCVar, C_CVar and C_CVar.GetCVar
    if not (set and get) then return false, "C_CVar unavailable" end
    local want = on and "1" or "0"
    local failed = {}
    for i = 1, #RESTRICTION_CVARS do
        local name = RESTRICTION_CVARS[i]
        set(name, want)
        if get(name) ~= want then failed[#failed+1] = name end
    end
    if #failed > 0 then
        return false, table.concat(failed, ", ")
    end
    return true
end

local function SetPieceCount()
    local n = 0
    for i = 1, #SET_SLOTS do
        local id = GetInventoryItemID("player", SET_SLOTS[i])
        if id and SET_ITEMS[id] then n = n + 1 end
    end
    return n
end

local function Store()
    ArcUI_ProcTrackerDB = ArcUI_ProcTrackerDB or {}
    ArcUI_ProcTrackerDB.soulburst = ArcUI_ProcTrackerDB.soulburst or {}
    local s = ArcUI_ProcTrackerDB.soulburst
    s.streaks = s.streaks or {}
    return s
end

local Refresh   -- fwd

local function Log(text)
    lines[#lines + 1] = text
    while #lines > MAX_LINES do table.remove(lines, 1) end
    if Refresh then Refresh() end
end

-- ── hazard summary ───────────────────────────────────────────────────────────
local function BuildSummary()
    local st = Store().streaks
    local n = #st
    local out = {}
    out[#out+1] = string.format("== Soulburst: %d procs recorded ==", n)
    if n == 0 then
        out[#out+1] = "No procs banked yet. Harvest with the 2pc equipped."
        return table.concat(out, "\n")
    end

    local ChanceAt = PT.Soulburst and PT.Soulburst.ChanceAt

    local function render(label, field)
        local reached, ended, over = {}, {}, 0
        for i = 1, MAX_K do reached[i], ended[i] = 0, 0 end
        local sum, cnt = 0, 0
        for i = 1, n do
            local k = st[i][field]
            if type(k) == "number" and k >= 1 then
                sum, cnt = sum + k, cnt + 1
                if k > MAX_K then over = over + 1 end
                local top = (k < MAX_K) and k or MAX_K
                for j = 1, top do reached[j] = reached[j] + 1 end
                if k <= MAX_K then ended[k] = ended[k] + 1 end
            end
        end
        out[#out+1] = ""
        out[#out+1] = "-- " .. label .. " --"
        out[#out+1] = "  k   reached  procs   hazard    model"
        for k = 1, MAX_K do
            if reached[k] > 0 then
                out[#out+1] = string.format("  %-3d %-8d %-7d %6.1f%%   %5.1f%%",
                    k, reached[k], ended[k],
                    (ended[k] / reached[k]) * 100,
                    ChanceAt and (ChanceAt(k) * 100) or 0)
            end
        end
        if over > 0 then
            out[#out+1] = string.format("  (%d streak(s) ran past k=%d)", over, MAX_K)
        end
        if cnt > 0 then
            out[#out+1] = string.format("  mean = %.2f attempts/proc   (model 5.03, flat-20%% = 5.00)", sum / cnt)
        end
    end

    render("GATED (only harvests consuming >= 4 fragments)", "kq")
    render("RAW (every harvest counted)", "kr")

    out[#out+1] = ""
    out[#out+1] = "Hazard climbing toward 100% = deck. Flattening near 39-40% ="
    out[#out+1] = "escalating chance. The column tracking model better is the"
    out[#out+1] = "correct attempt gate."
    return table.concat(out, "\n")
end

-- ── GUI ──────────────────────────────────────────────────────────────────────
-- FORWARD DECLARATION -- required, not tidiness. ScanAuras is defined further
-- down but BuildFrame wires it to the Probe button and the ID box. Without the
-- local existing first, those references resolve to a nil GLOBAL: the button
-- silently gets SetScript("OnClick", nil) and does nothing at all when clicked.
local ScanAuras
local customID   -- set from the ID box in BuildFrame, read by ScanAuras below

-- ── SPELL_UPDATE_COOLDOWN ring buffer ────────────────────────────────────────
-- The method that cracked Doom Winds and Storm Unleashed: anchor on a signal you
-- already trust (here the 473662 glow), ring-buffer every SPELL_UPDATE_COOLDOWN
-- payload, and dump the window around that anchor. Whichever spellID shows up
-- every single time and never otherwise IS the signal -- then look it up on
-- wowhead and you have your ID.
--
-- Two anchors here, because there are two unknowns:
--   PROC     -> which spellID marks a Soulburst landing (cross-check the glow)
--   HARVEST  -> does anything fire ONLY when 4+ fragments were consumed? That
--               would be a non-secret substitute for the gate we cannot read.
--
-- Payload is (spellID, baseSpellID, category, startRecoveryCategory, itemID).
-- Logged raw and unfiltered: filtering first is how you miss the signal.
local RING_MAX = 300
local ring, ringN = {}, 0

-- Default display filter. The unfiltered dump was ~50 lines per harvest, almost
-- all of it Voidfall / Catastrophe / World Killer / Meteor Shower churn with
-- nothing to do with consuming souls, and it buried the handful of lines that
-- matter.
--
-- Toggleable, NOT hardcoded: the "IDs" button flips back to showing everything.
-- The whole reason we found the builder tick and Consume Soul in the first place
-- was reading an unfiltered dump, so the ability to go back and look at all of it
-- has to stay one click away rather than a code edit.
--
-- Either way everything is RECORDED -- the ring buffer is unfiltered and the
-- passive correlation always sees every ID. This is display only.
local showAllIDs = false
local SHOW_IDS = {
    [1223423] = "Consume Soul (fires once if ANY soul taken)",
    [1223628] = "Consume Soul",
    [1266301] = "Consume Soul",
    [1232310] = "Feast of Souls",
    [1225789] = "builder tick (1 per soul, merges)",
    [1226019] = "Reap",
    [1245453] = "Cull",
    [1225826] = "Eradicate",
    [473662]  = "Consume (proc glow)",
    [1297433] = "Soulburst",
    [1245577] = "Soul Fragments",
    [1245584] = "Soul Fragments",
    [1223412] = "Soul Fragment",
}

local function RingPush(...)
    ringN = ringN + 1
    local i = ((ringN - 1) % RING_MAX) + 1
    ring[i] = { t = GetTime(), n = select("#", ...), ... }
end

-- Returns the SET of spellIDs seen in the window, so two dumps can be diffed
-- rather than eyeballed.
-- Asymmetric window on purpose. Everything interesting happens AFTER the cast:
-- fragments are consumed in a trickle and a symmetric +/-0.7s was cutting the
-- tail off, which is how a 2-soul Reap showed only one tick. Look back just far
-- enough to catch the cast itself, then look forward a long way.
local function RingDump(center, pre, post, tag)
    local rows, ids = {}, {}
    for i = 1, RING_MAX do
        local e = ring[i]
        local dt = e and (e.t - center)
        if dt and dt >= -pre and dt <= post then rows[#rows+1] = e end
    end
    table.sort(rows, function(a, b) return a.t < b.t end)
    if #rows == 0 then
        Log(("         [%s] no SPELL_UPDATE_COOLDOWN in -%.2f..+%.2fs"):format(tag, pre, post))
        return ids
    end
    Log(("         [%s] SPELL_UPDATE_COOLDOWN in -%.2f..+%.2fs:"):format(tag, pre, post))
    local shown = 0
    for i = 1, #rows do
        local e = rows[i]
        local id = e[1]
        -- ids[] stays UNFILTERED: the passive correlation must keep seeing every
        -- ID or it stops being able to find a signal we have not thought of.
        if id ~= nil and not (issecretvalue and issecretvalue(id)) then ids[id] = true end
        if id and (showAllIDs or SHOW_IDS[id]) then
            shown = shown + 1
            local label = SHOW_IDS[id]
            if not label then
                label = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)) or "?"
            end
            Log(("           %+.3fs  %-9d %s"):format(e.t - center, id, label))
        end
    end
    if shown == 0 then
        Log(("           (nothing soul-related; %d other updates hidden -- press IDs for all)"):format(#rows))
    elseif not showAllIDs and shown < #rows then
        Log(("           (%d unrelated updates hidden -- press IDs for all)"):format(#rows - shown))
    end
    return ids
end

-- Count "consume clusters": distinct timestamps carrying a 1225789 builder tick.
-- Each cluster is one fragment consumed... up to a point. Measured on a
-- controlled 0/1/2/3/4-soul ladder the counts came out 0/1/2/3/3 -- exact until
-- four, where two consumes landed in the same frame and merged into one
-- timestamp. That makes 3 souls and 4 souls indistinguishable, which is exactly
-- the boundary the tier cares about, so this can NEVER be the gate.
--
-- Printed anyway because it is cheap and it keeps the question honest: if more
-- samples ever show 4 clusters for 4 souls, the merge is timing-dependent rather
-- than structural and it is worth revisiting.
local function CountClusters(center, pre, post)
    local seen, n = {}, 0
    for i = 1, RING_MAX do
        local e = ring[i]
        local dt = e and (e.t - center)
        -- Both carriers: 1227702 replaces 1225789 inside Void Metamorphosis, and
        -- counting only the first reported CLUSTERS 0 for every VM harvest while
        -- the deck's own tick count was correct.
        if dt and dt >= -pre and dt <= post and (e[1] == 1225789 or e[1] == 1227702) then
            if not seen[e.t] then seen[e.t] = true n = n + 1 end
        end
    end
    return n
end

-- ── Passive <4 vs 4+ correlation ─────────────────────────────────────────────
-- Hunting a spell update that fires ONLY when 4+ fragments were consumed. Such a
-- signal would beat the META delta outright: no window timing, no cap clipping,
-- no carrier swap.
--
-- PASSIVE, not tagged. We already know the exact consume count from metaDelta,
-- so every harvest sorts itself into a bucket while you play. That is strictly
-- better than pressing a button before each cast: no ceremony, no mis-tags, and
-- the sample grows to hundreds instead of one pair.
--
-- A real signal must appear in EVERY 4+ sample and in ZERO sub-4 samples. An ID
-- in most-but-not-all 4+ casts is reported separately, because "usually" is not
-- a gate -- it is a coincidence that has not been caught yet.
local function Corr()
    local s = Store()
    s.corr = s.corr or { hiN = 0, loN = 0, hi = {}, lo = {} }
    return s.corr
end

local function CorrRecord(metaDelta, ids)
    if metaDelta == nil then return end   -- unknown consume count proves nothing
    local c = Corr()
    local n, bucket
    if metaDelta >= 4 then
        c.hiN = c.hiN + 1; bucket = c.hi
    else
        c.loN = c.loN + 1; bucket = c.lo
    end
    for id in pairs(ids) do bucket[id] = (bucket[id] or 0) + 1 end
end

-- ── Tick accuracy tally ──────────────────────────────────────────────────────
-- Every NON-capped harvest is a free calibration sample: the META delta is the
-- exact soul count and the tick count is our estimate of it, so recording the
-- pairs measures the undercount without any manual testing.
--
-- This is what decides whether ticks can ever be trusted at the cap. If a d=4
-- harvest is ever seen at 1 or 2 ticks, the rule-out threshold is unsafe at that
-- value and has to come down.
local function TickRecord(metaDelta, ticks, atCap)
    if atCap or type(metaDelta) ~= "number" or type(ticks) ~= "number" then return end
    if metaDelta < 1 then return end
    local s = Store()
    s.tickCal = s.tickCal or {}
    local row = s.tickCal[metaDelta]
    if not row then row = { n = 0, min = ticks, max = ticks, sum = 0 } s.tickCal[metaDelta] = row end
    row.n   = row.n + 1
    row.sum = row.sum + ticks
    if ticks < row.min then row.min = ticks end
    if ticks > row.max then row.max = ticks end
end

-- Returns text rather than logging, so Export can embed it. TickReport() below
-- is the thin wrapper that puts it in the live log.
local function TickText()
    local cal = Store().tickCal
    local o = {}
    if not cal or not next(cal) then
        return "== TICK CALIBRATION == no samples yet (needs non-capped harvests)."
    end
    o[#o+1] = "== TICK CALIBRATION == souls (exact META delta) vs builder ticks"
    o[#o+1] = "   souls  n     ticks min/avg/max"
    local keys = {}
    for d in pairs(cal) do keys[#keys+1] = d end
    table.sort(keys)
    local unsafeAt
    for i = 1, #keys do
        local d, r = keys[i], cal[keys[i]]
        o[#o+1] = ("   %-6d %-5d %d / %.1f / %d"):format(d, r.n, r.min, r.sum / r.n, r.max)
        -- Ticks no longer gate anything, but keep flagging overlap: if a 4+ soul
        -- harvest can produce as few ticks as a 1-2 soul one, no threshold would
        -- ever have worked, and this is the evidence for that.
        if d >= 4 and r.min <= 2 then unsafeAt = math.min(unsafeAt or 99, r.min) end
    end
    o[#o+1] = ""
    if unsafeAt then
        o[#o+1] = ("   A 4+ soul harvest was seen at only %d tick(s) -- overlapping"):format(unsafeAt)
        o[#o+1] = "   the sub-4 range. This is why ticks do not gate anything."
    else
        o[#o+1] = "   No overlap yet between 4+ and sub-4 tick counts."
    end
    return table.concat(o, "\n")
end

local function TickReport() Log(TickText()) end

-- THE gate-accuracy readout. Answers "is our detection of a qualifying harvest
-- correct, and how often do we have to guess" as counts rather than impressions.
local function GateText()
    local g = Store().gate
    if not g or not g.total then
        return "== GATE DECISIONS == no harvests recorded yet."
    end
    local o = {}
    local function row(label, n)
        o[#o+1] = ("   %-34s %-5d %5.1f%%"):format(label, n or 0, ((n or 0) / g.total) * 100)
    end
    o[#o+1] = ("== GATE DECISIONS == %d harvests"):format(g.total)
    row("exact, qualified (d >= 4)",      g.exact_true)
    row("exact, rejected (d < 4)",        g.exact_false)
    row("rejected, no Consume Soul",      g.ruled_out_no_consume)
    row("UNKNOWN at cap (counted)",       g.unknown_at_cap)
    row("UNKNOWN unreadable (counted)",   g.unknown_unreadable)
    o[#o+1] = ""
    local confident = (g.exact_true or 0) + (g.exact_false or 0) + (g.ruled_out_no_consume or 0)
    o[#o+1] = ("   CONFIDENT: %d/%d (%.1f%%)"):format(confident, g.total, (confident / g.total) * 100)
    o[#o+1] = ("   LATE-DELTA events: %d   CONFIRMED MISCOUNTS: %d")
        :format(g.late or 0, g.miscount or 0)
    if (g.miscount or 0) > 0 then
        o[#o+1] = "   A harvest that really took 4+ was rejected. The resolve"
        o[#o+1] = "   window is too short -- raise RESOLVE_DELAY."
    else
        o[#o+1] = "   No rejected harvest was ever later shown to have taken 4+."
    end
    return table.concat(o, "\n")
end

local function GateReport() Log(GateText()) end

local function CorrText()
    local c = Corr()
    local o = {}
    o[#o+1] = ("== PASSIVE CORRELATION == %d sub-4 samples, %d 4+ samples"):format(c.loN, c.hiN)
    if c.hiN == 0 or c.loN == 0 then
        o[#o+1] = "   Need at least one of each. Keep playing."
        return table.concat(o, "\n")
    end

    local exclusive, partial = {}, {}
    for id, n in pairs(c.hi) do
        if not c.lo[id] then
            if n >= c.hiN then exclusive[#exclusive+1] = id
            else partial[#partial+1] = { id = id, n = n } end
        end
    end
    table.sort(exclusive)
    table.sort(partial, function(a, b) return a.n > b.n end)

    local function nm(id)
        return tostring((C_Spell and C_Spell.GetSpellName) and C_Spell.GetSpellName(id) or nil)
    end

    if #exclusive > 0 then
        o[#o+1] = ("   EXCLUSIVE to 4+ (all %d, never sub-4)  <- CANDIDATE GATE:"):format(c.hiN)
        for i = 1, #exclusive do o[#o+1] = ("      %-9d %s"):format(exclusive[i], nm(exclusive[i])) end
    else
        o[#o+1] = "   EXCLUSIVE to 4+: (none)"
    end
    if #partial > 0 then
        o[#o+1] = "   never sub-4 but not in every 4+ (NOT a gate, watch it):"
        for i = 1, math.min(#partial, 8) do
            o[#o+1] = ("      %-9d %-28s %d/%d"):format(partial[i].id, nm(partial[i].id), partial[i].n, c.hiN)
        end
    end
    o[#o+1] = "   Empty EXCLUSIVE across a large sample = no such signal exists,"
    o[#o+1] = "   and the META delta stays the only exact gate."
    return table.concat(o, "\n")
end

local function CorrReport() Log(CorrText()) end

local function BuildFrame()
    if frame then return end
    frame = CreateFrame("Frame", "ArcUI_PT_SBDebugFrame", UIParent, "BackdropTemplate")
    frame:SetSize(760, 460)
    frame:SetPoint("CENTER")
    frame:SetMovable(true); frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 24,
        insets = { left = 6, right = 6, top = 6, bottom = 6 },
    })
    frame:SetFrameStrata("DIALOG")

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -12)
    title:SetText("Soulburst Debugger")

    statusText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusText:SetPoint("TOPLEFT", 16, -38)

    local function Btn(text, w, after, x, y)
        local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        b:SetSize(w, 22)
        if after then b:SetPoint("LEFT", after, "RIGHT", x, 0)
        else b:SetPoint("TOPLEFT", 16, y) end
        b:SetText(text)
        return b
    end

    -- Row 1: reading the data
    local sumBtn   = Btn("Summary", 80, nil, nil, -56)
    local probeBtn = Btn("Probe", 65, sumBtn, 6)
    local expBtn   = Btn("Export", 70, probeBtn, 6)
    local clearBtn = Btn("Clear Log", 80, expBtn, 6)
    local wipeBtn  = Btn("Wipe Data", 85, clearBtn, 6)

    -- Row 2: setting up the test
    local forceBtn  = Btn("Restrict: ?", 110, nil, nil, -82)
    local reloadBtn = Btn("Reload UI", 80, forceBtn, 6)
    -- Correlation accumulates passively on every harvest; this only reads it out.
    local cmpBtn    = Btn("Correlate", 85, reloadBtn, 6)
    -- Souls-only vs every spell update in the window.
    local idsBtn    = Btn("IDs: ?", 95, cmpBtn, 6)
    frame._idsBtn   = idsBtn

    -- Type any spell ID off a tooltip and Probe includes it.
    local idLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    idLabel:SetPoint("LEFT", idsBtn, "RIGHT", 10, 0)
    idLabel:SetText("ID:")

    local idBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    idBox:SetSize(80, 20)
    idBox:SetPoint("LEFT", idLabel, "RIGHT", 8, 0)
    idBox:SetAutoFocus(false)
    idBox:SetNumeric(true)
    idBox:SetScript("OnEnterPressed", function(self)
        customID = tonumber(self:GetText())
        self:ClearFocus()
        ScanAuras()
    end)
    idBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    frame._forceBtn = forceBtn

    local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 16, -112)
    scroll:SetPoint("BOTTOMRIGHT", -34, 16)

    editBox = CreateFrame("EditBox", nil, scroll)
    editBox:SetMultiLine(true)
    editBox:SetFontObject("ChatFontNormal")
    editBox:SetWidth(700)
    editBox:SetAutoFocus(false)
    editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    scroll:SetScrollChild(editBox)

    Refresh = function()
        if not frame or not frame:IsShown() then return end
        -- Button labels mirror live state, so the window is the source of truth
        -- rather than something you have to remember the state of.
        if frame._forceBtn then
            frame._forceBtn:SetText(AllForced() and "Restrict: ON" or "Restrict: OFF")
        end
        if frame._idsBtn then
            frame._idsBtn:SetText(showAllIDs and "IDs: All" or "IDs: Souls")
        end
        editBox:SetText(table.concat(lines, "\n"))
        editBox:SetCursorPosition(editBox:GetNumLetters())
        local kg, kr = 0, 0
        if PT.Soulburst and PT.Soulburst.GetAttempts then kg, kr = PT.Soulburst.GetAttempts() end
        local frag, status = "?", "?"
        if PT.Soulburst and PT.Soulburst.GetFragments then
            local f, s = PT.Soulburst.GetFragments()
            frag, status = (f ~= nil) and tostring(f) or "?", s or "?"
        end
        local chance = (PT.Soulburst and PT.Soulburst.GetChance and PT.Soulburst.GetChance()) or 0
        statusText:SetText(string.format(
            "%s  |  frag=%s (%s)  |  k=%d/%d  next=%.1f%%  |  %d banked  |  set %d/5",
            Context(), frag, status, kg, kr, chance * 100, #Store().streaks, SetPieceCount()))
    end

    sumBtn:SetScript("OnClick", function() Log("\n" .. BuildSummary() .. "\n") end)
    -- Probe IS the aura scan now. The old one-line version reported
    -- "fragments=0 status=noaura" and said nothing about whether the field was
    -- secret, which is the single most important thing this window has to answer.
    -- Closure, not a bare reference: this defers the lookup to click time so the
    -- button cannot be wired to nil no matter how the file gets reordered later.
    probeBtn:SetScript("OnClick", function() ScanAuras() end)
    clearBtn:SetScript("OnClick", function() lines = {} Refresh() end)
    -- Wipes EVERYTHING collected, not just streaks. The hazard table, the
    -- correlation and the tick calibration are all only as good as the pipeline
    -- that fed them, and that pipeline has changed repeatedly (phantom aura
    -- procs, the early-drain that measured harvests before the consume landed,
    -- a rule-out threshold since lowered). Mixing samples from before and after
    -- those fixes produces a table that looks authoritative and is not.
    wipeBtn:SetScript("OnClick", function()
        local s = Store()
        s.streaks, s.corr, s.tickCal, s.gate = {}, nil, nil, nil
        Log("-- ALL collected data wiped: streaks, correlation, tick calibration --")
        Log("   Everything from here is from the current pipeline only.")
    end)
    expBtn:SetScript("OnClick", function() ArcUI_PT_SBDebug.Export() end)

    -- Forced restrictions: the combat-first gate. An open-world pass proves
    -- nothing about M+, so this is the button that makes a session meaningful.
    forceBtn:SetScript("OnClick", function()
        local turningOn = not AllForced()
        local ok, bad = SetForced(turningOn)
        if ok then
            Log(("-- forced restrictions %s (%s) --  RELOAD for them to take effect")
                :format(turningOn and "ON" or "OFF", ForcedString()))
        else
            Log("-- could not set: "..tostring(bad).." --")
            Log("   set them by hand instead:")
            for i = 1, #RESTRICTION_CVARS do
                Log(("   /console %s %d"):format(RESTRICTION_CVARS[i], turningOn and 1 or 0))
            end
        end
        Refresh()
    end)

    reloadBtn:SetScript("OnClick", function() ReloadUI() end)


    cmpBtn:SetScript("OnClick", function() GateReport() TickReport() CorrReport() end)

    idsBtn:SetScript("OnClick", function()
        showAllIDs = not showAllIDs
        Log("-- spell-update display: " .. (showAllIDs and "ALL IDs" or "soul-related only") .. " --")
        Refresh()
    end)
end

-- ── hookup ───────────────────────────────────────────────────────────────────
-- Registered only while the debugger is on, so it costs nothing when closed.
local ringFrame = CreateFrame("Frame")
ringFrame:SetScript("OnEvent", function(_, _, ...) RingPush(...) end)

local function Enable()
    ringFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
    PT.Soulburst.OnAttempt = function(name, before, after, delta, qualifies, kg, kr,
                                      beforeStatus, afterStatus,
                                      furyBefore, furyAfter, furyDelta, furyFrags,
                                      furyMax, furyStatus,
                                      metaBefore, metaAfter, metaDelta, metaMax,
                                      tickCount, metaStatus)
        -- Two different numbers, and conflating them reads like a bug:
        --   rolled = the chance THIS harvest just rolled at, ChanceAt(k)
        --   next   = the chance the NEXT one will roll at, ChanceAt(k+1)
        -- The icon shows "next" because that is the actionable one, which makes
        -- the first harvest after a proc look like it skipped a step -- it did
        -- not, 6.6% is simply the bottom rung. Only harvests that actually
        -- advanced the counter rolled at all.
        local rolled = (qualifies ~= false) and
            string.format("%.1f%%", PT.Soulburst.ChanceAt(kg) * 100) or "-"
        Log(string.format(
            "%.2f  HARVEST %-9s qualifies=%-7s k=%d/%d  rolled=%-6s next=%.1f%%   %s",
            GetTime(), name,
            (qualifies == nil) and "UNKNOWN" or tostring(qualifies),
            kg, kr, rolled, (PT.Soulburst.ChanceAt(kg + 1)) * 100, Context()))

        -- The Fury line is THE experiment: fragments collected * 4 = Fury gained.
        -- Compare "est frags" against the direct delta above while BOTH are
        -- readable (out of combat). If they agree, the proxy is trustworthy and
        -- the 4-fragment gate survives combat, where the aura does not. A capped
        -- Fury bar undercounts, which is why max is printed beside it.
        -- THE GATE. metaDelta is fragments consumed, read from the one aura that
        -- stays non-secret in combat. This line is what decides qualifies=.
        Log(string.format(
            "         META %s -> %s (d=%s / max %s)  ticks=%s  metaRead=%s   <- THE GATE",
            tostring(metaBefore), tostring(metaAfter),
            (metaDelta ~= nil) and tostring(metaDelta) or "?",
            tostring(metaMax), tostring(tickCount), tostring(metaStatus)))

        -- Calibrate only where the delta is exact, i.e. with headroom below the
        -- cap. A clipped delta is not ground truth and would poison the tally.
        local atCap = (type(metaBefore) == "number" and type(metaMax) == "number")
            and (metaBefore + 4 > metaMax)
        TickRecord(metaDelta, tickCount, atCap)

        -- Tally HOW the gate decided, so "how good is our detection" is a number
        -- rather than an impression from scrolling logs.
        local g = Store()
        g.gate = g.gate or {}
        g.gate.total = (g.gate.total or 0) + 1
        local bucket
        if metaDelta ~= nil and not atCap then
            bucket = (qualifies and "exact_true") or "exact_false"
        elseif qualifies == false then
            bucket = "ruled_out_no_consume"
        else
            bucket = atCap and "unknown_at_cap" or "unknown_unreadable"
        end
        g.gate[bucket] = (g.gate[bucket] or 0) + 1

        -- The direct fragment count and the Fury proxy are both dead in combat
        -- (ABSENT and SECRET respectively) and printing "nil -> nil" on every
        -- single harvest buried the one line that matters. Only show them when
        -- they actually carry a reading, i.e. out of combat, where they are
        -- still worth having as a cross-check on the gate.
        if beforeStatus == "ok" or afterStatus == "ok" then
            Log(string.format("         frag %s -> %s (d=%s)  fragRead=%s -> %s",
                tostring(before), tostring(after),
                (delta ~= nil) and tostring(delta) or "?",
                tostring(beforeStatus), tostring(afterStatus)))
        end
        if furyStatus == "ok" then
            Log(string.format("         FURY %s -> %s (d=%s)  est frags=%s  max=%s",
                tostring(furyBefore), tostring(furyAfter),
                (furyDelta ~= nil) and tostring(furyDelta) or "?",
                (furyFrags ~= nil) and tostring(furyFrags) or "?",
                tostring(furyMax)))
        end

        -- Anchor 2: is there a spell-update that fires ONLY on a qualifying
        -- harvest? That would replace the fragment count we cannot read.
        -- Consume the tag here so it applies to exactly one cast.
        -- Centre on the CAST, not on this callback. This fires RESOLVE_DELAY
        -- after the cast, so centring here printed the consume ticks as if they
        -- preceded the harvest and made the timing impossible to read.
        local castAt = GetTime() - (PT.Soulburst.RESOLVE_DELAY or 0)
        -- Fire LATE. Dumping at +0.35s could not contain events that had not
        -- happened yet, which is precisely what truncated the consume trickle
        -- and made a 2-soul Reap look like 1.
        C_Timer.After(1.6, function()
            local clusters = CountClusters(castAt, 0.3, 1.5)
            Log(("         CLUSTERS %d builder ticks  vs  META d=%s   %s"):format(
                clusters,
                (metaDelta ~= nil) and tostring(metaDelta) or "?",
                (metaDelta ~= nil and clusters == metaDelta) and "(agree)"
                    or "(DISAGREE -- clusters merged)"))

            local ids = RingDump(castAt, 0.3, 1.5,
                "HARVEST " .. tostring(name) .. " (t=0 is the cast)")

            -- Sorts itself by the consume count we already measured. No tagging,
            -- no ceremony: the sample builds while you play.
            CorrRecord(metaDelta, ids)
        end)
    end

    -- Every overlay glow, not just Soulburst's. If 473662 turns out to be the
    -- wrong ID, the right one is somewhere in this stream at the moment a proc
    -- lands, and we would never see it by filtering first.
    PT.Soulburst.OnGlow = function(spellID)
        local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
        Log(string.format("%.2f  GLOW  spellID=%s (%s)%s",
            GetTime(), tostring(spellID), tostring(name),
            (spellID == 473662) and "   <- Soulburst signal" or ""))
    end

    -- A second signal for a proc already credited. Not an error: it is how we
    -- learn which detector is faster and whether either ever misses.
    PT.Soulburst.OnProcDup = function(source, gap)
        Log(string.format("%.2f  (dup proc signal from %s, +%.0fms after the first -- not counted)",
            GetTime(), tostring(source), (gap or 0) * 1000))
    end

    -- The aura no longer credits procs (it produced phantoms when combat ended
    -- and the restricted buff became readable). Logged so a glow that ever MISSES
    -- a proc is still visible: a big gap here with no preceding glow would mean
    -- the glow is not sufficient after all.
    PT.Soulburst.OnAuraSeen = function(sinceLastProc)
        Log(string.format("%.2f  (aura saw Soulburst, %.1fs after last credited proc -- not counted)",
            GetTime(), sinceLastProc or -1))
    end

    -- Fires only when a later read shows the delta grew after we decided.
    PT.Soulburst.OnVerify = function(name, used, late, decided, wasMiscount)
        local s = Store()
        s.gate = s.gate or {}
        s.gate.late = (s.gate.late or 0) + 1
        if wasMiscount then s.gate.miscount = (s.gate.miscount or 0) + 1 end
        Log(string.format(
            "         %s LATE DELTA on %s: gated on d=%d, actual d=%d (decided %s)%s",
            wasMiscount and "***MISCOUNT***" or "(late)",
            tostring(name), used, late, tostring(decided),
            wasMiscount and "  <- a real 4+ harvest was rejected" or ""))
    end

    PT.Soulburst.OnProc = function(kg, kr, chance, source)
        local ctx = Context()
        Log(string.format(
            "%.2f  *** SOULBURST PROC ***  via %s  landed on attempt k=%d (raw %d), model said %.1f%%\n         %s",
            GetTime(), tostring(source), kg, kr, chance * 100, ctx))
        -- Bank the streak for the hazard table. Guard k>=1: a proc credited with
        -- zero attempts means the harvest never resolved, which would poison the
        -- curve rather than describe it.
        if kg >= 1 or kr >= 1 then
            local st = Store().streaks
            st[#st+1] = { kq = kg, kr = kr, ctx = ctx }
        end

        -- Anchor 1: the glow already told us this is a proc, so everything in
        -- this window is a candidate signal for the same event. Dumped AFTER a
        -- delay so updates arriving just after the proc are in the buffer too --
        -- the signal is as often behind the anchor as in front of it.
        local at = GetTime()
        C_Timer.After(0.9, function() RingDump(at, 0.75, 0.9, "PROC") end)
    end
end

local function Disable()
    ringFrame:UnregisterAllEvents()
    PT.Soulburst.OnAttempt = nil
    PT.Soulburst.OnProc    = nil
    PT.Soulburst.OnProcDup  = nil
    PT.Soulburst.OnGlow     = nil
    PT.Soulburst.OnAuraSeen = nil
    PT.Soulburst.OnVerify   = nil
end

-- ── Aura ID scan ─────────────────────────────────────────────────────────────
-- Which aura actually holds the fragment count is now an open question: 1225789
-- turned out to be the Void Meta builder, and 1245577 has not read cleanly yet.
--
-- Probing BY SPELL ID is the safe way to ask. GetPlayerAuraBySpellID does not
-- throw when auras are restricted (it returns a secret struct instead), unlike
-- the slot and instance-ID APIs which blanket-refuse. So walking a candidate
-- list is legal in exactly the contexts where enumeration is not.
--
-- Read the output as: present + a plain number = usable. present + <secret> =
-- the field exists but is blocked here. absent = not this one.
local SCAN_IDS = {
    { 1227619, "Shattered Souls (what CDM displays)" },
    { 74394,   "Shattered Souls CooldownID" },
    { 1245577, "Soul Fragments (from tooltip)" },
    { 1225789, "Void Metamorphosis builder (50 stacks)" },
    { 1226019, "Reap" },
    { 1297433, "Soulburst (proc buff)" },
    { 473662,  "Soulburst overlay-glow spell" },
}

-- (customID is forward-declared above BuildFrame -- it is ASSIGNED in the ID box
-- handler there and READ here, so declaring it at this point would have made
-- those two different variables and the box a no-op.)

-- One line per candidate, and it must distinguish the three states that all
-- looked identical before: absent (wrong ID or none held), present-but-secret
-- (exists, blocked in this context), and present with a readable count.
local function ProbeOne(id, label)
    local a = C_UnitAuras.GetPlayerAuraBySpellID(id)
    if a == nil then
        Log(("   %-8d ABSENT                                  %s"):format(id, label))
        return
    end
    if issecretvalue and issecretvalue(a) then
        Log(("   %-8d present  struct=<SECRET>  apps=<blocked> %s"):format(id, label))
        return
    end
    local apps = a.applications
    local shown, verdict
    if apps == nil then
        shown, verdict = "nil", "no applications field"
    elseif issecretvalue and issecretvalue(apps) then
        shown, verdict = "<SECRET>", "BLOCKED here"
    else
        shown, verdict = tostring(apps), "READABLE"
    end
    Log(("   %-8d present  apps=%-9s %-16s %s"):format(id, shown, verdict, label))
end

-- Soul fragments are WORLD OBJECTS, not a player aura ("Walking into the soul or
-- casting Reap will collect it"), which is why every aura probe reads ABSENT
-- while the count sits plainly on screen. CDM must be sourcing that number
-- somewhere else, and these are the channels available to it: cast count and
-- charges. Both are documented SecretWhenCooldownsRestricted, so if the count
-- lives there it is also the value most likely to go secret in a key -- which
-- makes finding it AND testing it under forced restrictions the whole ballgame.
local function fmtV(v)
    if v == nil then return "nil" end
    if issecretvalue and issecretvalue(v) then return "<SECRET>" end
    return tostring(v)
end

local function ProbeSpellAPIs(id, label)
    local bits = {}
    if C_Spell and C_Spell.GetSpellCastCount then
        bits[#bits+1] = "castCount=" .. fmtV(C_Spell.GetSpellCastCount(id))
    end
    if C_Spell and C_Spell.GetSpellCharges then
        local ch = C_Spell.GetSpellCharges(id)
        if ch then
            bits[#bits+1] = ("charges=%s/%s"):format(fmtV(ch.currentCharges), fmtV(ch.maxCharges))
        else
            bits[#bits+1] = "charges=nil"
        end
    end
    Log(("   %-8d %s   %s"):format(id, table.concat(bits, "  "), label))
end

-- Assigns the forward-declared local above. Must NOT be "local function" here or
-- it creates a second, different local and the button keeps pointing at nil.
function ScanAuras()
    Log(("%.2f  AURA PROBE   set=%d/5   %s"):format(GetTime(), SetPieceCount(), Context()))
    for i = 1, #SCAN_IDS do ProbeOne(SCAN_IDS[i][1], SCAN_IDS[i][2]) end
    if customID then ProbeOne(customID, "<- your ID") end
    Log("  -- SPELL APIs (fragments are world objects, so the count is not an aura) --")
    for i = 1, #SCAN_IDS do ProbeSpellAPIs(SCAN_IDS[i][1], SCAN_IDS[i][2]) end
    if customID then ProbeSpellAPIs(customID, "<- your ID") end
    Log("   Looking for whichever field equals the fragment count on your screen.")
    Log("   <SECRET> there = readable now but blocked in a key. ABSENT/nil = not it.")
end

-- ── public interface (matches SUDebug / DWDebug) ─────────────────────────────
ArcUI_PT_SBDebug = {}

function ArcUI_PT_SBDebug.IsEnabled() return enabled end

function ArcUI_PT_SBDebug.Toggle()
    if not PT.Soulburst then
        print("|cffFF4444ProcTracker:|r Soulburst deck not loaded (Demon Hunter Devourer only)")
        return
    end
    enabled = not enabled
    if enabled then
        BuildFrame()
        Enable()
        frame:Show()
        lines = {}
        Log("|cff00ccffSoulburst debugger ON|r  set "..SetPieceCount().."/5  |  /pt sbdebug to close")
        Log("   "..Context())
        Log("   NOTE: forced=00000 inst=none is an UNRESTRICTED read. It says nothing")
        Log("   about M+ no matter what combat= shows.")
        Refresh()
    else
        Disable()
        if frame then frame:Hide() end
        print("|cff00ccffProcTracker:|r Soulburst debugger off")
    end
end

-- Separate pre-selected window, matching SUDebug and DWDebug.
--
-- Selecting text inside the main window (what this used to do) fights the live
-- log: every new harvest rewrites the EditBox and drops the selection, so a busy
-- fight made it impossible to actually copy anything. A detached snapshot does
-- not move.
function ArcUI_PT_SBDebug.Export()
    if #lines == 0 then
        print("|cffFF4444ProcTracker:|r Soulburst log is empty.")
        return
    end

    local body = table.concat(lines, "\n")
        .. "\n\n" .. GateText()
        .. "\n\n" .. BuildSummary()
        .. "\n\n" .. CorrText()
        .. "\n\n" .. TickText()

    local ef = CreateFrame("Frame", nil, UIParent, "BasicFrameTemplateWithInset")
    ef:SetSize(760, 540); ef:SetPoint("CENTER"); ef:SetFrameStrata("FULLSCREEN_DIALOG")
    ef:SetMovable(true); ef:EnableMouse(true); ef:RegisterForDrag("LeftButton")
    ef:SetScript("OnDragStart", ef.StartMoving); ef:SetScript("OnDragStop", ef.StopMovingOrSizing)

    local sf = CreateFrame("ScrollFrame", nil, ef, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", ef, "TOPLEFT", 8, -28)
    sf:SetPoint("BOTTOMRIGHT", ef, "BOTTOMRIGHT", -28, 8)

    local eb = CreateFrame("EditBox", nil, sf)
    eb:SetMultiLine(true)
    eb:SetFontObject("ChatFontNormal")
    eb:SetWidth(700)
    eb:SetAutoFocus(true)
    eb:SetScript("OnEscapePressed", function() ef:Hide() end)
    sf:SetScrollChild(eb)

    eb:SetText("=== PT_SOULBURST_LOG ===\n" .. body .. "\n=== END ===")
    eb:HighlightText()
    ef:Show()
end
