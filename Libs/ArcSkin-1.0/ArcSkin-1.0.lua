-- ===================================================================
-- ArcSkin-1.0 — the shared Arc options-panel library.
-- The look and row engine are a direct port of the Arc Ping Feed
-- standalone panel (Arc's approved template): navy window, title bar
-- with version, underlined tab strip, striped full-width rows (label
-- left / control right), uppercase hairline sections, pill switches,
-- slider + [-][value][+] rows, windowed scrolling dropdowns.
--
-- On top of that sits an ACECONFIG RENDERER: it reads a standard
-- AceConfig options table (get/set/hidden/order/args untouched — zero
-- option re-declaration) and draws it with those rows.
--   skin:OpenOptions(appName, optionsTable, opts)
--   skin:ToggleOptions(appName, optionsTable, opts)
--   skin:Refresh(appName)
-- opts: { title, version, width, height, selectTab }
--
-- Consumers: ArcUI_ProcTracker (first), ArcUI (Arc 2.0), future Arc
-- addons. No pcall. Zero idle CPU (everything click/event driven).
-- ===================================================================
local MAJOR, MINOR = "ArcSkin-1.0", 5
local AS = LibStub:NewLibrary(MAJOR, MINOR)
if not AS then return end

-- ── palette (the Arc Ping Feed panel look) ──────────────────────────
AS.COL = {
    bg      = { 0.043, 0.059, 0.102 },
    panel   = { 0.063, 0.094, 0.153 },
    well    = { 0.039, 0.067, 0.125 },
    line    = { 0.114, 0.165, 0.247 },
    line2   = { 0.165, 0.231, 0.341 },
    box     = { 0.055, 0.078, 0.130 },  -- section container fill, a step up from bg
    ink     = { 0.950, 0.970, 1.000 },  -- near-white primary labels
    dim     = { 0.700, 0.780, 0.880 },  -- readable secondary
    faint   = { 0.550, 0.650, 0.780 },
    arc     = { 0.247, 0.788, 0.949 },  -- Arc cyan accent
    arcDeep = { 0.078, 0.353, 0.451 },
}
local COL = AS.COL
local WHITE = "Interface\\Buttons\\WHITE8X8"
local ROW_H = 24   -- matches the locked KA template (was 26)

local function Skin(f, bg, borderCol)
    f:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    f:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 1)
    local b = borderCol or COL.line
    f:SetBackdropBorderColor(b[1], b[2], b[3], 1)
end
AS.Skin = Skin

-- ── AceConfig helpers ───────────────────────────────────────────────
local windows = {}   -- appName -> win

local function callv(v, info, ...)
    if type(v) == "function" then return v(info, ...) end
    return v
end

local function optSorted(args)
    local list = {}
    for key, opt in pairs(args) do
        if type(opt) == "table" then list[#list + 1] = { key = key, opt = opt } end
    end
    table.sort(list, function(a, b)
        local oa = tonumber(a.opt.order) or 100
        local ob = tonumber(b.opt.order) or 100
        if oa ~= ob then return oa < ob end
        return a.key < b.key
    end)
    return list
end

local function mkinfo(win, key, opt)
    -- minimal AceConfig info: Arc addons' handlers use closures and at most
    -- read info.arg, so positional path + named extras is enough
    return { key, appName = win.appName, option = opt, arg = opt.arg }
end

-- ── per-window dropdown management ──────────────────────────────────
local function CloseDropdown(win)
    if win.openDropdown then win.openDropdown:Hide(); win.openDropdown = nil end
end

-- ── small controls (exact template ports) ───────────────────────────
local function MakeSwitch(parent)
    -- SLIDING pill toggle with fully ROUNDED ends (Arc's call: keep the
    -- left/right slide, make the outline circular): the track is a capsule
    -- (two masked half-circles + middle), the knob a circle that slides
    local s = CreateFrame("Button", nil, parent)
    s:SetSize(28, 14)
    local function circle(tex)
        local m = s:CreateMaskTexture()
        m:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        m:SetAllPoints(tex)
        tex:AddMaskTexture(m)
    end
    local function pillTex(layer, h, inset)
        local capL = s:CreateTexture(nil, layer)
        capL:SetTexture(WHITE); capL:SetSize(h, h); capL:SetPoint("LEFT", inset, 0); circle(capL)
        local capR = s:CreateTexture(nil, layer)
        capR:SetTexture(WHITE); capR:SetSize(h, h); capR:SetPoint("RIGHT", -inset, 0); circle(capR)
        local mid = s:CreateTexture(nil, layer)
        mid:SetTexture(WHITE)
        mid:SetPoint("TOPLEFT", capL, "TOP", 0, 0)
        mid:SetPoint("BOTTOMRIGHT", capR, "BOTTOM", 0, 0)
        local texs = { capL, capR, mid }
        return { SetColor = function(_, r, g, b, a)
            for i = 1, 3 do texs[i]:SetVertexColor(r, g, b, a or 1) end
        end }
    end
    s.border = pillTex("BACKGROUND", 14, 0)   -- capsule outline
    s.fill   = pillTex("BORDER", 12, 1)       -- capsule inner fill
    s.knob = s:CreateTexture(nil, "OVERLAY")
    s.knob:SetTexture(WHITE)
    s.knob:SetSize(10, 10)
    circle(s.knob)
    function s:SetOn(on)
        self.knob:ClearAllPoints()
        if on then
            self.border:SetColor(COL.arcDeep[1], COL.arcDeep[2], COL.arcDeep[3], 1)
            self.fill:SetColor(COL.arc[1] * 0.22, COL.arc[2] * 0.22, COL.arc[3] * 0.22, 1)
            self.knob:SetPoint("RIGHT", -2, 0)
            self.knob:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 1)
        else
            self.border:SetColor(COL.line[1], COL.line[2], COL.line[3], 1)
            self.fill:SetColor(COL.well[1], COL.well[2], COL.well[3], 1)
            self.knob:SetPoint("LEFT", 2, 0)
            self.knob:SetVertexColor(COL.faint[1], COL.faint[2], COL.faint[3], 1)
        end
    end
    return s
end

local function MakeSwatch(parent, w, h)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(w or 24, h or 14)
    Skin(b, COL.well)
    b.tex = b:CreateTexture(nil, "OVERLAY")
    b.tex:SetTexture(WHITE)
    b.tex:SetPoint("TOPLEFT", 1, -1)
    b.tex:SetPoint("BOTTOMRIGHT", -1, 1)
    function b:SetColor(r, g, bb) self.tex:SetVertexColor(r, g, bb, 1) end
    b:SetScript("OnEnter", function() b:SetBackdropBorderColor(COL.arcDeep[1], COL.arcDeep[2], COL.arcDeep[3], 1) end)
    b:SetScript("OnLeave", function() b:SetBackdropBorderColor(COL.line[1], COL.line[2], COL.line[3], 1) end)
    return b
end

local BTN_FILL   = { 0.110, 0.161, 0.243 }   -- KA navy-blue button fill
local BTN_BORDER = { 0.298, 0.400, 0.549 }   -- steel border
local BTN_HOVER  = { 0.150, 0.205, 0.295 }   -- lighter on hover
local function MakeSmallButton(parent, label, w)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(w or 92, 22)
    Skin(b, BTN_FILL, BTN_BORDER)
    b.fs = b:CreateFontString(nil, "OVERLAY")
    b.fs:SetFont(STANDARD_TEXT_FONT, 11, "")
    b.fs:SetPoint("CENTER")
    b.fs:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
    b.fs:SetText(label or "")
    b:SetScript("OnEnter", function()
        b:SetBackdropColor(BTN_HOVER[1], BTN_HOVER[2], BTN_HOVER[3], 1)
        b:SetBackdropBorderColor(COL.arc[1], COL.arc[2], COL.arc[3], 1)
    end)
    b:SetScript("OnLeave", function()
        b:SetBackdropColor(BTN_FILL[1], BTN_FILL[2], BTN_FILL[3], 1)
        b:SetBackdropBorderColor(BTN_BORDER[1], BTN_BORDER[2], BTN_BORDER[3], 1)
    end)
    return b
end

-- WoW-style square checkbox (the Arc theme toggle): navy box + a cyan checkmark when on.
-- Same as Kick Assist: constant box, clean "checkmark-minimal" atlas desaturated + tinted cyan,
-- slightly overhanging the box, with a hover glow.
local function MakeCheckbox(parent)
    local c = CreateFrame("Button", nil, parent, "BackdropTemplate")
    c:SetSize(18, 18); Skin(c, COL.well, COL.line2)
    c.check = c:CreateTexture(nil, "OVERLAY")
    c.check:SetAtlas("checkmark-minimal"); c.check:SetDesaturated(true)
    c.check:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 1)
    c.check:SetSize(20, 20); c.check:SetPoint("CENTER", 0, 0); c.check:Hide()
    c._glow = c:CreateTexture(nil, "ARTWORK")
    c._glow:SetTexture("Interface\\Buttons\\ButtonHilight-Square"); c._glow:SetBlendMode("ADD")
    c._glow:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 0.55)
    c._glow:SetPoint("TOPLEFT", -3, 3); c._glow:SetPoint("BOTTOMRIGHT", 3, -3); c._glow:Hide()
    function c:SetHover(on) self._glow:SetShown(on and true or false) end
    function c:SetOn(on) self.check:SetShown(on and true or false) end
    return c
