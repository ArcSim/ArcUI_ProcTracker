-- ArcUI_PT_SoulburstDeck.lua
-- Devourer MID2 2pc "Soulburst" tracking. DEMON HUNTER / DEVOURER ONLY.
--
-- THIS IS NOT A DECK. It is an escalating-chance (bad luck protection) proc, and
-- it rides the deck engine only for the display. SimC models it as:
--
--     chance(k) = min( 0.0663 + 0.0519*(k-1), 0.3949 )
--
-- where k = QUALIFYING harvests since the last proc, and the counter resets on
-- every proc. Set bonus 1296615: effectN(1)=4 (fragment threshold),
-- effectN(2)=20% (the flat fallback). The curve above averages 19.89% over a
-- full cycle, which matches that 20% -- a good sign the fit describes something
-- real. But those three constants are commented "Fitted from PTR logs" in simc
-- (c70a7d002), NOT spell data, so treat them as a hypothesis under test.
--
-- HOW IT MAPS ONTO THE DECK ENGINE (display convention, not mechanics):
--   deckSize   = 8   -- the attempt at which the chance reaches its cap, so the
--                       bar fills as the proc chance ramps up. It is NOT a deck
--                       length and there is no rollover: the cycle ends on a
--                       PROC, never on reaching 8.
--   GetDeckPos = qualifying harvests since the last proc, clamped to 8
--   procs      = 1   -- one proc closes the cycle
--   violations = always 0. A deck "violation" means the deck failed to deliver
--                its promised procs. A capped ramp promises nothing (39.49% is
--                never 100%), so a long streak is legal, not a violation.
--                Reporting one here would cry wolf on normal behaviour.
--
-- THE ATTEMPT GATE. A harvest consuming < 4 fragments neither rolls nor advances
-- the counter. The APL has harvest lines with no souls_consumed>=4 guard, so
-- sub-4 harvests do happen in real play. We count BOTH ways -- gated (delta >= 4)
-- and raw (every harvest) -- and the debugger compares the two hazard curves, so
-- the data itself proves which gate is correct.
--
-- DETECTION (no CDM, nothing secret-unsafe):
--   attempt = UNIT_SPELLCAST_SUCCEEDED on "player" for Reap/Cull/Eradicate.
--             Player casts are explicitly non-secret in combat.
--   fragments = aura STACKS, not a power type: "Soul Fragments" 1245577,
--             verified in game off the tooltip. Blizzard compares aura
--             .applications unguarded in its own resource bars, so the field is
--             non-secret. Guarded with issecretvalue anyway; an unreadable count
--             degrades that harvest to "unknown", never to a wrong number.
--   proc    = Soulburst buff 1297433 presence transition. Presence only, which
--             is safe even if the struct is secret.
--
-- No pcall. Zero polling.

local issecretvalue = issecretvalue

-- ── Constants ─────────────────────────────────────────────────────────────────
-- Soul Fragments. VERIFIED IN GAME off the tooltip: 1245577, "Soul Fragments are
-- nearby", stack count = fragments held.
--
-- DO NOT go back to 1225789. That is "Void Metamorphosis", the 50-stack builder
-- ("Upon gaining 50 stacks, gain access to Void Metamorphosis") -- a completely
-- different resource that RISES on a harvest. Reading it made every attempt log
-- `frag 27 -> 30 (delta 0) qualifies=false`, so nothing ever counted.
--
-- The trap: Blizzard's own mixin is called DemonHunterSoulFragmentsBar and its
-- constant is DARK_HEART_SPELL_ID = 1225789, so both the file name and the
-- constant name say "soul fragments" while the value tracks the Void Meta
-- builder. The name was wrong, not the code. Verify a spell ID against an
-- in-game tooltip before trusting what it is called.
local SOUL_FRAGMENTS   = 1245577
local VOID_META        = 1217607   -- the active Void Metamorphosis buff

