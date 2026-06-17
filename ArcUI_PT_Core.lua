-- ArcUI_PT_Core.lua
-- ProcTracker: icon widget factory, per-deck options panel, /pt slash command.
-- No detection logic here. Decks register via PT.RegisterDeck().
-- No pcall. Zero polling.

PT = {}  -- global namespace, decks write into this

local InitMinimapButton  -- forward declare
local BuildOptionsPanel   -- forward declare
local LDB, LDBIcon        -- forward declare (real assignment near minimap section)

-- ── Registry ──────────────────────────────────────────────────────────────────
-- Each entry: { id, name, deckSize, procs, defaultIcon, widget, optPanel,
--               GetDeckPos, GetProcs, OnReset, OnEnable, OnDisable }
local registry  = {}   -- ordered list
local registryMap = {} -- id → entry

-- ── SavedVariables helpers ────────────────────────────────────────────────────
local DB_NAME = "ArcUI_ProcTrackerDB"

local function GetDB()
    ArcUI_ProcTrackerDB = ArcUI_ProcTrackerDB or {}
    return ArcUI_ProcTrackerDB
end

local ICON_DEFAULTS = {
    posX=0, posY=180, iconW=48, iconH=48, iconScale=1.0, frameStrata="HIGH", frameLevel=5, showViolations=false, desaturateEmpty=false, violOffX=0, violOffY=-20, violSize=12, violR=1, violG=0.2, violB=0.2,
    deckOffX=0, deckOffY=0,  deckSize=19,
    procOffX=0, procOffY=27, procSize=19,
    countDown=true, procCountDown=true,
    showDeckSuffix=false, showProcSuffix=false,
    customIcon=nil,
    emptyR=0.0,  emptyG=1.0,  emptyB=0.0,
    halfR=1.0,   halfG=0.82,  halfB=0.0,
    fullR=1.0,   fullG=0.0,   fullB=0.0,
    deckR=1.0,   deckG=1.0,   deckB=1.0,
    borderEnabled=true, borderThickness=1, borderInset=0,
    borderUseClass=false,
    borderR=0.0, borderG=0.0, borderB=0.0, borderA=1.0,
    lockPosition=false,
    textOnly=false,
    textsUnlocked=false,
}

local function IconDB(id)
    local db = GetDB()
    db.icons = db.icons or {}
    db.icons[id] = db.icons[id] or {}
    local t = db.icons[id]
    for k, v in pairs(ICON_DEFAULTS) do
        if t[k] == nil then t[k] = v end
    end
    return t
end

-- ── Border helpers (same method as CDMEnhance) ───────────────────────────────
local function GetClassColor()
    local _, class = UnitClass("player")
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if c then return c.r, c.g, c.b, 1 end
    return 1, 1, 1, 1
end

local function CreateBorderEdges(frame)
    if frame._arcPTBorderEdges then return frame._arcPTBorderEdges end
    local edges = {}
    for _, side in ipairs({"top","bottom","left","right"}) do
        local t = frame:CreateTexture(nil, "OVERLAY", nil, -1)
        t:SetColorTexture(1, 1, 1, 1)
        t:SetSnapToPixelGrid(true)
        t:SetTexelSnappingBias(1)
        edges[side] = t
    end
    frame._arcPTBorderEdges = edges
    return edges
end

local function UpdateBorder(frame, db, anchor)
    local edges = frame._arcPTBorderEdges or CreateBorderEdges(frame)
    anchor = anchor or frame  -- anchor border to icon texture if provided
    if not db.borderEnabled then
        for _, t in pairs(edges) do t:Hide() end
        return
    end
    local r, g, b, a
    if db.borderUseClass then
        r, g, b, a = GetClassColor()
    else
        r, g, b, a = db.borderR, db.borderG, db.borderB, db.borderA
    end
    local thickness = PixelUtil.GetNearestPixelSize(
        db.borderThickness or 2, frame:GetEffectiveScale(), 1)
    local insetX = PixelUtil.GetNearestPixelSize(
        db.borderInset or 0, frame:GetEffectiveScale(), 0)
    local insetY = insetX
    edges.top:ClearAllPoints()
    edges.top:SetPoint("TOPLEFT",     anchor, "TOPLEFT",     insetX,  -insetY)
    edges.top:SetPoint("TOPRIGHT",    anchor, "TOPRIGHT",   -insetX,  -insetY)
    edges.top:SetHeight(thickness); edges.top:SetVertexColor(r,g,b,a); edges.top:Show()
    edges.bottom:ClearAllPoints()
    edges.bottom:SetPoint("BOTTOMLEFT",  anchor, "BOTTOMLEFT",  insetX,  insetY)
    edges.bottom:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", -insetX, insetY)
    edges.bottom:SetHeight(thickness); edges.bottom:SetVertexColor(r,g,b,a); edges.bottom:Show()
    edges.left:ClearAllPoints()
    edges.left:SetPoint("TOPLEFT",    anchor, "TOPLEFT",    insetX, -insetY)
    edges.left:SetPoint("BOTTOMLEFT", anchor, "BOTTOMLEFT", insetX,  insetY)
    edges.left:SetWidth(thickness); edges.left:SetVertexColor(r,g,b,a); edges.left:Show()
    edges.right:ClearAllPoints()
    edges.right:SetPoint("TOPRIGHT",    anchor, "TOPRIGHT",    -insetX, -insetY)
    edges.right:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", -insetX,  insetY)
    edges.right:SetWidth(thickness); edges.right:SetVertexColor(r,g,b,a); edges.right:Show()
end

-- ── AceConfig locals (declared early for widget helpers) ─────────────────────
local AceConfig         = LibStub("AceConfig-3.0", true)
local AceConfigDialog   = LibStub("AceConfigDialog-3.0", true)
local AceConfigRegistry = LibStub("AceConfigRegistry-3.0", true)
local PT_OPTIONS_NAME   = "ArcUI_ProcTracker_Options"

-- ── Widget helpers ────────────────────────────────────────────────────────────
local function ProcColor(db, procs, maxProcs)
    if db.procCountDown then
        local rem = maxProcs - procs
        if rem == maxProcs then      return db.emptyR, db.emptyG, db.emptyB
        elseif rem > 0 then          return db.halfR,  db.halfG,  db.halfB
        else                         return db.fullR,  db.fullG,  db.fullB end
    else
        if procs == 0 then           return db.emptyR, db.emptyG, db.emptyB
        elseif procs < maxProcs then return db.halfR,  db.halfG,  db.halfB
        else                         return db.fullR,  db.fullG,  db.fullB end
    end
end

local GetDeckNS  -- forward declared, defined before BuildDeckOptionsGroup