end

-- tooltip attach (desc -> GameTooltip on hover, template-consistent)
local function AttachTip(region, getTitle, getBody)
    region:HookScript("OnEnter", function(self)
        local body = getBody and getBody()
        if not body or body == "" then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(getTitle and getTitle() or "", 1, 1, 1)
        GameTooltip:AddLine(body, 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    region:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

-- ── row factory ─────────────────────────────────────────────────────
-- Rows are pooled per kind on the window; each row is a full-width frame
-- with the stripe texture, a left label, and its control on the right.

local function NewRow(win, withLabel)
    local row = CreateFrame("Frame", nil, win.content)
    row:SetHeight(ROW_H)
    row._stripe = row:CreateTexture(nil, "BACKGROUND")
    row._stripe:SetTexture(WHITE)
    row._stripe:SetVertexColor(1, 1, 1, 0.03)
    row._stripe:SetAllPoints()
    if withLabel then
        row.label = row:CreateFontString(nil, "OVERLAY")
        row.label:SetFont(STANDARD_TEXT_FONT, 12, "")
        row.label:SetPoint("LEFT", 12, 0)
        row.label:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
        row.label:SetWordWrap(false)
        row.label:SetJustifyH("LEFT")
    end
    return row
end

local builders = {}

-- section header (AceConfig "header"): uppercase dim label + hairline
builders.section = function(win)
    local row = CreateFrame("Frame", nil, win.content)
    row:SetHeight(24)
    row._isSection = true
    row.label = row:CreateFontString(nil, "OVERLAY")
    row.label:SetFont(STANDARD_TEXT_FONT, 10, "")
    row.label:SetPoint("BOTTOMLEFT", 10, 5)
    row.label:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
    row.line = row:CreateTexture(nil, "ARTWORK")
    row.line:SetTexture(WHITE)
    row.line:SetVertexColor(COL.line[1], COL.line[2], COL.line[3], 0.8)
    row.line:SetPoint("BOTTOMLEFT", row.label, "BOTTOMRIGHT", 8, 2)
    row.line:SetPoint("RIGHT", row, "RIGHT", -10, 0)
    row.line:SetHeight(1)
    return row
end

-- collapsible section (dialogControl="CollapsibleHeader" toggles):
-- section look + chevron glyph; the option's get/set holds collapsed state
builders.collapse = function(win)
    local row = CreateFrame("Button", nil, win.content)
    row:SetHeight(24)
    row._isSection = true
    -- drawn chevron (two rotated bars): points right when collapsed,
    -- down when expanded
    local chev = CreateFrame("Frame", nil, row)
    chev:SetSize(12, 12)
    chev:SetPoint("BOTTOMLEFT", 8, 3)
    local c1 = chev:CreateTexture(nil, "OVERLAY")
    c1:SetTexture(WHITE); c1:SetSize(7, 1.5)
    c1:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 1)
    local c2 = chev:CreateTexture(nil, "OVERLAY")
    c2:SetTexture(WHITE); c2:SetSize(7, 1.5)
    c2:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 1)
    row.SetChevron = function(_, collapsed)
        c1:ClearAllPoints(); c2:ClearAllPoints()
        if collapsed then
            c1:SetPoint("CENTER", 0.5, 2); c1:SetRotation(math.rad(50))
            c2:SetPoint("CENTER", 0.5, -2); c2:SetRotation(math.rad(-50))
        else
            c1:SetPoint("CENTER", -2, 0.5); c1:SetRotation(math.rad(-50))
            c2:SetPoint("CENTER", 2, 0.5); c2:SetRotation(math.rad(50))
        end
    end
    row.label = row:CreateFontString(nil, "OVERLAY")
    row.label:SetFont(STANDARD_TEXT_FONT, 10, "")
    row.label:SetPoint("BOTTOMLEFT", 24, 5)
    row.label:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
    row.line = row:CreateTexture(nil, "ARTWORK")
    row.line:SetTexture(WHITE)
    row.line:SetVertexColor(COL.line[1], COL.line[2], COL.line[3], 0.8)
    row.line:SetPoint("BOTTOMLEFT", row.label, "BOTTOMRIGHT", 8, 2)
    row.line:SetPoint("RIGHT", row, "RIGHT", -10, 0)
    row.line:SetHeight(1)
    row:SetScript("OnClick", function(self) if self.onClick then self.onClick(self) end end)
    row:SetScript("OnEnter", function(self) self.label:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3]) end)
    row:SetScript("OnLeave", function(self) self.label:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3]) end)
    return row
end

-- description: dim wrapped text (variable height)
builders.desc = function(win)
    local row = CreateFrame("Frame", nil, win.content)
    row.text = row:CreateFontString(nil, "OVERLAY")
    row.text:SetFont(STANDARD_TEXT_FONT, 11, "")
    row.text:SetPoint("TOPLEFT", 12, -4)
    row.text:SetJustifyH("LEFT")
    row.text:SetJustifyV("TOP")
    row.text:SetWordWrap(true)
    row.text:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
    return row
end

-- toggle: pill switch right, whole row clickable
builders.toggle = function(win)
    local row = NewRow(win, true)
    row.sw = MakeCheckbox(row)
    -- Provisional placement, label-relative. renderRows then lines every checkbox
    -- in the block up on ONE shared column just past the widest label: pinned to
    -- the far right (the old behaviour) the box drifted away from the word it
    -- belongs to, which is exactly what the locked Arc template forbids.
    row.sw:SetPoint("LEFT", row.label, "RIGHT", 14, 0)
    row._colLabel, row._colCtrl = row.label, row.sw
    local function flip()
        local wasOn = row.sw.check:IsShown()
        if row.onFlip then row.onFlip() end
        PlaySound((not wasOn) and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
    end
    row.sw:SetScript("OnClick", flip)
    row:EnableMouse(true)
    row:SetScript("OnMouseUp", flip)
    row:HookScript("OnEnter", function() row.sw:SetHover(true) end)
    row:HookScript("OnLeave", function() row.sw:SetHover(false) end)
    row.sw:HookScript("OnEnter", function() row.sw:SetHover(true) end)
    row.sw:HookScript("OnLeave", function() row.sw:SetHover(false) end)
    AttachTip(row, function() return row.label:GetText() end, function() return row.tip end)
    return row
end

-- range: slider + [-] typed value box [+]
builders.range = function(win)
    local row = NewRow(win, true)
    row.min, row.max, row.step = 0, 100, 1
    local settingUp = false
    local function fmt(v)
        if row.isPct then return ("%.0f"):format(v * 100)
        elseif (row.step or 1) < 1 then return ("%.1f"):format(v)
        else return ("%d"):format(v) end
    end
    local function clamp(v)
        if v < row.min then v = row.min elseif v > row.max then v = row.max end
        if row.step >= 1 then v = math.floor(v + 0.5) end
        return v
    end
    local function setVal(v)
        if row.onCommit then row.onCommit(clamp(v)) end
    end
    local function MkArrow(glyph, dir)
        local b = CreateFrame("Button", nil, row, "BackdropTemplate")
        b:SetSize(14, 14)
        Skin(b, COL.well)
        local g = b:CreateFontString(nil, "OVERLAY")
        g:SetFont(STANDARD_TEXT_FONT, 11, "")
        g:SetPoint("CENTER", 0, 0)
        g:SetTextColor(COL.arc[1], COL.arc[2], COL.arc[3])
        g:SetText(glyph)
        b:SetScript("OnClick", function()
            CloseDropdown(win)
            setVal((row.getCur and row.getCur() or row.min) + dir * (row.step or 1))
        end)
        b:SetScript("OnEnter", function() b:SetBackdropBorderColor(COL.arcDeep[1], COL.arcDeep[2], COL.arcDeep[3], 1) end)
        b:SetScript("OnLeave", function() b:SetBackdropBorderColor(COL.line[1], COL.line[2], COL.line[3], 1) end)
        return b
    end
    local plusB = MkArrow("+", 1)
    plusB:SetPoint("RIGHT", -12, 0)
    local box = CreateFrame("EditBox", nil, row, "BackdropTemplate")
    box:SetSize(38, 16)
    box:SetPoint("RIGHT", plusB, "LEFT", -2, 0)
    Skin(box, COL.well)
    box:SetFont(STANDARD_TEXT_FONT, 11, "")
    box:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
    box:SetJustifyH("CENTER")
    box:SetAutoFocus(false)
    row.box = box
    local function commitTyped(self)
        local n = tonumber(self:GetText())
        if n then
            if row.isPct then n = n / 100 end
            setVal(n)
        elseif row.getCur then
            self:SetText(fmt(row.getCur()))
        end
    end
    box:SetScript("OnEnterPressed", function(self) commitTyped(self); self:ClearFocus() end)
    box:SetScript("OnEditFocusLost", commitTyped)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    local minusB = MkArrow("-", -1)
    minusB:SetPoint("RIGHT", box, "LEFT", -2, 0)
    local s = CreateFrame("Slider", nil, row, "BackdropTemplate")
    s:SetOrientation("HORIZONTAL")
    s:SetSize(110, 10)
    s:SetPoint("RIGHT", minusB, "LEFT", -8, 0)
    row.label:SetPoint("RIGHT", s, "LEFT", -8, 0)
    Skin(s, COL.well)
    s:SetThumbTexture(WHITE)
    local th = s:GetThumbTexture()
    th:SetSize(8, 10)
    th:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 1)
    row.slider = s
    s:SetScript("OnValueChanged", function(_, v)
        if settingUp then return end
        if row.step >= 1 then v = math.floor(v + 0.5) end
        if not box:HasFocus() then box:SetText(fmt(v)) end
        -- live while dragging: commit WITHOUT rerender (template behavior)
        if row.onLive then row.onLive(v) end
    end)
    row.Configure = function(self, mn, mx, st, isPct)
        self.min, self.max, self.step, self.isPct = mn or 0, mx or 100, st or 1, isPct
        settingUp = true
        s:SetMinMaxValues(self.min, self.max)
        s:SetValueStep(self.step > 0 and self.step or 0.001)
        s:SetObeyStepOnDrag(self.step > 0)
        settingUp = false
    end
    row.SetCurrent = function(self, v)
        settingUp = true
        if type(v) == "number" then s:SetValue(v); box:SetText(fmt(v)) else box:SetText("") end
        settingUp = false
    end
    AttachTip(row, function() return row.label:GetText() end, function() return row.tip end)
    return row
