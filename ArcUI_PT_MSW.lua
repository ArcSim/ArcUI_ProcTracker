local ADDON, PT = ...   -- private namespace, shared with Core (never the global PT)
-- ArcUI_PT_MSW.lua
-- Shared Maelstrom Weapon resource module.
-- Single UNIT_AURA listener — zero duplication across deck modules.
-- Fires callbacks:
--   PT.MSW.OnConsumed(stacksSpent, spenderID, ascActive)  -- real consume (spender found)
--   PT.MSW.OnExpired(instID, stacks)                      -- duration expire (no spender)
--   PT.MSW.OnGained(instID, apps)                         -- new MSW buff gained
-- No pcall. Zero polling.

local issecretvalue = issecretvalue

PT.MSW = {}

-- ── Constants ─────────────────────────────────────────────────────────────────
local MSW_SPELL_ID   = 344179
local ASC_SPELL_ID   = 114051
local ASC_BUFF_ID    = 114049

local MSW_SPENDER_IDS = {
    [188196]=true,   -- Lightning Bolt
    [188443]=true,   -- Chain Lightning
    [1218090]=true,  -- Primordial Storm
    [452201]=true,   -- Tempest
}

-- DW-initiated spells that set spenderCastID during DW window
local DW_INITIATORS = { [17364]=true, [115356]=true, [187874]=true }
local DW_CAST_ID    = 384352

-- ── State ─────────────────────────────────────────────────────────────────────
-- PRESENCE MODEL (12.1 rework): MSW is a single aura on the player, so instead
-- of instance-keyed maps fed by the UNIT_AURA payload (whose vectors are SECRET
-- in 12.1 restricted content -- iterating them THROWS -- and whose spellId
-- fields go secret, silently dropping MSW), we track one presence flag + one
-- stack cache, re-derived from C_UnitAuras.GetPlayerAuraBySpellID on every
-- player aura event. By-spellID reads stay functional under restriction (MSW is
-- gameplay-whitelisted; the call returns nil/struct, never throws) and the
-- nil-check is never secret. apps == 0 means "count unknown" (consume falls
-- back to 10, the pre-rework behavior for unknown counts).
local msw = {
    present         = false,
    auraInstanceID  = nil,   -- kept ONLY when non-secret (used for == compares)
    apps            = 0,
    spenderCastID   = nil,
    spenderCastTime = 0,
}
local ascendanceActive = false
local dwActive         = false
local mswTotalConsumed    = 0
local mswTotalStacksAll   = 0
local mswTotalConsumedNoAsc = 0
local mswTotalStacksNoAsc   = 0

-- Expose read-only state for deck modules that need it
PT.MSW.IsAscActive           = function() return ascendanceActive end
PT.MSW.IsDWActive            = function() return dwActive end
PT.MSW.GetTotalConsumed      = function() return mswTotalConsumed end
PT.MSW.GetTotalStacksAll     = function() return mswTotalStacksAll end
PT.MSW.GetTotalConsumedNoAsc = function() return mswTotalConsumedNoAsc end
PT.MSW.GetTotalStacksNoAsc   = function() return mswTotalStacksNoAsc end

-- ── Callbacks (subscriber tables — multiple decks can subscribe) ──────────────
PT.MSW.OnConsumed = {}   -- array of functions(stacksSpent, spenderID, ascActive)
PT.MSW.OnExpired  = {}   -- array of functions(instID, stacks)
PT.MSW.OnGained   = {}   -- array of functions(instID, apps)

