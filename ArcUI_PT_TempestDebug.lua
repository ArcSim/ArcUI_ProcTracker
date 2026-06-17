-- ArcUI_PT_TempestDebug.lua
-- Standalone Tempest timeline debugger for PT addon.
-- Watches ALL relevant events and CDM frame hooks for both:
--   Arc Discharge CDM frame  cooldownID = 112545
--   Tempest aura CDM frame   cooldownID = 82398
-- Toggle: /pt tdebug
-- No pcall. Zero polling. Zero CPU when hidden.

local issecretvalue = issecretvalue

-- ── Constants ─────────────────────────────────────────────────────────────────
local AD_CDM_ID       = 112545   -- Arc Discharge CDM cooldown ID
local TEMPEST_CDM_ID  = 82398    -- Tempest aura CDM cooldown ID
local TEMPEST_BUFF    = 454015
local TEMPEST_CAST    = 452201
local LB_ID           = 188196
local MSW_ID          = 344179
local AD_BUFF_ID      = 470532   -- Arc Discharge buff spellID

-- ── State ─────────────────────────────────────────────────────────────────────
local enabled      = false
local paused       = false
local log          = {}
local rawLog       = {}
local MAX_LOG      = 600
local logDirty     = false
local sessionStart = GetTime()
local mainFrame    = nil
local logBox       = nil

local adFrame      = nil   -- CDM frame for Arc Discharge
local tempFrame    = nil   -- CDM frame for Tempest aura
local adInstID     = nil
local tempInstID   = nil

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function TS()
    return string.format("%07.3f", GetTime() - sessionStart)
end

local function SafeVal(v)
    if v == nil then return "nil" end
    if issecretvalue and issecretvalue(v) then return "<secret>" end
    return tostring(v)
end

local COLOR = {
    msw_consume  = "00FFFF",
    msw_gain     = "44FFBB",
    tempest_gain = "00FF88",
    tempest_cast = "FFAA44",
    ad_gain      = "FF88FF",
    ad_refresh   = "AA44AA",
    ad_fade      = "884488",
    cdm_ad       = "FF88FF",
    cdm_temp     = "00CC88",
    spell_cd     = "FFFF44",
    override     = "88CCFF",
    separator    = "444444",
    info         = "888888",
    warn         = "FF8800",
}

