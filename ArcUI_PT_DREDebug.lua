-- ArcUI_PT_DREDebug.lua
-- DRE Ascendance deck debugger.
-- Logs MSW consumes, SPELL_UPDATE_COOLDOWN events in window,
-- proc credits, and deck rollovers to confirm spellID for DRE proc detection.
-- Toggle: /pt dredebug
-- No pcall. Zero polling. Zero CPU when hidden.

local issecretvalue = issecretvalue

-- ── Constants ─────────────────────────────────────────────────────────────────
local DRE_SPELL_ID = 378270
local ASC_SPELL_ID = 114051
local MSW_ID       = 344179

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

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function TS()
    return string.format("%07.3f", GetTime() - sessionStart)
end

local COLOR = {
    msw_consume = "00FFFF",
    msw_gain    = "44FFBB",
    dre_gain    = "AA44FF",
    spell_cd    = "FFAA44",
    deck        = "00FFCC",
    rollover    = "FFFF44",
    violation   = "FF4444",
    info        = "888888",
    separator   = "444444",
}

local function Push(tag, detail, colorKey)
    if not enabled or paused then return end
    local col = COLOR[colorKey] or "CCCCCC"
    local ts  = TS()
    local line = string.format("|cff%s[%s] %-38s|r %s", col, ts, tag, detail or "")
    table.insert(log, line)
    if #log > MAX_LOG then table.remove(log, 1) end
    table.insert(rawLog, string.format("[%s] %-38s %s", ts, tag, (detail or ""):gsub("|c%x%x%x%x%x%x%x%x",""):gsub("|r","")))
    if #rawLog > 10000 then table.remove(rawLog, 1) end
    logDirty = true
end

-- ── Wire DRE deck debug callbacks ─────────────────────────────────────────────
local function WireDeckDebug()
    if not PT.DRE then return end
    PT.DRE.OnDebug = function(tag, detail)
        local colorKey = "info"
        if tag:find("PROC CREDITED") then colorKey = "dre_gain"
        elseif tag:find("ROLLOVER") then colorKey = "rollover"
        elseif tag:find("VIOLATION") then colorKey = "violation"
        elseif tag:find("MSW consume") then colorKey = "msw_consume"
        elseif tag:find("SPELL_UPDATE_CD") then colorKey = "spell_cd"
        elseif tag:find("DECK:") then colorKey = "deck"
        end
        Push(tag, detail, colorKey)
    end
    PT.DRE.OnProc = function(deckNum, deckProcs, totalGain, deckPos)
        Push("PROC", "deck#" .. deckNum .. " procs=" .. deckProcs .. "/2 gain#" .. totalGain .. " pos=" .. deckPos, "dre_gain")
    end
    PT.DRE.OnDeckRollover = function(newDeck, prevProcs, violation)
        local key = violation and "violation" or "rollover"
        Push("ROLLOVER", "→deck#" .. newDeck .. " prevProcs=" .. prevProcs .. "/2" .. (violation and " VIOLATION" or " clean"), key)
    end
end

local function UnwireDeckDebug()
    if not PT.DRE then return end
    PT.DRE.OnDebug        = nil
    PT.DRE.OnProc         = nil
    PT.DRE.OnDeckRollover = nil
end

-- ── Also log raw SPELL_UPDATE_COOLDOWN for DRE/Asc IDs globally ──────────────
-- This fires even outside a consume window so we can see ALL 378270/114051 events
local spellWatchFrame = CreateFrame("Frame")
local spellWatchActive = false
local function EnableSpellWatch()
    if spellWatchActive then return end
    spellWatchActive = true
    spellWatchFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
    spellWatchFrame:SetScript("OnEvent", function(_, _, sid)
        if not enabled or paused then return end
        if issecretvalue and issecretvalue(sid) then return end
        local id = tonumber(sid)
        if not id then return end
        if id == DRE_SPELL_ID then
            Push("SPELL_UPDATE_CD 378270 (DRE)", "fired globally", "spell_cd")
        elseif id == ASC_SPELL_ID then
            Push("SPELL_UPDATE_CD 114051 (Asc)", "fired globally", "spell_cd")
        end
    end)
end
local function DisableSpellWatch()
    if not spellWatchActive then return end
    spellWatchActive = false
    spellWatchFrame:UnregisterAllEvents()
    spellWatchFrame:SetScript("OnEvent", nil)
end

-- ── Also log MSW GAINED ───────────────────────────────────────────────────────
local mswLogFrame = CreateFrame("Frame")
local mswLogActive = false
local function EnableMSWLog()
    if mswLogActive then return end
    mswLogActive = true
    mswLogFrame:RegisterUnitEvent("UNIT_AURA", "player")
    mswLogFrame:SetScript("OnEvent", function(_, _, _, info)
        if not enabled or paused then return end
        if not info then return end
        if info.addedAuras then
            for _, aura in ipairs(info.addedAuras) do
                local sid = not (issecretvalue and issecretvalue(aura.spellId)) and tonumber(aura.spellId) or nil
                if sid == 344179 then
                    local apps = not (issecretvalue and issecretvalue(aura.applications)) and tonumber(aura.applications) or "?"
                    Push("UNIT_AURA  MSW GAINED", "instID=" .. tostring(aura.auraInstanceID) .. " apps=" .. tostring(apps), "msw_gain")
                end
            end
        end
    end)