-- Subscribe/unsubscribe helpers
function PT.MSW.Subscribe(event, fn)
    local t = PT.MSW[event]
    if not t then return end
    for _, f in ipairs(t) do if f == fn then return end end
    t[#t+1] = fn
end
function PT.MSW.Unsubscribe(event, fn)
    local t = PT.MSW[event]
    if not t then return end
    for i, f in ipairs(t) do
        if f == fn then table.remove(t, i); return end
    end
end

-- ── Live read (secret-guarded field extraction) ───────────────────────────────
local function ReadLive()
    local live = C_UnitAuras.GetPlayerAuraBySpellID and
                 C_UnitAuras.GetPlayerAuraBySpellID(MSW_SPELL_ID)
    if not live then return false, nil, nil end
    local aid, apps
    if not (issecretvalue and issecretvalue(live.auraInstanceID)) then
        aid = live.auraInstanceID
    end
    if not (issecretvalue and issecretvalue(live.applications)) then
        apps = tonumber(live.applications)
    end
    return true, aid, apps
end

-- ── Init from live aura ────────────────────────────────────────────────────────
function PT.MSW.InitFromLive()
    local present, aid, apps = ReadLive()
    msw.present        = present
    msw.auraInstanceID = aid
    msw.apps           = (apps and apps > 0) and apps or 0
end

-- ── Reset ─────────────────────────────────────────────────────────────────────
function PT.MSW.Reset()
    msw.present         = false
    msw.auraInstanceID  = nil
    msw.apps            = 0
    msw.spenderCastID   = nil
    msw.spenderCastTime = 0
    ascendanceActive    = false
    dwActive            = false
    mswTotalConsumed    = 0
    mswTotalStacksAll   = 0
    mswTotalConsumedNoAsc = 0
    mswTotalStacksNoAsc   = 0
    -- Note: do NOT clear subscriber tables — decks re-subscribe on OnEnable
end

-- ── Consume/expire dispatch (shared by removal + same-batch replacement) ──────
local function FireConsumeOrExpire(stacksSpent, aidGone)
    local now          = GetTime()
    local spenderFound = msw.spenderCastID ~= nil
                        and (now - msw.spenderCastTime) < 0.3
    local spenderID    = spenderFound and msw.spenderCastID or nil
    msw.spenderCastID   = nil
    msw.spenderCastTime = 0

    if spenderFound then
        mswTotalConsumed  = mswTotalConsumed + 1
        mswTotalStacksAll = mswTotalStacksAll + stacksSpent
        if not ascendanceActive then
            mswTotalConsumedNoAsc = mswTotalConsumedNoAsc + 1
            mswTotalStacksNoAsc   = mswTotalStacksNoAsc + stacksSpent
        end
        for _, fn in ipairs(PT.MSW.OnConsumed) do
            fn(stacksSpent, spenderID, ascendanceActive)
        end
    else
        for _, fn in ipairs(PT.MSW.OnExpired) do
            fn(aidGone, stacksSpent)
        end
    end
end

-- ── Event frame ───────────────────────────────────────────────────────────────
local mswFrame = CreateFrame("Frame")
mswFrame:RegisterUnitEvent("UNIT_AURA", "player")
mswFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")

mswFrame:SetScript("OnEvent", function(_, event, a1, a2, a3)

    -- ── UNIT_SPELLCAST_SUCCEEDED ──────────────────────────────────────────────
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        if a1 ~= "player" then return end
        local spellArg = a3
        if not spellArg or (issecretvalue and issecretvalue(spellArg)) then return end
        local sid = tonumber(spellArg)
        if not sid then return end

        -- Ascendance
        if sid == ASC_SPELL_ID or sid == ASC_BUFF_ID then
            ascendanceActive = true
            C_Timer.After(15, function() ascendanceActive = false end)
        end

        -- DW hard-cast window
        if sid == DW_CAST_ID then
            dwActive = true
            C_Timer.After(10, function() dwActive = false end)
        end

        -- Spender tracking
        if MSW_SPENDER_IDS[sid] then
            -- During DW, don't overwrite a DW initiator (SS/WS/Crash) with triggered CL
            local isDWInitiator = dwActive and msw.spenderCastID
                                  and DW_INITIATORS[msw.spenderCastID]
            if not isDWInitiator then
                msw.spenderCastID   = sid
                msw.spenderCastTime = GetTime()
            end
            -- Sync live stack count at cast time (presence model: no aid
            -- compare -- MSW is a single aura, the live read IS our instance)
            if msw.present then
                local _p, _aid, apps = ReadLive()
                if apps and apps > (msw.apps or 0) then
                    msw.apps = apps
                end
            end
        end

        -- DW initiator during DW window (Stormstrike/Windstrike/Crash)
        if dwActive and DW_INITIATORS[sid] then
            msw.spenderCastID   = sid
            msw.spenderCastTime = GetTime()
        end
        return
    end

    -- ── UNIT_AURA ─────────────────────────────────────────────────────────────
    -- 12.1 REWORK: the payload is not used AT ALL. Its vectors are secret in
    -- restricted content (ipairs THROWS before any guard runs -- the bug that
    -- froze every deck), and its spellId fields go secret even when readable.
    -- Instead: every player aura change re-reads the ONE aura we care about by
    -- spell id and diffs PRESENCE. Event-driven, zero polling, works identically
    -- on live 12.0 and in 12.1 restricted content.
    if event == "UNIT_AURA" then
        local present, aid, apps = ReadLive()

        if present and not msw.present then
            -- GAINED
            msw.present        = true
            msw.auraInstanceID = aid
            msw.apps           = (apps and apps > 0) and apps or 0
            for _, fn in ipairs(PT.MSW.OnGained) do
                fn(aid, msw.apps)
            end

        elseif present and msw.present then
            -- Same instance = stack update. DIFFERENT instance (both aids
            -- readable, plain == on non-secrets) = a consume + regain landed
            -- in one event batch: fire the consume, then the gain.
            local replaced = aid ~= nil and msw.auraInstanceID ~= nil
                            and aid ~= msw.auraInstanceID
            if replaced then
                local cached = msw.apps or 0
                local spent  = math.min(10, cached > 0 and cached or 10)
                local gone   = msw.auraInstanceID
                FireConsumeOrExpire(spent, gone)
                msw.auraInstanceID = aid
                msw.apps           = (apps and apps > 0) and apps or 0
                for _, fn in ipairs(PT.MSW.OnGained) do
                    fn(aid, msw.apps)
                end
            else
                if apps and apps > 0 then msw.apps = apps end
                if aid ~= nil then msw.auraInstanceID = aid end
            end

        elseif (not present) and msw.present then
            -- REMOVED: consume (spender window decides) or expire
            local cached = msw.apps or 0
            local spent  = math.min(10, cached > 0 and cached or 10)
            local gone   = msw.auraInstanceID
            msw.present        = false
            msw.auraInstanceID = nil
            msw.apps           = 0
            FireConsumeOrExpire(spent, gone)
        end
        return
    end
end)