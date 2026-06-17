-- ArcUI_PT_ElemTempestDeck.lua
-- Tempest (Elemental) Maelstrom deck tracking.
-- DETECTION RULE (mirrors Enhancement RULE1):
--   Resource spend (ES/EQ/EB) opens a 5ms window.
--   If SPELL_UPDATE_CD 454015 fires within that window = Tempest proc.
--   ASC (114050) also spends Maelstrom but generates a free Tempest — ignore it.
--   Awakening Storms RPPM procs detected identically (no distinction needed).
-- No pcall. Zero polling.

local issecretvalue = issecretvalue

local function EDbg(tag, detail)
    if PT.ElemTempest and PT.ElemTempest.OnDebug then
        PT.ElemTempest.OnDebug(tag, detail)
    end
end

local TEMPEST_BUFF    = 454015
local TEMPEST_CAST    = 452201
local CDM_COOLDOWN_ID = 80173   -- Elemental Tempest CDM frame ID
local DECK_SIZE       = 333     -- Maelstrom per deck
local DECK_PROCS      = 2

local MAELSTROM_SPENDERS = {
    [8042]   = "Earth Shock",
    [462620] = "Earthquake",
    [61882]  = "Earthquake",
    [117014] = "Elemental Blast",
}
local ASC_SPELL_ID = 114050

local TEMPEST_NODE_ID  = 94892
local TEMPEST_ENTRY_ID = 117489

local elemTotalMaelstrom    = 0
local elemDeckNumber        = 1
local elemDeckProcs         = 0
local elemPrevDeckProcs     = 0
local elemPrevPrevDeckProcs = 0
local elemGainCount         = 0
local elemViolations        = 0
local elemEnabled           = false

local cdm  = { frame=nil, instID=nil }
local snap = { deckNumber=1, prevProcs=0, totalStacks=0, procCredited=false }

local function AdvanceDeck(cost)
    local before  = elemTotalMaelstrom
    elemTotalMaelstrom = elemTotalMaelstrom + cost
    local dBefore = math.floor(before / DECK_SIZE)
    local dAfter  = math.floor(elemTotalMaelstrom / DECK_SIZE)
    if dAfter > dBefore then
        local ppViolation = elemPrevPrevDeckProcs ~= 0 and elemPrevPrevDeckProcs ~= DECK_PROCS
        if ppViolation then
            elemViolations = elemViolations + 1
            EDbg("DECK VIOLATION", "deck#"..(elemDeckNumber-1)
                .." prevPrevProcs="..elemPrevPrevDeckProcs.."/"..DECK_PROCS
                .." VIOLATION#"..elemViolations)
            if PT.ElemTempest and PT.ElemTempest.OnDeckRollover then
                PT.ElemTempest.OnDeckRollover(elemDeckNumber-1, elemPrevPrevDeckProcs, true)
            end
        end
        elemPrevPrevDeckProcs = elemPrevDeckProcs
        elemPrevDeckProcs     = elemDeckProcs
        elemDeckProcs         = 0
        elemDeckNumber        = dAfter + 1
        EDbg("DECK ROLLOVER", "deck#"..elemDeckNumber
            .." prevProcs="..elemPrevDeckProcs.."/"..DECK_PROCS
            ..(not ppViolation and " clean" or ""))
        if not ppViolation and PT.ElemTempest and PT.ElemTempest.OnDeckRollover then
            PT.ElemTempest.OnDeckRollover(elemDeckNumber, elemPrevDeckProcs, false)
        end
    end
end

local function CreditProc(source, snapDeck)
    elemGainCount = elemGainCount + 1
    local creditedDeck, creditedProcs
    if snapDeck == elemDeckNumber then
        elemDeckProcs = elemDeckProcs + 1
        creditedDeck  = elemDeckNumber
        creditedProcs = elemDeckProcs
    elseif elemPrevDeckProcs < DECK_PROCS then
        elemPrevDeckProcs = elemPrevDeckProcs + 1
        creditedDeck  = elemDeckNumber - 1
        creditedProcs = elemPrevDeckProcs
        if elemPrevDeckProcs == DECK_PROCS and elemViolations > 0 then
            elemViolations = elemViolations - 1
        end
    else
        elemDeckProcs = elemDeckProcs + 1
        creditedDeck  = elemDeckNumber
        creditedProcs = elemDeckProcs
    end
    snap.procCredited = true
    EDbg("PROC CREDITED", source.." gain#"..elemGainCount
        .." creditedDeck#"..creditedDeck
        .." procs="..creditedProcs.."/"..DECK_PROCS
        ..(snapDeck ~= elemDeckNumber and " [rollover->prev]" or ""))
    if PT.ElemTempest and PT.ElemTempest.OnProcGained then
        PT.ElemTempest.OnProcGained(elemGainCount, elemDeckNumber, elemDeckProcs)
    end
    PT.UpdateDeck("elemtempest")
