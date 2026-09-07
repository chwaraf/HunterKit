# HunterKit

Feed-pet quick button • Sniper Mark range check • Pet Mend marker over the pet •
blaster gun sounds • passive-pet alert.
For **WoW Classic Era & Hardcore** (patch 1.15.x).

A self-contained, dependency-free (no Ace3/LibDBIcon) addon built for the
hardcore-first hunter. Every action is a deliberate click; nothing is automated.

Current version: **0.9.69** — see [`CHANGELOG.md`](CHANGELOG.md).

## Features

| Feature | What it does |
|---|---|
| **Feed Pet button** | A one-click button beside the pet happiness icon. Always feeds the **best** food in your bags (max happiness tier, then smallest open stack), shown as the food icon (or the **default Feed Pet icon** via the *Use default Feed Pet icon* option) with a **count of that food** (all its stacks) on it like an action button. The highlight glows only when the pet is **below happy and you are out of combat**. Respects your pins/excludes. Out-of-combat only (as Blizzard intends). |
| **Sniper Mark** | A reticle by the target frame that reports **IN RANGE / TOO CLOSE / OUT OF RANGE** — six art styles per state in the bold outlined cross family (the new defaults), the classics and a modern sci-fi set, tinted by state. Reflects state only — it never acts. |
| **Pet Mend Marker** | A **Mend Pet icon floating above your pet's head, nameplate style**. Green + solid when the pet is inside Mend Pet range, faded and greyed when it isn't — so you know at a glance, without reading a bar. Goes **bigger and pulsing with an expanding red ring** at or below **30% pet HP**. **On by default**, and it works with nameplates turned off. |
| **Gun sound** | Replaces the stock gunshot with a Star-Wars-style blaster pew, picked at random from the four bundled clips (never the same one twice in a row). One **Replace gun shot sound** toggle does both halves: pew on each shot *and* the stock gunshot muted in its place — untick it and the stock sound comes straight back. Arcane Shot, Multi-Shot and Aimed Shot pew too (**Pew on special shots**, on by default). Guns only; spell shots are never muted. |
| **Passive alert** | A big pulsing Ability Seal center-screen above your character while the pet is Passive, plus an optional glow on the passive button. Impossible to miss. |
| **Low ammo warning** | Periodic on-screen alert when your equipped arrows/bullets run low — the **equipped projectile's own icon under a red X**, right of the passive alert. The less ammo, the more often and the longer it shows. Optional voice warnings (**off by default**, voice only — no game sounds): bundled clips say "Low arrows!"/"Low ammo!" while low (at most once a minute) and "No arrows!"/"No ammo!" when the slot is empty (at most once every 45 s — 45 s is the floor for any voice). The warning icon **pulses** while shown, and the first warning of an episode fires the moment the threshold is reached. A **Warn frequency** slider (1×–4×) scales how often everything repeats. Threshold configurable (default 200). |
| **Ammo auto-buy** | Refills your **quiver / ammo pouch** at any vendor. It counts the ammo-specific bag slots (slots × the ammo's own stack size — 200 for every basic projectile, but read from the item, since some special shot stacks to 20), works out exactly how many arrows or bullets are missing, and buys **precisely that many** — `BuyMerchantItem` takes a count of *items*, so a 63-arrow top-up is one call for 63, not a spare stack. Large refills are chunked at the per-call stack cap (4000 arrows = 20 calls of 200). **Fill completely** or a **percentage slider** (5–100% of quiver capacity). Tier is your choice: **equipped** (more of what you shoot), **best** (highest tier your level allows), or **capped** (best, but never above a level cap — stay on cheap arrows while levelling). **Only buy highest usable ammo** (on by default) refuses to *downgrade*: low-level vendors often stock nothing but Rough Arrow / Light Shot, and rather than quietly filling a level-60 quiver with junk it declines and says why. Restocking the same tier or upgrading is always fine, and an explicit tier cap overrides it. **Gold reserve** and **max spend per visit** sliders are always respected, and a short budget simply buys fewer rounds. Three modes: **confirm** popup (default), **auto** at the vendor, or **manual** only. A **Refill ammo** button appears **only at vendors that actually sell arrows/bullets**, tucked **under the money display** in the merchant window's bottom-left and width-matched to it so it never overhangs the frame; its tooltip shows the exact amount, or the reason it can't buy. |
| **Aggro % readout** | A live threat percentage **above and to the right of your player frame** while you are in combat with a pet, led by **how much more damage would pull the mob** — e.g. `1.2k 74%`. Green while safe, amber as it climbs, red at the pull point (100% = the mob turns on you). Once it reaches your **Warn at** threshold it **swells to 1.18× and pulses** (the font, not the frame — scaling the frame dragged its anchor offsets with it and made the number jump across the screen), so it catches the eye without you having to read it. Quiet and passive: no sound, no popup, **on by default**. Draggable via `/htk unlock`. Reads the game's own threat numbers (see below), so it is exact rather than estimated. |
| **Pet aggro warning** | **Off by default** (opt-in, since it interrupts). A plain **THREAT** flash and a sound when your threat is **climbing** and reaches your threshold on a mob the **pet is tanking** — the cue to stop shooting, Feign Death, or let Growl catch up — and **AGGRO** if the mob does switch to you. It is **direction-aware**: the warning fires on the way *up* only, so easing off and watching the number fall back through the threshold is silent instead of nagging. The alert itself is deliberately just the one word — the exact percentage and the damage-to-pull are already on the readout by your player frame. It reads the **game's own threat numbers** (the threat API Blizzard *reinstated* in patch 1.13.5 and which is live in Classic Era 1.15.x and TBC Anniversary), so unlike the classic combat-log threat meters it needs **no per-spell coefficient tables, no talent/buff modelling and no addon comms** — and it can't drift. The percentage it warns on is Blizzard's own *scaled* figure, which already folds in the melee-110% / ranged-130% pull rule and re-scales itself when you move, so stepping forward mid-fight is handled for free. Costs **nothing at all while you're out of combat**: it polls only while you're in combat with a living pet, checks just two units (your pet's target and your own, deduplicated by GUID), and registers **zero combat-log events**. Threshold (40–100%), sound and repeat interval configurable. The percentage readout above works with or without it. |
| **Macros** | Six hunter macros in their own window (Options → **Macros** → *Open macro library*), each with a short explanation of what it is for and what to watch out for. Click to select, Ctrl+C to copy — an addon cannot write to your clipboard, so the text sits in a read-only box that repairs itself if you type in it. |
| **Weapon timers (auto shot + melee weave bar)** | **Off by default.** A bar showing your Auto Shot cycle while you are firing. In Classic, Auto Shot is a fixed **0.5s cast** followed by a weapon-speed cooldown — so the bar has a long **green** stretch where you are free to move and weave in a shot, and a **red** zone at the end where doing anything **clips** the shot and simply loses that damage. The red zone is drawn **to scale**, so you can see at a glance why a slow ranged weapon is easier to play: a 3.0s bow leaves 2.5s of free time, a 1.8s one leaves 1.3s. Crucially it does not only predict — after every shot it compares when the shot was *expected* against when it *actually* fired and reports the difference (`+0.34s`), which is ground truth including your own latency and the server's re-shot timer. A steady `+0.00` means you are clean. Follows haste procs (re-reads the weapon speed every shot) and restarts with Aimed Shot, which resets the cycle. Appears only while auto-shooting; the animation is detached the moment you stop. |
| **Melee weave marker** | Part of the shot bar. In **Classic Era** the melee and ranged swing timers are **independent** — that is what makes melee weaving possible, and it is worth real damage. (This is version-specific: WotLK deliberately *linked* them, which killed weaving there. HunterKit targets Era.) Out of the box the bar advises **static weaving only**: it will tell you to melee a target that is *already* in melee range and never tell you to go running anywhere. Turning on **Also weave by running in and out** (opt-in) adds the travel case — a blue line marking the last moment you could still leave, land a swing and be back before the shot, with the label reading **WEAVE** while the round trip genuinely fits. A second thin strip tracks your **melee swing**, driven by swings actually observed in the combat log rather than assumed — so it never claims a swing you did not get. It will not suggest a weave when the melee swing would still be on cooldown when you arrive, nor when the free window is too short for the trip (which is what a haste proc does to it), nor — by default — while Aimed Shot or Multi-Shot is up, since either is worth more than a Raptor Strike (that gate is switchable for max-weavers). The Aimed/Multi-Shot cooldown pips themselves are a separate opt-in row (**Show Aimed / Multi-Shot cooldowns**, off by default). While weaving is on the bar stays up for the whole fight, including in melee range where auto-shot stops -- that is exactly when the melee row matters. The melee strip is drawn from the moment weaving is on, not only after your first swing, because the common speedrun pattern is to shoot a pet-held target at range while meleeing a second one next to you. The options window draws a labelled picture of the bar so you can learn the colours without hovering anything, and the bar can optionally be **kept on screen** instead of appearing and vanishing. The round-trip time is a setting (default **2.5s**, the figure the Classic hunter guides quote for a good hunter with a movement buff) because the marker is only honest if it matches how fast *you* actually move — and it is ignored entirely while the target is already in melee. |
| **Options** | Draggable settings window — a master **Enable HunterKit** switch that pauses *every* feature at once, one rule per feature block, wrapped tooltips, and a two-click **Reset ALL settings** button (it arms to *Click again to CONFIRM* and disarms itself after 5 s). Thirteen sections: Master, Feed Pet, Sniper Mark, Pet Mend Marker, Ammo, Ammo auto-buy, Pet aggro warning, Weapon timers, Gun Sound, Passive pet alert, Macros, Positions (**lock/unlock** + **Reset positions** buttons) and Reset. The Sniper Mark block is a grid per state: **SHAPE** cycle-button + state name on the left, short **BRIGHTNESS** slider (0–200%, 100% at the bar's middle, overdrive stacks a second additive pass) on the right. Minimap button, `/htk lock\|unlock`, `/htk reset`. |

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
away. All marks ship as white-on-alpha **`.png`** so the state colour tints them:

| State | Shapes (click the option to cycle), **bold** = default |
|---|---|
| IN RANGE | **`plus`** · `crosshair` · `reticle` · `chevrons` · `diamond` · `ticks` |
| TOO CLOSE | **`cross`** · `x` · `hexx` · `block` · `bars` · `burst` |
| OUT OF RANGE | **`ban`** · `rings` · `dashed` · `halo` · `sides` · `slashes` |

The new art is generated on a black field and luminance-keyed to alpha by
`tools/build_mark_art.py` (black → transparent, mark → white), cropped, squared and
resized to 256 px, then converted losslessly to PNG by `tools/tga_to_png.py` — which
is the shipped format since 0.9.28 (PNG decodes natively, is 9× smaller than the
32-bit TGA the pipeline used to ship, and touches no pixel value; the three
restored classics are 512 px). **Every** style is art — the whole OUT OF RANGE and
TOO CLOSE sets included — and each state has its own compact **brightness slider**
in Options (**0–200%**, 100% at the bar's middle, sitting small on the right of its
label). Because the mark is drawn with an additive blend, above 100% the extra
intensity is stacked as a second additive pass rather than scaled, so overdrive
genuinely gets brighter.
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
plates visible:  0   anchor now: petframe
UnitPosition(pet)=-1.0,-1.0,-1.0  GetPlayerFacing=0.89
```

`anchor now:` is the mode the marker is *actually* using at that moment
(`plate`, `screen`, `petframe` or `none`); when it came from the client's own
screen-position API the source is named in brackets after it.

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
cvars (* = changed by an older HunterKit, restored on load/logout):
  nameplateShowFriends=0  nameplateShowAll=1  nameplateShowEnemies=1
  nameplateShowFriendlyPets=0  nameplateShowOnlyNames=0  nameplateMaxDistance=41.000000
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
| `/htk buy` | refill ammo from the open vendor (works in every mode) |
| `/htk buyinfo` | ammo auto-buy diagnostics (quiver space, vendor offers, the plan) |
| `/htk threat` | pet aggro warning diagnostics (threat API status, per-mob numbers, verdict) |
| `/htk shot` | auto shot timer diagnostics (ranged speed, free window, clip count) |
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

**"No pew?"** — Options → Gun Sound → **Replace gun shot sound** must be on, and the
pew only fires for a **gun** (bows and crossbows keep their own sound). `/htk sound`
plays all four pews back to back so you can hear them without waiting for a shot.
The stock gun shot is **muted by default**, so you'll hear the pew in its place.
If you drop your own `pew-N.ogg` files in `Media/`, you need a **`/reload`** for them
to be picked up. `/htk gunlist` lists exactly which sound IDs are muted.

**"Why is the gun completely silent?"** — That's the default: the original gun shot is
muted so you only hear the pew. There is one control, not two — **Replace gun shot
sound** in Options → Gun Sound turns the pew on *and* mutes the stock gunshot, and
unticking it unmutes those IDs again at once. Note the game's mute is
**session-wide in C++**, so a mute applied while the addon was enabled stays applied
after you disable the addon and `/reload`; untick the box (or re-enable the addon,
which unmutes on load when the setting is off) to bring the stock sound back, and a
game restart clears it either way.

**"Will this feed / stance-switch / attack / mend for me?"** — No. By design it never
performs a game action on its own. The only action paths are the feed button's
secure click and your own clicks. The mend marker is a readout; it cannot cast.

## Sound credits

All eight `Media/*.ogg` files are original to this project — no third-party
recording is bundled. Full details in [`CREDITS.md`](CREDITS.md):

- **`pew-1.ogg` … `pew-4.ogg`** — CC0 synthesised blaster chirps (a downward sine
  sweep with a noise bite and an exponential tail).
- **`voice_lowarrows.ogg`, `voice_lowammo.ogg`, `voice_noarrows.ogg`,
  `voice_noammo.ogg`** — the optional low-ammo voice warnings, text-to-speech
  rendered for this addon and trimmed with `ffmpeg`. Voice warnings are **off by
  default**; nothing plays unless you turn them on.

If you want a real Star-Wars-style pew, drop your own CC0/CC-BY files into
`Media/` named `pew-1.ogg` … `pew-4.ogg`, then `/reload`. Do **not** ship
copyrighted recordings.

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
needs a Lua interpreter on `PATH` (`lua`/`lua5.1`/`luajit`) or `pip install lupa`
(in an externally-managed Python, `python3 -m venv .venv && .venv/bin/pip install
lupa`, then run `.venv/bin/python tests/run_tests.py`).
Add `--verbose` to also echo the addon's chat output. **981 checks**, in **9** files:

| File | Covers |
|---|---|
| `test_mendmark.lua` (119) | marker visibility, range/urgency styling, all four plate-discovery paths plus the direct screen-position APIs, the anchor modes, the *removal* of the force-plate CVar ladder (a leftover CVar from an older install is still restored, and a blocked `SetCVar` neither loops nor throws), drag/lock, restricted-region safety, and the `/htk mend` capability report |
| `test_options_ui.lua` (90) | **builds the real settings window** and checks the layout: window/content size, one divider per section, slider values visible before interaction, no clipped or overlapping text, wrapped tooltips, no stray globals, no module `Init` that throws — plus the **real** `Positions.ToggleLock` round trip (edit mode hands you the movable marker, locking cleans up, a plate-anchored marker is never clamped) |
| `test_settings.lua` (133) | sniper-mark shapes: six distinct shapes per state, the shape on screen follows the cycle button, unknown saved values fall back — plus **Reset ALL settings** (defaults restored, the db slices the modules hold survive, the open window re-displays), the reset button's two-click confirm, and the low-ammo warning's thresholds, tiers and voice cooldowns |
| `test_ammobuy.lua` (125) | the ammo auto-buy planner and queue: quiver capacity (slots × the ammo's stack size, partial stacks, foreign stacks, pouch-vs-quiver family), the three tier modes, level gating, the never-downgrade guard (low-tier vendor refused, same-tier restock and upgrades allowed, tier cap and empty ammo slot exempt), the fill percentage, gold reserve / spend cap / too-poor, limited stock, token-cost ammo, non-200 vendor bundles, no quiver, no vendor ammo — plus the purchase queue (exact amounts, full 200-unit calls, single-call top-ups, the `GetMerchantItemMaxStack`-returns-1 fallback, stall abort, cancel on vendor close), all three vendor modes, and the merchant button (anchored under the money frame, shown only at ammo vendors) |
| `test_threatwatch.lua` (147) | the pet aggro warning's verdict logic against declarative threat tables: the pull-point maths and the damage-to-pull readout, direction-awareness (falling back through the threshold stays silent), alarm rate-limiting, the colour ramp and hot-state emphasis, the guarantee that the warning icon never overlaps the passive-pet alert — and, for the "as light as possible" brief, that it does **no** work when it cannot matter |
| `test_shottimer.lua` (193) | the Auto Shot *model*: the fixed 0.5s cast plus weapon-speed cooldown, how much free time is left and when the lockout starts, the measured `+0.34s` clip readout, haste re-reads, the melee swing strip built from observed swings, static vs travel weaving, the specials gate, and the redraw-skip optimisation |
| `test_macros.lua` (40) | the macro library as text: no macro targets or attacks without accounting for dead units, none pretends to aim Auto Shot with `[@unit]` (it cannot), each fits the client's 255-character limit, and every copy box holds its macro verbatim and repairs itself if edited |
| `test_feedpet.lua` (15) | the number on the feed button: that it is the **inventory** total for the picked food (every stack, not the one the click feeds), for a curated-DB food, for a **pinned** food the DB does not list and whose tooltip the client cannot describe, across three stacks, and back to 0 on empty bags |
| `test_docs.lua` (119) | every file parses, the `.toc` matches disk, `.toc` version == `HK.version` == newest `CHANGELOG` entry, every `/htk` subcommand documented here, the shipped mark art exists as PNG with no `.tga`/`.blp` strays — and this very section: the README's stated version, a row and a **current** check count for every test file, and a correct total |

The counts in that table are not decoration: `test_docs.lua` runs last, reads the
tally every other file reported through `HKTest.report`, and fails if this README
advertises a number the suite does not actually run. Adding a test therefore
requires updating this table in the same commit — which is the rule above, now
enforced rather than merely stated.

## License

MIT. See `LICENSE`. The bundled sound and texture assets are CC0, and
`CREDITS.md` also attributes the pet-food data and the Blizzard art referenced
in place — read it before redistributing.