local function UpdateIcon(entry)
    local w = entry.widget
    if not w then return end
    local db = IconDB(entry.id)
    local textOnly = db.textOnly == true
    -- CDM tracking warning overlay (suppressed in text-only mode)
    if w._cdmWarn then
        if textOnly then
            w._cdmWarn:Hide()
            if w._cdmWarnText then w._cdmWarnText:Hide() end
        else
            local ns = GetDeckNS(entry.id)
            if entry.noCDMWarn then
                w._cdmWarn:Hide()
                if w._cdmWarnText then w._cdmWarnText:Hide() end
            else
                local cdmOk = ns and ns.IsCDMTracking and ns.IsCDMTracking()
                if cdmOk then
                    w._cdmWarn:Hide()
                    if w._cdmWarnText then w._cdmWarnText:Hide() end
                else
                    w._cdmWarn:Show()
                    if w._cdmWarnText then w._cdmWarnText:Show() end
                end
            end
        end
    end
    -- Violation text
    if w._violText then
        if db.showViolations and entry.GetViolations then
            local v = entry.GetViolations()
            local r = db.violR or 1
            local g = db.violG or 0.2
            local b = db.violB or 0.2
            w._violText:SetTextColor(r, g, b)
            w._violText:SetText(tostring(v))
            w._violText:ClearAllPoints()
            w._violText:SetPoint("CENTER", w._icon, "CENTER", db.violOffX or 0, db.violOffY or -20)
            w._violText:Show()
        else
            w._violText:Hide()
        end
    end
    local deckSize = entry.deckSize
    local maxProcs = entry.procs
    local raw      = entry.GetDeckPos()   -- 0-based position in deck
    local procs    = entry.GetProcs()
    local pos      = db.countDown and (deckSize - raw) or raw
    local r, g, b  = ProcColor(db, procs, maxProcs)
    local font     = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
    local suffix   = db.showDeckSuffix and ("/" .. deckSize) or ""
    local procDisp = db.procCountDown and (maxProcs - procs) or procs
    local procSuffix = db.showProcSuffix and ("/" .. maxProcs) or ""

    -- Text-only mode: hide icon texture; text anchors remain valid
    -- (FontStrings stay anchored to the invisible icon region).
    if textOnly then
        if w._icon then w._icon:Hide() end
    else
        if w._icon then
            w._icon:Show()
            -- Desaturate when all procs for this deck are used up
            w._icon:SetDesaturated(db.desaturateEmpty == true and procs >= maxProcs)
        end
    end

    w._deckText:SetFont(font, db.deckSize, "OUTLINE")
    w._deckText:SetShadowOffset(1, -1); w._deckText:SetShadowColor(0, 0, 0, 1)
    w._deckText:SetText(tostring(pos) .. suffix)
    w._deckText:SetTextColor(db.deckR, db.deckG, db.deckB)
    w._deckText:ClearAllPoints()
    w._deckText:SetPoint("CENTER", w._icon, "CENTER", db.deckOffX, db.deckOffY)

    w._procText:SetFont(font, db.procSize, "OUTLINE")
    w._procText:SetShadowOffset(1, -1); w._procText:SetShadowColor(0, 0, 0, 1)
    w._procText:SetText(tostring(procDisp) .. procSuffix)
    w._procText:SetTextColor(r, g, b)
    w._procText:ClearAllPoints()
    w._procText:SetPoint("CENTER", w._icon, "CENTER", db.procOffX, db.procOffY)

    -- Border — hidden in text-only mode, otherwise applied to icon texture
    if textOnly then
        if w._arcPTBorderEdges then
            for _, t in pairs(w._arcPTBorderEdges) do t:Hide() end
        end
    else
        UpdateBorder(w, db, w._icon)
    end

    -- Resync text drag handles to follow the current text bounds
    if w._deckTextHandle and w._deckTextHandle._resync then w._deckTextHandle._resync() end
    if w._procTextHandle and w._procTextHandle._resync then w._procTextHandle._resync() end
    if w._violTextHandle and w._violTextHandle._resync then w._violTextHandle._resync() end
end

local function ApplyIconSize(f, w, h)
    f:SetSize(w + 4, h + 14)
    if f._icon then f._icon:SetSize(w, h) end
end

-- ── Text drag handles ────────────────────────────────────────────────────────
-- Creates an invisible mouse-enabled frame on top of a FontString.
-- When "unlock texts" is on, dragging the handle updates the offset DB keys
-- (offXKey/offYKey relative to the icon's CENTER) and refreshes the icon.
-- onRefresh() is called after drag stop so the options panel updates.
local function MakeTextDragHandle(parent, fontString, anchorTo, getDB, offXKey, offYKey, onRefresh)
    -- Manual drag with OnMouseDown/OnMouseUp (NOT RegisterForDrag) so motion
    -- starts the instant the button is pressed — no WoW drag threshold.

    local h = CreateFrame("Frame", nil, parent)
    h:SetFrameStrata(parent:GetFrameStrata())
    h:SetFrameLevel((parent:GetFrameLevel() or 5) + 10)
    h:EnableMouse(false)

    local outline = h:CreateTexture(nil, "OVERLAY")
    outline:SetAllPoints(h)
    outline:SetColorTexture(0.2, 0.8, 1.0, 0.18)
    outline:Hide()
    h._outline = outline

    -- Anchor handle directly to anchorTo (the icon) at the current text offset.
    -- The FontString's offset and the handle's offset use the same value,
    -- so dragging the handle directly mutates that offset in DB coordinates.
    local function Resync()
        local tw, th = fontString:GetStringWidth(), fontString:GetStringHeight()
        if tw < 12 then tw = 12 end
        if th < 12 then th = 12 end
        h:SetSize(tw + 6, th + 4)
        local d = getDB()
        h:ClearAllPoints()
        h:SetPoint("CENTER", anchorTo, "CENTER", d[offXKey] or 0, d[offYKey] or 0)
    end
    h._resync = Resync

    -- Drag state
    local dragging
    local dragStartCX, dragStartCY
    local dragStartOffX, dragStartOffY

    local function StopDrag(self)
        if not dragging then return end
        dragging = false
        self:SetScript("OnUpdate", nil)
        local x, y = GetCursorPosition()
        local sc   = parent:GetEffectiveScale()
        local dx   = x / sc - dragStartCX
        local dy   = y / sc - dragStartCY
        local newX = math.floor(dragStartOffX + dx + 0.5)
        local newY = math.floor(dragStartOffY + dy + 0.5)
        local d = getDB()
        d[offXKey] = newX
        d[offYKey] = newY
        self:ClearAllPoints()
        self:SetPoint("CENTER", anchorTo, "CENTER", newX, newY)
        dragStartCX, dragStartCY = nil, nil
        if onRefresh then onRefresh() end
        if AceConfigRegistry then
            AceConfigRegistry:NotifyChange(PT_OPTIONS_NAME)
        end
    end

    h:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        if not self:IsMouseEnabled() then return end
        local cx, cy = GetCursorPosition()
        local scale  = parent:GetEffectiveScale()
        dragStartCX  = cx / scale
        dragStartCY  = cy / scale
        local d = getDB()
        dragStartOffX = d[offXKey] or 0
        dragStartOffY = d[offYKey] or 0
        dragging = true
        self:SetScript("OnUpdate", function(s)
            local x, y = GetCursorPosition()
            local sc   = parent:GetEffectiveScale()
            local dx   = x / sc - dragStartCX
            local dy   = y / sc - dragStartCY
            local newX = dragStartOffX + dx
            local newY = dragStartOffY + dy
            s:ClearAllPoints()
            s:SetPoint("CENTER", anchorTo, "CENTER", newX, newY)
            fontString:ClearAllPoints()
            fontString:SetPoint("CENTER", anchorTo, "CENTER", newX, newY)
        end)
    end)
    h:SetScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" then return end
        StopDrag(self)
    end)
    -- Safety: if the cursor leaves the handle while the button is still held,
    -- WoW won't fire OnMouseUp on the handle. Watch for button release globally.
    h:SetScript("OnHide", function(self) StopDrag(self) end)

    return h
end

local function ApplyTextDragHandleState(entry, unlocked)
    local w = entry.widget
    if not w then return end
    for _, key in ipairs({"_deckTextHandle", "_procTextHandle", "_violTextHandle"}) do
        local h = w[key]
        if h then
            h:EnableMouse(unlocked == true)
            if h._outline then h._outline:SetShown(unlocked == true) end
            if unlocked and h._resync then h._resync() end
        end
    end
end

-- ── Widget helpers (continued) ───────────────────────────────────────────────

