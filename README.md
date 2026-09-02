# HunterKit

Feed-pet quick button • Sniper Mark range check • blaster gun sounds • passive-pet alert.
For **WoW Classic Era & Hardcore** (patch 1.15.x).

A self-contained, dependency-free (no Ace3/LibDBIcon) addon built for the
hardcore-first hunter. Every action is a deliberate click; nothing is automated.

## Features

| Feature | What it does |
|---|---|
| **Feed Pet button** | A one-click button beside the pet happiness icon. Always feeds the **best** food in your bags (max happiness tier, then smallest open stack). Respects your pins/excludes. Out-of-combat only (as Blizzard intends). |
| **Sniper Mark** | A crosshair by the target frame that shows **OK / NEAR / DEAD / FAR**. DEAD renders as an X (colorblind-safe). Reflects state only — it never acts. |
| **Gun sound** | Replaces the stock gunshot with a Star-Wars-style blaster pew. Respects guns-only, no-repeat, and mutes the stock sound. |
| **Passive alert** | A big pulsing Ability Seal center-screen above your character while the pet is Passive, plus an optional glow on the passive button. Impossible to miss. |
| **Options** | Draggable settings window, minimap button, `/htk lock|unlock`, `/htk reset`. |

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
| `/htk gunlist` | list the muted gun-sound FileDataIDs |
| `/htk selfcheck` | run API diagnostics |
| `/htk debug` | toggle verbose logging |

## FAQ

**"The mark says OK but my shot fails!"** — Walls. Classic has no line-of-sight API;
`IsSpellInRange` is distance-only. No addon can do better.

**"I use a unit-frame addon / I hid the frames in Edit Mode"** — In options, set the
Feed button and Sniper Mark **anchor parent to `UIParent`**. Since patch 1.15.9 you can
hide the default target/pet frame in Edit Mode with no addon — the UIParent option is
the fix.

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

**"Will this feed / stance-switch / attack for me?"** — No. By design it never
performs a game action on its own. The only action paths are the feed button's
secure click and your own clicks.

## Sound credits

The four bundled `pew-N.ogg` files are **CC0** synthesised blaster chirps (see
`CREDITS.md`). If you want a real Star-Wars-style pew, drop your own CC0/CC-BY
files into `Media/` named `pew-1.ogg` … `pew-4.ogg`, then `/reload`. Do **not**
ship copyrighted recordings.

## Compatibility

- **Edit Mode (1.15.9)** — supported via the `UIParent` anchor option.
- **MuteSoundFile (`/msf`) addon** — both manage mutes; last writer wins per ID. If
  you use `/msf`, remove overlapping gunshot IDs from one of the two.
- **Unit-frame addons** — set Feed/Mark parent to `UIParent`.

## License

MIT. See `LICENSE`. Sound assets CC0 — see `CREDITS.md`.
