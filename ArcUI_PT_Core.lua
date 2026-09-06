-- ArcUI_PT_Core.lua
-- ProcTracker: icon widget factory, per-deck options panel, /pt slash command.
-- No detection logic here. Decks register via PT.RegisterDeck().
-- No pcall. Zero polling.

-- PRIVATE namespace, NOT a global. This was `PT = {}` -- a bare two-letter global --
-- so any other addon or WeakAura that assigned PT replaced this table, and every
-- module's PT.<field> read went nil (the MSW.lua:141 error storm users reported).
-- WoW hands every file in this addon the SAME table through `...`, and each file
-- holds it as a LOCAL captured at load, so an outside PT can no longer reach us.
-- Every ArcUI_PT_*.lua file must therefore start with `local ADDON, PT = ...`.
local ADDON, PT = ...
_G.ArcUI_PT = PT   -- non-colliding handle, so /run ArcUI_PT.foo still works

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

-- Has WoW actually handed us our SavedVariables yet?
--
-- Do NOT test `if ArcUI_ProcTrackerDB then` for this. GetDB() FABRICATES that
-- global on first touch, and decks touch it before registering: DWDeck's
-- registration table evaluates ForceCDMSetting() -> PT.GetIconDB("dw") ->
-- GetDB() while building the table it passes to PT.RegisterDeck, so the global
-- exists but is EMPTY by the time the build guards run. Both guards then see a
-- truthy value and build the icon and bar out of ICON_DEFAULTS / BAR_DEFAULTS,
-- i.e. at the DEFAULT position. WoW later replaces the global with the real
-- saved table, but nothing ever re-anchors an existing widget -- SetPoint on the
-- bar happens only in BuildBarWidget and the drag/options handlers -- so it
-- stays wherever the defaults put it. That is the "my bar reset its position on
-- reload" bug, and the `not entry.widget` duplicate guard added in 1.1.3 is what
-- stopped the later correct-position rebuild from papering over it.
--
-- Gate every widget build on this flag instead.
local savedVarsLoaded = false
function PT.SavedVarsLoaded() return savedVarsLoaded end

local ICON_DEFAULTS = {
    posX=0, posY=180, iconW=48, iconH=48, iconScale=1.0, frameStrata="HIGH", frameLevel=5, showViolations=false, desaturateEmpty=false, violOffX=0, violOffY=-20, violSize=12, violR=1, violG=0.2, violB=0.2,
    deckOffX=0, deckOffY=0,  deckSize=19,
    procOffX=0, procOffY=27, procSize=19,
    countDown=true, procCountDown=true,
    -- The three readouts are independent: each has its own Show toggle, font,
    -- size, colour and position. Deck and proc default ON because they predate
    -- the toggles and were always drawn; the chance text is new, so it is opt-in.
    showDeckText=true, showProcText=true, showChanceText=false,
    -- Anchor spec per text: "0" = this widget's own icon, "cdm:<id>" = a
    -- Cooldown Manager icon, "action:<ids>" = an action bar button.
    deckAnchor="0", procAnchor="0", chanceAnchor="0", violAnchor="0",
    -- STATE VISUALS (timer entries). Two buckets, named for what the player
    -- sees rather than ArcUI's readyState/cooldownState pair -- that naming is
    -- FLIPPED for timers over there (running maps to readyState) and its own
    -- skill calls it the number one source of confusion. Here: "ready" means
    -- usable, "cd" means the internal cooldown is running.
    rdyAlpha=1.0, rdyDesat=false, rdyTint=false, rdyTintR=1, rdyTintG=1, rdyTintB=1,
    rdyGlow=false, rdyGlowStyle="pixel", rdyGlowR=0.95, rdyGlowG=0.95, rdyGlowB=0.32,
    rdyGlowPad=0, rdyGlowX=0, rdyGlowY=0, rdyGlowSpeed=0.25,
    rdyGlowLines=8, rdyGlowLength=0, rdyGlowThick=2, rdyGlowBorder=false,
    rdyGlowParticles=4, rdyGlowScale=1, rdyGlowDuration=1,
    cdAlpha=1.0,  cdDesat=false,  cdTint=false,  cdTintR=1,  cdTintG=1,  cdTintB=1,
    cdGlow=false, cdGlowStyle="pixel", cdGlowR=0.95, cdGlowG=0.95, cdGlowB=0.32,
    cdGlowPad=0, cdGlowX=0, cdGlowY=0, cdGlowSpeed=0.25,
    -- COOLDOWN ANIMATION (timer entries): the sweep the game draws over the
    -- icon while the internal cooldown runs. Blizzard's own defaults, except
    -- the edge line, which each entry can turn on for itself.
    swipeShow=true, swipeR=0, swipeG=0, swipeB=0, swipeA=0.8,
    swipeEdge=false, swipeNumbers=true, swipeBling=true, swipeReverse=false,
    cdGlowLines=8, cdGlowLength=0, cdGlowThick=2, cdGlowBorder=false,
    cdGlowParticles=4, cdGlowScale=1, cdGlowDuration=1,
    chanceOffX=0, chanceOffY=-27, chanceSize=19,
    chanceSpend=10,             -- stacks the next spender is assumed to eat (Enh full stack)
    chanceForecast="auto",      -- Ele only: "auto" | "instant" | "blast"
    chanceDecimals=true,        -- show 4.9% rather than 5%
    chanceColorMode="fixed",    -- "fixed" | "procs" | "chance"
    chanceR=1.0, chanceG=1.0, chanceB=1.0,
    -- "chance" mode: below low = cold, at/above high = hot, between = mid
    chanceLowPct=3, chanceHighPct=10,
    chanceColdR=0.6, chanceColdG=0.6, chanceColdB=0.6,
    chanceMidR=1.0,  chanceMidG=0.82, chanceMidB=0.0,
    chanceHotR=0.0,  chanceHotG=1.0,  chanceHotB=0.0,
    -- "procs left" mode: ONE COLOUR PER PROC COUNT, not three fixed buckets.
    -- Deck sizes differ (Doom Winds 3, Storm Unleashed 5, Tempest 2,
    -- Soulburst 1), and every one of them is small enough to name each count
    -- outright, which beats asking the user to pick thresholds over a range of
    -- three values. Sparse: only counts the user has actually edited are
    -- stored; the rest fall back to DefaultCountColor.
    chanceCountColors=nil,
    procSound="None",   -- sound when a proc comes off this deck
    procSoundEnabled=false, -- master switch: mutes without losing the picked sound
    procSoundChannel="Master", -- which of WoW's volume sliders it rides
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
    hideOOC=false,   -- opt-in: hide this widget while out of combat
    -- Fonts are PER TEXT (deckFont / procFont / violFont). nil = game default,
    -- otherwise a LibSharedMedia font name.
}

-- ── Shared media ──────────────────────────────────────────────────────────────
-- LibSharedMedia is a single shared registry, so the font list here automatically
-- includes anything other addons have registered -- ArcUI's fonts show up without
-- ProcTracker needing to know ArcUI exists.
local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
local DEFAULT_FONT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"

function PT.ResolveFont(name)
    if name and LSM then
        local path = LSM:Fetch("font", name, true)
        if path then return path end
    end
    return DEFAULT_FONT
end

-- Applying a font can FAIL silently: SetFont with a path the client cannot load
-- leaves the FontString with no font at all, which renders as nothing. That is
-- what made text vanish when cycling fonts. Always verify with GetFont and fall
-- back to the game font, so a bad pick degrades instead of blanking the text.
function PT.SetFontSafe(fs, fontName, size, flags)
    if not fs then return end
    size  = math.max(1, math.floor(tonumber(size) or 12))
    flags = flags or "OUTLINE"

    -- SetFont RETURNS a boolean; on failure the FontString silently KEEPS its
    -- previous font. Checking GetFont() afterwards is useless because it hands
    -- back that old font rather than nil, so a failed change looks identical to
    -- a successful one and the text just never updates. Trust the return value.
    local path = PT.ResolveFont(fontName)
    if fs:SetFont(path, size, flags) == false then
        -- The chosen font could not be loaded. Try it without the outline flag
        -- (some TTFs only fail with flags), then fall back to the game font so
        -- the text is never left blank.
        if fs:SetFont(path, size, "") == false then
            fs:SetFont(DEFAULT_FONT, size, flags)
        end
    end
    -- Last resort: a FontString with no font at all renders nothing.
    if not fs:GetFont() then
        fs:SetFont(DEFAULT_FONT, size, flags)
    end
end

-- Values table for an AceConfig select. Empty when LSM is missing, in which case
-- the option hides itself rather than showing a broken dropdown.
function PT.FontValues()
    local t = {}
    if LSM then
        for _, name in ipairs(LSM:List("font")) do t[name] = name end
    end
    return t
end

function PT.HasSharedMedia() return LSM ~= nil end

-- Applies the icon's three fonts directly, with no dependence on the rest of
-- the redraw. Mirrors PT.ApplyBarFonts so a font pick always lands even if the
-- surrounding update path bails out for some other reason.
function PT.ApplyIconFonts(entry)
    local w = entry and entry.widget
    if not w then return end
    local db = ArcUI_ProcTrackerDB and ArcUI_ProcTrackerDB.icons
                and ArcUI_ProcTrackerDB.icons[entry.id]
    if not db then return end
    PT.SetFontSafe(w._deckText, db.deckFont, db.deckSize)
    PT.SetFontSafe(w._procText, db.procFont, db.procSize)
    PT.SetFontSafe(w._violText, db.violFont, db.violSize or 12)
    PT.SetFontSafe(w._chanceText, db.chanceFont, db.chanceSize or 19)
end

local function IconDB(id)
    local db = GetDB()
    db.icons = db.icons or {}
    db.icons[id] = db.icons[id] or {}
    local t = db.icons[id]
    -- Entry-specific defaults win over the shared ones, so a tracker can ship a
    -- different starting strata, size or colour without every icon inheriting
    -- it. Applied FIRST: both passes only fill nils, so whichever runs first
    -- decides. A value the user has actually set is never touched by either.
    local e = registryMap[id]
    if e and e.iconDefaults then
        for k, v in pairs(e.iconDefaults) do
            if t[k] == nil then t[k] = v end
        end
    end
    for k, v in pairs(ICON_DEFAULTS) do
        if t[k] == nil then t[k] = v end
    end
    return t
end

-- Decks need their own saved settings (e.g. the DW "force CDM" override) before
-- the options panel has ever been opened, so expose the accessor.
PT.GetIconDB = IconDB

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

-- Force the options panel to re-read function-valued names/descs.
--
-- Hits BOTH renderers on purpose. NotifyChange drives stock AceConfigDialog and,
-- via the ConfigTableChange callback in OpenSkinnedOptions, the ArcSkin window
-- too -- but that callback is only registered once the skinned window has been
-- opened through that path. Calling skin:Refresh directly as well means a live
-- status line updates regardless of which renderer is up or how it was opened.
--
-- Both calls are no-ops when the panel is closed.
function PT.RefreshOptions()
    if AceConfigRegistry then AceConfigRegistry:NotifyChange(PT_OPTIONS_NAME) end
    local skin = LibStub and LibStub("ArcSkin-1.0", true)
    if skin and skin.Refresh then skin:Refresh(PT_OPTIONS_NAME) end
end

-- ── CDM frame lookup ──────────────────────────────────────────────────────────
-- Find an ACTIVE Cooldown Manager icon by its cooldownID, so a text overlay can
-- ride it and move wherever the player puts their CDM bars.
--
-- Walks itemFramePool:EnumerateActive(), NOT viewer:GetChildren(): CDM icons get
-- reparented (ArcUI moves them into its own groups), and a GetChildren sweep
-- silently misses those. Reading frame.cooldownID is a READ of a Blizzard field,
-- which never taints -- deliberately no CDM method calls or C_CooldownViewer
-- lookups here, since those are the paths that hand Blizzard code our taint.
local PT_CDM_VIEWERS = {
    "BuffIconCooldownViewer",
    "BuffBarCooldownViewer",
    "EssentialCooldownViewer",
    "UtilityCooldownViewer",
}

-- ── Action bar lookup ─────────────────────────────────────────────────────────
-- Find the action button currently holding one of `ids`, so a text overlay can
-- ride the player's own keybind button wherever their bars are.
--
-- Two sources, because no single one covers everything:
--   1. Every LibActionButton-1.0 registry in LibStub. Bartender4 and ElvUI each
--      ship their OWN copy under a different major string, so enumerate rather
--      than hardcode a name -- this picks up future LAB bars for free.
--   2. Known button names, for bars that are not LAB-based (Blizzard's own,
--      EllesmereUI).
--
-- `statehidden` buttons are skipped: a button on an inactive bar page still
-- exists and still reports an action slot, and anchoring to one would park the
-- text on something invisible.
--
-- A MACRO slot resolves to whatever it actually casts, so a "#showtooltip
-- Ascendance" macro matches exactly like a bare spell would.
local PT_BAR_PREFIXES = {
    "ActionButton", "MultiBarBottomLeftButton", "MultiBarBottomRightButton",
    "MultiBarRightButton", "MultiBarLeftButton",
    "MultiBar5Button", "MultiBar6Button", "MultiBar7Button",
}

