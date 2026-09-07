local ADDON, PT = ...   -- private namespace, shared with Core (never the global PT)
-- ArcUI_PT_RestoDRE.lua
-- Deeply Rooted Elements tracker for RESTORATION shaman.
--
-- NOT A DECK. Same family as Soulburst (the DH tier set): an escalating chance
-- that resets on a proc, so the useful readout is the CHANCE, not a card index.
--
--     chance that your Nth Riptide since the last proc procs = 1% x N
--     guaranteed by the 100th
--
-- MEASURED, not guessed. Fitted on a controlled 8.8 hour run -- 6875 Riptides,
-- 547 procs -- then verified against five independent community logs from a
-- different player, on different content, with Primal Tide Core talented:
--
--     rate            7.57%  (model ~8%)                     PASS
--     longest drought 34 draws (model guarantees by 100)      PASS
--     hazard shape    escalating beats flat 9.3e10 to 1       PASS
--
-- The clinching measurement needs no statistics. Riptides cast while Ascendance
-- is already up are all attempt #1, the coldest point of the counter, so they
-- read h(1) directly: 3 procs in 550 such draws = 0.55%. Flat RNG at the
-- observed 7.96% would have produced 44. P(3 or fewer | flat) = 3e-16.
--
-- KNOWN LIMITATION: a proc landing on the very next Riptide merges into ONE
-- 12s Ascendance rather than two 6s ones, and the cooldown signal cannot see
-- the second. That is h(1) = 1%, so it costs about 0.5% of procs (3 of 547 in
-- the reference run). Undercounting slightly is the honest failure direction:
-- the counter reads a little high, never low.
--
-- DETECTION: SPELL_UPDATE_COOLDOWN for 114052 -- Ascendance (RESTORATION), NOT
-- the Enhancement 114051 -- within 500ms of a Riptide cast. The window is what
-- separates a proc from a hand press, and it works because the GCD floor is
-- 750ms: two player casts can never be closer than that. Zero aura reads, so
-- nothing here breaks under 12.x secrecy.
--
-- PRIMAL TIDE CORE IS COUNTED, NOT OBSERVED. Its extra Riptide is a real DRE
-- draw but fires no cast event -- its only trace is an aura gain, which addons
-- cannot read under 12.x secrecy. So every 4th cast advances the counter by TWO.
-- Without that the displayed chance sits ~19% below the game's true attempt
-- number for anyone with the talent. The 4th-cast phase is assumed from when
-- tracking started, so it can be out of step with the game's own counter until
-- the next proc resets both.
--
-- No pcall. Zero polling. Zero CPU when the spec is wrong.

local RIPTIDE_ID  = 61295
local ASC_RESTO   = 114052    -- Ascendance (Restoration)
local DRE_SPELL   = 378270    -- Deeply Rooted Elements
-- Trait node, read off the talent tooltip. This is the AUTHORITATIVE check.
-- IsPlayerSpell / IsSpellKnownOrOverridesKnown have both reported false for a
-- talent that was actually taken (Primal Tide Core did exactly that), and a
-- false negative here hides the icon from someone who has the talent.
local DRE_NODE_ID  = 81051
local DRE_ENTRY_ID = 101937
local RESTO_SPEC  = 264
-- Primal Tide Core: every 4th Riptide applies a SECOND Riptide to another ally,
-- and each application rolls DRE independently. That extra draw fires NO cast
-- event -- its only trace is the aura gain, which addons cannot read under 12.x
-- secrecy -- so it has to be COUNTED deterministically or the tracker drifts
-- ~19% behind the game's real attempt number. Confirmed by log: application to
-- cast ratio is 1.192 with PTC, exactly 1.000 without.
local PTC_NODE_ID  = 80976
local PTC_ENTRY_ID = 101842
local PTC_EVERY    = 4
local PROC_WINDOW = 0.5       -- see header: GCD floor makes this unambiguous
local BASE_CHANCE = 0.01      -- +1% per Riptide since the last proc
local CAP_AT      = 100       -- 1 / BASE_CHANCE: guaranteed by here
local DRE_ICON    = 960689

PT.RestoDRE = PT.RestoDRE or {}
local RD = PT.RestoDRE

local registered    = false
local sinceProc     = 0       -- Riptides since the last proc: the counter
local totalProcs    = 0
local lastRiptideAt = 0
local ascUntil      = 0       -- Ascendance active until here
local sawAProc      = false   -- positive proof the talent is taken
local castCount     = 0       -- Riptide CASTS, for the PTC every-4th cadence

