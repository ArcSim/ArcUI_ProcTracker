-- ArcUI_PT_ElemTempestDebug.lua
-- Logs visibility/talent state at login + spellcast/proc timeline.

local TEMPEST_BUFF = 454015
local ASC_SPELL_ID = 114050
local MAELSTROM_SPENDERS = {
    [8042]   = "Earth Shock",
    [462620] = "Earthquake",
    [61882]  = "Earthquake",
    [117014] = "Elemental Blast",
}

local log      = {}
local paused   = false
local logDirty = false
local sessionStart = GetTime()

local function TS()
    return string.format("[%07.3f]", GetTime() - sessionStart)
end

local function Push(tag, detail)
    if paused then return end
    table.insert(log, TS().." "..string.format("%-45s", tag).." "..(detail or ""))
    logDirty = true
end

local function PushState(label)
    local configID = C_ClassTalents.GetActiveConfigID()
    local specIndex = GetSpecialization()
    local specID = specIndex and select(1, GetSpecializationInfo(specIndex)) or nil
    local ni = configID and C_Traits.GetNodeInfo(configID, 94892)
    local entry = PT.GetDeck and PT.GetDeck("elemtempest")
    local widget = entry and entry.widget
    Push(label, string.format(
        "spec=%s configID=%s rank=%s subTreeActive=%s widget=%s shown=%s elemEnabled=%s",
        tostring(specID),
        tostring(configID),
        tostring(ni and ni.activeRank),
        tostring(ni and ni.subTreeActive),
        tostring(widget ~= nil),
        tostring(widget and widget:IsShown()),
        tostring(PT.ElemTempest and PT.ElemTempest.GetStats and true)
    ))
end

-- Wire into deck namespace
PT.ElemTempest.OnDebug = function(tag, detail)
    Push(tag, detail)
end

-- Log key events that affect visibility
local visFrame = CreateFrame("Frame")
visFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
visFrame:RegisterEvent("PLAYER_LOGIN")
visFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
visFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
visFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
visFrame:SetScript("OnEvent", function(self, event)
    Push("EVENT", event)
    C_Timer.After(0.05, function() PushState("  state@0.05s") end)
    C_Timer.After(0.5,  function() PushState("  state@0.5s") end)
    C_Timer.After(2.0,  function() PushState("  state@2.0s") end)
end)

-- Log spellcasts and SPELL_UPDATE_CD 454015
local dbgFrame = CreateFrame("Frame")
dbgFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
dbgFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
dbgFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, _, spellID = ...
        if unit ~= "player" then return end
        local name = MAELSTROM_SPENDERS[spellID]
        if name then
            Push("SPELLCAST  "..name, "spellID="..spellID)
        elseif spellID == ASC_SPELL_ID then
            Push("SPELLCAST  ASC", "spellID="..spellID)
        elseif spellID == 452201 then
            Push("SPELLCAST  Tempest", "spellID="..spellID)
        end
    elseif event == "SPELL_UPDATE_COOLDOWN" then
        local sid = ...
        if issecretvalue and issecretvalue(sid) then return end
        if tonumber(sid) == TEMPEST_BUFF then
            Push("SPELL_UPDATE_CD 454015", "fired")
        end
    end
end)

-- Log initial state after load
C_Timer.After(0.1,  function() PushState("INIT@0.1s") end)
C_Timer.After(0.5,  function() PushState("INIT@0.5s") end)
C_Timer.After(1.0,  function() PushState("INIT@1.0s") end)
C_Timer.After(2.0,  function() PushState("INIT@2.0s") end)
C_Timer.After(5.0,  function() PushState("INIT@5.0s") end)

-- ── Window ────────────────────────────────────────────────────────────────────
local window = nil
local logBox  = nil

local function RefreshLog()
    if not logBox or not logDirty then return end
    logBox:SetText(table.concat(log, "\n"))
    logBox:SetCursorPosition(logBox:GetNumLetters())
    logDirty = false
end

local function DoExport()
    if logBox then
        logBox:SetText(table.concat(log, "\n"))
        logBox:SetCursorPosition(0)
        logBox:HighlightText()
        logDirty = false
    end
end

local function BuildWindow()
    if window then window:Show(); DoExport(); return end

    local f = CreateFrame("Frame", "ArcUI_ElemTempestDebugWindow", UIParent, "BackdropTemplate")
    f:SetSize(860, 500)
    f:SetPoint("CENTER")
    f:SetMovable(true); f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop",  f.StopMovingOrSizing)
    f:SetBackdrop({ bgFile="Interface/Tooltips/UI-Tooltip-Background",
                    edgeFile="Interface/Tooltips/UI-Tooltip-Border", edgeSize=16,
                    insets={left=4,right=4,top=4,bottom=4} })
    f:SetBackdropColor(0.05, 0.05, 0.10, 0.95)
    f:SetBackdropBorderColor(0.3, 0.5, 1.0, 0.8)
    f:SetFrameStrata("HIGH")
    window = f

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -10)
    title:SetText("|cff44AAFFArcUI|r ElemTempest Debug")

    local sub = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sub:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -28)
    sub:SetText("|cff888888Logs visibility state at key events + proc timeline|r")

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    local function Btn(lbl, px, fn)
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetSize(88, 22)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", px, -50)
        b:SetText(lbl)
        b:SetScript("OnClick", fn)
        return b
    end

    Btn("Clear", 10, function()
        log = {}; logDirty = true
        if logBox then logBox:SetText("") end
    end)

    Btn("State Now", 104, function()
        PushState("MANUAL CHECK")
        logDirty = true; RefreshLog()
    end)

    local pb = Btn("Pause", 198, nil)
    pb:SetScript("OnClick", function(self)
        paused = not paused
        self:SetText(paused and "|cffFF4444Resume|r" or "Pause")
    end)

    Btn("Export", 292, DoExport)

    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -80)
    scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -28, 10)

    local eb = CreateFrame("EditBox", nil, scroll)
    eb:SetMultiLine(true)
    eb:SetWidth(800)
    eb:SetAutoFocus(false)
    eb:SetFontObject(GameFontHighlightSmall)
    eb:SetScript("OnEscapePressed", function() f:Hide() end)
    scroll:SetScrollChild(eb)
    logBox = eb

    C_Timer.NewTicker(0.25, function()
        if f:IsShown() then RefreshLog() end
    end)

    DoExport()
end

local function EnableSilent()
    paused = false
    print("|cff44FF44ProcTracker:|r ElemTempest debug logging started. /pt etdebug to open.")
end

PT.ElemTempestDebug = {
    Toggle      = function()
        if window and window:IsShown() then window:Hide()
        else BuildWindow() end
    end,
    Export      = DoExport,
    StartSilent = EnableSilent,
}