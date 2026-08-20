local ADDON, PT = ...   -- private namespace, shared with Core (never the global PT)
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

-- ── ATTRIBUTION TIMELINE ──────────────────────────────────────────────────────
-- The question this exists to answer: when a Tempest buff arrives, did it come
-- from the MSW-spent deck or from the Awakening Storms RPPM off Stormstrike /
-- Windstrike? Nothing on the aura says so -- both talents trigger the SAME
-- buff spell (455129 is a proc-trigger-spell effect whose trigger IS 454015).
-- So the only hope is the surrounding event stream:
--   * the deck rolls inside the MSW spend, i.e. attached to the SPENDER cast
--   * AWS rolls inside the Stormstrike/Windstrike execute, i.e. attached to the STRIKE cast
-- Outside Ascendance/DW those are separated by a GCD and trivially separable.
-- Inside them, Thorim's Invocation makes Windstrike auto-cast the spender, so
-- both land together -- that is the case this timeline is built to crack. We
-- record ARRIVAL ORDER (a monotonic counter bumped per cast) as well as age,
-- because both can share a GetTime() while still arriving in a fixed order.
local STRIKE_IDS = { [17364]=true, [115356]=true }                      -- Stormstrike / Windstrike
local SPENDER_IDS = { [188196]=true, [188443]=true, [452201]=true, [1218090]=true } -- LB / CL / Tempest / Primordial Storm
local ATTRIB_WINDOW = 0.6   -- seconds a cast stays a plausible cause

local castSeq     = 0
local lastStrike  = { id=nil, seq=-1, t=nil }
local lastSpender = { id=nil, seq=-1, t=nil }
local lastAttribT = nil
local attrib      = { strikeOnly=0, spenderOnly=0, bothStrikeLast=0, bothSpenderLast=0, neither=0 }

-- Full SPELL_UPDATE_COOLDOWN payload trail. If AWS routes its grant through a
-- hidden trigger spell, it shows up here and nowhere else -- this is the same
-- instrument that caught the silent Fire Nova proc.
local sucRing, SUC_MAX = {}, 40

local function NoteCast(sid)
    if STRIKE_IDS[sid] then
        castSeq = castSeq + 1
        lastStrike.id, lastStrike.seq, lastStrike.t = sid, castSeq, GetTime()
    elseif SPENDER_IDS[sid] then
        castSeq = castSeq + 1
        lastSpender.id, lastSpender.seq, lastSpender.t = sid, castSeq, GetTime()
    end
end

local function NoteSUC(spellID, baseSpellID, category, startRecovery, itemID)
    sucRing[#sucRing+1] = { t=GetTime(), s=spellID, b=baseSpellID,
                            c=category, r=startRecovery, i=itemID }
    if #sucRing > SUC_MAX then table.remove(sucRing, 1) end
end

local function DumpSUCTrail(window)
    local now, shown = GetTime(), 0
    for i = #sucRing, 1, -1 do
        if now - sucRing[i].t > window then break end
        shown = shown + 1
    end
    if shown == 0 then
        Push("  spell-update trail", "none in the last "..string.format("%.1fs", window), "info")
        return
    end
    for i = #sucRing - shown + 1, #sucRing do
        local e = sucRing[i]
        Push(string.format("  SUC -%.3fs", now - e.t),
            "spellID="..SafeVal(e.s).."  base="..SafeVal(e.b)
            .."  cat="..SafeVal(e.c).."  startRec="..SafeVal(e.r)
            .."  item="..SafeVal(e.i), "info")
    end
end

-- ── MARKER HUNT: which spellIDs separate a DECK proc from an AWS proc? ───────
-- Tempest has TWO sources feeding one buff, and the current attribution rests
-- entirely on cast timing -- which collapses whenever a strike and a spend land
-- in the same window (the AMBIGUOUS buckets). A marker spell would settle it
-- outright, the way 1252413 did for Storm Unleashed: that turned out to be a
-- hidden 3s dummy aura stamped at proc time, invisible to the combat log and
-- only ever visible as a SPELL_UPDATE_COOLDOWN payload.
--
-- So: tally every ID seen around a gain, bucketed by what the gain was
-- attributed to, and diff the buckets. Only the UNAMBIGUOUS buckets train the
-- tally -- the ambiguous ones are the thing we are trying to resolve, so
-- letting them vote would poison the answer.
--
--   deck   IDs seen on "spend in window, no strike" gains
--   aws    IDs seen on "strike in window, no spend"  gains
--   quiet  IDs seen on MSW spends that produced NO gain at all
--
-- A deck marker = present on deck gains, absent from aws AND quiet.
-- THE CASE THIS EXISTS FOR: inside a Doom Winds or Ascendance window, Windstrike
-- / Stormstrike / Crash all spend Maelstrom while ALSO driving Awakening Storms,
-- so a strike and a spend are in the window on essentially every gain and cast
-- timing tells you nothing. Both sources can even succeed in the same frame.
-- Training therefore has to happen OUTSIDE burst, where the two sources can
-- still be told apart, and the resulting marker is then applied INSIDE it.
-- huntAmbig records burst-time gains without training on them, so a candidate
-- can be checked against the very windows it is meant to resolve.
local HUNT_SPAN   = 0.30   -- how far either side of a gain to collect IDs
local huntDeck, huntAws, huntQuiet, huntAmbig = {}, {}, {}, {}
local huntDeckN, huntAwsN, huntQuietN, huntAmbigN = 0, 0, 0, 0

