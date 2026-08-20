local ADDON, PT = ...   -- private namespace, shared with Core (never the global PT)
-- ArcUI_PT_ResetLab.lua
-- /pt resetlab -- combat-entry probe for the in-game deck RESET question.
--
-- THE QUESTION: Blizzard's decks appear to reset when you enter combat in an
-- instanced/raid context (the target dummy dome counts as one). If that is real,
-- ProcTracker's own deck position must reset with it or every count drifts.
--
-- WHAT THIS CANNOT DO: measure whether the SERVER reset its deck. Blizzard's
-- deck state is invisible to addons, and our own deck position only ever moves
-- when WE move it -- sampling it to detect a server reset is circular and was a
-- design mistake in the first version of this file. Deleted.
--
-- WHAT IT DOES: record WHICH boundary events fire in WHICH context, so a reset
-- trigger can be chosen per situation. Run it in each place a reset is believed
-- to happen (dummy dome, real raid pull, M+ gate drop, open world) and compare.
--
-- ALREADY WIRED IN CORE (see resetEventFrame near ResetAllDecks):
--   ENCOUNTER_START        resets when difficulty is 14-17 or 233 (current raids)
--   CHALLENGE_MODE_RESET   arms the M+ gate window
--   WORLD_STATE_TIMER_START  the yellow-gate drop, with skip protection
-- Each candidate event below reports whether Core's filter WOULD have fired, so
-- a context that resets in game but not in the addon is visible immediately.
--
-- Deliberately NOT using RegisterAllEvents: it would pull in
-- COMBAT_LOG_EVENT_UNFILTERED, which is protected in 12.x and throws
-- ADDON_ACTION_FORBIDDEN. The list below is curated instead. For genuinely
-- blanket coverage Blizzard's own /eventtrace already does the unsafe thing
-- safely, from inside their code -- use it as a cross-check, not a replacement.
--
-- No pcall. Zero idle cost: every event is registered only while armed.

local BEFORE_WINDOW = 5.0    -- seconds of history kept before combat entry
local AFTER_WINDOW  = 12.0   -- seconds of trawling after it

-- Buff IDs whose cooldown updates we already know are deck-relevant, so they
-- can be called out in the trawl instead of buried in the noise.
local NOTABLE = {
    [466772]  = "Doom Winds buff",
    [1262830] = "Storm Unleashed buff",
    [1252413] = "SU gain marker",
    [114051]  = "Ascendance (DRE grant)",
    [454015]  = "Tempest candidate",
    [454025]  = "Tempest candidate",
}

-- Events worth trawling. Grouped by why they are here.
local TRAWL = {
    -- combat / encounter boundaries
    "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
    "ENCOUNTER_START", "ENCOUNTER_END",
    "START_TIMER", "PLAYER_DEAD", "PLAYER_ALIVE",
    -- instance / zone context (the dome is an instanced area)
    "PLAYER_ENTERING_WORLD", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS",
    "ZONE_CHANGED_NEW_AREA", "UPDATE_INSTANCE_INFO",
    "PLAYER_DIFFICULTY_CHANGED", "INSTANCE_GROUP_SIZE_CHANGED",
    "CHALLENGE_MODE_START", "CHALLENGE_MODE_RESET", "CHALLENGE_MODE_COMPLETED",
    -- the most likely carriers of a server-side deck reset
    "SPELL_UPDATE_COOLDOWN", "SPELL_UPDATE_CHARGES", "SPELL_UPDATE_USABLE",
    "SPELL_UPDATE_ICON", "SPELLS_CHANGED",
    "ACTIONBAR_UPDATE_COOLDOWN", "ACTIONBAR_UPDATE_USABLE",
    "UNIT_AURA", "UNIT_SPELLCAST_SUCCEEDED",
    -- spec / talent, which also reset decks
    "PLAYER_SPECIALIZATION_CHANGED", "TRAIT_CONFIG_UPDATED",
    "ACTIVE_TALENT_GROUP_CHANGED", "PLAYER_TALENT_UPDATE",
}

