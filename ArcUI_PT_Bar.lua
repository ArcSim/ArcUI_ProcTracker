-- ArcUI_PT_Bar.lua
-- Bar widget for ProcTracker decks.
-- StatusBar fill, tick marks at exact proc positions, two independent text frames.
-- Text frames support free-drag OR anchor-to-bar with offset.
-- No pcall. Zero polling.

-- ── Bar textures ──────────────────────────────────────────────────────────────
local BAR_TEXTURES = {
    ["Blizzard"]   = "Interface\\TargetingFrame\\UI-StatusBar",
    ["Solid"]      = "Interface\\Buttons\\WHITE8X8",
    ["Minimalist"] = "Interface\\ChatFrame\\ChatFrameBackground",
    ["Aluminium"]  = "Interface\\PaperDollInfoFrame\\UI-Character-Skills-Bar",
    ["Otravi"]     = "Interface\\RaidFrame\\Raid-Bar-Hp-Fill",
    ["Armory"]     = "Interface\\PVPFrame\\UI-PVP-Capture-Bar-Fill",
}
local BAR_TEXTURE_KEYS = { "Blizzard","Solid","Minimalist","Aluminium","Otravi","Armory" }

-- Anchor options for text frames
local ANCHOR_POINTS = {
    FREE        = "Free (drag anywhere)",
    TOPLEFT     = "Top Left of Bar",
    TOP         = "Top of Bar (center)",
    TOPRIGHT    = "Top Right of Bar",
    LEFT        = "Left of Bar (center)",
    CENTER      = "Center of Bar",
    RIGHT       = "Right of Bar (center)",
    BOTTOMLEFT  = "Bottom Left of Bar",
    BOTTOM      = "Bottom of Bar (center)",
    BOTTOMRIGHT = "Bottom Right of Bar",
}
local ANCHOR_POINT_KEYS = {
    "FREE","TOPLEFT","TOP","TOPRIGHT","LEFT","CENTER","RIGHT","BOTTOMLEFT","BOTTOM","BOTTOMRIGHT"
}

-- ── SavedVariables defaults ───────────────────────────────────────────────────
local BAR_DEFAULTS = {
    barEnabled     = false,
    barX=0, barY=130,
    barW=200, barH=16,
    barVertical    = false,
    barRotateFill  = false,
    barCountDown   = true,
    barStrata      = "HIGH",
    barLevel       = 5,
    barLockPos     = false,
    barTexture     = "Blizzard",
    -- Fill colors
    barEmptyR=0.0, barEmptyG=1.0,  barEmptyB=0.0, barEmptyA=1.0,
    barHalfR =1.0, barHalfG =0.82, barHalfB =0.0, barHalfA =1.0,
    barFullR =1.0, barFullG =0.0,  barFullB =0.0, barFullA =1.0,
    -- Background
    barBgR=0.08, barBgG=0.08, barBgB=0.08, barBgA=0.85,
    -- Border
    barBorderEnabled=true,
    barBorderR=0.35, barBorderG=0.35, barBorderB=0.35, barBorderA=1.0,
    barBorderThickness=1,
    -- Tick marks
    barTickEnabled=true,
    barTickR=1.0, barTickG=1.0, barTickB=0.0, barTickA=1.0,
    barTickThickness=2,
    -- Deck position text
    barScale=1.0,
    -- Deck position text
    barDeckTextEnabled=false,
    barDeckTextAnchor="CENTER",
    barDeckTextX=0, barDeckTextY=110,
    barDeckTextOffX=0, barDeckTextOffY=0,
    barDeckTextSize=14,
    barDeckTextR=1.0, barDeckTextG=1.0, barDeckTextB=1.0, barDeckTextA=1.0,
    barDeckTextUseStateColor=false,
    -- Deck text state colors (independent from bar fill colors)
    barDeckTextEmptyR=0.0, barDeckTextEmptyG=1.0,  barDeckTextEmptyB=0.0, barDeckTextEmptyA=1.0,
    barDeckTextHalfR =1.0, barDeckTextHalfG =0.82, barDeckTextHalfB =0.0, barDeckTextHalfA =1.0,
    barDeckTextFullR =1.0, barDeckTextFullG =0.0,  barDeckTextFullB =0.0, barDeckTextFullA =1.0,
    barDeckCountDown=true,
    -- Proc count text
    barProcTextEnabled=true,
    barProcTextAnchor="TOP",
    barProcTextX=0, barProcTextY=108,
    barProcTextOffX=0, barProcTextOffY=2,
    barProcTextSize=14,
    barProcTextR=1.0, barProcTextG=1.0, barProcTextB=1.0, barProcTextA=1.0,
    barProcTextUseStateColor=true,
    -- Proc text state colors (independent from bar fill colors)
    barProcTextEmptyR=0.0, barProcTextEmptyG=1.0,  barProcTextEmptyB=0.0, barProcTextEmptyA=1.0,
    barProcTextHalfR =1.0, barProcTextHalfG =0.82, barProcTextHalfB =0.0, barProcTextHalfA =1.0,
    barProcTextFullR =1.0, barProcTextFullG =0.0,  barProcTextFullB =0.0, barProcTextFullA =1.0,
    barProcCountDown=true,
    barProcShowSuffix=false,
    barDeckShowSuffix=false,
    barDefaultsVersion=2,   -- bump to force anchor migration on existing saves
    -- Fill direction
    barFillReverse=false,   -- reverse fill start edge (top/right instead of bottom/left)
    -- Separate empty color for bar texture vs text
    barTexEmptyR=0.15, barTexEmptyG=0.15, barTexEmptyB=0.15, barTexEmptyA=0.6,
    barTexUseEmptyColor=false,   -- when false, bar goes transparent at 0 procs; when true uses barTexEmpty color
    -- Icon on bar
    barIconEnabled=false,
    barIconFileID=nil,      -- nil = use deck default icon
    barIconAnchor="LEFT",
    barIconOffX=0, barIconOffY=0,
    barIconSize=16,
    -- Icon border
    barIconBorderEnabled=false,
    barIconBorderR=1.0, barIconBorderG=1.0, barIconBorderB=1.0, barIconBorderA=1.0,
    barIconBorderThickness=1,
}

local MAX_TICKS = 16

local BAR_APPEARANCE_KEYS = {
    "barW","barH","barScale","barVertical","barRotateFill","barFillReverse","barCountDown",
    "barTexture",
    "barEmptyR","barEmptyG","barEmptyB","barEmptyA",
    "barHalfR","barHalfG","barHalfB","barHalfA",
    "barFullR","barFullG","barFullB","barFullA",
    "barBgR","barBgG","barBgB","barBgA",
    "barTexUseEmptyColor","barTexEmptyR","barTexEmptyG","barTexEmptyB","barTexEmptyA",
    "barBorderEnabled","barBorderR","barBorderG","barBorderB","barBorderA","barBorderThickness",
    "barTickEnabled","barTickR","barTickG","barTickB","barTickA","barTickThickness",
    "barIconEnabled","barIconFileID","barIconAnchor","barIconOffX","barIconOffY","barIconSize",
    "barIconBorderEnabled","barIconBorderR","barIconBorderG","barIconBorderB","barIconBorderA","barIconBorderThickness",
    "barDeckTextEnabled","barDeckTextAnchor","barDeckTextOffX","barDeckTextOffY","barDeckTextSize",
    "barDeckTextR","barDeckTextG","barDeckTextB","barDeckTextA","barDeckTextUseStateColor",
    "barDeckTextEmptyR","barDeckTextEmptyG","barDeckTextEmptyB","barDeckTextEmptyA",
    "barDeckTextHalfR","barDeckTextHalfG","barDeckTextHalfB","barDeckTextHalfA",
    "barDeckTextFullR","barDeckTextFullG","barDeckTextFullB","barDeckTextFullA",
    "barDeckCountDown","barDeckShowSuffix",
    "barProcTextEnabled","barProcTextAnchor","barProcTextOffX","barProcTextOffY","barProcTextSize",
    "barProcTextR","barProcTextG","barProcTextB","barProcTextA","barProcTextUseStateColor",
    "barProcTextEmptyR","barProcTextEmptyG","barProcTextEmptyB","barProcTextEmptyA",
    "barProcTextHalfR","barProcTextHalfG","barProcTextHalfB","barProcTextHalfA",
    "barProcTextFullR","barProcTextFullG","barProcTextFullB","barProcTextFullA",
    "barProcCountDown","barProcShowSuffix",
}

-- ── Per-deck proc position tracking ──────────────────────────────────────────
local procPositions = {}
local lastProcCount = {}

-- ── DB helpers ────────────────────────────────────────────────────────────────
local function GetDB()
    ArcUI_ProcTrackerDB = ArcUI_ProcTrackerDB or {}
    return ArcUI_ProcTrackerDB