end

-- select: 160px field + windowed scrolling pullout (12 rows)
builders.select = function(win)
    local row = NewRow(win, true)
    local b = CreateFrame("Button", nil, row, "BackdropTemplate")
    b:SetSize(160, 20)
    b:SetPoint("RIGHT", -12, 0)
    row.label:SetPoint("RIGHT", b, "LEFT", -8, 0)
    Skin(b, COL.well)
    row.field = b
    local vf = b:CreateFontString(nil, "OVERLAY")
    vf:SetFont(STANDARD_TEXT_FONT, 11, "")
    vf:SetPoint("LEFT", 8, 0)
    vf:SetPoint("RIGHT", -14, 0)
    vf:SetJustifyH("LEFT")
    vf:SetWordWrap(false)
    vf:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
    row.valueText = vf
    -- drawn chevron (two rotated bars), not a text glyph
    local arrow = CreateFrame("Frame", nil, b)
    arrow:SetSize(12, 12)
    arrow:SetPoint("RIGHT", -5, 0)
    local a1 = arrow:CreateTexture(nil, "OVERLAY")
    a1:SetTexture(WHITE)
    a1:SetSize(7, 1.5)
    a1:SetPoint("CENTER", -2, 0.5)
    a1:SetRotation(math.rad(-50))
    a1:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 1)
    local a2 = arrow:CreateTexture(nil, "OVERLAY")
    a2:SetTexture(WHITE)
    a2:SetSize(7, 1.5)
    a2:SetPoint("CENTER", 2, 0.5)
    a2:SetRotation(math.rad(50))
    a2:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 1)

    local VISROWS = 12
    local list = CreateFrame("Frame", nil, win.frame, "BackdropTemplate")
    list:SetFrameLevel(win.frame:GetFrameLevel() + 30)
    list:SetWidth(160)
    Skin(list, COL.panel, COL.arcDeep)
    list:Hide()
    row.list = list
    local items = {}
    for i = 1, VISROWS do
        local it = CreateFrame("Button", nil, list)
        it:SetPoint("TOPLEFT", 1, -1 - (i - 1) * 20)
        it:SetPoint("TOPRIGHT", -1, -1 - (i - 1) * 20)
        it:SetHeight(20)
        local hl = it:CreateTexture(nil, "HIGHLIGHT")
        hl:SetTexture(WHITE)
        hl:SetVertexColor(COL.arcDeep[1], COL.arcDeep[2], COL.arcDeep[3], 0.5)
        hl:SetAllPoints()
        it.fs = it:CreateFontString(nil, "OVERLAY")
        it.fs:SetFont(STANDARD_TEXT_FONT, 11, "")
        it.fs:SetPoint("LEFT", 8, 0)
        it.fs:SetPoint("RIGHT", -4, 0)
        it.fs:SetJustifyH("LEFT")
        it.fs:SetWordWrap(false)
        it.fs:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
        it.idx = i
        it:SetScript("OnClick", function(self)
            local v = row.values and row.values[row.offset + self.idx]
            if not v then return end
            CloseDropdown(win)
            if row.onPick then row.onPick(v.key) end
        end)
        items[i] = it
    end
    row.items = items
    row.offset = 0
    local function refreshList()
        local vis = math.min(#(row.values or {}), VISROWS)
        for i = 1, VISROWS do
            local v = row.values and row.values[row.offset + i]
            items[i].fs:SetText(v and v.label or "")
            items[i]:SetShown(i <= vis)
        end
    end
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        local maxOff = math.max(0, #(row.values or {}) - VISROWS)
        row.offset = row.offset - delta * 3
        if row.offset < 0 then row.offset = 0 elseif row.offset > maxOff then row.offset = maxOff end
        refreshList()
    end)
    b:SetScript("OnClick", function()
        if win.openDropdown == list then CloseDropdown(win) return end
        CloseDropdown(win)
        local vals = row.values or {}
        local vis = math.min(#vals, VISROWS)
        if vis == 0 then return end
        row.offset = 0
        for i, v in ipairs(vals) do
            if v.key == row.current then row.offset = math.max(0, math.min(i - 1, #vals - vis)) break end
        end
        refreshList()
        list:SetHeight(vis * 20 + 2)
        list:ClearAllPoints()
        list:SetPoint("TOPRIGHT", b, "BOTTOMRIGHT", 0, -1)
        list:Show()
        win.openDropdown = list
    end)
    b:SetScript("OnEnter", function() b:SetBackdropBorderColor(COL.arcDeep[1], COL.arcDeep[2], COL.arcDeep[3], 1) end)
    b:SetScript("OnLeave", function() b:SetBackdropBorderColor(COL.line[1], COL.line[2], COL.line[3], 1) end)
    AttachTip(row, function() return row.label:GetText() end, function() return row.tip end)
    return row
end

-- color: swatch right
builders.color = function(win)
    local row = NewRow(win, true)
    row.sw = MakeSwatch(row)
    row.sw:SetPoint("RIGHT", -12, 0)
    row.label:SetPoint("RIGHT", row.sw, "LEFT", -8, 0)
    row.sw:SetScript("OnClick", function()
        CloseDropdown(win)
        if row.onPickColor then row.onPickColor() end
    end)
    AttachTip(row, function() return row.label:GetText() end, function() return row.tip end)
    return row
end

-- execute: small button on the left (template RowButton)
builders.execute = function(win)
    local row = CreateFrame("Frame", nil, win.content)
    row:SetHeight(ROW_H)
    row._stripe = row:CreateTexture(nil, "BACKGROUND")
    row._stripe:SetTexture(WHITE)
    row._stripe:SetVertexColor(1, 1, 1, 0.03)
    row._stripe:SetAllPoints()
    row.btn = MakeSmallButton(row, "", 160)
    row.btn:SetPoint("LEFT", 12, 0)
    row.btn:SetScript("OnClick", function()
        CloseDropdown(win)
        if row.onExec then row.onExec() end
    end)
    AttachTip(row.btn, function() return row.btn.fs:GetText() end, function() return row.tip end)
    return row
end

-- input: 160px editbox right, commits on Enter
builders.input = function(win)
    local row = NewRow(win, true)
    local eb = CreateFrame("EditBox", nil, row, "BackdropTemplate")
    eb:SetSize(160, 18)
    eb:SetPoint("RIGHT", -12, 0)
    row.label:SetPoint("RIGHT", eb, "LEFT", -8, 0)
    Skin(eb, COL.well)
    eb:SetFont(STANDARD_TEXT_FONT, 11, "")
    eb:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
    eb:SetTextInsets(6, 6, 0, 0)
    eb:SetAutoFocus(false)
    eb:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        if row.onCommit then row.onCommit(self:GetText()) end
    end)
    eb:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        if row.getCur then self:SetText(row.getCur() or "") end
    end)
    eb:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(COL.arcDeep[1], COL.arcDeep[2], COL.arcDeep[3], 1) end)
    eb:SetScript("OnLeave", function(self) self:SetBackdropBorderColor(COL.line[1], COL.line[2], COL.line[3], 1) end)
    row.box = eb
    AttachTip(row, function() return row.label:GetText() end, function() return row.tip end)
    return row
end

-- ── pooling ─────────────────────────────────────────────────────────
local function acquire(win, kind)
    local pool = win.pools[kind]
    if not pool then pool = { n = 0, items = {} }; win.pools[kind] = pool end
    pool.n = pool.n + 1
    local row = pool.items[pool.n]
    if not row then
        row = builders[kind](win)
        pool.items[pool.n] = row
    end
    row:Show()
    return row
end

local function resetPools(win)
    for _, pool in pairs(win.pools) do
        for i = 1, pool.n do
            local row = pool.items[i]
            row:Hide()
            row:ClearAllPoints()
        end
        pool.n = 0
    end
    CloseDropdown(win)
end

-- ── the color picker plumbing (standard Ace color get/set) ──────────
local function OpenColorPicker(row, opt, info, win)
    local r0, g0, b0, a0 = 1, 1, 1, 1
    if opt.get then r0, g0, b0, a0 = opt.get(info) end
    local function commit()
        local nr, ng, nb = ColorPickerFrame:GetColorRGB()
        local na = 1
        if opt.hasAlpha and ColorPickerFrame.GetColorAlpha then na = ColorPickerFrame:GetColorAlpha() end
        if opt.set then opt.set(info, nr, ng, nb, na) end
        row.sw:SetColor(nr, ng, nb)
    end
    local function cancel()
        if opt.set then opt.set(info, r0, g0, b0, a0) end
        row.sw:SetColor(r0 or 1, g0 or 1, b0 or 1)
        AS:Refresh(win.appName)
    end
    if ColorPickerFrame.SetupColorPickerAndShow then
        ColorPickerFrame:SetupColorPickerAndShow({
            r = r0, g = g0, b = b0, hasOpacity = opt.hasAlpha and true or false, opacity = a0,
            swatchFunc = commit, opacityFunc = commit, cancelFunc = cancel,
        })
    else
        ColorPickerFrame.func = commit
        ColorPickerFrame.opacityFunc = commit
        ColorPickerFrame.cancelFunc = cancel
        ColorPickerFrame.hasOpacity = opt.hasAlpha and true or false
        ColorPickerFrame.opacity = a0
        ColorPickerFrame:SetColorRGB(r0 or 1, g0 or 1, b0 or 1)
        ColorPickerFrame:Show()
    end
end

-- ── linearize: expand nested (untabbed) groups into header + args ───
local function linearize(args)
    local out = {}
    local list = optSorted(args)
    local i = 0
    while i < #list do   -- nested groups INSERT their args mid-walk
        i = i + 1
        local e = list[i]
        if e.opt.type == "group" then
            out[#out + 1] = { key = e.key .. "__hdr",
                opt = { type = "header", name = e.opt.name or e.key, hidden = e.opt.hidden } }
            local sub = optSorted(e.opt.args or {})
            for s = #sub, 1, -1 do table.insert(list, i + 1, sub[s]) end
        else
            out[#out + 1] = e
        end
    end
    return out
end

-- a section boundary: a plain header, or a CollapsibleHeader toggle
local function isBoundary(opt)
    return opt.type == "header"
        or (opt.type == "toggle" and opt.dialogControl == "CollapsibleHeader")
end

-- split a linear option list into sections at the boundaries; leading
-- options before the first boundary form an implicit "General" section
local function splitSections(linear)
    local sections = {}
    local cur
    for _i, e in ipairs(linear) do
        if isBoundary(e.opt) then
            cur = { header = e, items = {} }
            sections[#sections + 1] = cur
        else
            if not cur then
                cur = { label = "General", header = nil, items = {} }
                sections[#sections + 1] = cur
            end
            cur.items[#cur.items + 1] = e
        end
    end
    return sections
end

-- ── render a linear list of options as template rows ────────────────
-- xL/xR = horizontal insets (boxes indent their rows), y0 = start cursor.
-- Returns the final y cursor; the CALLER sizes content + updates scroll.
local PAIRABLE = { toggle = true, range = true, select = true, color = true, input = true }

local function renderRows(win, entries, xL, xR, y0)
    local content = win.content
    local rowW = (content:GetWidth() or 440) - xL - xR
    -- SINGLE COLUMN for now (Arc's call): the width="half" pair declarations
    -- stay in the option tables; flip this back to `rowW >= 600` when the
    -- two-column layout returns
    local twoCol = false
    local colW = math.floor((rowW - 12) / 2)
    local y = y0
    local stripeN = 0
    local curCol = nil     -- nil = full width, "L"/"R" = the pair columns
    local lineRows = nil   -- rows of the visual line being assembled
    local colRows = {}     -- toggle rows sharing one control column (applied below)

    -- stripes are BACK (Arc's call): one stripe per visual LINE, shared by
    -- both columns of a pair, restarting under each section
    local function commitLine(h)
        stripeN = stripeN + 1
        local show = (stripeN % 2 == 1)
        for r = 1, #lineRows do
            local row = lineRows[r]
            if row._stripe then
                row._stripe:SetVertexColor(1, 1, 1, 0.03)
                row._stripe:SetShown(show)
            end
        end
        lineRows = nil
        y = y - h
    end

    local function place(row, h)
        row:SetFrameLevel(content:GetFrameLevel() + 5)
        if curCol == "L" then
            row:SetPoint("TOPLEFT", content, "TOPLEFT", xL, y)
            row:SetPoint("TOPRIGHT", content, "TOPLEFT", xL + colW, y)
            if h then row:SetHeight(h) end
            lineRows = { row }
        elseif curCol == "R" then
            row:SetPoint("TOPLEFT", content, "TOPLEFT", xL + colW + 12, y)
            row:SetPoint("TOPRIGHT", content, "TOPRIGHT", -xR, y)
            if h then row:SetHeight(h) end
            lineRows[#lineRows + 1] = row
            commitLine(h or ROW_H)
        else
            row:SetPoint("TOPLEFT", content, "TOPLEFT", xL, y)
            row:SetPoint("TOPRIGHT", content, "TOPRIGHT", -xR, y)
            if h then row:SetHeight(h) end
            local hh = h or row:GetHeight() or ROW_H
            if row._isSection then
                stripeN = 0
                y = y - hh
            else
                lineRows = { row }
                commitLine(hh)
            end
        end
    end

    local function renderOne(e)
        local key, opt, info = e.key, e.opt, e.info
        do
            local otype = opt.type
            local name = callv(opt.name, info)
            name = (name ~= nil) and tostring(name) or key
            local desc = callv(opt.desc, info)
            local disabled = callv(opt.disabled, info) and true or false

            if otype == "toggle" and opt.dialogControl == "CollapsibleHeader" then
                local row = acquire(win, "collapse")
                -- option VALUE = expanded; collapsed is its negation
                local collapsed = not (opt.get and opt.get(info))
                row:SetChevron(collapsed)
                row.label:SetText(name:upper())
                row.onClick = function()
                    if opt.set then opt.set(info, not (opt.get and opt.get(info))) end
                    win:Rerender()
                end
                place(row, 24)

            elseif otype == "header" then
                local row = acquire(win, "section")
                row.label:SetText(name:upper())
                place(row, 24)

            elseif otype == "description" then
                if not name:match("^%s*$") then   -- skip Ace spacer descriptions
                    local row = acquire(win, "desc")
                    row.text:SetWidth(rowW - 24)
                    row.text:SetText(name)
                    place(row, (row.text:GetStringHeight() or 12) + 10)
                end

            elseif otype == "toggle" then
                local row = acquire(win, "toggle")
                row.onFlip = nil
                row.label:SetText(name)
                row.tip = desc
                row.sw:SetOn(opt.get and opt.get(info) and true or false)
                row:SetAlpha(disabled and 0.45 or 1)
                row.onFlip = function()
                    if disabled then return end
                    CloseDropdown(win)
                    if opt.set then opt.set(info, not (opt.get and opt.get(info))) end
                    win:Rerender()
                end
                place(row, ROW_H)
                -- full-width rows only: a half-width pair column is a different
                -- width, so it must not be measured against the full-width labels
                if curCol == nil then colRows[#colRows + 1] = row end

            elseif otype == "range" then
                local row = acquire(win, "range")
                row.onLive, row.onCommit, row.getCur = nil, nil, nil
                row.label:SetText(name)
                row.tip = desc
                row:Configure(opt.min or 0, opt.max or 100, opt.step or 1, opt.isPercent)
                local cur = opt.get and opt.get(info)
                row:SetCurrent(cur)
                row:SetAlpha(disabled and 0.45 or 1)
                row.getCur = function() return (opt.get and opt.get(info)) or opt.min or 0 end
                row.onLive = function(v) if not disabled and opt.set then opt.set(info, v) end end
                row.onCommit = function(v)
                    if disabled then return end
                    if opt.set then opt.set(info, v) end
                    win:Rerender()
                end
                place(row, ROW_H)

            elseif otype == "select" then
                local row = acquire(win, "select")
                row.onPick = nil
                row.label:SetText(name)
                row.tip = desc
                local values = callv(opt.values, info) or {}
                local items = {}
                for k, label in pairs(values) do items[#items + 1] = { key = k, label = tostring(label) } end
                table.sort(items, function(a, b) return a.label < b.label end)
                row.values = items
                row.current = opt.get and opt.get(info)
                local cur = row.current
                local shown = nil
                for _n, it in ipairs(items) do if it.key == cur then shown = it.label end end
                row.valueText:SetText(shown or (cur ~= nil and tostring(cur) or ""))
                row:SetAlpha(disabled and 0.45 or 1)
                row.onPick = function(k)
                    if disabled then return end
                    if opt.set then opt.set(info, k) end
                    win:Rerender()
                end
                place(row, ROW_H)

            elseif otype == "color" then
                local row = acquire(win, "color")
                row.onPickColor = nil
                row.label:SetText(name)
                row.tip = desc
                local r, g, b = 1, 1, 1
                if opt.get then r, g, b = opt.get(info) end
                row.sw:SetColor(r or 1, g or 1, b or 1)
                row:SetAlpha(disabled and 0.45 or 1)
                row.onPickColor = function()
                    if disabled then return end
                    OpenColorPicker(row, opt, info, win)
                end
                place(row, ROW_H)

            elseif otype == "execute" then
                local row = acquire(win, "execute")
                row.onExec = nil
                row.btn.fs:SetText(name)
                local bw = row.btn.fs:GetStringWidth() + 26
                row.btn:SetWidth(math.max(120, math.min(bw, rowW - 24)))
                row.tip = desc
                row:SetAlpha(disabled and 0.45 or 1)
                row.onExec = function()
                    if disabled then return end
                    if opt.func then opt.func(info) end
                    win:Rerender()
                end
                place(row, ROW_H)

            elseif otype == "input" then
                local row = acquire(win, "input")
                row.onCommit, row.getCur = nil, nil
                row.label:SetText(name)
                row.tip = desc
                row.getCur = function() return (opt.get and opt.get(info)) or "" end
                row.box:SetText(row.getCur())
                row:SetAlpha(disabled and 0.45 or 1)
                row.onCommit = function(txt)
                    if disabled then return end
                    if opt.set then opt.set(info, txt) end
                    win:Rerender()
                end
                place(row, ROW_H)

            end
        end
    end

    -- visibility prefilter (pairing needs look-ahead), then lay out --
    -- eligible neighbors share one visual line as two columns
    local visList = {}
    for i = 1, #entries do
        local key, opt = entries[i].key, entries[i].opt
        local info = mkinfo(win, key, opt)
        if not callv(opt.hidden, info) then
            local nm = callv(opt.name, info)
            nm = (nm ~= nil) and tostring(nm) or key
            if not (opt.type == "description" and nm:match("^%s*$")) then
                visList[#visList + 1] = { key = key, opt = opt, info = info }
            end
        end
    end
    -- EXPLICIT PAIRING (Arc's final call after auto-pairing kept splitting
    -- semantic pairs): ONLY options declared width="half" pair up, and only
    -- with their immediate half neighbor -- X pairs with Y because the
    -- option table SAYS so, never because a column boundary landed there.
    -- Everything else renders full width.
    local function isHalf(e)
        return e ~= nil and PAIRABLE[e.opt.type]
            and not (e.opt.type == "toggle" and e.opt.dialogControl)
            and e.opt.width == "half"
    end
    local k = 0
    while k < #visList do
        k = k + 1
        local e, nxt = visList[k], visList[k + 1]
        if twoCol and isHalf(e) and isHalf(nxt) then
            curCol = "L"; renderOne(e)
            curCol = "R"; renderOne(nxt)
            k = k + 1
        else
            curCol = nil; renderOne(e)
        end
    end

    -- THE TOGGLE COLUMN. Measured after the loop because a label's width is only
    -- known once its text is set. Every checkbox in this block moves to one shared
    -- x just past the longest label, so the column is uniform instead of ragged
    -- (and near its label instead of pinned to the far edge).
    if #colRows > 0 then
        local widest = 0
        for i = 1, #colRows do
            local fs = colRows[i]._colLabel
            -- unbounded: GetStringWidth reports the ALREADY-TRUNCATED width, which
            -- would feed a too-small column back in on the next render
            local w = (fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth())
                   or fs:GetStringWidth() or 0
            if w > widest then widest = w end
        end
        local col = 12 + widest + 16
        local cap = rowW - 34               -- never shove the box off the right edge
        if col > cap then col = math.max(12, cap) end
        for i = 1, #colRows do
            local r = colRows[i]
            r._colCtrl:ClearAllPoints()
            r._colCtrl:SetPoint("LEFT", r, "LEFT", col, 0)
            -- Bound the label at the column so an over-long name ellipsizes instead
            -- of running underneath the box. Safe to do AFTER the control is anchored
            -- to the row: label and control both hang off the row, so no anchor cycle.
            r._colLabel:SetPoint("RIGHT", r, "LEFT", col - 6, 0)
        end
    end
    return y
end

-- section BOX chrome (the classic titled-square look): a cyan mini title
-- above a bordered darker box that the section's rows sit inside
builders.box = function(win)
    local f = CreateFrame("Frame", nil, win.content, "BackdropTemplate")
    -- COL.box, not COL.bg: the container has to sit a step ABOVE the window body,
    -- which is what makes a boxed section read as a group instead of an outline.
    Skin(f, COL.box, COL.line)
    return f
end

builders.boxtitle = function(win)
    local f = CreateFrame("Frame", nil, win.content)
    f.label = f:CreateFontString(nil, "OVERLAY")
    f.label:SetFont(STANDARD_TEXT_FONT, 10, "")
    f.label:SetPoint("BOTTOMLEFT", 6, 3)
    f.label:SetTextColor(COL.arc[1], COL.arc[2], COL.arc[3])
    return f
end

-- vertical divider between the two columns of a section (the Eleme look)
builders.vdiv = function(win)
    local f = CreateFrame("Frame", nil, win.content)
    f:SetFrameLevel(win.content:GetFrameLevel() + 2)
    local t = f:CreateTexture(nil, "ARTWORK")
    t:SetAllPoints()
    t:SetTexture(WHITE)
    t:SetVertexColor(COL.line[1], COL.line[2], COL.line[3], 0.5)
    return f
end

-- ── tab strips: PHYSICAL CHIPS (the classic-panel look) ─────────────
-- Each tab is a boxed button. `attached` = this is the row sitting ON
-- the page: its selected chip has NO bottom edge and the page's fill, so
-- it visibly opens into ("encapsulates") the panel below -- the panel's
-- own border is the divider, exactly like the classic attached tabs.
local function layoutTabs(win, holder, defs, activeKey, onPick, fontSize, chipH, attached)
    chipH = chipH or 24
    local x, rowY = 0, 0
    local maxW = (win.frame:GetWidth() or 500) - 20
    for i = 1, #defs do
        local d = defs[i]
        local tb = holder.btns[i]
        if not tb then
            tb = CreateFrame("Button", nil, holder, "BackdropTemplate")
            tb.fs = tb:CreateFontString(nil, "OVERLAY")
            tb.fs:SetPoint("CENTER", 0, 0)
            -- manual edges for the open-bottom attached style
            tb.eL = tb:CreateTexture(nil, "OVERLAY"); tb.eL:SetTexture(WHITE); tb.eL:SetWidth(1)
            tb.eL:SetPoint("TOPLEFT"); tb.eL:SetPoint("BOTTOMLEFT")
            tb.eT = tb:CreateTexture(nil, "OVERLAY"); tb.eT:SetTexture(WHITE); tb.eT:SetHeight(1)
            tb.eT:SetPoint("TOPLEFT"); tb.eT:SetPoint("TOPRIGHT")
            tb.eR = tb:CreateTexture(nil, "OVERLAY"); tb.eR:SetTexture(WHITE); tb.eR:SetWidth(1)
            tb.eR:SetPoint("TOPRIGHT"); tb.eR:SetPoint("BOTTOMRIGHT")
            holder.btns[i] = tb
        end
        tb:SetHeight(chipH)
        tb.fs:SetFont(STANDARD_TEXT_FONT, fontSize or 12, "")
        tb.fs:SetText(d.label)
        local w = tb.fs:GetStringWidth() + 24
        tb:SetWidth(w)
        if x + w > maxW and x > 0 then x = 0; rowY = rowY - (chipH + 4) end
        tb:ClearAllPoints()
        tb:SetPoint("TOPLEFT", holder, "TOPLEFT", x, rowY)
        x = x + w + 5
        tb.key = d.key
        local active = (d.key == activeKey)
        tb._active = active
        -- z-order: the attach line sits at holder+2; unselected chips stay
        -- UNDER it (+1) so the line covers their bottom borders, the
        -- selected chip rises ABOVE it (+3) so it notches through
        tb:SetFrameLevel(holder:GetFrameLevel() + ((active and attached) and 3 or 1))
        if active and attached then
            -- open bottom: window-bg fill (continuous with the area under
            -- the attach line), arc side/top edges, no backdrop border
            tb:SetBackdrop({ bgFile = WHITE })
            tb:SetBackdropColor(COL.bg[1], COL.bg[2], COL.bg[3], 1)
            tb.fs:SetTextColor(COL.arc[1], COL.arc[2], COL.arc[3])
            local a = COL.arc
            tb.eL:SetVertexColor(a[1], a[2], a[3], 1); tb.eL:Show()
            tb.eT:SetVertexColor(a[1], a[2], a[3], 1); tb.eT:Show()
            tb.eR:SetVertexColor(a[1], a[2], a[3], 1); tb.eR:Show()
        elseif active then
            Skin(tb, COL.panel, COL.arc)
            tb.fs:SetTextColor(COL.arc[1], COL.arc[2], COL.arc[3])
            tb.eL:Hide(); tb.eT:Hide(); tb.eR:Hide()
        else
            Skin(tb, COL.well, COL.line)
            tb.fs:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
            tb.eL:Hide(); tb.eT:Hide(); tb.eR:Hide()
        end
        tb:SetScript("OnClick", function(self) onPick(self.key) end)
        tb:SetScript("OnEnter", function(self)
            if not self._active then
                self:SetBackdropBorderColor(COL.arcDeep[1], COL.arcDeep[2], COL.arcDeep[3], 1)
                self.fs:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
            end
        end)
        tb:SetScript("OnLeave", function(self)
            if not self._active then
                self:SetBackdropBorderColor(COL.line[1], COL.line[2], COL.line[3], 1)
                self.fs:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
            end
        end)
        tb:Show()
    end
    for i = #defs + 1, #holder.btns do holder.btns[i]:Hide() end
    local h = -rowY + chipH
    holder:SetHeight(#defs > 0 and h or 1)
    return #defs > 0 and h or 0
end

local function groupTabs(args)
    local tabs = {}
    for _, e in ipairs(optSorted(args)) do
        if e.opt.type == "group" then tabs[#tabs + 1] = { key = e.key, label = tostring(e.opt.name or e.key) } end
    end
    return tabs
end

-- ── window construction ─────────────────────────────────────────────
-- Arc community Discord (shared across all Arc addons). Addons can't open URLs, so the
-- button shows a small copy popup with the link selected for Ctrl+C.
local ARC_DISCORD = "https://discord.gg/yMZmnFjUTd"
local BLURPLE = { 0.345, 0.396, 0.949 }   -- #5865F2
local discordCopy
local function ShowDiscordCopy(anchor)
    if not discordCopy then
        local d = CreateFrame("Frame", "ArcSkinDiscordCopy", UIParent, "BackdropTemplate")
        d:SetSize(300, 70); d:SetFrameStrata("FULLSCREEN_DIALOG"); d:SetToplevel(true)
        Skin(d, COL.panel, COL.arc)
        local t = d:CreateFontString(nil, "OVERLAY"); t:SetFont(STANDARD_TEXT_FONT, 12, ""); t:SetPoint("TOP", 0, -10)
        t:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3]); t:SetText("Press Ctrl+C to copy, then open it in your browser")
        local box = CreateFrame("EditBox", nil, d, "BackdropTemplate"); box:SetSize(272, 22); box:SetPoint("TOP", 0, -32); Skin(box, COL.well)
        box:SetFont(STANDARD_TEXT_FONT, 12, ""); box:SetTextInsets(6, 6, 0, 0); box:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3]); box:SetAutoFocus(false)
        box:SetScript("OnEscapePressed", function() d:Hide() end)
        box:SetScript("OnEnterPressed", function() d:Hide() end)
        box:SetScript("OnEditFocusLost", function() d:Hide() end)
        tinsert(UISpecialFrames, "ArcSkinDiscordCopy")
        d.box = box; discordCopy = d
    end
    discordCopy:ClearAllPoints(); discordCopy:SetPoint("CENTER", anchor or UIParent, "CENTER", 0, 0)
    discordCopy:Show(); discordCopy:Raise()
    discordCopy.box:SetText(ARC_DISCORD); discordCopy.box:SetFocus(); discordCopy.box:HighlightText()
end

local function BuildWindow(appName, opts)
    local p = CreateFrame("Frame", "ArcSkin_" .. appName:gsub("[^%w]", ""), UIParent, "BackdropTemplate")
    p:SetSize(opts.width or 500, opts.height or 620)
    p:SetPoint("CENTER", 0, 30)
    p:SetFrameStrata("DIALOG")
    p:SetMovable(true)
    p:EnableMouse(true)
    p:RegisterForDrag("LeftButton")
    p:SetScript("OnDragStart", p.StartMoving)
    p:SetScript("OnDragStop", p.StopMovingOrSizing)
    p:SetClampedToScreen(true)
    Skin(p, { COL.bg[1], COL.bg[2], COL.bg[3], 0.97 }, COL.line2)

    -- title bar
    local bar = CreateFrame("Frame", nil, p, "BackdropTemplate")
    bar:SetPoint("TOPLEFT", 1, -1)
    bar:SetPoint("TOPRIGHT", -1, -1)
    bar:SetHeight(30)
    Skin(bar, COL.panel)
    local t1 = bar:CreateFontString(nil, "OVERLAY")
    t1:SetFont(STANDARD_TEXT_FONT, 14, "")
    t1:SetPoint("LEFT", 12, 0)
    t1:SetText("|cff3fc9f2Arc|r|cffd5e2f2 " .. (opts.title or appName) .. "|r")
    p.titleFS = t1
    local ver = bar:CreateFontString(nil, "OVERLAY")
    ver:SetFont(STANDARD_TEXT_FONT, 10, "")
    ver:SetPoint("LEFT", t1, "RIGHT", 8, -1)
    ver:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
    ver:SetText(opts.version or "")
    p.verFS = ver
    local close = CreateFrame("Button", nil, bar)
    close:SetSize(24, 24)
    close:SetPoint("RIGHT", -4, 0)
    local cx = close:CreateFontString(nil, "OVERLAY")
    cx:SetFont(STANDARD_TEXT_FONT, 14, "")
    cx:SetPoint("CENTER")
    cx:SetText("x")
    cx:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
    close:SetScript("OnEnter", function() cx:SetTextColor(COL.arc[1], COL.arc[2], COL.arc[3]) end)
    close:SetScript("OnLeave", function() cx:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3]) end)
    close:SetScript("OnClick", function() p:Hide() end)

    -- resize grip (bottom-right); OnResized re-renders + lets the consumer
    -- persist the size
    p:SetResizable(true)
    if p.SetResizeBounds then p:SetResizeBounds(430, 400, 1400, 1000) end
    local grip = CreateFrame("Button", nil, p)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -2, 2)
    grip:SetFrameLevel(p:GetFrameLevel() + 40)
    local gtex = grip:CreateTexture(nil, "OVERLAY")
    gtex:SetAllPoints()
    gtex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    gtex:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 0.7)
    grip:SetScript("OnEnter", function() gtex:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 1) end)
    grip:SetScript("OnLeave", function() gtex:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 0.7) end)
    grip:SetScript("OnMouseDown", function() p:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        p:StopMovingOrSizing()
        if p.OnResized then p.OnResized(p) end
    end)

    -- footer: Arc community Discord (bottom-left; clear of the resize grip)
    local dline = p:CreateTexture(nil, "ARTWORK"); dline:SetTexture(WHITE)
    dline:SetVertexColor(COL.line[1], COL.line[2], COL.line[3], 1)
    dline:SetPoint("BOTTOMLEFT", 10, 30); dline:SetPoint("BOTTOMRIGHT", -10, 30); dline:SetHeight(1)
    local db = CreateFrame("Button", nil, p, "BackdropTemplate"); db:SetSize(84, 20); Skin(db, COL.well)
    db:SetPoint("BOTTOMLEFT", 10, 7)
    local dfs = db:CreateFontString(nil, "OVERLAY"); dfs:SetFont(STANDARD_TEXT_FONT, 11, "")
    dfs:SetPoint("CENTER"); dfs:SetText("|cff7289DADiscord|r")
    db:SetScript("OnEnter", function()
        db:SetBackdropBorderColor(BLURPLE[1], BLURPLE[2], BLURPLE[3], 1)
        GameTooltip:SetOwner(db, "ANCHOR_TOP"); GameTooltip:AddLine("Join the Arc UI Discord", 1, 1, 1)
        GameTooltip:AddLine("Questions, help, and updates", 0.7, 0.7, 0.7); GameTooltip:Show()
    end)
    db:SetScript("OnLeave", function() db:SetBackdropBorderColor(COL.line[1], COL.line[2], COL.line[3], 1); GameTooltip:Hide() end)
    db:SetScript("OnClick", function() ShowDiscordCopy(p) end)
    local dhint = p:CreateFontString(nil, "OVERLAY"); dhint:SetFont(STANDARD_TEXT_FONT, 10, "")
    dhint:SetPoint("LEFT", db, "RIGHT", 8, 0); dhint:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
    dhint:SetText("Questions or help? Join the Arc UI Discord")

    tinsert(UISpecialFrames, p:GetName())
    p:Hide()
    return p
end

local function renderWindow(win)
    resetPools(win)
    local tree = win.tree
    -- ── selection resolution FIRST, no layout yet: the bottom-most tab
    -- row needs to know it attaches to the page, which depends on how
    -- many levels this page actually has ──
    local rootTabs = groupTabs(tree.args or {})
    local found = false
    for _n, t in ipairs(rootTabs) do if t.key == win.sel then found = true end end
    if not found then win.sel = rootTabs[1] and rootTabs[1].key end
    local rootGroup = win.sel and tree.args[win.sel]

    local subTabs, curSub = {}, nil
    if rootGroup and rootGroup.childGroups == "tab" then
        subTabs = groupTabs(rootGroup.args or {})
        if #subTabs > 0 then
            curSub = win.subSel[win.sel]
            local ok = false
            for _n, t in ipairs(subTabs) do if t.key == curSub then ok = true end end
            if not ok then curSub = subTabs[1].key; win.subSel[win.sel] = curSub end
        end
    end

    local group = rootGroup
    if group and group.childGroups == "tab" and curSub then
        local sub = group.args and group.args[curSub]
        if sub then group = sub end
    end
    local linear = linearize((group and group.args) or {})

    -- SECTION TABS: a page with 2+ visible sections becomes tabbed instead
    -- of one long scroll (Arc's call). Hidden section headers drop the tab.
    local sections = splitSections(linear)
    local vis = {}
    for _i, s in ipairs(sections) do
        local hInfo = s.header and mkinfo(win, s.header.key, s.header.opt)
        if not (s.header and callv(s.header.opt.hidden, hInfo)) then
            if s.header then
                s.label = tostring(callv(s.header.opt.name, hInfo) or "?")
            end
            vis[#vis + 1] = s
        end
    end
    -- TAB BUCKETS. Two mechanisms:
    -- 1) EXPLICIT (preferred): a section header option may declare
    --    `arcGroup = "Tab Name"` -- consecutive sections sharing the tag
    --    share ONE tab named after it, each rendering as its own box.
    -- 2) HEURISTIC fallback: an untagged section with fewer than 3 options
    --    rides along in the current (untagged) tab instead of its own.
    local MERGE_MIN = 3
    local buckets = {}
    for _i, s in ipairs(vis) do
        local grp = s.header and s.header.opt.arcGroup
        local cur = buckets[#buckets]
        if cur and grp and cur.group == grp then
            cur.sections[#cur.sections + 1] = s
            cur.count = cur.count + #s.items
        elseif cur and not grp and not cur.group
            and (#s.items < MERGE_MIN or cur.count < MERGE_MIN) then
            cur.sections[#cur.sections + 1] = s
            cur.count = cur.count + #s.items
        else
            buckets[#buckets + 1] = { label = grp or s.label, group = grp, sections = { s }, count = #s.items }
        end
    end

    local pageKey = tostring(win.sel) .. "/" .. tostring(curSub or "")
    local useSecTabs = #buckets >= 2
    local selBucket
    if useSecTabs then
        local curLabel = win.secSel[pageKey]
        local found2
        for i, b in ipairs(buckets) do if b.label == curLabel then found2 = i break end end
        if not found2 then found2 = 1; win.secSel[pageKey] = buckets[1].label end
        selBucket = buckets[found2]
    end

    -- ── layout: EVERY level is attached (Arc's design) -- each selected
    -- chip opens into the arc-bordered container that wraps everything
    -- below it; the innermost container is the page itself ──
    local mainH = layoutTabs(win, win.tabHolder, rootTabs, win.sel, function(key)
        CloseDropdown(win)
        win.sel = key
        win:Rerender()
    end, 12, 24, true)
    local subH = 0
    if #subTabs > 0 then
        win.subHolder:Show()
        subH = layoutTabs(win, win.subHolder, subTabs, curSub, function(key)
            CloseDropdown(win)
            win.subSel[win.sel] = key
            win:Rerender()
        end, 11, 22, true)
    else
        win.subHolder:Hide()
        layoutTabs(win, win.subHolder, {}, nil, function() end, 11)
    end
    local secH = 0
    if useSecTabs then
        local defs = {}
        for i, b in ipairs(buckets) do defs[i] = { key = b.label, label = b.label } end
        win.secHolder:Show()
        secH = layoutTabs(win, win.secHolder, defs, selBucket.label, function(key)
            CloseDropdown(win)
            win.secSel[pageKey] = key
            win:Rerender()
        end, 11, 20, true)
    else
        win.secHolder:Hide()
        layoutTabs(win, win.secHolder, {}, nil, function() end, 11)
    end

    -- ── stack: MINIMAL ATTACHMENT (Arc's call: "only the top line") --
    -- each tab row sits on ONE arc line spanning the window; the selected
    -- open-bottom chip notches through it. No boxes around levels; spacing
    -- does the structure, the way a UI addon actually does it.
    win.wrap1:Hide(); win.wrap2:Hide()
    local function arcLine(line, off)
        line:Show()
        line:ClearAllPoints()
        line:SetPoint("TOPLEFT", win.frame, "TOPLEFT", 10, -off)
        line:SetPoint("TOPRIGHT", win.frame, "TOPRIGHT", -10, -off)
        line.tex:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 0.9)
    end
    win.tabHolder:ClearAllPoints()
    win.tabHolder:SetPoint("TOPLEFT", win.frame, "TOPLEFT", 10, -38)
    win.tabHolder:SetPoint("TOPRIGHT", win.frame, "TOPRIGHT", -10, -38)
    win.subHolder:ClearAllPoints()
    win.secHolder:ClearAllPoints()
    local yOff = 38 + mainH
    arcLine(win.lineA, yOff - 1)
    if subH > 0 then
        win.subHolder:SetPoint("TOPLEFT", win.frame, "TOPLEFT", 10, -yOff - 6)
        win.subHolder:SetPoint("TOPRIGHT", win.frame, "TOPRIGHT", -10, -yOff - 6)
        yOff = yOff + 6 + subH
        arcLine(win.lineB, yOff - 1)
    else
        win.lineB:Hide()
    end
    if secH > 0 then
        win.secHolder:SetPoint("TOPLEFT", win.frame, "TOPLEFT", 10, -yOff - 6)
        win.secHolder:SetPoint("TOPRIGHT", win.frame, "TOPRIGHT", -10, -yOff - 6)
        yOff = yOff + 6 + secH
        arcLine(win.tabLine, yOff - 1)
    else
        win.tabLine:Hide()
    end
    win.page:ClearAllPoints()
    win.page:SetPoint("TOPLEFT", win.frame, "TOPLEFT", 10, -yOff - 6)
    win.page:SetPoint("BOTTOMRIGHT", win.frame, "BOTTOMRIGHT", -10, 34)   -- leave room for the Discord footer
    win.page:SetBackdropBorderColor(0, 0, 0, 0)

    -- page body
    local contentW = win.scroll:GetWidth()
    if not contentW or contentW < 50 then contentW = 440 end
    win.content:SetWidth(contentW)
    if useSecTabs then
        -- CollapsibleHeader sections shown inside a tab must be EXPANDED
        -- (their members' hidden() checks the collapse state). CONTRACT
        -- (verified in PT Bar): the option VALUE is the EXPANDED boolean --
        -- get() false = collapsed, set(true) = expand. Only set when
        -- collapsed; Rerender re-entry is blocked by _rendering.
        for _bi, s in ipairs(selBucket.sections) do
            if s.header and s.header.opt.dialogControl == "CollapsibleHeader" then
                local hi = mkinfo(win, s.header.key, s.header.opt)
                if s.header.opt.set and not (s.header.opt.get and s.header.opt.get(hi)) then
                    s.header.opt.set(hi, true)   -- true = expanded
                end
            end
        end
        -- each section = a softly-framed block with breathing room (the
        -- Eleme spacing) + a vertical divider between the two columns
        local innerW = contentW - 20
        local twoCol = false   -- single column for now (must match renderRows)
        local colW = math.floor((innerW - 12) / 2)
        local y = -6
        for _bi, s in ipairs(selBucket.sections) do
            local anyVisible = false
            for _j, e in ipairs(s.items) do
                if not callv(e.opt.hidden, mkinfo(win, e.key, e.opt)) then anyVisible = true break end
            end
            if anyVisible then
                local title = acquire(win, "boxtitle")
                title:SetPoint("TOPLEFT", win.content, "TOPLEFT", 4, y)
                title:SetPoint("TOPRIGHT", win.content, "TOPRIGHT", -4, y)
                title:SetHeight(18)
                title.label:SetText((s.label or ""):upper())
                y = y - 18
                local box = acquire(win, "box")
                box:SetFrameLevel(win.content:GetFrameLevel() + 1)
                box:SetPoint("TOPLEFT", win.content, "TOPLEFT", 2, y)
                box:SetPoint("TOPRIGHT", win.content, "TOPRIGHT", -2, y)
                box:SetBackdropBorderColor(COL.line[1], COL.line[2], COL.line[3], 0.5)
                local boxTop = y
                -- Tight top pad (was 8 both sides). The old padding is what made a
                -- section title look stranded above its first row; the locked KA
                -- template hugs the box and lets the row height do the breathing.
                local yEnd = renderRows(win, s.items, 10, 10, y - 2)
                box:SetHeight(boxTop - yEnd + 3)
                if twoCol then
                    local vd = acquire(win, "vdiv")
                    vd:SetWidth(1)
                    vd:ClearAllPoints()
                    vd:SetPoint("TOP", box, "TOPLEFT", colW + 14, -6)
                    vd:SetPoint("BOTTOM", box, "BOTTOMLEFT", colW + 14, 6)
                end
                y = yEnd - 26
            end
        end
        win.content:SetHeight(-y + 8)
        win.UpdateScroll()
    else
        local yEnd = renderRows(win, linear, 1, 1, -6)
        win.content:SetHeight(-yEnd + 8)
        win.UpdateScroll()
    end
end

-- ── public API ──────────────────────────────────────────────────────

function AS:GetOptionsWindow(appName)
    return windows[appName]
end

function AS:OpenOptions(appName, optionsTable, opts)
    opts = opts or {}
    local win = windows[appName]
    if not win then
        local frame = BuildWindow(appName, opts)
        win = {
            appName = appName,
            frame = frame,
            pools = {},
            subSel = {},
        }
        windows[appName] = win

        -- nested encapsulation containers (arc-bordered, wrap deeper levels)
        win.wrap1 = CreateFrame("Frame", nil, frame, "BackdropTemplate")
        Skin(win.wrap1, COL.panel, COL.arc)
        win.wrap1:SetFrameLevel(frame:GetFrameLevel() + 1)
        win.wrap1:Hide()
        win.wrap2 = CreateFrame("Frame", nil, frame, "BackdropTemplate")
        Skin(win.wrap2, COL.panel, COL.arc)
        win.wrap2:SetFrameLevel(frame:GetFrameLevel() + 2)
        win.wrap2:Hide()

        win.tabHolder = CreateFrame("Frame", nil, frame)
        win.tabHolder.btns = {}
        win.tabHolder:SetFrameLevel(frame:GetFrameLevel() + 6)
        win.subHolder = CreateFrame("Frame", nil, frame)
        win.subHolder.btns = {}
        win.subHolder:SetFrameLevel(frame:GetFrameLevel() + 6)
        win.secHolder = CreateFrame("Frame", nil, frame)
        win.secHolder.btns = {}
        win.secHolder:SetFrameLevel(frame:GetFrameLevel() + 6)
        win.secSel = {}
        -- attach lines as leveled FRAMES: they must draw ABOVE unselected
        -- chips (covering their bottom borders) but BELOW the selected chip
        -- (which notches through) -- unselected chips level +7, lines +8,
        -- selected chips +9 (set in layoutTabs)
        local function makeLine()
            local lf = CreateFrame("Frame", nil, frame)
            lf:SetHeight(1)
            lf:SetFrameLevel(frame:GetFrameLevel() + 8)
            lf.tex = lf:CreateTexture(nil, "ARTWORK")
            lf.tex:SetAllPoints()
            lf.tex:SetTexture(WHITE)
            lf:Hide()
            return lf
        end
        win.tabLine = makeLine()
        win.lineA = makeLine()
        win.lineB = makeLine()

        -- page: panel-skinned area with a thin arc scrollbar (innermost
        -- container of the encapsulation chain -- border set arc per render)
        win.page = CreateFrame("Frame", nil, frame, "BackdropTemplate")
        Skin(win.page, COL.panel)
        win.page:SetFrameLevel(frame:GetFrameLevel() + 3)
        win.scroll = CreateFrame("ScrollFrame", nil, win.page)
        win.scroll:SetPoint("TOPLEFT", 1, -1)
        win.scroll:SetPoint("BOTTOMRIGHT", -9, 1)
        win.content = CreateFrame("Frame", nil, win.scroll)
        win.content:SetSize(1, 1)
        win.scroll:SetScrollChild(win.content)
        local sb = CreateFrame("Slider", nil, win.page)
        sb:SetPoint("TOPRIGHT", -2, -2)
        sb:SetPoint("BOTTOMRIGHT", -2, 2)
        sb:SetWidth(5)
        sb:SetOrientation("VERTICAL")
        sb:SetMinMaxValues(0, 0)
        sb:SetValue(0)
        local sbt = sb:CreateTexture(nil, "BACKGROUND")
        sbt:SetAllPoints()
        sbt:SetTexture(WHITE)
        sbt:SetVertexColor(COL.line[1], COL.line[2], COL.line[3], 0.5)
        sb:SetThumbTexture(WHITE)
        local thumb = sb:GetThumbTexture()
        thumb:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 0.8)
        thumb:SetSize(5, 40)
        win.sbar = sb
        sb:SetScript("OnValueChanged", function(_, v) win.scroll:SetVerticalScroll(v) end)
        win.scroll:EnableMouseWheel(true)
        win.scroll:SetScript("OnMouseWheel", function(_, delta)
            local lo, hi = sb:GetMinMaxValues()
            sb:SetValue(math.max(lo, math.min(hi, sb:GetValue() - delta * 32)))
        end)
        win.UpdateScroll = function()
            local ch = win.content:GetHeight() or 0
            local sh = win.scroll:GetHeight() or 0
            local max = math.max(0, ch - sh)
            sb:SetMinMaxValues(0, max)
            sb:SetShown(max > 0)
            if sb:GetValue() > max then sb:SetValue(max) end
        end
        win.scroll:SetScript("OnSizeChanged", function() win.UpdateScroll() end)

        win.Rerender = function(self)
            if self._rendering then return end   -- NotifyChange re-entry guard
            self._rendering = true
            local keep = self.sbar:GetValue()
            renderWindow(self)
            local lo, hi = self.sbar:GetMinMaxValues()
            self.sbar:SetValue(math.max(lo, math.min(hi, keep)))
            self._rendering = false
        end
        frame.OnResized = function(fr)
            win:Rerender()
            if win.onResize then win.onResize(fr:GetWidth(), fr:GetHeight()) end
        end
        frame:SetScript("OnShow", function() win:Rerender() end)
        frame:SetScript("OnHide", function() CloseDropdown(win) end)
        frame:SetScript("OnMouseDown", function() CloseDropdown(win) end)
    end

    win.tree = optionsTable
    win.onResize = opts.onResize or win.onResize
    if opts.title then win.frame.titleFS:SetText("|cff3fc9f2Arc|r|cffd5e2f2 " .. opts.title .. "|r") end
    if opts.version then win.frame.verFS:SetText(opts.version) end
    if opts.selectTab then win.sel = opts.selectTab end
    win.frame:Show()
    win:Rerender()
    return win
end

function AS:ToggleOptions(appName, optionsTable, opts)
    local win = windows[appName]
    if win and win.frame:IsShown() then
        win.frame:Hide()
        return win
    end
    return self:OpenOptions(appName, optionsTable, opts)
end

function AS:Refresh(appName)
    local win = windows[appName]
    if win and win.frame:IsShown() then win:Rerender() end
end
