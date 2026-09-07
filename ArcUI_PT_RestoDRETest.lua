local ADDON, PT = ...   -- private namespace, shared with Core (never the global PT)
-- ArcUI_PT_RestoDRETest.lua
-- RESEARCH trackers for Restoration Deeply Rooted Elements.
--
-- Registers TWO entries side by side so the leading hypothesis and its best
-- rival can be watched against each other live, with the addon's own icons,
-- position, proc counter and chance readout. One picker each, so either can be
-- pointed at any candidate model.
--
-- OFF BY DEFAULT and registered lazily: this is a research tool, and tabs for
-- models nobody has proven would only confuse people who just want their
-- tracker. Turn them on with /pt restodre testdeck.
--
-- IT IS NOT FLAT RNG, AND IT IS NOT A DECK. Fitted against three shamans
-- over three ~30 minute keys (713 Riptide casts, 813 live draws, 64 procs,
-- 61 gaps), with draws inside an active Ascendance excluded:
--
--     escalating +1.1% per Riptide   7.25e9 to 1 over flat RNG
--                                     597 to 1 over the best deck (2 in 21)
--
-- Flat RNG expects 9.2 gaps of 1-2 draws at this rate; the data has 1.
--
-- DECKS ARE RULED OUT OUTRIGHT, by definition rather than by statistics. A deck
-- puts EXACTLY P procs in every block of N cards. Testing all N alignments on
-- all three logs, NO shape between 5% and 12% can do it. Control: on flat RNG
-- data of the same size, no shape with N <= 45 ever passes (0 of 400), so the
-- test has full power there; only N near 100 passes, and it passes flat data
-- 13% of the time, which is weakness rather than evidence.
--
-- NO INTERNAL COOLDOWN. Once draws inside an active Ascendance are removed the
-- shortest gap is 1, i.e. two procs on consecutive live Riptides. An ICD would
-- forbid that, and would otherwise mimic this same "no short gaps" pattern.
--
-- NO DEAD WINDOW EITHER, and its absence supports the model. All 64 Ascendance
-- windows run exactly 6.000s with zero refreshes, so no proc ever landed during
-- one -- but that needs no suppression rule: the 37 Riptides cast inside a
-- window are attempt #1 (32) and #2 (5) since the proc, where an escalating
-- counter sits at 1.1% and 2.2%. BLP expects 0.46 procs there, flat expects
-- 2.79, so observing zero is 11.4x more likely under BLP.
-- It also means there are no double procs: a proc is always one 6s Ascendance.
--
-- PROC SIGNAL (settled empirically, see the research probe): a
-- SPELL_UPDATE_COOLDOWN for 114052 -- Ascendance (RESTORATION), NOT the
-- Enhancement 114051 -- landing within a window of a Riptide cast. The window
-- separates a proc from a hand-pressed Ascendance, and it works because the GCD
-- FLOOR is 750ms: two player casts can never be closer than that, so nothing
-- inside the window can be a hand press. Usually the proc lands in the same
-- frame (0.0ms), but a frame hitch can delay the whole event batch -- one was
-- measured at 99ms -- so the window is not tiny.
--
-- No pcall. Zero polling.

local RIPTIDE_ID  = 61295
local ASC_RESTO   = 114052
local PROC_WINDOW = 0.5

-- Candidate models, best fit first. BLP entries escalate by `base` per failed
-- Riptide and reset on a proc, so they are guaranteed by attempt 1/base -- that
-- ceiling is what the position readout counts against. Deck entries are the
-- classic P-in-N shuffle and are here as the rival family.
local SHAPES = {
    { kind = "blp",  base = 0.011, short = "Escalating +1.1%",
      label = "Escalating +1.1% per Riptide  (best fit)" },
    { kind = "blp",  base = 0.010, short = "Escalating +1.0%",
      label = "Escalating +1.0% per Riptide" },
    { kind = "blp",  base = 0.012, short = "Escalating +1.2%",
      label = "Escalating +1.2% per Riptide" },
    -- EVERY testable deck shape is ruled out. A deck delivers EXACTLY P procs in
    -- every block of N cards, and no shape from 5% to 12% can partition the
    -- pooled logs that way under ANY alignment. Only decks near N=100 survive,
    -- and a control shows those pass on pure flat RNG 13% of the time -- too
    -- few complete blocks to judge, not evidence. They are kept selectable so
    -- the failure can be watched live, but labelled for what they are.
    { kind = "deck", n = 23, p = 2, short = "Deck 2 in 23",
      label = "Deck 2 in 23  (8.70%)  RULED OUT" },
    { kind = "deck", n = 16, p = 1, short = "Deck 1 in 16",
      label = "Deck 1 in 16  (6.25%)  RULED OUT" },
    { kind = "deck", n = 26, p = 2, short = "Deck 2 in 26",
      label = "Deck 2 in 26  (7.69%)  RULED OUT" },
}

