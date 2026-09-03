# HunterKit

Feed-pet quick button • Sniper Mark range check • Pet Mend marker over the pet •
blaster gun sounds • passive-pet alert.
For **WoW Classic Era & Hardcore** (patch 1.15.x).

A self-contained, dependency-free (no Ace3/LibDBIcon) addon built for the
hardcore-first hunter. Every action is a deliberate click; nothing is automated.

Current version: **0.9.14** — see [`CHANGELOG.md`](CHANGELOG.md).

## Features

| Feature | What it does |
|---|---|
| **Feed Pet button** | A one-click button beside the pet happiness icon. Always feeds the **best** food in your bags (max happiness tier, then smallest open stack), shown as the food icon with a **count of that food** (all its stacks) on it like an action button. The highlight glows only when the pet is **below happy and you are out of combat**. Respects your pins/excludes. Out-of-combat only (as Blizzard intends). |
| **Sniper Mark** | A reticle by the target frame that reports **IN RANGE / TOO CLOSE / OUT OF RANGE** — six art styles per state in the bold outlined cross family (the new defaults), the classics and a modern sci-fi set, tinted by state. Reflects state only — it never acts. |
| **Pet Mend Marker** | A **Mend Pet icon floating above your pet's head, nameplate style**. Green + solid when the pet is inside Mend Pet range, faded and greyed when it isn't — so you know at a glance, without reading a bar. Goes **bigger and pulsing with an expanding red ring** at or below **30% pet HP**. **On by default**, and it works with nameplates turned off. |
| **Gun sound** | Replaces the stock gunshot with a Star-Wars-style blaster pew. Respects guns-only, no-repeat, and mutes the stock sound. |
| **Passive alert** | A big pulsing Ability Seal center-screen above your character while the pet is Passive, plus an optional glow on the passive button. Impossible to miss. |
| **Low ammo warning** | Periodic on-screen alert when your equipped arrows/bullets run low — the **equipped projectile's own icon under a red X**, right of the passive alert. The less ammo, the more often and the longer it shows. Sound is **distinct and rare**: a quest-failed style sting only when things get worse, and short bundled voice clips that speak the situation — "Low ammo!" when the count gets worse, "No arrows!" / "No ammo!" when the slot is empty (at most once every 30 s). Threshold configurable (default 200). |
| **Options** | Draggable settings window — a master **Enable HunterKit** switch that pauses *every* feature at once, one rule per feature block, wrapped tooltips, and a two-click **Reset ALL settings** button. The Sniper Mark block is a grid per state: **SHAPE** cycle-button + state name on the left, short **BRIGHTNESS** slider (0–200%, 100% at the bar's middle, overdrive stacks a second additive pass) on the right. Minimap button, `/htk lock\|unlock`, `/htk reset`. |

## Sniper Mark

A reticle beside the target frame that answers one question: **can I shoot?**
It reflects state only — it never fires, targets or casts.

| State | Colour | Character of the shapes |
|---|---|---|
| **IN RANGE** (Auto Shot ready) | green | open and angular — the shot is available |
| **TOO CLOSE** (inside the deadzone) | red | closed and heavy — back up |
| **OUT OF RANGE** | grey | a prohibition sign — no shot |

Each state has **six shapes of its own**, and each one is a real piece of art, not
a recolour of a single icon. The defaults are the **bold outlined cross family** —
the TOO CLOSE cross you liked, plus a matching circled IN RANGE plus and a matching
prohibition-sign OUT OF RANGE, generated against the cross itself so the line work matches.
The restored classic crosshair / X / ring marks and the sci-fi set remain one click
away. All marks ship as white-on-alpha `.tga` so the state colour tints them:

| State | Shapes (click the option to cycle), **bold** = default |
|---|---|
| IN RANGE | **`plus`** · `crosshair` · `reticle` · `chevrons` · `diamond` · `ticks` |
| TOO CLOSE | **`cross`** · `x` · `hexx` · `block` · `bars` · `burst` |
| OUT OF RANGE | **`ban`** · `rings` · `dashed` · `halo` · `sides` · `slashes` |

The new art is generated on a black field and luminance-keyed to alpha by
`tools/build_mark_art.py` (black → transparent, mark → white), cropped, squared and
resized to 256px, and **every** style is now art (the whole OUT OF RANGE and
TOO CLOSE sets included), and each state has its own compact **brightness slider** in Options (10–100%,
sitting small on the right of its label).
The colour always carries the state as well, so the mark stays
readable for colourblind players who pick a shape per state.

## Pet Mend Marker

The marker answers one question mid-fight: **can I Mend right now?**

| Pet state | Marker |
|---|---|
| In Mend Pet range, healthy | Solid icon, **green** box, full opacity |
| Out of Mend Pet range | **Red** box, icon greyed and faded to 45% (optional), `TOO FAR` label |
| At or below 30% HP | **Grows (up to ~14%), pulses, expanding red ring**, `MEND!` label |
| No pet / dead pet / Mend Pet not learned | Hidden |

- **Toggle:** Options → Pet Mend Marker → *Enable mend marker* — **on by default**. *Show only below threshold* makes it appear only at/below the HP threshold.
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

Earlier builds shipped an opt-in **Force pet name plate** CVar ladder here.
Real-world testing showed clients that publish **no** pet plate even with every
nameplate CVar turned on — there the option only held the player's nameplate
settings hostage, so it was **removed in 0.9.1**. Head anchoring now happens only
when the client itself publishes a pet plate; otherwise the marker uses the
pet-frame fallback. Any CVar an older build changed is still restored on
load/logout, and `/htk mend` marks those with a `*`.

**3. Otherwise fall back to the pet unit frame — under the avatar, looking like
a plate anyway.** The fallback sits centred on the avatar's vertical axis with a
clear gap below the frame (never overlapping it) and draws a nameplate-style
widget under the icon (pet name + a
green→red health bar), so it still reads like a plate rather than a stray icon.
The pet unit frame is used **even when you've hidden it in Edit Mode** (a hidden
frame keeps its layout), so the marker doesn't vanish for players following the
UIParent advice below.

