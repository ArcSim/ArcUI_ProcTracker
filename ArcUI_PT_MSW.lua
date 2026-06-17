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
local msw = {
    auraInstanceID  = nil,
    activeInstances = {},
    instanceApps    = {},
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

-- ── Init from live aura ────────────────────────────────────────────────────────
function PT.MSW.InitFromLive()
    local live = C_UnitAuras.GetPlayerAuraBySpellID and
                 C_UnitAuras.GetPlayerAuraBySpellID(MSW_SPELL_ID)
    if live and live.auraInstanceID then
        local n = not (issecretvalue and issecretvalue(live.applications))
                  and tonumber(live.applications) or 0
        msw.auraInstanceID = live.auraInstanceID
        msw.activeInstances[live.auraInstanceID] = true
        msw.instanceApps[live.auraInstanceID]    = n
    end
end

-- ── Reset ─────────────────────────────────────────────────────────────────────
function PT.MSW.Reset()
    msw.auraInstanceID  = nil
    msw.activeInstances = {}
    msw.instanceApps    = {}
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
            -- Sync live stack count at cast time
            if msw.auraInstanceID then
                local a = C_UnitAuras.GetPlayerAuraBySpellID(MSW_SPELL_ID)
                if a and a.auraInstanceID == msw.auraInstanceID and a.applications then
                    local n = not (issecretvalue and issecretvalue(a.applications))
                              and tonumber(a.applications)
                    if n and n > (msw.instanceApps[msw.auraInstanceID] or 0) then
                        msw.instanceApps[msw.auraInstanceID] = n
                    end
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
    if event == "UNIT_AURA" then
        local info = a2; if not info then return end

        -- addedAuras — track new MSW instances
        if info.addedAuras then
            for _, aura in ipairs(info.addedAuras) do
                local auraInstID = aura.auraInstanceID
                local sid = not (issecretvalue and issecretvalue(aura.spellId))
                            and tonumber(aura.spellId) or nil
                if sid == MSW_SPELL_ID then
                    msw.activeInstances[auraInstID] = true
                    msw.auraInstanceID = auraInstID
                    local n2 = not (issecretvalue and issecretvalue(aura.applications))
                               and tonumber(aura.applications) or 1
                    msw.instanceApps[auraInstID] = (n2 > 0) and n2 or 1
                    for _, fn in ipairs(PT.MSW.OnGained) do
                        fn(auraInstID, msw.instanceApps[auraInstID])
                    end
                end
            end
        end

        -- removedAuraInstanceIDs — consume or expire
        if info.removedAuraInstanceIDs then
            for _, instID in ipairs(info.removedAuraInstanceIDs) do
                if msw.activeInstances[instID] then
                    msw.activeInstances[instID] = nil
                    if instID == msw.auraInstanceID then msw.auraInstanceID = nil end

                    local cached      = msw.instanceApps[instID] or 10
                    local stacksSpent = math.min(10, cached > 0 and cached or 10)
                    msw.instanceApps[instID] = nil

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
                            fn(instID, stacksSpent)
                        end
                    end
                end
            end
        end

        -- updatedAuraInstanceIDs — keep stack count fresh
        if info.updatedAuraInstanceIDs and msw.auraInstanceID then
            for _, instID in ipairs(info.updatedAuraInstanceIDs) do
                if instID == msw.auraInstanceID then
                    local live = C_UnitAuras.GetPlayerAuraBySpellID(MSW_SPELL_ID)
                    if live and live.applications then
                        local apps = live.applications
                        if not (issecretvalue and issecretvalue(apps)) then
                            local n = tonumber(apps)
                            if n and n > 0 then
                                msw.instanceApps[msw.auraInstanceID] = n
                            end
                        end
                    end
                    break
                end
            end
        end
        return
    end
end)