local function Push(tag, detail, colorKey)
    if not enabled or paused then return end
    local col = (type(colorKey) == "string" and #colorKey == 6 and colorKey:match("^%x+$"))
                and colorKey
                or (COLOR[colorKey] or "CCCCCC")
    local ts  = TS()
    local line = string.format("|cff%s[%s] %-30s|r %s", col, ts, tag, detail or "")
    table.insert(log, line)
    if #log > MAX_LOG then table.remove(log, 1) end
    table.insert(rawLog, string.format("[%s] %-30s %s", ts, tag, (detail or ""):gsub("|c%x%x%x%x%x%x%x%x",""):gsub("|r","")))
    if #rawLog > 10000 then table.remove(rawLog, 1) end
    logDirty = true
end

local function Sep(label)
    Push("──── " .. (label or "") .. " ────", "", "separator")
end

-- ── CDM frame finder ──────────────────────────────────────────────────────────
local function FindCDMFrame(cooldownID)
    for _, name in ipairs({"EssentialCooldownViewer","UtilityCooldownViewer",
                           "BuffIconCooldownViewer","BuffBarCooldownViewer"}) do
        local v = _G[name]
        if v and v.itemFramePool then
            for frame in v.itemFramePool:EnumerateActive() do
                if frame.cooldownID == cooldownID then return frame end
            end
        end
    end
    return nil
end

-- ── Hook a CDM frame and log all its aura events ──────────────────────────────
local function HookFrame(frame, label, colorKey)
    if not frame or frame["_arcPTTDbgHooked_"..label] then return end
    frame["_arcPTTDbgHooked_"..label] = true

    if frame.OnAuraInstanceInfoSet then
        hooksecurefunc(frame, "OnAuraInstanceInfoSet", function(self)
            if not enabled then return end
            local instID = self.auraInstanceID
            Push(label..".OnAuraInstanceInfoSet",
                "instID="..SafeVal(instID), colorKey)
        end)
    end

    if frame.OnAuraInstanceInfoCleared then
        hooksecurefunc(frame, "OnAuraInstanceInfoCleared", function(self)
            if not enabled then return end
            Push(label..".OnAuraInstanceInfoCleared",
                "prev="..SafeVal(self.auraInstanceID), colorKey)
        end)
    end

    if frame.OnUnitAuraUpdatedEvent then
        hooksecurefunc(frame, "OnUnitAuraUpdatedEvent", function(self)
            if not enabled then return end
            local instID = self.auraInstanceID
            if not instID then return end  -- nil = not our aura, skip
            Push(label..".OnUnitAuraUpdatedEvent",
                "instID="..SafeVal(instID), colorKey)
        end)
    end

    Push(label.." HOOKED", "cooldownID="..tostring(frame.cooldownID), colorKey)
end

local function ScanAndHookFrames()
    local ad = FindCDMFrame(AD_CDM_ID)
    if ad and ad ~= adFrame then
        adFrame = ad
        HookFrame(adFrame, "AD_CDM["..AD_CDM_ID.."]", "cdm_ad")
    end
    local tf = FindCDMFrame(TEMPEST_CDM_ID)
    if tf and tf ~= tempFrame then
        tempFrame = tf
        HookFrame(tempFrame, "TEMP_CDM["..TEMPEST_CDM_ID.."]", "cdm_temp")
    end
end

-- Hook SetCooldownID and ClearCooldownID to log CDM frame pool events
local function InstallSetCDIDHook()
    if not CooldownViewerItemDataMixin then return end
    if CooldownViewerItemDataMixin._arcPTTDbgSetCDIDHooked then return end
    CooldownViewerItemDataMixin._arcPTTDbgSetCDIDHooked = true

    hooksecurefunc(CooldownViewerItemDataMixin, "SetCooldownID", function(self, cooldownID)
        if not enabled then return end
        local frameStr = tostring(self:GetName() or tostring(self))
        local tracking = PT.Tempest and PT.Tempest.IsCDMTracking and PT.Tempest.IsCDMTracking()
        if cooldownID == AD_CDM_ID then
            Push("SetCooldownID AD_CDM["..AD_CDM_ID.."] frame="..frameStr,
                "tracking="..tostring(tracking), "cdm_ad")
            if self ~= adFrame then
                adFrame = self
                HookFrame(adFrame, "AD_CDM["..AD_CDM_ID.."]", "cdm_ad")
            end
        elseif cooldownID == TEMPEST_CDM_ID then
            Push("SetCooldownID TEMP_CDM["..TEMPEST_CDM_ID.."] frame="..frameStr,
                "isNewFrame="..tostring(self ~= tempFrame).." tracking="..tostring(tracking), "cdm_temp")
            if self ~= tempFrame then
                tempFrame = self
                HookFrame(tempFrame, "TEMP_CDM["..TEMPEST_CDM_ID.."]", "cdm_temp")
            end
        else
            Push("SetCooldownID cdmID="..tostring(cooldownID).." frame="..frameStr, "", "info")
        end
    end)

    if CooldownViewerItemDataMixin.ClearCooldownID then
        hooksecurefunc(CooldownViewerItemDataMixin, "ClearCooldownID", function(self)
            if not enabled then return end
            local frameStr = tostring(self:GetName() or tostring(self))
            -- At posthook time cooldownID is already nil — log prevID via frame name
            local tracking = PT.Tempest and PT.Tempest.IsCDMTracking and PT.Tempest.IsCDMTracking()
            Push("ClearCooldownID frame="..frameStr,
                "cdm.frame==self="..tostring(PT.Tempest and PT.Tempest.GetCDMInstID and (cdm ~= nil))
                .." trackingAfter="..tostring(tracking), "cdm_temp")
        end)
    end
end

-- ── Event listener ────────────────────────────────────────────────────────────
local dbgFrame = CreateFrame("Frame")

dbgFrame:SetScript("OnEvent", function(_, event, a1, a2, a3)
    if not enabled then return end

    -- UNIT_SPELLCAST_SUCCEEDED
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        if a1 ~= "player" then return end
        if not a3 or (issecretvalue and issecretvalue(a3)) then return end
        local sid = tonumber(a3)
        if not sid then return end
        if sid == TEMPEST_CAST then
            Push("SPELLCAST  Tempest", "spellID="..sid, "tempest_cast")
        elseif sid == LB_ID then
            Push("SPELLCAST  LightningBolt", "spellID="..sid, "info")
        end
        return
    end

    -- SPELL_UPDATE_COOLDOWN
    if event == "SPELL_UPDATE_COOLDOWN" then
        if issecretvalue and issecretvalue(a1) then return end
        local sid = tonumber(a1)
        if sid == TEMPEST_BUFF then
            -- TempestDeck logs COUNTED/IGNORED when inside a consume window
            -- This fires for events outside any consume window
            -- Read instID from CDM frame state (already tracked by hooks)
            local cdmInstID = PT.Tempest and PT.Tempest.GetCDMInstID and SafeVal(PT.Tempest.GetCDMInstID()) or "nil"
            local tb = C_UnitAuras.GetPlayerAuraBySpellID(TEMPEST_BUFF)
            local auraInstID = tb and SafeVal(tb.auraInstanceID) or "nil"
            Push("SPELL_UPDATE_CD 454015", "fired (outside consume window) cdmInstID="..cdmInstID.." auraInstID="..auraInstID, "spell_cd")
        elseif sid == AD_BUFF_ID then
            Push("SPELL_UPDATE_CD 470532", "Arc Discharge buff CD fired", "spell_cd")
        end
        return
    end

    -- COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED
    if event == "COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED" then
        local base     = a1
        local override = a2
        local baseStr  = not (issecretvalue and issecretvalue(base))     and tostring(tonumber(base))    or "<secret>"
        local overStr  = not (issecretvalue and issecretvalue(override)) and tostring(tonumber(override)) or "<secret>"
        -- Only log LB overrides (relevant to Tempest)
        if not (issecretvalue and issecretvalue(base)) and tonumber(base) == LB_ID then
            Push("CDM_OVERRIDE_UPDATED", "base="..baseStr.." -> override="..overStr, "override")
        end
        -- Rehook in case CDM swapped frames
        ScanAndHookFrames()
        return
    end

    -- UNIT_AURA — track MSW and Tempest + AD buff
    if event == "UNIT_AURA" then
        if a1 ~= "player" then return end
        local info = a2; if not info then return end

        if info.addedAuras then
            for _, aura in ipairs(info.addedAuras) do
                local sid = not (issecretvalue and issecretvalue(aura.spellId)) and tonumber(aura.spellId) or nil
                if sid == MSW_ID then
                    local apps = not (issecretvalue and issecretvalue(aura.applications)) and tonumber(aura.applications) or "?"
                    Push("UNIT_AURA  MSW GAINED", "instID="..SafeVal(aura.auraInstanceID).." apps="..tostring(apps), "msw_gain")
                elseif sid == TEMPEST_BUFF then
                    Push("UNIT_AURA  Tempest GAINED", "instID="..SafeVal(aura.auraInstanceID), "tempest_gain")
                elseif sid == AD_BUFF_ID then
                    Push("UNIT_AURA  ArcDischarge GAINED", "instID="..SafeVal(aura.auraInstanceID), "ad_gain")
                end
            end
        end

        if info.updatedAuraInstanceIDs then
            for _, instID in ipairs(info.updatedAuraInstanceIDs) do
                -- Only log Tempest and AD refreshes (not MSW — too noisy)
                local tlive = C_UnitAuras.GetPlayerAuraBySpellID(TEMPEST_BUFF)
                if tlive and tlive.auraInstanceID == instID then
                    local apps = not (issecretvalue and issecretvalue(tlive.applications)) and tonumber(tlive.applications) or "?"
                    Push("UNIT_AURA  Tempest UPDATED", "instID="..SafeVal(instID).." apps="..tostring(apps), "tempest_gain")
                end
                local adlive = C_UnitAuras.GetPlayerAuraBySpellID(AD_BUFF_ID)
                if adlive and adlive.auraInstanceID == instID then
                    local apps = not (issecretvalue and issecretvalue(adlive.applications)) and tonumber(adlive.applications) or "?"
                    Push("UNIT_AURA  ArcDischarge UPDATED", "instID="..SafeVal(instID).." apps="..tostring(apps), "ad_refresh")
                end
            end
        end

        -- UNIT_AURA REMOVED intentionally not logged (noise)
        return
    end
end)

-- Register events
dbgFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
dbgFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
dbgFrame:RegisterEvent("COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED")
dbgFrame:RegisterUnitEvent("UNIT_AURA", "player")

-- Wire into TempestDeck decision log
local function WireDeckDebug()
    if PT and PT.Tempest then
        PT.Tempest.OnDebug = function(tag, detail)
            if not enabled then return end
            -- Color by tag prefix
            local col = "888888"
            if tag:find("FIRE")  then col = "00FF88"
            elseif tag:find("SKIP")  then col = "FF8800"
            elseif tag:find("PROC")  then col = "00FFCC"
            elseif tag:find("CDM")   then col = "00CC88"
            end
            Push("DECK: "..tag, detail, col)
        end
    end
end

-- Hook PT.MSW.OnConsumed via subscriber so we see MSW consumes
local function OnMSWConsumedDbg(stacksSpent, spenderID, ascActive)
    if not enabled then return end
    local sname = spenderID and (C_Spell.GetSpellName(spenderID) or tostring(spenderID)) or "?"
    Push("MSW_CONSUMED",
        "stacks="..tostring(stacksSpent)
        .." spender="..tostring(spenderID).."("..sname..")"
        ..(ascActive and " [ASC]" or ""), "msw_consume")
end

-- ── UI ────────────────────────────────────────────────────────────────────────
local DoExport  -- forward declaration

local function BuildUI()
    if mainFrame then mainFrame:Show(); return end

    local W, H = 680, 560
    local f = CreateFrame("Frame", "ArcUI_PT_TempestDebugFrame", UIParent, "BackdropTemplate")
    f:SetSize(W, H)
    f:SetPoint("CENTER")
    f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetFrameStrata("DIALOG")
    f:SetBackdrop({
        bgFile   = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile=true, tileSize=16, edgeSize=14,
        insets   = {left=4,right=4,top=4,bottom=4},
    })
    f:SetBackdropColor(0.04, 0.04, 0.09, 0.97)
    f:SetBackdropBorderColor(0.0, 0.7, 1.0, 0.9)
    mainFrame = f

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -10)
    title:SetText("|cff00CCFFProcTracker|r Tempest Debug")

    local sub = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sub:SetPoint("TOP", title, "BOTTOM", 0, -2)
    sub:SetText("|cff888888AD_CDM=112545  Tempest_CDM=82398  buff=454015  cast=452201  /pt tdebug to close|r")

    -- Legend
    local legend = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    legend:SetPoint("TOP", sub, "BOTTOM", 0, -2)
    legend:SetText(
        "|cff00FFFF■|r MSW consume  "..
        "|cff00FF88■|r Tempest gain  "..
        "|cffFFAA44■|r Tempest cast  "..
        "|cffFF88FF■|r AD gain  "..
        "|cffFF88FF■|r AD CDM hook  "..
        "|cff00CC88■|r Tempest CDM hook  "..
        "|cffFFFF44■|r SPELL_UPDATE_CD"
    )

    -- Buttons row
    local function Btn(lbl, px, fn)
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetSize(88, 22)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", px, -72)
        b:SetText(lbl)
        b:SetScript("OnClick", fn)
        return b
    end

    Btn("Clear", 10, function()
        log = {}; rawLog = {}; logDirty = true
        if logBox then logBox:SetText("") end
    end)

    local pb = Btn("Pause", 104, nil)
    pb:SetScript("OnClick", function(self)
        paused = not paused
        self:SetText(paused and "|cffFF4444Resume|r" or "Pause")
    end)

    Btn("Scan Frames", 198, function()
        ScanAndHookFrames()
        Sep("MANUAL SCAN")
        Push("AD_CDM frame",   adFrame   and "found cooldownID="..AD_CDM_ID   or "NOT FOUND", adFrame   and "cdm_ad"   or "warn")
        Push("TEMP_CDM frame", tempFrame and "found cooldownID="..TEMPEST_CDM_ID or "NOT FOUND", tempFrame and "cdm_temp" or "warn")
        Push("AD instID",      SafeVal(adFrame   and adFrame.auraInstanceID),   "cdm_ad")
        Push("Tempest instID", SafeVal(tempFrame and tempFrame.auraInstanceID), "cdm_temp")
    end)

    Btn("Scan Auras", 292, function()
        Sep("LIVE AURAS")
        local msw = C_UnitAuras.GetPlayerAuraBySpellID(MSW_ID)
        Push("MSW",       msw   and "instID="..SafeVal(msw.auraInstanceID).." apps="..SafeVal(msw.applications)   or "not active", msw   and "msw_gain"     or "info")
        local tb = C_UnitAuras.GetPlayerAuraBySpellID(TEMPEST_BUFF)
        Push("Tempest",   tb    and "instID="..SafeVal(tb.auraInstanceID).." apps="..SafeVal(tb.applications)     or "not active", tb    and "tempest_gain"  or "info")
        local ad = C_UnitAuras.GetPlayerAuraBySpellID(AD_BUFF_ID)
        Push("ArcDisch",  ad    and "instID="..SafeVal(ad.auraInstanceID).." apps="..SafeVal(ad.applications)     or "not active", ad    and "ad_gain"        or "info")
    end)

    Btn("Stats", 480, function()
        local stats = PT.Tempest and PT.Tempest.GetStats and PT.Tempest.GetStats()
        if not stats then Push("STATS", "unavailable", "warn"); return end
        Sep("STATS SNAPSHOT")
        Push("STATS", "MSW consumed="..stats.mswConsumed
            .."  Tempest procs="..stats.tempestProcs
            .."  violations="..stats.violations
            .."  deck#"..stats.deckNumber, "info")
    end)
    Btn("Export", 386, DoExport)

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    -- Scroll log area
    local sf = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT",     f, "TOPLEFT",   8, -98)
    sf:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -26, 8)

    local eb = CreateFrame("EditBox", nil, sf)
    eb:SetSize(W - 40, 8000)
    eb:SetPoint("TOPLEFT")
    eb:SetMultiLine(true)
    eb:SetFontObject("GameFontHighlightSmall")
    eb:SetAutoFocus(false)
    eb:EnableMouse(true)
    eb:SetTextInsets(4, 4, 4, 4)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnMouseDown",     function(self) self:SetFocus() end)
    sf:SetScrollChild(eb)
    logBox = eb

    -- OnUpdate flush
    local flushFrame = CreateFrame("Frame")
    flushFrame:SetScript("OnUpdate", function()
        if not logDirty or not mainFrame or not mainFrame:IsShown() then return end
        logBox:SetText(table.concat(log, "\n"))
        logDirty = false
    end)

    f:Show()
