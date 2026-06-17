-- ArcUI_PT_DWDeck.lua
-- Doom Winds deck tracking.
-- Detection: CDM frame hook on cooldownID=82621 (auraInstanceID change = proc).
-- Stack progression: PT.MSW.OnConsumed callback — no duplicate UNIT_AURA listener.
-- Asc suppression: deck frozen during Ascendance (stacks not counted).
-- Snapshot fix: dwSnapTotal set to pre-advance value on every consume.
-- Frame swap guard: self ~= dwCDMFrame on all hooks (M+ instance pool fix).
-- No pcall. Zero polling.

local issecretvalue = issecretvalue

-- ── Constants ─────────────────────────────────────────────────────────────────
local DW_CDM_ID  = 82621   -- CDM cooldown ID for DW buff
local DW_CAST_ID    = 384352  -- Doom Winds hard-cast (suppresses first proc)
local DW_DEFAULT_ICON = 1035054  -- Doom Winds icon file ID
local ASC_IDS    = { [114051]=true, [114049]=true }
local DECK_SIZE  = 600
local DECK_PROCS = 3

-- ── State ─────────────────────────────────────────────────────────────────────
local dwTotalStacks    = 0
local dwDeckNumber     = 1
local dwDeckProcs      = 0
local dwPrevProcs      = 0
local dwViolations     = 0
local dwGainCount      = 0
local dwSnapTotal      = 0   -- pre-advance snapshot for THIS consume's proc check
local dwLastAuraInstID = nil
local dwCDMFrame       = nil
local dwProcThisConsume= false
local dwLastProcTime   = 0
local hardCastBuf      = {}  -- timestamps of hard-cast DW (suppress first proc)

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function BufPush(buf)
    buf[#buf+1] = GetTime()
    if #buf > 10 then table.remove(buf, 1) end
end

local function BufCheck(buf, window)
    local now = GetTime()
    for i = #buf, 1, -1 do
        if (now - buf[i]) <= window then return true end
        if (now - buf[i]) > window then table.remove(buf, i) end
    end
    return false
end

-- ── Deck advancement ──────────────────────────────────────────────────────────
local function AdvanceDeck(n)
    local before = dwTotalStacks
    dwTotalStacks = dwTotalStacks + n
    local db = math.floor(before / DECK_SIZE)
    local da = math.floor(dwTotalStacks / DECK_SIZE)
    if da > db then
        dwPrevProcs  = dwDeckProcs
        dwDeckProcs  = 0
        dwDeckNumber = da + 1
        local violation = dwPrevProcs ~= DECK_PROCS
        if violation then dwViolations = dwViolations + 1 end
        if PT.DW.OnDeckRollover then
            PT.DW.OnDeckRollover(dwDeckNumber, dwPrevProcs, violation)
        end
    end
end

-- ── Proc confirmed ────────────────────────────────────────────────────────────
local dwEnabled = false  -- set true only when talented and registered

local function OnDWGain(source)
    if not dwEnabled then return end  -- zero CPU when untalented
    local now = GetTime()
    -- Same-frame dedup
    if now == dwLastProcTime then return end
    -- Already counted a proc for this MSW consume
    if dwProcThisConsume then return end

    dwProcThisConsume = true
    dwGainCount       = dwGainCount + 1
    dwLastProcTime    = now

    -- Rollover credit: use pre-advance snap vs current post-advance total
    local snapDeck = math.floor(dwSnapTotal / DECK_SIZE)
    local currDeck = math.floor(dwTotalStacks / DECK_SIZE)
    local rolledOver = currDeck > snapDeck
    local deckPos    = dwSnapTotal % DECK_SIZE

    if rolledOver and dwDeckNumber > 1 and dwPrevProcs < DECK_PROCS then
        -- Proc belongs to previous deck (arrived same frame as rollover)
        dwPrevProcs = dwPrevProcs + 1
        -- Retract premature violation if prev deck is now complete
        if dwPrevProcs == DECK_PROCS and dwViolations > 0 then
            dwViolations = dwViolations - 1
        end
    else
        -- Current deck (or prev deck already full → new deck)
        dwDeckProcs = dwDeckProcs + 1
    end

    if PT.DW.OnProc then
        PT.DW.OnProc(dwDeckNumber, dwDeckProcs, dwGainCount, deckPos)
    end
    PT.UpdateDeck("dw")
end

-- ── CDM frame hooks ───────────────────────────────────────────────────────────
local function HookDWFrame(frame)
    if frame._arcPTDWHooked then return end
    frame._arcPTDWHooked = true

    hooksecurefunc(frame, "OnAuraInstanceInfoSet", function(self)
        if self ~= dwCDMFrame then return end
        local instID = self.auraInstanceID
        if not instID or instID == dwLastAuraInstID then return end
        dwLastAuraInstID = instID
        local isHardCast = BufCheck(hardCastBuf, 0.5)
        if not isHardCast and not PT.MSW.IsAscActive() then
            OnDWGain("CDM_INSTID")
        end
    end)

    hooksecurefunc(frame, "OnAuraInstanceInfoCleared", function(self)
        if self ~= dwCDMFrame then return end
        -- cleared — nothing to do for proc detection
    end)

    hooksecurefunc(frame, "OnUnitAuraAddedEvent", function(self)
        if self ~= dwCDMFrame then return end
        local instID = self.auraInstanceID
        if not instID or instID == dwLastAuraInstID then return end
        dwLastAuraInstID = instID
        local isHardCast = BufCheck(hardCastBuf, 0.5)
        if not isHardCast and not PT.MSW.IsAscActive() then
            OnDWGain("CDM_ADDED")
        end
    end)

    hooksecurefunc(frame, "OnUnitAuraUpdatedEvent", function(self)
        if self ~= dwCDMFrame then return end
        local instID = self.auraInstanceID
        if not instID then return end
        if instID == dwLastAuraInstID then
            -- Same instID = back-to-back proc (duration refresh)
            local isHardCast = BufCheck(hardCastBuf, 0.5)
            if not isHardCast and not PT.MSW.IsAscActive() then
                OnDWGain("CDM_UPDATED")
            end
            return
        end
        dwLastAuraInstID = instID
        local isHardCast = BufCheck(hardCastBuf, 0.5)
        if not isHardCast and not PT.MSW.IsAscActive() then
            OnDWGain("CDM_INSTID_UPD")
        end
    end)
end

local function FindDWCDMFrame()
    local viewer = _G["BuffIconCooldownViewer"]
    if viewer and viewer.itemFramePool then
        for frame in viewer.itemFramePool:EnumerateActive() do
            if frame.cooldownID == DW_CDM_ID then return frame end
        end
    end
    return nil
end

local function InstallSetCooldownIDHook()
    if not CooldownViewerItemDataMixin then return end
    if CooldownViewerItemDataMixin._arcPTDWSetCDIDHooked then return end
    CooldownViewerItemDataMixin._arcPTDWSetCDIDHooked = true
    hooksecurefunc(CooldownViewerItemDataMixin, "SetCooldownID", function(self, cooldownID)
        if cooldownID ~= DW_CDM_ID then return end
        if self == dwCDMFrame then return end
        -- New frame claiming this cooldownID (e.g. instance pool swap)
        dwCDMFrame = self
        HookDWFrame(self)
    end)
end

local function RehookDWCDMFrame(force)
    -- Validate cached frame is still ours; clear if stale so FindDWCDMFrame re-scans
    if dwCDMFrame and dwCDMFrame.cooldownID ~= DW_CDM_ID then
        dwCDMFrame = nil
    end
    local frame = FindDWCDMFrame()
    if frame then
        if frame ~= dwCDMFrame then
            dwCDMFrame = frame
            -- New frame from pool — clear hook flag so hooks reinstall
            frame._arcPTDWHooked = nil
        end
        HookDWFrame(frame)
    end
end

-- ── MSW consume callback ──────────────────────────────────────────────────────
-- Registered after PT.MSW is loaded. Single source of MSW truth.
local function OnMSWConsumed(stacksSpent, spenderID, ascActive)
    if not dwEnabled then return end
    if ascActive then
        -- Deck frozen during Ascendance — don't advance, don't reset proc guard
        return
    end
    -- Snapshot pre-advance so proc detection uses correct rollover reference
    dwSnapTotal = dwTotalStacks
    AdvanceDeck(stacksSpent)
    dwProcThisConsume = false  -- reset per-consume proc guard
    PT.UpdateDeck("dw")
end

-- ── Public callbacks (set by debug module or external consumers) ──────────────
PT.DW = {}
PT.DW.OnProc        = nil   -- function(deckNum, deckProcs, totalGain, deckPos)
PT.DW.OnDeckRollover= nil   -- function(newDeckNum, prevProcs, violation)
PT.DW.IsCDMTracking = function()
    -- Live check: frame must exist AND still claim our cooldownID
    if not dwCDMFrame then return false end
    return dwCDMFrame.cooldownID == DW_CDM_ID
end
PT.DW.RehookCDM     = function() RehookDWCDMFrame() end

-- ── State accessors (used by Core icon widget) ─────────────────────────────────
local function GetDeckPos()
    return dwTotalStacks % DECK_SIZE
end

local function GetProcs()
    return dwDeckProcs
end

local function GetViolations()
    return dwViolations
end

-- ── Reset ─────────────────────────────────────────────────────────────────────
local function Reset()
    dwTotalStacks     = 0
    dwDeckNumber      = 1
    dwDeckProcs       = 0
    dwPrevProcs       = 0
    dwViolations      = 0
    dwGainCount       = 0
    dwSnapTotal       = 0
    dwLastAuraInstID  = nil
    dwProcThisConsume = false
    dwLastProcTime    = 0
    hardCastBuf       = {}
    -- dwCDMFrame stays — no need to re-scan
    PT.UpdateDeck("dw")
end

-- ── Spell event frame (hard-cast + asc detection) ─────────────────────────────
local dwEventFrame = CreateFrame("Frame")
dwEventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
dwEventFrame:RegisterEvent("COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED")

dwEventFrame:SetScript("OnEvent", function(_, event, a1, a2, a3)
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        if a1 ~= "player" then return end
        local spellArg = a3
        if not spellArg or (issecretvalue and issecretvalue(spellArg)) then return end
        local sid = tonumber(spellArg)
        if not sid then return end
        if sid == DW_CAST_ID then
            BufPush(hardCastBuf)
        end
        return
    end

    if event == "COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED" then
        -- CDM may reassign frame objects — rehook
        RehookDWCDMFrame()
        return
    end


end)

-- ── Talent gate ──────────────────────────────────────────────────────────────
-- Choice node shared between Ascendance and Deeply Rooted Elements (DRE).
-- TraitNodeID:        92219   (the shared node)
-- Ascendance entryID: 114291  definitionID: 119296
-- DRE entryID:        101816  definitionID: 106894
-- Deck only active when Ascendance is the selected entry — NOT when DRE is selected.
local ASC_NODE_ID  = 92219
local ASC_ENTRY_ID = 114291  -- Ascendance specific entry

local function IsDWTalented()
    local configID = C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_ClassTalents.GetActiveConfigID()
    if not configID then return false end
    local ni = C_Traits and C_Traits.GetNodeInfo and C_Traits.GetNodeInfo(configID, ASC_NODE_ID)
    if not ni or (ni.activeRank or 0) == 0 then return false end
    -- Node is talented — verify Ascendance (not DRE) is the active choice
    local activeEntryID = ni.activeEntry and ni.activeEntry.entryID
    return activeEntryID == ASC_ENTRY_ID
end

-- ── Register with ProcTracker Core ────────────────────────────────────────────
local function TryRegisterDeck()
    if not IsDWTalented() then return end
    PT.RegisterDeck({
        id          = "dw",
        name        = "Doom Winds",
        deckSize    = DECK_SIZE,
        procs       = DECK_PROCS,
        defaultIcon = DW_DEFAULT_ICON,
        GetDeckPos    = GetDeckPos,
        GetProcs      = GetProcs,
        GetViolations = GetViolations,
        OnReset     = Reset,
        OnEnable    = function()
            dwEnabled = true
            -- Wire MSW consume callback
            PT.MSW.Subscribe("OnConsumed", OnMSWConsumed)
            -- Hook CDM frame
            InstallSetCooldownIDHook()
            RehookDWCDMFrame()
            C_Timer.After(1, function() RehookDWCDMFrame(); PT.UpdateDeck("dw") end)
            C_Timer.After(3, function() RehookDWCDMFrame(); PT.UpdateDeck("dw") end)
            -- Init MSW from live state
            PT.MSW.InitFromLive()
        end,
    })
end

-- Show/hide widget based on current talent state
local function ApplyTalentVisibility()
    local entry = PT and PT.GetDeck and PT.GetDeck("dw")
    if not entry then return end
    -- If talent API not ready (zone transition), don't change state
    local configID = C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_ClassTalents.GetActiveConfigID()
    if not configID then return end
    local talented = IsDWTalented()
    if entry.widget then
        if talented then
            PT.ShowDeckIconIfEnabled("dw")
        else
            entry.widget:Hide()
        end
    end
    if PT.ApplyBarTalentVisibility then PT.ApplyBarTalentVisibility("dw", talented) end
    -- Pause MSW tracking when untalented
    if not talented then
        dwEnabled = false
        PT.MSW.Unsubscribe("OnConsumed", OnMSWConsumed)
        -- NOTE: no Reset() here — deck state survives zone/reload
    else
        dwEnabled = true
        PT.MSW.Subscribe("OnConsumed", OnMSWConsumed)
        PT.MSW.InitFromLive()
    end
end

-- Re-check on any talent/loadout change
local dwTalentFrame = CreateFrame("Frame")
dwTalentFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")           -- same as ArcUI TalentPicker
dwTalentFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
dwTalentFrame:RegisterEvent("ACTIVE_COMBAT_CONFIG_CHANGED")
-- Reset nodeID cache on spec change so we re-scan the new spec's tree
dwTalentFrame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
dwTalentFrame:SetScript("OnEvent", function()
    TryRegisterDeck()       -- no-op if already registered
    ApplyTalentVisibility() -- show/hide based on current state
end)

-- Subscribe to PLAYER_ENTERING_WORLD so we retry on fresh login
-- (C_ClassTalents not ready at file load time on login)
PT.OnEnterWorld[#PT.OnEnterWorld+1] = function()
    TryRegisterDeck()
    ApplyTalentVisibility()
end

TryRegisterDeck()
C_Timer.After(0.2, ApplyTalentVisibility)
C_Timer.After(1.0, ApplyTalentVisibility)