-- ── Talent / spec gate ───────────────────────────────────────────────────────
-- IsPlayerSpell is the cheap check, but it has lied about a taken talent before
-- (Primal Tide Core reported false through IsSpellKnownOrOverridesKnown), so a
-- proc we actually observed also counts as proof. Wrong in the safe direction:
-- the tracker can appear late, never wrongly for someone without the talent.
local function HasDRE()
    -- 1. The trait tree: authoritative, and correct the instant a talent is
    --    swapped rather than waiting for a spellbook refresh.
    local cfg = C_ClassTalents and C_ClassTalents.GetActiveConfigID
                and C_ClassTalents.GetActiveConfigID()
    if cfg and C_Traits and C_Traits.GetNodeInfo then
        local node = C_Traits.GetNodeInfo(cfg, DRE_NODE_ID)
        if node and node.activeEntry then
            return node.activeEntry.entryID == DRE_ENTRY_ID
                   and (node.activeEntry.rank or 0) > 0
        end
        -- node present but nothing selected: definitively NOT talented
        if node then return false end
    end
    -- 2. Fallbacks, only if the trait API gave us nothing at all (early login).
    if sawAProc then return true end
    if IsPlayerSpell then return IsPlayerSpell(DRE_SPELL) and true or false end
    return false
end

-- Ask the TRAIT TREE, not the spellbook: IsSpellKnownOrOverridesKnown reported
-- false for this exact talent when it was actually taken, which would silently
-- undercount every draw.
local function HasPTC()
    local cfg = C_ClassTalents and C_ClassTalents.GetActiveConfigID
                and C_ClassTalents.GetActiveConfigID()
    if not cfg then return false end
    local node = C_Traits and C_Traits.GetNodeInfo
                 and C_Traits.GetNodeInfo(cfg, PTC_NODE_ID)
    if not node or not node.activeEntry then return false end
    if node.activeEntry.entryID ~= PTC_ENTRY_ID then return false end
    return (node.activeEntry.rank or 0) > 0
end

-- Draws contributed by the NEXT cast: 2 on a Primal Tide Core cast, else 1.
local function DrawsForNextCast()
    if HasPTC() and ((castCount + 1) % PTC_EVERY == 0) then return 2 end
    return 1
end

local function IsResto()
    local spec = GetSpecialization and GetSpecialization()
    if not spec then return false end
    local id = GetSpecializationInfo and GetSpecializationInfo(spec)
    return id == RESTO_SPEC
end

local function Eligible() return IsResto() and HasDRE() end

-- ── Readouts ─────────────────────────────────────────────────────────────────
local function ChanceAt(n)
    local c = BASE_CHANCE * n
    return (c > 1) and 1 or c
end

-- Chance of the NEXT DRAW, and deliberately not the next CAST.
--
-- A Primal Tide Core cast rolls twice, so "chance this button press procs" is
-- the combined 1-(1-h(N))(1-h(N+1)). That is more accurate and it was what this
-- showed at first, but it breaks the one relationship users actually rely on:
-- every failed draw is +1%, so the counter and the percentage must agree. It
-- produced a counter of 0 next to 3%, which reads as "nothing has failed yet,
-- but three failures' worth of chance" -- and it also SPIKED on the doubled
-- cast then dropped back, which looks like a bug every time.
--
-- Per-draw keeps chance == (counter + 1)%, always, with no exceptions. The PTC
-- cast still shows up honestly: it advances the counter by 2, so the percentage
-- jumps by 2 in step with it.
local function GetChanceValue()
    return ChanceAt(sinceProc + 1) * 100
end
local function GetDeckPos()     return sinceProc end
local function GetProcs()       return 0 end   -- no deck, nothing is spent
local function GetViolations()  return 0 end   -- not a deck: nothing to violate

local function GetDeckText()
    -- Whole percent: the steps are 1 point apart, and a decimal only adds width
    -- on a small icon without adding information.
    return string.format("%.0f%%", GetChanceValue())
end

local function GetProcText() return tostring(sinceProc) end

local function Reset()
    sinceProc, totalProcs, lastRiptideAt, ascUntil = 0, 0, 0, 0
    castCount = 0
    PT.UpdateDeck("restodre")
end

-- MUST stay in sync with the option's get() in Core, which falls back to
-- loadCondition.defaultOn when the value is nil. Split logic would let the
-- toggle and the gate disagree about what "untouched" means.
local function RequireTalentGate()
    local idb = PT.GetIconDB and PT.GetIconDB("restodre")
    if not idb then return true end
    if idb.requireLoad == nil then return true end   -- untouched = on
    return idb.requireLoad == true
end

