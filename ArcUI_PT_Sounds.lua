-- ArcUI_PT_Sounds  --  a sound when a proc comes off the deck.
--
-- The deck metaphor is already the whole mental model here (deck size, deck
-- procs, rollover), so the sound wants to be a CARD DRAW: the paper snap of
-- pulling one, or the fanfare of what you flipped over.
--
-- WHY WOW'S OWN SOUNDKIT AND NOT SHIPPED AUDIO FILES:
--   * zero bytes added to the addon, and it works for everyone with no download
--   * legal. Anime / TCG rips are copyrighted, and an addon shipping them is a
--     DMCA and moderation risk for the whole project.
-- Anything beyond this list is the USER'S to add: every LibSharedMedia sound is
-- offered alongside these, so dropping your own file into any media addon (or
-- ArcUI's own Sounds folder) makes it selectable here without ArcUI shipping it.

local ADDON, PT = ...
PT.Sounds = PT.Sounds or {}
local S = PT.Sounds

-- Curated from Blizzard_SharedXML/Mainline/SoundKitConstants.lua (881 entries).
-- Grouped by the beat they hit: the REVEAL (payoff fanfare) and the ALERT
-- (short and cutting, for when you just need to know).
--
-- The DRAW group (paper flips, book opens, talent clicks) was cut: the deck
-- metaphor read well on paper but the actual clips are too soft and dry to
-- register as "you just got a proc" mid-pull.
S.KITS = {
    { label = "Reveal: Legendary",     kit = 63971 },
    { label = "Reveal: Epic Loot",     kit = 31578 },
    { label = "Reveal: Azerite",       kit = 118238 },
    { label = "Reveal: Corrupted",     kit = 147833 },
    { label = "Reveal: Warforged",     kit = 51561 },
    { label = "Reveal: Bonus Roll",    kit = 31581 },
    { label = "Reveal: Dig Site",      kit = 38326 },

    { label = "Alert: Raid Warning",   kit = 8959 },
    { label = "Alert: Ready Check",    kit = 8960 },
    { label = "Alert: Power Aura",     kit = 23287 },
    { label = "Alert: Orb Impact",     kit = 97597 },
    { label = "Alert: Invasion",       kit = 44292 },
}

local byLabel = {}
for i = 1, #S.KITS do byLabel[S.KITS[i].label] = S.KITS[i].kit end

local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)

-- Sounds shipped WITH ProcTracker, registered into LibSharedMedia so they show
-- up in every picker (ours, ArcUI's, anyone's). ProcTracker ships its own copy
-- rather than leaning on ArcUI: it has to work when ArcUI is not installed.
-- LSM dedups by NAME, so when ArcUI is present and registers the same label
-- there is still only one entry in the list.
-- These lead the picker (see S.OWN below): they are the ones worth reaching for,
-- so they should not be buried in the alphabetical tail with everyone else's media.
S.OWN = {
    "ArcUI: Ultra Instinct",
    "ArcUI: Ultra Instinct Theme",
    "ArcUI: Kaching",
}

if LSM then
    local MEDIA = [[Interface\AddOns\ArcUI_ProcTracker\Sounds\]]
    LSM:Register("sound", "ArcUI: Ultra Instinct", MEDIA .. "UltraInstinct.mp3")
    LSM:Register("sound", "ArcUI: Ultra Instinct Theme", MEDIA .. "UltraInstinctTheme.mp3")
    LSM:Register("sound", "ArcUI: Kaching", MEDIA .. "Kaching.ogg")
end

-- Play by NAME. Our own labels win, then anything LibSharedMedia knows about --
-- which is how a user's own file (ArcUI's sound pack, SharedMedia packs, or a
-- one-file media addon of their own) becomes selectable without us shipping it.
-- WoW's own output channels. "Master" ignores the SFX slider, which is what an
-- alert wants by default; the rest let a sound ride a slider the player already
-- tuned (put callouts on Dialog, keep them audible when SFX is turned down).
S.CHANNELS = { "Master", "SFX", "Music", "Ambience", "Dialog" }

function S.ChannelValues()
    return {
        Master   = "Master (ignores other sliders)",
        SFX      = "Sound Effects",
        Music    = "Music",
        Ambience = "Ambience",
        Dialog   = "Dialog",
    }
end

function S.ChannelSorting() return S.CHANNELS end

local function validChannel(c)
    for i = 1, #S.CHANNELS do if S.CHANNELS[i] == c then return c end end
    return "Master"
end

function S.Play(name, channel)
    if not name or name == "" or name == "None" then return end
    local ch = validChannel(channel)
    local kit = byLabel[name]
    if kit then
        PlaySound(kit, ch)
        return true
    end
    if LSM then
        local path = LSM:Fetch("sound", name, true)
        if path then PlaySoundFile(path, ch); return true end
    end
    return false
end

-- AceConfig select values: None, our kit labels, then every LSM sound.
function S.Values()
    local t = { None = "None" }
    for i = 1, #S.KITS do t[S.KITS[i].label] = S.KITS[i].label end
    if LSM then
        for _, n in ipairs(LSM:List("sound")) do t[n] = n end
    end
    return t
end

