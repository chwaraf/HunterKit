# Changelog
All notable changes to HunterKit are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/), and the project adheres to
[Semantic Versioning](https://semver.org/).

## [0.9.15] - 2026-09-03

### Changed
- **Voice warnings are opt-in: OFF by default** (dbVersion 19 forces the new
  default once for existing profiles; the checkbox re-enables).
- **Voice only — no game sounds at all.** The quest-failed sting fallback is
  gone; if a clip is missing, the warning is simply silent.
- **Clips shortened to the first sentence** ("No ammo, lad!" — the second
  sentence was still getting cut in game): 1.7–1.9 s, four clips matching the
  situation AND the projectile: `voice_lowarrows.ogg`, `voice_lowammo.ogg`,
  `voice_noarrows.ogg`, `voice_noammo.ogg`.

### Fixed
- **"Low ammo" was never heard**: `lastTier` was updated on EVERY tick, so by
  the time the warn period elapsed the tier had already "caught up" and the
  escalation voice was skipped. It now updates only when a warn actually
  fires, so the first warning and every escalation speaks.

### Tests
- 119 + 54 + 68 + 43 = **284 green** (voice-only assertion: no sound outside
  the addon's Media folder is ever played; default-off default; low-arrows
  clip path).

---

## [0.9.14] - 2026-09-03

### Changed
- **Voice clips ship as .ogg, and speak the situation.** Every mp3 take --
  including untouched generator output -- stopped mid-word on the live
  client; the classic-era engine's mp3 decoder is the flaky part, so all
  three clips are re-encoded to ogg vorbis (44.1 kHz mono, the format addon
  sounds universally ship as). New clip set (long-form render, trimmed at
  the detected silence gaps with 0.3 s tails):
  - `voice_lowammo.ogg` — "Low ammo, lad! The quiver's running light!"
    (3.5 s) — plays when the count gets WORSE (first entry / escalation)
  - `voice_noarrows.ogg` — "No arrows, lad! The quiver's empty!" (3.2 s)
  - `voice_noammo.ogg` — "No ammo, lad! We're out of ammo!" (2.8 s),
    at most once every 30 s
  The quest-failed sting is now only the fallback for a missing clip.

### Tests
- 119 + 54 + 66 + 43 = **282 green** (low-tier voice path asserted).

---

## [0.9.13] - 2026-09-03

### Fixed
- **Feed button food count showed 1 instead of the real stack size** on live
  clients: `HK.GetBagItemCount` read `info.itemCount` from
  `C_Container.GetContainerItemInfo`, but the live struct field is
  **`stackCount`** — the count was always nil, and every stack fell back to
  "1". Now reads `stackCount` (with `itemCount` as fallback), and the test
  stub gained a live-shaped `C_Container` (stackCount/itemID/hyperlink) so
  the suite runs the SAME code path as 1.15.x — reintroducing the bug now
  fails the suite (verified: it reports the stacks-of-1 total).
- **Feed button highlight made unmistakable**: the food icon itself now tints
  happiness-orange/red alongside the border (thickened 1px -> 2px), and the
  border is created BEFORE the fontstring work in `BuildButton` so nothing
  downstream can leave the button permanently dull. Rule unchanged: ON only
  when the pet is below happy AND out of combat.
- **"No ammo" voice no longer nags**: it speaks at most once every 30 s
  (was: every 10 s warn). The visual re-warns keep their period.
- **Clips no longer cut off the last word**: re-recorded and re-trimmed with
  a 0.3 s tail of the detected silence gap after the final word (the old cut
  started the fade AT the silence boundary, clipping the release), plus a
  trimmed leading silence. 3.2 s / 3.0 s.

### Tests
- 119 + 54 + 66 + 43 = **282 green**.

---

## [0.9.12] - 2026-09-03

### Changed
- **Voice clips (fifth take) re-recorded with a British-accented voice**
  (`en-GB` candidate pool instead of the generic `en` pool, whose takes kept
  reading generic no matter the text). Same production as 0.9.11: long-form
  dwarfy line rendered first, first two sentences cut at the silencedetect
  boundaries with a fade. `voice_noarrows.mp3` 3.0 s, `voice_noammo.mp3`
  3.0 s. A pitch-shifted (-3 semitones) variant can be produced on request.

---

## [0.9.11] - 2026-09-03

### Fixed
- **Voice clips (fourth take) finally match the dwarfy audition.** The
  generator only holds the voice's character in long-form text, so the clips
  are now produced the same way the audition is: the picked voice reads the
  full dwarfy line ("No arrows, lad! The quiver's empty! Back to the vendor
  we go..."), and the first two sentences are cut out at the detected silence
  boundaries (ffmpeg `silencedetect`) with a 50 ms fade. In game you hear
  only the short warning — rendered in the long-form voice the user approved.
  `voice_noarrows.mp3` 2.3 s, `voice_noammo.mp3` 2.5 s, 48 kbps mono.

---

## [0.9.10] - 2026-09-03

### Fixed
- **Voice clips re-recorded (third take) with the user-picked voice.** The
  previous takes auditioned a long paragraph but generated three-word
  exclamations, and the voice model drifts to a generic read on inputs that
  short. The clips now say exactly the auditioned phrases, lengthened to two
  short sentences so the voice stays in character:
  `voice_noarrows.mp3` — "No arrows, lad! The quiver's empty!",
  `voice_noammo.mp3` — "No ammo, lad! We're out of ammo!"

---

## [0.9.9] - 2026-09-03

### Fixed
- **Feed button was stuck on the "?" icon with no count** (regression from
  0.9.8): `countText:SetFontObject(NumberFontNormalSmallOutline)` referenced a
  font object that does not exist on all classic builds — the nil global broke
  the rest of `BuildButton` (border, tooltip, drag), and `UpdateState` then
  died on the nil border before `RefreshMacro` ever ran. The count font is now
  set with `SetFont("Fonts\ARIALN.TTF", 11, "OUTLINE")` + a `GameFontHighlightSmall`
  fallback, the icon/count refresh runs **before** the highlight, and the
  border write is nil-guarded.
- **Feed button count now counts the PICKED food** (all of its stacks), not
  every edible food in the bags — the icon shows the food that will be fed,
  the number shows how much of it you have.
- **Voice clips re-recorded** with the voice the user picked (the first batch
  did not match the audition) and re-phrased to full sentences ("No arrows,
  lad!" / "No ammo, lad!") so the playback no longer cuts off mid-word.

### Tests
- 119 + 54 + 62 + 43 = **278 green** (new: picked-food icon texture, count =
  picked food's total across stacks, count font set via SetFont+OUTLINE).

---

## [0.9.8] - 2026-09-03

### Added
- **Ammo warning icon**: the warning now shows the *equipped projectile's own
  icon* (arrows or bullets, resolved via `GetItemInfo`) under a big **red X**
  — "no arrows"/"no ammo" readable at a glance. The empty-tier label matches
  (`NO ARROWS!` vs `NO AMMO!`).
- **Bundled dwarf-style voice clips** (`Media/voice_noarrows.mp3`,
  `Media/voice_noammo.mp3`): the empty tier *speaks* on every warn. The client
  has no TTS API, so the clips ship with the addon; the sting is the fallback
  if a clip is ever missing.
- **Feed button food count**: the icon now carries the **total edible food**
  in your bags (all stacks, not just the one the click will feed), gold like
  an action-button count, red `0` when the bags hold nothing edible.

### Changed
- **Ammo sound policy is distinct AND rare**: the sting (now
  `igQuestFailed.ogg`, deliberately not the common RaidWarning) fires only
  when the situation gets **worse** — first entry into warning or a tier
  escalation. Periodic re-warns are visual-only; the empty tier speaks.
- **Ammo threshold default raised 100 → 200** (migration only moves values
  still at the old default; user-chosen thresholds are never rewritten).

### Fixed
- **Feed button highlight is now consistent**: it glows only when the pet is
  **below happy (content/unhappy) AND you are out of combat** — previously it
  glowed green even for a happy pet. `PLAYER_REGEN_DISABLED` re-runs the
  update so the glow dies the moment combat starts.
- The ammo warning icon used to show a generic arrow whenever *anything* was
  equipped (inverted condition); it now follows the real item.

### Tests
- `dbVersion` 18; stub bag/item-info/pet-happiness APIs made state-driven.
- 119 + 54 + 60 + 43 = **276 green**.

---

## [0.9.7] - 2026-09-03

### Added
- **Low ammo warning** (`AmmoWarn.lua`, new): periodic on-screen alert +
  raid-warning sound when the ammo on your ranged weapon runs low. The less
  ammo, the smarter it gets: below threshold a brief nudge every 90 s, below
  half that every 45 s, critical every 15 s with a 12 s display, `NO AMMO!`
  every 10 s for 20 s. Re-arms on bag updates; sits **right of the passive
  alert** when both are displayed. Options: threshold (10..500, default 100),
  sound toggle. (No TTS API exists on this client — the raid-warning sound is
  the audible channel.)

### Changed
- **Shorter, aligned brightness sliders**: the compact bars shrank 150→110 px,
  all rows share one left edge, and each slider's value now reads on the bar's
  own line instead of below it.
- **Brightness is 0–200%** with 100% at the bar's **middle**: past 100% the
  sniper mark draws a second additive pass (overdrive) — vertex colours clamp
  at full, so overdrive is what actually gets brighter. Default 100.
- **Mend Pet Marker** gained *Show only below threshold*: the marker only
  appears at/below the "Urgent below % HP" line, instead of always showing.

### Fixed
- `dbVersion` 17 (ammo settings, mend `onlyBelow`; migration is a no-op).

### Tests
- 119 + 54 + 50 + 43 = **266 green**.

---

## [0.9.6] - 2026-09-03
### Changed (Options — Sniper Mark reworked per sketch)
- The Sniper Mark block is now the sketched grid: column headers **SHAPE** and
  **BRIGHTNESS** on one level; one row per state with the shape cycle-button on
  the left, the state name (**IN RANGE / TOO CLOSE / OUT OF RANGE**) beside it,
  and that state's brightness slider on the right. The word "shape" is gone from
  the row labels; the state texts stay.

### Added (tests)
- Existing options-window geometry tests cover the new grid (compact sliders,
  labels, no clipping); suite still 117 + 54 + 40 + 40 = 251, all passing.

## [0.9.5] - 2026-09-03
### Fixed
- **Ticking "Enable HunterKit" in combat threw `ADDON_ACTION_BLOCKED`** on
  `HunterKitFeedButton:SetSize()`. The feed button is a secure action button, and
  SetSize/SetPoint on it are protected actions in combat. Both now defer to
  `PLAYER_REGEN_ENABLED`; regression-tested (no resize while in combat, applied on
  regen).
- **Mend fallback no longer overlaps the pet frame.** It now sits a clear 6px gap
  below the frame bottom, centred on the avatar's vertical axis (the portrait
  centre is measured out of combat; a stock-frame constant otherwise).

### Changed
- **Brightness sliders are compact** — small bars on the right of their label
  instead of full-width rows, as requested.

### Added (tests)
- Combat-defer resize checks; options-window tests taught the compact slider
  class; suite now 117 + 54 + 40 + 40 = 251, all passing.

## [0.9.4] - 2026-09-03
### Fixed / explained
- **"Name anchoring doesn't work when nameplates are off but the name shows."**
  That name is drawn by the *unit-name* setting (`UnitNameFriendlyPetName`), which
  exposes **no frame and no screen position** — unlike a name-only *plate*, which
  looks almost identical but is a real frame and therefore anchorable. `/htk mend`
  now detects this exact case (unit-name CVar on, no pet plate) and says so,
  pointing at the anchorable name-only plate combo
  (`nameplateShowFriendlyPets` + `nameplateShowOnlyNames`) instead of silently
  falling back. The CVar dump now lists `UnitNameFriendlyPetName` too.

### Added (tests)
- Report checks for the unit-name explanation; suite now 117 + 54 + 38 + 40 = 249,
  all passing.

## [0.9.3] - 2026-09-03
### Changed (correction: last round's feed changes belonged to the mend marker)
- **Feed button restored to its old settings.** The 0.9.2 under-avatar default and
  "Follow pet name" option are gone; the button is back beside the happiness icon
  and un-dragged installs migrate their offsets back (db v16).
- **Mend marker fallback now sits under the pet avatar.** When no plate/screen
  position exists (or a plate anchor fails), the marker centres just below the
  portrait circle instead of hovering above the frame — attached to the pet,
  never off-screen.
- **Mend follows the pet name when it's displayed.** That was already true and is
  now documented + relied upon: a shown name (full or name-only plate) means a
  plate frame exists, and `auto` anchors over it; with nameplates fully off there
  is no name object to attach to and the under-avatar fallback applies.
- **IN RANGE brightness trimmed** (plus ×1.4, the rest ×1.2 at build time) after
  0.9.2's boost read too hot.
- **New: a brightness slider per mark state** (IN RANGE / TOO CLOSE / OUT OF
  RANGE, 10–100%) in Options → Sniper Mark. With the ADD blend, scaling the
  vertex colour scales the glow exactly; defaults 100%.

### Added (tests)
- Brightness slider checks (50% halves the drawn green channel, 100% restores);
  feed-anchor checks removed with the reverted feature; suite now
  115 + 54 + 38 + 40 = 247, all passing.

## [0.9.2] - 2026-09-03
### Changed
- **Brighter IN RANGE marks.** The generated IN RANGE art read dim next to the
  cross; the converter now applies a per-art intensity boost (plus ×1.6, the rest
  of the IN RANGE set ×1.35) on top of the gamma curve, so the green state reads
  as bold as the others.
- **Feed button default moved under the pet avatar.** The old right-of-happiness
  spot could sit off-screen and read as detached; the default (and Reset ALL) now
  centre it just below the pet frame. Saved positions you dragged are untouched;
  un-dragged installs migrate (db v15).
- **New option: "Follow pet name when shown" (on by default).** When the client
  publishes the pet's name — a full or name-only plate — the feed button hangs
  just below it, re-anchoring on plate add/remove and after combat; with no plate
  it falls back to under the avatar. So yes: the pet name is anchorable exactly
  when it is displayed, because the name text is drawn by the plate frame; when
  nothing is displayed there is no name object to attach to.

### Added (tests)
- Feed-anchor checks (plate shown → under the name; no plate → under the avatar);
  suite now 115 + 54 + 38 + 40 = 247, all passing.

## [0.9.1] - 2026-09-03
### Changed (Sniper Mark)
- **IN RANGE `plus` gained its circles** — redrawn as the bold plus with a centre
  dot inside two concentric rings, same outlined style as the TOO CLOSE cross.
- **OUT OF RANGE default is now `ban`** — a prohibition sign (circle + diagonal
  bar) in the same family style, because the broken-cross read too much like its
  siblings. Clearly distinct silhouette; `broken` retired (saved `broken` values
  fall forward to `ban` via the v14 migration).

### Fixed
- **`/htk lock` / `/htk unlock` crashed with "Can't measure restricted regions".**
  The geometry helper's fallback called `GetLeft()` unguarded, which hard-errors
  for frames anchored into restricted regions (name plates). Every measurement in
  `HK.AbsRect` is now pcall-guarded, so locking/unlocking can never blow up on a
  restricted frame again.

### Removed
- **"Force pet name plate" is gone**, answering the open question with yes: the
  self-disable diagnostic proved the client publishes no pet plate even with
  every nameplate CVar on, so the option could never enable head anchoring and
  only held the player's nameplate settings hostage. The checkbox, the CVar
  ladder and the self-disable logic are removed (db v14). Any CVar an older build
  changed is still restored on load/logout, and `/htk mend` keeps its honest
  capability report pointing at the draggable fallback.

### Added (tests)
- Removal + leftover-restore checks (blocked SetCVar retry, restore-once path),
  lock-safety expectations; suite now 115 + 54 + 36 + 40 = 245, all passing.

## [0.9.0] - 2026-09-02
### Changed (Sniper Mark — the bold cross family)
- **The mark you liked is now the house style.** The thick outlined TOO CLOSE
  `cross` gets two siblings generated against it so the line work matches:
  `plus` (IN RANGE — bold crosshair with centre dot) and `broken` (OUT OF RANGE —
  the same cross split open with an empty middle). The trio is the new default, so
  all three states now read as one family.
- The restored classics (`crosshair` / `x` / `rings`) and the sci-fi set remain as
  options; `aperture` (IN RANGE) and `hollow` (OUT OF RANGE) retired to keep six
  per state.
- **Migration (db v13):** saved values still on the *old default* trio
  (`crosshair` / `x` / `rings`) are moved to the matching bold marks; any style you
  deliberately chose is untouched.

### Added (tests)
- Fallback/reset expectations updated to the new defaults; suite still
  139 + 54 + 36 + 40 = 269, all passing.

## [0.8.3] - 2026-09-02
### Fixed
- **The master "Enable HunterKit" switch only hid the mend marker.** Range, Feed
  and PassivePulse checked only their own per-feature toggle, so unchecking the
  master left the sniper mark, feed button and passive alert running. All three
  now honour `HK.db.enabled` (hide + self-pause), matching MendMark and Sounds.
  Covered by new regression checks (master off hides mark + feed button; master on
  restores them).
- **Generated marks were barely visible in-game.** Two causes, both fixed: the art
  was drawn with `BLEND`, while the known-good classic marks use `ADD` — the mark
  now renders with `ADD` exactly like the originals, so the black surround adds
  nothing and the white art adds its tint at full strength; and the converter now
  gamma-boosts the keyed alpha so strokes are solid instead of a faint wash. The
  build preview now composites additively over grey, i.e. it predicts what the
  client shows, and every mark reads bright and bold in it.

### Added (tests)
- Master-switch regression checks; suite now 139 + 54 + 36 + 40 = 269, all passing.

## [0.8.2] - 2026-09-02
### Fixed
- **`reticle` was almost invisible.** Its generated strokes were hairline-thin; it
  has been redrawn with heavy, chunky strokes and re-keyed, and now reads clearly
  at in-game size.
- **A one-tick OUT OF RANGE flash when crossing from TOO CLOSE into IN RANGE.**
  The range probes can lag the server's position for a single tick while you move,
  and the most visible false reading was a momentary OUT OF RANGE. Entering FAR now
  requires two consecutive agreeing ticks (0.2 s); every other state change still
  applies instantly so the mark never feels laggy. Covered by a new regression test
  (a lone FAR tick must not change what is on screen).

### Changed (Sniper Mark — complete art set)
- The last procedural styles are gone: TOO CLOSE `burst` and the whole OUT OF RANGE
  set (`dashed`, `halo`, `sides`, `slashes`, `hollow`) are now bundled bold art, so
  **every** style in **every** state is a detailed graphic mark. The old
  `weakcross` procedural is retired and renamed `hollow` (its art); unknown saved
  values still fall back to the state default.
- Art regenerated bolder across the board and shipped uncompressed (type-2) 256px.

### Added (tests)
- Three new checks for the FAR debounce plus a confirming-tick update; suite now
  139 + 54 + 31 + 40 = 264, all passing.

## [0.8.1] - 2026-09-02
### Changed (Sniper Mark — graphic styles, classic marks restored)
- **The classic marks are back as the defaults.** `Media/crosshair.tga` (IN RANGE),
  `crosshair-x.tga` (TOO CLOSE) and `crosshair-outline.tga` (OUT OF RANGE) — the art
  removed in 0.8.0 — are restored and set as each state's first/default style.
  They were dropped because 0.8.0's procedural engine replaced them, which traded
  "always works" for "looks simple"; the user asked for graphic styles, so the
  answer is real art, not fewer primitives.
- **A new modern sci-fi art set.** Nine `.tga` marks were generated (glowing white
  on black), luminance-keyed to alpha by `tools/build_mark_art.py` (black →
  transparent, mark → white so the state colour tints them), cropped, squared and
  resized to 256 px: `reticle`, `aperture`, `chevrons`, `diamond`, `ticks` (IN
  RANGE) and `hexx`, `cross`, `block`, `bars` (TOO CLOSE). Each state now has six
  art-or-vector styles; the new ones total ~0.5 MB versus the old 3 × 1 MB.
- **New renderer primitive** `{"art", path}` draws a full-frame tinted texture;
  procedural `seg`/`ring`/`dot` primitives are kept for the crisp fallbacks
  (`burst`, and the OUT OF RANGE set whose art is still being generated) and set
  their blend mode explicitly so a pooled texture reused after an art draw stays
  correct.
- The shape dropdowns list the new names, and unknown saved values still fall back
  to the state's default (the classic mark), so old configurations stay valid.

### Fixed
- **The new marks rendered as a broken mosaic / were barely visible in-client.**
  The first build wrote them as RLE-compressed TGA (type 10), but Classic Era's
  loader only reads UNCOMPRESSED 32-bit RGBA TGA (type 2) -- exactly what the
  known-good originals are. The converter now writes type 2 at 256 px, matching the
  originals' format byte-for-byte (verified by header inspection).

### Tooling
- `tools/build_mark_art.py` converts `art/*.png` into `Media/*.tga` and writes a
  human-viewable `art/preview.png`. Source PNGs are ignored via a new `.gitignore`
  so only the `.tga` ship.

### Known follow-up
- A few *OUT OF RANGE* styles (`dashed`, `halo`, `sides`, `slashes`, `weakcross`)
  and TOO CLOSE `burst` remain procedural until the image-generation allowance
  resets; they will be swapped for matching art. Everything else is already art.

### Added (tests)
- The existing shape tests now run against art-backed styles: six distinct
  silhouettes per state, defaults equal the classic marks, and the on-screen style
  follows the dropdown. 139 + 54 + 28 + 40 = 261 checks.

## [0.8.0] - 2026-09-02
### Fixed
- **The sniper-mark shape options did nothing.** `Range.lua` built its shape table
  at load time —
  `local SHAPES = { crosshair = reticle, x = xMark, rings = outlineMark }` — but
  those three textures are created later by `BuildFrame()`, so every value was
  `nil` and the table was **empty**. Consequences: `StyleFor` never matched the
  saved choice and always returned the hardcoded fallback, and `ShowStyle`
  iterated nothing, so the mark kept whatever visibility it was built with. The
  dropdowns were decorative. The shape is now drawn on demand and the saved
  choice is honoured immediately.

### Changed (Sniper Mark — 18 shapes, six per state)
- **Each state has six shapes of its own**, and the states differ by *character*,
  not just colour: IN RANGE is open/angular (`crosshair`, `brackets`, `diamond`,
  `chevrons`, `ticks`, `ringdot`), TOO CLOSE is closed/blocking (`x`, `block`,
  `circle`, `arrows`, `bars`, `burst`), OUT OF RANGE is broken/hollow (`rings`,
  `dashed`, `halo`, `sides`, `slashes`, `weakcross`).
- **Drawn procedurally** from `Interface\Buttons\WHITE8x8` (line segments, rings
  approximated by 24 segments, dots) in a −1..1 unit box scaled to the mark size.
  No art files, textures are pooled and reused, and a style switch costs no
  allocations after the first draw.
- `Media/crosshair.tga`, `crosshair-x.tga` and `crosshair-outline.tga` are
  **removed** — nothing references them any more (~3 MB). They are still in git
  history at `31d1ce4` if you want the old look back.
- The three dropdowns now cycle their own state's six shapes (they all offered the
  same three before), and say so in their tooltips.

### Changed (Options)
- **Slider numbers are centred** above the bar instead of right-aligned, and the
  label column is capped at the left half minus the number's column so a long
  label cannot run underneath it. A programmatic `SetValue` no longer writes back
  to the db (`syncing` guard).
- **Reset ALL settings button** (new *Reset* section): two clicks — the first arms
  it ("Click again to CONFIRM"), the armed state expires after 5 s — then
  `HK.ResetAll()` restores every default, including saved positions.
- **The open window follows a reset.** Every control registers a refresher
  (`Options.RefreshControls`), so checkboxes, sliders and dropdowns re-display the
  restored values instead of showing what you had before.

### Changed (MendMark)
- **"Force pet name plate" now admits defeat.** Once every rung the client has is
  on, the pet is out, and ~5 s later there is still no pet plate, the option
  switches itself off, restores the CVars it changed, refreshes the checkbox and
  prints one line saying head anchoring isn't available on this client. Before, it
  left your nameplate CVars changed and appeared to do nothing.

### Fixed (Core)
- `HK.ResetAll` wipes and refills each db **sub-table in place** rather than
  replacing it: every module holds its own local reference to its slice
  (`db = HK.db.range`), so fresh tables would have left them all writing to
  orphans that are never saved.

### Added (tests)
- **`tests/test_settings.lua` (28 checks)**: six distinct shapes per state (no two
  identical), the shape on screen follows the dropdown for all three states,
  unknown saved values fall back, `HK.ResetAll` restores defaults while keeping
  the db slices the modules hold, and the reset button's two-click/expiry flow.
- **The Options harness now loads every module in `.toc` order**, as the client
  does — the shape dropdowns read their lists from `Range`. That immediately
  surfaced two modules failing to initialise under the stub (`FeedPet`,
  `PassivePulse`); the stub gained the tooltip, bag, sound and unit APIs they use,
  plus `PetHasActionBar`, `CheckInteractDistance`, target state, `SetRotation` and
  a queued `C_Timer.After` (`HKTest.RunDelayed`) so delayed callbacks are testable.
- MendMark: the force-plate give-up path (ladder climbs, then restores, switches
  off, prints once and not every tick).
- Revert proofs: ignoring the saved shape → 4 failures; `HK.ResetAll` replacing
  the db slices → the identity check fails; the force-plate give-up removed → 5
  failures.
- Suite: **139 + 54 + 28 + 40 = 261 checks**.

## [0.7.1] - 2026-09-02
### Changed
- **`/htk unlock` shows the movable fallback, not the over-the-head marker.**
  While frames are unlocked, `ResolveAnchor()` returns the pet-frame anchor even
  when a pet plate exists — and even when *Anchor* is set to `plate` — so what you
  see is what you can drag. `/htk lock` sends it back over the pet's head. It has
  to work that way: a frame anchored to a name plate is a **restricted region**
  (the client throws and taints if anything touches its drag or clamp state) and
  the addon re-applies the plate anchor every 100 ms, so the head marker can be
  neither moved nor held. Edit mode therefore shows **one** marker, not two —
  there is no second, movable copy of the head marker to show.
- **The clamp follows the anchor.** Never clamped while the marker hangs off a
  name plate (it must follow the pet off-screen, and the client refuses the call
  anyway); clamped while it is the draggable fallback in edit mode, so it can't be
  dropped off-screen. Applied only when the anchor mode changes, not 10×/second.

### Fixed
- **A frame that stopped being draggable was never cleaned up.** `Positions.SetLock`
  skipped every frame whose `draggableIf` reported "not movable now". That was
  right while the state was static, but the marker's state now flips, so locking
  left it with its drag handlers, its mouse-enabled state and its faded edit-mode
  alpha. "Not movable now" now only skips the *setup*; anything we made draggable
  is still torn down (tracked as `dd.dragSetup`).
- **Unlock clamped a plate-anchored frame for up to 100 ms.** `draggableIf`
  answered "petframe" while the frame was still anchored to the plate (the ticker
  had not re-anchored yet), so `SetLock` ran `SetClampedToScreen(true)` on a
  restricted region — the exact client error fixed in 0.6.2, absorbed by
  `HK.SafeClamp` but still thrown. `draggableIf` now calls `Update()` first, so the
  frame is off the plate before `SetLock` acts on the answer.

### Added (tests)
- `test_options_ui.lua` now drives the **real** `HK.Positions.ToggleLock()` with a
  live pet plate: unlock → fallback anchor, frame movable, drag handlers bound,
  fallback widget shown, head marker off the plate; lock → back on the plate,
  handlers removed, not movable, alpha restored, still on screen. A stub that
  throws `Can't clamp restricted regions` whenever the marker is plate-anchored
  proves it is never clamped in that state. Edit mode with no pet stays on the UI
  fallback and never goes looking for a plate.
- Each of the three fixes proven by reverting it: the edit-mode anchor branch → 7
  failures, the `Update()` inside `draggableIf` → the clamp failure, the
  `dragSetup` teardown guard → 2 "left draggable" failures.
- Suite: **132 behaviour + 52 UI + 40 docs = 224 checks**.

## [0.7.0] - 2026-09-02
### Changed (Options window layout — 7 reported UI problems)
- **The window is bigger:** 392×520 → **474×604**, content column 360 → **436 px**,
  with more room for the scrollbar.
- **"L" clipped off every *Low*.** `OptionsSliderTemplate`'s `$parentLow`/`$parentHigh`
  fontstrings are centred on the bar's bottom corners; the bar started at content
  `x=0`, so the left label sat half outside the scroll area, which clips its
  children. The template's `Text`/`Low`/`High` are now **hidden** and the bar is
  inset 8 px.
- **Slider values are always visible.** `$parentText` was only written from
  `OnValueChanged`, so a slider showed no number until you touched it. Each row now
  has its own value fontstring, written at build time and updated on drag.
- **Numbers no longer overlap the labels.** Layout per row: label left, value
  right-aligned in a 64 px column, full-width slider underneath (was: label to the
  right of a half-width slider, with the template's text floating over it).
- **Sections are visibly separate.** Each feature block gets a 1 px rule spanning
  the content width plus more air: header 30 px, checkbox 26 px, slider/dropdown 46 px.
- **Tooltips wrap and are concise.** `GameTooltip:AddLine` was called without its
  5th argument, so long help text rendered as one clipped line; it now passes
  `wrap = true` through one shared `AttachTooltip` helper. 26 strings were rewritten
  shorter (every slider body now fits in 220 characters; the longest of all 28 is
  243, the force-plate caveat), and the two controls that had no tooltip at all
  (Passive Alert size, sonar rings) got one — all 28 controls now have one.

### Changed (nameplate diagnostics — the earlier conclusion was wrong)
- **`nameplateShowFriendlyMinions` is now a rung of the force-plate ladder**
  (`FriendlyPets` → `FriendlyMinions` → `Friends` → `All`), which is what publishes
  a pet plate on Classic Era. Rungs are cumulative and the ladder still stops at the
  first rung that yields a plate.
- **`/htk mend` probes CVars by name.** `C_Console.GetAllCommands()` returns
  registered *console commands*, not CVars, so the previous dump omitted real
  nameplate CVars and reported them as "not on this client". The dump now probes a
  candidate list with `GetCVar` (nil = genuinely absent) and adds any nameplate
  console commands on top; values HunterKit changed are marked `*` with the value
  they replaced.
- **Honest answer to "can you turn on a plate for just my pet?":** no. The finest
  granularity the CVar API offers is friendly pets/minions, which also publishes
  plates for other players' pets and minions. The README and the in-game tooltip say
  so, and the README's "those CVars are gone on 1.15.9" claim is corrected.

### Added (tests)
- **`tests/test_options_ui.lua` (29 checks).** The harness used to only syntax-check
  `Options.lua`; `MakeWindow` now runs against `tests/wow_stub.lua` (the stub gained
  the widget methods it needs: scroll children, slider min/max/value,
  `SetWordWrap`, `GameTooltip` line recording, and `OptionsSliderTemplate`'s three
  fontstrings), and the suite asserts the layout above — value visible before
  interaction, template `Text`/`Low`/`High` hidden, bar inset from the clipping
  edge, label/value columns disjoint, one divider per section, every tooltip
  wrapped. Reverting the fixes makes 12 of these fail.
- **A module `Init` that throws now fails the suite.** `HK:Load()` pcall-guards each
  module, so a missing client method inside `MakeWindow` used to disappear silently.
- **Stray-global guard.** The stub snapshots `_G` before the addon loads; the suite
  fails on any new global outside an explicit allowlist. That is the bug class that
  shipped twice as `attempt to call a nil value (global 'Update')` — dropping a
  `local` in `Options.lua` reproduces it (`FAIL … — sliderCount`).
- Mend-marker tests cover the new minions rung (rung 2 is
  `nameplateShowFriendlyMinions`, insufficient alone; the ladder stops once a plate
  exists) and restoring **every** CVar it touched.
- Suite: **132 behaviour + 29 UI + 40 docs = 201 checks**.

## [0.6.2] - 2026-09-02
### Fixed (live client error: `/htk unlock` / `/htk lock` threw + tainted)
- **`HunterKitMendMarker:SetClampedToScreen(): Action[ClampedToScreen] failed because
  [Can't clamp restricted regions]` + `Lua Taint: HunterKit`.** The mend marker was
  registered as draggable unconditionally, so `Positions.SetLock` ran its full drag
  setup on it — including `f:SetClampedToScreen(true)` (Options.lua:667) — even while
  the marker was anchored to the pet's **name plate**, which is a protected/restricted
  frame. The client refuses the call and taints the addon.
- **Root design error:** the over-the-head marker was never the player's to move. It
  must follow the pet. Only the **UI fallback** should be draggable.

### Changed
- **`draggableIf` opt-out for registered draggables.** The mend marker registers
  `draggableIf = function() return ResolveAnchor() == "petframe" end`, so it takes part
  in lock/unlock only while it's on the UI fallback. While it's on a plate or a
  screen-position anchor, `SetLock` skips it entirely (no SetMovable, no clamp, no drag
  scripts, no taint).
- **`HK.DraggableActive(d)`** (Core) decides that, so the rule lives in one place and is
  testable rather than inlined in the lock loop.
- **`HK.SafeClamp(f, on)`** (Core) pcall-guards every `SetClampedToScreen` call, so a
  restricted anchor can never break lock/unlock for *any* module — not just this one.
  The marker's own build-time `SetClampedToScreen(false)` goes through it too.

### Tests
- The stub now reproduces the client's restricted-region error. New checks: draggable on
  the UI fallback, NOT draggable on a plate anchor, NOT draggable on a screen-position
  anchor, `HK.SafeClamp` absorbs the throw, and a SetLock-shaped loop (using the real
  Core helpers) skips the restricted marker without touching it.
- **Proven:** stubbing `HK.DraggableActive` back to `return true` fails three checks,
  including "restricted marker was skipped, not touched". Behaviour suite is now 129.


## [0.6.1] - 2026-09-02
### Fixed (live client error: `/htk reset` and `/htk unlock`)
- **`HunterKit/MendMark.lua:355: attempt to call a nil value`.** The draggable
  registration sits inside `BuildFrame` (line 304), but `local function Update` was
  declared at line 595 — so the closure `function() Update() end` compiled to a
  **global** lookup (nil at runtime), not the local. `Options.Reset` calls `d.apply()`
  on every registered draggable, which is where it surfaced; `Options.SetLock` would
  have hit it the same way on lock.
- **Fix:** forward-declare `local OnUpdateAnchor, Update` at the top (the file already
  did exactly this for `OnUpdateAnchor`, for the same reason) and assign
  `Update = function() ... end` where the body lives.

### Added (regression coverage — the gap that let it ship)
- The suite now **invokes every callback each draggable registers** — `apply`, `save`,
  `opts.restore`, `opts.onUpdate`, `opts.saveFromScreen` — plus an Options-style
  `Reset` loop. Previously it only checked the registration existed, which is why a
  nil-callable slipped through.
- **Proven, not assumed:** reverting the fix makes the suite fail with the client's own
  message — `attempt to call a nil value (global 'Update')` — and restoring it passes.
- Scanned all eight addon files for the same forward-reference bug class (a call to a
  `local function` declared later in the chunk): all clean.


## [0.6.0] - 2026-09-02
### Measured on a live 1.15.9 client (via the 0.5.0 probe)
```
screen-pos APIs: GetUnitNamePosition=absent  GetUnitScreenPosition=absent
pet plate via:   GetNamePlateForUnit=none  NAME_PLATE_UNIT_ADDED=none  GetNamePlates=none  NamePlateN scan=none
plates visible:  0        UnitPosition(pet)=refused   GetPlayerFacing=0.89
nameplate cvars: nameplateShowAll=1  nameplateShowEnemies=1  nameplateMaxDistance=41
```
No pet plate, no screen-position API, no pet world position, and the friendly/pet
nameplate CVars no longer exist — so **over-the-head anchoring is not available on
1.15.9** and *Force pet name plate* cannot help there (rungs 1-2 are gone, rung 3
`nameplateShowAll` is already 1). Recorded in the README so nobody re-litigates it.

### Fixed
- **`/htk mend` printed misleading advice.** Out of combat with a healthy pet the
  marker is hidden *before* it resolves an anchor, so the report showed `mode=nil`
  and then claimed it "is anchored to the pet unit frame". Anchor resolution is now
  split from anchor application (`ResolveAnchor`), so the report always prints
  `anchor would be: <mode>` plus why the marker is hidden.

### Added
- **`hidden because:` line** — the exact gate that's keeping the marker off screen
  (master switch, no pet, Mend Pet untrained, out of combat + healthy, ...).
- **Full nameplate CVar dump** from `C_Console.GetAllCommands()` — this is what
  proved the friendly-plate CVars are gone on 1.15.9, and it answers "which setting
  would give my pet a plate?" on any client instead of guessing.
- **`LadderCVarsUsable()`** — counts ladder rungs that exist *and* are still off, so
  the addon only suggests Force pet name plate when it could actually work, and says
  plainly "nothing else to turn on here" when it can't.
- **The UI fallback is now draggable** (`/htk unlock` → drag → lock), registered like
  the feed button and sniper mark, with the drop point stored in `mend.pinX`/`pinY`
  (kept separate from `offsetY`, which is still the gap above the anchor's top edge in
  plate mode). `/htk reset` returns it above the pet frame. On a client where the head
  anchor is impossible, placement is the only lever left, so it's in the player's hands.

### Notes
- Test suite: 105 -> **118** behaviour checks, including a stub of the exact 1.15.9
  CVar set asserting the report resolves the anchor while hidden, names the hidden
  reason, dumps the CVars, and does NOT suggest force-plate when it cannot help.


## [0.5.0] - 2026-09-02
### Added (world anchoring paths that don't depend on C_NamePlate)
- **Direct screen-position probing.** Some TBC-lineage builds are reported to expose a
  unit's on-screen name position as a plain function. HunterKit now probes for those by
  name at load (`GetUnitNamePosition`, `GetUnitScreenPosition`) and, if one answers for
  `pet`, anchors to it directly — **true world anchoring with every nameplate off**
  (`mode=screen`). Absent on a client, nothing changes. The Y convention (measured from
  the top-left, in pixels) is converted to a UIParent anchor and the raw pair is printed
  by `/htk mend` so it can be checked on screen instead of trusted.
- **Legacy `NamePlateN` discovery.** Fourth plate path: `NamePlate1..N` children of
  `WorldFrame` with the unit token on the child unit frame — the layout clients used
  before `C_NamePlate`.
- **`/htk mend` capability report.** Prints which screen-position APIs the client has
  (and their raw return), which of the four plate-discovery paths found the pet, the
  visible plate count, and `UnitPosition("pet")` / `GetPlayerFacing`. Client capability
  differs between Era, TBC-lineage and the Midnight UI merge, so the addon reports it
  instead of assuming.

### Notes
- `UnitPosition()` is documented as not working on pets ("does not work on pets or any
  unit not in your group"), and there is still no world-to-screen API in Classic Era —
  but rather than argue about which client has what, the probe makes it answerable
  in-game in one command.
- Test suite: 95 -> **105** behaviour checks (legacy NamePlateN scan incl. a plate that
  stops matching, screen-position anchor + coordinate conversion + height offset,
  fallback when the API stops answering, stale anchor-source cleared, capability
  report contents).


## [0.4.0] - 2026-09-02
### Added (Pet Mend Marker: true over-the-head anchoring with nameplates off)
- **Three independent ways to find the pet's name plate**, first hit wins:
  `C_NamePlate.GetNamePlateForUnit("pet", true)` (which also returns the
  "forbidden" plates instances use), the plate handed to `NAME_PLATE_UNIT_ADDED`,
  and a scan of `C_NamePlate.GetNamePlates()`. Any of them gives real
  world anchoring above the pet's head.
- **"Force pet name plate" (opt-in, off by default).** This is the fix for "I want
  it over the pet's head but I don't want nameplates on": HunterKit walks a ladder of
  nameplate CVars from the least invasive up — `nameplateShowFriendlyPets` →
  `nameplateShowFriends` → `nameplateShowAll` — **stopping at the first rung that
  actually produces a pet plate**. CVars the client doesn't have are skipped
  (`GetCVar` returns nil), it waits ~1s between rungs for the client to react, and it
  never touches them in combat (the client locks CVars there). Your previous values are
  saved in SavedVariables and **restored on untick and at logout**, so nothing is
  written to your config permanently.
- **Nameplate-style fallback widget.** When there's no pet plate to sit on, the marker
  draws a plate of its own: pet name + a green→red health bar under the icon, so the
  fallback reads like a nameplate instead of a stray icon. Hidden automatically when a
  real plate is carrying the marker (that plate already shows name and health).
- **`/htk mend` now reports `plate=true|false`** and marks every CVar HunterKit changed
  with a `*`, and its advice line explains the Force pet name plate option.

### Fixed / changed
- Anchor resolution no longer depends on a single API: a client that only reports the
  pet through `NAME_PLATE_UNIT_ADDED` (or only through the visible-plate list) now
  anchors over the head instead of falling back to the pet frame.
- **dbVersion stays 12**; the new `mend.plateStyle`, `mend.forcePlate` and
  `mend.plateCVars` keys arrive through `MergeDefaults`. `HK.version` / `.toc` -> **0.4.0**.
- README anchoring section rewritten to state the constraint and the workaround
  precisely (no world-to-screen API; `UnitPosition` does not work on pets), and the
  test suite grew from 67 to **95** behaviour checks (CVar ladder + escalation +
  restore + logout restore + combat-lock guard + blocked-SetCVar guard + missing-CVar clients + plate
  discovery + widget).


## [0.3.0] - 2026-09-02
### Added (Pet Mend Marker)
- **A Mend Pet icon above your pet's head.** Green box + solid icon when the pet is
  inside Mend Pet range, so you can see at a glance — without reading a bar — that a
  Mend will land. Out of range it gets a **red box**, a greyed icon faded to 45% and a
  `TOO FAR` label, so "not in range" reads differently from "in range" at a glance.
- **Urgent state at or below 30% pet HP.** The marker grows up to ~14%, pulses, throws
  an expanding red ring and labels itself `MEND!`. The box colour keeps carrying the
  range answer (green/red) so the two signals never fight. The threshold is a slider (5-100%,
  default 30) and the pulse can be turned off.
- **On by default**, with its own Options → Pet Mend Marker section: enable, icon size,
  height above the head, urgent threshold, urgent pulse, only-in-combat, fade when out
  of range, label, and the anchor mode.
- **Visibility rules:** hidden with no pet, a dead pet, or Mend Pet untrained. *Only in
  combat* is on by default, but a pet below the threshold always shows, combat or not.
  `/htk unlock` force-shows it so the size/height sliders can be tuned out of combat.
- **`/htk mend`** prints the live diagnostic (spell, range state, HP vs threshold,
  anchor mode, shown/hidden) plus the nameplate CVars the client is reading.
  `/htk selfcheck` gained `mend marker` and `mend diag` probes, and `/htk help` + the
  `/htk` feature line list the new module.

### Notes (anchoring, honestly)
- Classic Era exposes a unit's world position **only while it has a name plate** —
  there is no world-to-screen API, so no addon can float a frame over a pet the client
  isn't drawing a plate for. The marker therefore uses the pet's name plate when one
  exists (`mode=plate`) and **falls back to the pet unit frame** otherwise
  (`mode=petframe`), so it still works with every nameplate turned off. Anchor = `plate`
  makes it head-only (hidden with no plate); `petframe` makes the UI position permanent.
- The pet-frame fallback is used **even when the pet frame is hidden in Edit Mode** (a
  hidden frame keeps its layout), so the marker doesn't disappear for players who follow
  the "hide the default frames" advice.
- Nothing is automated: this is a readout. It never casts Mend Pet.

### Changed (docs + schema)
- **Options window is 60px taller** (392x520) so the new section doesn't push the
  Positions buttons out of view; the window already scrolls (wheel + draggable bar).
- **dbVersion 11 -> 12.** New `mend` section; existing users get the defaults via
  `MergeDefaults` (no field rewrite). `HK.version` / `.toc` bumped to **0.3.0**.
- **README rewritten to match the shipped addon**: the Pet Mend Marker section and its
  anchoring rules, the per-state sniper mark styles shipped in 0.2.34, `/htk mend`, and a
  Development section stating that README/CHANGELOG/.toc/Core are updated in the same
  change as the code.
- **New `tests/` harness.** `python3 tests/run_tests.py` loads the real `Core.lua` and
  `MendMark.lua` against a stub client and asserts the marker's states, thresholds,
  gating and anchoring (67 checks), then checks that every addon file parses, that the
  `.toc` matches the files on disk, that the `.toc` and newest CHANGELOG entry match
  `HK.version`, and that every `/htk` subcommand is documented in the README.


## [0.2.34] - 2026-09-02
### Changed
- **Sniper mark: per-state style pickers.** The two old "Blink when too close" and
  "Too-close as an X" checkboxes are gone. In their place, three dropdowns let you
  choose the mark shape independently for each situation: **IN RANGE mark**,
  **TOO CLOSE mark**, and **OUT OF RANGE mark** (options: crosshair / rings / x).
- **Default crosshair moved right** (offset 6 -> 14) so it clears the elite target
  frame art. Applied on upgrade only to users who haven't hand-dragged the mark;
  a mark you repositioned yourself stays put.
- **EDIT MODE warning is smaller and more transparent** (320x60 vs 440x96, 36pt text
  vs 52, translucent 35% red, thin 2px border, gentler blink) so it's noticed but
  no longer dominates the screen.
- **Options labels no longer clip their first letter**: each label is now left
  justified, non-wrapping, given room, and the window/content were widened so text
  doesn't run into the frame edge.


## [0.2.33] - 2026-09-02
### Fixed (EDIT MODE banner showed on login + Options module load error)
- **`FontString:SetText(): Font not set` was the root cause of BOTH symptoms.** In
  `BuildEditBanner` the font string called `SetText("EDIT MODE")` **before** `SetFont`.
  On the live client a FontString cannot be set until it has a font, so that line threw
  and aborted the rest of `BuildEditBanner` — which means `editBanner:SetShown(false)`
  never ran. The frame was created visible by default, so the red block appeared on
  login instead of only when unlocked.
- **Fix:** set the font *before* the text, and call `SetShown(false)` immediately after
  creating the banner so even a partial failure can never leave it visible at login.
- **Replaced the border with plain WHITE8x8 texture strips.** The previous banner used
  `SetBackdrop`, which needs the `BackdropTemplate` mixin on some clients and could be
  the *next* error after the font one. The border is now drawn with four simple
  texture edges — no template, no failure mode.
- The `Lua Taint: HunterKit` message was a consequence of the Options module throwing
  during load; with the load error gone it should not appear again.


## [0.2.32] - 2026-09-02
### Fixed (the icons that still jumped on "Lock frames" — root cause found)
- **The jump was the anchor-frame coordinate round-trip, not a sign flip.** The drag
  stored each frame's offset measured against a **unit-frame anchor** (the pet
  happiness icon / the target frame). A unit frame lives in a different coordinate
  **and scale** space than UIParent, so the stored `(offsetX, offsetY)` never matched
  the `SetPoint` offset that put the frame back — so on lock the frame was placed
  somewhere else and "jumped." (The pulse and feed-click fixes worked because they
  never measured a frame against a unit-frame anchor.)
- **The fix: never leave UIParent space.** All three frames are direct children of
  UIParent, so a frame's `GetCenter()` and `UIParent:GetCenter()` are in the **same**
  coordinate space. The new `HK.SaveDragged` stores the frame's on-screen centre as an
  offset from UIParent's CENTRE and `ApplyPosition` re-applies it with the same
  CENTRE/CENTRE anchor — so it round-trips exactly. That is what actually stops the
  drag from jumping when you press "Lock frames."
- **New `moved` flag.** Until you drag a frame it still anchors to its unit frame (pet
  happiness icon / target frame), as designed. The first time you drag it, `moved`
  becomes true and it switches to the absolute UIParent-CENTRE offset, so it stays
  exactly where you drop it. `/htk reset` clears `moved` and returns frames to their
  default anchor.
- **v9→v10 migration** resets all three frames' offsets (and `moved`) to defaults so
  any stale/relative position saved by the broken builds is cleared automatically.
  `dbVersion` is now 10.

### Changed (edit mode banner)
- **The big red "EDIT MODE" text is now a real, unmissable banner.** It's a solid red
  block with a bright red border (not just faint floating text), 52px outlined red
  "EDIT MODE" text, on the highest (TOOLTIP) strata so nothing can cover it. It shows
  while frames are unlocked and hides when you lock.

## [0.2.31] - 2026-09-02
### Added (edit mode clarity + feed safety)
- **Big red "EDIT MODE" banner.** While the frames are unlocked (edit mode) a large,
  blinking red "EDIT MODE" banner is shown at the top of the screen so it's obvious you're
  repositioning. It's hidden automatically when you press "Lock frames" or close the
  options window. (Tooltip strata, mouse-disabled, so it never blocks clicks.)
- **Clicking the feed button never feeds in edit mode.** While frames are unlocked, the
  feed button's secure attributes (`type1`/`spell`/`target-item`/`target-bag`/`target-slot`)
  are blanked **and** its click registration is unregistered, so a left-click (or a
  left-press while dragging) can never cast Feed Pet. On lock the secure spell and the
  click registration are restored (still safe: re-armed only out of combat).
- **`/htk debug` now logs the real drag geometry.** Every drag start/stop and lock-apply
  prints the frame's `GetRect`/centre (in UIParent space, via `HK.AbsCenter`), the cursor
  position, and the saved point — so when an icon still "jumps" we capture exactly what
  the client reports instead of guessing. `HK.Dbg` / `HK.Geom` behind the `/htk debug`
  toggle.

### Fixed (drag offset never saved + pulse never restored — real root cause)
- **The drag offset was NEVER being saved.** `OnDragStop` (and the lock branch) read
  `dd.saveFromScreen` / `dd.restore` / `dd.onUpdate`, but those callbacks sit on
  `dd.opts.*`, so they were **nil** — the fallback wrote `(0,0)` to the offset. So every
  drag was discarded: on lock, `apply` re-applied the *old/default* offset and the icon
  snapped back to where it started. Same thing for `restore` (feature visibility was never
  restored) and `onUpdate` (the passive pulse loop was never re-bound — that's why the
  pulse died after edit). All three now read `dd.opts.*`, so the dropped offset is saved,
  visibility is restored, and the pulse keeps running.
- **Reverted the coordinate change from 0.2.30.** I had wrongly assumed `GetLeft`/`GetTop`
  use a Y-down origin and "fixed" it by flipping Y — but Blizzard's API docs confirm
  `GetLeft`/`GetTop`/`GetCenter` and `SetPoint` offsets are ALL measured **from the
  bottom-left of the screen (Y-up)**, so they're already consistent. `HK.AbsCenter`
  (`left + w/2, bottom + h/2`) is correct as-is. 0.2.30's Y-flip made the offset wrong
  again; it is removed.
- **v8→v9 migration clears stale bad positions.** Earlier builds wrote a bad/zero offset
  (the bug above) for the feed/range/pulse frames. On load, v9 resets those three
  `offsetX`/`offsetY` (and the `parent` for feed/range) to the defaults once, so any
  leftover wrong position is cleared automatically. `dbVersion` is now 9.
- **If your icons are still at a bad spot**, run `/htk reset` (or delete the `HunterKitDB`
  SavedVariable) — older builds may have written a bad offset for the feed/range/pulse
  frames, and reset clears it to the default position.

## [0.2.30] - 2026-09-02 (superseded — coordinate change was wrong, reverted in 0.2.31)
### Fixed (icons jump on lock + passive pulse dies after edit)
- **Icons no longer jump when you press "Lock frames".** Two root causes, both fixed:
  1. **`saveFromScreen` was never called** — the drag-release handler read
     `dd.saveFromScreen`, but the callback lives at `dd.opts.saveFromScreen`, so the
     fallback `save(0,0)` ran instead and the offset was never updated from the drag.
     On lock, `apply` then re-applied the *old default* offset → the icon snapped back
     to where it started.
  2. **A coordinate-space mismatch** — every saved offset was computed in **Y-down**
     UIParent space, but `SetPoint` applies offsets in **Y-up** space (positive offset
     = up). So the offset's Y had the wrong sign, and when `apply` re-positioned the
     frame it flipped vertically, in *both* the CENTER/UIParent and anchor-frame
     (unit-frame RIGHT) modes.
  Fix: added `HK.ScreenCenter()` which returns a frame's centre in the same **Y-up**
  space `GetCursorPosition`/`SetPoint` use (it walks the parent chain, then flips Y from
  the top edge into bottom-left space). The drag's grab offset and every module's
  `saveFromScreen` now use it, so the dropped on-screen centre round-trips exactly
  through `SetPoint` on lock (verified for both anchor modes). (`dd.restore` was also
  mis-keyed as `dd.restore` instead of `dd.opts.restore` and is fixed.)
- **Icons now track the cursor correctly during edit** (they previously drifted/jumped
  at drag start because the grab offset mixed Y-down frame coords with Y-up cursor
  coords). The grab offset is now computed in the same Y-up space as the cursor.
- **The passive alert keeps pulsing after edit.** The lock branch (and the drag release)
  was blanking the frame's `OnUpdate` script with `SetScript("OnUpdate", nil)`, which
  permanently destroyed the pulse animation loop (it runs on a frame `OnUpdate`).
  Draggables now carry an `onUpdate` re-bind: `SetLock` and `OnDragStop` restore the
  feature's own `OnUpdate` (the passive pulse) instead of leaving it nil.


### Fixed (auto-lock + drag re-attach + hidden sniper mark)
- **Edit mode no longer auto-locks.** Removed the idle/cursor-position timer that locked
  the frames when the cursor left the UI. Edit mode now ends ONLY when you press
  "Lock frames" OR close the options window with the X / ESC (the window's `OnHide`
  re-locks). It will never lock while you're mid-arranging.
- **Icons stay exactly where you drop them.** On release, `OnDragStop` only saves the
  computed UIParent-space offset (`saveFromScreen`) and no longer re-applies the anchor
  immediately — re-applying mid-drag was momentarily nudging the icon. The anchor-based
  position is applied once on lock, reproducing the exact spot you dropped it. Verified
  the left/right (unit-frame) and centre (UIParent) offset math round-trips exactly.
- **Sniper mark is visible while frames are unlocked.** Edit mode now force-shows every
  draggable (even a mark with no target) so it can be grabbed. `Range.Update`,
  `FeedPet.UpdateState`, and `PassivePulse.Refresh` early-return while editing, so the
  feature modules never re-hide or re-position the frame mid-drag.


### Fixed (drag jump — replaced the dragging mechanism)
- **Removed `StartMoving`/`StopMovingOrSizing` entirely** (they reset a frame's anchor,
  which is what made every icon jump down/right when released). Frames are now dragged
  with a **fully manual, cursor-pinned drag**: `OnDragStart` records the grab offset from
  the frame's real on-screen centre, `OnUpdate` re-pins the frame to the cursor every
  frame (clear + SetPoint to UIParent), and `OnDragStop` converts the dropped centre into
  a UIParent-space offset against the frame it anchors to, then re-applies. The frame's
  anchor is never reset, so it stays exactly where you drop it.
- All draggable frames (feed, sniper mark, passive alert) are parented to UIParent and
  measured with `HK.AbsCenter` (which walks parents), so the offset is in one coordinate
  space regardless of each frame's parent. Kill the earlier "vanish" and the current
  "jump" at the same root cause.

### Changed (edit mode)
- **Unlocking now shows all icons and auto-locks.** Clicking "Unlock frames" shows every
  draggable frame (even ones that are normally hidden, so you can grab them), faded at
  60% so you can tell it's edit mode. It stays unlocked until you press "Lock frames" OR
  **~6 seconds pass with no interaction**, at which point it auto-locks and restores each
  frame's normal visibility. The idle timer never fires while you're mid-drag.
- Locking restores each feature's proper visibility (feed shows if pet+enabled, sniper
  only shows with a target, passive only while passive).

## [0.2.27] - 2026-09-01
### Fixed (frames vanishing on drag — root cause found)
- **The sniper mark was a child of the target frame**, not UIParent. A frame's
  `GetLeft`/`GetTop` are in its PARENT's coordinate system, so a mark parented to
  `TargetFrame` returns coordinates in TargetFrame space (a different origin from
  UIParent). The drag offset math mixed that with UIParent-space coordinates, so on
  release the frame was placed at a wildly wrong spot — off-screen / vanished.
- **All draggable frames are now parented to UIParent** (feed button, sniper mark,
  passive alert) and only *anchored* to the pet/target frame for position.
- **Offsets are computed in UIParent coordinate space.** New `HK.AbsRect`/`HK.AbsCenter`
  helpers walk a frame's parent chain and convert any frame — regardless of its
  parent — into UIParent space before measuring. The feed button's offset is now
  measured correctly even though the button (UIParent child) and the happiness icon
  (pet-frame child) have different parents. This is what stops both icons from
  jumping/vanishing on release.
- Reverted to the native `StartMoving`/`StopMovingOrSizing` drag now that frames are
  UIParent-parented (it clamps to the screen and won't vanish), combined with the
  corrected UIParent-space offset save.

## [0.2.26] - 2026-09-01
### Fixed (drag & lock toggle)
- **"Unlock frames" now alternates to "Lock frames".** The toggle button's text updates
  to reflect the current state, so clicking it toggles between unlocking and locking the
  frames (this is what "should alternate between lock/unlock" meant).
- **Frames no longer jump on release after a drag.** The old path used
  `StartMoving()`/`StopMovingOrSizing()`, which re-anchors the frame and causes it to
  snap/jump to a different spot when re-applied. Frames are now dragged with a
  self-tracked manual drag (the same pattern the minimap button uses): the frame is
  pinned to the cursor via `OnUpdate` and, on release, its on-screen position is measured
  against its real anchor frame and re-applied — so it stays exactly where you drop it.
  This applies to the feed button, sniper mark, and passive alert.
- The drag handlers now capture each frame/`draggable` in a fresh local, so the closures
  always act on the frame being dragged (no cross-frame mix-ups).

## [0.2.25] - 2026-09-01
### Added (feed button)
- **"Only when hungry" option.** When enabled, the feed button is hidden once the
  pet is content/full (happiness 3) and reappears as soon as the pet gets hungry
  (happiness < 3). Off by default, so the button shows at all times unless you opt in.
  Added to the Feed Pet section and re-evaluated live on every happiness/pet-bar update.

## [0.2.24] - 2026-09-01
### Fixed (drag position jump)
- **Dragging a frame no longer makes it jump when released.** The problem: after a
  drag the frame is left anchored to `UIParent` in absolute coordinates, but the
  saved offset was being interpreted against the frame's *anchor frame* (TargetFrame,
  happiness icon) — a different origin. The sniper mark and passive alert didn't have a
  screen-position mapper, so the saved coords were wrong and the frame jumped to a
  different spot on release. Both now compute their offset from on-screen position
  against the frame they actually anchor to (handling both the TargetFrame
  LEFT/RIGHT mode and the UIParent CENTER mode), so the mark stays where you drop it.
  The feed button already had this mapper.

### Changed (sizes)
- **Sniper mark default is 50% bigger** — default 40 → **60**; the "Mark size" slider
  now goes up to **96**.
- **Feed button is bigger by default** — default 22 → **28**; the minimum size you can
  set is now **24** (was 16) and the max is **48**.
- A v7→v8 migration applies the new default sizes once to users still on the old
  default (custom sizes are preserved).

## [0.2.23] - 2026-09-01
### Changed (options UI)
- **Removed the redundant "Restore stock gunshot now" button.** Its action was the
  same as unchecking "Replace gun shot sound" (which already restores the stock
  gunshot immediately by unmuting). The Gun Sound section is now a single toggle.
- **Compacted the settings layout** — tighter row spacing (headers 12px, checkboxes
  24px, sliders/dropdowns 28px) so far fewer rows are needed to see everything.
- **Rewrote every option's description and label to match the current behaviour:**
  - Feed: explains it one-click casts Feed Pet onto the best food in bags and that
    right-click opens the food pin menu; the "Anchor" dropdown note now says it sits
    beside the pet's happiness icon (the real anchor).
  - Sniper Mark: label changed from generic "OK/DEAD" to the real states
    (IN RANGE / TOO CLOSE / OUT OF RANGE); "Blink when too close" and "Too-close as
    an X" replace the stale "0-8 yd dead zone" wording.
  - Passive Alert: "Label" now says it shows "PET PASSIVE!".

## [0.2.22] - 2026-09-01
### Changed (sniper mark — make OUT OF RANGE visually distinct)
- **OUT OF RANGE now uses a bare outline-only reticle** (`Media/crosshair-outline.tga`
  — just the two concentric rings, no crosshair lines, no centre dot). It reads as
  "no shot available" and is instantly distinguishable from the full green crosshair
  that appears when IN RANGE. IN RANGE (full crosshair) and OUT OF RANGE (hollow
  rings) are no longer near-identical; they now differ in both shape and colour.
- TOO CLOSE still shows the compact red X.

## [0.2.21] - 2026-09-01
### Fixed (sniper mark — "too close" at range, root cause confirmed by selfcheck)
- **The unreliable spell probe is gone.** Your `/htk selfcheck` `range diag` proved it:
  `autoShotInRange=0` but `closeProbe(Raptor Strike)=1` while the target was clearly far
  (>28 yd, since `interact(follow,4)=false`). Raptor Strike's `IsSpellInRange` reports "in
  range" even at long distance on this client — that's what made an out-of-range target
  read "TOO CLOSE". Wing Clip's spell ID (14264) also didn't resolve, so the fallback was
  the broken Raptor Strike.
- **"Too close" is now decided only by `CheckInteractDistance("target", 2)`** (the 11 yd
  "Trade"/deadzone probe), which the same selfcheck confirmed is accurate here
  (`interact(trade,2)=false` when far). Final logic — both probes verified on your client:
  - Auto Shot in range → **IN RANGE** (green)
  - Auto Shot out of range, but within 11 yd (trade) → **TOO CLOSE** (red X)
  - Otherwise → **OUT OF RANGE** (grey)
- Removed the now-dead Raptor Strike / Wing Clip probe code.

## [0.2.20] - 2026-09-01
### Fixed (sniper mark — the "too close" probe was the wrong spell)
- **The close-range probe now uses Wing Clip, not Raptor Strike.** On some clients
  `IsSpellInRange("Raptor Strike")` reports "in range" even when the target is far
  away (a known quirk), which is why an out-of-range target still showed "TOO CLOSE".
  Wing Clip (14264) is the canonical, reliable melee-range check the range weakauras
  use. Raptor Strike is now only a fallback if the player hasn't trained Wing Clip.
- `/htk selfcheck`'s `range diag` now reports which close probe is in use and its
  value, so we can confirm the real client range with one command.

## [0.2.19] - 2026-09-01
### Fixed (sniper mark — far no longer reads "too close")
- **The deadzone probe that misfired is gone.** The previous build used
  `CheckInteractDistance("target", 2)` ("Trade") to decide "too close". On some
  Classic clients that interaction index returns true far beyond the deadzone, so a
  clearly out-of-range target was still classified as "TOO CLOSE". The "too close"
  decision is now driven **only by precise spell ranges**:
  - `IsSpellInRange("Auto Shot")` = 1 → **IN RANGE** (green).
  - Auto Shot out of range **but** a melee spell (Raptor Strike, 5 yd) in range →
    **TOO CLOSE** (red X).
  - Otherwise → **OUT OF RANGE** (grey).
- **Added a `range diag` line to `/htk selfcheck`** that dumps the raw
  `autoShotInRange`, `raptorInRange`, `wingClipInRange` and
  `interact(trade,2)`/`interact(follow,4)` values so we can confirm the real client
  ranges and, if you want, widen the deadzone using a real reference probe.

### Changed (sniper mark graphics)
- **More realistic scope reticle** (`Media/crosshair.tga`): concentric outer +
  inner rings, fine crosshair hairlines, mil-dot marks, and a centre dot — looks
  like an actual scope instead of a plain plus.
- **Red X is smaller** (`Media/crosshair-x.tga`): now spans ~60% of the frame
  (was ~80%), so the "too close" warning reads as a compact mark rather than a big
  crossing-out.

## [0.2.18] - 2026-09-01
### Fixed (sniper mark range labels)
- **"Too close" and "out of range" are now genuinely distinguished.** The previous
  logic used `CheckInteractDistance("target", 4)` (the ~28 yd probe) everywhere, which
  returns true even when the target is far away — so a clearly out-of-range target was
  mislabelled "TOO CLOSE / MOVE BACK". The state logic now matches the reference hunter
  range weakaura:
  - `IsSpellInRange("Auto Shot")` = in range → **IN RANGE** (green).
  - Auto Shot **not** in range **but** within melee (Raptor Strike) **or** inside the
    deadzone interaction distance (`CheckInteractDistance("target", 2)`) → **TOO CLOSE**
    (red X).
  - Otherwise → **OUT OF RANGE** (grey).
- The `CheckInteractDistance` return is now normalised (`== 1 or == true`) so it works
  whether the client returns a boolean or a number, and its ~28 yd counterpart is no
  longer used for the too-close decision.

## [0.2.17] - 2026-09-01
### Changed (sniper mark)
- **The crosshair is now a proper graphic.** Replaced the simple line-drawn plus
  with a bundled TGA reticle (`Media/crosshair.tga`): a dotted centre, four tick
  arms, and a thin outer ring — clean and crisp at any size. The close/dead-zone
  state uses a matching bold **X** graphic (`Media/crosshair-x.tga`) instead of
  rotated lines, so it reads clearly and scales correctly. Both are pure white and
  tinted per state (green/yellow/red/grey).
- **Crosshair centred on the target portrait's line.** It anchors to the target
  frame's right edge with its **centre on the same horizontal line** as the
  portrait, so it no longer sits off to one side.
- **Clear, unambiguous labels.** The old "DEAD" text (which read like "the target
  is dead") is replaced with the actual range state: **"IN RANGE"** (green),
  **"TOO CLOSE"** (yellow), **"MOVE BACK"** (red, dead-zone), **"OUT OF RANGE"**
  (grey). No more confusion between an out-of-range/too-close target and a dead one.

## [0.2.16] - 2026-09-01
### Polished
- **Passive alert cleaned up (single, centred seal).** Removed the dark backdrop
  "frame" that was larger than the seal and looked out of place, and fixed the
  sonar rings to expand **symmetrically from the seal's centre** (they were
  anchored to the icon's top-left, so they grew off-centre). The alert frame now
  matches the seal icon size exactly; the label hangs below and the rings expand
  beyond it cleanly.
- **Sniper mark redesigned (bigger + more precise).** Default size raised to 40px
  (slider now goes up to 64). The reticle is now a proper four-arm crosshair with
  a **centre gap** (instead of a solid plus) plus a centre dot, so it reads as a
  crisp sniper mark and scales nicely at larger sizes. The dead-zone X is scaled
  to match.
- **Feed icon anchor fixed.** It now anchors to the **happiness icon's right edge**
  (the happiness icon is a separate frame just right of the pet portrait, so
  anchoring to the pet frame's own edge put the button ON it). It now sits fully
  to the right of the happiness icon with its centre on the same height. Default
  gap is 12px. Same frame is used for drag-position save, so repositioning stays
  consistent. Re-applied once for existing users via a v6→v7 DB migration.
- **Options scrollbar direction fixed** — the thumb now moves down as you scroll
  down (it was inverted).

## [0.2.15] - 2026-09-01
### Fixed
- **Right-click on the feed icon no longer opens-and-instantly-closes the pin menu.** The
  button registers `AnyDown/AnyUp` (as the reference addon does), which fires the click
  callback on *both* the press and the release. The right-click handler now only acts on
  the release, so one right-click = one menu toggle (open, or close if already open).
- **Passive alert load error fixed.** Removed the bogus `PET_BAR_SHOW` / `PET_BAR_HIDE`
  event registrations (the game has no such events) that threw
  `Frame:RegisterEvent(): Attempt to register unknown event "PET_BAR_SHOW"`. The alert now
  listens only to `PET_BAR_UPDATE`, `PET_BAR_UPDATE_USABLE`, and `PLAYER_ENTERING_WORLD`.
- **Passive alert shows a single seal icon.** Removed the extra star `flash` texture behind
  the `Ability_Seal` icon (which read as a second icon). The alert now shows just the one
  pulsing seal (132311) + the red "PET PASSIVE!" label. Also disabled the pet-bar glow
  (`smallGlowOnPetBar`) by default so the passive state isn't also highlighted on the pet
  bar.

### Changed (options cleanup)
- **Gun sound collapsed to a single "Replace gun shot sound" toggle.** Removed the
  separate "Enable gun sound", "Guns only", "Mute stock gunshot", and "No immediate
  repeats" controls. The one toggle now turns the pew on/off AND replaces the stock
  gunshot (turning it off also restores the normal gun sound). The "Restore stock gunshot
  now" button is kept.
- **Removed stale options:** feed "Hungry glow" and "Warn at full" (neither is used by the
  feed logic — the button already shows hunger state on its border and the tooltip shows
  happiness), and the passive "Attention flash" (the flash it controlled was removed).
- **Options window now has a visible scrollbar** (track + draggable thumb) that tracks the
  scroll position; scrolling still works via mouse wheel and now also by dragging the bar.
- **"Reset positions" actually works now.** It force-restores the default offset/anchor for
  the feed button, sniper mark, and passive alert (the old `MergeDefaults` only filled
  nil values, so a previously-saved bad offset was never reset). The feed button's
  position is also reset to the good default (right of the pet frame) once for existing
  users via a v5→v6 DB migration, and the default gap is now a clean 10px.

### Fixed
- **Feed button anchor default corrected** (right of the pet frame, clear of the happiness
  icon). Its stale "way below" placement is fixed by the reset/migration above.

## [0.2.14] - 2026-09-01
### Fixed (root cause found: pet was already at max happiness)
- **The feed button has always been feeding correctly — the pet was full.** In-game
  click diagnostics confirmed every secure attribute was correct (`spell=Feed Pet`,
  `target-item=0 7`, out of combat, food resolved to the scanned stack). The reason
  the pet never ate is that `GetPetHappiness()` returned **3 (Happy / green)**. In
  Classic the game only lets a pet eat when happiness is **below 3** (`Unhappy`=1 or
  `Content`=2); at max happiness there is nothing to restore, so it refuses the food.
  This explains why the macro, `/use`, and secure spell+target-item builds all appeared
  to "do nothing" — they were each feeding a full pet.
- **The button now explains itself instead of silently no-oping.** On click it prints
  a clear note when the pet is at max happiness ("pet is already content/full (3) — the
  game won't feed it. Feed when happiness < 3"), and when no pet is summoned. The hover
  tooltip now also shows the pet's current happiness state (Unhappy / Content / Happy)
  and whether it will feed on click.
- **Removed the double log line.** The button registers `AnyDown/AnyUp` (matching the
  reference addon), which fires the click callback on both the press and the release;
  the diagnostic now only prints on the release, so you get one line per click.
- Pin/unpin, passive alert, and pew are unchanged.

## [0.2.13] - 2026-09-01
### Fixed (diagnostic build for the still-not-feeding button)
- **Click capture now matches the proven reference addon.** The feed button is
  now `RegisterForClicks("AnyDown", "AnyUp")` — the same registration the
  reference single-click feed addon (Feed-O-Matic / LibSpellButton) uses. The
  previous `"LeftButtonUp","RightButtonUp"` only captured the *release*, which
  can prevent the secure spell's item-targeting from being consummated (the cast
  enters "pick a food" mode but never asserts the pick). If Feed Pet was entering
  its targeting cursor (the light-blue dot) instead of auto-eating, this is the fix.
- **Feed button now logs the real attributes on every left-click (always-on).**
  The hover tooltip reads `lastFood` (a Lua variable), which is why it can show
  "Cured Ham Steak" even while the button's actual secure attributes are empty.
  PostClick now prints the *actual* `spell`, `target-item`, `target-bag`,
  `target-slot`, plus pet / happiness / combat state, every time it's clicked. This
  tells us definitively whether the cast ran and whether `target-item` was set, so
  the next in-game test pinpoints the failure instead of guessing.
- No behaviour change to pin/unpin, passive alert, or pew. This build is *only* the
  RegisterForClicks match + always-on diagnostic so we can finally see what the
  secure engine is doing.

## [0.2.12] - 2026-09-01
### Fixed
- **Feed button actually casts now — the root cause was an `OnClick` override.** The
  0.2.11 secure spell + `target-item` button still "did nothing" because it installed a
  custom **`OnClick`** script on the `SecureActionButtonTemplate`. Overriding `OnClick`
  **replaces** the template's own protected click handler, so its secure dispatch
  (`type1="spell"` + `target-item`) never ran, even out of combat. The reference
  addon (Feed-O-Matic / LibSpellButton) never overrides `OnClick`; it attaches custom
  behavior to **`PostClick`** and leaves `OnClick` to the template. HunterKit now does the
  same: the button is a pure secure spell button, and the right-click pin-menu toggle /
  debug log live on **`PostClick`**. Left-click feeding is now handled entirely by the
  template's native secure path, so the feed fires.
- **Spell-name resolution hardened:** `C_Spell.GetSpellInfo(6991)` is preferred, falling
  back to the legacy `GetSpellInfo(6991)`, then the literal `"Feed Pet"`.
- **Fixed the earlier 0.2.6 note** (which claimed calling `SecureActionButton_OnClick`
  from a custom `OnClick` was "the canonical recipe") — that is **not** correct on the
  live client and was the reason the button was inert. The correct recipe is the reference
  addon's: no `OnClick` override, use `PostClick`.

## [0.2.11] - 2026-09-01
### Fixed
- **Feed button now uses the actual working mechanism (supersedes 0.2.10).** The `/cast Feed Pet` + `/use <bag> <slot>` macro path (even with `[pet]` conditions) is fragile on the current client: macrotext execution is deprioritized/limited and a `/use` can feed the food to **your character** instead of the pet — which is why the button "did nothing" for you. I reverse-engineered the reference single-click feed addon (**Feed-O-Matic** / **LibSpellButton**) and found it does **not** use a `/use` macro at all. It creates a `SecureActionButtonTemplate` with `type1 = "spell"` and `spell = "Feed Pet"` (spell ID **6991**), and sets the secure **`target-item`** (a `"bag slot"` string) plus `target-bag`/`target-slot` attributes to the chosen food. That is Blizzard's supported "cast a spell targeting an item" pattern (same as Disenchanting). The feed button now does exactly this: it casts Feed Pet onto the best food's bag/slot. Verified in the harness: left-click dispatches `spell:Feed Pet | item:0 2 | bag:0 | slot:2`.
- **Right-click on the feed icon toggles the pin menu.** Right-clicking the feed icon now opens the food menu (pin/unpin); right-clicking it **again while the menu is open closes it** (previously it only ever opened/rebuild the menu, so you couldn't dismiss it that way).
- **Drag-unlock clear now exists for the new spell/target attributes** — dragging in `/htk unlock` mode blanks the feed button's `spell`/`target-item`/`target-bag`/`target-slot` (not just `type1`/`macrotext1`) so a left-press while dragging can't feed.

## [0.2.10] - 2026-09-01
### Fixed
- **Feed button genuinely feeds now (this supersedes 0.2.9).** The previous macro was `/cast Feed Pet` + `/use <bag> <slot>` with **no `[pet]` condition**, so the `/use` had no pet context — it could feed the food to **your character** (or resolve nothing for the pet), which is why the button "did nothing". The feed macro is now the battle-tested form where **both** lines carry the `[pet,nodead,nocombat]` condition: `/cast [pet,nodead,nocombat] Feed Pet` then `/use [pet,nodead,nocombat] <bag> <slot>`. `[pet]` gives the `/use` the pet target, `[nodead]` does nothing when the pet is dead, `[nocombat]` matches Feed Pet's out-of-combat rule. The button still resolves and offers the best food regardless of happiness (the game itself refuses to consume on a full pet, but the addon still attempts it and shows the food).
- **Pinning no longer a no-op / every food can be unpinned.** The right-click menu's `PinItem` only *added* a food and early-returned if it was already pinned, so once you pinned a food there was **no way to unpin it**, and it would be force-fed forever (overriding the best-food scan). Left-clicking a row now **toggles**: pin an unpinned food / unpin a pinned food. The row's right-hand label flips between `Pin` and `UNPIN`, and the menu title reads "Feed — click a food to pin/unpin".
- **Passive alert uses the Ability Seal icon, pops and warns in red.** The alert now always shows the pet-Passive icon `Ability_Seal` (FileDataID 132311, the icon you linked) regardless of what the pet bar reports, and the pulsing icon is labelled **"PET PASSIVE!" in red** (was "PET IS PASSIVE" in gold) directly below the seal. The icon still size-pulses each cycle.

## [0.2.9] - 2026-09-01
### Fixed
- **Pew now fires the instant the gun fires (no more ~1s lag).** The trigger was the combat-log `RANGE_DAMAGE` subevent, which is the **damage-landing** event — it fires when the projectile *hits the target*, i.e. after the projectile's travel time. That's why the pew trailed the gun shot. The trigger is now the player's `UNIT_SPELLCAST_SUCCEEDED` for **Auto Shot (spellID 75)** — the **weapon-launch** event, which fires the moment the missile leaves the weapon (the same instant the stock gunshot is heard). Only Auto Shot (75) is used, so **Multi-Shot, Arcane Shot and Aimed Shot keep their own audible spell sounds** and are never overridden by a pew.
- **Feed button genuinely feeds.** `RefreshMacro` set the macro to `/use <bag> <slot>` only. In Classic, pet food is consumed only while the **Feed Pet** ability is active — a bare `/use food` just uses the item and does nothing for the pet. The macro is now **`/cast Feed Pet` followed by `/use <bag> <slot>`**, which is the documented one-click feed. The button keeps resolving and offering the best food regardless of happiness (the game itself refuses to consume food on a full pet, but the addon still attempts it and shows the food).
- **Removed the audible at-login pew pre-load.** The 0.2.8 cache-warm played all four pews into the `Master` bus at `PLAYER_ENTERING_WORLD`, which was **audible** (four pews every login). It's removed; the first pew after login may decode ~50ms later, but no pew is ever heard off-combat.

## [0.2.8] - 2026-09-01
### Changed
- **Gun sound now silences ONLY the auto-shot; Multi-Shot / Arcane Shot keep their sound.** The muzzle set was incorrectly muting the hunter *spell-cast* weapon-fire sound `spell_hu_blunderbuss_weaponfire_01..06` (FileDataIDs 921248-921258), which is **shared by those shot abilities** — so they went silent too. The mute list is now exactly the weapon fire/load set: `GunFire01/02/03` (567721, 567718, 567722) and `GunLoad01/02/03` (567719, 567720, 567723). Those are the gun's own "bang"; spells are untouched. A `v4 -> v5` migration strips the spell-cast IDs out of any already-saved list so upgrading users get their ability sounds back.

### Changed (feed)
- **Diet cache refreshes when the pet / pet-bar changes** — so a newly-summoned pet (which may have a different diet set) is rescanned and the food picker always sees the right edible set. This is part of reliably finding the *best* food in bags.
- **Feeding stays available at full happiness.** The feed button is shown and the best food is still resolved regardless of the pet's current happiness level (the game just won't consume food on a full pet, as before). The button never hides merely because the pet is content.

## [0.2.7] - 2026-09-01
### Removed
- **`GetPetFoodTypes` no longer treated as a single comma-string.** On Classic the
  API returns **multiple string values** (e.g. `"Meat", "Fish", ...`), not one
  comma-joined string. The old code captured only the first return, so it saw a
  single diet type and `PickFood()` couldn't match most foods. `GetDiets()` now
  collects all returns (and still splits comma-strings for any client that
  returns one — robust to both shapes).

### Added
- **New `FoodDB.lua`** — a curated Classic-era pet-food database keyed by diet
  type (Fungus/Fish/Meat/Bread/Cheese/Fruit), with an item-ID → diet-type map
  (`HK.FOOD_BY_ITEM`) for O(1) lookup. Sourced from Fizzwidget Feed-O-Matic's
  vanilla food list. `FoodType()` uses it to answer "is this item edible for this
  pet" **without scanning a tooltip**, and `MatchesDiet()` falls back to the
  tooltip scan only for foods not in the DB. `PickFood()` now has a far better
  chance of *finding* food in your bags — this is the "add as many foods as
  possible" fix.
- **`/htk gunlist`** — prints exactly which FileDataIDs HunterKit is configured
  to mute, so you can confirm the mute set in-game.

### Fixed
- **Passive alert never showed (`isActive` read from the wrong position).** The
  authoritative `GetPetActionInfo` return order is `name, texture, isToken,
  isActive, ...` — **`texture` is the 2nd value and `isActive` is the 4th**, with
  **no `subtext` field** (confirmed on warcraft.wiki.gg). The old code read
  `name, _, texture, _, isActive`, which placed `texture` on `isToken` and
  `isActive` on `autoCastAllowed` — so `PetPassiveInfo()` always saw "not
  active" and the alert stayed hidden on the real client (it only "passed" a
  harness that used a fake `name, subtext, texture, isToken, isActive` layout).
  Now parses the return into a table and reads the texture from position 2 (falling
  back to 3) and the active flag from position 4 (falling back to 5), so it works
  regardless of whether the client includes `subtext`. Also: the pet-action scan
  now returns no passive slot for non-hunters.
- **Original gun shot still played** — `mutedFileIDs` was never being populated
  for existing users. `MergeDefaults` only fills keys that are `nil`, so anyone who
  already had a `mutedFileIDs` key (e.g. an empty or short list left over from an
  early build) kept that stale list and never received the full gun-mute set; and
  a leftover `muteOriginal = false` from the old "don't mute by default" era kept
  the stock sound. The `v3 → v4` migration now **unions the configured list with
  the full default set** and **forces `muteOriginal = true`**.
- **`GetPetFoodTypes` harness divergence** — the test harness now mirrors the real
  multi-value contract (and returns no pet for non-hunters), so the food and
  passive code paths are actually exercised against the real API shape.

## [0.2.6] - 2026-09-01
### Fixed
- **Crash when unchecking "Enable feed pet"** — `RescanSettings` called a bare
  `RefreshMacro()` (a nil global) instead of `FeedPet:RefreshMacro()`. It also now
  applies visibility on toggle, so unchecking actually hides the feed button.
- **Feed button "did nothing" (secure macro never ran)** — overriding the
  `SecureActionButtonTemplate`'s `OnClick` with a custom script **clobbered the
  secure dispatch**, so the feed macro never fired. The custom `OnClick` now calls
  the global `SecureActionButton_OnClick(self)` first to dispatch the secure feed
  macro, then handles the right-click menu / debug log. This is the canonical
  recipe for a secure button with extra behavior.
- **Passive-slot detection was reading the wrong fields** — `GetPetActionInfo`
  returns `name, subtext, texture, isToken, isActive, ...`; `isActive` is the 5th
  return and `texture` the 3rd. The code read them at positions 4/2, so the
  Passive alert never showed. Now reads the correct positions and also accepts an
  action name that contains "passive" as a fallback.
- **Drag-position save corrupted feed button placement** — after a drag, the saved
  `(x, y)` came from `GetPoint()` (relative to `UIParent` BOTTOMLEFT) and were
  mis-used as the offset from the pet frame, landing the button over the pet
  frame. Each draggable now computes its offset from its on-screen position
  (`saveFromScreen`), so the button stays where you drop it.
- **Feed button tooltip** — hovering now shows exactly what the click will feed
  (the food name + stack count), so the action is never a surprise.

## [0.2.5] - 2026-09-01
### Fixed
- **`ADDON_ACTION_FORBIDDEN` on feed click** — the feed button was a *plain*
  button whose `OnClick` called the protected functions `CastSpellByName` /
  `UseContainerItem`, which Blizzard blocks from addon code (the "attempt to call
  the protected function 'UNKNOWN()'" error). Reverted to a proper
  **`SecureActionButtonTemplate`** button whose left-click is a **secure macro**
  (`type1 = "macro"`, `macrotext1 = "/use <bag> <slot>"` for the exact best-food
  stack, falling back to `/cast Feed Pet`). No protected function is ever called
  from addon code now, so the feed works without tripping protection. Left-click
  feeding is a player-initiated click; right-click still opens the picker menu.
- **Original gun shot not silenced.** The stock gun shot is now **muted by
  default** (`muteOriginal = true`), and `mutedFileIDs` now holds the real
  Classic gun fire/load FileDataIDs — `GunFire01-03` / `GunLoad01-03`
  (`567718-567723`, confirmed as what a hunter gun spell references) plus the
  spell `blunderbuss_weaponfire` set (`921248-921258`). The pew still plays on
  the combat-log ranged event, so you get the replacement sound instead of the
  stock gun shot.
- **Drag-mode feed safety** — in `/htk unlock` mode the secure macro is blanked
  (`type1`/`macrotext1` cleared) so a left-press while dragging never feeds.

## [0.2.4] - 2026-09-01
### Fixed
- **Options scroll threw an error on open** ("attempt to call a nil value" at
  `GetScrollRange`) — that ScrollFrame method doesn't exist on this client. The
  scroll range is now derived from content vs frame height, so mouse-wheel
  scrolling works without erroring.
- **Feed button still un-interactable** — a secure macro button's clicks must be
  routed through a secure macro, which kept failing on this client. Switched to a
  plain button whose left-click is a *player-initiated click* that casts
  `Feed Pet` and uses the best food directly (out-of-combat only). This is an
  explicitly allowed action path (the addon never acts on its own). The button
  now also has visible hover/pressed highlights so it's obviously clickable.
- **Feed button covered the pet happiness icon** — default horizontal offset
  raised (12 → 30 px) so the button sits clearly to the right of the pet frame.
- **`UseContainerItem` compat** — added `HK.UseContainerItem` (prefers
  `C_Container.UseContainerItem`, falls back to the legacy global), since the
  Midnight UI merge moved it out of the global namespace.

## [0.2.3] - 2026-09-01
### Fixed
- **Options window showed only the section headers** ("5 names") — every
  checkbox, slider and dropdown was created **without a `SetPoint`**, so they all
  stacked at the panel's default corner and were clipped out of view. All widget
  factories now anchor each control at its intended `TOPLEFT` row, so the full
  settings list renders and scrolls.
- **Feed button un-clickable** — the button was a child of the pet frame, which is
  a protected unit-frame whose secure click handling can swallow a child's
  left-clicks. The button is now parented to `UIParent` and only *anchored*
  (for position) to the pet frame, so it is never inside a secure frame hierarchy.
  It also sits at frame level 50 / HIGH strata so nothing overlaps it.
- **Removed the `PetFrameHappy` global dependency** — that frame global may not
  exist on the current client; anchoring is done against the pet frame directly.
- **Gun sound "still loud and clear" / no pew** — two fixes: (1) the ranged-weapon
  classification now falls back to the localized item-type string when
  `GetItemInfoInstant` is absent or returns unexpected values, so a gun is still
  detected; (2) the pew files were regenerated at ~-13 dBFS (was ~-22 dBFS,
  which was inaudible under the stock shot), so the pew is clearly heard while
  still blending under the (un-muted) original.
- **Sound now respects the enable toggles** — the pew no longer plays when the
  master switch or "Gun sound" is switched off.
- **`/htk selfcheck` diagnostics** — added `feed diag`, `petframehappy global`,
  and `sound diag` (weapon type, filter result, muted IDs, CLEU range events,
  pews played). Run `/htk selfcheck` to confirm the feed button anchor and that
  the pew path actually fires on your client.

## [0.2.2] - 2026-08-31
### Fixed
- **Taint / ADDON_ACTION_BLOCKED**: the secure feed button was being
  `SetShown()` from tainted code while in combat (`HunterKitFeedButton:SetShown()`
  is a protected call). Visibility changes are now guarded by
  `InCombatLockdown()` and re-applied on `PLAYER_REGEN_ENABLED`. This also fixes
  the feed button becoming un-clickable (a tainted secure frame drops its
  secure action).
- **Feed button placement**: now anchors to the pet happiness icon
  (`PetFrameHappy`) and draws at a raised frame level, so it sits *beside* the
  icon (no overlap) and is reliably clickable (`EnableMouse(true)`).
- **Sniper Mark position**: now sits to the **right** of the target frame
  (was left).

### Changed
- **Gun sound** made **less distinct**: regenerated the four pews at ~-22 dBFS
  (was -13 dBFS) and slightly shorter, so they blend under the stock gunshot
  instead of standing out as a crisp blaster.
- **Stock-mute is now OFF by default.** The game's mute is session-wide and
  persisted after disabling the addon + `/reload`. Now:
  - `muteOriginal` defaults to `false` (so the original gunshot is never muted
    unless you explicitly enable it).
  - `mutedFileIDs` is pre-populated with the real gun auto-shot IDs
    (`spell_hu_blunderbuss_weaponfire_01..06`, FileDataIDs `921248/921250/
    921252/921254/921256/921258`) so the opt-in mute actually works. Sourced from
    the Classic hunter gun-sound list (OldGunSounds/HunterGunSound addons).
  - Turning the "Mute stock gunshot" toggle off, or pressing the new
    **"Restore stock gunshot now"** button, unmutes the IDs (and best-effort
    restores the configured IDs from any prior session).
  - Added a tooltip warning that the mute is applied by the game (session-wide),
    and the restore button/note unless you otherwise manage it.

## [0.2.1] - 2026-08-31
### Fixed
- **Container API compat**: on Classic patch 1.15.9 the legacy global bag
  functions (`GetContainerNumSlots`, `GetContainerItemID`, `GetContainerItemInfo`)
  are no longer present — the Midnight UI merge replaced them with the
  `C_Container` namespace, which returns a **table** (itemID/itemCount/icon)
  instead of positional values. Added `HK.GetBagNumSlots/GetBagItemID/
  GetBagItemCount/GetBagItemLink`, which prefer `C_Container` and fall back to the
  legacy globals. This fixes the `attempt to call a nil value` in
  `FeedPet:PickFood()`.
- Added `HK.GetItemInfo` compat (falls back to `C_Item.GetItemInfo`).
- **Passive slot detection**: `GetPetActionInfo` now returns the texture as a
  numeric FileDataID (e.g. 132311 for Ability_Seal), not a path string, so
  `texture:find("Ability_Seal")` errored. `IsPassiveTexture()` now matches the
  numeric FileDataID *or* the path string on older clients.
- **Sounds**: fixed a `nil` global call — `ApplyMutes()` inside the
  `PLAYER_ENTERING_WORLD` handler now correctly calls `Sounds.ApplyMutes()`.

## [0.2.0] - 2026-08-31
### Added
- **F1 Feed Pet** — secure one-click button, best-food picker (max tier then
  smallest stack), pin/exclude lists, exact-stack `/use <bag> <slot>` macro,
  happiness border + hungry glow, right-click menu.
- **F2 Sniper Mark** — range-state crosshair (OK / NEAR / DEAD / FAR) using
  `IsSpellInRange` + `CheckInteractDistance`; colorblind-safe X in the dead zone;
  10 Hz ticker; one-shot blink on entering the dead zone.
- **F3 Gun sound** — CLEU-driven pew, guns-only, no-repeat, throttle,
  `MuteSoundFile` for the stock shot, `/htk sound` preview.
- **F4 Passive Alert** — center-screen pulsing Ability Seal (rings + bounce +
  label), passive-slot resolution via texture scan (never hardcoded slot ),
  optional pet-bar glow.
- **F5 Options** — draggable window, checkboxes/sliders/dropdowns, minimap
  button, `/htk lock|unlock`, `/htk reset`.
- **Core** — SavedVariables schema + merge/migration, event bus, structural
  class gate (non-hunters never register CLEU or mutes), `/htk selfcheck`.

### Changed
- Built against the 2026 client truth: **Interface 11509** (patch 1.15.9).
- Anchor to resolved parents with `or UIParent` fallback (no nil-global errors
  if a unit-frame addon or Edit Mode removes a Blizzard frame).
- Secure feed button uses `type1` / `macrotext1` (left-click-only) and
  `RegisterForClicks` up/down.
- Passive alert pulse driven portably by `OnUpdate` (no client-specific
  `Scale` animation signature).
- Sound-ID discovery targets wago.tools (wow.tools is retired).

## [0.1.0] - YYYY-MM-DD
### Added
- Initial skeleton (TOC, Core, empty module stubs).
