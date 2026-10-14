local ADDON, PT = ...   -- private namespace, shared with Core (never the global PT)
-- ArcUI_PT_Moving.lua
-- ProcTracker is now part of Arc Auras. This last version still tracks, and
-- points the player there: a notice at each login while Arc Auras is not
-- loaded, and an Arc Auras tab first in the options. With Arc Auras loaded it
-- stays quiet: Arc Auras asks which trackers to bring over, and switches
-- each imported one off here so nothing shows twice.

local MV = {}
PT.Moving = MV

local LINK = "https://www.curseforge.com/wow/addons/arc-auras"
local ICON = "Interface\\AddOns\\ArcUI_ProcTracker\\Textures\\ArcAuras_Icon"
local CYAN = { 0.25, 0.79, 0.95 }
local DEEP = { 0.10, 0.44, 0.62 }
local LINE = { 0.16, 0.24, 0.33 }

local notice

function MV.ArcAurasLoaded()
    local A = C_AddOns
    return A ~= nil and A.IsAddOnLoaded ~= nil and A.IsAddOnLoaded("ArcAuras") == true
end

-- Where Arc Auras stands: "loaded"; "off" (installed, switched off for this
-- character); "broken" (installed and on, yet it did not load: out of date or
-- a load error); "missing" (not installed). Its download can arrive without
-- it loading, so "off" must never be told to download what it already has.
function MV.ArcAurasState()
    if MV.ArcAurasLoaded() then return "loaded" end
    local A = C_AddOns
    if not (A and A.DoesAddOnExist and A.DoesAddOnExist("ArcAuras")) then return "missing" end
    local me = UnitName and UnitName("player") or nil
    local on = A.GetAddOnEnableState and A.GetAddOnEnableState("ArcAuras", me) or 0
    if on == 0 then return "off" end
    return "broken"
end

-- What the notice and the tab say in each state.
MV.WORDS = {
    missing = "This is the last ProcTracker update. Arc Auras tracks the same procs and more, with more looks, glows and sounds. Install it and it brings your trackers over, in the same places with the same looks.",
    off = "This is the last ProcTracker update. Arc Auras is installed but switched off. Turn it on to bring your trackers over, in the same places with the same looks.",
    broken = "This is the last ProcTracker update. Arc Auras is installed but could not load. Update it to the latest version and it brings your trackers over, in the same places with the same looks.",
}

-- Switches Arc Auras on (every character, as the addon list's own tick does
-- for "All") and reloads so it loads; its move window asks next.
function MV.TurnOnArcAuras()
    local A = C_AddOns
    if not (A and A.EnableAddOn) then return end
    A.EnableAddOn("ArcAuras")
    if ReloadUI then ReloadUI() end
end

local function Skin(f, r, g, b, er, eg, eb)
    f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    f:SetBackdropColor(r, g, b, 1)
    f:SetBackdropBorderColor(er, eg, eb, 1)
end