local function BuildIconWidget(entry)
    local db    = IconDB(entry.id)
    local id    = entry.id
    local w     = db.iconW or 48
    local h     = db.iconH or 48

    local f = CreateFrame("Frame", "ArcUI_PT_Icon_" .. id, UIParent)
    f:SetSize(w + 4, h + 14)
    f:SetScale(db.iconScale or 1.0)
    f:SetFrameStrata(db.frameStrata or "HIGH")
    f:SetFrameLevel(db.frameLevel or 5)
    -- Load anchor: use saved anchor type if present, fall back to CENTER/CENTER.
    -- StopMovingOrSizing may have reanchored to a screen corner, so we store
    -- the full anchor info (point + relativePoint) not just offsets.
    f:SetPoint(
        db.posPoint or "CENTER",
        UIParent,
        db.posRelPoint or "CENTER",
        db.posX or 0,
        db.posY or 0
    )
    f:SetClampedToScreen(true)
    local locked = db.lockPosition == true
    f:SetMovable(not locked)
    f:EnableMouse(not locked)
    f:RegisterForDrag("LeftButton")   -- always register; OnDragStart guard handles lock
    f:SetScript("OnDragStart", function(self)
        if IconDB(id).lockPosition then return end
        self:StartMoving()
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        -- Save the FULL anchor description, not just offsets. SetClampedToScreen
        -- can change the anchor type during drag (e.g. CENTER → BOTTOMLEFT) so
        -- saving only x/y and re-applying as CENTER/CENTER puts the icon at a
        -- different screen position on reload.
        local point, _, relPoint, x, y = self:GetPoint()
        local idb = IconDB(id)
        idb.posPoint    = point
        idb.posRelPoint = relPoint
        idb.posX        = x
        idb.posY        = y
    end)

    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetSize(w, h)
    icon:SetPoint("CENTER", f, "CENTER", 0, 3)
    local cid = db.customIcon
    local defaultTex = C_Spell.GetSpellTexture(entry.defaultIcon) or entry.defaultIcon or 136048
    icon:SetTexture(cid and (C_Spell.GetSpellTexture(cid) or cid) or defaultTex)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f._icon = icon

    local dt = f:CreateFontString(nil, "OVERLAY")
    dt:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", db.deckSize, "OUTLINE")
    dt:SetPoint("CENTER", icon, "CENTER", db.deckOffX, db.deckOffY)
    dt:SetTextColor(db.deckR, db.deckG, db.deckB)
    dt:SetDrawLayer("OVERLAY", 2)
    f._deckText = dt

    f._deckTextHandle = MakeTextDragHandle(f, dt, icon,
        function() return IconDB(id) end, "deckOffX", "deckOffY",
        function() UpdateIcon(entry) end)

    local pt = f:CreateFontString(nil, "OVERLAY")
    pt:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", db.procSize, "OUTLINE")
    pt:SetPoint("CENTER", icon, "CENTER", db.procOffX, db.procOffY)
    pt:SetTextColor(db.emptyR, db.emptyG, db.emptyB)
    pt:SetDrawLayer("OVERLAY", 2)
    f._procText = pt

    f._procTextHandle = MakeTextDragHandle(f, pt, icon,
        function() return IconDB(id) end, "procOffX", "procOffY",
        function() UpdateIcon(entry) end)

    local vt = f:CreateFontString(nil, "OVERLAY")
    vt:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", db.violSize or 12, "OUTLINE")
    vt:SetPoint("CENTER", icon, "CENTER", db.violOffX or 0, db.violOffY or -20)
    vt:SetTextColor(db.violR or 1, db.violG or 0.2, db.violB or 0.2)
    vt:SetDrawLayer("OVERLAY", 2)
    vt:SetText("")
    vt:SetShown(db.showViolations == true)
    f._violText = vt

    f._violTextHandle = MakeTextDragHandle(f, vt, icon,
        function() return IconDB(id) end, "violOffX", "violOffY",
        function() UpdateIcon(entry) end)

    -- CDM tracking warning overlay — yellow tint + ! text when CDM frame not hooked
    local cdmWarn = f:CreateTexture(nil, "OVERLAY")
    cdmWarn:SetAllPoints(icon)
    cdmWarn:SetColorTexture(1, 0.85, 0, 0.25)
    cdmWarn:Hide()
    f._cdmWarn = cdmWarn

    local cdmWarnText = f:CreateFontString(nil, "OVERLAY")
    cdmWarnText:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 22, "OUTLINE")
    cdmWarnText:SetPoint("CENTER", icon, "CENTER", 0, 0)
    cdmWarnText:SetTextColor(1, 0.85, 0, 1)
    cdmWarnText:SetText("!")
    cdmWarnText:SetDrawLayer("OVERLAY", 3)
    cdmWarnText:Hide()
    f._cdmWarnText = cdmWarnText

    entry.widget = f
    -- Respect saved deckEnabled state — don't show if user disabled the icon
    local idb = IconDB(entry.id)
    if idb.deckEnabled == false then
        f:Hide()
    end
    -- Apply saved text-unlock state for drag handles
    ApplyTextDragHandleState(entry, idb.textsUnlocked == true)
    -- Mirror talent-driven show/hide to the bar widget
    -- Deck modules call entry.widget:Show/Hide directly for talent gating,
    -- so we intercept here to keep bar in sync.
    hooksecurefunc(f, "Show", function(self)
        if entry.barWidget then
            local db = ArcUI_ProcTrackerDB and ArcUI_ProcTrackerDB.bars and ArcUI_ProcTrackerDB.bars[entry.id]
            if db and db.barEnabled then
                entry.barWidget:Show()
            end
        end
    end)
    hooksecurefunc(f, "Hide", function(self)
        if entry.barWidget then
            -- Only hide bar for talent reasons if barEnabled is on
            -- (deckEnabled hide should not affect bar)
            local idb2 = IconDB(entry.id)
            if idb2.deckEnabled ~= false then
                -- This is a talent-driven hide — also hide bar
                if entry.barWidget then entry.barWidget:Hide() end
                if entry.barWidget and entry.barWidget._deckTextFrame then entry.barWidget._deckTextFrame:Hide() end
                if entry.barWidget and entry.barWidget._procTextFrame then entry.barWidget._procTextFrame:Hide() end
            end
        end
    end)
    UpdateIcon(entry)
    return f
end

-- ── AceConfig options ────────────────────────────────────────────────────────
local collapsedSections = {}  -- session-only collapse state per deck

GetDeckNS = function(id)
    -- Map deck id to its namespace table on PT
    if id == "dw"           then return PT.DW end
    if id == "tempest"      then return PT.Tempest end
    if id == "elemtempest"  then return PT.ElemTempest end
    return nil
end