local DW_BUFF_FOR_BURST = 466772

-- IDs that ride along with a Maelstrom SPEND rather than with a proc. They will
-- score perfectly against AWS gains (which need no spend) and mean nothing --
-- annotated rather than hidden, because suppressing a row could hide the real
-- answer if one of these ever turns out to be more than it looks.
local SPEND_ARTIFACT = {
    [410681] = "Overflowing Maelstrom -- granted by ANY MSW spend",
    [344179] = "Maelstrom Weapon itself",
    [454015] = "the Tempest buff -- fires on gain AND loss, no direction",
}

-- "Burst" = a window where spends and strikes are unavoidably interleaved.
local function InBurst()
    if PT.MSW and PT.MSW.IsAscActive and PT.MSW.IsAscActive() then return true, "ASC" end
    local dw = C_UnitAuras.GetPlayerAuraBySpellID
           and C_UnitAuras.GetPlayerAuraBySpellID(DW_BUFF_FOR_BURST)
    if dw then return true, "DW" end
    return false, nil
end

local function HuntCollect(tally, centreT, done)
    -- Wait out the trailing half of the span so the ring holds both sides.
    C_Timer.After(HUNT_SPAN, function()
        if not enabled then return end
        local seen = {}
        for i = 1, #sucRing do
            local e = sucRing[i]
            if math.abs(e.t - centreT) <= HUNT_SPAN then
                if not (issecretvalue and issecretvalue(e.s)) then
                    local id = tonumber(e.s)
                    if id then seen[id] = true end
                end
            end
        end
        for id in pairs(seen) do tally[id] = (tally[id] or 0) + 1 end
        if done then done(seen) end
    end)
end