local function ButtonHoldsSpell(btn, ids)
    if not btn then return false end
    if btn.GetAttribute and btn:GetAttribute("statehidden") then return false end
    if btn.IsShown and not btn:IsShown() then return false end
    local slot = btn.action or (btn.GetAttribute and btn:GetAttribute("action"))
    if type(slot) ~= "number" or not HasAction(slot) then return false end
    local aType, id = GetActionInfo(slot)
    if aType ~= "spell" and aType ~= "macro" then return false end
    if not id then return false end
    for i = 1, #ids do if ids[i] == id then return true end end
    return false
end

function PT.FindActionButton(ids)
    if type(ids) ~= "table" or #ids == 0 then return nil end
    if LibStub and type(LibStub.libs) == "table" then
        for major, lib in pairs(LibStub.libs) do
            if type(major) == "string" and major:find("^LibActionButton%-1%.0")
               and type(lib) == "table" and type(lib.GetAllButtons) == "function" then
                for b in pairs(lib:GetAllButtons()) do
                    if ButtonHoldsSpell(b, ids) then return b end
                end
            end
        end
    end
    for _, prefix in ipairs(PT_BAR_PREFIXES) do
        for i = 1, 12 do
            local b = _G[prefix .. i]
            if ButtonHoldsSpell(b, ids) then return b end
        end
    end
    return nil
end

function PT.FindCDMFrame(cooldownID)
    if not cooldownID or cooldownID == 0 then return nil end
    for _, viewerName in ipairs(PT_CDM_VIEWERS) do
        local viewer = _G[viewerName]
        if viewer and viewer.itemFramePool then
            for frame in viewer.itemFramePool:EnumerateActive() do
                if frame.cooldownID == cooldownID then return frame end
            end
        end
    end
    return nil
end

-- ── Deck proc chance ──────────────────────────────────────────────────────────
-- A deck is `size` cards holding `procs` procs, and every unit of resource
-- spent turns one card. So "will my next spender proc?" is hypergeometric:
-- draw K cards from the N remaining, which hold P remaining procs.
--
-- MissChance returns the probability of drawing NONE of the p procs. It is the
-- P-term form (at most a handful of factors) rather than the K-term one, which
-- keeps it exact in floating point and cheap:
--     C(n-p, k) / C(n, k) = product over j of (n-k-j) / (n-j)
local function MissChance(n, p, k)
    if p <= 0 then return 1 end          -- no procs left to hit
    if k <= 0 then return 1 end          -- drawing nothing hits nothing
    if n - k < p then return 0 end       -- drawing so many that a proc is certain
    local miss = 1
    for j = 0, p - 1 do
        miss = miss * (n - k - j) / (n - j)
    end
    return miss
end

-- CONTINUITY is the part players actually ask about: a spend that runs off the
-- end of the deck keeps drawing into the NEXT deck, which is freshly stocked.
-- So sitting on 0 procs left near the end of a deck is NOT a flat zero.
-- Returns a PERCENTAGE (0-100).
function PT.DeckChance(size, maxProcs, pos, procsHit, spend)
    size     = size or 1
    maxProcs = maxProcs or 0
    local K = tonumber(spend) or 0
    if K < 1 then K = 1 end
    local N = size - (pos % size)                  -- cards left in this deck
    local P = maxProcs - (procsHit or 0)           -- procs left in this deck
    if P < 0 then P = 0 end

    if K < N then
        return (1 - MissChance(N, P, K)) * 100
    end
    -- the spender consumes the rest of this deck; anything left over starts the
    -- next one. Emptying a deck that still holds procs cannot miss.
    local miss = (P > 0) and 0 or 1
    local over = K - N
    if over > 0 then
        miss = miss * MissChance(size, maxProcs, over)
    end
    return (1 - miss) * 100
end

-- Shared formatting so every deck's readout looks the same. A decimal matters
-- at the low end: a full Doom Winds deck sits at 4.9%, and rounding that to 5%
-- throws away most of the range the number ever moves in.
function PT.FormatChance(pct, decimals)
    if pct >= 99.95 then return "100%" end
    if decimals ~= false and pct < 10 then return string.format("%.1f%%", pct) end
    return string.format("%.0f%%", pct)
end

-- ── Widget helpers ────────────────────────────────────────────────────────────

-- Default colour for "N procs left", for any deck size: a full deck reads
-- green, a spent one red, anything between gold. Mirrors the proc counter's
-- own empty/half/full defaults so the two readouts start out agreeing.
-- NOTE the name: anything containing the literal "CountColor" trips the
-- pre-release upvalue checker, which matches defined names by SUBSTRING and
-- would flag this line as a call to CountColor below it.
local function ProcCountTint(left, maxProcs)
    if left <= 0 then return 1, 0, 0 end
    if left >= (maxProcs or 1) then return 0, 1, 0 end
    return 1, 0.82, 0
end

-- The stored override for a count, if the user set one.
local function CountColor(db, left, maxProcs)
    local t = db.chanceCountColors and db.chanceCountColors[left]
    if t then return t[1] or 1, t[2] or 1, t[3] or 1 end
    return ProcCountTint(left, maxProcs)
end
PT.CountColor = CountColor

