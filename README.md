# HunterKit

Feed-pet quick button • Sniper Mark range check • Pet Mend marker over the pet •
blaster gun sounds • passive-pet alert.
For **WoW Classic Era & Hardcore** (patch 1.15.x).

A self-contained, dependency-free (no Ace3/LibDBIcon) addon built for the
hardcore-first hunter. Every action is a deliberate click; nothing is automated.

Current version: **0.3.0** — see [`CHANGELOG.md`](CHANGELOG.md).

## Features

| Feature | What it does |
|---|---|
| **Feed Pet button** | A one-click button beside the pet happiness icon. Always feeds the **best** food in your bags (max happiness tier, then smallest open stack). Respects your pins/excludes. Out-of-combat only (as Blizzard intends). |
| **Sniper Mark** | A reticle by the target frame that reports **IN RANGE / TOO CLOSE / OUT OF RANGE**. You pick the shape per state (crosshair / rings / X); TOO CLOSE defaults to an X so it's colorblind-safe. Reflects state only — it never acts. |
| **Pet Mend Marker** | A **Mend Pet icon above your pet's head**. Green + solid when the pet is inside Mend Pet range, faded and greyed when it isn't — so you know at a glance, without reading a bar. Goes **bigger and pulsing with an expanding red ring** at or below **30% pet HP**. **On by default.** |
| **Gun sound** | Replaces the stock gunshot with a Star-Wars-style blaster pew. Respects guns-only, no-repeat, and mutes the stock sound. |
| **Passive alert** | A big pulsing Ability Seal center-screen above your character while the pet is Passive, plus an optional glow on the passive button. Impossible to miss. |
| **Options** | Draggable settings window, minimap button, `/htk lock\|unlock`, `/htk reset`. |

## Pet Mend Marker

The marker answers one question mid-fight: **can I Mend right now?**

| Pet state | Marker |
|---|---|
| In Mend Pet range, healthy | Solid icon, **green** box, full opacity |
| Out of Mend Pet range | **Red** box, icon greyed and faded to 45% (optional), `TOO FAR` label |
| At or below 30% HP | **Grows (up to ~14%), pulses, expanding red ring**, `MEND!` label |
| No pet / dead pet / Mend Pet not learned | Hidden |

- **Toggle:** Options → Pet Mend Marker → *Enable mend marker* — **on by default**.
- **Out of combat:** hidden once the pet is healthy (*Only in combat*, on by
  default). A pet below the threshold always shows, combat or not.
- **Threshold** is a slider (5–100%, default **30**).
- **`/htk mend`** prints the live state, the anchor actually in use, and the
  nameplate CVars the client is reading.

### Anchoring — and why nameplates matter

The client only publishes a unit's **world position** while that unit has a name
plate. Classic Era has no world-to-screen API, so no addon can float a frame over
a pet the client isn't drawing a plate for. The marker therefore anchors like
this:

1. **`auto` (default)** — over the pet's head when a pet name plate exists;
   otherwise above the **pet unit frame**. It still works with every nameplate
   turned off, it just follows the UI frame instead of the pet's head.
2. **`plate`** — head-anchored only. Hidden when the client exposes no plate
   (use this if you never want the UI fallback).
3. **`petframe`** — always above the pet unit frame.

The pet unit frame is used **even when you've hidden it in Edit Mode** (a hidden
frame keeps its layout), so the marker doesn't vanish for players following the
UIParent advice below. Turn friendly nameplates on if you want true
over-the-head anchoring; `/htk mend` tells you which mode is live.

## Install

1. Unzip so that `Interface/AddOns/HunterKit/HunterKit.toc` exists.
2. Enable **HunterKit** in the AddOn list (tick *"Load out of date AddOns"* after
   a game patch if prompted).
3. `/htk` opens settings, `/htk unlock` moves things, `/htk help` lists everything.

## Slash commands

