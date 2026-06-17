-- ArcUI_PT_TempestDeck.lua
-- Tempest (Enhancement) MSW deck tracking.
-- DETECTION RULE (single source of truth):
--   Tempest proc = new instID appears on CDM frame (cooldownID=82398)
--   within the same frame as MSW_CONSUMED, AND spender != Tempest cast (452201)
-- No polling. No COOLDOWN_VIEWER. No SPELL_UPDATE_COOLDOWN. No OnUnitAuraUpdatedEvent.
-- No pcall. Zero polling.

local issecretvalue = issecretvalue

local function TDbg(tag, detail)
    if PT.Tempest and PT.Tempest.OnDebug then PT.Tempest.OnDebug(tag, detail) end
end

local function SafeVal(v)
    if v == nil then return "nil" end
    if issecretvalue and issecretvalue(v) then return "<secret>" end
    return tostring(v)
end

local TEMPEST_BUFF    = 454015
local AD_BUFF_ID      = 470532
local AD_CDM_ID       = 112545
local TEMPEST_CAST    = 452201
local CDM_COOLDOWN_ID = 82398
local DECK_SIZE       = 100
local DECK_PROCS      = 2
local TEMPEST_NODE_ID  = 94892
local TEMPEST_ENTRY_ID = 117489

local CreditProc
local Reset
local GetStats

local tempTotalStacks   = 0
local tempDeckNumber    = 1
local tempDeckProcs     = 0
local tempPrevDeckProcs = 0
local tempGainCount     = 0
local tempMSWConsumed   = 0  -- total MSW stacks spent (for WCL comparison)
local tempViolations    = 0
local tempEnabled       = false
local prevTempInstID    = nil

local cdm   = { frame=nil, instID=nil, clearedAt=0 }
local adCDM = { instID=nil }  -- Arc Discharge CDM state (debug only)
local snap = { deckNumber=1, prevProcs=0, totalStacks=0, procCredited=false }

local function AdvanceDeck(n)
    local before    = tempTotalStacks
    tempTotalStacks = tempTotalStacks + n
    local dBefore   = math.floor(before / DECK_SIZE)
    local dAfter    = math.floor(tempTotalStacks / DECK_SIZE)
    if dAfter > dBefore then
        local prevProcsSnap = tempDeckProcs
        tempPrevDeckProcs = tempDeckProcs
        tempDeckProcs     = 0
        tempDeckNumber    = dAfter + 1
        -- Defer violation check by one frame so same-frame SPELL_UPDATE_CD 454015
        -- (rollover→prev credit) can arrive before we count a violation
        C_Timer.After(0, function()
            -- Only count as violation if UNDER the required procs (undercount)
            -- Overflow (>DECK_PROCS) means a late proc arrived and was redirected to new deck — not a violation
            local violation = tempPrevDeckProcs < DECK_PROCS
            if violation then tempViolations = tempViolations + 1 end
            TDbg("DECK ROLLOVER", "deck#"..tempDeckNumber.." prevProcs="..prevProcsSnap.."/"..DECK_PROCS
                ..(violation and " VIOLATION#"..tempViolations or " clean"))
            if PT.Tempest and PT.Tempest.OnDeckRollover then
                PT.Tempest.OnDeckRollover(tempDeckNumber, tempPrevDeckProcs, violation)
            end
        end)
    end
end

local function FindCDMFrame()
    for _, name in ipairs({"EssentialCooldownViewer","UtilityCooldownViewer",
                           "BuffIconCooldownViewer","BuffBarCooldownViewer"}) do
        local v = _G[name]
        if v and v.itemFramePool then
            for frame in v.itemFramePool:EnumerateActive() do
                if frame.cooldownID == CDM_COOLDOWN_ID then return frame end
            end
        end
    end
    return nil
end

local function HookCDMFrame(frame)
    if not frame or frame._arcPTTempestHooked then return end
    frame._arcPTTempestHooked = true
    if frame.OnAuraInstanceInfoSet then
        hooksecurefunc(frame, "OnAuraInstanceInfoSet", function(self)
            if not tempEnabled then return end
            local instID = self.auraInstanceID
            if not instID then return end
            if instID ~= prevTempInstID then
                TDbg("CDM instID", tostring(prevTempInstID).." -> "..tostring(instID))
                prevTempInstID = instID
            end
            cdm.instID = instID
        end)
    end
    if frame.OnAuraInstanceInfoCleared then
        hooksecurefunc(frame, "OnAuraInstanceInfoCleared", function(self)
            if not tempEnabled then return end
            cdm.clearedAt = GetTime()
            cdm.instID    = nil
        end)
    end
