# ArcUI ProcTracker — Changelog

## 1.4.0
### New Features
- **Deeply Rooted Elements tracker (Restoration)** — A new icon showing the chance your next Riptide procs Ascendance, and how many Riptides you have cast since your last proc. The chance climbs 1% per Riptide and resets when it procs. Off by default, and only shows if you have the talent.
### Improvements
- **12.1.5 test client** — Loads on the 12.1.5 PTR without the out of date warning.

## 1.3.1
- **Natural Harmony**: Nature's Guardian now uses the shorter cooldown when you have the talent. 35 seconds for Elemental, 30 for Restoration.

## 1.3.0
- **Nature's Guardian tracker (new)**: An icon for its 45 second cooldown. Shows only when you have the talent.
- **Proc chance text (new)**: Every deck can show the odds your next spender procs.
- **Separate texts**: Deck position, proc count and proc chance each have their own toggle, font, colour and position.
- **Attach text to other icons**: Any text can ride a Cooldown Manager icon or an action bar button.
- **Cooldown and glow options**: Sweep, edge line and glow settings with separate ready and on cooldown looks, plus preview buttons.
- **Cleaner options window**: Controls line up in one column, long dropdowns scroll, and sections no longer draw a stray line.

## 1.2.0
- **Proc sounds for Doom Winds**: Play a sound the moment a proc comes off the Doom Winds deck, set up under the deck's new Sounds tab.

## 1.1.8
- **Safe Mythic+ Reset (new, on by default)**: Decks now reset the moment a key starts, so a reset can never be missed. If you use "the skip", turn the new toggle off under Mythic+ to keep the exact gate-drop behaviour.
- **Fixed decks sometimes not resetting in Mythic+**: A reset could be missed at the key start and the deck then stayed wrong for the whole dungeon. Fixed with Safe Reset on or off.

## 1.1.7
- **Fixed the addon breaking when another addon uses the same name internally**: ProcTracker kept its internals under a name so short that other addons could claim it too. When one did, ProcTracker lost track of itself and threw a stream of Lua errors, and the decks stopped working entirely. If you have had error spam since installing, or it never worked at all, this is the cause and it is fixed. Nothing on your end needs changing.

## 1.1.6
- **Classic Options Panel Fix (for real this time)**: The fix in 1.1.5 did not work. Opening the settings window with the Classic Options Panel turned on still failed with a Lua error, so /pt did nothing. That is now genuinely fixed. If you have been unable to open your settings since 1.1.0, this is the one.
- **New /pt classic and /pt arc commands**: Switch between the two options styles straight from chat. The toggle for it normally lives inside the settings window, which is no help when the window will not open, so this is the way out if you ever get stuck again.
- **Options Panel Polish**: Toggles are now proper checkboxes and line up in a single column in each section instead of sitting out at the far edge, section groups read as raised panels, and the spacing is tighter so more fits on screen without scrolling. Buttons got a cleaner look to match.
- **Discord Button**: The settings window now has a Discord button if you want help or want to report something.

## 1.1.5
- **Classic Options Panel Fix** — Fixed the Classic Options Panel refusing to open with an "unknown parameter" error. The panel has been broken since 1.1.0 for anyone who switched to it under General; the default Arc options window was never affected.

## 1.1.4
- **New Soulburst Tracking (Demon Hunter)** — Tracks the Devourer two-piece set bonus for Midnight Season 2. The icon shows the chance your next Reap, Cull or Eradicate procs Soulburst: it starts at 7%, climbs each time a harvest fails to proc, and resets when one lands. Only harvests that consume 4 or more Soul Fragments count, matching the set bonus.
- **Only Show With 2-Piece** — The Soulburst tracker hides its icon and bar unless you have the set equipped. On by default, and can be turned off in the Widget section if you want it visible anyway. Tracking keeps running either way, so swapping gear never leaves the counter wrong.
- **Bar Scale Fix** — Fixed bars briefly appearing at the wrong size and slightly off position until their first update.
- **Free Text Position Fix** — Fixed bar texts set to Free positioning jumping to a different spot after a reload.

## 1.1.3
- **New Storm Unleashed Deck** — Tracks the Crash Lightning reset proc for Enhancement: 5 procs per 250 Maelstrom Weapon spent, with its own icon and bar.
- **Doom Winds Without the Cooldown Manager** — With Rolling Thunder or Feral Spirit talented, the Doom Winds deck now tracks procs on its own and no longer needs the Cooldown Manager set up. The Behavior tab tells you which talent is providing the signal.
- **Tempest Without the Cooldown Manager** — The Tempest deck no longer asks for Cooldown Manager tracking, and the "CDM frame not found" warning it sometimes showed mid-fight is gone.
- **Detection Method Setting** — Decks that can track without the Cooldown Manager now say so, and a new "Use CDM Detection Instead" option lets you switch back if you ever need to.
- **Behavior Tab** — The Reset tab is now Behavior and holds both Reset Deck Tracking and the detection settings. These stay available even if you turn the icon off and use only the bar.
- **Duplicate Icon Fix** — Fixed a second, frozen copy of a deck icon sometimes appearing on login or reload.
- **Deck Reset Fix** — Decks now reset when a boss encounter starts at target dummies and in older raids, matching how they already reset in current raids.

## 1.1.2
- **Hide Out of Combat** — New per-deck option for icons and bars to hide them until you enter combat.
- **Font Selection** — Pick the font used by each deck's icon and bar text, including fonts shared by other addons like ArcUI.
- **Doom Winds Deck Fix** — Fixed the Doom Winds deck counting extra procs.

## 1.1.0
- **New Options Look** — Brand-new Arc options window with tab navigation and a resizable panel. "Classic Options Panel" under General brings back the old one.
- **Works With CDM Icons or Bars** — Deck tracking now hooks the cooldown wherever it lives in the Cooldown Manager: shown as an icon or as a bar, in any viewer.
- **Cleaner Option Groups** — Icon and bar settings reorganized into clearer tabs and sections.
- **Bar Improvements** — Position X/Y fields with Reset to Center, dragging and Lock Position fixes, and a new Single Fill Color option.
- **Patch 12.1 Ready** — Proc detection updated for Midnight's Patch 12.1 API changes.

## 1.0.3
- **Mythic Flex Raids** — Proc decks now reset at the start of a boss encounter on the new Mythic Flexible raid difficulty, matching how they already reset on Normal, Heroic, Mythic, and LFR.
- **Patch 12.0.7** — Updated for WoW 12.0.7.