local enabled   = false
local combatT   = nil
local history   = {}   -- rolling BEFORE buffer: { t, ev, info }
local rows      = {}   -- everything shown in the window

-- ── Window ────────────────────────────────────────────────────────────────────
local frame, scroll, edit

local function Push(label, info, tag)
    local t = combatT and (GetTime() - combatT) or 0
    local sign = t >= 0 and "+" or "-"
    local color = (tag == "hit" and "|cff44FF44")
        or (tag == "combat" and "|cffFFD000")
        or (tag == "notable" and "|cff66CCFF")
        or (tag == "bad" and "|cffFF4444")
        or "|cffAAAAAA"
    rows[#rows+1] = string.format("[%s%06.3f] %s%-34s|r %s",
        sign, math.abs(t), color, label, info or "")
    if edit then
        edit:SetText(table.concat(rows, "\n"))
        edit:GetParent():UpdateScrollChildRect()
    end
end

local function BuildWindow()
    if frame then return end
    frame = CreateFrame("Frame", "ArcUIPTResetLab", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(860, 520)
    frame:SetPoint("CENTER")
    frame:SetMovable(true); frame:EnableMouse(true); frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetFrameStrata("DIALOG")

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.title:SetPoint("TOP", 0, -5)
    frame.title:SetText("ProcTracker -- Deck Reset Lab")

    local sub = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sub:SetPoint("TOPLEFT", 14, -28)
    sub:SetText("|cff888888Run in each context (dome / raid / M+ gate / open world). Watch "
        .."ENCOUNTER_START and whether Core WOULD reset.  |  /pt resetlab to close|r")

    scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -46)
    scroll:SetPoint("BOTTOMRIGHT", -32, 40)

    edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetFontObject("ChatFontNormal")
    edit:SetWidth(800)
    edit:SetAutoFocus(false)
    edit:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
    scroll:SetScrollChild(edit)

    local sel = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    sel:SetSize(110, 22); sel:SetPoint("BOTTOMLEFT", 14, 12)
    sel:SetText("Select All")
    sel:SetScript("OnClick", function()
        edit:SetFocus(); edit:HighlightText()
    end)

    local clr = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    clr:SetSize(90, 22); clr:SetPoint("LEFT", sel, "RIGHT", 8, 0)
    clr:SetText("Clear")
    clr:SetScript("OnClick", function()
        wipe(rows); edit:SetText("")
    end)
end

-- ── Context reporting ─────────────────────────────────────────────────────────
-- The whole point: which context are we in, and would Core's existing filter
-- have reset here?
local function Context()
    local inInst, instType = IsInInstance()
    local name, _, diff, diffName, _, _, _, instID = GetInstanceInfo()
    return string.format("inInstance=%s type=%s diff=%s(%s) instID=%s zone=%s",
        tostring(inInst), tostring(instType), tostring(diff),
        tostring(diffName), tostring(instID), tostring(name))
end

-- Mirrors the ENCOUNTER_START gate in Core so a mismatch is obvious.
local function CoreWouldResetOnEncounter()
    local inInst, instType = IsInInstance()
    if inInst and instType == "raid" then
        return true, "instance type is raid"
    end
    return false, "instance type is "..tostring(instType)
        .." -- only type=raid resets on ENCOUNTER_START (M+ resets on the gate drop)"
end

-- ── Event handling ────────────────────────────────────────────────────────────
local watcher = CreateFrame("Frame")

