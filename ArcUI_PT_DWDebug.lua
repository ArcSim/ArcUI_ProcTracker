-- ArcUI_PT_DWDebug.lua
-- Doom Winds deck timeline debugger.
-- Watches CDM frame aura hooks, MSW consumes, hard-cast buffer,
-- proc gains, deck state, and rehook events.
-- Toggle: /pt dwdebug
-- No pcall. Zero polling. Zero CPU when hidden.

local issecretvalue = issecretvalue

-- ── Constants ─────────────────────────────────────────────────────────────────
local DW_CDM_ID   = 82621    -- CDM cooldownID for DW buff
local DW_CAST_ID  = 384352   -- Doom Winds hard-cast spellID
local DW_BUFF_ID  = 466772   -- Doom Winds buff spellID
local MSW_ID      = 344179

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

local dwFrame        = nil   -- CDM frame for DW buff
local dwKnownInstIDs = {}  -- set of auraInstanceIDs confirmed as DW buff

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
    dw_gain      = "FF6600",
    dw_cast      = "FF4400",
    dw_cdm       = "FFAA44",
    rehook       = "88CCFF",
    invalidate   = "FF88FF",
    deck         = "00FFCC",
    rollover     = "FFFF44",
    violation    = "FF4444",
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
    local line = string.format("|cff%s[%s] %-38s|r %s", col, ts, tag, detail or "")
    table.insert(log, line)
    if #log > MAX_LOG then table.remove(log, 1) end
    table.insert(rawLog, string.format("[%s] %-38s %s", ts, tag, (detail or ""):gsub("|c%x%x%x%x%x%x%x%x",""):gsub("|r","")))
    if #rawLog > 10000 then table.remove(rawLog, 1) end
    logDirty = true
end

local function Sep(label)
    Push("──── " .. (label or "") .. " ────", "", "separator")
end

-- ── CDM frame finder ──────────────────────────────────────────────────────────
local function FindDWCDMFrame()
    local viewer = _G["BuffIconCooldownViewer"]
    if viewer and viewer.itemFramePool then
        for frame in viewer.itemFramePool:EnumerateActive() do
            if frame.cooldownID == DW_CDM_ID then return frame end
        end
    end
    return nil
end

-- ── Hook CDM frame ────────────────────────────────────────────────────────────
local function HookDWCDMFrame(frame)
    if not frame or frame._arcPTDWDbgHooked then return end
    frame._arcPTDWDbgHooked = true

    if frame.OnAuraInstanceInfoSet then
        hooksecurefunc(frame, "OnAuraInstanceInfoSet", function(self)
            if not enabled then return end
            Push("DW_CDM.OnAuraInstanceInfoSet",
                "instID="..SafeVal(self.auraInstanceID)
                .." tracking="..tostring(PT.DW and PT.DW.IsCDMTracking and PT.DW.IsCDMTracking()), "dw_cdm")
        end)
    end

    if frame.OnAuraInstanceInfoCleared then
        hooksecurefunc(frame, "OnAuraInstanceInfoCleared", function(self)
            if not enabled then return end
            Push("DW_CDM.OnAuraInstanceInfoCleared",
                "prev="..SafeVal(self.auraInstanceID), "dw_cdm")
        end)
    end

    if frame.OnUnitAuraAddedEvent then
        hooksecurefunc(frame, "OnUnitAuraAddedEvent", function(self)
            if not enabled then return end
            Push("DW_CDM.OnUnitAuraAddedEvent",
                "instID="..SafeVal(self.auraInstanceID), "dw_cdm")
        end)
    end

    if frame.OnUnitAuraUpdatedEvent then
        hooksecurefunc(frame, "OnUnitAuraUpdatedEvent", function(self)
            if not enabled then return end
            local instID = self.auraInstanceID
            if not instID then return end
            Push("DW_CDM.OnUnitAuraUpdatedEvent",
                "instID="..SafeVal(instID), "dw_cdm")
        end)
    end

    Push("DW_CDM["..DW_CDM_ID.."] HOOKED", "frame="..tostring(frame:GetName() or tostring(frame)), "dw_cdm")
end

local function ScanAndHookFrames()
    local f = FindDWCDMFrame()
    if f and f ~= dwFrame then
        dwFrame = f
        HookDWCDMFrame(f)
    end
end

