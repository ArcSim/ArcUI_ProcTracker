# ArcUI ProcTracker

A lightweight World of Warcraft addon (WoW 12.0, Midnight) that tracks Shaman proc **decks** — the sequence/shuffle-based procs like Doom Winds, Tempest, Elemental Tempest, and Deeply Rooted Elements — on a movable icon or bar, so you can see how far through the deck you are and when the next proc is due.

**Current version:** 1.0.2

**Companion to:** [ArcUI](https://github.com/ArcSim/ArcUI)

---

## What it does

Each tracked ability is modelled as a **deck**: as you spend casts, cards are drawn from the deck, and the proc becomes more likely (and eventually guaranteed) as it empties. ProcTracker reads the live game state and shows that deck position plus the predicted proc on a single clean icon — no guessing, no spreadsheets.

- **Deck position** — how many cards remain before the next proc, shown as text on the icon with color thresholds (empty / half / full)
- **Proc prediction** — a separate readout for the predicted proc state
- **Icon or bar display** — show each deck as a movable icon, or as a bar
- **Per-deck customization** — position, size, scale, strata, colors, borders (including class-colored), and text placement, all per deck
- **Reset triggers** — decks reset automatically at the start of a boss encounter (Normal/Heroic/Mythic/LFR/Mythic Flexible raids) and on Mythic+ key start, plus a manual reset
- **Debug timelines** — optional per-deck debug views for verifying proc behavior

### Tracked decks

| Deck | Ability |
|---|---|
| DW | Doom Winds |
| Tempest | Tempest (Stormbringer) |
| Elemental Tempest | Tempest (Elemental) |
| DRE | Deeply Rooted Elements |
| MSW | Maelstrom Weapon (shared module) |

---

## Slash commands

| Command | What it does |
|---|---|
| `/pt` | List all decks |
| `/pt <deck>` | Open that deck's icon options (e.g. `/pt dw`) |
| `/pt reset <deck>` | Reset a deck (e.g. `/pt reset dw`) |

A minimap button is also provided (left-click opens options; right-click toggles the Tempest debug timeline).

---

## Design

- **Zero idle CPU** — fully event-driven, no polling
- **No `pcall`** anywhere in the codebase
- Settings stored per character in SavedVariables `ArcUI_ProcTrackerDB`

---

## Requirements

- World of Warcraft 12.0 (Midnight)
- Works standalone; pairs naturally with [ArcUI](https://github.com/ArcSim/ArcUI)