local function BuildDeckOptionsGroup(entry)
    local id   = entry.id
    local function db() return IconDB(id) end
    local function refresh() UpdateIcon(entry) end
    local order = 0
    local function o() order = order + 1; return order end

    local function deckEnabled()
        local v = db().deckEnabled
        return v == nil or v == true  -- nil = default on
    end
    local function iconHidden() return not deckEnabled() end

    return {
        type = "group",
        name = entry.name,
        args = {

            -- ── DECK ENABLED ──────────────────────────────────────────────────
            enableHeader = {
                type = "header", name = "Deck", order = o(),
            },
            deckEnabled = {
                type  = "toggle", name = "Show Icon Widget",
                desc  = "Show the icon widget for this deck. Disable if you only want to use the bar.",
                order = o(), width = "full",
                get   = function()
                    if db().deckEnabled == nil then return true end
                    return db().deckEnabled
                end,
                set   = function(_, v)
                    db().deckEnabled = v
                    local w = entry.widget
                    if w then if v then w:Show() else w:Hide() end end
                end,
            },

            -- ── CDM TRACKING ──────────────────────────────────────────────────
            cdmHeader = {
                type = "header", name = "CDM Tracking", order = o(),
                hidden = function() return iconHidden() or entry.noCDMWarn end,
            },
            cdmStatus = {
                type = "description",
                name = function()
                    local ns = GetDeckNS(entry.id)
                    local ok = ns and ns.IsCDMTracking and ns.IsCDMTracking()
                    if ok then
                        return "|cff44FF44CDM frame hooked — tracking active|r"
                    else
                        return "|cffFF4444CDM frame NOT found — detection disabled|r"
                    end
                end,
                order = o(), width = "full",
                hidden = function() return iconHidden() or entry.noCDMWarn end,
            },
            cdmReverify = {
                type = "execute", name = "Reverify CDM Tracking",
                desc = "Scans CDM viewers and re-hooks the tracking frame. Use this if tracking failed on login.",
                order = o(), width = "full",
                hidden = function() return iconHidden() or entry.noCDMWarn end,
                func = function()
                    local ns = GetDeckNS(entry.id)
                    if ns and ns.RehookCDM then
                        ns.RehookCDM()
                        C_Timer.After(0.1, function()
                            UpdateIcon(entry)
                            AceConfigDialog:Open(PT_OPTIONS_NAME)
                        end)
                    end
                end,
            },

            -- ── ICON ──────────────────────────────────────────────────────────
            iconHeader = {
                type = "header", name = "Icon", order = o(),
                hidden = iconHidden,
            },
            lockPosition = {
                type  = "toggle", name = "Lock Position",
                desc  = "Prevent the icon from being dragged. When locked the frame is click-through.",
                order = o(), width = "full",
                hidden = iconHidden,
                get   = function() return db().lockPosition == true end,
                set   = function(_, v)
                    db().lockPosition = v
                    local wf = entry.widget
                    if wf then
                        wf:SetMovable(not v)
                        wf:EnableMouse(not v)
                    end
                end,
            },
            textOnly = {
                type  = "toggle", name = "Text Only (No Icon)",
                desc  = "Hide the icon texture, border, and CDM warning overlay. Only the deck position and proc count text are shown. Frame remains draggable.",
                order = o(), width = "full",
                hidden = iconHidden,
                get   = function() return db().textOnly == true end,
                set   = function(_, v)
                    db().textOnly = v
                    refresh()
                end,
            },
            textsUnlocked = {
                type  = "toggle", name = "Unlock Texts (Drag to Position)",
                desc  = "Enables click-and-drag on the deck, proc, and violation texts. A faint blue overlay marks the draggable area. Disable to lock and click-through.",
                order = o(), width = "full",
                hidden = iconHidden,
                get   = function() return db().textsUnlocked == true end,
                set   = function(_, v)
                    db().textsUnlocked = v
                    ApplyTextDragHandleState(entry, v)
                end,
            },
            posX = {
                type  = "input", name = "Position X",
                desc  = "Horizontal offset from screen center. Negative = left, positive = right.",
                order = o(), width = "half",
                hidden = iconHidden,
                get   = function() return tostring(db().posX or 0) end,
                set   = function(_, v)
                    local n = tonumber(v)
                    if not n then return end
                    db().posX        = n
                    db().posPoint    = "CENTER"
                    db().posRelPoint = "CENTER"
                    local wf = entry.widget
                    if wf then
                        wf:ClearAllPoints()
                        wf:SetPoint("CENTER", UIParent, "CENTER", db().posX or 0, db().posY or 0)
                    end
                end,
            },
            posY = {
                type  = "input", name = "Position Y",
                desc  = "Vertical offset from screen center. Negative = down, positive = up.",
                order = o(), width = "half",
                hidden = iconHidden,
                get   = function() return tostring(db().posY or 0) end,
                set   = function(_, v)
                    local n = tonumber(v)
                    if not n then return end
                    db().posY        = n
                    db().posPoint    = "CENTER"
                    db().posRelPoint = "CENTER"
                    local wf = entry.widget
                    if wf then
                        wf:ClearAllPoints()
                        wf:SetPoint("CENTER", UIParent, "CENTER", db().posX or 0, db().posY or 0)
                    end
                end,
            },
            recenterPos = {
                type  = "execute", name = "Reset to Center",
                desc  = "Reset icon position to screen center (0, 0).",
                order = o(), width = "full",
                hidden = iconHidden,
                func  = function()
                    db().posX        = 0
                    db().posY        = 0
                    db().posPoint    = "CENTER"
                    db().posRelPoint = "CENTER"
                    local wf = entry.widget
                    if wf then
                        wf:ClearAllPoints()
                        wf:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
                    end
                end,
            },
            iconScale = {
                type = "range", name = "Scale",
                desc = "Scales the entire icon widget uniformly — multiplies all sizes",
                min = 0.5, max = 3.0, step = 0.05,
                order = o(), width = "full",
                hidden = iconHidden,
                get  = function() return db().iconScale or 1.0 end,
                set  = function(_, v)
                    local oldScale = db().iconScale or 1.0
                    db().iconScale = v
                    local wf = entry.widget
                    if wf then
                        -- Compensate position for scale change so icon stays centered
                        -- SetScale changes coordinate space: pos in scaled space = pos_screen / new_scale
                        -- So we multiply by oldScale/newScale to keep screen position identical
                        local _, _, _, x, y = wf:GetPoint()
                        local ratio = oldScale / v
                        wf:SetScale(v)
                        wf:ClearAllPoints()
                        wf:SetPoint("CENTER", UIParent, "CENTER", x * ratio, y * ratio)
                        -- Save corrected position with anchor reset to CENTER/CENTER
                        local idb = IconDB(id)
                        idb.posX        = x * ratio
                        idb.posY        = y * ratio
                        idb.posPoint    = "CENTER"
                        idb.posRelPoint = "CENTER"
                    end
                end,
            },
            iconW = {
                type = "range", name = "Width",
                min = 16, max = 200, step = 1,
                order = o(), width = "half",
                hidden = iconHidden,
                get  = function() return db().iconW or 48 end,
                set  = function(_, v)
                    db().iconW = v
                    local wf = entry.widget
                    if wf then ApplyIconSize(wf, v, db().iconH or 48) end
                end,
            },
            iconH = {
                type = "range", name = "Height",
                min = 16, max = 200, step = 1,
                order = o(), width = "half",
                hidden = iconHidden,
                get  = function() return db().iconH or 48 end,
                set  = function(_, v)
                    db().iconH = v
                    local wf = entry.widget
                    if wf then ApplyIconSize(wf, db().iconW or 48, v) end
                end,
            },
            frameStrata = {
                type   = "select", name = "Frame Strata",
                desc   = "The strata layer the icon sits on",
                order  = o(), width = "normal",
                hidden = iconHidden,
                values = {
                    BACKGROUND        = "BACKGROUND",
                    LOW               = "LOW",
                    MEDIUM            = "MEDIUM",
                    HIGH              = "HIGH",
                    DIALOG            = "DIALOG",
                    FULLSCREEN        = "FULLSCREEN",
                    FULLSCREEN_DIALOG  = "FULLSCREEN_DIALOG",
                    TOOLTIP           = "TOOLTIP",
                },
                sorting = {"BACKGROUND","LOW","MEDIUM","HIGH","DIALOG","FULLSCREEN","FULLSCREEN_DIALOG","TOOLTIP"},
                get  = function() return db().frameStrata or "HIGH" end,
                set  = function(_, v)
                    db().frameStrata = v
                    local w = entry.widget
                    if w then w:SetFrameStrata(v) end
                end,
            },
            frameLevel = {
                type  = "input", name = "Frame Level",
                desc  = "Level within the strata (1-128, higher = on top)",
                order = o(), width = "half",
                hidden = iconHidden,
                get  = function() return tostring(db().frameLevel or 5) end,
                set  = function(_, v)
                    local n = tonumber(v)
                    if not n then return end
                    n = math.max(1, math.min(128, math.floor(n)))
                    db().frameLevel = n
                    local w = entry.widget
                    if w then w:SetFrameLevel(n) end
                end,
            },
            customIcon = {
                type  = "input", name = "Icon File ID",
                desc  = "File ID to override the icon texture. Leave blank for default.",
                order = o(), width = "half",
                hidden = iconHidden,
                get   = function() return db().customIcon and tostring(db().customIcon) or "" end,
                set   = function(_, v)
                    v = v and v:match("^%s*(.-)%s*$") or ""
                    local num = tonumber(v)
                    local w   = entry.widget
                    if num then
                        local tex = C_Spell.GetSpellTexture(num) or num
                        db().customIcon = num
                        if w then w._icon:SetTexture(tex) end
                    else
                        db().customIcon = nil
                        if w then
                            w._icon:SetTexture(C_Spell.GetSpellTexture(entry.defaultIcon) or entry.defaultIcon or 136048)
                        end
                    end
                end,
            },

            desaturateEmpty = {
                type  = "toggle", name = "Desaturate when no procs left",
                desc  = "Desaturates the icon texture when proc count is 0.",
                order = o(), width = "full",
                hidden = iconHidden,
                get   = function() return db().desaturateEmpty == true end,
                set   = function(_, v)
                    db().desaturateEmpty = v
                    refresh()
                end,
            },

            -- ── DECK POSITION TEXT ────────────────────────────────────────────
            deckTextHeader = {
                type = "header", name = "Deck Position Text", order = o(),
                hidden = iconHidden,
            },
            countDown = {
                type  = "toggle", name = "Count Down  (600 to 0)",
                order = o(), width = "full",
                hidden = iconHidden,
                get   = function() return db().countDown end,
                set   = function(_, v) db().countDown = v; refresh() end,
            },
            showDeckSuffix = {
                type  = "toggle", name = "Show /" .. entry.deckSize .. " suffix",
                order = o(), width = "full",
                hidden = iconHidden,
                get   = function() return db().showDeckSuffix end,
                set   = function(_, v) db().showDeckSuffix = v; refresh() end,
            },
            deckSize = {
                type = "range", name = "Font Size",
                min = 6, max = 32, step = 1,
                order = o(), width = "half",
                hidden = iconHidden,
                get  = function() return db().deckSize end,
                set  = function(_, v) db().deckSize = v; refresh() end,
            },
            deckColor = {
                type = "color", name = "Color",
                order = o(), width = "half", hasAlpha = false,
                hidden = iconHidden,
                get  = function() return db().deckR, db().deckG, db().deckB end,
                set  = function(_, r, g, b)
                    local d = db(); d.deckR=r; d.deckG=g; d.deckB=b; refresh()
                end,
            },
            deckOffX = {
                type = "range", name = "Offset X",
                min = -50, max = 50, step = 1,
                order = o(), width = "half",
                hidden = iconHidden,
                get  = function() return db().deckOffX end,
                set  = function(_, v) db().deckOffX = v; refresh() end,
            },
            deckOffY = {
                type = "range", name = "Offset Y",
                min = -50, max = 50, step = 1,
                order = o(), width = "half",
                hidden = iconHidden,
                get  = function() return db().deckOffY end,
                set  = function(_, v) db().deckOffY = v; refresh() end,
            },
            deckInputX = {
                type = "input", name = "X (exact)",
                desc = "Type an exact X offset (overrides the slider's -50..50 range).",
                order = o(), width = "half",
                hidden = iconHidden,
                get  = function() return tostring(db().deckOffX or 0) end,
                set  = function(_, v)
                    local n = tonumber(v); if not n then return end
                    db().deckOffX = math.floor(n + 0.5); refresh()
                end,
            },
            deckInputY = {
                type = "input", name = "Y (exact)",
                desc = "Type an exact Y offset (overrides the slider's -50..50 range).",
                order = o(), width = "half",
                hidden = iconHidden,
                get  = function() return tostring(db().deckOffY or 0) end,
                set  = function(_, v)
                    local n = tonumber(v); if not n then return end
                    db().deckOffY = math.floor(n + 0.5); refresh()
                end,
            },

            -- ── PROC COUNT TEXT ───────────────────────────────────────────────
            procTextHeader = {
                type = "header", name = "Proc Count Text", order = o(),
                hidden = iconHidden,
            },
            procCountDown = {
                type  = "toggle", name = "Count Down  (3 to 0)",
                order = o(), width = "full",
                hidden = iconHidden,
                get   = function() return db().procCountDown end,
                set   = function(_, v) db().procCountDown = v; refresh() end,
            },
            showProcSuffix = {
                type  = "toggle", name = "Show /" .. entry.procs .. " suffix",
                order = o(), width = "full",
                hidden = iconHidden,
                get   = function() return db().showProcSuffix end,
                set   = function(_, v) db().showProcSuffix = v; refresh() end,
            },
            procSize = {
                type = "range", name = "Font Size",
                min = 6, max = 32, step = 1,
                order = o(), width = "half",
                hidden = iconHidden,
                get  = function() return db().procSize end,
                set  = function(_, v) db().procSize = v; refresh() end,
            },
            procOffX = {
                type = "range", name = "Offset X",
                min = -50, max = 50, step = 1,
                order = o(), width = "half",
                hidden = iconHidden,
                get  = function() return db().procOffX end,
                set  = function(_, v) db().procOffX = v; refresh() end,
            },
            procOffY = {
                type = "range", name = "Offset Y",
                min = -50, max = 50, step = 1,
                order = o(), width = "half",
                hidden = iconHidden,
                get  = function() return db().procOffY end,
                set  = function(_, v) db().procOffY = v; refresh() end,
            },
            procInputX = {
                type = "input", name = "X (exact)",
                desc = "Type an exact X offset (overrides the slider's -50..50 range).",
                order = o(), width = "half",
                hidden = iconHidden,
                get  = function() return tostring(db().procOffX or 0) end,
                set  = function(_, v)
                    local n = tonumber(v); if not n then return end
                    db().procOffX = math.floor(n + 0.5); refresh()
                end,
            },
            procInputY = {
                type = "input", name = "Y (exact)",
                desc = "Type an exact Y offset (overrides the slider's -50..50 range).",
                order = o(), width = "half",
                hidden = iconHidden,
                get  = function() return tostring(db().procOffY or 0) end,
                set  = function(_, v)
                    local n = tonumber(v); if not n then return end
                    db().procOffY = math.floor(n + 0.5); refresh()
                end,
            },

            -- ── PROC COLORS ───────────────────────────────────────────────────
            procColorsHeader = {
                type = "header", name = "Proc Count Colors", order = o(),
                hidden = iconHidden,
            },
            emptyColor = {
                type = "color", name = "All Procs Available",
                desc  = "No procs used this deck",
                order = o(), width = "full", hasAlpha = false,
                hidden = iconHidden,
                get  = function() return db().emptyR, db().emptyG, db().emptyB end,
                set  = function(_, r, g, b)
                    local d = db(); d.emptyR=r; d.emptyG=g; d.emptyB=b; refresh()
                end,
            },
            halfColor = {
                type = "color", name = "Procs Partially Used",
                desc  = "Some but not all procs used",
                order = o(), width = "full", hasAlpha = false,
                hidden = iconHidden,
                get  = function() return db().halfR, db().halfG, db().halfB end,
                set  = function(_, r, g, b)
                    local d = db(); d.halfR=r; d.halfG=g; d.halfB=b; refresh()
                end,
            },
            fullColor = {
                type = "color", name = "All Procs Used",
                desc  = "All procs consumed this deck",
                order = o(), width = "full", hasAlpha = false,
                hidden = iconHidden,
                get  = function() return db().fullR, db().fullG, db().fullB end,
                set  = function(_, r, g, b)
                    local d = db(); d.fullR=r; d.fullG=g; d.fullB=b; refresh()
                end,
            },

            -- ── BORDER ────────────────────────────────────────────────────────
            borderHeader = {
                type = "header", name = "Border", order = o(),
                hidden = iconHidden,
            },
            borderEnabled = {
                type  = "toggle", name = "Enable Border",
                order = o(), width = "full",
                hidden = iconHidden,
                get   = function() return db().borderEnabled end,
                set   = function(_, v) db().borderEnabled = v; refresh() end,
            },
            borderUseClass = {
                type  = "toggle", name = "Use Class Color",
                order = o(), width = "full",
                hidden = iconHidden,
                get   = function() return db().borderUseClass end,
                set   = function(_, v) db().borderUseClass = v; refresh() end,
            },
            borderThickness = {
                type = "range", name = "Thickness",
                min = 1, max = 10, step = 1,
                order = o(), width = "half",
                hidden = iconHidden,
                get  = function() return db().borderThickness end,
                set  = function(_, v) db().borderThickness = v; refresh() end,
            },
            borderInset = {
                type = "range", name = "Inset",
                min = -10, max = 10, step = 1,
                order = o(), width = "half",
                hidden = iconHidden,
                get  = function() return db().borderInset end,
                set  = function(_, v) db().borderInset = v; refresh() end,
            },
            borderColor = {
                type = "color", name = "Border Color",
                order = o(), width = "full", hasAlpha = true,
                hidden = iconHidden,
                get  = function() return db().borderR, db().borderG, db().borderB, db().borderA end,
                set  = function(_, r, g, b, a)
                    local d = db(); d.borderR=r; d.borderG=g; d.borderB=b; d.borderA=a; refresh()
                end,
            },

            -- ── RESET ─────────────────────────────────────────────────────────
            resetHeader = {
                type = "header", name = "Reset", order = o(),
                hidden = iconHidden,
            },
            resetDeck = {
                type  = "execute", name = "Reset Deck Tracking",
                desc  = "Reset deck position and proc count to zero",
                order = o(), width = "full",
                hidden = iconHidden,
                func  = function()
                    if entry.OnReset then entry.OnReset() end
                    UpdateIcon(entry)
                end,
            },


            -- ── VIOLATIONS ────────────────────────────────────────────────────
            violHeader = {
                type = "header", name = "Violations", order = o(),
                hidden = iconHidden,
            },
            showViolations = {
                type  = "toggle", name = "Show Violation Counter",
                desc  = "Shows a count of decks that had wrong proc count. Disabled by default.",
                order = o(), width = "full",
                hidden = iconHidden,
                get   = function() return db().showViolations == true end,
                set   = function(_, v)
                    db().showViolations = v
                    local w = entry.widget
                    if w and w._violText then w._violText:SetShown(v) end
                    UpdateIcon(entry)
                end,
            },
            violSize = {
                type = "range", name = "Font Size",
                min = 6, max = 32, step = 1,
                order = o(), width = "half",
                hidden = function() return iconHidden() or not db().showViolations end,
                get  = function() return db().violSize or 12 end,
                set  = function(_, v)
                    db().violSize = v
                    local w = entry.widget
                    if w and w._violText then
                        w._violText:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", v, "OUTLINE")
                    end
                end,
            },
            violOffX = {
                type = "range", name = "Offset X",
                min = -100, max = 100, step = 1,
                order = o(), width = "half",
                hidden = function() return iconHidden() or not db().showViolations end,
                get  = function() return db().violOffX or 0 end,
                set  = function(_, v)
                    db().violOffX = v
                    local w = entry.widget
                    if w and w._violText then
                        w._violText:ClearAllPoints()
                        w._violText:SetPoint("CENTER", w._icon, "CENTER", v, db().violOffY or -20)
                    end
                    if w and w._violTextHandle and w._violTextHandle._resync then w._violTextHandle._resync() end
                end,
            },
            violOffY = {
                type = "range", name = "Offset Y",
                min = -100, max = 100, step = 1,
                order = o(), width = "half",
                hidden = function() return iconHidden() or not db().showViolations end,
                get  = function() return db().violOffY or -20 end,
                set  = function(_, v)
                    db().violOffY = v
                    local w = entry.widget
                    if w and w._violText then
                        w._violText:ClearAllPoints()
                        w._violText:SetPoint("CENTER", w._icon, "CENTER", db().violOffX or 0, v)
                    end
                    if w and w._violTextHandle and w._violTextHandle._resync then w._violTextHandle._resync() end
                end,
            },
            violInputX = {
                type = "input", name = "X (exact)",
                desc = "Type an exact X offset (overrides the slider's -100..100 range).",
                order = o(), width = "half",
                hidden = function() return iconHidden() or not db().showViolations end,
                get  = function() return tostring(db().violOffX or 0) end,
                set  = function(_, v)
                    local n = tonumber(v); if not n then return end
                    db().violOffX = math.floor(n + 0.5)
                    local w = entry.widget
                    if w and w._violText then
                        w._violText:ClearAllPoints()
                        w._violText:SetPoint("CENTER", w._icon, "CENTER", db().violOffX, db().violOffY or -20)
                    end
                    if w and w._violTextHandle and w._violTextHandle._resync then w._violTextHandle._resync() end
                end,
            },
            violInputY = {
                type = "input", name = "Y (exact)",
                desc = "Type an exact Y offset (overrides the slider's -100..100 range).",
                order = o(), width = "half",
                hidden = function() return iconHidden() or not db().showViolations end,
                get  = function() return tostring(db().violOffY or -20) end,
                set  = function(_, v)
                    local n = tonumber(v); if not n then return end
                    db().violOffY = math.floor(n + 0.5)
                    local w = entry.widget
                    if w and w._violText then
                        w._violText:ClearAllPoints()
                        w._violText:SetPoint("CENTER", w._icon, "CENTER", db().violOffX or 0, db().violOffY)
                    end
                    if w and w._violTextHandle and w._violTextHandle._resync then w._violTextHandle._resync() end
                end,
            },
            violColor = {
                type = "color", name = "Color",
                order = o(), width = "full", hasAlpha = false,
                hidden = function() return iconHidden() or not db().showViolations end,
                get  = function() return db().violR or 1, db().violG or 0.2, db().violB or 0.2 end,
                set  = function(_, r, g, b)
                    local d = db(); d.violR=r; d.violG=g; d.violB=b
                    local w = entry.widget
                    if w and w._violText then w._violText:SetTextColor(r, g, b) end
                end,
            },
        },
    }