-- ── SetCooldownID / ClearCooldownID hooks ─────────────────────────────────────
local function InstallSetCDIDHook()
    if not CooldownViewerItemDataMixin then return end
    if CooldownViewerItemDataMixin._arcPTDWDbgSetCDIDHooked then return end
    CooldownViewerItemDataMixin._arcPTDWDbgSetCDIDHooked = true

    hooksecurefunc(CooldownViewerItemDataMixin, "SetCooldownID", function(self, cooldownID)
        if not enabled then return end
        local frameStr = tostring(self:GetName() or tostring(self))
        local tracking = PT.DW and PT.DW.IsCDMTracking and PT.DW.IsCDMTracking()
        if cooldownID == DW_CDM_ID then
            Push("SetCooldownID DW_CDM["..DW_CDM_ID.."]",
                "frame="..frameStr.." isNewFrame="..tostring(self ~= dwFrame)
                .." tracking="..tostring(tracking), "rehook")
            if self ~= dwFrame then
                dwFrame = self
                HookDWCDMFrame(self)
            end
        end
    end)

    if CooldownViewerItemDataMixin.ClearCooldownID then
        hooksecurefunc(CooldownViewerItemDataMixin, "ClearCooldownID", function(self)
            if not enabled then return end
            local tracking = PT.DW and PT.DW.IsCDMTracking and PT.DW.IsCDMTracking()
            Push("ClearCooldownID",
                "frame="..tostring(self:GetName() or tostring(self))
                .." trackingAfter="..tostring(tracking), "invalidate")
        end)
    end
end

-- ── MSW consume subscriber ────────────────────────────────────────────────────
local function OnMSWConsumedDbg(stacksSpent, spenderID, ascActive)
    if not enabled then return end
    local sname = spenderID and (C_Spell.GetSpellName(spenderID) or tostring(spenderID)) or "?"
    -- Read totals live from PT.MSW (authoritative source, counts all consumes)
    local tot    = PT.MSW.GetTotalConsumed and PT.MSW.GetTotalConsumed() or "?"
    local totStk = PT.MSW.GetTotalStacksAll and PT.MSW.GetTotalStacksAll() or "?"
    local noAsc  = PT.MSW.GetTotalConsumedNoAsc and PT.MSW.GetTotalConsumedNoAsc() or "?"
    local noAscS = PT.MSW.GetTotalStacksNoAsc and PT.MSW.GetTotalStacksNoAsc() or "?"
    Push("MSW_CONSUMED",
        "stacks="..tostring(stacksSpent)
        .." spender="..tostring(spenderID).."("..sname..")"
        ..(ascActive and " [ASC]" or "")
        .."  |cff888888total="..tostring(tot).." stk="..tostring(totStk)
        .." noASC="..tostring(noAsc).." noASCstk="..tostring(noAscS).."|r",
        "msw_consume")
end

-- ── Wire DW deck debug callbacks ──────────────────────────────────────────────
local function WireDeckDebug()
    if not (PT and PT.DW) then return end

    PT.DW.OnProc = function(deckNum, deckProcs, totalGain, deckPos)
        if not enabled then return end
        Push("PROC GAINED",
            "deck#"..tostring(deckNum).." procs="..tostring(deckProcs).."/3"
            .." total#"..tostring(totalGain).." pos="..tostring(deckPos), "dw_gain")
    end

    PT.DW.OnDeckRollover = function(newDeckNum, prevProcs, violation)
        if not enabled then return end
        local col = violation and "violation" or "rollover"
        Push("DECK ROLLOVER",
            "newDeck#"..tostring(newDeckNum)
            .." prevProcs="..tostring(prevProcs).."/3"
            ..(violation and " *** VIOLATION ***" or " clean"), col)
    end
end

local function UnwireDeckDebug()
    if not (PT and PT.DW) then return end
    PT.DW.OnProc        = nil
    PT.DW.OnDeckRollover = nil
end

-- ── Event listener ────────────────────────────────────────────────────────────
local dbgFrame = CreateFrame("Frame")