-- TWO SEPARATE GATES, deliberately. Spec drives DETECTION; the talent gate only
-- drives DISPLAY. Collapsing them would stop counting whenever the icon is
-- hidden, so a talent swap mid-session would silently desync the counter from
-- the game's instead of just hiding a widget.
-- Shows only when ALL of these hold:
--   the user enabled the icon   (deckEnabled, checked by ShowDeckIconIfEnabled)
--   the spec is Restoration
--   Deeply Rooted Elements is actually talented (unless the user turned the
--   load condition off, in which case they have asked to see it regardless)
local function ApplyVisibility()
    local entry = PT and PT.GetDeck and PT.GetDeck("restodre")
    if not entry then return end
    local specOK = IsResto()
    local showOK = specOK
    if specOK and RequireTalentGate() then showOK = HasDRE() end
    if entry.widget then
        if showOK then PT.ShowDeckIconIfEnabled("restodre")
        else entry.widget:Hide() end
    end
    if PT.ApplyBarTalentVisibility then
        PT.ApplyBarTalentVisibility("restodre", showOK)
    end
end

-- ── Events ───────────────────────────────────────────────────────────────────
local evFrame = CreateFrame("Frame")

local function OnEvent(_, event, arg1, arg2, arg3)
    -- DETECTION gates on SPEC only, never on Eligible(). Eligible() includes the
    -- talent check, and the talent check trusts a proc as proof -- so gating
    -- detection on it deadlocks: IsPlayerSpell returning a false negative would
    -- stop the very event that would have corrected it. Display is gated
    -- separately in ApplyVisibility, which is the whole point of two gates.
    if not registered or not IsResto() then return end

    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        if arg1 ~= "player" then return end
        local id = arg3
        if issecretvalue and issecretvalue(id) then return end
        if tonumber(id) ~= RIPTIDE_ID then return end
        lastRiptideAt = GetTime()
        castCount = castCount + 1
        -- A Riptide cast while Ascendance is still up CAN proc -- measured at
        -- 0.55%, which is exactly h(1) -- but that proc merges into the running
        -- aura and fires no cooldown event, so it is invisible. Count the draw
        -- anyway: it really did roll, and skipping it would desync the counter
        -- from the game's.
        -- +2 on a PTC cast: the extra application is a real draw the game
        -- counts and we cannot observe. Advancing by 1 there would leave the
        -- displayed chance permanently below the true one.
        sinceProc = sinceProc + (HasPTC() and (castCount % PTC_EVERY == 0) and 2 or 1)
        PT.UpdateDeck("restodre")
        return
    end

    if event == "SPELL_UPDATE_COOLDOWN" then
        local id = arg1
        if issecretvalue and issecretvalue(id) then return end
        if tonumber(id) ~= ASC_RESTO then return end
        if lastRiptideAt == 0 then return end
        if (GetTime() - lastRiptideAt) > PROC_WINDOW then return end
        -- Outside the window this is a hand-pressed Ascendance, not a proc.
        local firstEver = not sawAProc
        sawAProc   = true
        totalProcs = totalProcs + 1
        -- A proc is positive proof the talent is taken, which IsPlayerSpell can
        -- get wrong. Re-evaluate visibility so the icon appears rather than
        -- staying hidden for the rest of the session.
        if firstEver then ApplyVisibility() end

        -- A Primal Tide Core cast rolls TWICE. If only one of those two draws
        -- procced, the other one FAILED, and that failure belongs to the new
        -- counter -- so the counter starts at 1, not 0.
        --
        -- Strictly we cannot tell which of the pair procced: if it was the
        -- first, the second failed afterwards and the true counter is 1; if it
        -- was the second, the first was already counted and the true counter is
        -- 0. Simulated over 400k procs it is exactly 50/50, so neither choice is
        -- more accurate. Given that, count the failure: it matches what the
        -- player just watched happen (two Riptides went out, one procced) and
        -- avoids a counter of 0 sitting under an obviously-doubled cast. The
        -- error either way is 1 draw = 1 percentage point, and it never
        -- accumulates because the next proc resets everything.
        local wasPTCCast = HasPTC() and (castCount % PTC_EVERY == 0)
        sinceProc  = wasPTCCast and 1 or 0
        ascUntil   = GetTime() + 6.0
        PT.UpdateDeck("restodre")
        return
    end
end