end

-- ── SS cast + RTL (Awakening Storms) event listener ─────────────────────────────
-- RTL (211094) consumes the AD buff (470532). Consuming AD can cause SPELL_UPDATE_CD 454015
-- to fire — making it look like a deck proc inside a consume window. Tracking SS casts
-- and RTL lets us correlate false proc signals with AD consumption events.
local SS_IDS = { [17364]=true, [115356]=true }
local RTL_ID = 211094  -- Ride the Lightning / Awakening Storms

local ssRtlFrame = CreateFrame("Frame")
ssRtlFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
ssRtlFrame:RegisterEvent("UNIT_AURA")
ssRtlFrame:SetScript("OnEvent", function(_, event, a1, a2, a3)
    if not enabled then return end

    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        if a1 ~= "player" then return end
        if not a3 or (issecretvalue and issecretvalue(a3)) then return end
        local sid = tonumber(a3)
        if not sid then return end
        if SS_IDS[sid] then
            Push("SPELLCAST SS", "spellID="..sid.." (RPPM roll for AS)", "FF8844")
        elseif sid == RTL_ID then
            -- RTL fires = AD buff being consumed = may trigger SPELL_UPDATE_CD 454015
            Push("SPELLCAST RTL", "spellID="..sid.." *** AD consumed -> possible Tempest CD update ***", "FF4400")
        end
        return
    end

    if event == "UNIT_AURA" then
        if a1 ~= "player" then return end
        local info = a2; if not info then return end
        if info.addedAuras then
            for _, aura in ipairs(info.addedAuras) do
                local sid = not (issecretvalue and issecretvalue(aura.spellId)) and tonumber(aura.spellId) or nil
                if sid == RTL_ID then
                    Push("UNIT_AURA RTL GAINED", "instID="..SafeVal(aura.auraInstanceID), "FF4400")
                end
            end
        end
        if info.removedAuraInstanceIDs and info.addedAuras == nil then
            -- Only log removes that aren't paired with a gain (noise reduction)
        end
        return
    end
end)