end
local function BarDB(id)
    local db = GetDB()
    db.bars = db.bars or {}
    db.bars[id] = db.bars[id] or {}
    local t = db.bars[id]
    for k, v in pairs(BAR_DEFAULTS) do
        if t[k] == nil then t[k] = v end
    end
    -- Migration: if anchors are FREE from old default, reset to correct anchors
    if (t.barDefaultsVersion or 1) < 2 then
        t.barDeckTextAnchor = "CENTER"
        t.barProcTextAnchor = "TOP"
        t.barProcShowSuffix = false
        t.barDeckCountDown  = true
        t.barProcCountDown  = true
        t.barCountDown      = true
        t.barDefaultsVersion = 2
    end
    return t
end

-- ── Proc color (for text — uses barEmpty/Half/Full) ─────────────────────────
local function TextProcColor(db, procs, maxProcs)
    if db.barProcCountDown then
        local rem = maxProcs - procs
        if rem == maxProcs then return db.barEmptyR,db.barEmptyG,db.barEmptyB,db.barEmptyA
        elseif rem > 0     then return db.barHalfR, db.barHalfG, db.barHalfB, db.barHalfA
        else                    return db.barFullR, db.barFullG, db.barFullB, db.barFullA end
    else
        if procs == 0           then return db.barEmptyR,db.barEmptyG,db.barEmptyB,db.barEmptyA
        elseif procs < maxProcs then return db.barHalfR, db.barHalfG, db.barHalfB, db.barHalfA
        else                         return db.barFullR, db.barFullG, db.barFullB, db.barFullA end
    end
end

-- ── Per-text state color (each text has its own independent state colors) ──────
local function DeckTextStateColor(db, procs, maxProcs)
    if db.barProcCountDown then
        local rem = maxProcs - procs
        if rem == maxProcs then return db.barDeckTextEmptyR,db.barDeckTextEmptyG,db.barDeckTextEmptyB,db.barDeckTextEmptyA
        elseif rem > 0     then return db.barDeckTextHalfR, db.barDeckTextHalfG, db.barDeckTextHalfB, db.barDeckTextHalfA
        else                    return db.barDeckTextFullR, db.barDeckTextFullG, db.barDeckTextFullB, db.barDeckTextFullA end
    else
        if procs == 0           then return db.barDeckTextEmptyR,db.barDeckTextEmptyG,db.barDeckTextEmptyB,db.barDeckTextEmptyA
        elseif procs < maxProcs then return db.barDeckTextHalfR, db.barDeckTextHalfG, db.barDeckTextHalfB, db.barDeckTextHalfA
        else                         return db.barDeckTextFullR, db.barDeckTextFullG, db.barDeckTextFullB, db.barDeckTextFullA end
    end
end

local function ProcTextStateColor(db, procs, maxProcs)
    if db.barProcCountDown then
        local rem = maxProcs - procs
        if rem == maxProcs then return db.barProcTextEmptyR,db.barProcTextEmptyG,db.barProcTextEmptyB,db.barProcTextEmptyA
        elseif rem > 0     then return db.barProcTextHalfR, db.barProcTextHalfG, db.barProcTextHalfB, db.barProcTextHalfA
        else                    return db.barProcTextFullR, db.barProcTextFullG, db.barProcTextFullB, db.barProcTextFullA end
    else
        if procs == 0           then return db.barProcTextEmptyR,db.barProcTextEmptyG,db.barProcTextEmptyB,db.barProcTextEmptyA
        elseif procs < maxProcs then return db.barProcTextHalfR, db.barProcTextHalfG, db.barProcTextHalfB, db.barProcTextHalfA
        else                         return db.barProcTextFullR, db.barProcTextFullG, db.barProcTextFullB, db.barProcTextFullA end
    end
end

-- ── Bar fill color (separate empty override for the bar texture itself) ───────
local function BarFillColor(db, procs, maxProcs)
    if procs == 0 and db.barTexUseEmptyColor then
        return db.barTexEmptyR, db.barTexEmptyG, db.barTexEmptyB, db.barTexEmptyA
    end
    -- half/full states same as text
    if db.barProcCountDown then
        local rem = maxProcs - procs
        if rem == maxProcs then return db.barEmptyR,db.barEmptyG,db.barEmptyB,db.barEmptyA
        elseif rem > 0     then return db.barHalfR, db.barHalfG, db.barHalfB, db.barHalfA
        else                    return db.barFullR, db.barFullG, db.barFullB, db.barFullA end
    else
        if procs == 0           then return db.barEmptyR,db.barEmptyG,db.barEmptyB,db.barEmptyA
        elseif procs < maxProcs then return db.barHalfR, db.barHalfG, db.barHalfB, db.barHalfA
        else                         return db.barFullR, db.barFullG, db.barFullB, db.barFullA end
    end
end

-- ── Text anchor ───────────────────────────────────────────────────────────────
local function ApplyTextAnchor(tf, barFrame, anchor, offX, offY, freeX, freeY)
    tf:ClearAllPoints()
    if anchor == "FREE" or not barFrame then
        tf:SetPoint("CENTER", UIParent, "CENTER", freeX, freeY)
    else
        tf:SetPoint(anchor, barFrame, anchor, offX, offY)
    end
end

-- ── Update ────────────────────────────────────────────────────────────────────
local function HideAllBarElements(entry)
    local bw = entry.barWidget
    if bw then bw:Hide() end
    if bw and bw._deckTextFrame then bw._deckTextFrame:Hide() end
    if bw and bw._procTextFrame then bw._procTextFrame:Hide() end
    -- icon is child of bw so hides with it, but hide explicitly for safety
    if bw and bw._barIcon then bw._barIcon:Hide() end
end