end

local optionsRegistered = false

local function BuildMasterOptionsTable()
    local args = {}
    local order = 1

    -- ── General tab (appears last) ───────────────────────────────────────────
    args.general = {
        type        = "group",
        name        = "General",
        order       = 999,
        args = {
            minimapHeader = {
                type = "header", name = "Minimap Button", order = 1,
            },
            hideMinimap = {
                type  = "toggle",
                name  = "Hide Minimap Button",
                desc  = "Hide the ProcTracker icon on the minimap. You can still open options with /pt.",
                order = 2,
                width = "full",
                get = function()
                    local db = ArcUI_ProcTrackerDB or {}
                    return db.minimap and db.minimap.hide == true
                end,
                set = function(_, v)
                    ArcUI_ProcTrackerDB = ArcUI_ProcTrackerDB or {}
                    ArcUI_ProcTrackerDB.minimap = ArcUI_ProcTrackerDB.minimap or {}
                    ArcUI_ProcTrackerDB.minimap.hide = v and true or false
                    if LDBIcon then
                        if v then LDBIcon:Hide("ArcUI_ProcTracker")
                        else      LDBIcon:Show("ArcUI_ProcTracker") end
                    end
                end,
            },
        },
    }

    for _, entry in ipairs(registry) do
        -- Build icon sub-group from existing BuildDeckOptionsGroup
        local iconGroup = BuildDeckOptionsGroup(entry)
        iconGroup.name        = "Icon"
        iconGroup.order       = 1
        iconGroup.type        = "group"

        -- Build bar sub-group from bar module if loaded
        local barGroup
        if PT.BuildBarOptionsGroup then
            local barArgs = PT.BuildBarOptionsGroup(entry)
            barGroup = {
                type  = "group",
                name  = "Bar",
                order = 2,
                args  = barArgs,
            }
        end

        -- Deck tab wraps both sub-groups
        local deckTab = {
            type        = "group",
            name        = entry.name,
            order       = order,
            childGroups = "tab",
            args        = {
                icon = iconGroup,
                bar  = barGroup or {
                    type = "group", name = "Bar", order = 2,
                    args = {
                        noBar = {
                            type = "description", order = 1,
                            name = "|cff888888Bar module not loaded.|r",
                        }
                    }
                },
            },
        }
        args[entry.id] = deckTab
        order = order + 1
    end
    return {
        type        = "group",
        name        = "Proc Deck Tracker",
        childGroups = "tab",
        args        = args,
    }