-- Where a given text hangs. 0 / nil = this widget's own icon (the default and
-- the old behaviour). Anything else is a CDM cooldownID: the text rides that
-- icon and moves with the player's CDM bars.
--
-- FALLS BACK to the widget's icon whenever the CDM frame is not up (talent not
-- taken, spell not on their bars, mid-reshuffle). A text that silently vanishes
-- because its anchor went away is far worse than one that goes home.
-- The anchor SPEC is a string so it can name what kind of thing it points at:
--   nil / "" / "0"     this widget's own icon (the default, and the old behaviour)
--   "cdm:<cooldownID>" a Cooldown Manager icon
--   "action:<a,b,c>"   an action button holding ANY of those spell IDs. A list,
--                      because a spell can sit on the bar under more than one id
--                      (Ascendance is 114051 and 384352), and which one the bar
--                      reports depends on overrides.
-- A bare number is still accepted: this shipped as a cooldownID for one session
-- before action bars were an option.
local function ParseIDs(csv)
    local t = {}
    for n in tostring(csv):gmatch("[-]?%d+") do t[#t + 1] = tonumber(n) end
    return t
end

-- spec -> last frame we resolved it to. Never stale-dangerous: every read is
-- validated before use, so a wrong entry costs one failed check and a re-sweep.
local anchorCache = {}
local anchorIDs   = {}   -- spec -> parsed id list, so the pattern match is done once

function PT.InvalidateAnchorCache()
    wipe(anchorCache)
end

local function ResolveAnchor(spec)
    local ids = anchorIDs[spec]
    if not ids then
        local kind, rest = spec:match("^(%a+):(.+)$")
        if not kind then return nil end
        ids = { kind = kind, list = ParseIDs(rest) }
        anchorIDs[spec] = ids
    end

    -- validate the remembered frame first: O(1), and the common case
    local cached = anchorCache[spec]
    if cached then
        if ids.kind == "cdm" then
            if cached.cooldownID == ids.list[1] then return cached end
        elseif ids.kind == "action" then
            if ButtonHoldsSpell(cached, ids.list) then return cached end
        end
        anchorCache[spec] = nil
    end

    local found
    if ids.kind == "cdm" then
        found = PT.FindCDMFrame(ids.list[1])
    elseif ids.kind == "action" then
        found = PT.FindActionButton(ids.list)
    end
    anchorCache[spec] = found
    return found
end

-- ── Timer state visuals ───────────────────────────────────────────────────────
-- ONE writer for the icon's look, so alpha/desaturate/tint/glow can never fight
-- each other. Called from UpdateIcon's timer branch with the current state; it
-- reads that state's settings and applies all four.
-- Resolved lazily, NOT at file scope: Core loads before some libraries, and a
-- file-scope grab would cache nil forever and silently kill every glow.
local GLOW_KEY = "ArcPTState"
local function GetLCG()
    return LibStub and LibStub("LibCustomGlow-1.0", true)
end

local function StopStateGlow(w)
    local LCG = GetLCG()
    if not (LCG and w._icon) then return end
    local host = w._glowHost
    if not host then return end
    LCG.PixelGlow_Stop(host, GLOW_KEY)
    LCG.AutoCastGlow_Stop(host, GLOW_KEY)
    LCG.ButtonGlow_Stop(host, GLOW_KEY)
    LCG.ProcGlow_Stop(host, GLOW_KEY)
end

-- The sweep the game draws over the icon. Every knob here is a plain widget
-- setter, so none of it touches the duration itself -- the timer stays exactly
-- as secret-safe as it was.
local function ApplyCooldownLook(w, db)
    local cd = w._ngCooldown
    if not cd then return end
    cd:SetDrawSwipe(db.swipeShow ~= false)
    cd:SetSwipeColor(db.swipeR or 0, db.swipeG or 0, db.swipeB or 0,
        (type(db.swipeA) == "number") and db.swipeA or 0.8)
    cd:SetDrawEdge(db.swipeEdge == true)
    cd:SetHideCountdownNumbers(db.swipeNumbers == false)
    cd:SetDrawBling(db.swipeBling ~= false)
    cd:SetReverse(db.swipeReverse == true)
end

local function ApplyStateVisuals(w, db, onCD)
    if not w._icon then return end
    local p = onCD and "cd" or "rdy"
    local alpha = db[p .. "Alpha"]
    if type(alpha) ~= "number" then alpha = 1 end
    w._icon:SetAlpha(alpha)
    w._icon:SetDesaturated(db[p .. "Desat"] == true)
    if db[p .. "Tint"] == true then
        w._icon:SetVertexColor(db[p .. "TintR"] or 1, db[p .. "TintG"] or 1, db[p .. "TintB"] or 1)
    else
        w._icon:SetVertexColor(1, 1, 1)
    end

    -- Glow needs a FRAME to hang on; the icon is a texture. One host per widget.
    --
    -- PADDING AND MOVEMENT BOTH LIVE ON THE HOST, and LCG's own xOffset/yOffset
    -- are left at zero. Those arguments mean EXPANSION from the frame edge, not
    -- movement -- feeding a "move the glow down" value into them just grows the
    -- halo, which is the documented "proc glow sits lower" bug. Sizing the host
    -- for padding and anchoring it for movement keeps one mechanism for each and
    -- makes both behave identically across every style.
    local LCG = GetLCG()
    if not LCG then return end
    if not w._glowHost then
        w._glowHost = CreateFrame("Frame", nil, w)
    end
    StopStateGlow(w)
    if db[p .. "Glow"] ~= true then return end

    local iw, ih = w._icon:GetSize()
    if not iw or iw < 1 then iw, ih = 32, 32 end
    local pad = tonumber(db[p .. "GlowPad"]) or 0
    w._glowHost:ClearAllPoints()
    w._glowHost:SetSize(iw + pad * 2, ih + pad * 2)
    w._glowHost:SetPoint("CENTER", w._icon, "CENTER",
        tonumber(db[p .. "GlowX"]) or 0, tonumber(db[p .. "GlowY"]) or 0)

    local col   = { db[p .. "GlowR"] or 0.95, db[p .. "GlowG"] or 0.95, db[p .. "GlowB"] or 0.32, 1 }
    local style = db[p .. "GlowStyle"] or "pixel"
    local speed = tonumber(db[p .. "GlowSpeed"]) or 0.25
    if style == "autocast" then
        LCG.AutoCastGlow_Start(w._glowHost, col,
            tonumber(db[p .. "GlowParticles"]) or 4, speed,
            tonumber(db[p .. "GlowScale"]) or 1, 0, 0, GLOW_KEY)
    elseif style == "button" then
        LCG.ButtonGlow_Start(w._glowHost, col, speed, nil, GLOW_KEY, 0, 0)
    elseif style == "proc" or style == "procloop" then
        -- same art; the loop variant skips the burst intro, which on a state
        -- that is already running reads as a proc that just happened
        LCG.ProcGlow_Start(w._glowHost, {
            color = col, key = GLOW_KEY,
            startAnim = (style == "proc"),
            duration = tonumber(db[p .. "GlowDuration"]) or 1,
        })
    else
        -- length 0 means "let the library work it out from the frame size"
        local len = tonumber(db[p .. "GlowLength"]) or 0
        LCG.PixelGlow_Start(w._glowHost, col,
            tonumber(db[p .. "GlowLines"]) or 8, speed,
            (len > 0) and len or nil,
            tonumber(db[p .. "GlowThick"]) or 2,
            0, 0, db[p .. "GlowBorder"] == true, GLOW_KEY)
    end
end

local function TextAnchor(w, spec)
    -- Fast path, and the default: no anchor set means no lookup at all, so a
    -- user who never turns this on pays a single comparison.
    if spec == nil or spec == 0 or spec == "0" or spec == "" then return w._icon end
    if type(spec) == "number" then spec = "cdm:" .. spec end
    if type(spec) ~= "string" then return w._icon end
    return ResolveAnchor(spec) or w._icon
end
PT.TextAnchor = TextAnchor

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
            PT.SetFontSafe(w._violText, db.violFont, db.violSize or 12)
            w._violText:SetText(tostring(v))
            w._violText:ClearAllPoints()
            w._violText:SetPoint("CENTER", TextAnchor(w, db.violAnchor), "CENTER", db.violOffX or 0, db.violOffY or -20)
            w._violText:Show()
        else
            w._violText:Hide()
        end
    end
    -- A timer entry has no deck, so none of the deck-shaped readouts mean
    -- anything for it. Bail after the icon itself is drawn.
    if entry.isTimer then
        local onCD = entry.ns and entry.ns.IsOnCooldown and entry.ns.IsOnCooldown() or false
        if w._previewState then onCD = (w._previewState == "cd") end
        if w._icon then
            w._icon:SetShown(not textOnly)
            ApplyStateVisuals(w, db, onCD)
        end
        ApplyCooldownLook(w, db)
        if w._ngCooldown then w._ngCooldown:SetShown(not textOnly) end
        if w._deckText   then w._deckText:Hide() end
        if w._procText   then w._procText:Hide() end
        if w._chanceText then w._chanceText:Hide() end
        if w._violText   then w._violText:Hide() end
        if w._cdmWarn    then w._cdmWarn:Hide() end
        if w._cdmWarnText then w._cdmWarnText:Hide() end
        if textOnly then
            if w._arcPTBorderEdges then
                for _, t in pairs(w._arcPTBorderEdges) do t:Hide() end
            end
        else
            UpdateBorder(w, db, w._icon)
        end
        return
    end

    local deckSize = entry.deckSize
    local maxProcs = entry.procs
    local raw      = entry.GetDeckPos()   -- 0-based position in deck
    local procs    = entry.GetProcs()
    local pos      = db.countDown and (deckSize - raw) or raw
    local r, g, b  = ProcColor(db, procs, maxProcs)
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

    -- Optional per-deck text override. A tracker whose meaningful readout is not
    -- a deck position (e.g. Soulburst, an escalating-chance proc where the useful
    -- number is the CHANCE, not a card index) supplies GetDeckText/GetProcText and
    -- formats its own string. Decks that do not define them are untouched.
    local deckStr = tostring(pos) .. suffix
    if entry.GetDeckText then
        local s = entry.GetDeckText()
        if s ~= nil then deckStr = s end
    end

    PT.SetFontSafe(w._deckText, db.deckFont, db.deckSize)
    w._deckText:SetShadowOffset(1, -1); w._deckText:SetShadowColor(0, 0, 0, 1)
    w._deckText:SetText(deckStr)
    w._deckText:SetTextColor(db.deckR, db.deckG, db.deckB)
    w._deckText:ClearAllPoints()
    w._deckText:SetPoint("CENTER", TextAnchor(w, db.deckAnchor), "CENTER", db.deckOffX, db.deckOffY)
    w._deckText:SetShown(db.showDeckText ~= false)

    -- ── PROC CHANCE readout ────────────────────────────────────────────────
    -- Its own text, not a mode on the deck text, so it can sit alongside the
    -- card index rather than replacing it. Only decks that can actually work
    -- out a chance (GetChanceText) ever draw it.
    if w._chanceText then
        local wantChance = (db.showChanceText == true) and entry.GetChanceText ~= nil
        if wantChance then
            local pct = entry.GetChanceValue and entry.GetChanceValue() or nil
            local str = entry.GetChanceText()
            w._chanceText:SetText(str or "")
            local cr, cg, cb = db.chanceR or 1, db.chanceG or 1, db.chanceB or 1
            local mode = db.chanceColorMode or "fixed"
            if mode == "procs" then
                -- keyed on procs LEFT (what actually drives the chance), not on
                -- procs hit, so the colour tracks the number the reading means
                local left = maxProcs - procs
                if left < 0 then left = 0 end
                cr, cg, cb = CountColor(db, left, maxProcs)
            elseif mode == "chance" and pct then
                local lo = db.chanceLowPct or 3
                local hi = db.chanceHighPct or 10
                if pct >= hi then
                    cr, cg, cb = db.chanceHotR or 0, db.chanceHotG or 1, db.chanceHotB or 0
                elseif pct < lo then
                    cr, cg, cb = db.chanceColdR or 0.6, db.chanceColdG or 0.6, db.chanceColdB or 0.6
                else
                    cr, cg, cb = db.chanceMidR or 1, db.chanceMidG or 0.82, db.chanceMidB or 0
                end
            end
            PT.SetFontSafe(w._chanceText, db.chanceFont, db.chanceSize or 19)
            w._chanceText:SetShadowOffset(1, -1); w._chanceText:SetShadowColor(0, 0, 0, 1)
            w._chanceText:SetTextColor(cr, cg, cb)
            w._chanceText:ClearAllPoints()
            w._chanceText:SetPoint("CENTER", TextAnchor(w, db.chanceAnchor), "CENTER",
                db.chanceOffX or 0, db.chanceOffY or -27)
        end
        w._chanceText:SetShown(wantChance)
    end

    w._procText:SetShown(db.showProcText ~= false)
    local procStr = tostring(procDisp) .. procSuffix
    if entry.GetProcText then
        local s = entry.GetProcText()
        if s ~= nil then procStr = s end
    end

    PT.SetFontSafe(w._procText, db.procFont, db.procSize)
    w._procText:SetShadowOffset(1, -1); w._procText:SetShadowColor(0, 0, 0, 1)
    w._procText:SetText(procStr)
    w._procText:SetTextColor(r, g, b)
    w._procText:ClearAllPoints()
    w._procText:SetPoint("CENTER", TextAnchor(w, db.procAnchor), "CENTER", db.procOffX, db.procOffY)

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

-- PREVIEW: hold the icon in one state for a few seconds so its look can be
-- judged without waiting for the real thing. UpdateIcon reads _previewState
-- INSTEAD of the live state while it is set, so the preview cannot be stomped
-- by a refresh landing mid-preview (a proc, a bar event, an options rerender).
local PREVIEW_SECONDS = 6

function PT.PreviewState(entry, p)
    local w = entry and entry.widget
    if not w then return end
    w._previewState = p
    -- Show the sweep too when previewing the cooldown look, but never while a
    -- REAL cooldown is running -- overwriting it would lie about the timer.
    local live = entry.ns and entry.ns.IsOnCooldown and entry.ns.IsOnCooldown()
    if p == "cd" and w._ngCooldown and not live then
        w._ngCooldown:SetCooldown(GetTime(), PREVIEW_SECONDS)
    end
    UpdateIcon(entry)
    C_Timer.After(PREVIEW_SECONDS, function()
        if w._previewState ~= p then return end   -- a newer preview took over
        w._previewState = nil
        -- hand the icon back to whoever actually owns its state
        if entry.ns and entry.ns.Refresh then entry.ns.Refresh() else UpdateIcon(entry) end
    end)
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

    -- anchorTo may be a FRAME or a FUNCTION returning one. It has to be able to
    -- change: a text can ride a CDM icon, and CDM swaps those frames out from
    -- under us on every layout refresh.
    local function AT()
        if type(anchorTo) == "function" then return anchorTo() end
        return anchorTo
    end

    -- Anchor handle directly to the anchor (the icon) at the current text offset.
    -- The FontString's offset and the handle's offset use the same value,
    -- so dragging the handle directly mutates that offset in DB coordinates.
    local function Resync()
        local tw, th = fontString:GetStringWidth(), fontString:GetStringHeight()
        if tw < 12 then tw = 12 end
        if th < 12 then th = 12 end
        h:SetSize(tw + 6, th + 4)
        local d = getDB()
        h:ClearAllPoints()
        h:SetPoint("CENTER", AT(), "CENTER", d[offXKey] or 0, d[offYKey] or 0)
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
        self:SetPoint("CENTER", AT(), "CENTER", newX, newY)
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
            s:SetPoint("CENTER", AT(), "CENTER", newX, newY)
            fontString:ClearAllPoints()
            fontString:SetPoint("CENTER", AT(), "CENTER", newX, newY)
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
    for _, key in ipairs({"_deckTextHandle", "_procTextHandle", "_violTextHandle", "_chanceTextHandle"}) do
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

    f._deckTextHandle = MakeTextDragHandle(f, dt, function() return TextAnchor(f, IconDB(id).deckAnchor) end,
        function() return IconDB(id) end, "deckOffX", "deckOffY",
        function() UpdateIcon(entry) end)

    local pt = f:CreateFontString(nil, "OVERLAY")
    pt:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", db.procSize, "OUTLINE")
    pt:SetPoint("CENTER", icon, "CENTER", db.procOffX, db.procOffY)
    pt:SetTextColor(db.emptyR, db.emptyG, db.emptyB)
    pt:SetDrawLayer("OVERLAY", 2)
    f._procText = pt

    f._procTextHandle = MakeTextDragHandle(f, pt, function() return TextAnchor(f, IconDB(id).procAnchor) end,
        function() return IconDB(id) end, "procOffX", "procOffY",
        function() UpdateIcon(entry) end)

    -- Timer entries (Nature's Guardian) draw a real Cooldown over the icon and
    -- hand it a duration object. WoW renders the swipe AND the countdown text
    -- itself, so the remaining time is never read, compared or stored in Lua --
    -- which is what keeps it correct under instance cooldown secrecy.
    if entry.isTimer then
        local cd = CreateFrame("Cooldown", nil, f, "CooldownFrameTemplate")
        cd:SetAllPoints(icon)
        f._ngCooldown = cd
    end

    local ct = f:CreateFontString(nil, "OVERLAY")
    ct:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", db.chanceSize or 19, "OUTLINE")
    ct:SetPoint("CENTER", icon, "CENTER", db.chanceOffX or 0, db.chanceOffY or -27)
    ct:SetTextColor(db.chanceR or 1, db.chanceG or 1, db.chanceB or 1)
    ct:SetDrawLayer("OVERLAY", 2)
    ct:SetText("")
    ct:SetShown(db.showChanceText == true)
    f._chanceText = ct

    f._chanceTextHandle = MakeTextDragHandle(f, ct, function() return TextAnchor(f, IconDB(id).chanceAnchor) end,
        function() return IconDB(id) end, "chanceOffX", "chanceOffY",
        function() UpdateIcon(entry) end)

    local vt = f:CreateFontString(nil, "OVERLAY")
    vt:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", db.violSize or 12, "OUTLINE")
    vt:SetPoint("CENTER", icon, "CENTER", db.violOffX or 0, db.violOffY or -20)
    vt:SetTextColor(db.violR or 1, db.violG or 0.2, db.violB or 0.2)
    vt:SetDrawLayer("OVERLAY", 2)
    vt:SetText("")
    vt:SetShown(db.showViolations == true)
    f._violText = vt

    f._violTextHandle = MakeTextDragHandle(f, vt, function() return TextAnchor(f, IconDB(id).violAnchor) end,
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
    if id == "dw"             then return PT.DW end
    if id == "stormunleashed" then return PT.StormUnleashed end
    if id == "tempest"        then return PT.Tempest end
    if id == "elemtempest"    then return PT.ElemTempest end
    -- Fallback: a deck can hand its namespace to RegisterDeck. Without this, a
    -- new deck that is missed above silently loses ALL CDM tracking -- not just
    -- the status text, but InvalidateAllCDMFrames and SchedulePTCDMRehook too,
    -- so it would never re-hook after a CDM rebuild.
    local entry = registryMap[id]
    return entry and entry.ns or nil
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

    -- ── Per-deck option overrides ────────────────────────────────────────────
    -- Every label here was written for a DECK: "Deck Position", "All Procs Used",
    -- "/250 suffix". A tracker that is not a deck (Soulburst is an escalating
    -- proc chance) inherits wording that describes nothing it does, and options
    -- that are wired to fields its display overrides ignore.
    --
    -- entry.ui     renames a label or description
    -- entry.uiHide removes an option the deck's display makes inert
    --
    -- Both are optional; every existing deck is untouched.
    local UI     = entry.ui     or {}
    local UIHIDE = entry.uiHide or {}
    local function L(key, default) return UI[key] or default end
    -- hidden() that also respects the deck's own opt-out
    -- A timer entry has no deck, so every deck-shaped row hides with it.
    -- Deck-only rows that do NOT go through H(). Kept as its own helper so the
    -- next deck-specific option added here has an obvious thing to use.
    local function notTimer()
        return function() return iconHidden() or entry.isTimer end
    end
    local function H(key)
        return function()
            return iconHidden() or entry.isTimer or UIHIDE[key] == true
        end
    end
    -- chance rows: hidden unless this deck can compute one AND it is switched on
    local function CH()
        return function()
            return iconHidden() or not entry.GetChanceText or db().showChanceText ~= true
        end
    end
    -- the threshold rows on top of that: only in "chance" colour mode
    local function CHC()
        return function()
            return CH()() or (db().chanceColorMode or "fixed") ~= "chance"
        end
    end
    -- ATTACH TO: build the two rows (preset picker + custom ID) that let one
    -- text ride a CDM icon instead of this widget's own. Shared by all four
    -- texts rather than written out per text, because they differ only by key.
    local function AnchorRows(args, key, order0, visible)
        -- One list, two kinds: Cooldown Manager icons and action bar buttons.
        local opts = {}
        for _, p in ipairs(entry.cdmAnchors or {}) do
            opts[#opts + 1] = { spec = "cdm:" .. p.id, name = p.name .. "  (CDM)" }
        end
        for _, p in ipairs(entry.actionAnchors or {}) do
            opts[#opts + 1] = { spec = "action:" .. table.concat(p.ids, ","),
                                name = p.name .. "  (action bar)" }
        end
        local function cur()
            local v = db()[key]
            if type(v) == "number" then return (v == 0) and "0" or ("cdm:" .. v) end
            return v or "0"
        end
        local function isCustom()
            local v = cur()
            if v == "0" then return false end
            for _, o in ipairs(opts) do if o.spec == v then return false end end
            return true
        end
        args[key] = {
            type = "select", name = "Attach To",
            desc = "Where this text sits."
                .. "|n|n|cff8298b4This icon keeps it on the ProcTracker widget. Attach it to a Cooldown Manager icon or one of your action bar buttons and the text rides that instead, moving wherever you put your bars. If the target is not up (talent not taken, spell not on your bars, or an inactive bar page) the text falls back to this widget rather than disappearing.|r",
            order = order0, width = 1.5,
            hidden = visible,
            values = function()
                local t = { ["0"] = "This icon" }
                for _, o in ipairs(opts) do t[o.spec] = o.name end
                t["custom"] = "Custom cooldown ID..."
                return t
            end,
            sorting = function()
                local s = { "0" }
                for _, o in ipairs(opts) do s[#s + 1] = o.spec end
                s[#s + 1] = "custom"
                return s
            end,
            get = function() return isCustom() and "custom" or cur() end,
            set = function(_, v)
                -- "custom" is a sentinel, not a value: keep whatever is already
                -- set so choosing it does not wipe the ID being edited
                if v == "custom" then
                    if not isCustom() then db()[key] = "cdm:1" end
                else
                    db()[key] = v
                end
                refresh()
            end,
        }
        args[key .. "Custom"] = {
            type = "input", name = "Cooldown ID",
            desc = "The CDM cooldownID to attach to. ArcUI's Show IDs on Hover shows these on a Cooldown Manager icon.",
            order = order0 + 0.001, width = 1.0,
            hidden = function()
                if visible() then return true end
                return not isCustom()
            end,
            get = function() return (cur():match("(%d+)")) or "" end,
            set = function(_, v)
                local n = tonumber(v)
                if not n then return end
                db()[key] = "cdm:" .. math.floor(n)
                refresh()
            end,
        }
    end

    -- the procs-left colour rows: only in "procs" colour mode
    local function CHP()
        return function()
            return CH()() or (db().chanceColorMode or "fixed") ~= "procs"
        end
    end

    local T = {
        type = "group",
        name = entry.name,
        args = {

            -- ── WIDGET (master toggle lives WITH the icon options; the header
            -- is never hidden so a disabled deck can be re-enabled) ───────────
            iconHeader = {
                type = "header", name = "Widget", order = o(),
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

            -- Optional per-deck load condition. A deck that is only meaningful
            -- under some external requirement (Soulburst needs the MID2 2-piece)
            -- supplies entry.loadCondition; decks without one never see this.
            loadCondition = {
                type  = "toggle",
                -- Never empty even when hidden: AceConfig renders a nameless
                -- control badly if the hidden check is ever bypassed.
                name  = (entry.loadCondition and entry.loadCondition.name) or "Load Condition",
                desc  = (entry.loadCondition and entry.loadCondition.desc) or "",
                order = o(), width = "full",
                hidden = function() return entry.loadCondition == nil end,
                -- A deck may declare defaultOn: a load condition that is the
                -- sensible default for that deck (Soulburst is meaningless
                -- without the set bonus it tracks). nil means "never touched",
                -- so it falls through to the deck's preference.
                get   = function()
                    local v = db().requireLoad
                    if v == nil then
                        return (entry.loadCondition and entry.loadCondition.defaultOn) == true
                    end
                    return v == true
                end,
                set   = function(_, v)
                    db().requireLoad = v
                    if entry.loadCondition and entry.loadCondition.Apply then
                        entry.loadCondition.Apply()
                    end
                end,
            },
            loadConditionStatus = {
                type  = "description",
                name  = function()
                    local lc = entry.loadCondition
                    if not lc or not lc.Status then return "" end
                    return lc.Status()
                end,
                order = o(), width = "full",
                hidden = function()
                    local lc = entry.loadCondition
                    if lc == nil then return true end
                    local v = db().requireLoad
                    if v == nil then v = lc.defaultOn == true end
                    return v ~= true
                end,
            },

            lockPosition = {
                type  = "toggle", name = "Lock Position",
                desc  = "Prevent the icon from being dragged. When locked the frame is click-through.",
                order = o(), width = "half",
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
                order = o(), width = "half",
                hidden = iconHidden,
                get   = function() return db().textOnly == true end,
                set   = function(_, v)
                    db().textOnly = v
                    refresh()
                end,
            },
            hideOOC = {
                type  = "toggle", name = "Hide Out of Combat",
                desc  = "Hide this icon whenever you are not in combat, and show it again when combat starts.",
                order = o(), width = 1.2,
                hidden = iconHidden,
                get   = function() return db().hideOOC == true end,
                set   = function(_, v)
                    db().hideOOC = v
                    local wf = entry.widget
                    if wf then
                        if not v then
                            -- Restore immediately and clear our ownership flag
                            -- so nothing later re-hides it.
                            wf._ptHiddenByOOC = nil
                            if db().deckEnabled ~= false then wf:Show() end
                        else
                            PT.RefreshCombatVisibility()
                        end
                    end
                end,
            },
            textsUnlocked = {
                type  = "toggle", name = "Unlock Texts (Drag to Position)",
                desc  = "Enables click-and-drag on the deck, proc, and violation texts. A faint blue overlay marks the draggable area. Disable to lock and click-through.",
                order = o(), width = "half",
                hidden = notTimer(),
                get   = function() return db().textsUnlocked == true end,
                set   = function(_, v)
                    db().textsUnlocked = v
                    ApplyTextDragHandleState(entry, v)
                end,
            },
            desaturateEmpty = {
                type  = "toggle", name = "Desaturate when no procs left",
                desc  = "Desaturates the icon texture when proc count is 0.",
                order = o(), width = "half",
                hidden = notTimer(),
                get   = function() return db().desaturateEmpty == true end,
                set   = function(_, v)
                    db().desaturateEmpty = v
                    refresh()
                end,
            },

            -- ── POSITION & SIZE ───────────────────────────────────────────────
            posHeader = {
                type = "header", name = "Position & Size", order = o(),
                hidden = iconHidden,
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
                order  = o(), width = "half",
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

            -- ── DECK POSITION TEXT ────────────────────────────────────────────
            deckTextHeader = {
                type = "header", name = L("deckTextHeader", "Deck Position Text"), order = o(),
                hidden = function() return iconHidden() or entry.isTimer end,
            },
            deckTextNote = {
                type = "description", name = L("deckTextNote", ""), order = o(),
                hidden = function() return iconHidden() or L("deckTextNote", "") == "" end,
            },
            showDeckText = {
                type  = "toggle", name = "Show Deck Position",
                desc  = "Draw the card position on the icon.",
                order = o(), width = "full",
                hidden = H("showDeckText"),
                get   = function() return db().showDeckText ~= false end,
                set   = function(_, v) db().showDeckText = v; refresh() end,
            },
            countDown = {
                type  = "toggle", name = "Count Down  (600 to 0)",
                order = o(), width = "half",
                hidden = function()
                    return H("countDown")() or db().showDeckText == false
                end,
                get   = function() return db().countDown end,
                set   = function(_, v) db().countDown = v; refresh() end,
            },
            showDeckSuffix = {
                type  = "toggle", name = "Show /" .. entry.deckSize .. " suffix",
                order = o(), width = "half",
                hidden = function()
                    return H("showDeckSuffix")() or db().showDeckText == false
                end,
                get   = function() return db().showDeckSuffix end,
                set   = function(_, v) db().showDeckSuffix = v; refresh() end,
            },
            deckFont = {
                type = "select", name = "Font",
                desc = L("deckFontDesc",
                    "Font for the deck position text. Includes fonts shared by other addons, such as ArcUI."),
                order = o(), width = 1.2,
                dialogControl = "LSM30_Font",
                hidden = function() return iconHidden() or not PT.HasSharedMedia() end,
                values = function() return PT.FontValues() end,
                get  = function() return db().deckFont end,
                set  = function(_, v) db().deckFont = v; PT.ApplyIconFonts(entry); refresh() end,
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
                type = "header", name = L("procTextHeader", "Proc Count"), order = o(),
                hidden = function() return iconHidden() or entry.isTimer end,
            },
            procTextNote = {
                type = "description", name = L("procTextNote", ""), order = o(),
                hidden = function() return iconHidden() or L("procTextNote", "") == "" end,
            },
            showProcText = {
                type  = "toggle", name = "Show Proc Count",
                desc  = "Draw the proc counter on the icon.",
                order = o(), width = "full",
                hidden = H("showProcText"),
                get   = function() return db().showProcText ~= false end,
                set   = function(_, v) db().showProcText = v; refresh() end,
            },
            procCountDown = {
                type  = "toggle", name = "Count Down  (3 to 0)",
                order = o(), width = "half",
                hidden = function()
                    return H("procCountDown")() or db().showProcText == false
                end,
                get   = function() return db().procCountDown end,
                set   = function(_, v) db().procCountDown = v; refresh() end,
            },
            showProcSuffix = {
                type  = "toggle", name = "Show /" .. entry.procs .. " suffix",
                order = o(), width = "half",
                hidden = H("showProcSuffix"),
                get   = function() return db().showProcSuffix end,
                set   = function(_, v) db().showProcSuffix = v; refresh() end,
            },
            procFont = {
                type = "select", name = "Font",
                desc = L("procFontDesc",
                    "Font for the proc count text. Includes fonts shared by other addons, such as ArcUI."),
                order = o(), width = 1.2,
                dialogControl = "LSM30_Font",
                hidden = function() return iconHidden() or not PT.HasSharedMedia() end,
                values = function() return PT.FontValues() end,
                get  = function() return db().procFont end,
                set  = function(_, v) db().procFont = v; PT.ApplyIconFonts(entry); refresh() end,
            },
            procSize = {
                type = "range", name = "Font Size",
                min = 6, max = 32, step = 1,
                order = o(), width = "full",
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

            -- proc count colors flow in the same "Proc Count" section
            emptyColor = {
                type = "color", name = L("emptyColorName", "All Procs Available"),
                desc  = L("emptyColorDesc", "No procs used this deck"),
                order = o(), width = "full", hasAlpha = false,
                hidden = H("emptyColor"),
                get  = function() return db().emptyR, db().emptyG, db().emptyB end,
                set  = function(_, r, g, b)
                    local d = db(); d.emptyR=r; d.emptyG=g; d.emptyB=b; refresh()
                end,
            },
            halfColor = {
                type = "color", name = L("halfColorName", "Procs Partially Used"),
                desc  = L("halfColorDesc", "Some but not all procs used"),
                order = o(), width = "full", hasAlpha = false,
                hidden = H("halfColor"),
                get  = function() return db().halfR, db().halfG, db().halfB end,
                set  = function(_, r, g, b)
                    local d = db(); d.halfR=r; d.halfG=g; d.halfB=b; refresh()
                end,
            },
            fullColor = {
                type = "color", name = L("fullColorName", "All Procs Used"),
                desc  = L("fullColorDesc", "All procs consumed this deck"),
                order = o(), width = "full", hasAlpha = false,
                hidden = H("fullColor"),
                get  = function() return db().fullR, db().fullG, db().fullB end,
                set  = function(_, r, g, b)
                    local d = db(); d.fullR=r; d.fullG=g; d.fullB=b; refresh()
                end,
            },

            -- ── PROC CHANCE TEXT ──────────────────────────────────────────────
            -- Only offered by decks that can work out a chance (GetChanceText).
            chanceHeader = {
                type = "header", name = "Proc Chance Text", order = o(),
                hidden = function() return iconHidden() or not entry.GetChanceText end,
            },
            showChanceText = {
                type  = "toggle", name = "Show Proc Chance",
                desc  = "The odds your NEXT spender procs, from the cards and procs left in the deck."
                     .. "|n|nA spender that runs off the end of the deck keeps drawing into the next one, so this never sits at a flat zero just because the current deck is spent.",
                order = o(), width = "full",
                hidden = function() return iconHidden() or not entry.GetChanceText end,
                get   = function() return db().showChanceText == true end,
                set   = function(_, v)
                    db().showChanceText = v
                    local w = entry.widget
                    if w and w._chanceText then w._chanceText:SetShown(v) end
                    UpdateIcon(entry)
                end,
            },
            chanceSpend = {
                type = "range", name = "Spender Maelstrom Cost",
                desc = "How many Maelstrom Weapon stacks your next spender is assumed to eat. Enhancement spends a full 10.",
                order = o(), width = 1.2,
                min = 1, max = 10, step = 1,
                hidden = function() return CH()() or not entry.chanceSpendSlider end,
                get = function() return db().chanceSpend or 10 end,
                set = function(_, v) db().chanceSpend = v; refresh() end,
            },
            chanceForecast = {
                type = "select", name = "Forecast",
                desc = "Which spender the chance assumes you will cast next."
                    .. "|n|n|cff8298b4Instant, follow casts assumes Earth Shock or Earthquake while nothing is on the cast bar, and switches to Elemental Blast the moment you start casting it. Costs are read from the game, so Eye of the Storm is already accounted for.|r",
                order = o(), width = 1.4,
                hidden = function() return CH()() or not entry.chanceForecastPicker end,
                values  = {
                    auto    = "Instant, follow casts",
                    instant = "Instant only",
                    blast   = "Elemental Blast only",
                },
                sorting = { "auto", "instant", "blast" },
                get = function() return db().chanceForecast or "auto" end,
                set = function(_, v) db().chanceForecast = v; refresh() end,
            },
            chanceForecastNote = {
                type = "description", order = o(), fontSize = "medium",
                name = function()
                    return "|cff8298b4Assuming: "
                        .. (PT.ElemTempest_ForecastLabel and PT.ElemTempest_ForecastLabel() or "?")
                        .. "|r"
                end,
                hidden = function() return CH()() or not entry.chanceForecastPicker end,
            },
            chanceDecimals = {
                type = "toggle", name = "Show a decimal  (4.9% not 5%)",
                order = o(), width = 1.4,
                hidden = CH(),
                get = function() return db().chanceDecimals ~= false end,
                set = function(_, v) db().chanceDecimals = v; refresh() end,
            },
            chanceColorMode = {
                type = "select", name = "Colour By",
                desc = "|cff8298b4Fixed keeps one colour. Procs left reuses the proc counter's own colours, so both readouts agree. Chance colours by the percentage itself, using the thresholds below.|r",
                order = o(), width = 1.2,
                hidden = CH(),
                values  = { fixed = "Fixed colour", procs = "Procs left", chance = "Chance" },
                sorting = { "fixed", "procs", "chance" },
                get = function() return db().chanceColorMode or "fixed" end,
                set = function(_, v) db().chanceColorMode = v; refresh() end,
            },
            chanceColor = {
                type = "color", name = "Colour", order = o(), width = "half", hasAlpha = false,
                hidden = function()
                    return CH()() or (db().chanceColorMode or "fixed") ~= "fixed"
                end,
                get = function() return db().chanceR or 1, db().chanceG or 1, db().chanceB or 1 end,
                set = function(_, r, g, b)
                    local d = db(); d.chanceR=r; d.chanceG=g; d.chanceB=b; refresh()
                end,
            },
            -- Each threshold sits directly under the colour it switches on, so
            -- the pair reads as one rule instead of two disconnected sliders.
            chanceColdColor = {
                type = "color", name = "Low Colour", order = o(), width = "half", hasAlpha = false,
                hidden = CHC(),
                get = function() return db().chanceColdR or 0.6, db().chanceColdG or 0.6, db().chanceColdB or 0.6 end,
                set = function(_, r, g, b)
                    local d = db(); d.chanceColdR=r; d.chanceColdG=g; d.chanceColdB=b; refresh()
                end,
            },
            chanceLowPct = {
                type = "input", name = "Low Below (%)",
                desc = "Use the low colour while the chance is under this.",
                order = o(), width = 1.0,
                hidden = CHC(),
                get = function() return tostring(db().chanceLowPct or 3) end,
                set = function(_, v)
                    local n = tonumber(v); if not n then return end
                    if n < 0 then n = 0 elseif n > 100 then n = 100 end
                    db().chanceLowPct = n; refresh()
                end,
            },
            chanceMidColor = {
                type = "color", name = "Mid Colour", order = o(), width = "half", hasAlpha = false,
                hidden = CHC(),
                get = function() return db().chanceMidR or 1, db().chanceMidG or 0.82, db().chanceMidB or 0 end,
                set = function(_, r, g, b)
                    local d = db(); d.chanceMidR=r; d.chanceMidG=g; d.chanceMidB=b; refresh()
                end,
            },
            chanceHotColor = {
                type = "color", name = "High Colour", order = o(), width = "half", hasAlpha = false,
                hidden = CHC(),
                get = function() return db().chanceHotR or 0, db().chanceHotG or 1, db().chanceHotB or 0 end,
                set = function(_, r, g, b)
                    local d = db(); d.chanceHotR=r; d.chanceHotG=g; d.chanceHotB=b; refresh()
                end,
            },
            chanceHighPct = {
                type = "input", name = "High At (%)",
                desc = "Use the high colour once the chance reaches this.",
                order = o(), width = 1.0,
                hidden = CHC(),
                get = function() return tostring(db().chanceHighPct or 10) end,
                set = function(_, v)
                    local n = tonumber(v); if not n then return end
                    if n < 0 then n = 0 elseif n > 100 then n = 100 end
                    db().chanceHighPct = n; refresh()
                end,
            },

            -- "Procs left" mode: one colour row per proc count, generated
            -- after this table from entry.procs (see the loop below).
            chanceFont = {
                type = "select", name = "Font",
                desc = "Font for the proc chance text. Includes fonts shared by other addons, such as ArcUI.",
                order = o(), width = 1.2,
                dialogControl = "LSM30_Font",
                hidden = function() return CH()() or not PT.HasSharedMedia() end,
                values = function() return PT.FontValues() end,
                get  = function() return db().chanceFont end,
                set  = function(_, v) db().chanceFont = v; PT.ApplyIconFonts(entry); refresh() end,
            },
            chanceSize = {
                type = "range", name = "Font Size",
                min = 6, max = 40, step = 1,
                order = o(), width = "half",
                hidden = CH(),
                get  = function() return db().chanceSize or 19 end,
                set  = function(_, v) db().chanceSize = v; refresh() end,
            },
            chanceOffX = {
                type = "range", name = "Offset X",
                min = -100, max = 100, step = 1,
                order = o(), width = "half",
                hidden = CH(),
                get  = function() return db().chanceOffX or 0 end,
                set  = function(_, v)
                    db().chanceOffX = v; refresh()
                    local w = entry.widget
                    if w and w._chanceTextHandle and w._chanceTextHandle._resync then
                        w._chanceTextHandle._resync()
                    end
                end,
            },
            chanceOffY = {
                type = "range", name = "Offset Y",
                min = -100, max = 100, step = 1,
                order = o(), width = "half",
                hidden = CH(),
                get  = function() return db().chanceOffY or -27 end,
                set  = function(_, v)
                    db().chanceOffY = v; refresh()
                    local w = entry.widget
                    if w and w._chanceTextHandle and w._chanceTextHandle._resync then
                        w._chanceTextHandle._resync()
                    end
                end,
            },

            -- ── VIOLATIONS (lives in the Proc Count section: no own header;
            -- the violation counter is a proc-count companion) ────────────────
            showViolations = {
                type  = "toggle", name = "Show Violation Counter",
                desc  = "Shows a count of decks that had wrong proc count. Disabled by default.",
                order = o(), width = "full",
                hidden = H("showViolations"),
                get   = function() return db().showViolations == true end,
                set   = function(_, v)
                    db().showViolations = v
                    local w = entry.widget
                    if w and w._violText then w._violText:SetShown(v) end
                    UpdateIcon(entry)
                end,
            },
            violFont = {
                type = "select", name = "Font",
                desc = "Font for the violation counter text. Includes fonts shared by other addons, such as ArcUI.",
                order = o(), width = 1.2,
                dialogControl = "LSM30_Font",
                hidden = function()
                    return iconHidden() or not db().showViolations or not PT.HasSharedMedia()
                end,
                values = function() return PT.FontValues() end,
                get  = function() return db().violFont end,
                set  = function(_, v) db().violFont = v; PT.ApplyIconFonts(entry); refresh() end,
            },
            violSize = {
                type = "range", name = "Font Size",
                min = 6, max = 32, step = 1,
                order = o(), width = "half",
                hidden = function() return iconHidden() or not db().showViolations end,
                get  = function() return db().violSize or 12 end,
                set  = function(_, v)
                    db().violSize = v
                    -- Go through the normal redraw rather than setting the font
                    -- here: hardcoding the default font meant changing the size
                    -- silently threw away the user's chosen violation font.
                    refresh()
                end,
            },
            violColor = {
                type = "color", name = "Color",
                order = o(), width = "half", hasAlpha = false,
                hidden = function() return iconHidden() or not db().showViolations end,
                get  = function() return db().violR or 1, db().violG or 0.2, db().violB or 0.2 end,
                set  = function(_, r, g, b)
                    local d = db(); d.violR=r; d.violG=g; d.violB=b
                    local w = entry.widget
                    if w and w._violText then w._violText:SetTextColor(r, g, b) end
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
        },
    }

    -- PER-PROC-COUNT COLOUR ROWS. Generated rather than written out because
    -- deck sizes differ (3 for Doom Winds, 5 for Storm Unleashed, 1 for
    -- Soulburst), so the number of rows is a property of the deck. Listed
    -- from a full deck down to a spent one, the order it actually depletes in.
    do
        local maxProcs = entry.procs or 1
        local args = T.args.icon and T.args.icon.args or T.args
        -- Anchor the generated rows to the option they follow. o() only ever
        -- counts UP, and this loop runs AFTER the whole table is built, so
        -- calling o() here would order these rows past every later section and
        -- drop them under Border instead of in Proc Chance Text. Fractional
        -- offsets off the High At row keep them exactly where the fixed
        -- swatches used to sit.
        local base = (args.chanceHighPct and args.chanceHighPct.order) or 0
        local k = 0
        for left = maxProcs, 0, -1 do
            local n = left
            k = k + 1
            local label
            if n == 0 then label = "No Procs Left"
            elseif n == 1 then label = "1 Proc Left"
            else label = n .. " Procs Left" end
            args["chanceCount" .. n] = {
                type = "color", name = label, order = base + k * 0.001, width = "half", hasAlpha = false,
                hidden = CHP(),
                get = function()
                    return PT.CountColor(db(), n, maxProcs)
                end,
                set = function(_, r, g, b)
                    local d = db()
                    d.chanceCountColors = d.chanceCountColors or {}
                    d.chanceCountColors[n] = { r, g, b }
                    refresh()
                end,
            }
        end
    end
    -- STATE VISUAL sections, timer entries only. Generated per state rather than
    -- written out twice: the two differ only by prefix and label.
    if entry.isTimer then
        local args = T.args.icon and T.args.icon.args or T.args
        -- COOLDOWN ANIMATION, before the state sections: it describes the sweep
        -- itself rather than either state's look.
        do
            local function on() return iconHidden() end
            args.swipeHeader = {
                type = "header", name = "Cooldown Animation", order = o(), hidden = on,
            }
            args.swipeNote = {
                type = "description", order = o(), fontSize = "medium",
                name = "|cff8298b4The sweep the game draws over the icon while the cooldown runs.|r",
                hidden = on,
            }
            args.swipeShow = {
                type = "toggle", name = "Show Sweep", order = o(), width = 1.2, hidden = on,
                get = function() return db().swipeShow ~= false end,
                set = function(_, v) db().swipeShow = v; refresh() end,
            }
            args.swipeColor = {
                type = "color", name = "Sweep Colour", order = o(), width = "half",
                hasAlpha = true,
                hidden = function() return on() or db().swipeShow == false end,
                get = function()
                    local d = db()
                    return d.swipeR or 0, d.swipeG or 0, d.swipeB or 0,
                           (type(d.swipeA) == "number") and d.swipeA or 0.8
                end,
                set = function(_, r, g, b, a)
                    local d = db(); d.swipeR, d.swipeG, d.swipeB, d.swipeA = r, g, b, a
                    refresh()
                end,
            }
            args.swipeEdge = {
                type = "toggle", name = "Show Edge Line",
                desc = "The bright line that travels the leading edge of the sweep.",
                order = o(), width = 1.2, hidden = on,
                get = function() return db().swipeEdge == true end,
                set = function(_, v) db().swipeEdge = v; refresh() end,
            }
            args.swipeNumbers = {
                type = "toggle", name = "Show Countdown Numbers",
                order = o(), width = 1.4, hidden = on,
                get = function() return db().swipeNumbers ~= false end,
                set = function(_, v) db().swipeNumbers = v; refresh() end,
            }
            args.swipeBling = {
                type = "toggle", name = "Finish Flash",
                desc = "The flash the game plays as the cooldown ends.",
                order = o(), width = 1.2, hidden = on,
                get = function() return db().swipeBling ~= false end,
                set = function(_, v) db().swipeBling = v; refresh() end,
            }
            args.swipeReverse = {
                type = "toggle", name = "Reverse Sweep",
                desc = "Fill the icon as the cooldown runs down instead of unfilling it.",
                order = o(), width = 1.2, hidden = on,
                get = function() return db().swipeReverse == true end,
                set = function(_, v) db().swipeReverse = v; refresh() end,
            }
            args.swipePreview = {
                type = "execute", name = "Preview Sweep",
                desc = "Run a short cooldown on the icon so you can see the sweep,"
                    .. " the edge line and the finish flash.",
                order = o(), width = 1.4, hidden = on,
                func = function() PT.PreviewState(entry, "cd") end,
            }
        end

        local STATES = {
            { p = "rdy", title = "Ready State",
              note = "How the icon looks while the proc is available." },
            { p = "cd",  title = "On Cooldown State",
              note = "How the icon looks while the internal cooldown is running." },
        }
        for _, st in ipairs(STATES) do
            local p = st.p
            local function on() return iconHidden() end
            args[p .. "Header"] = {
                type = "header", name = st.title, order = o(),
                hidden = on,
            }
            args[p .. "Note"] = {
                type = "description", order = o(), fontSize = "medium",
                name = "|cff8298b4" .. st.note .. "|r", hidden = on,
            }
            args[p .. "Alpha"] = {
                type = "range", name = "Opacity", min = 0, max = 1, step = 0.05,
                order = o(), width = 1.2, hidden = on,
                get = function() local v = db()[p .. "Alpha"]; return (type(v) == "number") and v or 1 end,
                set = function(_, v) db()[p .. "Alpha"] = v; refresh() end,
            }
            args[p .. "Desat"] = {
                type = "toggle", name = "Desaturate",
                desc = "Grey the icon out, the way the game does for a spell on cooldown.",
                order = o(), width = 1.2, hidden = on,
                get = function() return db()[p .. "Desat"] == true end,
                set = function(_, v) db()[p .. "Desat"] = v; refresh() end,
            }
            args[p .. "Tint"] = {
                type = "toggle", name = "Tint", order = o(), width = 1.2, hidden = on,
                get = function() return db()[p .. "Tint"] == true end,
                set = function(_, v) db()[p .. "Tint"] = v; refresh() end,
            }
            args[p .. "TintColor"] = {
                type = "color", name = "Tint Colour", order = o(), width = "half",
                hasAlpha = false,
                hidden = function() return on() or db()[p .. "Tint"] ~= true end,
                get = function() return db()[p .. "TintR"] or 1, db()[p .. "TintG"] or 1, db()[p .. "TintB"] or 1 end,
                set = function(_, r, g, b)
                    local d = db(); d[p .. "TintR"], d[p .. "TintG"], d[p .. "TintB"] = r, g, b
                    refresh()
                end,
            }
            args[p .. "Glow"] = {
                type = "toggle", name = "Glow", order = o(), width = 1.2, hidden = on,
                get = function() return db()[p .. "Glow"] == true end,
                set = function(_, v) db()[p .. "Glow"] = v; refresh() end,
            }
            args[p .. "GlowStyle"] = {
                type = "select", name = "Glow Style", order = o(), width = 1.2,
                hidden = function() return on() or db()[p .. "Glow"] ~= true end,
                values  = {
                    pixel    = "Pixel Glow",
                    autocast = "AutoCast Sparkles",
                    button   = "Button Glow",
                    proc     = "Blizzard Proc",
                    procloop = "Proc Loop (no burst)",
                },
                sorting = { "button", "pixel", "autocast", "proc", "procloop" },
                get = function() return db()[p .. "GlowStyle"] or "pixel" end,
                set = function(_, v) db()[p .. "GlowStyle"] = v; refresh() end,
            }
            args[p .. "GlowColor"] = {
                type = "color", name = "Glow Colour", order = o(), width = "half",
                hasAlpha = false,
                hidden = function() return on() or db()[p .. "Glow"] ~= true end,
                get = function() return db()[p .. "GlowR"] or 0.95, db()[p .. "GlowG"] or 0.95, db()[p .. "GlowB"] or 0.32 end,
                set = function(_, r, g, b)
                    local d = db(); d[p .. "GlowR"], d[p .. "GlowG"], d[p .. "GlowB"] = r, g, b
                    refresh()
                end,
            }
            -- SUPPORT MATRIX: every style honours a different subset, so a knob
            -- that would do nothing is hidden rather than shown dead. Mirrors
            -- ArcUI's GetSupportedOpts.
            local function glowOn() return on() or db()[p .. "Glow"] ~= true end
            local function styleIs(...)
                local want = { ... }
                return function()
                    if glowOn() then return true end
                    local cur = db()[p .. "GlowStyle"] or "pixel"
                    for i = 1, #want do if want[i] == cur then return false end end
                    return true
                end
            end
            local function num(key, label, desc, mn, mx, step, dflt, hide)
                args[p .. key] = {
                    type = "range", name = label, desc = desc,
                    order = o(), width = 1.2,
                    min = mn, max = mx, step = step,
                    hidden = hide,
                    get = function()
                        local v = db()[p .. key]
                        return (type(v) == "number") and v or dflt
                    end,
                    set = function(_, v) db()[p .. key] = v; refresh() end,
                }
            end
            -- shared by every style
            num("GlowPad", "Glow Size",
                "Grows the glow outward from the icon edge.", -16, 32, 1, 0, glowOn)
            num("GlowX", "Glow Offset X",
                "Moves the glow. Separate from Glow Size, which only expands it.",
                -50, 50, 1, 0, glowOn)
            num("GlowY", "Glow Offset Y",
                "Moves the glow. Separate from Glow Size, which only expands it.",
                -50, 50, 1, 0, glowOn)
            num("GlowSpeed", "Animation Speed", nil, 0.01, 2, 0.01, 0.25,
                styleIs("pixel", "autocast", "button"))
            -- pixel only
            num("GlowLines", "Lines", "How many line segments travel the border.",
                1, 30, 1, 8, styleIs("pixel"))
            num("GlowLength", "Line Length", "0 sizes each line from the icon.",
                0, 30, 1, 0, styleIs("pixel"))
            num("GlowThick", "Line Thickness", nil, 1, 12, 1, 2, styleIs("pixel"))
            args[p .. "GlowBorder"] = {
                type = "toggle", name = "Draw Behind Border",
                order = o(), width = 1.2, hidden = styleIs("pixel"),
                get = function() return db()[p .. "GlowBorder"] == true end,
                set = function(_, v) db()[p .. "GlowBorder"] = v; refresh() end,
            }
            -- autocast only
            num("GlowParticles", "Sparkle Count", nil, 1, 20, 1, 4, styleIs("autocast"))
            num("GlowScale", "Sparkle Scale", nil, 0.2, 3, 0.05, 1, styleIs("autocast"))
            -- proc only
            num("GlowDuration", "Animation Duration", nil, 0.1, 5, 0.1, 1,
                styleIs("proc", "procloop"))
            args[p .. "Preview"] = {
                type = "execute", name = "Preview This State",
                desc = "Hold the icon in this state for a few seconds so you can"
                    .. " see the look without waiting for it to happen.",
                order = o(), width = 1.4, hidden = on,
                func = function() PT.PreviewState(entry, p) end,
            }
        end
    end

    -- ATTACH TO rows for each text, anchored just under the option they follow
    -- (o() only counts up and this runs after the table is built, so calling it
    -- here would order these past every later section).
    do
        local args = T.args.icon and T.args.icon.args or T.args
        local function after(k, fallback)
            local a = args[k]
            return (a and a.order) or fallback
        end
        AnchorRows(args, "deckAnchor",   after("showDeckSuffix", 0) + 0.0005,
            function() return iconHidden() or db().showDeckText == false end)
        AnchorRows(args, "procAnchor",   after("showProcSuffix", 0) + 0.0005,
            function() return iconHidden() or db().showProcText == false end)
        AnchorRows(args, "chanceAnchor", after("chanceOffY", 0) + 0.0005, CH())
        AnchorRows(args, "violAnchor",   after("violOffY", 0) + 0.0005,
            function() return iconHidden() or not db().showViolations end)
    end
    return T
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
            mplusHeader = {
                type = "header", name = "Mythic+", order = 0.1,
            },
            safeMPlusReset = {
                type  = "toggle",
                name  = "Safe Mythic+ Reset",
                desc  = "Reset every deck the moment a key starts.\n\n"
                    .."ON (recommended): the reset can never be missed. If it is ever skipped, "
                    .."the deck stays wrong for the whole dungeon, so this is the safe choice.\n\n"
                    .."OFF: the deck resets on the yellow gate drop instead, matching the game "
                    .."exactly. This keeps 'the skip' working, where leaving the dungeon across "
                    .."the gate drop and coming back keeps your deck.",
                order = 0.2,
                width = "full",
                get = function()
                    local db = ArcUI_ProcTrackerDB or {}
                    if db.safeMPlusReset == nil then return true end   -- default ON
                    return db.safeMPlusReset == true
                end,
                set = function(_, v)
                    ArcUI_ProcTrackerDB = ArcUI_ProcTrackerDB or {}
                    ArcUI_ProcTrackerDB.safeMPlusReset = v and true or false
                end,
            },
            minimapHeader = {
                type = "header", name = "Minimap Button", order = 1,
            },
            classicOptions = {
                type  = "toggle",
                name  = "Classic Options Panel",
                desc  = "Use the old options window instead of the new Arc look. Applies immediately.",
                order = 0.5,
                width = "full",
                get = function()
                    local db = ArcUI_ProcTrackerDB or {}
                    return db.classicOptions == true
                end,
                set = function(_, v)
                    ArcUI_ProcTrackerDB = ArcUI_ProcTrackerDB or {}
                    ArcUI_ProcTrackerDB.classicOptions = v and true or false
                    -- swap the open panel to the chosen style immediately
                    local skin = LibStub and LibStub("ArcSkin-1.0", true)
                    local sw = skin and skin:GetOptionsWindow(PT_OPTIONS_NAME)
                    local aceFrame = AceConfigDialog and AceConfigDialog.OpenFrames
                        and AceConfigDialog.OpenFrames[PT_OPTIONS_NAME]
                    local wasOpen = (sw and sw.frame:IsShown()) or (aceFrame ~= nil)
                    if sw and sw.frame:IsShown() then sw.frame:Hide() end
                    if aceFrame and AceConfigDialog then AceConfigDialog:Close(PT_OPTIONS_NAME) end
                    if wasOpen then
                        C_Timer.After(0.05, function() BuildOptionsPanel() end)
                    end
                end,
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

        -- Behavior: everything that affects the DECK itself rather than one of
        -- its displays. Reset and the detection method both apply to the Icon
        -- and the Bar equally, so neither belongs inside the Widget tab -- and
        -- nothing in here is gated on the icon being enabled.
        -- Sounds gets its own tab rather than living inside Icon: it is not about
        -- the widget, and it is where every future audio option belongs.
        -- Sounds gets its own tab rather than living inside Icon: it is not about
        -- the widget, and it is where every future audio option belongs.
        --
        -- NOTE this is built in the CALLER, outside BuildDeckOptionsGroup, so the
        -- `db()` / `o()` locals that the icon options use are NOT in scope here.
        -- Use the public accessor instead -- reaching for db() made every render
        -- of this tab throw "attempt to call a nil value".
        local function sdb() return PT.GetIconDB(entry.id) end
        local function soundOff() return not sdb().procSoundEnabled end
        local function playCurrent()
            if PT.Sounds then PT.Sounds.Play(sdb().procSound, sdb().procSoundChannel) end
        end
        local soundsGroup = {
            type = "group", name = "Sounds", order = 2.5,
            args = {
                procHeader = {
                    type = "header", name = "Proc Sound", order = 0,
                },
                procEnabled = {
                    type  = "toggle", name = "Enable Proc Sound",
                    desc  = "Play a sound the moment a proc comes off this deck."
                         .. "|n|nYour chosen sound is kept when this is off, so you can silence it for one pull and switch it back on without picking it again.",
                    order = 1, width = 1.4,
                    get   = function() return sdb().procSoundEnabled and true or false end,
                    set   = function(_, v)
                        sdb().procSoundEnabled = v and true or false
                        -- hear it the moment you switch it on
                        if v then playCurrent() end
                    end,
                },
                procSound = {
                    type  = "select", name = "Proc Sound",
                    desc  = "Play a sound when a proc comes off this deck. "
                         .. "|cff8298b4The Ultra Instinct and Kaching sounds ship with ProcTracker. The Reveal and Alert entries are the game's own sounds, so they cost nothing and work for everyone. Any LibSharedMedia sound you have installed is offered too, so you can use your own file.|r",
                    order = 2, width = 1.4,
                    disabled = soundOff,
                    values  = function() return PT.Sounds and PT.Sounds.Values() or { None = "None" } end,
                    sorting = function() return PT.Sounds and PT.Sounds.Sorting() or { "None" } end,
                    get   = function() return sdb().procSound or "None" end,
                    set   = function(_, v)
                        sdb().procSound = v
                        -- preview on pick: choosing a sound you cannot hear is useless
                        if PT.Sounds then PT.Sounds.Play(v, sdb().procSoundChannel) end
                    end,
                    -- ArcSkin puts a speaker in the field and on every line of
                    -- the pullout, so you can audition a sound without picking it
                    arcPreview = function(_, v)
                        if PT.Sounds then PT.Sounds.Play(v, sdb().procSoundChannel) end
                    end,
                },
                procChannel = {
                    type  = "select", name = "Output Channel",
                    desc  = "Which of the game's volume sliders this sound comes out of. "
                         .. "|cff8298b4Master ignores the other sliders, so the sound stays audible even with Sound Effects turned right down. Pick one of the others if you would rather it follow a slider you already set.|r",
                    order = 3, width = 1.4,
                    disabled = soundOff,
                    values  = function() return PT.Sounds and PT.Sounds.ChannelValues() or { Master = "Master" } end,
                    sorting = function() return PT.Sounds and PT.Sounds.ChannelSorting() or { "Master" } end,
                    get   = function() return sdb().procSoundChannel or "Master" end,
                    set   = function(_, v)
                        sdb().procSoundChannel = v
                        if PT.Sounds then PT.Sounds.Play(sdb().procSound, v) end
                    end,
                    -- hear the current sound on whichever channel you point at
                    arcPreview = function(_, v)
                        if PT.Sounds then PT.Sounds.Play(sdb().procSound, v) end
                    end,
                },
            },
        }

        local behaviorGroup = {
            type = "group", name = "Behavior", order = 3,
            args = {
                resetDesc = {
                    type = "description", order = 1, width = "full",
                    name = "Resets this deck's tracking — deck position and proc count back to zero. Applies to both the Icon widget and the Bar.",
                },
                resetDeck = {
                    type  = "execute", name = "Reset Deck Tracking",
                    desc  = "Reset deck position and proc count to zero",
                    order = 2, width = "full",
                    func  = function()
                        if entry.OnReset then entry.OnReset() end
                        UpdateIcon(entry)
                    end,
                },

                -- ── DETECTION METHOD ─────────────────────────────────────────
                -- Switches what runs under the hood. Nothing here touches the
                -- user's layout: the icon, the bar and their positions are
                -- untouched, only the source the deck counts from changes.
                cdmHeader = {
                    type = "header", name = "Detection Method", order = 10,
                    hidden = function()
                        local ns = GetDeckNS(entry.id)
                        if ns and ns.CanSkipCDM and ns.CanSkipCDM() then return false end
                        return entry.noCDMWarn
                    end,
                },
                cdmFreeStatus = {
                    type = "description", order = 11, width = "full",
                    -- Name the talent when the deck can tell us which one it is.
                    -- "your talents" leaves the user guessing which to keep.
                    name = function()
                        local ns  = GetDeckNS(entry.id)
                        local why = ns and ns.SkipCDMReason and ns.SkipCDMReason()
                        if why then
                            return "|cff44FF44Cooldown Manager not needed — |r|cffFFD000"
                                ..why.."|r|cff44FF44 provides the tracking signal.|r"
                        end
                        return "|cff44FF44Cooldown Manager not needed — your talents provide "
                            .."the tracking signal.|r"
                    end,
                    hidden = function()
                        local ns = GetDeckNS(entry.id)
                        return not (ns and ns.CanSkipCDM and ns.CanSkipCDM())
                            or IconDB(entry.id).forceCDM == true
                    end,
                },
                forceCDM = {
                    type = "toggle", name = "Use CDM Detection Instead",
                    desc = "Your talents let this deck track procs without CDM. Turn this on "
                        .."to fall back to the CDM method if the talent-based tracking ever "
                        .."misbehaves. Lose the talent and the deck falls back on its own.",
                    order = 12, width = "full",
                    hidden = function()
                        local ns = GetDeckNS(entry.id)
                        return not (ns and ns.CanSkipCDM and ns.CanSkipCDM())
                    end,
                    get = function() return IconDB(entry.id).forceCDM == true end,
                    set = function(_, v)
                        IconDB(entry.id).forceCDM = v
                        local ns = GetDeckNS(entry.id)
                        if ns and ns.SetForceCDM then ns.SetForceCDM(v) end
                        UpdateIcon(entry)
                    end,
                },
                cdmStatus = {
                    type = "description", order = 13, width = "full",
                    name = function()
                        local ns = GetDeckNS(entry.id)
                        local ok = ns and ns.IsCDMTracking and ns.IsCDMTracking()
                        if ok then
                            return "|cff44FF44CDM frame hooked — tracking active|r"
                        else
                            return "|cffFF4444CDM frame NOT found — detection disabled|r"
                        end
                    end,
                    hidden = function() return entry.noCDMWarn end,
                },
                cdmReverify = {
                    type = "execute", name = "Reverify CDM Tracking",
                    desc = "Scans CDM viewers and re-hooks the tracking frame. Use this if tracking failed on login.",
                    order = 14, width = "full",
                    hidden = function() return entry.noCDMWarn end,
                    func = function()
                        local ns = GetDeckNS(entry.id)
                        if ns and ns.RehookCDM then
                            ns.RehookCDM()
                            C_Timer.After(0.1, function()
                                UpdateIcon(entry)
                                local skin = LibStub and LibStub("ArcSkin-1.0", true)
                                local sw = skin and skin:GetOptionsWindow(PT_OPTIONS_NAME)
                                if sw and sw.frame:IsShown() then
                                    skin:Refresh(PT_OPTIONS_NAME)
                                else
                                    AceConfigDialog:Open(PT_OPTIONS_NAME)
                                end
                            end)
                        end
                    end,
                },
            },
        }

        -- Deck tab wraps the sub-groups
        local deckTab = {
            type        = "group",
            name        = entry.name,
            order       = order,
            childGroups = "tab",
            args        = {
                icon  = iconGroup,
                -- A timer entry has no deck, so the Bar tab (which plots deck
                -- position) and the Behavior tab (deck reset, violations,
                -- rollover) have nothing to say about it. Omitted rather than
                -- shown empty.
                bar   = (not entry.isTimer) and (barGroup or {
                    type = "group", name = "Bar", order = 2,
                    args = {
                        noBar = {
                            type = "description", order = 1,
                            name = "|cff888888Bar module not loaded.|r",
                        }
                    }
                }) or nil,
                -- Only decks whose proc site calls PT.Sounds.PlayFor get this
                -- tab. Showing it everywhere would offer a sound that never
                -- plays on the decks that are not wired up yet.
                sounds = entry.hasProcSound and soundsGroup or nil,
                reset = (not entry.isTimer) and behaviorGroup or nil,
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

-- skipValidation is REQUIRED, not an optimization. Our section headers carry
-- `arcGroup`, a custom key ArcSkin reads to bucket consecutive sections into
-- tabs. ArcSkin gets the table handed to it directly so it never cares, but the
-- Classic panel goes through AceConfigDialog -> AceConfigRegistry, whose
-- validator rejects ANY key it does not know and throws "arcGroup: unknown
-- parameter", killing the panel outright. There is no public way to whitelist a
-- custom key -- basekeys is a local upvalue -- so the supported escape is this
-- flag. AceConfigDialog itself ignores keys it does not recognize, so the
-- Classic panel renders fine without it.
-- MIND THE API. The flag has to go to AceConfigREGISTRY, whose third argument is
-- skipValidation. AceConfig-3.0's third argument is SLASHCMD, so the old
-- `AceConfig:RegisterOptionsTable(name, tbl, true)` broke the Classic panel two
-- ways at once: validation still ran (so arcGroup threw "unknown parameter"), and
-- `true` was taken as a slash command, sending CreateChatCommand into
-- LibStub("AceConsole-3.0") -- a library this addon does not load -- which threw
-- outright. Net effect: /pt opened nothing for anyone on Classic Options.
local function RefreshMasterOptions()
    if not AceConfigRegistry or not AceConfigDialog then return end
    AceConfigRegistry:RegisterOptionsTable(PT_OPTIONS_NAME, BuildMasterOptionsTable(), true)
    optionsRegistered = true
end

-- Arc 2.0 theme: render the SAME options table in the ArcSkin window.
-- Live refresh: PT fires NotifyChange on drag/CDM updates -- forward it.
local skinNotifyListener
local function OpenSkinnedOptions(entry)
    local skin = LibStub and LibStub("ArcSkin-1.0", true)
    if not skin then return false end
    if not skinNotifyListener and AceConfigRegistry and AceConfigRegistry.RegisterCallback then
        skinNotifyListener = {}
        AceConfigRegistry.RegisterCallback(skinNotifyListener, "ConfigTableChange", function(_, appName)
            if appName == PT_OPTIONS_NAME then skin:Refresh(PT_OPTIONS_NAME) end
        end)
    end
    local version = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata("ArcUI_ProcTracker", "Version")) or ""
    local db = ArcUI_ProcTrackerDB or {}
    -- one-time size migration: pre-two-column saved widths are too narrow
    -- for the paired-row layout; reset them once so the new look shows
    if db.skinWinV ~= 2 then
        db.skinWinV = 2
        if db.skinWinW and db.skinWinW < 700 then db.skinWinW, db.skinWinH = nil, nil end
    end
    skin:ToggleOptions(PT_OPTIONS_NAME, BuildMasterOptionsTable(), {
        title = "ProcTracker",
        version = version,
        width = db.skinWinW or 760, height = db.skinWinH or 640,
        selectTab = entry and entry.id or nil,
        onResize = function(w, h)
            ArcUI_ProcTrackerDB = ArcUI_ProcTrackerDB or {}
            ArcUI_ProcTrackerDB.skinWinW = math.floor(w + 0.5)
            ArcUI_ProcTrackerDB.skinWinH = math.floor(h + 0.5)
        end,
    })
    return true
end

-- Both option paths call this after opening: force opted-in widgets visible for
-- the duration of the session, and arm the OnHide hook that restores normal
-- visibility on close. Deferred because the frame does not exist until the
-- window has actually been built.
local function ArmOptionsPreview()
    C_Timer.After(0.05, function()
        if PT.WatchOptionsFrame then PT.WatchOptionsFrame() end
        if PT.RefreshCombatVisibility then PT.RefreshCombatVisibility() end
    end)
end

BuildOptionsPanel = function(entry)
    -- the Arc look is the DEFAULT (Arc's call); Classic is the opt-out
    local db = ArcUI_ProcTrackerDB
    if not (db and db.classicOptions) and OpenSkinnedOptions(entry) then
        ArmOptionsPreview()
        return
    end

    if not AceConfigRegistry or not AceConfigDialog then
        print("|cffFF4444ProcTracker:|r AceConfig not available")
        return
    end

    RefreshMasterOptions()

    local frame = AceConfigDialog.OpenFrames and AceConfigDialog.OpenFrames[PT_OPTIONS_NAME]
    if frame and frame.frame and frame.frame:IsShown() then
        AceConfigDialog:Close(PT_OPTIONS_NAME)
        if PT.RefreshCombatVisibility then PT.RefreshCombatVisibility() end
    else
        AceConfigDialog:Open(PT_OPTIONS_NAME)
        ArmOptionsPreview()
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
    -- If SavedVariables are already in, build the widget immediately.
    -- Must be savedVarsLoaded, NOT `if ArcUI_ProcTrackerDB then` -- see the note
    -- on savedVarsLoaded above.
    if savedVarsLoaded then
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

-- ── Out-of-combat hiding ─────────────────────────────────────────────────────
-- Opt-in per deck. This is layered ON TOP of the existing gates rather than
-- replacing them: a widget shows only if the user enabled it AND (it is not set
-- to hide out of combat OR we are in combat). Talent visibility still owns
-- whether Show is attempted at all.
local function InCombat()
    return InCombatLockdown() or UnitAffectingCombat("player")
end

-- While the options panel is open, widgets are forced visible even when set to
-- hide out of combat -- otherwise the thing you are configuring is invisible
-- exactly when you are trying to position it. Works for both the Arc skin
-- window and the classic AceConfig one.
local function GetOptionsFrame()
    local skin = LibStub and LibStub("ArcSkin-1.0", true)
    local sw = skin and skin.GetOptionsWindow and skin:GetOptionsWindow(PT_OPTIONS_NAME)
    if sw and sw.frame then return sw.frame end
    local af = AceConfigDialog and AceConfigDialog.OpenFrames
               and AceConfigDialog.OpenFrames[PT_OPTIONS_NAME]
    return af and af.frame or nil
end

function PT.OptionsShown()
    local f = GetOptionsFrame()
    return (f and f:IsShown()) and true or false
end

-- Re-evaluate when the panel closes, however it was closed (X, Escape, /pt).
-- Hooked once per frame; HookScript cannot be removed, so guard with a flag.
function PT.WatchOptionsFrame()
    local f = GetOptionsFrame()
    if not f or f._ptOOCHooked then return end
    f._ptOOCHooked = true
    f:HookScript("OnHide", function() PT.RefreshCombatVisibility() end)
end

-- The single "should an opted-in widget be visible right now" test.
local function ShouldShowOOC()
    return InCombat() or PT.OptionsShown()
end
PT.ShouldShowOOC = ShouldShowOOC

local function CombatAllowsIcon(idb)
    return not idb.hideOOC or ShouldShowOOC()
end

function PT.CombatAllowsShow(idb)
    return CombatAllowsIcon(idb)
end

-- Safe show for talent-driven visibility — respects user's deckEnabled setting.
-- Deck modules call this instead of entry.widget:Show() directly.
function PT.ShowDeckIconIfEnabled(id)
    local entry = registryMap[id]
    if not entry or not entry.widget then return end
    local idb = IconDB(id)
    if idb.deckEnabled ~= false and CombatAllowsIcon(idb) then
        entry.widget:Show()
    end
end

-- Re-evaluate every widget's combat visibility. Called on combat start/end and
-- whenever the option is toggled. Only ever acts on decks that opted in, so a
-- deck with hideOOC off is never touched here and keeps its existing state.
function PT.RefreshCombatVisibility()
    local shouldShow = ShouldShowOOC()
    for _, entry in ipairs(registry) do
        local idb = IconDB(entry.id)
        local w = entry.widget
        if w then
            if idb.hideOOC then
                if shouldShow then
                    w._ptHiddenByOOC = nil
                    if idb.deckEnabled ~= false then w:Show() end
                else
                    w._ptHiddenByOOC = true
                    w:Hide()
                end
            elseif w._ptHiddenByOOC then
                -- Option was turned off while we had it hidden: undo OUR hide
                -- only, never anything hidden by deckEnabled or talent gating.
                w._ptHiddenByOOC = nil
                if idb.deckEnabled ~= false then w:Show() end
            end
        end
        if PT.ApplyBarVisibility then
            PT.ApplyBarVisibility(entry)
        end
    end
end

local combatWatch = CreateFrame("Frame")
combatWatch:RegisterEvent("PLAYER_REGEN_DISABLED")
combatWatch:RegisterEvent("PLAYER_REGEN_ENABLED")
-- PLAYER_ENTERING_WORLD so a widget set to hide out of combat starts hidden at
-- login and after a reload, instead of showing until the first combat ends.
combatWatch:RegisterEvent("PLAYER_ENTERING_WORLD")
combatWatch:SetScript("OnEvent", function() PT.RefreshCombatVisibility() end)

-- ── Lifecycle ─────────────────────────────────────────────────────────────────
local watchFrame = CreateFrame("Frame")
watchFrame:RegisterEvent("ADDON_LOADED")
watchFrame:RegisterEvent("PLAYER_LOGIN")
watchFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
-- COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED handled via CooldownViewerItemDataMixin hooks below

watchFrame:SetScript("OnEvent", function(_, event, a1, a2)
    if event == "ADDON_LOADED" and a1 == "ArcUI_ProcTracker" then
        ArcUI_ProcTrackerDB = ArcUI_ProcTrackerDB or {}
        -- Set BEFORE any build below: this is the first moment the saved table is
        -- guaranteed real rather than one GetDB() fabricated for us.
        savedVarsLoaded = true
        -- Build icons for all registered decks.
        -- The `not entry.widget` guard is REQUIRED, not defensive. SavedVariables
        -- are populated before ADDON_LOADED fires, so a deck file that manages to
        -- register at load time (talent APIs happened to be ready) hits the
        -- "ArcUI_ProcTrackerDB already exists" branch in RegisterDeck and builds
        -- its widget there. Without this check we would build a SECOND one here.
        -- BuildIconWidget names its frame ArcUI_PT_Icon_<id>, so the duplicate
        -- overwrites the global and the first frame is orphaned on screen --
        -- visible, never updated, never hidden. That is the two-icons bug.
        for _, entry in ipairs(registry) do
            if not entry.widget then
                BuildIconWidget(entry)
                if entry.OnEnable then entry.OnEnable() end
            end
        end
        InitMinimapButton()
        -- (login chat message removed -- Arc's call: minimal chat output;
        -- the minimap button and /pt are the discoverability paths)
        return
    end

    if event == "PLAYER_LOGIN" then
        -- C_ClassTalents becomes available shortly after PLAYER_LOGIN
        -- Retry deck registration in case talents weren't ready at file load time
        C_Timer.After(0.5, function()
            for _, fn in ipairs(PT.OnEnterWorld) do fn() end
            -- Build widgets for any newly registered decks
            for _, entry in ipairs(registry) do
                if not entry.widget and savedVarsLoaded then
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
    -- a CDM reshuffle moves cooldownIDs between pooled frames
    PT.InvalidateAnchorCache()
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
        -- Re-anchor immediately as well: a text riding a CDM icon is pointed at
        -- a POOLED frame, and after a reshuffle that frame may now belong to a
        -- different cooldown. Waiting for the 1s settle would leave the text
        -- sitting on the wrong icon in the meantime.
        UpdateIcon(entry)
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

-- Action buttons MOVE without being destroyed: bar paging, stance swaps and
-- vehicles all change which slot a button shows. A text riding a button would
-- otherwise stay put and end up on whatever occupies it next, so re-resolve on
-- the same events the bars themselves react to. Event-driven, no polling.
local ptBarWatch = CreateFrame("Frame")
ptBarWatch:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
ptBarWatch:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
ptBarWatch:RegisterEvent("UPDATE_BONUS_ACTIONBAR")
ptBarWatch:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
ptBarWatch:SetScript("OnEvent", function()
    PT.InvalidateAnchorCache()
    for _, entry in ipairs(registry) do UpdateIcon(entry) end
end)

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

-- LOGOUT / RELOG is the third reset case, and it needs no code: the server
-- resets the deck when the character leaves and returns, and every deck keeps
-- its position in plain locals that are NEVER written to SavedVariables. So a
-- reload or a relog starts every deck at 0, which matches. Do NOT "improve"
-- this by persisting deck position -- that would survive a reset the server
-- performed and desync the counter permanently.
-- SAFE M+ RESET (default ON). The gate-drop chain below is precise but FRAGILE,
-- and when it misses there is no second chance for the rest of the key: the arm
-- is one-shot, so a missed confirm means the deck silently runs the whole dungeon
-- desynced from the server. Reported repeatedly as "sometimes it misses a reset
-- and then never resets again".
-- Safe mode resets on CHALLENGE_MODE_START instead, which is unconditional and
-- cannot be missed.
-- THE TRADE-OFF, deliberately accepted as the default: this breaks "the skip".
-- The server only resets decks for players INSIDE at the gate drop, so someone
-- who zones out across the drop keeps their real deck while safe mode resets the
-- addon's. Turning this OFF restores the skip-accurate gate-drop chain.
-- Skipping is niche; a silently wrong deck for a whole key is not.
local function SafeMPlusResetEnabled()
    local db = ArcUI_ProcTrackerDB
    if not db or db.safeMPlusReset == nil then return true end   -- default ON
    return db.safeMPlusReset == true
end
PT.SafeMPlusResetEnabled = SafeMPlusResetEnabled

local cmResetArmed = false; local cmResetStartTS = nil; local cmResetInstID = nil
local lastEnterWorldTS = -10
local resetEventFrame = CreateFrame("Frame")
resetEventFrame:RegisterEvent("ENCOUNTER_START")
resetEventFrame:RegisterEvent("CHALLENGE_MODE_RESET")
resetEventFrame:RegisterEvent("CHALLENGE_MODE_START")   -- safe-mode reset (see SafeMPlusResetEnabled)
resetEventFrame:RegisterEvent("WORLD_STATE_TIMER_START")
resetEventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
resetEventFrame:SetScript("OnEvent", function(_, event, a1)
    if event == "PLAYER_ENTERING_WORLD" then
        lastEnterWorldTS = GetTime()
        return
    end
    if event == "ENCOUNTER_START" then
        -- RULE: a RAID encounter start resets the server's deck. An M+ boss does
        -- NOT -- inside a key only the yellow-gate drop resets, handled below via
        -- CHALLENGE_MODE_RESET + WORLD_STATE_TIMER_START. ENCOUNTER_START fires on
        -- every M+ boss too, so acting on it there would wipe the deck several
        -- times per key.
        --
        -- Gate on INSTANCE TYPE, not difficulty. M+ is type "party", so it is
        -- excluded structurally. The previous numeric list (14-17, 233) was too
        -- narrow: the target-dummy dome reports type=raid diff=3 ("10 Player")
        -- and fires ENCOUNTER_START (encounterID 3591 "Sinister Single"), and the
        -- server DOES reset there -- so dummy practice was silently drifting.
        -- Legacy raid difficulties were missing for the same reason.
        local inInst, instType = IsInInstance()
        if inInst and instType == "raid" then ResetAllDecks() end
        return
    end
    if event == "CHALLENGE_MODE_START" then
        -- SAFE MODE: unconditional reset the moment the key starts. Cannot be
        -- missed by a lost arm, a slow load, or a competing world-state timer.
        if SafeMPlusResetEnabled() then ResetAllDecks() end
        return
    end
    if event == "CHALLENGE_MODE_RESET" then
        cmResetArmed = true; cmResetStartTS = GetTime()
        cmResetInstID = select(8, GetInstanceInfo()); return
    end
    if event == "WORLD_STATE_TIMER_START" and cmResetArmed then
        -- ONLY timerID 1 consumes the arm. This disarm used to sit OUTSIDE the
        -- a1 check, so ANY world-state timer firing between CHALLENGE_MODE_RESET
        -- and the real gate-drop timer ate the arm, and the genuine confirm was
        -- then never seen. The chain is one-shot with no retry, so that key ran
        -- its whole duration with a desynced deck -- "it missed the reset and
        -- then never reset again". Unrelated timers are now ignored, and the arm
        -- expires on its own once the 9s window has passed.
        if a1 ~= 1 then
            if (GetTime() - (cmResetStartTS or 0)) > 9 then
                cmResetArmed = false; cmResetStartTS = nil; cmResetInstID = nil
            end
            return
        end
        do
            local inInst, instType = IsInInstance()
            local diff   = select(3, GetInstanceInfo())
            local instID = select(8, GetInstanceInfo())
            -- Deck-reset SKIP protection: the server only resets proc decks for
            -- players INSIDE at the yellow-gate drop; zoning out across the drop
            -- ("the skip") keeps the deck. When a skipper zones back in, the
            -- client syncs the already-running key timer and fires a load-sync
            -- WORLD_STATE_TIMER_START — which can land within the 9s arm window
            -- if the skip was fast, wrongly resetting the addon deck. A genuine
            -- gate-drop event fires while standing in the world; a load-sync one
            -- fires right after PLAYER_ENTERING_WORLD. Reject the latter.
            if inInst and instType == "party" and diff == 8 and instID == cmResetInstID
            and (GetTime() - (cmResetStartTS or 0)) <= 9
            and (GetTime() - lastEnterWorldTS) > 2.5 then ResetAllDecks() end
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

    -- /pt classic  -- switch options style WITHOUT the panel. The toggle for this
    -- normally lives inside the panel, so if one style ever fails to open, the
    -- setting that would fix it is unreachable. This is the way out.
    if arg == "classic" or arg == "arc" then
        ArcUI_ProcTrackerDB = ArcUI_ProcTrackerDB or {}
        ArcUI_ProcTrackerDB.classicOptions = (arg == "classic")
        print("|cffFFAA00ProcTracker|r options style: " .. (arg == "classic" and "Classic" or "Arc"))
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

    -- /pt resetlab → toggle the combat-entry deck RESET probe
    if arg == "resetlab" then
        if not PT.ResetLab then
            print("|cffFF4444ProcTracker:|r ResetLab not loaded")
            return
        end
        PT.ResetLab.Toggle()
        return
    end

    -- /pt sudebug → toggle Storm Unleashed timeline debugger
    -- /pt sudebug export → open window and export
    if arg == "sudebug" or arg:sub(1,8) == "sudebug " then
        if not ArcUI_PT_SUDebug then
            print("|cffFF4444ProcTracker:|r SUDebug not loaded")
            return
        end
        local sub = arg:sub(9)
        if sub == "export" then
            if not ArcUI_PT_SUDebug.IsEnabled() then ArcUI_PT_SUDebug.Toggle() end
            C_Timer.After(0.1, function() ArcUI_PT_SUDebug.Export() end)
        else
            ArcUI_PT_SUDebug.Toggle()
        end
        return
    end

    -- /pt sbdebug → toggle Soulburst (Devourer 2pc) debugger
    -- /pt sbdebug export → open window and export
    if arg == "sbdebug" or arg:sub(1,8) == "sbdebug " then
        if not ArcUI_PT_SBDebug then
            print("|cffFF4444ProcTracker:|r SBDebug not loaded")
            return
        end
        local sub = arg:sub(9)
        if sub == "export" then
            if not ArcUI_PT_SBDebug.IsEnabled() then ArcUI_PT_SBDebug.Toggle() end
            C_Timer.After(0.1, function() ArcUI_PT_SBDebug.Export() end)
        else
            ArcUI_PT_SBDebug.Toggle()
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