| Command | Action |
|---|---|
| `/htk` or `/htk ui` | open options |
| `/htk help` | list commands + feature status |
| `/htk lock` / `/htk unlock` | toggle drag handles |
| `/htk reset` | reset positions |
| `/htk sound` | preview the four pews |
| `/htk feed` | show what the feed button will feed (food + stack + macro) |
| `/htk mend` | pet mend marker diagnostics (state, anchor, nameplate CVars) |
| `/htk gunlist` | list the muted gun-sound FileDataIDs |
| `/htk selfcheck` | run API diagnostics |
| `/htk debug` | toggle verbose logging |

## FAQ

**"The mark says IN RANGE but my shot fails!"** — Walls. Classic has no line-of-sight API;
`IsSpellInRange` is distance-only. No addon can do better.

**"The mend marker isn't floating over my pet's head."** — That's the nameplate
rule above: no pet plate, no world position. Run `/htk mend` — it prints the
anchor in use (`mode=plate` vs `mode=petframe`) and the relevant CVars. Set
Anchor = `petframe` to make the UI position permanent, or enable friendly
nameplates for true head anchoring.

**"I use a unit-frame addon / I hid the frames in Edit Mode"** — In options, set the
Feed button and Sniper Mark **anchor parent to `UIParent`**. Since patch 1.15.9 you can
hide the default target/pet frame in Edit Mode with no addon — the UIParent option is
the fix. The pet mend marker keeps working either way (it anchors to the pet frame's
layout even while that frame is hidden).

**"No pew?"** — Options → Gun Sound → it's guns-only by default. Click **Preview** to
test. The stock gun shot is **muted by default**, so you'll hear the pew in its place.
If you drop your own `pew-N.ogg` files in `Media/`, you need a **`/reload`** for them
to be picked up.

**"Why is the gun completely silent?"** — That's the default: the original gun shot is
muted so you only hear the pew. If you'd rather keep the stock sound, uncheck
**Mute stock gunshot** in Options → Gun Sound. Note the game's mute is
**session-wide in C++**, so a muted sound stays muted even after you disable the addon
and `/reload`; press **Restore stock gunshot now** (or uncheck the box) to bring the
stock sound back, and only a game restart clears it if you leave it muted.

**"Will this feed / stance-switch / attack / mend for me?"** — No. By design it never
performs a game action on its own. The only action paths are the feed button's
secure click and your own clicks. The mend marker is a readout; it cannot cast.

## Sound credits

The four bundled `pew-N.ogg` files are **CC0** synthesised blaster chirps (see
`CREDITS.md`). If you want a real Star-Wars-style pew, drop your own CC0/CC-BY
files into `Media/` named `pew-1.ogg` … `pew-4.ogg`, then `/reload`. Do **not**
ship copyrighted recordings.

## Compatibility

- **Edit Mode (1.15.9)** — supported via the `UIParent` anchor option.
- **Nameplate addons / nameplates off** — the mend marker falls back to the pet
  unit frame; see the anchoring section above.
- **MuteSoundFile (`/msf`) addon** — both manage mutes; last writer wins per ID. If
  you use `/msf`, remove overlapping gunshot IDs from one of the two.
- **Unit-frame addons** — set Feed/Mark parent to `UIParent`.

## Development

**Every change updates the docs in the same commit** — that's the rule, and the
test suite enforces part of it:

| File | Update it when… |
|---|---|
| `README.md` | a feature, slash command, default, or behaviour changes |
| `CHANGELOG.md` | always — a new `## [x.y.z] - date` entry at the top |
| `HunterKit.toc` | the version bumps, or a `.lua` file is added/removed |
| `Core.lua` | `HK.version` and, for schema changes, `HK.defaults` + `dbVersion` + a migration block |

`python3 tests/run_tests.py` runs the Lua tests: it loads the real `Core.lua` and
`MendMark.lua` against a stub client (`tests/wow_stub.lua`), then checks that
every addon file parses, that the `.toc` matches the files on disk, that the
`.toc` version matches `HK.version`, that the newest `CHANGELOG` entry matches
it too, and that every `/htk` subcommand in `Core.lua` is documented here.
Needs a Lua interpreter on `PATH` (`lua`/`lua5.1`/`luajit`) or `pip install lupa`.
Add `--verbose` to echo the addon's chat output.

## License

MIT. See `LICENSE`. Sound assets CC0 — see `CREDITS.md`.