local function UpdateBar(entry)
    local bw = entry.barWidget
    if not bw then return end
    local db = BarDB(entry.id)
    -- If bar disabled, ensure everything is hidden and bail
    if not db.barEnabled then
        HideAllBarElements(entry)
        return
    end
    if not bw:IsShown() then return end

    local db       = BarDB(entry.id)
    local deckSize = entry.deckSize
    local maxProcs = entry.procs
    local raw      = entry.GetDeckPos()
    local procs    = entry.GetProcs()
    local vert     = db.barVertical
    local bW, bH   = db.barW, db.barH
    -- fillVal: countDown=drain from full (bar empties as stacks are spent)
    local fillVal  = db.barCountDown and (deckSize - raw) or raw
    -- Note: fill direction is handled by SetReverseFill on the StatusBar
    local r,g,b,a      = TextProcColor(db, procs, maxProcs)
    local br,bg_,bb_,ba_ = BarFillColor(db, procs, maxProcs)

    -- Vertical: swap W/H on the frame so bar stands upright
    if vert then
        bw:SetSize(bH, bW)
    else
        bw:SetSize(bW, bH)
    end
    bw:SetScale(db.barScale or 1.0)
    local curStrata = db.barStrata or "HIGH"
    local curLevel  = db.barLevel or 5
    bw:SetFrameStrata(curStrata)
    bw:SetFrameLevel(curLevel)
    -- text must sit above bar(+0) → ticks(+10) → border(+15) → icon(+20)
    local textLevel = curLevel + 30
    if bw._deckTextFrame then
        bw._deckTextFrame:SetFrameStrata(curStrata)
        bw._deckTextFrame:SetFrameLevel(textLevel)
    end
    if bw._procTextFrame then
        bw._procTextFrame:SetFrameStrata(curStrata)
        bw._procTextFrame:SetFrameLevel(textLevel)
    end

    -- StatusBar fill
    local bar = bw._bar
    bar:SetMinMaxValues(0, deckSize)
    bar:SetValue(fillVal)
    bar:SetStatusBarColor(br, bg_, bb_, ba_)
    -- Orientation: VERTICAL makes bar fill bottom→top (same as ArcUI bars)
    bar:SetOrientation(vert and "VERTICAL" or "HORIZONTAL")
    -- ReverseFill: flips which end the bar fills from
    bar:SetReverseFill(db.barFillReverse == true)
    -- RotatesTexture: rotates the texture pixels (visual only, independent)
    bar:SetRotatesTexture(db.barRotateFill == true)

    -- Texture
    local texPath = BAR_TEXTURES[db.barTexture] or BAR_TEXTURES["Blizzard"]
    bar:SetStatusBarTexture(texPath)
    local barTex = bar:GetStatusBarTexture()
    if barTex then
        barTex:SetSnapToPixelGrid(false)
        barTex:SetTexelSnappingBias(0)
    end

    -- Background
    bw._bg:SetVertexColor(db.barBgR, db.barBgG, db.barBgB, db.barBgA)

    -- Border — 4 textures parented directly to bw (not StatusBar),
    -- so SetColorTexture is non-secret and renders correctly.
    local bf = bw._borderFrame
    if db.barBorderEnabled then
        local t    = math.max(1, db.barBorderThickness)
        local br,bg_,bb,ba = db.barBorderR,db.barBorderG,db.barBorderB,db.barBorderA
        bf.top:ClearAllPoints()
        bf.top:SetPoint("TOPLEFT",  bw,"TOPLEFT",  0, 0)
        bf.top:SetPoint("TOPRIGHT", bw,"TOPRIGHT", 0, 0)
        bf.top:SetHeight(t); bf.top:SetColorTexture(br,bg_,bb,ba); bf.top:Show()

        bf.bottom:ClearAllPoints()
        bf.bottom:SetPoint("BOTTOMLEFT",  bw,"BOTTOMLEFT",  0,0)
        bf.bottom:SetPoint("BOTTOMRIGHT", bw,"BOTTOMRIGHT", 0,0)
        bf.bottom:SetHeight(t); bf.bottom:SetColorTexture(br,bg_,bb,ba); bf.bottom:Show()

        bf.left:ClearAllPoints()
        bf.left:SetPoint("TOPLEFT",    bw,"TOPLEFT",    0,0)
        bf.left:SetPoint("BOTTOMLEFT", bw,"BOTTOMLEFT", 0,0)
        bf.left:SetWidth(t); bf.left:SetColorTexture(br,bg_,bb,ba); bf.left:Show()

        bf.right:ClearAllPoints()
        bf.right:SetPoint("TOPRIGHT",    bw,"TOPRIGHT",    0,0)
        bf.right:SetPoint("BOTTOMRIGHT", bw,"BOTTOMRIGHT", 0,0)
        bf.right:SetWidth(t); bf.right:SetColorTexture(br,bg_,bb,ba); bf.right:Show()
    else
        bf.top:Hide(); bf.bottom:Hide(); bf.left:Hide(); bf.right:Hide()
    end

    -- Tick marks at exact recorded proc fractions
    -- frac = 0-1 of deck stacks when proc fired (0=deck start, 1=deck end)
    -- We need to place the tick at the visual bar position where the fill was
    -- when the proc fired, accounting for countDown and reverseFill.
    --
    -- With countDown: bar starts full (fillVal=deckSize) and drains.
    --   Proc at frac means fillVal was (1-frac)*deckSize → fill level = (1-frac).
    -- Without countDown: bar starts empty and fills.
    --   Proc at frac means fillVal was frac*deckSize → fill level = frac.
    -- barFillReverse flips which physical end is "full" (handled by SetReverseFill
    --   on the StatusBar), so we flip the visual position too.
    --
    -- Actual frame dims after vertical swap:
    --   horizontal: frame is bW × bH
    --   vertical:   frame is bH × bW (SetSize(bH,bW) was called above)
    local ticks     = bw._ticks
    local positions = procPositions[entry.id] or {}
    for i = 1, MAX_TICKS do ticks[i]:Hide() end
    if db.barTickEnabled and #positions > 0 then
        local tr,tg,tb,ta = db.barTickR,db.barTickG,db.barTickB,db.barTickA
        local thick = math.max(1, db.barTickThickness or 2)
        -- Actual frame pixel dimensions
        local frameW = vert and bH or bW
        local frameH = vert and bW or bH
        for i = 1, math.min(#positions, MAX_TICKS) do
            local frac = positions[i]
            -- fillLevel: how full was the bar when this proc fired (0=empty, 1=full)
            local fillLevel = db.barCountDown and (1 - frac) or frac
            -- Apply reverseFill: flip which physical end represents "full"
            local visualFrac = db.barFillReverse and (1 - fillLevel) or fillLevel
            local tick = ticks[i]
            tick:ClearAllPoints()
            tick:SetColorTexture(tr,tg,tb,ta)
            if vert then
                -- Vertical bar fills bottom→top (SetOrientation VERTICAL)
                -- visualFrac=1 → top of bar, visualFrac=0 → bottom
                local yOff = visualFrac * frameH
                tick:SetPoint("BOTTOMLEFT",  bw, "BOTTOMLEFT",  0, yOff)
                tick:SetPoint("BOTTOMRIGHT", bw, "BOTTOMRIGHT", 0, yOff)
                tick:SetHeight(thick)
                tick:SetWidth(0)  -- width driven by the two SetPoint anchors
            else
                -- Horizontal bar fills left→right (SetOrientation HORIZONTAL)
                -- visualFrac=0 → left edge, visualFrac=1 → right edge
                local xOff = visualFrac * frameW
                tick:SetPoint("TOPLEFT",    bw, "TOPLEFT",    xOff, 0)
                tick:SetPoint("BOTTOMLEFT", bw, "BOTTOMLEFT", xOff, 0)
                tick:SetWidth(thick)
                tick:SetHeight(0)  -- height driven by the two SetPoint anchors
            end
            tick:Show()
        end
    end

    -- Deck pos text
    local dtf = bw._deckTextFrame
    if db.barDeckTextEnabled then
        local pos  = db.barDeckCountDown and (deckSize-raw) or raw
        local font = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
        local deckFontSize = math.max(6, math.floor((db.barDeckTextSize or 14) * (db.barScale or 1.0)))
        dtf.text:SetFont(font, deckFontSize, "OUTLINE")
        dtf.text:SetShadowOffset(1,-1); dtf.text:SetShadowColor(0,0,0,1)
        local deckSuffix = db.barDeckShowSuffix and ("/"..tostring(deckSize)) or ""
        dtf.text:SetText(tostring(pos)..deckSuffix)
        local dtr,dtg,dtb,dta
        if db.barDeckTextUseStateColor then
            dtr,dtg,dtb,dta = DeckTextStateColor(db, procs, maxProcs)
        else
            dtr,dtg,dtb,dta = db.barDeckTextR,db.barDeckTextG,db.barDeckTextB,db.barDeckTextA
        end
        dtf.text:SetTextColor(dtr,dtg,dtb,dta)
        ApplyTextAnchor(dtf, bw, db.barDeckTextAnchor,
            db.barDeckTextOffX, db.barDeckTextOffY, db.barDeckTextX, db.barDeckTextY)
        dtf:Show()
    else
        dtf:Hide()
    end

    -- Icon on bar
    local icoFrame = bw._barIcon
    if icoFrame then
        if db.barIconEnabled then
            local iconSize = math.max(4, math.floor((db.barIconSize or 16) * (db.barScale or 1.0)))
            icoFrame:SetSize(iconSize, iconSize)
            local fileID = db.barIconFileID or entry.defaultIcon or 136048
            local tex = C_Spell.GetSpellTexture(fileID)
            icoFrame._tex:SetTexture(tex or fileID)
            icoFrame:ClearAllPoints()
            local ap = db.barIconAnchor or "LEFT"
            icoFrame:SetPoint(ap, bw, ap, db.barIconOffX or 0, db.barIconOffY or 0)
            -- Icon border
            local ibe = icoFrame._edges
            if db.barIconBorderEnabled then
                local t  = math.max(1, db.barIconBorderThickness or 1)
                local ir,ig,ib_,ia = db.barIconBorderR,db.barIconBorderG,db.barIconBorderB,db.barIconBorderA
                ibe.top:ClearAllPoints()
                ibe.top:SetPoint("TOPLEFT",icoFrame,"TOPLEFT",0,0)
                ibe.top:SetPoint("TOPRIGHT",icoFrame,"TOPRIGHT",0,0)
                ibe.top:SetHeight(t); ibe.top:SetColorTexture(ir,ig,ib_,ia); ibe.top:Show()
                ibe.bottom:ClearAllPoints()
                ibe.bottom:SetPoint("BOTTOMLEFT",icoFrame,"BOTTOMLEFT",0,0)
                ibe.bottom:SetPoint("BOTTOMRIGHT",icoFrame,"BOTTOMRIGHT",0,0)
                ibe.bottom:SetHeight(t); ibe.bottom:SetColorTexture(ir,ig,ib_,ia); ibe.bottom:Show()
                ibe.left:ClearAllPoints()
                ibe.left:SetPoint("TOPLEFT",icoFrame,"TOPLEFT",0,0)
                ibe.left:SetPoint("BOTTOMLEFT",icoFrame,"BOTTOMLEFT",0,0)
                ibe.left:SetWidth(t); ibe.left:SetColorTexture(ir,ig,ib_,ia); ibe.left:Show()
                ibe.right:ClearAllPoints()
                ibe.right:SetPoint("TOPRIGHT",icoFrame,"TOPRIGHT",0,0)
                ibe.right:SetPoint("BOTTOMRIGHT",icoFrame,"BOTTOMRIGHT",0,0)
                ibe.right:SetWidth(t); ibe.right:SetColorTexture(ir,ig,ib_,ia); ibe.right:Show()
            else
                ibe.top:Hide(); ibe.bottom:Hide(); ibe.left:Hide(); ibe.right:Hide()
            end
            icoFrame:Show()
        else
            icoFrame:Hide()
        end
    end

    -- Proc count text
    local ptf = bw._procTextFrame
    if db.barProcTextEnabled then
        local procDisp = db.barProcCountDown and (maxProcs-procs) or procs
        local font = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
        local procFontSize = math.max(6, math.floor((db.barProcTextSize or 14) * (db.barScale or 1.0)))
        ptf.text:SetFont(font, procFontSize, "OUTLINE")
        ptf.text:SetShadowOffset(1,-1); ptf.text:SetShadowColor(0,0,0,1)
        local procSuffix = db.barProcShowSuffix and ("/"..tostring(maxProcs)) or ""
        ptf.text:SetText(tostring(procDisp)..procSuffix)
        local ptr,ptg,ptb,pta
        if db.barProcTextUseStateColor then
            ptr,ptg,ptb,pta = ProcTextStateColor(db, procs, maxProcs)
        else
            ptr,ptg,ptb,pta = db.barProcTextR,db.barProcTextG,db.barProcTextB,db.barProcTextA
        end
        ptf.text:SetTextColor(ptr,ptg,ptb,pta)
        ApplyTextAnchor(ptf, bw, db.barProcTextAnchor,
            db.barProcTextOffX, db.barProcTextOffY, db.barProcTextX, db.barProcTextY)
        ptf:Show()
    else
        ptf:Hide()
    end
end

-- ── Widget builder ────────────────────────────────────────────────────────────
local function MakeDraggableTextFrame(frameName, id, xKey, yKey, anchorKey)
    local tf = CreateFrame("Frame", frameName, UIParent)
    tf:SetSize(80, 24)
    tf:SetMovable(true)
    tf:EnableMouse(true)
    tf:RegisterForDrag("LeftButton")
    tf:SetClampedToScreen(true)
    -- Strata and level set dynamically in BuildBarWidget
    tf:SetScript("OnDragStart", function(self)
        local db = BarDB(id)
        if db.barLockPos then return end
        if db[anchorKey] ~= "FREE" then return end
        self:StartMoving()
    end)
    tf:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local _,_,_,x,y = self:GetPoint()
        local db = BarDB(id); db[xKey]=x; db[yKey]=y
    end)
    tf.text = tf:CreateFontString(nil, "OVERLAY")
    tf.text:SetPoint("CENTER")
    tf.text:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
    tf.text:SetText("")
    tf.text:SetShadowOffset(1,-1); tf.text:SetShadowColor(0,0,0,1)
    tf:Hide()
    return tf