end

local function RehookCDMFrame()
    if cdm.frame then return end
    local cv = _G.CooldownViewer
    if not cv then return end
    local viewers = {
        cv.EssentialCooldownViewer, cv.UtilityCooldownViewer,
        cv.BuffIconCooldownViewer,  cv.BuffBarCooldownViewer,
    }
    for _, viewer in ipairs(viewers) do
        if viewer and viewer.cooldowns then
            for _, item in ipairs(viewer.cooldowns) do
                if item.cooldownID == CDM_COOLDOWN_ID then
                    cdm.frame = item
                    EDbg("ELEM_CDM["..CDM_COOLDOWN_ID.."] HOOKED", "cooldownID="..CDM_COOLDOWN_ID)
                    hooksecurefunc(item, "OnAuraInstanceInfoSet", function(self, instID)
                        if not issecretvalue(instID) then
                            cdm.instID = instID
                            EDbg("ELEM_CDM["..CDM_COOLDOWN_ID.."].OnAuraInstanceInfoSet",
                                "instID="..tostring(instID))
                        end
                    end)
                    hooksecurefunc(item, "OnAuraInstanceInfoCleared", function(self, prev)
                        EDbg("ELEM_CDM["..CDM_COOLDOWN_ID.."].OnAuraInstanceInfoCleared",
                            "prev="..tostring(prev))
                    end)
                    return
                end
            end
        end
    end
end

local function GetMaelstromCost(spellID)
    local costs = C_Spell.GetSpellPowerCost(spellID)
    if not costs then return 0 end
    for _, c in ipairs(costs) do
        if c.type == 11 then return c.cost or 0 end
    end
    return 0
end

local function OnMaelstromSpent(spellID, cost, isASC)
    if not elemEnabled then return end
    snap.deckNumber   = elemDeckNumber
    snap.prevProcs    = elemPrevDeckProcs
    snap.totalStacks  = elemTotalMaelstrom
    snap.procCredited = false

    local instIDAtSpend  = cdm.instID
    local snapDeckAtSpend = elemDeckNumber

    if not isASC then
        AdvanceDeck(cost)
        snap.totalStacks = elemTotalMaelstrom
        snap.deckNumber  = elemDeckNumber
    end

    EDbg("MAELSTROM SPEND", "spellID="..spellID
        .." cost="..cost
        ..(isASC and " [ASC]" or "")
        .." instIDAtSpend="..tostring(instIDAtSpend)
        .." snapDeck="..tostring(snapDeckAtSpend)
        .." deckNow="..tostring(elemDeckNumber)
        .." deckPos="..(elemTotalMaelstrom % DECK_SIZE))

    if isASC then return end

    local spellCDFiredAt = nil
    local spellCDFrame   = CreateFrame("Frame")
    spellCDFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
    local spendTime = GetTime()

    spellCDFrame:SetScript("OnEvent", function(self, _, sid)
        if issecretvalue and issecretvalue(sid) then return end
        if tonumber(sid) == TEMPEST_BUFF then
            local age = (GetTime() - spendTime) * 1000
            local instIDNow = cdm.instID
            if spellCDFiredAt then
                EDbg("SPELL_UPDATE_CD 454015 IGNORED (already seen)",
                    string.format("age=%.1fms instID=%s", age, tostring(instIDNow)))
            elseif age > 5 then
                EDbg("SPELL_UPDATE_CD 454015 IGNORED (too late)",
                    string.format("age=%.1fms > 5ms instID=%s", age, tostring(instIDNow)))
            else
                spellCDFiredAt = GetTime()
                EDbg("SPELL_UPDATE_CD 454015 COUNTED",
                    string.format("age=%.1fms instID=%s atSpend=%s",
                        age, tostring(instIDNow), tostring(instIDAtSpend)))
            end
        end
    end)

    C_Timer.After(0.005, function()
        spellCDFrame:UnregisterAllEvents()
        spellCDFrame:SetScript("OnEvent", nil)
        if not elemEnabled then return end
        local instIDNow = cdm.instID
        EDbg("RULE1 check", "atSpend="..tostring(instIDAtSpend)
            .." now="..tostring(instIDNow)
            .." spellCD="..(spellCDFiredAt and "YES" or "NO")
            .." snapDeck="..tostring(snapDeckAtSpend)
            .." deckNow="..tostring(elemDeckNumber))
        if spellCDFiredAt then
            EDbg("RULE1 FIRE (SPELL_UPDATE_CD 454015)", "instID="..tostring(instIDNow))
            CreditProc("RULE1", snapDeckAtSpend)
        else
            EDbg("RULE1 NO PROC", "no SPELL_UPDATE_CD 454015")
            PT.UpdateDeck("elemtempest")
        end
    end)