-- ── Enable / Disable ──────────────────────────────────────────────────────────
local function Enable()
    enabled      = true
    sessionStart = GetTime()
    BuildUI()
    InstallSetCDIDHook()
    ScanAndHookFrames()
    -- Subscribe to MSW consumes
    if PT and PT.MSW and PT.MSW.Subscribe then
        PT.MSW.Subscribe("OnConsumed", OnMSWConsumedDbg)
    end
    WireDeckDebug()
    Sep("SESSION START")
    Push("INFO", "AD_CDM="..AD_CDM_ID.."  Tempest_CDM="..TEMPEST_CDM_ID.."  buff="..TEMPEST_BUFF.."  cast="..TEMPEST_CAST, "info")
    -- Live state snapshot
    local msw = C_UnitAuras.GetPlayerAuraBySpellID(MSW_ID)
    Push("INIT MSW",       msw   and "instID="..SafeVal(msw.auraInstanceID).." apps="..SafeVal(msw.applications)   or "not active", msw   and "msw_gain"    or "info")
    local tb = C_UnitAuras.GetPlayerAuraBySpellID(TEMPEST_BUFF)
    Push("INIT Tempest",   tb    and "instID="..SafeVal(tb.auraInstanceID).." apps="..SafeVal(tb.applications)     or "not active", tb    and "tempest_gain" or "info")
    local ad = C_UnitAuras.GetPlayerAuraBySpellID(AD_BUFF_ID)
    Push("INIT ArcDisch",  ad    and "instID="..SafeVal(ad.auraInstanceID).." apps="..SafeVal(ad.applications)     or "not active", ad    and "ad_gain"      or "info")
    Push("AD_CDM frame",   adFrame   and "found" or "NOT FOUND — cast Tempest first or use Scan Frames", adFrame   and "cdm_ad"   or "warn")
    Push("TEMP_CDM frame", tempFrame and "found" or "NOT FOUND — cast Tempest first or use Scan Frames", tempFrame and "cdm_temp" or "warn")