dbgFrame:SetScript("OnEvent", function(_, event, a1, a2, a3)
    if not enabled then return end

    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        if a1 ~= "player" then return end
        if not a3 or (issecretvalue and issecretvalue(a3)) then return end
        local sid = tonumber(a3)
        if not sid then return end
        if sid == DW_CAST_ID then
            Push("SPELLCAST  DoomWinds (hard-cast)", "spellID="..sid.." — suppressing first proc", "dw_cast")
        end
        return
    end

    if event == "UNIT_AURA" then
        if a1 ~= "player" then return end
        local info = a2; if not info then return end
        if info.addedAuras then
            for _, aura in ipairs(info.addedAuras) do
                local sid = not (issecretvalue and issecretvalue(aura.spellId)) and tonumber(aura.spellId) or nil
                if sid == MSW_ID then
                    local apps = not (issecretvalue and issecretvalue(aura.applications)) and tonumber(aura.applications) or "?"
                    Push("UNIT_AURA  MSW GAINED", "instID="..SafeVal(aura.auraInstanceID).." apps="..tostring(apps), "msw_gain")
                elseif sid == DW_BUFF_ID then
                    local instID = aura.auraInstanceID
                    dwKnownInstIDs[instID] = true
                    -- Also check via spell ID API in case instID from addedAuras is secret
                    local live = C_UnitAuras.GetPlayerAuraBySpellID(DW_BUFF_ID)
                    local liveInstID = live and live.auraInstanceID or nil
                    Push("UNIT_AURA  DW BUFF GAINED", "instID="..SafeVal(instID).." spellIDapi="..SafeVal(liveInstID), "dw_gain")
                    if liveInstID then dwKnownInstIDs[liveInstID] = true end
                end
            end
        end
        if info.removedAuraInstanceIDs then
            for _, instID in ipairs(info.removedAuraInstanceIDs) do
                if dwKnownInstIDs[instID] then
                    dwKnownInstIDs[instID] = nil
                    Push("UNIT_AURA  DW BUFF FADED", "instID="..SafeVal(instID), "dw_cast")
                end
            end
        end
        return
    end

    if event == "COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED" then
        local base = a1
        local baseStr = not (issecretvalue and issecretvalue(base)) and tostring(tonumber(base)) or "<secret>"
        Push("CDM_OVERRIDE_UPDATED", "base="..baseStr, "rehook")
        ScanAndHookFrames()
        return
    end
end)

-- ── UI ────────────────────────────────────────────────────────────────────────
local function DoExport()
    if #rawLog == 0 then print("|cffFF4444PT DWDebug:|r No log."); return end
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
    eb2:SetText("=== PT_DW_LOG ===\n" .. table.concat(rawLog, "\n") .. "\n=== END ===")
    eb2:HighlightText(); ef:Show()
end

local function BuildUI()
    if mainFrame then mainFrame:Show(); return end

    local W, H = 700, 560
    local f = CreateFrame("Frame", "ArcUI_PT_DWDebugFrame", UIParent, "BackdropTemplate")
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
    f:SetBackdropColor(0.06, 0.03, 0.01, 0.97)
    f:SetBackdropBorderColor(1.0, 0.4, 0.0, 0.9)
    mainFrame = f

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -10)
    title:SetText("|cffFF6600ProcTracker|r Doom Winds Debug")

    local sub = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sub:SetPoint("TOP", title, "BOTTOM", 0, -2)
    sub:SetText("|cff888888DW_CDM="..DW_CDM_ID.."  DW_buff="..DW_BUFF_ID.."  DW_cast="..DW_CAST_ID.."  /pt dwdebug to close|r")

    local legend = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    legend:SetPoint("TOP", sub, "BOTTOM", 0, -2)
    legend:SetText(
        "|cff00FFFF■|r MSW consume  "..
        "|cff44FFBB■|r MSW gain  "..
        "|cffFF6600■|r DW proc  "..
        "|cffFF4400■|r DW cast  "..
        "|cffFFAA44■|r CDM hook  "..
        "|cff88CCFF■|r rehook  "..
        "|cffFF88FF■|r invalidate  "..
        "|cffFF4444■|r violation"
    )

    local function Btn(lbl, px, fn)
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetSize(94, 22)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", px, -72)
        b:SetText(lbl)
        b:SetScript("OnClick", fn)
        return b
    end

    Btn("Clear", 10, function()
        log = {}; rawLog = {}; logDirty = true
        if logBox then logBox:SetText("") end
    end)

    local pb = Btn("Pause", 110, nil)
    pb:SetScript("OnClick", function(self)
        paused = not paused
        self:SetText(paused and "|cffFF4444Resume|r" or "Pause")
    end)

    Btn("Scan Frames", 210, function()
        ScanAndHookFrames()
        Sep("MANUAL SCAN")
        Push("DW_CDM frame", dwFrame and "found cooldownID="..DW_CDM_ID or "NOT FOUND", dwFrame and "dw_cdm" or "warn")
        if dwFrame then
            Push("DW_CDM instID", SafeVal(dwFrame.auraInstanceID), "dw_cdm")
        end
        local tracking = PT.DW and PT.DW.IsCDMTracking and PT.DW.IsCDMTracking()
        Push("IsCDMTracking", tostring(tracking), tracking and "dw_cdm" or "warn")
        local dw = C_UnitAuras.GetPlayerAuraBySpellID(DW_BUFF_ID)
        Push("DW buff live", dw and "instID="..SafeVal(dw.auraInstanceID) or "not active", dw and "dw_gain" or "info")
        local msw = C_UnitAuras.GetPlayerAuraBySpellID(MSW_ID)
        Push("MSW live", msw and "apps="..SafeVal(msw.applications) or "not active", msw and "msw_gain" or "info")
    end)

    Btn("Stats", 310, function()
        Sep("DW DECK STATE")
        local e = PT and PT.GetDeck and PT.GetDeck("dw")
        if not e then Push("deck", "not registered", "warn"); return end
        Push("DeckPos",    tostring(e.GetDeckPos and e.GetDeckPos()), "info")
        Push("Procs",      tostring(e.GetProcs and e.GetProcs()).."/3", "info")
        Push("Violations", tostring(e.GetViolations and e.GetViolations()), "info")
        Push("IsCDMTracking", tostring(PT.DW and PT.DW.IsCDMTracking and PT.DW.IsCDMTracking()), "info")
        Sep("MSW TOTALS (from PT.MSW)")
        local tot    = PT.MSW.GetTotalConsumed and PT.MSW.GetTotalConsumed() or 0
        local totStk = PT.MSW.GetTotalStacksAll and PT.MSW.GetTotalStacksAll() or 0
        local noAsc  = PT.MSW.GetTotalConsumedNoAsc and PT.MSW.GetTotalConsumedNoAsc() or 0
        local noAscS = PT.MSW.GetTotalStacksNoAsc and PT.MSW.GetTotalStacksNoAsc() or 0
        Push("All consumes",  "count="..tot.."  stacks="..totStk, "info")
        Push("Excl ASC",      "count="..noAsc.."  stacks="..noAscS, "info")
        Push("ASC consumes",  "count="..(tot-noAsc).."  stacks="..(totStk-noAscS), "info")
    end)

    Btn("Export", 410, DoExport)

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

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

    local flushFrame = CreateFrame("Frame")
    flushFrame:SetScript("OnUpdate", function()
        if not logDirty or not mainFrame or not mainFrame:IsShown() then return end
        logBox:SetText(table.concat(log, "\n"))
        logDirty = false
    end)

    f:Show()