end

local function RefreshMasterOptions()
    if not AceConfig or not AceConfigDialog then return end
    AceConfig:RegisterOptionsTable(PT_OPTIONS_NAME, BuildMasterOptionsTable())
    optionsRegistered = true
end

BuildOptionsPanel = function(entry)
    if not AceConfig or not AceConfigDialog then
        print("|cffFF4444ProcTracker:|r AceConfig not available")
        return
    end

    RefreshMasterOptions()

    local frame = AceConfigDialog.OpenFrames and AceConfigDialog.OpenFrames[PT_OPTIONS_NAME]
    if frame and frame.frame and frame.frame:IsShown() then
        AceConfigDialog:Close(PT_OPTIONS_NAME)
    else
        AceConfigDialog:Open(PT_OPTIONS_NAME)
        if entry then
            C_Timer.After(0.05, function()
                AceConfigDialog:SelectGroup(PT_OPTIONS_NAME, entry.id)
            end)
        end
        C_Timer.After(0.05, function()
            local f2 = AceConfigDialog.OpenFrames[PT_OPTIONS_NAME]
            if not f2 or not f2.frame then return end
            local af = f2.frame
            af:SetWidth(420)
            af:ClearAllPoints()
            af:SetPoint("CENTER")
            if not af._ptSolidBg then
                af._ptSolidBg = CreateFrame("Frame", nil, af)
                af._ptSolidBg:SetPoint("TOPLEFT",     af, "TOPLEFT",     8, -8)
                af._ptSolidBg:SetPoint("BOTTOMRIGHT", af, "BOTTOMRIGHT", -8, 8)
                af._ptSolidBg:SetFrameLevel(math.max(1, af:GetFrameLevel() - 1))
                local tex = af._ptSolidBg:CreateTexture(nil, "BACKGROUND")
                tex:SetAllPoints()
                tex:SetColorTexture(0.12, 0.12, 0.12, 0.95)
            end
            af._ptSolidBg:Show()
        end)
    end
end
-- ── Public API ────────────────────────────────────────────────────────────────
-- Deck modules subscribe here to retry registration on PLAYER_ENTERING_WORLD
PT.OnEnterWorld = {}  -- array of functions — deck modules subscribe to retry registration