-- Sorted so the picker reads Draw -> Reveal -> Alert -> everything else,
-- instead of AceConfig's default alphabetical scramble.
function S.Sorting()
    local out, placed = { "None" }, { None = true }
    -- our own shipped sounds first, then the game's kits, then everyone else's
    -- media alphabetically -- alphabetical alone buried these in the B's
    local have = {}
    if LSM then
        for _, n in ipairs(LSM:List("sound")) do have[n] = true end
    end
    for i = 1, #S.OWN do
        local n = S.OWN[i]
        if have[n] and not placed[n] then out[#out + 1] = n; placed[n] = true end
    end
    for i = 1, #S.KITS do
        local n = S.KITS[i].label
        if not placed[n] then out[#out + 1] = n; placed[n] = true end
    end
    if LSM then
        local extra = {}
        for _, n in ipairs(LSM:List("sound")) do
            if not byLabel[n] and not placed[n] then extra[#extra + 1] = n end
        end
        table.sort(extra)
        for i = 1, #extra do out[#out + 1] = extra[i] end
    end
    return out
end

-- Play whatever this deck is set to. One call at each deck's proc site.
function S.PlayFor(deckID)
    if not (deckID and PT.GetIconDB) then return end
    local db = PT.GetIconDB(deckID)
    -- the enable switch is the mute: it keeps your chosen sound so you can flip
    -- it back on mid-session without re-picking
    if db and db.procSoundEnabled then S.Play(db.procSound, db.procSoundChannel) end
end

-- ── audition window: hear them all, then pick ───────────────────────────────
local win
local function Build()
    if win then return win end
    win = CreateFrame("Frame", "ArcUIPTSoundLab", UIParent, "BackdropTemplate")
    win:SetSize(560, 420)
    win:SetPoint("CENTER")
    win:SetFrameStrata("DIALOG")
    win:SetMovable(true); win:EnableMouse(true); win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving)
    win:SetScript("OnDragStop", win.StopMovingOrSizing)
    win:SetBackdrop({ bgFile = [[Interface\Buttons\WHITE8X8]],
                      edgeFile = [[Interface\Buttons\WHITE8X8]], edgeSize = 1 })
    win:SetBackdropColor(0.043, 0.059, 0.102, 1)
    win:SetBackdropBorderColor(0.247, 0.788, 0.949, 1)
    tinsert(UISpecialFrames, "ArcUIPTSoundLab")

    local t = win:CreateFontString(nil, "OVERLAY")
    t:SetFont(STANDARD_TEXT_FONT, 14, "")
    t:SetPoint("TOPLEFT", 12, -10)
    t:SetText("|cff3fc9f2Proc|r|cffd5e2f2 Sounds|r   -- click one to hear it")

    local hint = win:CreateFontString(nil, "OVERLAY")
    hint:SetFont(STANDARD_TEXT_FONT, 10, "")
    hint:SetPoint("TOPLEFT", 12, -30)
    hint:SetTextColor(0.62, 0.70, 0.80)
    hint:SetText("Your own sounds appear in the deck's picker too -- any LibSharedMedia sound is offered.")

    -- audition list = our shipped sounds first, then the game's kits, so this
    -- window matches the order the deck picker actually shows
    local audition = {}
    local haveLSM = {}
    if LSM then
        for _, n in ipairs(LSM:List("sound")) do haveLSM[n] = true end
    end
    for i = 1, #S.OWN do
        if haveLSM[S.OWN[i]] then audition[#audition + 1] = { label = S.OWN[i] } end
    end
    for i = 1, #S.KITS do audition[#audition + 1] = S.KITS[i] end

    local col, row = 0, 0
    for i = 1, #audition do
        local e = audition[i]
        local b = CreateFrame("Button", nil, win, "BackdropTemplate")
        b:SetSize(168, 22)
        b:SetPoint("TOPLEFT", 12 + col * 178, -50 - row * 26)
        b:SetBackdrop({ bgFile = [[Interface\Buttons\WHITE8X8]],
                        edgeFile = [[Interface\Buttons\WHITE8X8]], edgeSize = 1 })
        b:SetBackdropColor(0.063, 0.094, 0.153, 1)
        b:SetBackdropBorderColor(0.078, 0.353, 0.451, 1)
        local fs = b:CreateFontString(nil, "OVERLAY")
        fs:SetFont(STANDARD_TEXT_FONT, 11, "")
        fs:SetPoint("LEFT", 8, 0)
        fs:SetText(e.label)
        b:SetScript("OnEnter", function() b:SetBackdropBorderColor(0.247, 0.788, 0.949, 1) end)
        b:SetScript("OnLeave", function() b:SetBackdropBorderColor(0.078, 0.353, 0.451, 1) end)
        b:SetScript("OnClick", function()
            S.Play(e.label)
            print("|cff33ff99[PT Sounds]|r " .. e.label
                .. (e.kit and ("  (SoundKit " .. e.kit .. ")") or "  (shipped file)"))
        end)
        row = row + 1
        if row >= 13 then row = 0; col = col + 1 end
    end
    return win
end

SLASH_ARCPTSOUND1 = "/ptsound"
SlashCmdList.ARCPTSOUND = function()
    Build()
    win:SetShown(not win:IsShown())
end