-- THE GATE. "Void Metamorphosis" builder, 50 stacks ("Upon gaining 50 stacks,
-- gain access to Void Metamorphosis").
--
-- Reap harvests fragments and each one consumed pushes this counter UP, so the
-- INCREASE across a Reap is the number of fragments consumed. That is the whole
-- trick, and it works for one reason: this aura is NOT SECRET IN COMBAT.
--
-- Everything else we tried is blocked exactly when it matters. Measured in a
-- raid instance at combat=1:
--     1245577 (Soul Fragments)  ABSENT        <- restricted, returns nil
--     GetSpellCastCount(...)    <SECRET>      <- SecretWhenCooldownsRestricted
--     1225789 (this)            apps=25  READABLE
-- The direct fragment count can never be compared in combat. This can.
--
-- Two ways it can mislead, both handled below rather than assumed away:
--   it CAPS at 50, so a harvest near the top clips the increase; and
--   activating Void Metamorphosis resets it, which reads as a large negative.
local VM_BUILDER       = 1225789
-- The same counter while Void Metamorphosis is up, when 1225789 stops existing.
-- Blizzard calls this SILENCE_THE_WHISPERS_SPELL_ID and swaps to it on exactly
-- this condition in DemonHunterSoulFragmentsBar.
local VM_BUILDER_META  = 1227702

-- Proc signal. Arc observed in game that a Soulburst proc lights the spell
-- overlay glow on 473662, which fires SPELL_ACTIVATION_OVERLAY_GLOW_SHOW.
--
-- This is a BETTER signal than the buff: it is a plain event carrying a plain
-- spellID, it reads nothing from the aura system, and so it cannot be blocked by
-- aura secrecy in instances. Aura presence stays wired up in parallel so the
-- debugger can show which one fires first and whether either ever misses, but
-- whichever arrives first credits the proc and the other is deduped.
local SOULBURST_GLOW   = 473662

-- "Consume Soul". Fires once per harvest that consumed AT LEAST ONE soul, and is
-- completely absent when none were consumed -- verified on max-stack Reaps that
-- logged no 1223423 whatsoever.
--
-- It does NOT count souls (see the 125-sample correlation: nothing separates 4
-- from 3). What it gives us is the zero case, and that is worth having precisely
-- where the builder delta is blind: at the 50-stack cap the delta reads 0 whether
-- you consumed nothing or consumed five, so without this every capped harvest is
-- UNKNOWN and gets counted. With it, a capped harvest that consumed nothing is a
-- hard false.
local CONSUME_SOUL     = 1223423
local CONSUME_WINDOW   = 0.35   -- can arrive a frame either side of the cast

-- Two independent signals for one proc, so a same-proc window is required or
-- every proc counts twice.
local PROC_DEDUP = 0.25
local SOULBURST        = 1297433   -- the 2pc proc buff

-- spell_shadow_shadesofdarkness. Icon ID 136194, but passed as a PATH, and it
-- has to be -- CONFIRMED in game, do not "simplify" this back to the number.
--
-- The engine resolves icons with
--     C_Spell.GetSpellTexture(defaultIcon) or defaultIcon or 136048
-- so the value is tried as a SPELL ID first. 136194 IS a real spell:
--     /dump C_Spell.GetSpellTexture(136194)  ->  237577
-- that lookup succeeds, wins, and returns spell 136194's art (237577, a wolf).
-- The icon ID is never reached. Storm Unleashed only escapes this because its
-- 7636566 is above the spell range, so the lookup returns nil and falls through.
--
-- A path cannot be mistaken for a spell ID: GetSpellTexture returns nil for it
-- and SetTexture takes it directly. Use paths for any classic-range icon ID.
local SB_DEFAULT_ICON  = "Interface\\Icons\\spell_shadow_shadesofdarkness"

local HARVESTS = {
    [1226019] = "Reap",
    [1245453] = "Cull",
    [1225826] = "Eradicate",
}

local THRESHOLD = 4          -- set bonus effectN(1)
local CAP_AT    = 8          -- attempt at which chance reaches the cap
local DECK_PROCS = 1

local BLP_BASE, BLP_STEP, BLP_CAP = 0.0663, 0.0519, 0.3949

local DEVOURER_SPEC_ID = 1480

-- Fragments land in the same event batch as the cast, but not always in the same
-- frame. Long enough to catch the consume, short enough that a second harvest
-- cannot land first (harvests are GCD-bound).
-- MEASURED, do not shrink. Fragments are not consumed in one step: each one
-- fires its own Consume Soul plus a 1225789 tick, and they trickle in over
-- roughly 130-190ms AFTER the cast. At the old 0.15s this read mid-trickle and
-- reported d=1 on a harvest that actually consumed 4 -- the gate looked broken
-- when it was only being read too early.
--
-- 0.40 was still too short. A controlled 2-soul Reap reported d=1 with its only
-- builder tick at +0.233s, so the tail runs past that. Pushed out to 1.0s, and
-- OnHarvestCast now drains any pending harvest first, so a back-to-back cast
-- inside the window closes the previous measurement instead of dropping it --
-- which is what makes a delay this long safe despite the ~1.5s GCD.
local RESOLVE_DELAY = 1.0

-- ── State ─────────────────────────────────────────────────────────────────────
local sbGated      = 0     -- qualifying harvests since last proc  (the real k)
local sbRaw        = 0     -- every harvest since last proc        (gate control)
local sbTotalProcs = 0
local sbLastFrag   = nil
local sbFragStatus = "unknown"
local sbBurstUp    = false
local sbEnabled    = false
local sbPending    = nil   -- { name, before }
local sbLastConsumeSoul = 0   -- GetTime() of the most recent 1223423
local sbHarvestSeq      = 0   -- bumped per harvest; invalidates stale self-audits

-- Builder ticks since the current harvest began. One 1225789 update fires per
-- soul consumed, but several landing in the same frame collapse into one, so
-- this is a LOWER BOUND on souls, never an exact count.
--
-- Measured across two ladders (normal and at the 50-stack cap):
--     1 soul -> 1 tick      2 souls -> 2 ticks
--     3 souls -> 2 or 3     4 souls -> 3        10 souls -> 6
-- 3 gave 3 in one run and 2 in the other, so ticks can never separate 3 from 4.
-- What they DO settle is the bottom: 4 souls was never observed below 3 ticks,
-- and 1 and 2 were exact in both runs.
local sbTickCount    = 0
local sbLastTickTime = 0
-- Counted for the calibration table only -- ticks no longer gate anything.
-- See the removal note in ResolvePending for the measurements that retired them.

-- ── Public API ────────────────────────────────────────────────────────────────
PT.Soulburst = {}
PT.Soulburst.OnProc    = nil   -- (kGated, kRaw, chanceAtProc)
PT.Soulburst.OnAttempt = nil   -- (name, before, after, delta, qualifies, kGated, kRaw)

-- The single-slot callbacks above are owned by the debugger. The deck-hypothesis
-- tester needs the SAME stream at the same time, so there is also a subscriber
-- list. Fire() feeds both: the single slot stays working untouched, and any
-- number of subscribers ride alongside it. Same shape as PT.MSW.Subscribe.
local subscribers = { OnAttempt = {}, OnProc = {}, OnProcDup = {}, OnGlow = {},
                      OnAuraSeen = {}, OnVerify = {} }

function PT.Soulburst.Subscribe(evt, fn)
    local t = subscribers[evt]
    if not t or type(fn) ~= "function" then return end
    for i = 1, #t do if t[i] == fn then return end end
    t[#t+1] = fn
end

function PT.Soulburst.Unsubscribe(evt, fn)
    local t = subscribers[evt]
    if not t then return end
    for i = #t, 1, -1 do if t[i] == fn then table.remove(t, i) end end
end

local function Fire(evt, ...)
    local single = PT.Soulburst[evt]
    if single then single(...) end
    local t = subscribers[evt]
    for i = 1, #t do t[i](...) end
end

-- ── Secret-safe reads ─────────────────────────────────────────────────────────
local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v)
end

-- returns count(number|nil), status(string), inVoidMeta(bool)
--
-- ONE carrier in both states. The previous Dark Heart / Silence the Whispers
-- swap only existed to mirror Blizzard's resource bar, and that bar is not
-- tracking fragments at all -- see the constants block. Void Meta is still read,
-- but purely so the debugger can show it alongside a harvest; it no longer
-- selects which aura we count.
local function ReadFragments()
    local vm = C_UnitAuras.GetPlayerAuraBySpellID(VOID_META)
    local inVoidMeta = (vm ~= nil)

    local a = C_UnitAuras.GetPlayerAuraBySpellID(SOUL_FRAGMENTS)
    -- Absent aura means ZERO fragments, not an unknown count. The buff only
    -- exists while fragments are held ("Soul Fragments are nearby"), so it
    -- vanishes the moment a harvest drains you -- and that is a completely normal
    -- reading, not a failure. Returning nil here made every full drain resolve as
    -- UNKNOWN and poisoned the delta.
    --
    -- The status string still says "noaura" so this stays diagnosable: if the
    -- spell ID were ever wrong the log reads `fragRead=noaura -> noaura` on every
    -- harvest, which is obvious, rather than a silent stream of delta 0.
    if a == nil then return 0, "noaura", inVoidMeta end
    if IsSecret(a) then return nil, "SECRET_STRUCT", inVoidMeta end
    local apps = a.applications
    if apps == nil then return nil, "noapps", inVoidMeta end
    if IsSecret(apps) then return nil, "SECRET_APPS", inVoidMeta end
    return apps, "ok", inVoidMeta
end

-- Void Meta builder stacks. Non-secret in combat, which is the entire point.
--
-- The carrier SWAPS while Void Metamorphosis is active: 1225789 stops existing
-- (observed as metaRead=noaura on every harvest during VM) and 1227702 takes
-- over. This mirrors Blizzard's own resource bar, which switches between exactly
-- these two on the same condition. Without the swap every harvest inside VM is a
-- blind spot that has to be counted unverified.
-- returns count(number|nil), status(string)
local function ReadMeta()
    local inVM = C_UnitAuras.GetPlayerAuraBySpellID(VOID_META) ~= nil
    local id = inVM and VM_BUILDER_META or VM_BUILDER

    local a = C_UnitAuras.GetPlayerAuraBySpellID(id)
    -- ABSENT MEANS ZERO, not unknown. A stacking aura at 0 stacks does not
    -- exist, so the builder vanishes whenever it is empty -- most often right
    -- after Void Metamorphosis consumes it. Observed as
    --     META nil -> 4 (d=? / max 50)  metaRead=noaura
    -- which was really 0 -> 4, a perfectly good qualifying harvest, discarded
    -- into UNKNOWN. Same fix already applied to Soul Fragments.
    --
    -- Safe because absent is distinguishable from blocked: a restricted aura
    -- returns a SECRET struct, which the checks below catch separately.
    if a == nil then return 0, inVM and "empty(vm)" or "empty", id end
    if IsSecret(a) then return nil, "SECRET_STRUCT", id end
    local apps = a.applications
    if apps == nil then return nil, "noapps", id end
    if IsSecret(apps) then return nil, "SECRET_APPS", id end
    return apps, "ok", id
end

-- Max for the CURRENTLY ACTIVE carrier, not always 1225789.
--
-- Inside Void Metamorphosis the counter becomes Collapsing Star stacks with its
-- own (smaller) ceiling. Reporting 50 there would make the cap guard never fire
-- during VM, so a delta clipped at that lower ceiling would be treated as an
-- exact measurement and a real 4+ harvest could be marked qualifies=false.
local function ReadMetaMax()
    local f = C_Spell and C_Spell.GetSpellMaxCumulativeAuraApplications
    if not f then return nil end
    local inVM = C_UnitAuras.GetPlayerAuraBySpellID(VOID_META) ~= nil
    local v = f(inVM and VM_BUILDER_META or VM_BUILDER)
    if v == nil or IsSecret(v) then return nil end
    return v
end

-- ── Fury proxy for fragments consumed ───────────────────────────────────────
-- The direct count is a dead end IN COMBAT. Confirmed by frame inspection: out
-- of combat the CDM frame holds auraDataCached.applications = 4, name "Soul
-- Fragments", spellId 1245577; in combat every field of that same table reads
-- <secret>, and GetPlayerAuraBySpellID returns nothing at all. A secret cannot
-- be compared, so `held >= 4` can never work where it matters.
--
-- The tooltip gives an indirect route: "casting Reap will collect it, granting
-- you 4 Fury". So fragments collected = Fury gained / 4, and player UnitPower is
-- annotated SecretWhenUnitPowerRestricted -- non-secret in normal play, unlike
-- the aura. If that holds up, the gate survives combat.
--
-- Two known ways this can lie, both visible in the log rather than silent:
--   Fury CAPS, so a harvest at full Fury undercounts (delta smaller than 4*N).
--   Other Fury sources inside the resolve window inflate it.
-- Which is why the raw delta and the derived estimate are both logged, never
-- silently folded into the verdict.
local FURY = (Enum and Enum.PowerType and Enum.PowerType.Fury) or 17

local function ReadFury()
    local v = UnitPower("player", FURY)
    if v == nil then return nil, "nil" end
    if IsSecret(v) then return nil, "SECRET" end
    return v, "ok"
end

local function ReadFuryMax()
    local v = UnitPowerMax("player", FURY)
    if v == nil or IsSecret(v) then return nil end
    return v
end

-- presence only: a secret struct still means "present"
local function BurstActive()
    return C_UnitAuras.GetPlayerAuraBySpellID(SOULBURST) ~= nil
end

-- ── Model ─────────────────────────────────────────────────────────────────────
local function ChanceAt(k)
    if k < 1 then return 0 end
    local c = BLP_BASE + BLP_STEP * (k - 1)
    if c > BLP_CAP then c = BLP_CAP end
    return c
end

-- ── Attempt resolution ────────────────────────────────────────────────────────
-- Resolves the outstanding harvest, if any. Called both from the delayed timer
-- and from the proc path.
--
-- ORDER MATTERS. The proc's UNIT_AURA lands BEFORE our RESOLVE_DELAY timer, so
-- if we let the timer run on its own the harvest that actually procced would be
-- counted AFTER the counter reset -- every recorded streak short by one, and the
-- next streak starting at 1 instead of 0. So OnProc drains the pending harvest
-- first. This is the same class of ordering bug that made Storm Unleashed finish
-- 4/5 and 6/5 before it was pinned down.
-- FORWARD DECLARATIONS -- required. ResolvePending (below) applies a deferred
-- proc through both of these, but they are defined further down. Without the
-- locals existing first those references resolve to nil GLOBALS and every proc
-- that had to wait for a harvest would be silently dropped. Syntax-checks clean,
-- fails silently at runtime.
local sbProcPending   -- source string, set when a proc must wait for a harvest
local ApplyProc

local function ResolvePending()
    if not sbPending then return end
    local p = sbPending
    sbPending = nil

    local after, status = ReadFragments()
    local before = p.before

    local delta
    -- Single carrier now, so a Void Meta transition mid-window no longer changes
    -- which aura we read and the old carrier-flip guard is gone.
    if type(before) == "number" and type(after) == "number" then
        delta = before - after
        if delta < 0 then delta = 0 end
    end

    -- PRIMARY GATE: the Void Meta builder's INCREASE = fragments consumed, and
    -- unlike everything else it survives combat. Computed first; the fragment
    -- delta and the Fury proxy below are now only cross-checks.
    local metaAfter, metaAfterStatus, metaAfterCarrier = ReadMeta()
    local metaDelta
    -- Only subtract two readings of the SAME counter. Void Metamorphosis
    -- starting or ending inside the window swaps the carrier, and differencing
    -- across that swap produces a number with no meaning -- which would sail
    -- straight through the >= 4 test.
    if p.metaCarrier == metaAfterCarrier
       and type(p.meta) == "number" and type(metaAfter) == "number" then
        metaDelta = metaAfter - p.meta
    elseif p.metaCarrier ~= metaAfterCarrier then
        metaAfterStatus = "carrier-swapped"
    end

    local qualifies
    if metaDelta ~= nil and metaDelta >= 0 then
        -- Clipped at the cap: the builder cannot rise past max, so an increase
        -- that stops short there is a floor, not a measurement. Only trust it
        -- when it already clears the threshold; otherwise say UNKNOWN rather
        -- than wrongly rule the harvest out.
        local atCap = (p.metaMax ~= nil) and (p.meta + THRESHOLD > p.metaMax)
        if metaDelta >= THRESHOLD then
            qualifies = true
        elseif not atCap then
            qualifies = false
        end
    elseif metaDelta ~= nil and metaDelta < 0 then
        -- Void Metamorphosis consumed the stacks and reset the builder. The
        -- increase is unrecoverable through this window, so do not guess.
        qualifies = nil
    elseif delta ~= nil and p.beforeStatus == "ok" and status == "ok" then
        -- Only trust the fragment delta when BOTH reads actually succeeded.
        -- "noaura" maps to 0 (a genuine zero when readable), but in combat it
        -- also means "restricted", and 0 - 0 = 0 then sails into the >= 4 test
        -- and returns a confident FALSE built on nothing. That is how a
        -- carrier-swapped harvest got marked not-qualifying instead of unknown.
        qualifies = (delta >= THRESHOLD)
    elseif type(before) == "number" and p.beforeStatus == "ok" then
        -- Delta unreadable, but we did have a pre-cast count. Fall back to it:
        -- a harvest can only consume what was there, so fewer than THRESHOLD
        -- fragments held means fewer than THRESHOLD consumed, which cannot
        -- qualify. The converse is an assumption (it also needs
        -- souls_to_consume >= 4), so only the negative direction is trusted --
        -- "definitely did not qualify" is sound, "qualified" stays UNKNOWN.
        if before < THRESHOLD then qualifies = false end
    end
    -- ZERO-SOULS OVERRIDE. Runs AFTER the chain above, on whatever it left
    -- unresolved -- it only ever turns an UNKNOWN into a false, never the
    -- reverse.
    --
    -- This is the cap window's answer. At 50/50 the builder delta reads 0 whether
    -- you consumed nothing or consumed five with nowhere to put them, so every
    -- capped harvest was UNKNOWN and got counted. But the tier rolls on souls
    -- consumed, not on the builder (simc passes fragments_consumed straight from
    -- consume_soul_fragments, independent of it) -- confirmed in game: you CAN
    -- proc at 50/50 by sucking in 4+.
    --
    -- Consume Soul is absent entirely when zero souls were taken, verified on
    -- max-stack Reaps. It cannot count souls (nothing separates 4 from 3 across a
    -- 125-sample correlation), but it settles the zero case exactly.
    local sawConsume = (p.castAt ~= nil)
        and (sbLastConsumeSoul >= p.castAt - CONSUME_WINDOW)
    if qualifies == nil and not sawConsume then
        qualifies = false
    end

    -- LOW-TICK RULE-OUT: REMOVED. Do not reinstate without new evidence.
    --
    -- Ticks looked usable on two hand-run ladders (1->1, 2->2, 4->3) but the
    -- passive calibration over a real session killed it. Against exact deltas:
    --     souls=4  -> ticks ranged 2..4
    --     souls=5  -> ticks ranged 2..4
    --     souls=10 -> ticks ranged 4..8
    -- A 4-soul harvest and a 2-soul harvest can both report 2 ticks, so no
    -- threshold separates them. Small controlled ladders hid this because the
    -- merge depends on frame timing, which is far more variable in real combat
    -- than at a dummy.
    --
    -- Rejecting a harvest that really rolled is worse than admitting we do not
    -- know: it stalls the counter and understates the displayed chance. UNKNOWN
    -- gets counted, which errs the harmless way.
    --
    -- Ticks are still COUNTED and still reported, purely to keep the calibration
    -- table alive in case the picture changes.

    -- qualifies still nil = genuinely unknown. Count it (better an attempt we
    -- cannot verify than a silently dropped one) and flag it for the debugger.

    sbRaw = sbRaw + 1
    if qualifies ~= false then sbGated = sbGated + 1 end

    sbLastFrag, sbFragStatus = after, status

    -- Fury proxy, reported alongside the direct read so the two can be compared
    -- while the direct read still works (out of combat). That comparison is what
    -- validates the proxy before we ever rely on it in combat.
    local furyAfter, furyAfterStatus = ReadFury()
    local furyDelta, furyFrags
    if type(p.fury) == "number" and type(furyAfter) == "number" then
        furyDelta = furyAfter - p.fury
        if furyDelta >= 0 then furyFrags = furyDelta / 4 end
    end

    Fire("OnAttempt", p.name, before, after, delta, qualifies, sbGated, sbRaw,
         p.beforeStatus, status,
         p.fury, furyAfter, furyDelta, furyFrags, p.furyMax,
         (p.furyStatus == "ok" and furyAfterStatus == "ok") and "ok" or
         ((p.furyStatus ~= "ok") and p.furyStatus or furyAfterStatus),
         p.meta, metaAfter, metaDelta, p.metaMax, sbTickCount,
         (p.metaStatus == "ok" and metaAfterStatus == "ok") and "ok" or
         ((p.metaStatus ~= "ok") and p.metaStatus or metaAfterStatus))

    -- ── SELF-AUDIT ───────────────────────────────────────────────────────────
    -- Re-read the counter a second later and see whether the delta GREW after we
    -- committed to a decision. If it did, souls were still arriving when we
    -- measured and the number we gated on was short.
    --
    -- This is the one gate failure that is otherwise invisible: a genuine 4-soul
    -- harvest read as d=3 looks exactly like a real 3-soul harvest. Comparing
    -- against a later read is the only way to catch it, and it costs one timer.
    --
    -- Only meaningful while nothing else has touched the counter, so it is
    -- abandoned if another harvest starts first.
    if metaDelta ~= nil and p.metaCarrier ~= nil then
        local seq       = sbHarvestSeq
        local resolveAt = GetTime()
        local baseline  = p.meta
        local carrier   = p.metaCarrier
        local decided   = qualifies
        local usedDelta = metaDelta
        local nm        = p.name
        C_Timer.After(1.0, function()
            if seq ~= sbHarvestSeq then return end          -- another harvest ran
            -- ANY consumption after we resolved means the counter moved for a
            -- reason that is not this harvest. The big one is the Soulburst proc
            -- itself: it makes the next Consume instant, that Consume eats souls
            -- and raises the builder, and 473662 is not in HARVESTS so it never
            -- bumps the sequence. Every late-delta seen so far was this, sitting
            -- directly after a proc -- pure false alarms that would have hidden a
            -- genuine truncation.
            if sbLastConsumeSoul > resolveAt then return end
            local late, lateStatus, lateCarrier = ReadMeta()
            if lateStatus ~= "ok" or lateCarrier ~= carrier then return end
            if type(late) ~= "number" or type(baseline) ~= "number" then return end
            local lateDelta = late - baseline
            if lateDelta > usedDelta then
                Fire("OnVerify", nm, usedDelta, lateDelta, decided,
                     (decided == false) and (lateDelta >= THRESHOLD))
            end
        end)
    end

    -- A proc that arrived while this harvest was still being measured has been
    -- waiting for exactly this moment: the attempt is now counted, so applying
    -- the proc resets the counter in the right order.
    -- REQUIRED. This is the only place the attempt counter actually changes, and
    -- without a refresh here the icon keeps showing the PREVIOUS cast's value
    -- until the next harvest happens to redraw it -- so the first Reap after a
    -- proc appeared to leave the counter at 0 and the chance at 6.6%, and only
    -- caught up one cast late. OnHarvestCast redraws at CAST time, before the
    -- consume has resolved, which is too early to know anything.
    PT.UpdateDeck("soulburst")

    if sbProcPending then
        local src = sbProcPending
        sbProcPending = nil
        ApplyProc(src)          -- refreshes again after the reset
    end
end

local function OnHarvestCast(name)
    if not sbEnabled then return end
    -- Close out the previous harvest before starting a new one. With a 1.0s
    -- resolve window and a ~1.5s GCD this is rarely needed, but a hasted or
    -- instant-cast Reap can land inside it, and without this the earlier
    -- measurement would be discarded along with its attempt.
    if sbPending then ResolvePending() end

    -- Capture the read STATUS as well as the count. A nil count alone cannot
    -- distinguish "no fragments held" from "the field went secret", and those
    -- demand opposite responses, so both statuses ride through to the debugger.
    local before, beforeStatus, vm = ReadFragments()
    local fury, furyStatus = ReadFury()
    local meta, metaStatus, metaCarrier = ReadMeta()
    sbPending = {
        name = name, before = before, beforeStatus = beforeStatus, vm = vm,
        fury = fury, furyStatus = furyStatus, furyMax = ReadFuryMax(),
        meta = meta, metaStatus = metaStatus, metaCarrier = metaCarrier,
        metaMax = ReadMetaMax(), castAt = GetTime(),
    }
    sbTickCount, sbLastTickTime = 0, 0   -- count ticks for THIS harvest only
    sbHarvestSeq = sbHarvestSeq + 1      -- invalidates any pending self-audit
    C_Timer.After(RESOLVE_DELAY, ResolvePending)
    PT.UpdateDeck("soulburst")
end

local sbLastProcAt = 0

-- Single credit path for both proc signals (overlay glow and aura presence).
-- The first to arrive wins; anything inside PROC_DEDUP is a duplicate view of
-- the same proc and is reported, not counted, so the debugger can show the
-- ordering and lag between the two without corrupting the streak.
-- Applies the proc. Split out so it can run either immediately or deferred.
-- Assigns the forward-declared local above -- NOT "local function".
function ApplyProc(source)
    sbTotalProcs = sbTotalProcs + 1
    local chance = ChanceAt(sbGated)

    Fire("OnProc", sbGated, sbRaw, chance, source)

    sbGated, sbRaw = 0, 0
    PT.UpdateDeck("soulburst")
end

-- Single credit path for both proc signals (overlay glow and aura presence).
--
-- DO NOT resolve the pending harvest here. The proc arrives ~0.2s after the
-- cast while fragments are still trickling in until ~1.0s, so draining early
-- measured the harvest before a single fragment had been consumed -- the very
-- cast that procced logged META d=0 and qualifies=false. That is the "sometimes
-- not counting a Reap I know consumed 4+" bug.
--
-- Instead the proc WAITS for that harvest to finish measuring. ResolvePending
-- counts the attempt first, then applies the proc, so the ordering that mattered
-- (attempt credited before the counter resets) is preserved without truncating
-- the measurement. Costs up to ~0.8s of display latency on the reset; being
-- right is worth more than being instant here.
local function CreditProc(source)
    if not sbEnabled then return end
    local now = GetTime()
    if now - sbLastProcAt < PROC_DEDUP then
        Fire("OnProcDup", source, now - sbLastProcAt)
        return
    end
    sbLastProcAt = now

    if sbPending then
        sbProcPending = source
        return
    end
    ApplyProc(source)
end

-- ── State accessors ───────────────────────────────────────────────────────────
-- Deck position is the ramp progress, clamped: past the cap the chance stops
-- climbing, so a full bar honestly means "as likely as it will ever get".
local function GetDeckPos()
    return (sbGated > CAP_AT) and CAP_AT or sbGated
end
-- The engine derives its state colours from procs vs maxProcs, so a constant 0
-- would pin every bar and text to the "empty" colour forever and the widget
-- would look dead. With procs=1 this gives two honest states: empty while the
-- chance is still ramping, full once it has hit the 39.49% cap and stopped
-- climbing. That is the one threshold on this proc actually worth seeing.
local function GetProcs()
    return (sbGated >= CAP_AT) and DECK_PROCS or 0
end
local function GetViolations() return 0 end   -- see the header: not applicable

-- ── Display text ─────────────────────────────────────────────────────────────
-- This tracker's meaningful number is the CHANCE, not a position in a deck, so
-- it overrides both text fields (the engine falls back to the numeric deck
-- readout for any deck that does not define these).
--
--   main text = chance the NEXT harvest procs, climbing 7 / 12 / 17 / 22 / 27 /
--               33 / 38 / 39 and then holding at the cap
--   sub text  = qualifying harvests since the last proc
--
-- Whole percent is deliberate: the steps are ~5.2 points apart, so a decimal
-- adds width on a small icon without adding information. The debugger prints
-- the exact values.
local function GetDeckText()
    return string.format("%.0f%%", ChanceAt(sbGated + 1) * 100)
end

local function GetProcText()
    return tostring(sbGated)
end

local function Reset()
    sbGated, sbRaw = 0, 0
    sbTotalProcs   = 0
    sbBurstUp      = false
    sbPending      = nil
    sbProcPending  = nil   -- clearing sbPending strands it otherwise: nothing
                           -- would ever resolve, and it would fire against the
                           -- first harvest after the reset instead.
    sbLastProcAt   = 0
    PT.UpdateDeck("soulburst")
end

-- Exposed for the debugger and any future chance readout.
PT.Soulburst.GetChance     = function() return ChanceAt(sbGated + 1) end
PT.Soulburst.GetAttempts   = function() return sbGated, sbRaw end
PT.Soulburst.GetTotalProcs = function() return sbTotalProcs end
PT.Soulburst.GetFragments  = function() return sbLastFrag, sbFragStatus end
PT.Soulburst.ChanceAt      = ChanceAt
PT.Soulburst.CAP_AT        = CAP_AT
-- Exposed so the debugger can centre its ring dump on the CAST rather than on
-- the resolve. Offsets relative to the resolve read as if the cast happened at
-- -0.22s, which made the consume ticks look like they landed before the harvest.
PT.Soulburst.RESOLVE_DELAY = RESOLVE_DELAY
PT.Soulburst.THRESHOLD     = THRESHOLD
PT.Soulburst.ReadFragments = ReadFragments

-- ── Spec gate ────────────────────────────────────────────────────────────────
-- Tier set, not a talent, so there is nothing in the trait tree to check. Spec
-- alone decides. The 2pc itself is deliberately NOT a gate: piece detection by
-- item ID is fragile across difficulty variants, and a Devourer without the tier
-- simply never procs, which costs nothing.
local function IsDevourer()
    local _, class = UnitClass("player")
    if class ~= "DEMONHUNTER" then return false end
    local CSI = C_SpecializationInfo
    local idx = CSI and CSI.GetSpecialization and CSI.GetSpecialization()
    if not idx then return false end
    -- specId is documented Nilable=false Default=0, so an unresolved spec comes
    -- back as 0. Treat that as "not yet known" rather than "not Devourer".
    if CSI.GetSpecializationInfo then
        local id = CSI.GetSpecializationInfo(idx)
        if id and id ~= 0 then return id == DEVOURER_SPEC_ID end
    end
    return false
end

-- ── MID2 2-piece detection ───────────────────────────────────────────────────
-- There is no Lua API for equipped set count. C_Item.GetItemSetInfo returns only
-- the set NAME, and the "(5/5)" line in the tooltip is drawn client-side with no
-- scriptable equivalent. So count equipped pieces against the set's item IDs,
-- which come straight from simc's item_set_bonus table for set 1296615 and are
-- stable across difficulties (difficulty rides on bonusIDs, not the item ID --
-- confirmed against a Mythic 6/6 chest reporting ItemID 271540).
local SET_ITEMS = {
    [271540] = true,  -- Coreguard        (chest)
    [271538] = true,  -- Studded Gauntlets(hands)
    [271537] = true,  -- Relentless Stare (head)
    [271536] = true,  -- Legwraps         (legs)
    [271535] = true,  -- Jaws             (shoulders)
}
local SET_SLOTS = { 1, 3, 5, 7, 10 }   -- head, shoulder, chest, legs, hands

local function SetPieceCount()
    local n = 0
    for i = 1, #SET_SLOTS do
        local itemID = GetInventoryItemID("player", SET_SLOTS[i])
        if itemID and SET_ITEMS[itemID] then n = n + 1 end
    end
    return n
end

local function Has2pc() return SetPieceCount() >= 2 end

-- Is the 2-piece requirement active? DEFAULTS ON.
--
-- This is a deliberate exception to "new options default off": that rule exists
-- so an update never changes behaviour someone already relies on, and this deck
-- is brand new in this version, so there is no prior behaviour to preserve. A
-- Soulburst tracker with no set bonus equipped can never do anything, so showing
-- it by default would only ever be clutter.
--
-- MUST stay in sync with the option's get() in Core, which falls back to
-- loadCondition.defaultOn on nil. Split logic here would let the toggle and the
-- gate disagree about what "untouched" means.
local function RequireSetGate()
    local idb = PT.GetIconDB and PT.GetIconDB("soulburst")
    if not idb then return true end
    if idb.requireLoad == nil then return true end   -- untouched = on
    return idb.requireLoad == true
end

-- The load-condition status line is a function-based label, and AceConfigDialog
-- only re-evaluates those when something tells it to redraw. Without this the
-- text stays stale while you swap gear and only corrects when the panel is
-- closed and reopened.
--
-- Debounced because equipping a set fires PLAYER_EQUIPMENT_CHANGED once PER
-- PIECE, and each notify redraws the whole panel.
local sbNotifyQueued = false
local function NotifyOptions()
    if sbNotifyQueued then return end
    sbNotifyQueued = true
    C_Timer.After(0.2, function()
        sbNotifyQueued = false
        -- Core's helper hits both the stock dialog and the ArcSkin window; going
        -- through AceConfigRegistry alone only reaches the skin if its
        -- ConfigTableChange listener happens to be registered.
        if PT.RefreshOptions then PT.RefreshOptions() end
    end)
end

local function ApplySpecVisibility()
    local entry = PT and PT.GetDeck and PT.GetDeck("soulburst")
    if not entry then return end

    -- TWO SEPARATE GATES, deliberately.
    --   specOK drives DETECTION. Spec is the hard requirement.
    --   showOK drives DISPLAY, and additionally honours the optional 2-piece
    --          requirement the user can switch on.
    -- Collapsing them would stop tracking whenever the set is off, so swapping a
    -- tier piece mid-session would silently desync the counter instead of just
    -- hiding a widget.
    local specOK = IsDevourer()
    local showOK = specOK
    if specOK and RequireSetGate() then
        showOK = Has2pc()
    end

    if entry.widget then
        if showOK then
            PT.ShowDeckIconIfEnabled("soulburst")
        else
            entry.widget:Hide()
        end
    end
    if PT.ApplyBarTalentVisibility then
        PT.ApplyBarTalentVisibility("soulburst", showOK)
    end

    sbEnabled = specOK
    if not specOK then
        sbGated, sbRaw = 0, 0
        sbPending     = nil
        sbProcPending = nil   -- same reason as in Reset: never strand it
    end
end

-- ── Events ───────────────────────────────────────────────────────────────────
local ev = CreateFrame("Frame")
ev:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
ev:RegisterUnitEvent("UNIT_AURA", "player")
ev:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW")
ev:RegisterEvent("SPELL_UPDATE_COOLDOWN")   -- only to spot Consume Soul
ev:SetScript("OnEvent", function(_, event, a1, a2, a3)
    if not sbEnabled then return end

    -- Payloads differ per event, so destructure per branch rather than assuming
    -- one shape: UNIT_SPELLCAST_SUCCEEDED is (unit, castGUID, spellID) while
    -- SPELL_ACTIVATION_OVERLAY_GLOW_SHOW is just (spellID).
    -- Timestamp only. Cheapest possible handler, and it must record even when no
    -- harvest is pending: Consume Soul can land a frame BEFORE
    -- UNIT_SPELLCAST_SUCCEEDED, so gating on sbPending would miss it and wrongly
    -- rule the harvest a zero-soul cast.
    if event == "SPELL_UPDATE_COOLDOWN" then
        -- Guard before comparing: a secret spellID would throw on ==, and this
        -- handler runs on every cooldown update in combat.
        if IsSecret(a1) then return end
        if a1 == CONSUME_SOUL then
            sbLastConsumeSoul = GetTime()
        -- BOTH carriers. Inside Void Metamorphosis the builder swaps to 1227702
        -- exactly as ReadMeta already handles, so watching only 1225789 reported
        -- ticks=0 for every harvest in a VM window while the delta was perfectly
        -- fine. Harmless for the gate (the rule-out needs ticks > 0) but it
        -- silently dropped every VM harvest out of the calibration sample.
        elseif (a1 == VM_BUILDER or a1 == VM_BUILDER_META) and sbPending then
            -- Count DISTINCT timestamps: several ticks in one frame are one
            -- server batch, not several souls.
            local now = GetTime()
            if now ~= sbLastTickTime then
                sbLastTickTime = now
                sbTickCount    = sbTickCount + 1
            end
        end
        return
    end

    if event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" then
        if IsSecret(a1) then return end
        Fire("OnGlow", a1)                 -- log every glow, not just ours
        if a1 == SOULBURST_GLOW then CreditProc("glow") end
        return
    end

    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        local spellID = a3
        if IsSecret(spellID) then return end
        local name = HARVESTS[spellID]
        if name then OnHarvestCast(name) end
        return
    end

    -- UNIT_AURA: presence transition on the proc buff.
    --
    -- OBSERVED ONLY -- this must NOT credit a proc. The Soulburst buff (1297433)
    -- is restricted in combat, so GetPlayerAuraBySpellID returns nil throughout a
    -- fight and the presence flag stays false. The moment combat drops the aura
    -- becomes readable, presence flips false->true, and the aura path reported a
    -- second "proc" 3.5s after the real one at k=0 -- far outside any dedup
    -- window. Those phantoms inflate every deck candidate's proc count and
    -- suppress the violations the whole test depends on.
    --
    -- The glow (473662) has been correct on every proc across every log, so it is
    -- the sole credit source. This branch stays purely to report disagreement.
    local up = BurstActive()
    if up and not sbBurstUp then
        sbBurstUp = true
        Fire("OnAuraSeen", GetTime() - sbLastProcAt)
    elseif not up and sbBurstUp then
        sbBurstUp = false
    end
end)

-- ── Register with ProcTracker Core ───────────────────────────────────────────
local function TryRegisterDeck()
    if not IsDevourer() then return end
    PT.RegisterDeck({
        id            = "soulburst",
        name          = "Soulburst",
        ns            = PT.Soulburst,
        deckSize      = CAP_AT,
        procs         = DECK_PROCS,
        defaultIcon   = SB_DEFAULT_ICON,
        noCDMWarn     = true,   -- detection never touches CDM
        GetDeckPos    = GetDeckPos,
        GetProcs      = GetProcs,
        GetViolations = GetViolations,
        GetDeckText   = GetDeckText,   -- chance %, not a deck position
        GetProcText   = GetProcText,   -- harvests since last proc

        -- WeakAuras-style load condition. Off by default so installing an
        -- update never makes someone's icon vanish; they opt in.
        loadCondition = {
            defaultOn = true,   -- see RequireSetGate for why
            name = "Only Show With 2-Piece",
            desc = "On by default. Hides the icon and bar unless you have at least "
                .. "2 pieces of Abyssal Doomhound's Pursuit equipped. Turn this off "
                .. "to keep the tracker visible without the set. Tracking keeps "
                .. "running either way, so the counter stays correct if you swap gear.",
            Apply  = ApplySpecVisibility,
            Status = function()
                local n = SetPieceCount()
                if n >= 2 then
                    return ("|cff44FF44%d/5 pieces equipped. Tracker is showing.|r"):format(n)
                end
                return ("|cffFF4444%d/5 pieces equipped. Need 2 for the set bonus, "
                        .. "so the tracker is hidden.|r"):format(n)
            end,
        },

        -- ── Options-panel wording ────────────────────────────────────────────
        -- The shared panel is written for decks. None of that language describes
        -- this tracker, so rename what it shows and hide what it cannot do.
        ui = {
            -- Short titles, no banner text. The panel explains itself through
            -- control names and tooltips; a paragraph at the top of every
            -- section just pushed the actual settings off screen.
            deckTextHeader = "Proc Chance Text",
            procTextHeader = "Harvest Counter",

            deckFontDesc = "Font for the proc chance percentage.",
            procFontDesc = "Font for the harvest counter -- casts since your last proc.",

            -- Two states only: climbing, or pinned at the 39% ceiling. There is
            -- no middle, so the third colour is hidden rather than left dangling.
            emptyColorName = "Chance Still Climbing",
            emptyColorDesc = "Colour while the proc chance is still rising with each harvest.",
            fullColorName  = "Max Chance Reached",
            fullColorDesc  = "Colour once the chance has hit its 39% ceiling and stops rising.",

            -- Bar panel
            barDeckTextHeader = "Proc Chance Text",
            barDeckShow       = "Show Proc Chance",
            barDeckShowDesc   = "Chance your next qualifying harvest procs Soulburst.",
            barProcTextHeader = "Harvest Counter",
            barProcShow       = "Show Harvest Counter",
            barProcShowDesc   = "Casts since your last proc.",
            barTickDesc       = "Draws a tick on the bar at the harvest count where each proc fired.",
        },
        uiHide = {
            -- Both texts are supplied by GetDeckText/GetProcText, so the shared
            -- count-down and suffix toggles are wired to nothing.
            countDown      = true,
            showDeckSuffix = true,
            procCountDown  = true,
            showProcSuffix = true,
            -- No middle state to colour (see above).
            halfColor      = true,
            -- A "violation" means a deck delivered the wrong number of procs.
            -- This is not a deck and GetViolations is always 0, so the counter
            -- would sit at zero forever.
            showViolations = true,
            -- Bar equivalents of the same inert toggles.
            barDeckCountDown  = true,
            barDeckShowSuffix = true,
            barProcCountDown  = true,
            barProcShowSuffix = true,
        },
        OnReset       = Reset,
        OnEnable      = function() sbEnabled = IsDevourer() end,
    })
end

local sbSpecFrame = CreateFrame("Frame")
sbSpecFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
sbSpecFrame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
-- Needed for the 2-piece load condition: swapping tier has to re-evaluate the
-- display immediately, not on the next spec change.
sbSpecFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
sbSpecFrame:SetScript("OnEvent", function()
    TryRegisterDeck()
    ApplySpecVisibility()
    NotifyOptions()   -- keep the 2-piece status line live while swapping gear
end)

PT.OnEnterWorld[#PT.OnEnterWorld+1] = function()
    TryRegisterDeck()
    ApplySpecVisibility()
end

TryRegisterDeck()
C_Timer.After(0.2, ApplySpecVisibility)
C_Timer.After(1.0, ApplySpecVisibility)
