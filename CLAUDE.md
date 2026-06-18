# ArcUI_ProcTracker — Claude Code Instructions

ArcUI_ProcTracker ("Arc Proc Tracker" on CurseForge, project `1516247`) is a standalone WoW
addon that tracks Shaman proc **decks** — sequence/shuffle-RNG procs whose next trigger can be
predicted from how many casts have been spent. Sibling of ArcUI. Target client: WoW 12.0.x
(Midnight).

> For shared WoW-addon rules (12.0 secret/taint, dev workflow, reference sources, packaging),
> see the global **`wow-addon-dev`** skill. This file is only what's specific to ProcTracker.

---

## What it is

Each tracked ability is a "deck": as casts are spent, cards are drawn and the proc becomes
guaranteed as the deck empties. ProcTracker reads live game state and shows the deck position +
predicted proc on a movable icon or bar. Decks:
- **DW** — Doom Winds
- **Tempest** / **Elemental Tempest** — Tempest (Enhancement / Elemental)
- **DRE** — Deeply Rooted Elements
- **MSW** — Maelstrom Weapon (shared module; reset first so decks see clean state)

## Architecture

- Global namespace is **`PT`** (NOT ArcUI's `local ADDON, ns = ...` pattern). Decks register via
  `PT.RegisterDeck()`.
- **`ArcUI_PT_Core.lua`** — icon widget factory, per-deck options panel, `/pt` slash command,
  registry (`registry` / `registryMap`), SavedVariables (`ArcUI_ProcTrackerDB`), minimap button,
  and the central deck-reset events. No detection logic lives here.
- **`ArcUI_PT_Bar.lua`** — bar display. **`ArcUI_PT_MSW.lua`** — Maelstrom Weapon shared state.
- **`ArcUI_PT_<X>Deck.lua`** — per-deck detection engines. **`ArcUI_PT_<X>Debug.lua`** — debug
  timelines (`/pt` minimap right-click toggles the Tempest one).
- **No `pcall`. Zero polling** — event-driven only.

## Deck resets

Centralized in `ArcUI_PT_Core.lua` (`ResetAllDecks` + `resetEventFrame`). Decks reset on:
- **`ENCOUNTER_START` in a raid** — difficulty gate `(diff >= 14 and diff <= 17) or diff == 233`
  (14–17 = Normal/Heroic/Mythic/LFR; **233 = Mythic Flexible**, added in 12.0.7).
- **Mythic+ key start** — `CHALLENGE_MODE_RESET` arms it, confirmed by `WORLD_STATE_TIMER_START`
  at difficulty 8.
- **Manual** `/pt reset <deck>`.

If a new raid difficulty is added in a future patch, add its ID to that gate — verify the ID in
`E:\WoWDev\wow-ui-source\AddOns\Blizzard_FrameXMLUtil\DifficultyUtil.lua`.

---

## Releasing  (this is the important part)

Releases are fully automated via **GitHub Actions + the BigWigs packager**
(`.github/workflows/release.yml`). When the user says **"publish X.Y.Z"**:

1. Bump `## Version: X.Y.Z` in `ArcUI_ProcTracker.toc`.
2. Add a `## X.Y.Z` section to **`CHANGELOG.md`** — this file IS the CurseForge changelog
   (`.pkgmeta` `manual-changelog`). Format: `- **Title** — Description`, plain user-facing English.
3. `luac -p` every touched Lua file.
4. Commit.
5. Tag and push. **The tag has NO "v" prefix** — the CurseForge file label is
   `ArcUI_ProcTracker-{project-version}` and `{project-version}` is the tag verbatim, so `1.0.4`
   gives `ArcUI_ProcTracker-1.0.4` (a leading `v` would leak into the label):
   ```
   git tag -a X.Y.Z -m "Release X.Y.Z"
   git push origin main
   git push origin X.Y.Z
   ```

The tag push triggers the workflow, which builds per `.pkgmeta`, uploads to CurseForge (project
read from the toc's `## X-Curse-Project-ID: 1516247`), and creates the GitHub release. **Do NOT**
run `gh release create` or POST CurseForge manually — the Action does both. For a beta file, put
"alpha"/"beta" in the tag (e.g. `X.Y.Z-beta`).

**Pipeline pieces — don't break these:** toc `## X-Curse-Project-ID: 1516247`; repo secret
`CF_API_KEY` (a CurseForge token); `.pkgmeta` (`package-as: ArcUI_ProcTracker`,
`manual-changelog: CHANGELOG.md`, the ignore list); the `-n ":{package-name}-{project-version}"`
label in the workflow. CurseForge's own "Automatic Packaging" is set to **No automatic packaging**
— Actions is the only packager (don't re-enable it or files double-build).

## Conventions

- **Commit/push only on release** — keep changes uncommitted for in-game testing before that.
- All new options default **OFF** (opt-in).
- Surgical fixes; one bug/feature per session; `luac -p` before declaring done.