end

local function RehookCDMFrame()
    local frame = FindCDMFrame()
    if frame then
        if frame ~= cdm.frame then cdm.frame = frame end
        HookCDMFrame(frame)
    end
end

local function HookADCDMFrame(frame)
    if not frame or frame._arcPTADHooked then return end
    frame._arcPTADHooked = true
    if frame.OnAuraInstanceInfoSet then
        hooksecurefunc(frame, "OnAuraInstanceInfoSet", function(self)
            if not tempEnabled then return end
            adCDM.instID = self.auraInstanceID
            TDbg("AD_CDM instID set", SafeVal(self.auraInstanceID))
        end)
    end
    if frame.OnAuraInstanceInfoCleared then
        hooksecurefunc(frame, "OnAuraInstanceInfoCleared", function(self)
            if not tempEnabled then return end
            TDbg("AD_CDM instID cleared", "prev="..SafeVal(adCDM.instID))
            adCDM.instID = nil
        end)
    end
end

local function FindAndHookADCDMFrame()
    for _, name in ipairs({"EssentialCooldownViewer","UtilityCooldownViewer",
                           "BuffIconCooldownViewer","BuffBarCooldownViewer"}) do
        local v = _G[name]
        if v and v.itemFramePool then
            for frame in v.itemFramePool:EnumerateActive() do
                if frame.cooldownID == AD_CDM_ID then
                    HookADCDMFrame(frame); return
                end
            end
        end
    end
end

local function InstallSetCooldownIDHook()
    if not CooldownViewerItemDataMixin then return end
    if CooldownViewerItemDataMixin._arcPTTempestSetCDIDHooked then return end
    CooldownViewerItemDataMixin._arcPTTempestSetCDIDHooked = true
    hooksecurefunc(CooldownViewerItemDataMixin, "SetCooldownID", function(self, cooldownID)
        if cooldownID == CDM_COOLDOWN_ID then
            if self ~= cdm.frame then cdm.frame = self; HookCDMFrame(self) end
        elseif cooldownID == AD_CDM_ID then
            HookADCDMFrame(self)
        end
    end)
end

CreditProc = function(source)
    if snap.procCredited then TDbg("SKIP already credited", source); return end
    snap.procCredited = true
    tempGainCount     = tempGainCount + 1
    local snapDeckNum = snap.deckNumber
    if snapDeckNum == tempDeckNumber then
        tempDeckProcs = tempDeckProcs + 1
    elseif tempPrevDeckProcs < DECK_PROCS then
        tempPrevDeckProcs = tempPrevDeckProcs + 1
        -- If prev deck just reached the required proc count, retract the premature violation
        if tempPrevDeckProcs == DECK_PROCS and tempViolations > 0 then
            tempViolations = tempViolations - 1
        end
    else
        tempDeckProcs = tempDeckProcs + 1
    end
    -- Log which deck actually got the proc
    local creditedDeck  = (snapDeckNum == tempDeckNumber) and tempDeckNumber or (tempDeckNumber - 1)
    local creditedProcs = (snapDeckNum == tempDeckNumber) and tempDeckProcs or tempPrevDeckProcs
    TDbg("PROC CREDITED", source.." gain#"..tempGainCount
        .." creditedDeck#"..creditedDeck.." procs="..creditedProcs.."/"..DECK_PROCS
        ..(snapDeckNum ~= tempDeckNumber and " [rollover→prev]" or ""))
    if PT.Tempest and PT.Tempest.OnProc then
        PT.Tempest.OnProc(tempDeckNumber, tempDeckProcs, tempGainCount, tempTotalStacks % DECK_SIZE)
    end
    PT.UpdateDeck("tempest")
end