end

local function Disable()
    enabled = false
    if PT and PT.MSW and PT.MSW.Unsubscribe then
        PT.MSW.Unsubscribe("OnConsumed", OnMSWConsumedDbg)
    end
    if PT and PT.Tempest then
        PT.Tempest.OnDebug = nil
    end
    if mainFrame then mainFrame:Hide() end
end

-- ── Slash command ─────────────────────────────────────────────────────────────
-- Silent background logging — no window, just accumulate entries
-- /pt tdebug export → open window and export immediately
local function EnableSilent()
    if enabled then return end  -- already running
    enabled      = true
    sessionStart = GetTime()
    InstallSetCDIDHook()
    ScanAndHookFrames()
    if PT and PT.MSW and PT.MSW.Subscribe then
        PT.MSW.Subscribe("OnConsumed", OnMSWConsumedDbg)
    end
    WireDeckDebug()
    Sep("SESSION START")
    Push("INFO", "AD_CDM="..AD_CDM_ID.."  Tempest_CDM="..TEMPEST_CDM_ID.."  buff="..TEMPEST_BUFF.."  cast="..TEMPEST_CAST, "info")
    local msw = C_UnitAuras.GetPlayerAuraBySpellID(MSW_ID)
    Push("INIT MSW", msw and "instID="..SafeVal(msw.auraInstanceID).." apps="..SafeVal(msw.applications) or "not active", msw and "msw_gain" or "info")
    local tb = C_UnitAuras.GetPlayerAuraBySpellID(TEMPEST_BUFF)
    Push("INIT Tempest", tb and "instID="..SafeVal(tb.auraInstanceID).." apps="..SafeVal(tb.applications) or "not active", tb and "tempest_gain" or "info")
    local ad = C_UnitAuras.GetPlayerAuraBySpellID(AD_BUFF_ID)
    Push("INIT ArcDisch", ad and "instID="..SafeVal(ad.auraInstanceID).." apps="..SafeVal(ad.applications) or "not active", ad and "ad_gain" or "info")
    print("|cff44FF44ProcTracker:|r Tempest debug logging started silently. Use |cffFFFF00/pt tdebug|r to open window or |cffFFFF00/pt tdebug export|r to export.")