-- Built once, on first show.
local function BuildNotice()
    local f = CreateFrame("Frame", "ArcUIProcTrackerMovingNotice", UIParent, "BackdropTemplate")
    f:SetSize(460, 214)
    f:SetPoint("CENTER", 0, 140)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    Skin(f, 0.06, 0.09, 0.15, CYAN[1], CYAN[2], CYAN[3])
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    -- Escape closes it like any other window.
    tinsert(UISpecialFrames, "ArcUIProcTrackerMovingNotice")

    local logo = f:CreateTexture(nil, "ARTWORK")
    logo:SetSize(56, 56)
    logo:SetPoint("TOPLEFT", 16, -16)
    logo:SetTexture(ICON)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", logo, "TOPRIGHT", 12, -2)
    title:SetTextColor(CYAN[1], CYAN[2], CYAN[3])
    title:SetText("ArcUI ProcTracker is now part of Arc Auras")

    local body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    body:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    body:SetPoint("RIGHT", f, "RIGHT", -18, 0)
    body:SetJustifyH("LEFT")
    f.body = body

    local box = CreateFrame("EditBox", nil, f, "BackdropTemplate")
    box:SetSize(320, 24)
    box:SetPoint("BOTTOMLEFT", 18, 50)
    Skin(box, 0.04, 0.06, 0.10, LINE[1], LINE[2], LINE[3])
    box:SetFontObject(ChatFontNormal)
    box:SetTextInsets(8, 8, 0, 0)
    box:SetAutoFocus(false)
    box:SetText(LINK)
    box:SetCursorPosition(0)
    -- The box only holds the link for copying, so typing can't change it.
    box:SetScript("OnTextChanged", function(self, userInput)
        if userInput then
            self:SetText(LINK)
            self:HighlightText()
        end
    end)
    box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 2, -6)
    hint:SetText("Click the link, then press Ctrl+C to copy it.")
    f.box, f.hint = box, hint

    local function Button(text, w, onClick)
        local b = CreateFrame("Button", nil, f, "BackdropTemplate")
        b:SetSize(w, 24)
        Skin(b, 0.10, 0.15, 0.22, DEEP[1], DEEP[2], DEEP[3])
        local label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        label:SetPoint("CENTER")
        label:SetText(text)
        b.label = label
        b:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(CYAN[1], CYAN[2], CYAN[3], 1) end)
        b:SetScript("OnLeave", function(self) self:SetBackdropBorderColor(DEEP[1], DEEP[2], DEEP[3], 1) end)
        b:SetScript("OnClick", onClick)
        return b
    end
    local close = Button("Got it", 96, function() f:Hide() end)
    close:SetPoint("BOTTOMRIGHT", -18, 18)
    -- installed but switched off: one click turns it on, in place of the link
    local turnOn = Button("Turn on Arc Auras", 150, function() MV.TurnOnArcAuras() end)
    turnOn:SetPoint("RIGHT", close, "LEFT", -8, 0)
    f.close, f.turnOn = close, turnOn

    return f
end

-- The words and the way forward for where Arc Auras stands right now.
function MV.PaintNotice()
    if not notice then return end
    local state = MV.ArcAurasState()
    notice.body:SetText(MV.WORDS[state] or MV.WORDS.missing)
    local off = state == "off"
    notice.box:SetShown(not off)
    notice.hint:SetShown(not off)
    notice.turnOn:SetShown(off)
end

function MV.ShowNotice()
    notice = notice or BuildNotice()
    MV.PaintNotice()
    notice:Show()
end

-- The options tab, first in the row (Core adds it). Without Arc Auras it says
-- where to get it, or turns it on when it is installed but switched off; with
-- Arc Auras loaded it opens Arc Auras' import.
function MV.BuildOptionsTab(order)
    local function there() return MV.ArcAurasLoaded() end
    local function missing() return not MV.ArcAurasLoaded() end
    local function noLink()
        local s = MV.ArcAurasState()
        return s == "loaded" or s == "off"
    end
    local function notOff() return MV.ArcAurasState() ~= "off" end
    return {
        type  = "group",
        name  = "Arc Auras",
        order = order,
        args  = {
            head = {
                type = "header", order = 1,
                name = "ProcTracker is now part of Arc Auras",
            },
            gone = {
                type = "description", order = 2, fontSize = "medium", hidden = there,
                name = function() return MV.WORDS[MV.ArcAurasState()] or MV.WORDS.missing end,
            },
            get = {
                type = "execute", order = 3, width = 1.2, hidden = noLink,
                name = "Get Arc Auras",
                desc = "Shows the download link to copy.",
                func = function() MV.ShowNotice() end,
            },
            turnOn = {
                type = "execute", order = 3.5, width = 1.4, hidden = notOff,
                name = "Turn on Arc Auras",
                desc = "Switches Arc Auras on and reloads, so it can bring your trackers over.",
                func = function() MV.TurnOnArcAuras() end,
            },
            here = {
                type = "description", order = 4, fontSize = "medium", hidden = missing,
                name = "Arc Auras is installed: it asks at login which trackers to bring over. They arrive in the same places with the same looks, and switch off here so nothing shows twice.",
            },
            import = {
                type = "execute", order = 5, width = 1.6, hidden = missing,
                name = "Open the import in Arc Auras",
                func = function()
                    local open = SlashCmdList and SlashCmdList.ARCUIVTWO
                    if open then open("proctracker") end
                end,
            },
        },
    }
end

-- A real login only: a /reload or a loading screen never brings it back.
local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:SetScript("OnEvent", function(self, _, isInitialLogin)
    self:UnregisterEvent("PLAYER_ENTERING_WORLD")
    if isInitialLogin ~= true or MV.ArcAurasLoaded() then return end
    -- Entering the world closes every Escape-closable window, so open it after.
    C_Timer.After(1, MV.ShowNotice)
end)