local function Describe(ev, a1, a2, a3)
    if ev == "SPELL_UPDATE_COOLDOWN" or ev == "SPELL_UPDATE_CHARGES" then
        if issecretvalue and issecretvalue(a1) then return "spellID=<secret>" end
        local id = tonumber(a1)
        if id and NOTABLE[id] then
            return "spellID="..id.."  <<< "..NOTABLE[id]
        end
        return id and ("spellID="..id) or "spellID=nil"
    end
    if ev == "UNIT_SPELLCAST_SUCCEEDED" then
        if a1 ~= "player" then return nil end
        if issecretvalue and issecretvalue(a3) then return "spellID=<secret>" end
        return "spellID="..tostring(a3)
    end
    if ev == "UNIT_AURA" then
        if a1 ~= "player" then return nil end
        return "unit=player"
    end
    if ev == "ENCOUNTER_START" then
        local would, why = CoreWouldResetOnEncounter()
        return "encounterID="..tostring(a1).."  name="..tostring(a2)
            .."\n        "..(would and "|cff44FF44Core WOULD reset|r" or "|cffFF8844Core will NOT reset|r")
            .."  ("..why..")\n        "..Context()
    end
    if ev == "ENCOUNTER_END" then
        return "encounterID="..tostring(a1).."  name="..tostring(a2)
    end
    if ev == "CHALLENGE_MODE_RESET" then
        return "|cff44FF44arms the M+ gate window|r  "..Context()
    end
    if ev == "WORLD_STATE_TIMER_START" then
        return "timerID="..tostring(a1).."  (gate drop candidate)  "..Context()
    end
    if ev == "PLAYER_ENTERING_WORLD" or ev == "ZONE_CHANGED_NEW_AREA" then
        return Context()
    end
    return ""
end

local function Record(ev, info)
    local now = GetTime()
    if not combatT then
        history[#history+1] = { t = now, ev = ev, info = info }
        -- trim to the BEFORE window
        while history[1] and (now - history[1].t) > BEFORE_WINDOW do
            table.remove(history, 1)
        end
        return
    end
    local notable = info and info:find("<<<") ~= nil
    Push(ev, info, notable and "notable" or nil)
end

watcher:SetScript("OnEvent", function(_, ev, a1, a2, a3)
    if not enabled then return end

    if ev == "PLAYER_REGEN_DISABLED" then
        combatT = GetTime()
        Push("==== COMBAT ENTERED ====", Context(), "combat")
        -- flush the BEFORE buffer
        for _, h in ipairs(history) do
            local t = h.t - combatT
            rows[#rows+1] = string.format("[-%06.3f] |cff777777%-34s|r %s",
                math.abs(t), "BEFORE "..h.ev, h.info or "")
        end
        wipe(history)
        C_Timer.After(AFTER_WINDOW, function()
            if not enabled then return end
            Push("==== TRAWL WINDOW CLOSED ====",
                "compare the events above against another context (raid pull, M+ gate, "
                .."open world) -- the difference is the trigger", "combat")
            combatT = nil
        end)
        return
    end

    if ev == "PLAYER_REGEN_ENABLED" then
        if combatT then Push("COMBAT ENDED", "", "combat") end
        return
    end

    local info = Describe(ev, a1, a2, a3)
    if info == nil then return end   -- filtered (other unit)
    Record(ev, info)
end)

local function SetEnabled(on)
    enabled = on
    if on then
        BuildWindow()
        frame:Show()
        wipe(rows); wipe(history); combatT = nil
        for _, ev in ipairs(TRAWL) do watcher:RegisterEvent(ev) end
        Push("==== RESET LAB ARMED ====",
            "enter combat in the dome. BEFORE window="..BEFORE_WINDOW
            .."s  AFTER="..AFTER_WINDOW.."s", "combat")
        Push("how to read",
            "Watch ENCOUNTER_START / CHALLENGE_MODE_RESET / WORLD_STATE_TIMER_START "
            .."and whether Core WOULD reset in this context. Deck position is NOT "
            .."evidence -- it only moves when the addon moves it.", "info")
        Push("context now", Context(), "info")
    else
        watcher:UnregisterAllEvents()
        if frame then frame:Hide() end
    end
end

PT.ResetLab = { Toggle = function() SetEnabled(not enabled) end }