end

local elemEventFrame = CreateFrame("Frame")
elemEventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
elemEventFrame:SetScript("OnEvent", function(self, event, unit, _, spellID)
    if unit ~= "player" then return end
    if spellID == ASC_SPELL_ID then
        local cost = GetMaelstromCost(spellID)
        EDbg("SPELLCAST ASC", "spellID="..spellID.." cost="..cost)
        OnMaelstromSpent(spellID, cost, true)
        return
    end
    if MAELSTROM_SPENDERS[spellID] then
        local cost = GetMaelstromCost(spellID)
        EDbg("SPELLCAST", "spellID="..spellID
            .." ("..MAELSTROM_SPENDERS[spellID]..")"
            .." cost="..cost)
        OnMaelstromSpent(spellID, cost, false)
    end
end)

local function Reset()
    elemTotalMaelstrom    = 0
    elemDeckNumber        = 1
    elemDeckProcs         = 0
    elemPrevDeckProcs     = 0
    elemPrevPrevDeckProcs = 0
    elemGainCount         = 0
    elemViolations        = 0
    snap.deckNumber       = 1
    snap.prevProcs        = 0
    snap.totalStacks      = 0
    snap.procCredited     = false
    cdm.instID            = nil
    EDbg("RESET", "Elemental deck reset")
    PT.UpdateDeck("elemtempest")
end

local function GetStats()
    return {
        deckNumber  = elemDeckNumber,
        deckProcs   = elemDeckProcs,
        prevProcs   = elemPrevDeckProcs,
        totalStacks = elemTotalMaelstrom,
        gainCount   = elemGainCount,
        violations  = elemViolations,
    }
end

local function GetDeckPos() return elemTotalMaelstrom % DECK_SIZE end
local function GetProcs()   return elemDeckProcs end

local function IsTempestTalented()
    local specIndex = GetSpecialization()
    local specID    = specIndex and select(1, GetSpecializationInfo(specIndex)) or nil
    if specID ~= 262 then return false end
    local configID = C_ClassTalents.GetActiveConfigID()
    if not configID then return false end
    local ni = C_Traits.GetNodeInfo(configID, TEMPEST_NODE_ID)
    if not ni or (ni.activeRank or 0) == 0 then return false end
    -- Hero tree node: must also be in the player's active subtree
    if ni.subTreeID then return ni.subTreeActive == true end
    return true
end

PT.ElemTempest = {
    OnDeckRollover = nil,
    OnProcGained   = nil,
    OnDebug        = nil,
    IsCDMTracking  = function() return cdm.frame ~= nil end,
    RehookCDM      = RehookCDMFrame,
    GetCDMInstID   = function() return cdm.instID end,
    GetStats       = GetStats,
    Reset          = Reset,
}

local function ApplyTalentVisibility()
    local entry = PT and PT.GetDeck and PT.GetDeck("elemtempest")
    if not entry then return end
    local talented = IsTempestTalented()
    if entry.widget then
        if talented then PT.ShowDeckIconIfEnabled("elemtempest") else entry.widget:Hide() end
    end
    if PT.ApplyBarTalentVisibility then PT.ApplyBarTalentVisibility("elemtempest", talented) end
    if not talented then
        elemEnabled = false
    else
        elemEnabled = true
    end
end

local function TryRegister()
    if not IsTempestTalented() then return end
    if PT.GetDeck and PT.GetDeck("elemtempest") then return end
    elemEnabled = true
    RehookCDMFrame()
    PT.RegisterDeck({
        id          = "elemtempest",
        name        = "Tempest (Elemental)",
        deckSize    = DECK_SIZE,
        procs       = DECK_PROCS,
        defaultIcon = TEMPEST_CAST,
        noCDMWarn   = true,
        GetDeckPos  = GetDeckPos,
        GetProcs    = GetProcs,
        OnReset     = Reset,
        OnEnable    = function()
            elemEnabled = true
            PT.UpdateDeck("elemtempest")
        end,
    })
    EDbg("REGISTERED", "Elemental Tempest deck — CDM ID="..CDM_COOLDOWN_ID)
end

local elemTalentFrame = CreateFrame("Frame")
elemTalentFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
elemTalentFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
elemTalentFrame:RegisterEvent("ACTIVE_COMBAT_CONFIG_CHANGED")
elemTalentFrame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
elemTalentFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
elemTalentFrame:SetScript("OnEvent", function()
    TryRegister()
    ApplyTalentVisibility()
end)

PT.OnEnterWorld = PT.OnEnterWorld or {}
PT.OnEnterWorld[#PT.OnEnterWorld+1] = function()
    TryRegister()
    ApplyTalentVisibility()
end

TryRegister()
C_Timer.After(0.2, ApplyTalentVisibility)
C_Timer.After(1.0, ApplyTalentVisibility)