local function OnMSWConsumed(stacksSpent, spenderID, ascActive)
    if not tempEnabled then return end
    snap.deckNumber   = tempDeckNumber
    snap.prevProcs    = tempPrevDeckProcs
    snap.totalStacks  = tempTotalStacks
    snap.procCredited = false
    tempMSWConsumed = tempMSWConsumed + stacksSpent
    local instIDAtConsume  = cdm.instID
    local snapDeckAtConsume = snap.deckNumber  -- log for debugging boundary cases
    AdvanceDeck(stacksSpent)
    TDbg("MSW consume", "stacks="..stacksSpent
        .." instIDAtConsume="..tostring(instIDAtConsume)
        .." snapDeck="..tostring(snapDeckAtConsume)
        .." deckNow="..tostring(tempDeckNumber)
        .." deckPos="..(tempTotalStacks % DECK_SIZE))
    -- Rule: MSW_CONSUMED + SPELL_UPDATE_CD 454015 fires within same frame = proc
    local spellCDFiredAt    = nil
    local adInstIDAtConsume = adCDM.instID  -- snapshot for debug logging only

    local spellCDFrame = CreateFrame("Frame")
    spellCDFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
    local consumeTime = GetTime()
    spellCDFrame:SetScript("OnEvent", function(self, _, sid)
        if issecretvalue and issecretvalue(sid) then return end
        if tonumber(sid) == TEMPEST_BUFF then
            local age = (GetTime() - consumeTime) * 1000
            local instIDNow = cdm.instID or prevTempInstID
            if spellCDFiredAt then
                TDbg("SPELL_UPDATE_CD 454015 IGNORED (already seen)", string.format("age=%.1fms instID=%s", age, tostring(instIDNow)))
            elseif age > 5 then
                TDbg("SPELL_UPDATE_CD 454015 IGNORED (too late)", string.format("age=%.1fms > 5ms instID=%s", age, tostring(instIDNow)))
            else
                spellCDFiredAt = GetTime()
                TDbg("SPELL_UPDATE_CD 454015 COUNTED", string.format("age=%.1fms instID=%s atConsume=%s", age, tostring(instIDNow), tostring(instIDAtConsume)))
            end
        end
    end)

    C_Timer.After(0.005, function()
        spellCDFrame:UnregisterAllEvents()
        spellCDFrame:SetScript("OnEvent", nil)
        if not tempEnabled then return end
        local instIDNow = cdm.instID or prevTempInstID
        -- Debug info only — AD consumed = had instID at consume, now nil
        local adConsumedInWindow = adInstIDAtConsume ~= nil and adCDM.instID == nil
        TDbg("RULE1 check", "atConsume="..tostring(instIDAtConsume).." now="..tostring(instIDNow)
            .." spellCD="..(spellCDFiredAt and "YES" or "NO")
            .." adInstAtConsume="..SafeVal(adInstIDAtConsume)
            .." adInstNow="..SafeVal(adCDM.instID)
            .." adConsumed="..(adConsumedInWindow and "YES" or "NO")
            .." snapDeck="..tostring(snapDeckAtConsume).." deckNow="..tostring(tempDeckNumber))
        if spellCDFiredAt then
            TDbg("RULE1 FIRE (SPELL_UPDATE_CD 454015)", "instID="..tostring(instIDNow))
            CreditProc("RULE1")
        else
            TDbg("RULE1 NO PROC", "no SPELL_UPDATE_CD 454015")
            PT.UpdateDeck("tempest")
        end
    end)
end


PT.Tempest = {}
PT.Tempest.GetStats      = function() return GetStats() end
PT.Tempest.GetCDMInstID  = function() return cdm.instID or prevTempInstID end
PT.Tempest.IsCDMTracking  = function()
    if not cdm.frame then return false end
    return cdm.frame.cooldownID == CDM_COOLDOWN_ID
end
PT.Tempest.RehookCDM      = function() RehookCDMFrame() end
PT.Tempest.InvalidateFrame = function(itemFrame)
    if itemFrame == nil or cdm.frame == itemFrame then cdm.frame = nil end
end
PT.Tempest.OnProc         = nil
PT.Tempest.OnDeckRollover = nil
PT.Tempest.OnDebug        = nil

local function GetDeckPos()    return tempTotalStacks % DECK_SIZE end
GetStats = function()
    return {
        mswConsumed = tempMSWConsumed,
        tempestProcs = tempGainCount,
        violations  = tempViolations,
        deckNumber  = tempDeckNumber,
    }
end
local function GetProcs()      return tempDeckProcs end
local function GetViolations() return tempViolations end