end

local function BuildBarWidget(entry)
    local db = BarDB(entry.id)
    local id = entry.id

    local f = CreateFrame("Frame", "ArcUI_PT_Bar_"..id, UIParent)
    f:SetSize(db.barW, db.barH)
    f:SetFrameStrata(db.barStrata or "HIGH")
    f:SetFrameLevel(db.barLevel or 5)
    f:SetPoint("CENTER", UIParent, "CENTER", db.barX, db.barY)
    f:SetClampedToScreen(true)
    f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self)
        if BarDB(id).barLockPos then return end
        self:StartMoving()
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local _,_,_,x,y = self:GetPoint()
        local bdb=BarDB(id); bdb.barX=x; bdb.barY=y
    end)

    -- Background
    local bg = f:CreateTexture(nil,"BACKGROUND")
    bg:SetAllPoints(); bg:SetSnapToPixelGrid(false)
    bg:SetColorTexture(db.barBgR,db.barBgG,db.barBgB,db.barBgA)
    f._bg = bg

    -- StatusBar
    local bar = CreateFrame("StatusBar", nil, f)
    bar:SetAllPoints(f)
    bar:SetMinMaxValues(0, entry.deckSize)
    bar:SetValue(0)
    bar:SetOrientation("HORIZONTAL")   -- UpdateBar sets correct orientation
    bar:SetReverseFill(false)
    bar:SetStatusBarTexture(BAR_TEXTURES[db.barTexture] or BAR_TEXTURES["Blizzard"])
    bar:SetStatusBarColor(0,1,0,1)
    local barTex = bar:GetStatusBarTexture()
    if barTex then barTex:SetSnapToPixelGrid(false); barTex:SetTexelSnappingBias(0) end
    f._bar = bar

    -- Tick overlay (child of f, above StatusBar)
    local tickOverlay = CreateFrame("Frame", nil, f)
    tickOverlay:SetAllPoints(f)
    tickOverlay:SetFrameLevel(f:GetFrameLevel()+10)
    local ticks = {}
    for i = 1, MAX_TICKS do
        local t = tickOverlay:CreateTexture(nil,"OVERLAY")
        t:SetDrawLayer("OVERLAY",7)
        t:SetSnapToPixelGrid(false); t:SetTexelSnappingBias(0)
        t:Hide(); ticks[i]=t
    end
    f._ticks = ticks

    -- Border: 4 textures on a frame child of f (NOT parented to StatusBar)
    -- This is critical — StatusBar children inherit taint in some cases.
    local borderFrame = CreateFrame("Frame", nil, f)
    borderFrame:SetAllPoints(f)
    borderFrame:SetFrameLevel(tickOverlay:GetFrameLevel()+5)
    local bf = {}
    for _, side in ipairs({"top","bottom","left","right"}) do
        local t = borderFrame:CreateTexture(nil,"OVERLAY")
        t:SetDrawLayer("OVERLAY",7)
        t:SetSnapToPixelGrid(false)
        bf[side] = t
    end
    f._borderFrame = bf

    -- Icon frame (child of f, above tick overlay) — frame holds texture + border edges
    local barIconFrame = CreateFrame("Frame", nil, f)
    barIconFrame:SetSize(db.barIconSize or 16, db.barIconSize or 16)
    barIconFrame:SetFrameLevel(borderFrame:GetFrameLevel() + 5)  -- icon above border
    barIconFrame:Hide()

    local barIconTex = barIconFrame:CreateTexture(nil, "ARTWORK")
    barIconTex:SetAllPoints(barIconFrame)
    barIconTex:SetSnapToPixelGrid(false)
    barIconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    -- Icon border edges (OVERLAY layer above icon texture)
    local ibEdges = {}
    for _, side in ipairs({"top","bottom","left","right"}) do
        local t = barIconFrame:CreateTexture(nil, "OVERLAY")
        t:SetDrawLayer("OVERLAY", 2)
        t:SetSnapToPixelGrid(false)
        t:Hide()
        ibEdges[side] = t
    end
    barIconFrame._tex   = barIconTex
    barIconFrame._edges = ibEdges
    f._barIcon = barIconFrame

    -- Text frames
    local dtf = MakeDraggableTextFrame(
        "ArcUI_PT_BarDeckText_"..id, id, "barDeckTextX","barDeckTextY","barDeckTextAnchor")
    local ptf = MakeDraggableTextFrame(
        "ArcUI_PT_BarProcText_"..id, id, "barProcTextX","barProcTextY","barProcTextAnchor")
    -- Text frames: same strata as bar, frame level 20 above bar
    local initStrata = db.barStrata or "HIGH"
    local initLevel  = (db.barLevel or 5) + 20
    dtf:SetFrameStrata(initStrata)
    ptf:SetFrameStrata(initStrata)
    dtf:SetFrameLevel(initLevel)
    ptf:SetFrameLevel(initLevel)
    f._deckTextFrame = dtf
    f._procTextFrame = ptf

    procPositions[id] = procPositions[id] or {}
    entry.barWidget = f
    if db.barEnabled then f:Show() else f:Hide() end
    UpdateBar(entry)
    return f
end