-- Bump whenever SHAPES is reordered or its meaning changes. A stored testShape
-- is only an INDEX, so reordering silently repoints a saved selection at a
-- different model: the deck-only list defaulted to 5, which is now a deck entry
-- in a BLP-led list, so trackers came back on the wrong model with nothing on
-- screen saying so. A version stamp discards selections made against an older
-- list instead of honouring a number that no longer means what it did.
local SHAPES_VERSION = 4

-- The two trackers. Same event stream, independent state and settings, so they
-- can be compared draw for draw instead of one at a time.
-- B no longer defaults to a deck: every deck shape is ruled out, so pitting
-- one against A would be comparing the answer to a known-wrong model. The live
-- question is the INCREMENT, so B runs the other end of the fitted range.
local TRACKERS = {
    { id = "restodretest",  name = "DRE Test A", default = 1 },   -- +1.1%
    { id = "restodretest2", name = "DRE Test B", default = 3 },   -- +1.2%
}

-- The two icons are visually identical -- same spell icon, same position and
-- proc readout -- so the running model has to be in the name or there is no way
-- to tell which is which, or to notice one sitting on the wrong model.
local function TrackerName(t, s)
    return string.format("%s (%s)", t.name, s.short or "?")
end

PT.RestoDRETest = PT.RestoDRETest or {}
local RT = PT.RestoDRETest

local registered    = false
local lastRiptideAt = 0
local state         = {}    -- per tracker id

for _, t in ipairs(TRACKERS) do
    state[t.id] = { totalDraws = 0, sinceProc = 0, deckProcs = 0, deckNumber = 1 }
end

local function Shape(id, fallback)
    local db = PT.GetIconDB and PT.GetIconDB(id)
    if db and db.testShape and db.testShapeVer ~= SHAPES_VERSION then
        db.testShape = nil          -- stale index against an older SHAPES list
        db.testShapeVer = SHAPES_VERSION
    end
    local i = (db and db.testShape) or fallback
    return SHAPES[i] or SHAPES[fallback], i
end

-- A BLP model's analogue of deck size: the attempt at which the escalating
-- chance reaches 100%, so the position readout still means "how far through".
local function ShapeSize(s)
    if s.kind == "blp" then return math.floor(1 / s.base) end
    return s.n
end

local function Reset(id, fallback)
    local st = state[id]
    st.totalDraws, st.sinceProc, st.deckProcs, st.deckNumber = 0, 0, 0, 1
    PT.UpdateDeck(id)
end

local function Advance(id, fallback, n)
    local s, st = Shape(id, fallback), state[id]
    local before = st.totalDraws
    st.totalDraws = st.totalDraws + n
    st.sinceProc  = st.sinceProc + n
    if s.kind == "deck" then
        if math.floor(st.totalDraws / s.n) > math.floor(before / s.n) then
            st.deckNumber = math.floor(st.totalDraws / s.n) + 1
            st.deckProcs  = 0        -- new deck, procs reset
        end
    end
end

-- ── Events ───────────────────────────────────────────────────────────────────
local evFrame = CreateFrame("Frame")

local function OnEvent(_, event, arg1, arg2, arg3)
    if not registered then return end

    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        if arg1 ~= "player" then return end
        local id = arg3
        if issecretvalue and issecretvalue(id) then return end
        if tonumber(id) ~= RIPTIDE_ID then return end
        lastRiptideAt = GetTime()
        for _, t in ipairs(TRACKERS) do
            Advance(t.id, t.default, 1)
            PT.UpdateDeck(t.id)
        end
        return
    end

    if event == "SPELL_UPDATE_COOLDOWN" then
        local id = arg1
        if issecretvalue and issecretvalue(id) then return end
        if tonumber(id) ~= ASC_RESTO then return end
        -- tight window only: outside it this is a hand-pressed Ascendance
        if lastRiptideAt == 0 then return end
        if (GetTime() - lastRiptideAt) > PROC_WINDOW then return end
        for _, t in ipairs(TRACKERS) do
            local st = state[t.id]
            st.deckProcs = st.deckProcs + 1
            st.sinceProc = 0          -- escalating chance resets on a proc
            PT.UpdateDeck(t.id)
        end
        return
    end
