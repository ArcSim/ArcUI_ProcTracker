-- ArcUI_PT_DWDeck.lua
-- Doom Winds deck tracking.
-- Detection: CDM frame hooks on cooldownID=82621. A proc is CDM calling
--   OnAuraInstanceInfoSet (its own change detection), or OnUnitAuraUpdatedEvent
--   while the buff is already up (a refresh = back-to-back proc). The aura
--   instance ID itself is secret on 12.1 and is never compared for detection.
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
local dwAuraActive     = false  -- DW buff up? driven by CDM's own Set/Cleared calls
local dwLastClearedAt  = 0      -- when CDM last cleared its aura slot (flap detection)
-- A Set this soon after a Clear is CDM flapping, not a proc. The flap is a
-- SAME-FRAME event: on 12.0.x any CooldownViewerSettings.OnDataChanged runs
-- RefreshLayout -> itemFramePool:ReleaseAll() -> re-Acquire, so every item
-- frame's aura slot is cleared and immediately re-set inside one rebuild.
-- 12.1 added OnCooldownDataChanged, which updates in place when the frame count
-- is unchanged and therefore never clears the slot -- so on 12.1 this guard
-- simply never fires. 0.1s is one rebuild's worth of slack, nothing more.
local FLAP_WINDOW      = 0.1
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

-- Secret-safe aura-instance comparison (12.1: frame.auraInstanceID is SECRET in
-- instances; == between two secrets makes a secret boolean and boolean-testing
-- it THROWS). Returns true (known same) / false (known different) / nil
-- (unknowable -- at least one side secret). When unknowable, callers fall back
-- to the time/consume guards that already dedup proc counting.
local function SameAuraID(a, b)
    if a == nil or b == nil then return false end
    if issecretvalue and (issecretvalue(a) or issecretvalue(b)) then return nil end
    return a == b
end

-- Store an aid for future compares ONLY when non-secret (a stored secret would
-- poison every later compare into "unknowable").
local function StorableAID(v)
    if v == nil then return nil end
    if issecretvalue and issecretvalue(v) then return nil end
    return v
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

-- Debug attempt reporting. PT.DW.OnAttempt is nil unless DWDebug is open, so
-- this costs one table lookup per hook fire in normal play.
local function Attempt(source, accepted, reason)
    local fn = PT.DW and PT.DW.OnAttempt
    if fn then fn(source, accepted, reason) end
end

local function OnDWGain(source)
    if not dwEnabled then return end  -- zero CPU when untalented
    local now = GetTime()
    -- Same-frame dedup
    if now == dwLastProcTime then Attempt(source, false, "same-frame dedup"); return end
    -- Already counted a proc for this MSW consume
    if dwProcThisConsume then Attempt(source, false, "already counted this MSW consume"); return end

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

    Attempt(source, true, nil)
    if PT.DW.OnProc then
        PT.DW.OnProc(dwDeckNumber, dwDeckProcs, dwGainCount, deckPos)
    end
    PT.UpdateDeck("dw")
end

-- ── CDM frame hooks ───────────────────────────────────────────────────────────
-- Shared gate for the CDM hook paths. Order preserved exactly: BufCheck runs on
-- every fire (it also prunes the buffer), then the Ascendance check.
local function GateGain(source)
    if BufCheck(hardCastBuf, 0.5) then
        Attempt(source, false, "hard-cast window")
        return
    end
    if PT.MSW.IsAscActive() then
        Attempt(source, false, "Ascendance active")
        return
    end
    OnDWGain(source)
end