-- PT.RegisterDeck(def)
-- def = {
--   id          = "dw",           -- unique string key
--   name        = "Doom Winds",    -- display name
--   deckSize    = 600,             -- stacks per deck
--   procs       = 3,               -- expected procs per deck
--   defaultIcon = 384352,          -- spell ID or file ID for default texture
--   GetDeckPos  = function() return currentPos end,   -- 0-based position in deck
--   GetProcs    = function() return currentProcs end, -- completed procs this deck
--   OnReset     = function() ... end,  -- called when user hits Reset Deck
--   OnEnable    = function() ... end,  -- called after widget is built
-- }
function PT.RegisterDeck(def)
    assert(def.id,          "PT.RegisterDeck: missing id")
    assert(def.name,        "PT.RegisterDeck: missing name")
    assert(def.deckSize,    "PT.RegisterDeck: missing deckSize")
    assert(def.procs,       "PT.RegisterDeck: missing procs")
    assert(def.GetDeckPos,  "PT.RegisterDeck: missing GetDeckPos")
    assert(def.GetProcs,    "PT.RegisterDeck: missing GetProcs")
    -- Idempotent — ignore if already registered with this id
    if registryMap[def.id] then return end
    def.defaultIcon = def.defaultIcon or 136048
    def.widget   = nil
    def.optPanel = nil
    registry[#registry+1] = def
    registryMap[def.id]   = def
    -- If ADDON_LOADED already fired, build the widget immediately
    if ArcUI_ProcTrackerDB then
        BuildIconWidget(def)
        if def.OnEnable then def.OnEnable() end
        optionsRegistered = false  -- refresh options so new tab appears
    end
end

-- Call from a deck module to trigger icon redraw after state change
function PT.UpdateDeck(id)
    local entry = registryMap[id]
    if entry then UpdateIcon(entry) end
end

-- Get a registered deck entry by id
function PT.GetDeck(id)
    return registryMap[id]
end

-- Iterate all registered decks
function PT.ForEachDeck(fn)
    for _, entry in ipairs(registry) do fn(entry) end
end

-- Safe show for talent-driven visibility — respects user's deckEnabled setting.
-- Deck modules call this instead of entry.widget:Show() directly.
function PT.ShowDeckIconIfEnabled(id)
    local entry = registryMap[id]
    if not entry or not entry.widget then return end
    local idb = IconDB(id)
    if idb.deckEnabled ~= false then
        entry.widget:Show()
    end
end

-- ── Lifecycle ─────────────────────────────────────────────────────────────────
local watchFrame = CreateFrame("Frame")
watchFrame:RegisterEvent("ADDON_LOADED")
watchFrame:RegisterEvent("PLAYER_LOGIN")
watchFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
-- COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED handled via CooldownViewerItemDataMixin hooks below

watchFrame:SetScript("OnEvent", function(_, event, a1, a2)
    if event == "ADDON_LOADED" and a1 == "ArcUI_ProcTracker" then
        ArcUI_ProcTrackerDB = ArcUI_ProcTrackerDB or {}
        -- Build icons for all registered decks
        for _, entry in ipairs(registry) do
            BuildIconWidget(entry)
            if entry.OnEnable then entry.OnEnable() end
        end
        InitMinimapButton()
        print("|cffFFAA00ProcTracker|r loaded — " .. #registry .. " deck(s) active  |cff888888/pt for options|r")
        return
    end

    if event == "PLAYER_LOGIN" then
        -- C_ClassTalents becomes available shortly after PLAYER_LOGIN
        -- Retry deck registration in case talents weren't ready at file load time
        C_Timer.After(0.5, function()
            for _, fn in ipairs(PT.OnEnterWorld) do fn() end
            -- Build widgets for any newly registered decks
            for _, entry in ipairs(registry) do
                if not entry.widget and ArcUI_ProcTrackerDB then
                    BuildIconWidget(entry)
                    if entry.OnEnable then entry.OnEnable() end
                end
            end
        end)
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        local isLogin, isReload = a1, a2
        -- Fire OnEnterWorld callbacks so deck modules can retry TryRegisterDeck
        -- (C_ClassTalents is not ready at ADDON_LOADED on fresh login)
        for _, fn in ipairs(PT.OnEnterWorld) do fn() end
        for _, entry in ipairs(registry) do
            -- Only reset on fresh login — NOT on reload or zone transition
            if isLogin and not isReload then
                if entry.OnReset then entry.OnReset() end
            end
            UpdateIcon(entry)
        end
        return
    end

end)

-- ── CDM change detection ────────────────────────────────────────────────────
-- RefreshLayout calls itemFramePool:ReleaseAll() silently (no ClearCooldownID),
-- then acquires new frames and calls SetCooldownID. So hooking ClearCooldownID
-- never fires on remove. The correct signal is:
--   1. CooldownViewerSettings.OnDataChanged  — fires when user adds/removes in CDM UI
--   2. hooksecurefunc CooldownViewerMixin.OnAcquireItemFrame — fires after ReleaseAll
--      for each new frame, letting us invalidate stale refs and rehook
-- Both paths funnel into SchedulePTCDMRehook which nils stale frames + rehooks.
local _ptCDMRehookPending = false

local function InvalidateAllCDMFrames()
    -- Always invalidate immediately so IsCDMTracking is accurate and rehook fires.
    for _, entry in ipairs(registry) do
        if not entry.noCDMWarn then
            local ns = GetDeckNS(entry.id)
            if ns and ns.InvalidateFrame then
                ns.InvalidateFrame(nil)
            end
        end
    end
end

local function SchedulePTCDMRehook()
    if _ptCDMRehookPending then return end
    _ptCDMRehookPending = true
    -- Rehook immediately so the frame ref is restored ASAP.
    -- Do NOT update the overlay yet — CDM reassigns within milliseconds in combat.
    -- Only show ! if the frame is STILL missing after 1s.
    for _, entry in ipairs(registry) do
        if not entry.noCDMWarn then
            local ns = GetDeckNS(entry.id)
            if ns and ns.RehookCDM then ns.RehookCDM() end
        end
    end
    C_Timer.After(1.0, function()
        _ptCDMRehookPending = false
        for _, entry in ipairs(registry) do
            if not entry.noCDMWarn then
                local ns = GetDeckNS(entry.id)
                if ns and ns.RehookCDM then ns.RehookCDM() end
            end
            UpdateIcon(entry)
        end
        if AceConfigRegistry and optionsRegistered then
            AceConfigRegistry:NotifyChange(PT_OPTIONS_NAME)
        end
    end)
end

local function InstallCDMMixinHooks()
    -- Hook SetCooldownID on the mixin — fires during RefreshData after ReleaseAll
    if CooldownViewerItemDataMixin and CooldownViewerItemDataMixin.SetCooldownID then
        if not CooldownViewerItemDataMixin._arcPTCDMSetHooked then
            CooldownViewerItemDataMixin._arcPTCDMSetHooked = true
            hooksecurefunc(CooldownViewerItemDataMixin, "SetCooldownID", function(self, cooldownID)
                -- Fires for EVERY frame after a reshuffle — just schedule rehook
                SchedulePTCDMRehook()
            end)
        end
    end
    -- Hook OnAcquireItemFrame on CooldownViewerMixin — fires right after ReleaseAll
    -- for each new frame. This is our earliest signal that a reshuffle happened.
    if CooldownViewerMixin and CooldownViewerMixin.OnAcquireItemFrame then
        if not CooldownViewerMixin._arcPTAcquireHooked then
            CooldownViewerMixin._arcPTAcquireHooked = true
            hooksecurefunc(CooldownViewerMixin, "OnAcquireItemFrame", function()
                -- ReleaseAll just happened — all our cached frame refs are now stale
                InvalidateAllCDMFrames()
                SchedulePTCDMRehook()
            end)
        end
    end
    -- EventRegistry: CooldownViewerSettings.OnDataChanged fires when user
    -- adds/removes/reorders in CDM settings panel — earliest possible signal
    if EventRegistry and EventRegistry.RegisterCallback then
        EventRegistry:RegisterCallback("CooldownViewerSettings.OnDataChanged", function()
            InvalidateAllCDMFrames()
            SchedulePTCDMRehook()
        end, "ArcUI_ProcTracker_CDM")
    end
end
InstallCDMMixinHooks()

-- ── Slash command ─────────────────────────────────────────────────────────────
-- ── Combat reset events ─────────────────────────────────────────────────────
-- All decks share the same reset conditions — managed centrally here.
local function ResetAllDecks()
    -- Reset shared MSW module first so deck resets see clean state
    if PT.MSW and PT.MSW.Reset then PT.MSW.Reset() end
    for id, entry in pairs(registryMap) do
        if entry.OnReset then entry.OnReset() end
    end
    -- Re-init MSW from live after all decks reset
    if PT.MSW and PT.MSW.InitFromLive then PT.MSW.InitFromLive() end
end

local cmResetArmed = false; local cmResetStartTS = nil; local cmResetInstID = nil
local resetEventFrame = CreateFrame("Frame")
resetEventFrame:RegisterEvent("ENCOUNTER_START")
resetEventFrame:RegisterEvent("CHALLENGE_MODE_RESET")
resetEventFrame:RegisterEvent("WORLD_STATE_TIMER_START")
resetEventFrame:SetScript("OnEvent", function(_, event, a1)
    if event == "ENCOUNTER_START" then
        local diff = select(3, GetInstanceInfo())
        -- 14-17 = Normal/Heroic/Mythic/LFR raids; 233 = Mythic Flexible (added in 12.0.7)
        if diff and ((diff >= 14 and diff <= 17) or diff == 233) then ResetAllDecks() end
        return
    end
    if event == "CHALLENGE_MODE_RESET" then
        cmResetArmed = true; cmResetStartTS = GetTime()
        cmResetInstID = select(8, GetInstanceInfo()); return
    end
    if event == "WORLD_STATE_TIMER_START" and cmResetArmed then
        if a1 == 1 then
            local inInst, instType = IsInInstance()
            local diff   = select(3, GetInstanceInfo())
            local instID = select(8, GetInstanceInfo())
            if inInst and instType == "party" and diff == 8 and instID == cmResetInstID
            and (GetTime() - (cmResetStartTS or 0)) <= 9 then ResetAllDecks() end
        end
        cmResetArmed = false; cmResetStartTS = nil; cmResetInstID = nil; return
    end
end)

-- /pt           → list decks
-- /pt dw        → open DW icon options
-- /pt reset dw  → reset DW deck
-- ── Minimap button ───────────────────────────────────────────────────────────
LDB     = LibStub and LibStub("LibDataBroker-1.1", true)
LDBIcon = LibStub and LibStub("LibDBIcon-1.0", true)

local ptLDB = LDB and LDB:NewDataObject("ArcUI_ProcTracker", {
    type = "launcher",
    text = "Proc Tracker",
    icon = "Interface\\AddOns\\ArcUI_ProcTracker\\Textures\\PT_Icon_400x400",
    OnClick = function(self, button)
        if button == "RightButton" then
            -- Right click: toggle Tempest debug timeline
            if ArcUI_PT_TempestDebug then
                ArcUI_PT_TempestDebug.Toggle()
            else
                print("|cffFF4444ProcTracker:|r TempestDebug not loaded")
            end
            return
        end
        -- Left click: list all decks, open first one
        for _, entry in ipairs(registry) do
            BuildOptionsPanel(entry)
            return
        end
    end,
    OnTooltipShow = function(tooltip)
        if not tooltip or not tooltip.AddLine then return end
        tooltip:SetText("|cffFFAA00Proc Tracker|r")
        tooltip:AddLine("Left-click: open options", 0.7, 0.7, 0.7)
        tooltip:AddLine("Right-click: cycle decks", 0.7, 0.7, 0.7)
        tooltip:AddLine("|cff888888/pt for commands|r", 0.5, 0.5, 0.5)
        for _, entry in ipairs(registry) do
            local pos  = entry.GetDeckPos()
            local db   = IconDB(entry.id)
            local disp = db.countDown and (entry.deckSize - pos) or pos
            tooltip:AddLine(entry.name .. ":  " .. disp .. "/" .. entry.deckSize
                .. "  procs=" .. entry.GetProcs() .. "/" .. entry.procs,
                1, 0.85, 0)
        end
    end,
})

InitMinimapButton = function()
    if not LDB or not LDBIcon or not ptLDB then
        print("|cffFF4444ProcTracker:|r LibDBIcon not found — minimap button unavailable")
        return
    end
    local db = GetDB()
    db.minimap = db.minimap or {}
    LDBIcon:Register("ArcUI_ProcTracker", ptLDB, db.minimap)
    if db.minimap.hide then
        LDBIcon:Hide("ArcUI_ProcTracker")
    else
        LDBIcon:Show("ArcUI_ProcTracker")
    end
end

SLASH_ARCPROCTRACKER1 = "/pt"
SlashCmdList["ARCPROCTRACKER"] = function(arg)
    arg = arg and arg:match("^%s*(.-)%s*$") or ""

    if arg == "" then
        BuildOptionsPanel(registry[1])
        return
    end

    -- /pt reset <id>
    local resetID = arg:match("^reset%s+(.+)$")
    if resetID then
        local entry = registryMap[resetID]
        if entry then
            if entry.OnReset then entry.OnReset() end
            UpdateIcon(entry)
            print("|cffFFAA00ProcTracker|r reset deck: " .. entry.name)
        else
            print("|cffFF4444ProcTracker:|r unknown deck '" .. resetID .. "'")
        end
        return
    end

    -- /pt <id> → open panel on that deck's tab
    local entry = registryMap[arg]
    if entry then
        BuildOptionsPanel(entry)
        return
    end

    -- /pt tdebug → toggle Tempest timeline debugger
    -- /pt tdebug start → silent background logging (no window)
    -- /pt tdebug export → open window and trigger export
    if arg == "tdebug" or arg:sub(1,7) == "tdebug " then
        if not ArcUI_PT_TempestDebug then
            print("|cffFF4444ProcTracker:|r TempestDebug not loaded")
            return
        end
        local sub = arg:sub(8)  -- everything after "tdebug "
        if sub == "start" then
            ArcUI_PT_TempestDebug.StartSilent()
        elseif sub == "export" then
            if not ArcUI_PT_TempestDebug.IsEnabled() then
                ArcUI_PT_TempestDebug.StartSilent()
            end
            ArcUI_PT_TempestDebug.Toggle()  -- open window
            C_Timer.After(0.1, function()
                ArcUI_PT_TempestDebug.Export()
            end)
        else
            ArcUI_PT_TempestDebug.Toggle()
        end
        return
    end

    -- /pt etdebug → toggle Elemental Tempest timeline debugger
    -- /pt etdebug start → silent background logging
    -- /pt etdebug export → open window and export
    if arg == "etdebug" or arg:sub(1,8) == "etdebug " then
        if not PT.ElemTempestDebug then
            print("|cffFF4444ProcTracker:|r ElemTempestDebug not loaded")
            return
        end
        local sub = arg:sub(9)
        if sub == "start" then
            PT.ElemTempestDebug.StartSilent()
        elseif sub == "export" then
            PT.ElemTempestDebug.Toggle()
            C_Timer.After(0.1, function()
                PT.ElemTempestDebug.Export()
            end)
        else
            PT.ElemTempestDebug.Toggle()
        end
        return
    end

    -- /pt dwdebug → toggle Doom Winds timeline debugger
    -- /pt dwdebug export → open window and export
    if arg == "dwdebug" or arg:sub(1,8) == "dwdebug " then
        if not ArcUI_PT_DWDebug then
            print("|cffFF4444ProcTracker:|r DWDebug not loaded")
            return
        end
        local sub = arg:sub(9)
        if sub == "export" then
            if not ArcUI_PT_DWDebug.IsEnabled() then ArcUI_PT_DWDebug.Toggle() end
            C_Timer.After(0.1, function() ArcUI_PT_DWDebug.Export() end)
        else
            ArcUI_PT_DWDebug.Toggle()
        end
        return
    end

    -- /pt dredebug → toggle DRE Ascendance deck debugger
    if arg == "dredebug" then
        if not ArcUI_PT_DREDebug then
            print("|cffFF4444ProcTracker:|r DREDebug not loaded")
            return
        end
        ArcUI_PT_DREDebug.Toggle()
        return
    end

    -- /pt minimap
    if arg == "minimap" then
        local db = GetDB()
        db.minimap = db.minimap or {}
        db.minimap.hide = not db.minimap.hide
        if not LDBIcon or not ptLDB then return end
        if db.minimap.hide then
            LDBIcon:Hide("ArcUI_ProcTracker")
            print("|cffFFAA00ProcTracker|r minimap button hidden  |cff888888/pt minimap to show|r")
        else
            LDBIcon:Show("ArcUI_ProcTracker")
            print("|cffFFAA00ProcTracker|r minimap button shown")
        end
        return
    end

    print("|cffFF4444ProcTracker:|r unknown command '" .. arg .. "'")
end