local function HuntReport()
    Sep("MARKER CANDIDATES")
    Push("gains sampled", string.format(
        "deck=%d  aws=%d  quiet(no gain)=%d  |  ambiguous/burst=%d (not trained on)",
        huntDeckN, huntAwsN, huntQuietN, huntAmbigN), "info")
    if huntDeckN == 0 or huntAwsN == 0 then
        Push("  not enough yet", "need at least one UNAMBIGUOUS gain of EACH kind, "
            .."OUTSIDE a DW/Asc window -- a spend-only gain and a strike-only gain. "
            .."Burst-time gains cannot train this; they are what it has to solve.", "warn")
        return
    end
    local rows = {}
    local all = {}
    for id in pairs(huntDeck) do all[id] = true end
    for id in pairs(huntAws)  do all[id] = true end
    for id in pairs(all) do
        local d = (huntDeck[id]  or 0) / huntDeckN
        local a = (huntAws[id]   or 0) / huntAwsN
        local q = huntQuietN > 0 and ((huntQuiet[id] or 0) / huntQuietN) or 0
        local m = huntAmbigN > 0 and ((huntAmbig[id] or 0) / huntAmbigN) or 0
        rows[#rows+1] = { id = id, d = d, a = a, q = q, m = m, score = d - a }
    end
    table.sort(rows, function(x, y)
        if x.score ~= y.score then return math.abs(x.score) > math.abs(y.score) end
        return x.id < y.id
    end)
    local found = false
    for i = 1, math.min(#rows, 14) do
        local r = rows[i]
        -- Only interesting if it leans one way AND is not just background noise
        -- that fires on every spend regardless.
        local artifact = SPEND_ARTIFACT[r.id]
        local clean = not artifact
                  and ((r.d == 1 and r.a == 0 and r.q == 0)
                    or (r.a == 1 and r.d == 0 and r.q == 0))
        if clean then found = true end
        local nm = C_Spell.GetSpellName and C_Spell.GetSpellName(r.id)
        local lean = r.score > 0 and "DECK" or (r.score < 0 and "AWS" or "--")
        Push(string.format("  %s%d", clean and ">>> " or "    ", r.id),
            string.format("deck %.0f%%  aws %.0f%%  quiet %.0f%%  burst %.0f%%  leans %s  %s%s",
                r.d * 100, r.a * 100, r.q * 100, r.m * 100, lean,
                nm and ('"'..nm..'"') or "(unnamed)",
                clean and "   <<< SEPARATOR"
                    or (artifact and ("   [artifact: "..artifact.."]") or "")),
            clean and "tempest_gain" or (artifact and "warn" or "info"))
    end
    if not found then
        Push("  no clean separator", "no ID is exclusive to one source -- judge by the "
            .."lean percentages, or the two sources may share every signal and "
            .."cast timing stays the only discriminator", "warn")
    end
end

local function AttributeGain(trigger)
    if not enabled then return end
    local now = GetTime()
    -- One gain can surface as several signals in the same frame (SPELL_UPDATE_CD
    -- plus an aura add/update). Attribute once, then just note the extra signal.
    if lastAttribT == now then
        Push("  also signalled by", trigger, "info")
        return
    end
    lastAttribT = now

    local sAge = lastStrike.t  and (now - lastStrike.t)
    local pAge = lastSpender.t and (now - lastSpender.t)
    local sIn  = sAge ~= nil and sAge <= ATTRIB_WINDOW
    local pIn  = pAge ~= nil and pAge <= ATTRIB_WINDOW

    local verdict, bucket, col
    if sIn and not pIn then
        verdict, bucket, col = "AWS  (strike in window, no spend)", "strikeOnly", "FF8844"
    elseif pIn and not sIn then
        verdict, bucket, col = "DECK (spend in window, no strike)", "spenderOnly", "00FF88"
    elseif sIn and pIn then
        -- The hard case. Arrival order is the only thing left that differs.
        if lastStrike.seq > lastSpender.seq then
            verdict, bucket, col = "AMBIGUOUS -> STRIKE arrived last", "bothStrikeLast", "FFFF44"
        else
            verdict, bucket, col = "AMBIGUOUS -> SPENDER arrived last", "bothSpenderLast", "FFFF44"
        end
    else
        verdict, bucket, col = "NEITHER (no cast in window)", "neither", "FF4444"
    end
    attrib[bucket] = attrib[bucket] + 1

    -- Feed the marker hunt from the UNAMBIGUOUS buckets only. A burst-time gain
    -- is never training data even if it happens to look clean: inside DW/Asc the
    -- "no strike in window" reading is an artifact of what we sampled, not a
    -- statement about the source.
    local burst, burstWhy = InBurst()
    if burst then
        huntAmbigN = huntAmbigN + 1
        HuntCollect(huntAmbig, now)
    elseif bucket == "spenderOnly" then
        huntDeckN = huntDeckN + 1
        HuntCollect(huntDeck, now)
    elseif bucket == "strikeOnly" then
        huntAwsN = huntAwsN + 1
        HuntCollect(huntAws, now)
    elseif bucket == "bothStrikeLast" or bucket == "bothSpenderLast" then
        huntAmbigN = huntAmbigN + 1
        HuntCollect(huntAmbig, now)
    end
    if burst then
        verdict = verdict .. "  |cffFF8844[" .. burstWhy .. " BURST -- attribution unreliable]|r"
    end

    Push("TEMPEST GAIN ["..trigger.."]", string.format(
        "%s  |  strike=%s age=%s seq=%d   spender=%s age=%s seq=%d",
        verdict,
        lastStrike.id  and tostring(lastStrike.id)  or "none",
        sAge and string.format("%.3fs", sAge) or "-", lastStrike.seq,
        lastSpender.id and tostring(lastSpender.id) or "none",
        pAge and string.format("%.3fs", pAge) or "-", lastSpender.seq), col)
    DumpSUCTrail(0.6)
end

-- ── Event listener ────────────────────────────────────────────────────────────
local dbgFrame = CreateFrame("Frame")

dbgFrame:SetScript("OnEvent", function(_, event, a1, a2, a3, a4, a5)
    if not enabled then return end

    -- UNIT_SPELLCAST_SUCCEEDED
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        if a1 ~= "player" then return end
        if not a3 or (issecretvalue and issecretvalue(a3)) then return end
        local sid = tonumber(a3)
        if not sid then return end
        NoteCast(sid)
        if sid == TEMPEST_CAST then
            Push("SPELLCAST  Tempest", "spellID="..sid.."  seq="..castSeq, "tempest_cast")
        elseif SPENDER_IDS[sid] then
            Push("SPELLCAST  spender", "spellID="..sid.."  seq="..castSeq.." (MSW spend -> deck rolls)", "info")
        end
        return
    end

    -- SPELL_UPDATE_COOLDOWN
    if event == "SPELL_UPDATE_COOLDOWN" then
        NoteSUC(a1, a2, a3, a4, a5)
        if issecretvalue and issecretvalue(a1) then return end
        local sid = tonumber(a1)
        if sid == TEMPEST_BUFF then
            AttributeGain("SPELL_UPDATE_CD")
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
        -- 12.1: payload vectors are SECRET in restricted content (ipairs throws)
        if issecretvalue and issecretvalue(info.isFullUpdate) then return end

        if info.addedAuras then
            for _, aura in ipairs(info.addedAuras) do
                local sid = not (issecretvalue and issecretvalue(aura.spellId)) and tonumber(aura.spellId) or nil
                if sid == MSW_ID then
                    local apps = not (issecretvalue and issecretvalue(aura.applications)) and tonumber(aura.applications) or "?"
                    Push("UNIT_AURA  MSW GAINED", "instID="..SafeVal(aura.auraInstanceID).." apps="..tostring(apps), "msw_gain")
                elseif sid == TEMPEST_BUFF then
                    Push("UNIT_AURA  Tempest GAINED", "instID="..SafeVal(aura.auraInstanceID), "tempest_gain")
                    AttributeGain("AURA_ADDED")
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
                    -- A 2-stack buff means a second grant shows up HERE as an
                    -- update, not as a new aura instance.
                    Push("UNIT_AURA  Tempest UPDATED", "instID="..SafeVal(instID).." apps="..tostring(apps), "tempest_gain")
                    AttributeGain("AURA_UPDATED")
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

-- Events are registered on Enable() only -- zero idle cost for users who
-- never open the debugger

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

    -- Baseline for the hunt: a spend that produces NO gain. Anything appearing
    -- here fires on ordinary spends and therefore cannot be a proc marker, no
    -- matter how well it correlates with deck gains.
    local centre = GetTime()
    C_Timer.After(0.05, function()
        if not enabled then return end
        -- lastAttribT is stamped by AttributeGain, so if it moved into this
        -- window a gain happened and this was not a quiet spend.
        if lastAttribT and math.abs(lastAttribT - centre) <= 0.05 then return end
        huntQuietN = huntQuietN + 1
        HuntCollect(huntQuiet, centre)
    end)
end

-- ── UI ────────────────────────────────────────────────────────────────────────
local DoExport  -- forward declaration

local function BuildUI()
    if mainFrame then mainFrame:Show(); return end

    -- 780 not 680: the button row is full at seven 88px buttons and Candidates
    -- makes eight. The scroll frame anchors to the frame edges and the editbox
    -- derives from W, so both follow.
    local W, H = 780, 560
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

    Btn("Candidates", 668, function()
        HuntReport()
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

    Btn("Attrib", 574, function()
        Sep("ATTRIBUTION TALLY")
        local clean = attrib.strikeOnly + attrib.spenderOnly
        local amb   = attrib.bothStrikeLast + attrib.bothSpenderLast
        Push("AWS  (strike only)",    tostring(attrib.strikeOnly),  "FF8844")
        Push("DECK (spend only)",     tostring(attrib.spenderOnly), "00FF88")
        Push("ambiguous, strike last", tostring(attrib.bothStrikeLast),  "FFFF44")
        Push("ambiguous, spend last",  tostring(attrib.bothSpenderLast), "FFFF44")
        Push("neither in window",      tostring(attrib.neither),     "FF4444")
        Push("SPLIT", string.format("clean=%d  ambiguous=%d  (%.0f%% resolvable by window alone)",
            clean, amb, (clean + amb) > 0 and (clean / (clean + amb) * 100) or 0), "info")
        Push("READ THIS AS", "if the two CLEAN buckets show a consistent difference in their "
            .."spell-update trails, that difference is the discriminator for the ambiguous ones", "info")
    end)

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
-- (registered on Enable() only)
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
        -- 12.1: payload vectors are SECRET in restricted content (ipairs throws)
        if issecretvalue and issecretvalue(info.isFullUpdate) then return end
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
    -- Carrying tallies across toggles would mix samples from different talent
    -- setups or fights into one diff.
    wipe(huntDeck); wipe(huntAws); wipe(huntQuiet); wipe(huntAmbig)
    huntDeckN, huntAwsN, huntQuietN, huntAmbigN = 0, 0, 0, 0
    dbgFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    dbgFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
    dbgFrame:RegisterEvent("COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED")
    dbgFrame:RegisterUnitEvent("UNIT_AURA", "player")
    ssRtlFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    ssRtlFrame:RegisterEvent("UNIT_AURA")
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