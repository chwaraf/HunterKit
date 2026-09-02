# HunterKit

Feed-pet quick button • Sniper Mark range check • Pet Mend marker over the pet •
blaster gun sounds • passive-pet alert.
For **WoW Classic Era & Hardcore** (patch 1.15.x).

A self-contained, dependency-free (no Ace3/LibDBIcon) addon built for the
hardcore-first hunter. Every action is a deliberate click; nothing is automated.

Current version: **0.7.0** — see [`CHANGELOG.md`](CHANGELOG.md).

## Features

| Feature | What it does |
|---|---|
| **Feed Pet button** | A one-click button beside the pet happiness icon. Always feeds the **best** food in your bags (max happiness tier, then smallest open stack). Respects your pins/excludes. Out-of-combat only (as Blizzard intends). |
| **Sniper Mark** | A reticle by the target frame that reports **IN RANGE / TOO CLOSE / OUT OF RANGE**. You pick the shape per state (crosshair / rings / X); TOO CLOSE defaults to an X so it's colorblind-safe. Reflects state only — it never acts. |
| **Pet Mend Marker** | A **Mend Pet icon floating above your pet's head, nameplate style**. Green + solid when the pet is inside Mend Pet range, faded and greyed when it isn't — so you know at a glance, without reading a bar. Goes **bigger and pulsing with an expanding red ring** at or below **30% pet HP**. **On by default**, and it works with nameplates turned off. |
| **Gun sound** | Replaces the stock gunshot with a Star-Wars-style blaster pew. Respects guns-only, no-repeat, and mutes the stock sound. |
| **Passive alert** | A big pulsing Ability Seal center-screen above your character while the pet is Passive, plus an optional glow on the passive button. Impossible to miss. |
| **Options** | Draggable settings window — one rule per feature block, live numbers on every slider, wrapped tooltips. Minimap button, `/htk lock\|unlock`, `/htk reset`. |

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

### Anchoring: how it floats over the pet

A frame can only sit at a unit's position in the world if the client publishes
that position — and the only way it does that is through the unit's **name
plate**. Classic Era has no world-to-screen API, and `UnitPosition()` doesn't
work on pets at all, so no addon can project the pet into screen space by
itself. What the marker does instead:

**0. If the client hands out screen coordinates directly, no plate is needed.**
Older/TBC-lineage builds have been reported to expose the unit's on-screen name
position as a plain function. HunterKit probes for those by name at load
(`GetUnitNamePosition`, `GetUnitScreenPosition`) and, if one answers for `pet`,
anchors straight to it — real world anchoring with every nameplate off. `/htk mend`
prints whether your client has one and the raw values it returned, so this is
verifiable rather than assumed (`mode=screen`).

**1. Find a pet plate — four independent ways, first hit wins.**
`C_NamePlate.GetNamePlateForUnit("pet", true)` (including the "forbidden" plates
instances use), the plate handed to `NAME_PLATE_UNIT_ADDED`, a scan of
`C_NamePlate.GetNamePlates()`, and the pre-`C_NamePlate` layout — `NamePlate1..N`
children of `WorldFrame` carrying the unit token. Any of them gives true
over-the-head anchoring.

**2. If you have nameplates off, make one exist — without you turning them on.**
**There is no pet-only plate setting on any client.** The finest granularity the
CVar API offers is *friendly pets / minions* — enabling it publishes plates for
**other players' pets and minions too**. There is nothing narrower to choose.

Tick **Force pet name plate** (opt-in, off by default). HunterKit then walks a
ladder of nameplate CVars from the least invasive up —
`nameplateShowFriendlyPets` → `nameplateShowFriendlyMinions` →
`nameplateShowFriends` → `nameplateShowAll` — skipping any the client doesn't
have, and **stops at the first rung that actually produces a pet plate**. (On
Classic Era the friendly + minions pair is what publishes one.) It waits ~1s
between rungs so the client can react, and never touches CVars during combat
(the client locks them). Your previous values are stored in SavedVariables and
**restored when you untick the option or log out**, so nothing is written to
your config permanently. `/htk mend` marks every CVar it changed with a `*` and
shows the value it replaced.

**3. Otherwise fall back to the pet unit frame — and look like a plate anyway.**
The fallback draws a nameplate-style widget under the icon (pet name + a
green→red health bar), so it still reads like a plate rather than a stray icon.
The pet unit frame is used **even when you've hidden it in Edit Mode** (a hidden
frame keeps its layout), so the marker doesn't vanish for players following the
UIParent advice below.

**4. Otherwise the UI fallback is yours to place.** `/htk unlock`, drag the
marker wherever you read it best, lock again — the spot is saved per character
(`/htk reset` returns it above the pet frame). Only the fallback is draggable:
while the marker floats over the pet's head it keeps following the pet, and
lock/unlock leaves it alone (a frame anchored to a name plate is a *restricted
region* — touching its clamp/drag state throws and taints).