end

-- ── Registration (lazy, opt-in) ──────────────────────────────────────────────
function RT.IsOn() return registered end

function RT.Enable()
    if registered then return end
    registered = true
    evFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    evFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
    evFrame:SetScript("OnEvent", OnEvent)

    for _, t in ipairs(TRACKERS) do
        local id, fallback = t.id, t.default
        local s = Shape(id, fallback)
        PT.RegisterDeck({
            id          = id,
            name        = TrackerName(t, s),
            deckSize    = ShapeSize(s),
            procs       = (s.kind == "blp") and 1 or s.p,
            defaultIcon = 960689,          -- DRE icon
            noCDMWarn   = true,            -- research entry, nothing to cross-check
            GetDeckPos = function()
                local sh, st = Shape(id, fallback), state[id]
                if sh.kind == "blp" then return st.sinceProc end
                return st.totalDraws % sh.n
            end,
            GetProcs = function()
                local sh, st = Shape(id, fallback), state[id]
                if sh.kind == "blp" then return 0 end   -- no deck, nothing spent
                return st.deckProcs
            end,
            GetChanceValue = function()
                local sh, st = Shape(id, fallback), state[id]
                if sh.kind == "blp" then
                    local c = sh.base * (st.sinceProc + 1) * 100
                    return (c > 100) and 100 or c
                end
                -- same hypergeometric math every other deck uses; it is in Core
                return PT.DeckChance(sh.n, sh.p, st.totalDraws % sh.n, st.deckProcs, 1)
            end,
            GetChanceText = function()
                local sh, st = Shape(id, fallback), state[id]
                local v
                if sh.kind == "blp" then
                    v = sh.base * (st.sinceProc + 1) * 100
                    if v > 100 then v = 100 end
                else
                    v = PT.DeckChance(sh.n, sh.p, st.totalDraws % sh.n, st.deckProcs, 1)
                end
                local db = PT.GetIconDB and PT.GetIconDB(id)
                return PT.FormatChance(v, db and db.chanceDecimals)
            end,
            -- BLP models have NO deck, so a card index against a fabricated
            -- deck size is a number that means nothing -- the useful readout is
            -- the CHANCE. Same convention the Soulburst tracker already uses:
            -- main text = chance, sub text = attempts since the last proc.
            -- Returning nil for deck shapes leaves them on the card index.
            GetDeckText = function()
                local sh, st = Shape(id, fallback), state[id]
                if sh.kind ~= "blp" then return nil end
                local c = sh.base * (st.sinceProc + 1) * 100
                if c > 100 then c = 100 end
                return string.format("%.0f%%", c)
            end,
            GetProcText = function()
                local sh, st = Shape(id, fallback), state[id]
                if sh.kind ~= "blp" then return nil end
                return tostring(st.sinceProc)
            end,
            OnReset = function() Reset(id, fallback) end,
            ns      = RT,
            -- model picker instead of a spend slider: these entries draw one
            -- card per Riptide, so there is no spend size to set
            testShapePicker = true,
            testShapeDefault = fallback,
            SHAPES = SHAPES,
        })
    end
    print("|cff33ff99ProcTracker:|r Resto DRE TEST trackers on (research, 2 entries)")
end

-- Applied when a model setting changes: the entry's own size/procs have to
-- follow, because Core reads them straight off the entry for every readout.
-- Takes an id so one picker never resets the other tracker's run.
function RT.ApplyShape(which)
    for _, t in ipairs(TRACKERS) do
        if not which or which == t.id then
            local entry = PT.GetDeck and PT.GetDeck(t.id)
            if entry then
                local s = Shape(t.id, t.default)
                entry.name     = TrackerName(t, s)
                entry.deckSize = ShapeSize(s)
                entry.procs    = (s.kind == "blp") and 1 or s.p
                local st = state[t.id]
                st.totalDraws, st.sinceProc, st.deckProcs, st.deckNumber = 0, 0, 0, 1
                PT.UpdateDeck(t.id)
            end
        end
    end
end

RT.Shapes = SHAPES
RT.Trackers = TRACKERS