end

-- ── Enable / Disable ──────────────────────────────────────────────────────────
local function Enable()
    enabled      = true
    sessionStart = GetTime()
    log = {}; rawLog = {}
    dbgFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    dbgFrame:RegisterEvent("UNIT_AURA")
    dbgFrame:RegisterEvent("COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED")
    BuildUI()
    InstallSetCDIDHook()
    ScanAndHookFrames()
    if PT and PT.MSW and PT.MSW.Subscribe then
        PT.MSW.Subscribe("OnConsumed", OnMSWConsumedDbg)
    end
    WireDeckDebug()
    Sep("SESSION START")
    Push("INFO", "DW_CDM="..DW_CDM_ID.."  DW_buff="..DW_BUFF_ID.."  DW_cast="..DW_CAST_ID, "info")
    local msw = C_UnitAuras.GetPlayerAuraBySpellID(MSW_ID)
    Push("INIT MSW", msw and "instID="..SafeVal(msw.auraInstanceID).." apps="..SafeVal(msw.applications) or "not active", msw and "msw_gain" or "info")
    local dw = C_UnitAuras.GetPlayerAuraBySpellID(DW_BUFF_ID)
    Push("INIT DW buff", dw and "instID="..SafeVal(dw.auraInstanceID) or "not active", dw and "dw_gain" or "info")
    Push("DW_CDM frame", dwFrame and "found" or "NOT FOUND — use Scan Frames after DW procs", dwFrame and "dw_cdm" or "warn")
    Push("IsCDMTracking", tostring(PT.DW and PT.DW.IsCDMTracking and PT.DW.IsCDMTracking()), "info")
end

local function Disable()
    enabled = false
    dbgFrame:UnregisterAllEvents()
    if PT and PT.MSW and PT.MSW.Unsubscribe then
        PT.MSW.Unsubscribe("OnConsumed", OnMSWConsumedDbg)
    end
    UnwireDeckDebug()
    if mainFrame then mainFrame:Hide() end
end

-- ── Public API (registered via PT slash in Core) ──────────────────────────────
ArcUI_PT_DWDebug = {
    Toggle    = function() if enabled then Disable() else Enable() end end,
    Export    = DoExport,
    IsEnabled = function() return enabled end,
}