end

-- Registered via PT slash in Core: /pt tdebug

DoExport = function()
    if #rawLog == 0 then print("|cffFF4444PT TempestDebug:|r No log."); return end
    local ef = CreateFrame("Frame", nil, UIParent, "BasicFrameTemplateWithInset")
    ef:SetSize(720, 520); ef:SetPoint("CENTER"); ef:SetFrameStrata("DIALOG")
    ef:SetMovable(true); ef:EnableMouse(true); ef:RegisterForDrag("LeftButton")
    ef:SetScript("OnDragStart", ef.StartMoving); ef:SetScript("OnDragStop", ef.StopMovingOrSizing)
    local sf2 = CreateFrame("ScrollFrame", nil, ef, "UIPanelScrollFrameTemplate")
    sf2:SetPoint("TOPLEFT", ef, "TOPLEFT", 8, -28); sf2:SetPoint("BOTTOMRIGHT", ef, "BOTTOMRIGHT", -28, 8)
    local eb2 = CreateFrame("EditBox", nil, sf2)
    eb2:SetMultiLine(true); eb2:SetFontObject("ChatFontNormal"); eb2:SetWidth(680)
    eb2:SetAutoFocus(true); eb2:SetScript("OnEscapePressed", function() ef:Hide() end)
    sf2:SetScrollChild(eb2)
    eb2:SetText("=== PT_TEMPEST_LOG ===\n" .. table.concat(rawLog, "\n") .. "\n=== END ===")
    eb2:HighlightText(); ef:Show()
end

ArcUI_PT_TempestDebug = {
    Toggle      = function() if enabled then Disable() else Enable() end end,
    StartSilent = EnableSilent,
    Export      = DoExport,
    IsEnabled   = function() return enabled end,
}