local function HookDWFrame(frame)
    if frame._arcPTDWHooked then return end
    frame._arcPTDWHooked = true

    -- 12.1 NOTE: auraInstanceID is SECRET even in the open world, so the old
    -- "did the id change?" test is dead -- SameAuraID can only ever answer
    -- "unknowable". Detection is therefore driven by WHICH CDM callback fires,
    -- plus a plain nil-check on the id (nil-checks are never secret):
    --
    --   OnAuraInstanceInfoSet     Blizzard calls this ONLY when its own compare
    --                             inside SetAuraInstanceInfo saw a different
    --                             aura instance/spell. The CALL IS the signal.
    --   OnAuraInstanceInfoCleared the aura went away.
    --   OnUnitAuraAddedEvent      CooldownViewer.lua fires this on EVERY active
    --                             item frame for ANY added-aura batch, so it
    --                             says nothing about DW. NOT a proc source.
    --   OnUnitAuraUpdatedEvent    dispatched only for frames mapped to this
    --                             aura instance, so while the buff is up it
    --                             means the aura itself changed = a refresh.

    hooksecurefunc(frame, "OnAuraInstanceInfoSet", function(self)
        if self ~= dwCDMFrame then return end
        local instID = self.auraInstanceID
        if not instID then return end
        -- ONE rule, both branches: a Set arriving right after a Clear is CDM
        -- flapping its own slot for an aura that never left, not a new proc.
        -- Deliberately NOT an id comparison: the id is readable on live but
        -- always <secret> on 12.1, so an id test can only ever work on one
        -- branch and would leave the other unguarded. Timing works on both --
        -- observed flaps re-set in the SAME frame as the clear, while a genuine
        -- proc needs fresh MSW spends and cannot land this soon after the buff
        -- actually ended.
        if (GetTime() - dwLastClearedAt) <= FLAP_WINDOW then
            -- Constant string on purpose: this fires on every CDM rebuild (many
            -- per second on live), and building the message here would allocate
            -- even with the debugger closed.
            Attempt("CDM_SET", false, "CDM flap (re-set immediately after a clear)")
            return
        end
        dwAuraActive     = true
        dwLastAuraInstID = StorableAID(instID)
        GateGain("CDM_SET")
    end)

    hooksecurefunc(frame, "OnAuraInstanceInfoCleared", function(self)
        if self ~= dwCDMFrame then return end
        dwAuraActive    = false
        dwLastClearedAt = GetTime()
        -- Deliberately KEEP dwLastAuraInstID. A flap is Clear-then-Set of the
        -- same instance, so wiping it here would blind the guard above and let
        -- every flap through as a proc. A genuine proc always carries a NEW
        -- instance id, so holding the old one can never block a real one.
    end)

    hooksecurefunc(frame, "OnUnitAuraAddedEvent", function(self)
        if self ~= dwCDMFrame then return end
        local instID = self.auraInstanceID
        if not instID then return end
        -- Not a DW signal (see above). The ONLY thing it is good for is
        -- resyncing when the buff was already up before our hooks existed
        -- (login mid-window) so no Set was ever seen. That resync must NOT
        -- count: the gain happened before we were watching, and it may already
        -- have been counted through the frame we were bound to before.
        if dwAuraActive then
            Attempt("CDM_ADDED", false, "unrelated aura batch, DW already tracked")
            return
        end
        dwAuraActive     = true
        dwLastAuraInstID = StorableAID(instID)
        Attempt("CDM_ADDED", false, "state resync only (buff was already up)")
    end)

    hooksecurefunc(frame, "OnUnitAuraUpdatedEvent", function(self)
        if self ~= dwCDMFrame then return end
        local instID = self.auraInstanceID
        if not instID then return end
        if not dwAuraActive then
            -- Same resync case as above: state only, never counted.
            dwAuraActive     = true
            dwLastAuraInstID = StorableAID(instID)
            Attempt("CDM_UPDATED", false, "state resync only (buff was already up)")
            return
        end
        -- Buff already up and its own aura instance updated = duration refresh
        -- = back-to-back proc.
        local same = SameAuraID(instID, dwLastAuraInstID)
        if same == false then dwLastAuraInstID = StorableAID(instID) end
        GateGain(same == nil and "CDM_UPD_SECRET" or "CDM_UPDATED")
    end)
end

-- All four CDM viewers. The player decides where DW lives in their layout: the
-- buff-BAR viewer is a common choice instead of the buff-icon one, and a
-- cooldown can be moved between categories entirely. Every viewer's item frames
-- share the same aura callbacks (CooldownViewerBuffBarItemMixin is built from
-- CooldownViewerBuffItemMixin, and the aura lifecycle lives further up in
-- CooldownViewerItemDataMixin), so detection works identically in all of them —
-- only the visual layer differs. Scanning one viewer was the only thing tying
-- us to the icon.
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
                if frame.cooldownID == DW_CDM_ID then return frame end
            end
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
            -- Resync active state from the new frame WITHOUT counting a proc:
            -- a rebind is not a gain. Plain nil-check, never secret.
            dwAuraActive = frame.auraInstanceID ~= nil
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
PT.DW.OnAttempt     = nil   -- function(source, accepted, reason) — DWDebug only
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
    dwAuraActive      = dwCDMFrame ~= nil and dwCDMFrame.auraInstanceID ~= nil
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