end
local function DisableMSWLog()
    if not mswLogActive then return end
    mswLogActive = false
    mswLogFrame:UnregisterAllEvents()
    mswLogFrame:SetScript("OnEvent", nil)
end

-- ── UI ────────────────────────────────────────────────────────────────────────
local function BuildUI()
    if mainFrame then return end

    local f = CreateFrame("Frame", "ArcUI_PT_DREDebugFrame", UIParent, "BackdropTemplate")
    f:SetSize(820, 500)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetBackdrop({ bgFile="Interface\\Tooltips\\UI-Tooltip-Background", edgeFile="Interface\\Tooltips\\UI-Tooltip-Border", edgeSize=16, insets={left=4,right=4,top=4,bottom=4} })
    f:SetBackdropColor(0.05, 0.05, 0.1, 0.95)
    f:SetBackdropBorderColor(0.4, 0.2, 0.8, 1)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop",  f.StopMovingOrSizing)
    f:SetFrameStrata("HIGH")
    mainFrame = f

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -10)
    title:SetText("|cffAA44FFProcTracker|r DRE Debug")

    local sub = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sub:SetPoint("TOP", title, "BOTTOM", 0, -2)
    sub:SetText("|cff888888DRE_spellID=378270  Asc_spellID=114051  /pt dredebug to close|r")

    -- Buttons
    local function MakeBtn(label, x, onclick)
        local b = CreateFrame("Button", nil, f, "GameMenuButtonTemplate")
        b:SetSize(90, 22)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", x, -8)
        b:SetText(label)
        b:SetScript("OnClick", onclick)
        return b
    end

    MakeBtn("Clear", 10, function()
        log = {}; rawLog = {}; logDirty = true
        if logBox then logBox:SetText("") end
    end)

    MakeBtn("Pause", 105, function(self)
        paused = not paused
        self:SetText(paused and "Resume" or "Pause")
    end)

    MakeBtn("Copy Log", 200, function()
        if #rawLog == 0 then print("|cffAA44FFPT DREDebug:|r No log."); return end
        local eb2 = CreateFrame("EditBox", "ArcUI_PT_DREDebugCopy", UIParent, "InputBoxTemplate")
        eb2:SetSize(600, 400)
        eb2:SetPoint("CENTER")
        eb2:SetMultiLine(true)
        eb2:SetMaxLetters(0)
        eb2:SetAutoFocus(true)
        eb2:SetFontObject("GameFontHighlightSmall")
        eb2:SetText("=== PT_DRE_LOG ===\n" .. table.concat(rawLog, "\n") .. "\n=== END ===")
        eb2:HighlightText()
        eb2:Show()
        eb2:SetScript("OnEscapePressed", function(s) s:Hide() end)
    end)

    MakeBtn("Reset Deck", 295, function()
        if PT.DRE and PT.GetDeck then
            local entry = PT.GetDeck("dre")
            if entry and entry.OnReset then entry.OnReset() end
        end
        Push("──── RESET ────", "", "separator")
    end)

    -- Log box
    local sf = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -55)
    sf:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -28, 8)

    local eb = CreateFrame("EditBox", nil, sf)
    eb:SetSize(sf:GetWidth(), 1)
    eb:SetMultiLine(true)
    eb:SetMaxLetters(0)
    eb:SetAutoFocus(false)
    eb:SetFontObject("GameFontHighlightSmall")
    eb:SetScript("OnEscapePressed", function() f:Hide() end)
    sf:SetScrollChild(eb)
    logBox = eb

    -- Ticker
    f:SetScript("OnUpdate", function()
        if not logDirty or not mainFrame or not mainFrame:IsShown() then return end
        logBox:SetText(table.concat(log, "\n"))
        logDirty = false
    end)

    f:SetScript("OnHide", function()
        enabled = false
        DisableSpellWatch()
        DisableMSWLog()
        UnwireDeckDebug()
    end)

    -- Info line
    Push("──── SESSION START ────", "", "separator")
    Push("INFO", "DRE=378270  Asc=114051  MSW=344179  deck=333/2", "info")
end

-- ── Toggle ────────────────────────────────────────────────────────────────────
local function Toggle()
    if not mainFrame then BuildUI() end

    if mainFrame:IsShown() then
        mainFrame:Hide()
    else
        enabled = true
        EnableSpellWatch()
        EnableMSWLog()
        WireDeckDebug()
        Push("──── SESSION START ────", "", "separator")
        Push("INFO", "DRE=378270  Asc=114051  MSW=344179  deck=333/2", "info")
        mainFrame:Show()
    end
end

-- ── Slash command ─────────────────────────────────────────────────────────────
-- Hooked into /pt dispatch in Core
ArcUI_PT_DREDebug = {
    Toggle = Toggle,
}

-- Register with PT slash dispatch if already loaded
if PT and PT.SlashHandlers then
    PT.SlashHandlers["dredebug"] = function() Toggle() end
end