-- ── Proc position tracking ────────────────────────────────────────────────────
local function CheckProcFired(entry)
    local id    = entry.id
    local procs = entry.GetProcs()
    local last  = lastProcCount[id] or 0
    if procs > last then
        local frac = entry.GetDeckPos() / entry.deckSize
        local pos  = procPositions[id] or {}
        for _ = last+1, procs do pos[#pos+1]=frac end
        procPositions[id] = pos
    elseif procs < last then
        procPositions[id] = {}
    end
    lastProcCount[id] = procs
end

-- ── Hook PT.UpdateDeck ────────────────────────────────────────────────────────
local _origUpdateDeck = PT.UpdateDeck
function PT.UpdateDeck(id)
    _origUpdateDeck(id)
    local entry = PT.GetDeck(id)
    if not entry then return end
    CheckProcFired(entry)
    if entry.barWidget then
        local db = BarDB(id)
        if not db.barEnabled then
            HideAllBarElements(entry)
        else
            UpdateBar(entry)
        end
    end
end

-- ── Options ───────────────────────────────────────────────────────────────────
local function BuildBarOptionsGroup(entry)
    local id = entry.id
    local function db() return BarDB(id) end
    local function refresh()
        if entry.barWidget then UpdateBar(entry) end
    end
    local order = 0
    local function o() order=order+1; return order end
    local function hidden() return not db().barEnabled end

    -- Session-only collapsed state per section (resets on reload, same as ArcUI)
    local sec = {
        layout=true, size=true, texture=true, fillColors=true,
        emptyState=true, border=true, ticks=true, icon=true,
        deckText=true, procText=true, copy=true,
    }
    local function secHidden(k) return hidden() or sec[k] end

    return {
        barEnabled = {
            type="toggle", name="Enable Bar",
            desc="Show a bar widget alongside or instead of the icon.",
            order=o(), width="full",
            get=function() return db().barEnabled==true end,
            set=function(_,v)
                db().barEnabled=v
                if v then
                    local bw=entry.barWidget
                    if bw then bw:Show() end
                    UpdateBar(entry)
                else
                    HideAllBarElements(entry)
                end
            end,
        },

        -- Copy Appearance
        copyHeader = {
            type="toggle", name="Copy Appearance From", dialogControl="CollapsibleHeader",
            order=o(), width="full",
            hidden=hidden,
            get=function() return not sec.copy end,
            set=function(_,v) sec.copy=not v
                local r=LibStub and LibStub("AceConfigRegistry-3.0",true)
                if r then r:NotifyChange("ArcUI_ProcTracker_Options") end
            end,
        },
        copyFromDeck = {
            type="select", name="Copy From",
            desc="Choose another deck's bar to copy all appearance settings from.",
            order=o(), width="full",
            hidden=function() return secHidden("copy") end,
            values=function()
                local t = {}
                -- First pass: registered decks (get their display names)
                local registeredNames = {}
                if PT.ForEachDeck then
                    PT.ForEachDeck(function(e)
                        registeredNames[e.id] = e.name
                    end)
                end
                -- Second pass: all saved bar data — includes decks from other specs
                -- that aren't currently registered (e.g. Enhancement bars on Elemental)
                local db2 = ArcUI_ProcTrackerDB and ArcUI_ProcTrackerDB.bars or {}
                for deckID, _ in pairs(db2) do
                    if deckID ~= id then
                        -- Use registered name if available, otherwise prettify the ID
                        t[deckID] = registeredNames[deckID] or deckID
                    end
                end
                return t
            end,
            get=function() return db()._copyFromDeck or "" end,
            set=function(_,v) db()._copyFromDeck = v end,
        },
        copyApply = {
            type="execute", name="Apply Copy",
            desc="Copies all bar appearance settings from the selected deck to this bar.",
            order=o(), width="full",
            hidden=function() return secHidden("copy") end,
            func=function()
                local srcID = db()._copyFromDeck
                if not srcID or srcID == "" then return end
                local srcDB = BarDB(srcID)
                local dstDB = db()
                for _, k in ipairs(BAR_APPEARANCE_KEYS) do
                    dstDB[k] = srcDB[k]
                end
                -- Rebuild widget to apply size changes
                local bw = entry.barWidget
                if bw then
                    bw:SetSize(dstDB.barW, dstDB.barH)
                end
                UpdateBar(entry)
                -- Notify AceConfig to refresh the panel
                local AceConfigRegistry = LibStub and LibStub("AceConfigRegistry-3.0", true)
                if AceConfigRegistry then
                    AceConfigRegistry:NotifyChange("ArcUI_ProcTracker_Options")
                end
            end,
        },

        -- Layout
        layoutHeader = {
            type="toggle", name="Layout", dialogControl="CollapsibleHeader",
            order=o(), width="full",
            hidden=hidden,
            get=function() return not sec.layout end,
            set=function(_,v) sec.layout=not v
                local r=LibStub and LibStub("AceConfigRegistry-3.0",true)
                if r then r:NotifyChange("ArcUI_ProcTracker_Options") end
            end,
        },
        barVertical = {
            type="toggle", name="Vertical",
            desc="Rotates the bar frame 90 degrees so it stands upright (width becomes height).",
            order=o(), width=0.8, hidden=function() return secHidden("layout") end,
            get=function() return db().barVertical==true end,
            set=function(_,v) db().barVertical=v; refresh() end,
        },
        _spLayout1 = { type="description", name=" ", order=o(), width=0.1, hidden=function() return secHidden("layout") end },
        barRotateFill = {
            type="toggle", name="Rotate Fill",
            desc="Rotates the bar texture pixels. Use alongside Vertical for aesthetic effect — does not change fill direction.",
            order=o(), width=0.9, hidden=function() return secHidden("layout") end,
            get=function() return db().barRotateFill==true end,
            set=function(_,v) db().barRotateFill=v; refresh() end,
        },
        barFillReverse = {
            type="toggle", name="Reverse Fill",
            desc="Reverses which end the bar fills from (e.g. top-to-bottom instead of bottom-to-top for vertical bars).",
            order=o(), width=0.8, hidden=function() return secHidden("layout") end,
            get=function() return db().barFillReverse==true end,
            set=function(_,v) db().barFillReverse=v; refresh() end,
        },
        _spLayout2 = { type="description", name=" ", order=o(), width=0.1, hidden=function() return secHidden("layout") end },
        barCountDown = {
            type="toggle", name="Count Down",
            desc="Bar drains as you spend stacks (same as icon count down).",
            order=o(), width=0.9, hidden=function() return secHidden("layout") end,
            get=function() return db().barCountDown==true end,
            set=function(_,v) db().barCountDown=v; refresh() end,
        },
        barLockPos = {
            type="toggle", name="Lock Position",
            order=o(), width="full", hidden=function() return secHidden("layout") end,
            get=function() return db().barLockPos==true end,
            set=function(_,v)
                db().barLockPos=v
                local bw=entry.barWidget
                if bw then bw:SetMovable(not v); bw:EnableMouse(not v) end
            end,
        },
        barStrata = {
            type="select", name="Frame Strata",
            desc="Strata layer for the bar and all its text frames.",
            order=o(), width="full", hidden=function() return secHidden("layout") end,
            values={ BACKGROUND="BACKGROUND", LOW="LOW", MEDIUM="MEDIUM", HIGH="HIGH", DIALOG="DIALOG", FULLSCREEN="FULLSCREEN" },
            sorting={"BACKGROUND","LOW","MEDIUM","HIGH","DIALOG","FULLSCREEN"},
            get=function() return db().barStrata or "HIGH" end,
            set=function(_,v)
                db().barStrata = v
                local bw = entry.barWidget
                if not bw then return end
                bw:SetFrameStrata(v)
                local textLevel = (db().barLevel or 5) + 20
                if bw._deckTextFrame then
                    bw._deckTextFrame:SetFrameStrata(v)
                    bw._deckTextFrame:SetFrameLevel(textLevel)
                end
                if bw._procTextFrame then
                    bw._procTextFrame:SetFrameStrata(v)
                    bw._procTextFrame:SetFrameLevel(textLevel)
                end
            end,
        },
        barLevel = {
            type="range", name="Frame Level",
            desc="Frame level within the strata. Text frames sit 20 levels above this value.",
            min=1, max=100, step=1,
            order=o(), width="full", hidden=function() return secHidden("layout") end,
            get=function() return db().barLevel or 5 end,
            set=function(_,v)
                db().barLevel = v
                local bw = entry.barWidget
                if not bw then return end
                bw:SetFrameLevel(v)
                local textLevel = v + 20
                if bw._deckTextFrame then bw._deckTextFrame:SetFrameLevel(textLevel) end
                if bw._procTextFrame then bw._procTextFrame:SetFrameLevel(textLevel) end
            end,
        },

        -- Size
        sizeHeader = {
            type="toggle", name="Size", dialogControl="CollapsibleHeader",
            order=o(), width="full",
            hidden=hidden,
            get=function() return not sec.size end,
            set=function(_,v) sec.size=not v
                local r=LibStub and LibStub("AceConfigRegistry-3.0",true)
                if r then r:NotifyChange("ArcUI_ProcTracker_Options") end
            end,
        },
        barW = {
            type="range", name="Width",
            min=20, max=600, step=1,
            order=o(), width="full", hidden=function() return secHidden("size") end,
            get=function() return db().barW end,
            set=function(_,v) db().barW=v; refresh() end,
        },
        barH = {
            type="range", name="Height",
            min=4, max=80, step=1,
            order=o(), width="full", hidden=function() return secHidden("size") end,
            get=function() return db().barH end,
            set=function(_,v) db().barH=v; refresh() end,
        },

        barScale = {
            type="range", name="Bar Scale",
            desc="Scales the entire bar widget uniformly.",
            min=0.5, max=3.0, step=0.05,
            order=o(), width="full", hidden=function() return secHidden("size") end,
            get=function() return db().barScale or 1.0 end,
            set=function(_,v)
                local old = db().barScale or 1.0
                db().barScale = v
                local bw = entry.barWidget
                if bw then
                    -- Compensate position so bar stays in place
                    local _,_,_,x,y = bw:GetPoint()
                    local ratio = old / v
                    bw:SetScale(v)
                    bw:ClearAllPoints()
                    bw:SetPoint("CENTER", UIParent, "CENTER", x*ratio, y*ratio)
                    local bdb = BarDB(id); bdb.barX = x*ratio; bdb.barY = y*ratio
                end
            end,
        },

        -- Texture
        textureHeader = {
            type="toggle", name="Bar Texture", dialogControl="CollapsibleHeader",
            order=o(), width="full",
            hidden=hidden,
            get=function() return not sec.texture end,
            set=function(_,v) sec.texture=not v
                local r=LibStub and LibStub("AceConfigRegistry-3.0",true)
                if r then r:NotifyChange("ArcUI_ProcTracker_Options") end
            end,
        },
        barTexture = {
            type="select", name="Texture",
            order=o(), width="full", hidden=function() return secHidden("texture") end,
            values=function()
                local t={} for _,k in ipairs(BAR_TEXTURE_KEYS) do t[k]=k end; return t
            end,
            sorting=BAR_TEXTURE_KEYS,
            get=function() return db().barTexture or "Blizzard" end,
            set=function(_,v)
                db().barTexture=v
                local bw=entry.barWidget
                if bw then
                    bw._bar:SetStatusBarTexture(BAR_TEXTURES[v] or BAR_TEXTURES["Blizzard"])
                    local tx=bw._bar:GetStatusBarTexture()
                    if tx then tx:SetSnapToPixelGrid(false); tx:SetTexelSnappingBias(0) end
                end
            end,
        },

        -- Fill Colors
        fillColorHeader = {
            type="toggle", name="Fill Colors", dialogControl="CollapsibleHeader",
            order=o(), width="full",
            hidden=hidden,
            get=function() return not sec.fillColors end,
            set=function(_,v) sec.fillColors=not v
                local r=LibStub and LibStub("AceConfigRegistry-3.0",true)
                if r then r:NotifyChange("ArcUI_ProcTracker_Options") end
            end,
        },
        barEmptyColor = {
            type="color", name="All Procs Available", hasAlpha=false,
            desc="Bar color when no procs have fired yet this deck.",
            order=o(), width=1.1, hidden=function() return secHidden("fillColors") end,
            get=function() return db().barEmptyR,db().barEmptyG,db().barEmptyB end,
            set=function(_,r,g,b) db().barEmptyR=r;db().barEmptyG=g;db().barEmptyB=b; refresh() end,
        },
        _spColor1 = { type="description", name=" ", order=o(), width=0.1, hidden=function() return secHidden("fillColors") end },
        barHalfColor = {
            type="color", name="Partial Procs Used", hasAlpha=false,
            desc="Bar color when some but not all procs have fired.",
            order=o(), width=1.1, hidden=function() return secHidden("fillColors") end,
            get=function() return db().barHalfR,db().barHalfG,db().barHalfB end,
            set=function(_,r,g,b) db().barHalfR=r;db().barHalfG=g;db().barHalfB=b; refresh() end,
        },
        barFullColor = {
            type="color", name="All Procs Done", hasAlpha=false,
            desc="Bar color when all expected procs have fired.",
            order=o(), width=1.1, hidden=function() return secHidden("fillColors") end,
            get=function() return db().barFullR,db().barFullG,db().barFullB end,
            set=function(_,r,g,b) db().barFullR=r;db().barFullG=g;db().barFullB=b; refresh() end,
        },
        _spColor2 = { type="description", name=" ", order=o(), width=0.1, hidden=function() return secHidden("fillColors") end },
        barBgColor = {
            type="color", name="Background", hasAlpha=true,
            order=o(), width=1.1, hidden=function() return secHidden("fillColors") end,
            get=function() return db().barBgR,db().barBgG,db().barBgB,db().barBgA end,
            set=function(_,r,g,b,a)
                db().barBgR=r;db().barBgG=g;db().barBgB=b;db().barBgA=a
                local bw=entry.barWidget
                if bw then bw._bg:SetVertexColor(r,g,b,a) end
            end,
        },

        -- Bar texture empty state color
        barTexEmptyHeader = {
            type="toggle", name="Bar Empty State Color", dialogControl="CollapsibleHeader",
            order=o(), width="full",
            hidden=hidden,
            get=function() return not sec.emptyState end,
            set=function(_,v) sec.emptyState=not v
                local r=LibStub and LibStub("AceConfigRegistry-3.0",true)
                if r then r:NotifyChange("ArcUI_ProcTracker_Options") end
            end,
        },
        barTexUseEmptyColor = {
            type="toggle", name="Custom Empty Bar Color",
            desc="When no procs have fired, use a separate color for the bar texture (independent of the text color).",
            order=o(), width="full", hidden=function() return secHidden("emptyState") end,
            get=function() return db().barTexUseEmptyColor==true end,
            set=function(_,v) db().barTexUseEmptyColor=v; refresh() end,
        },
        barTexEmptyColor = {
            type="color", name="Bar Empty Color", hasAlpha=true,
            desc="Bar texture color when no procs have fired. Only used when Custom Empty Bar Color is enabled.",
            order=o(), width="full",
            hidden=function() return secHidden("emptyState") or not db().barTexUseEmptyColor end,
            get=function() return db().barTexEmptyR,db().barTexEmptyG,db().barTexEmptyB,db().barTexEmptyA end,
            set=function(_,r,g,b,a) db().barTexEmptyR=r;db().barTexEmptyG=g;db().barTexEmptyB=b;db().barTexEmptyA=a; refresh() end,
        },

        -- Border
        borderHeader = {
            type="toggle", name="Border", dialogControl="CollapsibleHeader",
            order=o(), width="full",
            hidden=hidden,
            get=function() return not sec.border end,
            set=function(_,v) sec.border=not v
                local r=LibStub and LibStub("AceConfigRegistry-3.0",true)
                if r then r:NotifyChange("ArcUI_ProcTracker_Options") end
            end,
        },
        barBorderEnabled = {
            type="toggle", name="Show Border",
            order=o(), width=0.8, hidden=function() return secHidden("border") end,
            get=function() return db().barBorderEnabled==true end,
            set=function(_,v) db().barBorderEnabled=v; refresh() end,
        },
        _spBorder1 = { type="description", name=" ", order=o(), width=0.1, hidden=function() return secHidden("border") end },
        barBorderThickness = {
            type="range", name="Thickness",
            min=1, max=6, step=1,
            order=o(), width=0.9, hidden=function() return secHidden("border") end,
            get=function() return db().barBorderThickness or 1 end,
            set=function(_,v) db().barBorderThickness=v; refresh() end,
        },
        barBorderColor = {
            type="color", name="Border Color", hasAlpha=true,
            order=o(), width="full", hidden=function() return secHidden("border") end,
            get=function() return db().barBorderR,db().barBorderG,db().barBorderB,db().barBorderA end,
            set=function(_,r,g,b,a) db().barBorderR=r;db().barBorderG=g;db().barBorderB=b;db().barBorderA=a; refresh() end,
        },

        -- Tick Marks
        tickHeader = {
            type="toggle", name="Proc Tick Marks", dialogControl="CollapsibleHeader",
            order=o(), width="full",
            hidden=hidden,
            get=function() return not sec.ticks end,
            set=function(_,v) sec.ticks=not v
                local r=LibStub and LibStub("AceConfigRegistry-3.0",true)
                if r then r:NotifyChange("ArcUI_ProcTracker_Options") end
            end,
        },
        barTickEnabled = {
            type="toggle", name="Show Tick Marks",
            desc="Draws a tick on the bar at the exact deck position where each proc fired.",
            order=o(), width=0.9, hidden=function() return secHidden("ticks") end,
            get=function() return db().barTickEnabled==true end,
            set=function(_,v) db().barTickEnabled=v; refresh() end,
        },
        _spTick1 = { type="description", name=" ", order=o(), width=0.1, hidden=function() return secHidden("ticks") end },
        barTickThicknessInline = {
            type="range", name="Thickness",
            min=1, max=8, step=1,
            order=o(), width=0.8, hidden=function() return secHidden("ticks") end,
            get=function() return db().barTickThickness or 2 end,
            set=function(_,v) db().barTickThickness=v; refresh() end,
        },
        barTickColor = {
            type="color", name="Tick Color", hasAlpha=true,
            order=o(), width="full", hidden=function() return secHidden("ticks") end,
            get=function() return db().barTickR,db().barTickG,db().barTickB,db().barTickA end,
            set=function(_,r,g,b,a) db().barTickR=r;db().barTickG=g;db().barTickB=b;db().barTickA=a; refresh() end,
        },

        -- Icon
        iconHeader = {
            type="toggle", name="Icon", dialogControl="CollapsibleHeader",
            order=o(), width="full",
            hidden=hidden,
            get=function() return not sec.icon end,
            set=function(_,v) sec.icon=not v
                local r=LibStub and LibStub("AceConfigRegistry-3.0",true)
                if r then r:NotifyChange("ArcUI_ProcTracker_Options") end
            end,
        },
        barIconEnabled = {
            type="toggle", name="Show Icon",
            desc="Display a small icon on the bar.",
            order=o(), width="full", hidden=function() return secHidden("icon") end,
            get=function() return db().barIconEnabled==true end,
            set=function(_,v) db().barIconEnabled=v; refresh() end,
        },
        barIconFileID = {
            type="input", name="Icon File ID",
            desc="Spell or file ID for the icon texture. Leave blank to use the deck's default icon.",
            order=o(), width="full",
            hidden=function() return secHidden("icon") or not db().barIconEnabled end,
            get=function() return db().barIconFileID and tostring(db().barIconFileID) or "" end,
            set=function(_,v)
                v = v and v:match("^%s*(.-)%s*$") or ""
                local n = tonumber(v)
                db().barIconFileID = n or nil
                refresh()
            end,
        },
        barIconSize = {
            type="range", name="Icon Size",
            min=8, max=64, step=1,
            order=o(), width="full",
            hidden=function() return secHidden("icon") or not db().barIconEnabled end,
            get=function() return db().barIconSize or 16 end,
            set=function(_,v) db().barIconSize=v; refresh() end,
        },
        barIconAnchor = {
            type="select", name="Icon Anchor Point",
            order=o(), width="full",
            hidden=function() return secHidden("icon") or not db().barIconEnabled end,
            values=ANCHOR_POINTS, sorting=ANCHOR_POINT_KEYS,
            get=function() return db().barIconAnchor or "LEFT" end,
            set=function(_,v) db().barIconAnchor=v; refresh() end,
        },
        barIconOffX = {
            type="range", name="Icon Offset X",
            min=-200, max=200, step=1,
            order=o(), width="full",
            hidden=function() return secHidden("icon") or not db().barIconEnabled end,
            get=function() return db().barIconOffX or 0 end,
            set=function(_,v) db().barIconOffX=v; refresh() end,
        },
        barIconOffY = {
            type="range", name="Icon Offset Y",
            min=-100, max=100, step=1,
            order=o(), width="full",
            hidden=function() return secHidden("icon") or not db().barIconEnabled end,
            get=function() return db().barIconOffY or 0 end,
            set=function(_,v) db().barIconOffY=v; refresh() end,
        },
        barIconBorderEnabled = {
            type="toggle", name="Icon Border",
            order=o(), width=0.8,
            hidden=function() return secHidden("icon") or not db().barIconEnabled end,
            get=function() return db().barIconBorderEnabled==true end,
            set=function(_,v) db().barIconBorderEnabled=v; refresh() end,
        },
        _spIconBorder = { type="description", name=" ", order=o(), width=0.1,
            hidden=function() return secHidden("icon") or not db().barIconEnabled end },
        barIconBorderThickness = {
            type="range", name="Thickness",
            min=1, max=6, step=1,
            order=o(), width=0.9,
            hidden=function() return secHidden("icon") or not db().barIconEnabled end,
            get=function() return db().barIconBorderThickness or 1 end,
            set=function(_,v) db().barIconBorderThickness=v; refresh() end,
        },
        barIconBorderColor = {
            type="color", name="Border Color", hasAlpha=true,
            order=o(), width="full",
            hidden=function() return secHidden("icon") or not db().barIconEnabled end,
            get=function() return db().barIconBorderR,db().barIconBorderG,db().barIconBorderB,db().barIconBorderA end,
            set=function(_,r,g,b,a) db().barIconBorderR=r;db().barIconBorderG=g;db().barIconBorderB=b;db().barIconBorderA=a; refresh() end,
        },

        -- Deck Position Text
        deckTextHeader = {
            type="toggle", name="Deck Position Text", dialogControl="CollapsibleHeader",
            order=o(), width="full",
            hidden=hidden,
            get=function() return not sec.deckText end,
            set=function(_,v) sec.deckText=not v
                local r=LibStub and LibStub("AceConfigRegistry-3.0",true)
                if r then r:NotifyChange("ArcUI_ProcTracker_Options") end
            end,
        },
        barDeckTextEnabled = {
            type="toggle", name="Show Deck Position",
            desc="Displays the current deck position as a draggable text element.",
            order=o(), width=1.0, hidden=function() return secHidden("deckText") end,
            get=function() return db().barDeckTextEnabled==true end,
            set=function(_,v) db().barDeckTextEnabled=v; refresh() end,
        },
        _spDeckTog1 = { type="description", name=" ", order=o(), width=0.1,
            hidden=function() return secHidden("deckText") or not db().barDeckTextEnabled end },
        barDeckCountDown = {
            type="toggle", name="Count Down",
            order=o(), width=0.75,
            hidden=function() return secHidden("deckText") or not db().barDeckTextEnabled end,
            get=function() return db().barDeckCountDown==true end,
            set=function(_,v) db().barDeckCountDown=v; refresh() end,
        },
        _spDeckTog2 = { type="description", name=" ", order=o(), width=0.1,
            hidden=function() return secHidden("deckText") or not db().barDeckTextEnabled end },
        barDeckShowSuffix = {
            type="toggle", name="Show /Size Suffix",
            desc="Show the deck size after the position e.g. 142/333.",
            order=o(), width=0.85,
            hidden=function() return secHidden("deckText") or not db().barDeckTextEnabled end,
            get=function() return db().barDeckShowSuffix==true end,
            set=function(_,v) db().barDeckShowSuffix=v; refresh() end,
        },
        barDeckTextSize = {
            type="range", name="Font Size",
            min=8, max=32, step=1,
            order=o(), width="full",
            hidden=function() return secHidden("deckText") or not db().barDeckTextEnabled end,
            get=function() return db().barDeckTextSize or 14 end,
            set=function(_,v) db().barDeckTextSize=v; refresh() end,
        },
        barDeckTextUseStateColor = {
            type="toggle", name="Use Proc State Color",
            desc="Color changes with proc state (All Available / Partial / Done) instead of fixed color.",
            order=o(), width="full",
            hidden=function() return secHidden("deckText") or not db().barDeckTextEnabled end,
            get=function() return db().barDeckTextUseStateColor==true end,
            set=function(_,v) db().barDeckTextUseStateColor=v; refresh() end,
        },
        barDeckTextColor = {
            type="color", name="Fixed Color", hasAlpha=true,
            order=o(), width="full",
            hidden=function() return secHidden("deckText") or not db().barDeckTextEnabled or db().barDeckTextUseStateColor end,
            get=function() return db().barDeckTextR,db().barDeckTextG,db().barDeckTextB,db().barDeckTextA end,
            set=function(_,r,g,b,a) db().barDeckTextR=r;db().barDeckTextG=g;db().barDeckTextB=b;db().barDeckTextA=a; refresh() end,
        },
        barDeckTextEmptyColor = {
            type="color", name="All Procs Available", hasAlpha=true,
            order=o(), width="full",
            hidden=function() return secHidden("deckText") or not db().barDeckTextEnabled or not db().barDeckTextUseStateColor end,
            get=function() return db().barDeckTextEmptyR,db().barDeckTextEmptyG,db().barDeckTextEmptyB,db().barDeckTextEmptyA end,
            set=function(_,r,g,b,a) db().barDeckTextEmptyR=r;db().barDeckTextEmptyG=g;db().barDeckTextEmptyB=b;db().barDeckTextEmptyA=a; refresh() end,
        },
        barDeckTextHalfColor = {
            type="color", name="Partial Procs Used", hasAlpha=true,
            order=o(), width="full",
            hidden=function() return secHidden("deckText") or not db().barDeckTextEnabled or not db().barDeckTextUseStateColor end,
            get=function() return db().barDeckTextHalfR,db().barDeckTextHalfG,db().barDeckTextHalfB,db().barDeckTextHalfA end,
            set=function(_,r,g,b,a) db().barDeckTextHalfR=r;db().barDeckTextHalfG=g;db().barDeckTextHalfB=b;db().barDeckTextHalfA=a; refresh() end,
        },
        barDeckTextFullColor = {
            type="color", name="All Procs Done", hasAlpha=true,
            order=o(), width="full",
            hidden=function() return secHidden("deckText") or not db().barDeckTextEnabled or not db().barDeckTextUseStateColor end,
            get=function() return db().barDeckTextFullR,db().barDeckTextFullG,db().barDeckTextFullB,db().barDeckTextFullA end,
            set=function(_,r,g,b,a) db().barDeckTextFullR=r;db().barDeckTextFullG=g;db().barDeckTextFullB=b;db().barDeckTextFullA=a; refresh() end,
        },
        barDeckTextAnchor = {
            type="select", name="Anchor Point",
            desc="FREE: drag anywhere.  Other options snap the text to that edge of the bar.",
            order=o(), width="full",
            hidden=function() return secHidden("deckText") or not db().barDeckTextEnabled end,
            values=ANCHOR_POINTS, sorting=ANCHOR_POINT_KEYS,
            get=function() return db().barDeckTextAnchor or "FREE" end,
            set=function(_,v) db().barDeckTextAnchor=v; refresh() end,
        },
        barDeckTextOffX = {
            type="range", name="Offset X",
            min=-200, max=200, step=1,
            order=o(), width="full",
            hidden=function() return secHidden("deckText") or not db().barDeckTextEnabled or db().barDeckTextAnchor=="FREE" end,
            get=function() return db().barDeckTextOffX or 4 end,
            set=function(_,v) db().barDeckTextOffX=v; refresh() end,
        },
        barDeckTextOffY = {
            type="range", name="Offset Y",
            min=-100, max=100, step=1,
            order=o(), width="full",
            hidden=function() return secHidden("deckText") or not db().barDeckTextEnabled or db().barDeckTextAnchor=="FREE" end,
            get=function() return db().barDeckTextOffY or 0 end,
            set=function(_,v) db().barDeckTextOffY=v; refresh() end,
        },

        -- Proc Count Text
        procTextHeader = {
            type="toggle", name="Proc Count Text", dialogControl="CollapsibleHeader",
            order=o(), width="full",
            hidden=hidden,
            get=function() return not sec.procText end,
            set=function(_,v) sec.procText=not v
                local r=LibStub and LibStub("AceConfigRegistry-3.0",true)
                if r then r:NotifyChange("ArcUI_ProcTracker_Options") end
            end,
        },
        barProcTextEnabled = {
            type="toggle", name="Show Proc Count",
            desc="Displays the proc count for the current deck as a draggable text element.",
            order=o(), width=1.0, hidden=function() return secHidden("procText") end,
            get=function() return db().barProcTextEnabled==true end,
            set=function(_,v) db().barProcTextEnabled=v; refresh() end,
        },
        _spProcTog1 = { type="description", name=" ", order=o(), width=0.1,
            hidden=function() return secHidden("procText") or not db().barProcTextEnabled end },
        barProcCountDown = {
            type="toggle", name="Count Down",
            order=o(), width=0.75,
            hidden=function() return secHidden("procText") or not db().barProcTextEnabled end,
            get=function() return db().barProcCountDown==true end,
            set=function(_,v) db().barProcCountDown=v; refresh() end,
        },
        _spProcTog2 = { type="description", name=" ", order=o(), width=0.1,
            hidden=function() return secHidden("procText") or not db().barProcTextEnabled end },
        barProcShowSuffix = {
            type="toggle", name="Show /Max Suffix",
            desc="Show the max procs after the count e.g. 1/2.",
            order=o(), width=0.85,
            hidden=function() return secHidden("procText") or not db().barProcTextEnabled end,
            get=function() return db().barProcShowSuffix~=false end,
            set=function(_,v) db().barProcShowSuffix=v; refresh() end,
        },
        barProcTextSize = {
            type="range", name="Font Size",
            min=8, max=32, step=1,
            order=o(), width="full",
            hidden=function() return secHidden("procText") or not db().barProcTextEnabled end,
            get=function() return db().barProcTextSize or 14 end,
            set=function(_,v) db().barProcTextSize=v; refresh() end,
        },
        barProcTextUseStateColor = {
            type="toggle", name="Use Proc State Color",
            desc="Color changes with proc state (All Available / Partial / Done) instead of fixed color.",
            order=o(), width="full",
            hidden=function() return secHidden("procText") or not db().barProcTextEnabled end,
            get=function() return db().barProcTextUseStateColor~=false end,
            set=function(_,v) db().barProcTextUseStateColor=v; refresh() end,
        },
        barProcTextColor = {
            type="color", name="Fixed Color", hasAlpha=true,
            order=o(), width="full",
            hidden=function() return secHidden("procText") or not db().barProcTextEnabled or db().barProcTextUseStateColor end,
            get=function() return db().barProcTextR,db().barProcTextG,db().barProcTextB,db().barProcTextA end,
            set=function(_,r,g,b,a) db().barProcTextR=r;db().barProcTextG=g;db().barProcTextB=b;db().barProcTextA=a; refresh() end,
        },
        barProcTextEmptyColor = {
            type="color", name="All Procs Available", hasAlpha=true,
            order=o(), width="full",
            hidden=function() return secHidden("procText") or not db().barProcTextEnabled or not db().barProcTextUseStateColor end,
            get=function() return db().barProcTextEmptyR,db().barProcTextEmptyG,db().barProcTextEmptyB,db().barProcTextEmptyA end,
            set=function(_,r,g,b,a) db().barProcTextEmptyR=r;db().barProcTextEmptyG=g;db().barProcTextEmptyB=b;db().barProcTextEmptyA=a; refresh() end,
        },
        barProcTextHalfColor = {
            type="color", name="Partial Procs Used", hasAlpha=true,
            order=o(), width="full",
            hidden=function() return secHidden("procText") or not db().barProcTextEnabled or not db().barProcTextUseStateColor end,
            get=function() return db().barProcTextHalfR,db().barProcTextHalfG,db().barProcTextHalfB,db().barProcTextHalfA end,
            set=function(_,r,g,b,a) db().barProcTextHalfR=r;db().barProcTextHalfG=g;db().barProcTextHalfB=b;db().barProcTextHalfA=a; refresh() end,
        },
        barProcTextFullColor = {
            type="color", name="All Procs Done", hasAlpha=true,
            order=o(), width="full",
            hidden=function() return secHidden("procText") or not db().barProcTextEnabled or not db().barProcTextUseStateColor end,
            get=function() return db().barProcTextFullR,db().barProcTextFullG,db().barProcTextFullB,db().barProcTextFullA end,
            set=function(_,r,g,b,a) db().barProcTextFullR=r;db().barProcTextFullG=g;db().barProcTextFullB=b;db().barProcTextFullA=a; refresh() end,
        },
        barProcTextAnchor = {
            type="select", name="Anchor Point",
            desc="FREE: drag anywhere.  Other options snap the text to that edge of the bar.",
            order=o(), width="full",
            hidden=function() return secHidden("procText") or not db().barProcTextEnabled end,
            values=ANCHOR_POINTS, sorting=ANCHOR_POINT_KEYS,
            get=function() return db().barProcTextAnchor or "FREE" end,
            set=function(_,v) db().barProcTextAnchor=v; refresh() end,
        },
        barProcTextOffX = {
            type="range", name="Offset X",
            min=-200, max=200, step=1,
            order=o(), width="full",
            hidden=function() return secHidden("procText") or not db().barProcTextEnabled or db().barProcTextAnchor=="FREE" end,
            get=function() return db().barProcTextOffX or 4 end,
            set=function(_,v) db().barProcTextOffX=v; refresh() end,
        },
        barProcTextOffY = {
            type="range", name="Offset Y",
            min=-100, max=100, step=1,
            order=o(), width="full",
            hidden=function() return secHidden("procText") or not db().barProcTextEnabled or db().barProcTextAnchor=="FREE" end,
            get=function() return db().barProcTextOffY or 0 end,
            set=function(_,v) db().barProcTextOffY=v; refresh() end,
        },
    }
end

-- ── Bootstrap ─────────────────────────────────────────────────────────────────
do
    local _origRegister = PT.RegisterDeck
    function PT.RegisterDeck(def)
        _origRegister(def)
        if ArcUI_ProcTrackerDB then
            local entry = PT.GetDeck(def.id)
            if entry and not entry.barWidget then BuildBarWidget(entry) end
        end
    end
end

PT.BuildBarOptionsGroup = BuildBarOptionsGroup

local bootFrame = CreateFrame("Frame")
bootFrame:RegisterEvent("ADDON_LOADED")
bootFrame:SetScript("OnEvent", function(self, _, addon)
    if addon ~= "ArcUI_ProcTracker" then return end
    self:UnregisterAllEvents()
    C_Timer.After(0.01, function()
        if PT.ForEachDeck then
            PT.ForEachDeck(function(entry)
                if not entry.barWidget then BuildBarWidget(entry) end
            end)
        end
    end)
end)

PT.UpdateBar = function(id)
    local entry = PT.GetDeck(id)
    if entry then UpdateBar(entry) end
end

-- Called by deck ApplyTalentVisibility to mirror talent gating on the bar.
-- talented=true  → show bar if barEnabled; run UpdateBar
-- talented=false → hide bar + text frames unconditionally
function PT.ApplyBarTalentVisibility(id, talented)
    local entry = PT.GetDeck(id)
    if not entry or not entry.barWidget then return end
    if talented then
        local db = BarDB(id)
        if db.barEnabled then
            entry.barWidget:Show()
            UpdateBar(entry)
        end
    else
        HideAllBarElements(entry)
    end
end