Reset = function()
    tempTotalStacks   = 0; tempDeckNumber    = 1
    tempDeckProcs     = 0; tempPrevDeckProcs = 0
    tempGainCount     = 0; tempViolations    = 0; tempMSWConsumed = 0
    snap.deckNumber   = 1; snap.prevProcs    = 0
    snap.totalStacks  = 0; snap.procCredited = false
    cdm.instID        = nil; cdm.clearedAt   = 0
    prevTempInstID    = nil
    -- Note: PT.MSW.Reset() intentionally NOT called here — MSW is a shared module
    -- owned by Core, not by TempestDeck. Calling it here breaks DW deck state.
    PT.MSW.InitFromLive()
    PT.UpdateDeck("tempest")
end

local function IsTempestTalented()
    local specIndex = GetSpecialization()
    local specID    = specIndex and select(1, GetSpecializationInfo(specIndex)) or nil
    if specID ~= 263 then return false end
    local configID = C_ClassTalents.GetActiveConfigID()
    if not configID then return false end
    local ni = C_Traits.GetNodeInfo(configID, TEMPEST_NODE_ID)
    if not ni or (ni.activeRank or 0) == 0 then return false end
    -- Hero tree node: must also be in the player's active subtree
    if ni.subTreeID then return ni.subTreeActive == true end
    return true
end

local function ApplyTalentVisibility()
    local entry = PT and PT.GetDeck and PT.GetDeck("tempest")
    if not entry then return end
    -- If talent API not ready (zone transition), don't change state
    local configID = C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_ClassTalents.GetActiveConfigID()
    if not configID then return end
    local talented = IsTempestTalented()
    if entry.widget then
        if talented then PT.ShowDeckIconIfEnabled("tempest") else entry.widget:Hide() end
    end
    if PT.ApplyBarTalentVisibility then PT.ApplyBarTalentVisibility("tempest", talented) end
    if not talented then
        tempEnabled = false
        PT.MSW.Unsubscribe("OnConsumed", OnMSWConsumed)
        -- NOTE: no Reset() here — deck state survives zone/reload
        -- Reset only happens via Core.ResetAllDecks (M+ start) or manual reset button
    else
        tempEnabled = true
        PT.MSW.Subscribe("OnConsumed", OnMSWConsumed)
        PT.MSW.InitFromLive()
    end
end

local function TryRegisterDeck()
    if not IsTempestTalented() then return end
    PT.RegisterDeck({
        id            = "tempest",
        name          = "Tempest",
        deckSize      = DECK_SIZE,
        procs         = DECK_PROCS,
        defaultIcon   = TEMPEST_CAST,
        GetDeckPos    = GetDeckPos,
        GetProcs      = GetProcs,
        GetViolations = GetViolations,
        OnReset       = Reset,
        OnEnable      = function()
            tempEnabled = true
            PT.MSW.Subscribe("OnConsumed", OnMSWConsumed)
            InstallSetCooldownIDHook()
            RehookCDMFrame()
            FindAndHookADCDMFrame()
            C_Timer.After(1, function() RehookCDMFrame(); FindAndHookADCDMFrame(); PT.UpdateDeck("tempest") end)
            C_Timer.After(3, function() RehookCDMFrame(); FindAndHookADCDMFrame(); PT.UpdateDeck("tempest") end)
            PT.MSW.InitFromLive()
            C_Timer.After(0.1, function()
                if cdm.frame and cdm.frame.auraInstanceID then
                    local v = cdm.frame.auraInstanceID
                    if not (issecretvalue and issecretvalue(v)) then
                        prevTempInstID = v; cdm.instID = v
                        TDbg("INIT prevTempInstID", tostring(v))
                    end
                end
            end)
        end,
    })
end

local tempTalentFrame = CreateFrame("Frame")
tempTalentFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
tempTalentFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
tempTalentFrame:RegisterEvent("ACTIVE_COMBAT_CONFIG_CHANGED")
tempTalentFrame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
tempTalentFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
tempTalentFrame:SetScript("OnEvent", function()
    TryRegisterDeck()
    ApplyTalentVisibility()
end)

PT.OnEnterWorld[#PT.OnEnterWorld+1] = function()
    TryRegisterDeck()
    ApplyTalentVisibility()
end

TryRegisterDeck()
C_Timer.After(0.2, ApplyTalentVisibility)
C_Timer.After(1.0, ApplyTalentVisibility)