**4. Otherwise the UI fallback is yours to place.** `/htk unlock`, drag the
marker wherever you read it best, lock again — the spot is saved per character
(`/htk reset` returns it under the pet avatar).

**In edit mode you always drag the fallback — even when the head anchor is live.**
`/htk unlock` switches the marker to the UI fallback widget while frames are
unlocked, so the thing on screen is the thing you can move; `/htk lock` sends it
back over the pet's head. It has to be that way: a frame anchored to a name plate
is a *restricted region*, so the client throws and taints if anything touches its
drag or clamp state, and the addon re-applies the plate anchor every 100 ms — a
drag there could neither be started nor kept. That is also why edit mode shows
**one** marker, not two: there is no second, movable copy of the head marker to
show, and showing the immovable one would leave you dragging nothing.

When the client shows the pet's name via a **name-only plate**, that plate frame
exists and `auto` anchors over the head/name — a name-only plate looks like "just
the name" but IS anchorable. Careful with the lookalike: the *unit-name* setting
(`UnitNameFriendlyPetName`) also draws the pet's name with all nameplates off, but
it exposes **no frame and no screen position**, so nothing can anchor to it — there
the marker falls back under the avatar and `/htk mend` explains the difference.

Anchor modes: **`auto`** (default) = head/name when a plate exists, else under
the avatar · **`plate`** = head only, hidden while there's no plate ·
**`petframe`** = always the UI widget under the avatar.

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
`/htk unlock` and drag it where you want it. (An opt-in CVar ladder that tried to
force a pet plate into existence was removed in 0.9.1 — on such clients it could
never work.)

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
- **Nameplate addons / nameplates off** — the mend marker still works: it anchors
  over the head when the client publishes a pet plate, otherwise it uses the
  nameplate-style fallback widget. A nameplate addon that replaces Blizzard's
  plates is fine too — the marker anchors to the plate frame, it doesn't restyle it.
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
Add `--verbose` to echo the addon's chat output. **261 checks**, in four files:

| File | Covers |
|---|---|
| `test_mendmark.lua` (139) | marker visibility, range/urgency styling, all four plate-discovery paths, the anchor modes, the force-plate CVar ladder, drag/lock, restricted-region safety |
| `test_options_ui.lua` (54) | **builds the real settings window** and checks the layout: window/content size, one divider per section, slider values visible before interaction, no clipped or overlapping text, wrapped tooltips, no stray globals, no module `Init` that throws — plus the **real** `Positions.ToggleLock` round trip (edit mode hands you the movable marker, locking cleans up, a plate-anchored marker is never clamped) |
| `test_settings.lua` (28) | sniper-mark shapes: six distinct shapes per state, the shape on screen follows the dropdown, unknown saved values fall back — plus **Reset ALL settings** (defaults restored, the db slices the modules hold survive, the open window re-displays) and the reset button's two-click confirm |
| `test_docs.lua` (40) | every file parses, the `.toc` matches disk, `.toc` version == `HK.version` == newest `CHANGELOG` entry, every `/htk` subcommand documented here |

## License

MIT. See `LICENSE`. Sound assets CC0 — see `CREDITS.md`.