-- ── Registration ─────────────────────────────────────────────────────────────
local function TryRegister()
    if registered then return end
    if not IsResto() then return end
    registered = true
    evFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    evFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
    evFrame:SetScript("OnEvent", OnEvent)

    PT.RegisterDeck({
        id            = "restodre",
        name          = "Deeply Rooted Elements",
        ns            = RD,
        deckSize      = CAP_AT,
        procs         = 1,
        defaultIcon   = DRE_ICON,
        noCDMWarn     = true,          -- detection never touches CDM

        -- Presets for the "Attach To" dropdown, so the text can ride a Cooldown
        -- Manager icon or an action button instead of this widget. That is the
        -- point for most people: hide the icon entirely and put the chance on
        -- the Riptide they are already watching.
        --
        -- CooldownIDs are NOT spell ids -- these come from the in-game tooltip:
        -- Riptide 29968, Ascendance 29973.
        cdmAnchors = {
            { id = 29968, name = "Riptide" },
            { id = 29973, name = "Ascendance" },
        },
        actionAnchors = {
            { name = "Riptide",    ids = { RIPTIDE_ID } },
            { name = "Ascendance", ids = { ASC_RESTO } },
        },
        GetDeckPos     = GetDeckPos,
        GetProcs       = GetProcs,
        GetViolations  = GetViolations,
        -- DELIBERATELY no GetChanceText/GetChanceValue. Those add Core's
        -- separate "Proc Chance" text, which is what a real deck needs because
        -- its position and its chance are different numbers. This has no deck
        -- position: the chance IS the main text, so supplying both would put
        -- the same number on the icon twice and give the panel two controls
        -- for it. Same choice Soulburst makes.
        GetDeckText    = GetDeckText,  -- the proc chance
        GetProcText    = GetProcText,  -- Riptides cast since the last proc
        OnReset        = Reset,
        OnEnable       = ApplyVisibility,

        -- Off by default, like every Arc feature: installing an update must
        -- never make an icon appear on someone who did not ask for it.
        -- Core only RENDERS this option; the gate itself is the module's job
        -- (see ApplyVisibility). A `test` field here would look wired up and do
        -- nothing, which is worse than no option at all.
        loadCondition = {
            defaultOn = true,
            name = "Only Show With Deeply Rooted Elements",
            desc = "On by default. Hides the icon unless you are Restoration "
                .. "with Deeply Rooted Elements talented.",
        },

        -- KEY IS `ui`, NOT `labels`. Core reads entry.ui; anything else is
        -- silently ignored, which is exactly what happened the first time --
        -- the panel kept saying "Deck Position Text" and "Proc Count" with no
        -- error to show why. Only the keys Core actually looks up are set here.
        ui = {
            deckTextHeader = "Proc Chance Text",
            deckShow       = "Show Proc Chance",
            deckFontDesc   = "Font for the proc chance percentage.",

            procTextHeader = "Riptides Since Last Proc",
            procShow       = "Show Riptide Count",
            procFontDesc   = "Font for the Riptide count -- casts since your last proc.",

            -- Two states only: climbing, or pinned at 100%. No middle, so the
            -- third colour is hidden rather than left dangling.
            emptyColorName = "Chance Still Climbing",
            emptyColorDesc = "Colour while the proc chance is still rising with each Riptide.",
            fullColorName  = "Guaranteed (100%)",
            fullColorDesc  = "Colour once the chance has reached 100%.",

            -- Bar panel
            barDeckTextHeader = "Proc Chance Text",
            barDeckShow       = "Show Proc Chance",
            barDeckShowDesc   = "Chance that your next Riptide procs Ascendance.",
            barProcTextHeader = "Riptides Since Last Proc",
            barProcShow       = "Show Riptide Count",
            barProcShowDesc   = "Riptides cast since your last proc.",
            barTickDesc       = "Draws a tick at the Riptide count where each proc fired.",
        },
        uiHide = {
            -- Both texts come from GetDeckText/GetProcText, so the shared
            -- count-down and suffix toggles are wired to nothing.
            countDown      = true,
            showDeckSuffix = true,
            procCountDown  = true,
            showProcSuffix = true,
            halfColor      = true,
            -- A violation means a deck delivered the wrong proc count. This is
            -- not a deck, so the counter would sit at zero forever.
            showViolations = true,
            barDeckCountDown  = true,
            barDeckShowSuffix = true,
            barProcCountDown  = true,
            barProcShowSuffix = true,
        },
    })
end

-- Spec changes decide whether this exists at all, so watch for them rather than
-- polling. Registration is idempotent in Core, so a repeat call is harmless.
local specFrame = CreateFrame("Frame")
specFrame:RegisterEvent("PLAYER_LOGIN")
specFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
specFrame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
-- Talent changes inside a spec do not fire the spec events, so without this the
-- icon lingers after DRE is untalented until the next spec swap or reload.
specFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
specFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
specFrame:SetScript("OnEvent", function()
    TryRegister()
    if registered then
        ApplyVisibility()
        PT.UpdateDeck("restodre")
    end
end)

RD.Reset      = Reset
RD.GetChance  = GetChanceValue
RD.Eligible   = Eligible