Anchor modes: **`auto`** (default) = head when a plate exists, else the pet
frame · **`plate`** = head only, hidden while there's no plate · **`petframe`** =
always the UI widget.

### What 1.15.9 actually offers (measured, not assumed)

`/htk mend` on a live 1.15.9 hunter reports:

```
screen-pos APIs: GetUnitNamePosition=absent  GetUnitScreenPosition=absent
pet plate via:   GetNamePlateForUnit=none  NAME_PLATE_UNIT_ADDED=none  GetNamePlates=none  NamePlateN scan=none
plates visible:  0
UnitPosition(pet)=-1.0,-1.0,-1.0  GetPlayerFacing=0.89
```

What that measurement rules out on 1.15.9: **no** screen-position API, **no** pet
world position (`UnitPosition("pet")` is refused), and **no pet plate while
nameplates are off** — so without a plate there is nothing to anchor to, and the
marker is a draggable UI widget. On a client that does publish a pet plate it
floats over the pet's head with no further setup. Run `/htk mend` to see which one
you have.

**What it does *not* rule out:** earlier builds also concluded the
friendly/pet nameplate CVars "no longer exist". That was wrong, and it was our
instrument, not the client: `C_Console.GetAllCommands()` lists registered
**console commands**, and several nameplate CVars aren't registered as one. Pet
plates *are* available on 1.15.9 through the friendly + minions settings (that is
not pet-only — see below). `/htk mend` therefore probes the CVars **by name**
with `GetCVar`, and reports each one it finds with its value. Shape of that line
(**illustrative** — run `/htk mend` for your own client's real values):

```
cvars: nameplateShowAll=1  nameplateShowEnemies=1  nameplateShowFriends=0
       nameplateShowFriendlyMinions=0  nameplateShowFriendlyPets=0  nameplateMaxDistance=41.000000
```

(Real output varies by client; anything the client doesn't have is simply absent
from the line, which is now a trustworthy absence.)

`/htk mend` prints which one is live **and a capability report for your client**:
which screen-position APIs exist and what they return, which of the four plate
paths found the pet, how many plates are visible, and what `UnitPosition("pet")`
and `GetPlayerFacing` give back. If something anchors differently on your client
than described here, that output says exactly why.

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

**"The mend marker isn't floating over my pet's head."** — Run `/htk mend` and
read the `anchor would be:` line. `plate` = it's over the pet's head. `petframe` =
the client publishes no position for your pet, so it's on the UI fallback. With no
pet plate of any kind — no screen-position API either — that's all there is: use
`/htk unlock` and drag it where you want it. **Force pet name plate** makes head
anchoring work with your own nameplates off and restores them afterwards; note it
is *not* pet-only (see above), and there is no pet-only setting to ask for.

> Earlier versions of this README said the friendly-plate CVars were "gone" on
> 1.15.9. That was a bad measurement, not a client fact: the diagnostic listed
> **console commands** (`C_Console.GetAllCommands()`), and several real nameplate
> CVars aren't registered as console commands. `/htk mend` now probes the CVars
> **by name** with `GetCVar`, so what it prints is what the client actually has.

**"How do I know what my client actually supports?"** — Run `/htk mend`. Alongside
the marker's state it prints a capability report: every screen-position API it
probed for (`absent` or the raw x,y it returned), which of the four plate-discovery
paths found your pet, the visible plate count, and `UnitPosition("pet")` /
`GetPlayerFacing` results. Client capabilities differ between Era, TBC-lineage and
the Midnight UI merge — this is the ground truth rather than a guess.

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
- **Nameplate addons / nameplates off** — the mend marker still works: tick
  **Force pet name plate** for head anchoring, or let it use the nameplate-style
  fallback widget. A nameplate addon that replaces Blizzard's plates is fine too —
  the marker anchors to the plate frame, it doesn't restyle it.
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

`python3 tests/run_tests.py` runs the Lua tests: it loads the real addon files
against a stub client (`tests/wow_stub.lua`) — no logic is re-implemented — and
needs a Lua interpreter on `PATH` (`lua`/`lua5.1`/`luajit`) or `pip install lupa`.
Add `--verbose` to echo the addon's chat output. **201 checks**, in three files:

| File | Covers |
|---|---|
| `test_mendmark.lua` (132) | marker visibility, range/urgency styling, all four plate-discovery paths, the anchor modes, the force-plate CVar ladder, drag/lock, restricted-region safety |
| `test_options_ui.lua` (29) | **builds the real settings window** and checks the layout: window/content size, one divider per section, slider values visible before interaction, no clipped or overlapping text, wrapped tooltips, no stray globals, no module `Init` that throws |
| `test_docs.lua` (40) | every file parses, the `.toc` matches disk, `.toc` version == `HK.version` == newest `CHANGELOG` entry, every `/htk` subcommand documented here |

## License

MIT. See `LICENSE`. Sound assets CC0 — see `CREDITS.md`.
