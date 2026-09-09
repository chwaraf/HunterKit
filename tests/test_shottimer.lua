--[[==============================================================================
 HunterKit — tests: Auto Shot timer / weave bar (ShotTimer)

 The feature is a model of a game mechanic, so these tests are mostly about the
 MODEL, not the pixels: given a weapon speed and a shot at time T, when is the
 next shot, how much free time is left, and when does the lockout begin. The
 widget assertions come after, and only for things a player would notice.

 Run with tests/run_tests.py.
==============================================================================]]

local passes, failures = 0, {}
local say = HKTest.say

local function check(name, cond, detail)
  if cond then
    passes = passes + 1
    say("  ok   " .. name)
  else
    failures[#failures + 1] = name .. (detail and (" — " .. tostring(detail)) or "")
    say("  FAIL " .. name .. (detail and (" — " .. tostring(detail)) or ""))
  end
end

HKTest.prints = {}
HKTest.state.isHunter = true
HKTest.state.rangedSpeed = 3.0
local HK = HKTest.LoadAddon(unpack(HKTest.addonFiles))
HK:Load()
local ST = HK.ShotTimer
check("the ShotTimer module loaded", ST ~= nil)

local function At(t) HKTest.state.now = t end

-- Puts the world in a known state: a hunter shooting a weapon of the given
-- speed, with one shot already away at time `t`.
local function Shooting(speedVal, t)
  HKTest.state.rangedSpeed = speedVal
  HK.db.shottimer.enabled = true
  ST.RescanSettings()
  ST._SetRepeating(true)
  At(t)
  ST._OnShotFired(t)
  -- Reset AFTER the priming shot: that shot is measured against the previous
  -- scenario's prediction and would otherwise be counted as a bogus clip.
  ST.ResetStats()
  return HK.db.shottimer
end

-- ---------------------------------------------------------------------------
-- 1) The cycle: shot -> weapon-speed recovery -> next shot
-- ---------------------------------------------------------------------------
Shooting(3.0, 100)
local remaining, total, locked = ST.Progress(100)
check("right after a shot, the full cycle remains",
  math.abs(remaining - 3.0) < 0.001, tostring(remaining))
check("the cycle is the weapon's speed", math.abs(total - 3.0) < 0.001, tostring(total))
check("...and you are free to act", locked == false, tostring(locked))

remaining = ST.Progress(101.5)
check("halfway through, half the cycle remains",
  math.abs(remaining - 1.5) < 0.001, tostring(remaining))

-- ---------------------------------------------------------------------------
-- 2) The 0.5s lockout -- the whole point of the feature
-- ---------------------------------------------------------------------------
Shooting(3.0, 200)
check("2.0s in (1.0s left) you may still act", ST.IsLocked(202.0) == false)
check("2.4s in (0.6s left) you may still act", ST.IsLocked(202.4) == false)
check("2.5s in (0.5s left) the lockout begins", ST.IsLocked(202.5) == true)
check("2.9s in you must hold still", ST.IsLocked(202.9) == true)

-- The free window is the number a player actually acts on.
check("a 3.0s weapon gives 2.5s of free time",
  math.abs(ST.SafeWindow(200) - 2.5) < 0.001, tostring(ST.SafeWindow(200)))
check("...which shrinks as the shot approaches",
  math.abs(ST.SafeWindow(202.0) - 0.5) < 0.001, tostring(ST.SafeWindow(202.0)))
check("inside the lockout the free window is zero",
  ST.SafeWindow(202.7) == 0, tostring(ST.SafeWindow(202.7)))

-- The cast time is FIXED: it does not scale with the weapon. This is why slow
-- weapons are easier to play, and the single most important fact in the module.
Shooting(1.8, 300)
check("a fast 1.8s weapon still locks out for 0.5s",
  math.abs(ST.SafeWindow(300) - 1.3) < 0.001, tostring(ST.SafeWindow(300)))
Shooting(3.3, 400)
check("a slow 3.3s weapon leaves much more room",
  math.abs(ST.SafeWindow(400) - 2.8) < 0.001, tostring(ST.SafeWindow(400)))

-- ---------------------------------------------------------------------------
-- 3) Measuring the clip -- ground truth, not prediction
-- ---------------------------------------------------------------------------
Shooting(3.0, 500)
-- The shot arrives exactly on time: nothing was clipped.
ST._OnShotFired(503.0)
check("a shot on time reports no clip", ST.LastDelay() == 0, tostring(ST.LastDelay()))
local shots, clips = ST.Stats()
check("...and is not counted as a clip", clips == 0, tostring(clips))

-- The shot arrives late: the player clipped it, and by how much.
Shooting(3.0, 600)
ST._OnShotFired(603.34)
check("a late shot reports the delay",
  math.abs(ST.LastDelay() - 0.34) < 0.001, tostring(ST.LastDelay()))
shots, clips = ST.Stats()
check("...and is counted", clips == 1, tostring(clips))

-- A few milliseconds late is latency, not a mistake. Reporting it would train
-- the player to chase noise.
Shooting(3.0, 700)
ST._OnShotFired(703.04)
check("a few ms late is noise, not a clip", ST.LastDelay() == 0, tostring(ST.LastDelay()))
shots, clips = ST.Stats()
check("...and is not counted against the player", clips == 0, tostring(clips))

-- ---------------------------------------------------------------------------
-- 4) Haste: the bar must follow the weapon, not a login-time snapshot
-- ---------------------------------------------------------------------------
Shooting(3.0, 800)
check("before the proc, the cycle is 3.0s",
  math.abs(ST.Speed() - 3.0) < 0.001, tostring(ST.Speed()))
HKTest.state.rangedSpeed = 2.1            -- Aspect of the Hawk procs mid-fight
ST._OnShotFired(803.0)
check("a haste proc shortens the cycle on the next shot",
  math.abs(ST.Speed() - 2.1) < 0.001, tostring(ST.Speed()))
check("...and the free window shrinks with it",
  math.abs(ST.SafeWindow(803.0) - 1.6) < 0.001, tostring(ST.SafeWindow(803.0)))

-- ---------------------------------------------------------------------------
-- 5) Aimed Shot restarts the cycle
--
-- Documented behaviour since 2.0.1. Without this the bar counts down to a shot
-- that is never coming, which is worse than showing nothing.
-- ---------------------------------------------------------------------------
Shooting(3.0, 900)
ST._OnTimerReset(901.0)      -- Aimed Shot lands 1s into the cycle
remaining = ST.Progress(901.0)
check("Aimed Shot restarts the full cycle",
  math.abs(remaining - 3.0) < 0.001, tostring(remaining))

-- ---------------------------------------------------------------------------
-- 6) Trusting the server over our own prediction
-- ---------------------------------------------------------------------------
Shooting(3.0, 1000)
-- The server says the cast started later than we predicted (movement, the
-- re-shot timer). The shot is therefore later than we thought.
ST._OnCastStarted(1002.9)
remaining = ST.Progress(1002.9)
check("a late cast start pushes the prediction back",
  math.abs(remaining - 0.5) < 0.001, tostring(remaining))

-- But an early cast start must never yank the bar backwards.
Shooting(3.0, 1100)
ST._OnCastStarted(1101.0)    -- absurdly early
remaining = ST.Progress(1101.0)
check("an early cast start does not rewind the bar",
  math.abs(remaining - 2.0) < 0.001, tostring(remaining))

-- ---------------------------------------------------------------------------
-- 7) Visibility: present while shooting, gone otherwise
-- ---------------------------------------------------------------------------
Shooting(3.0, 1200)
check("the bar shows while auto-repeat is on", ST.IsShown() == true)
check("...and animates", ST.IsAnimating() == true)

ST._SetRepeating(false)
HKTest.state.playerCombat = false      -- out of combat entirely
ST.Refresh()
check("stopping auto-repeat hides the bar", ST.IsShown() == false)
check("...and detaches the OnUpdate", ST.IsAnimating() == false,
  "an idle bar must not run every frame")

HK.db.shottimer.enabled = false
ST.RescanSettings()
ST._SetRepeating(true)
ST.Refresh()
check("disabled: no bar at all", ST.IsShown() == false)
check("disabled: nothing animating", ST.IsAnimating() == false)
HK.db.shottimer.enabled = true
ST.RescanSettings()

-- ---------------------------------------------------------------------------
-- 8) What the bar actually says
-- ---------------------------------------------------------------------------
Shooting(3.0, 1300)
HK.db.shottimer.weave = false      -- weave cue tested separately, below
ST.RescanSettings()
At(1300)
ST.OnUpdate()
check("the label counts down the FREE time, not the raw cycle",
  ST.LabelText() == "2.5s", tostring(ST.LabelText()))
HK.db.shottimer.weave = true
ST.RescanSettings()

At(1302.7)                    -- inside the lockout
ST.OnUpdate()
check("inside the lockout it says hold", ST.LabelText() == "hold",
  tostring(ST.LabelText()))

-- The fill grows toward the shot.
Shooting(3.0, 1400)
At(1400)
ST.OnUpdate()
local early = ST.FillWidth()
At(1402.5)
ST.OnUpdate()
local late = ST.FillWidth()
check("the bar fills as the shot approaches", late > early,
  tostring(early) .. " -> " .. tostring(late))

-- The measured clip is surfaced to the player.
Shooting(3.0, 1500)
ST._OnShotFired(1503.4)
At(1503.4)
ST.OnUpdate()
check("a clip is shown on the bar",
  (ST.DelayText() or ""):find("0.40") ~= nil, tostring(ST.DelayText()))
At(1510)                      -- well past the hold time
ST.OnUpdate()
check("...and fades away rather than nagging",
  ST.DelayText() == "", tostring(ST.DelayText()))

-- A clean shot never shows a clip readout at all.
Shooting(3.0, 1600)
ST._OnShotFired(1603.0)
At(1603.0)
ST.OnUpdate()
check("a clean shot shows no clip figure", ST.DelayText() == "",
  tostring(ST.DelayText()))

-- ---------------------------------------------------------------------------
-- 9) Robustness
-- ---------------------------------------------------------------------------
-- Predictions must not outlive the shooting. A stale countdown after you stop
-- firing would send the player to hold still for a shot that is not coming.
Shooting(3.0, 1650)
check("while shooting there is a prediction", ST.Progress(1650) ~= nil)
HK.ShotTimer._SetRepeating(false)
HKTest.state.rangedSpeed = 3.0

-- A nonsense speed from the API must not poison the model.
HKTest.state.rangedSpeed = 0               -- no ranged weapon equipped
Shooting(0, 1700)
check("a zero weapon speed is ignored, not believed",
  ST.Speed() > 0, tostring(ST.Speed()))
HKTest.state.rangedSpeed = 3.0

-- Diagnostics must never throw, in any state.
Shooting(3.0, 1800)
check("/htk shot runs without error", pcall(ST.PrintDiag) == true)
ST._SetRepeating(false)
ST.Refresh()
check("/htk shot runs while not shooting", pcall(ST.PrintDiag) == true)

-- ---------------------------------------------------------------------------
-- 10) Defaults
-- ---------------------------------------------------------------------------
check("the bar is OFF by default (it is a big, permanent UI change)",
  HK.defaults.shottimer.enabled == false)
check("the clip readout is on once the bar is enabled",
  HK.defaults.shottimer.showDelay == true)


-- ---------------------------------------------------------------------------
-- 11) MELEE WEAVING
--
-- In Classic Era the melee and ranged cycles are INDEPENDENT -- that is what
-- makes weaving possible at all. (WotLK deliberately linked them, which killed
-- it there; these tests pin the Era behaviour so a future edit cannot quietly
-- import the wrong model.)
-- ---------------------------------------------------------------------------
HK.db.shottimer.weave = true
HK.db.shottimer.travel = 2.5
-- These scenarios are about the ROUND-TRIP ("normal") weave, which is opt-in:
-- by default the bar only advises a weave you can take without moving.
HK.db.shottimer.travelWeave = true
ST.RescanSettings()

-- These scenarios test the weave TIMING, so put both specials on cooldown --
-- otherwise the "spend Aimed/Multi first" gate (correctly) vetoes every weave.
local function SpecialsOnCD(now)
  HKTest.state.cooldowns = {
    [19434] = { now, 6 },   -- Aimed
    [2643]  = { now, 10 },  -- Multi
  }
end
local function SpecialsReady()
  HKTest.state.cooldowns = {}
end
SpecialsOnCD(0)

-- A melee swing must NOT disturb the ranged cycle.
Shooting(3.0, 2000)
local before = ST.Progress(2000.5)
ST._OnMeleeSwing(2000.5)
local after = ST.Progress(2000.5)
check("a melee swing does not touch the ranged timer (Era, not WotLK)",
  math.abs(before - after) < 0.0001, tostring(before) .. " vs " .. tostring(after))

-- ...and the shot does not reset the melee cycle either.
HKTest.state.meleeSpeed = 2.4
ST._ClearMelee()
ST._OnMeleeSwing(2100)
HKTest.state.now = 2101
local meleeBefore = ST.MeleeReady(2101)
ST._OnShotFired(2101)
check("an auto shot does not reset the melee swing",
  math.abs(ST.MeleeReady(2101) - meleeBefore) < 0.0001,
  tostring(meleeBefore) .. " vs " .. tostring(ST.MeleeReady(2101)))

-- The melee cycle counts down from an OBSERVED swing.
ST._ClearMelee()
check("with no swing seen, we admit we do not know", ST.MeleeReady(2200) == nil)
ST._OnMeleeSwing(2200)
check("after a swing, the melee cycle is full",
  math.abs(ST.MeleeReady(2200) - 2.4) < 0.001, tostring(ST.MeleeReady(2200)))
check("...and drains", math.abs(ST.MeleeReady(2201) - 1.4) < 0.001,
  tostring(ST.MeleeReady(2201)))
check("...and floors at zero, not negative",
  ST.MeleeReady(2299) == 0, tostring(ST.MeleeReady(2299)))

-- ---------------------------------------------------------------------------
-- 12) The weave decision: does the round trip fit?
-- ---------------------------------------------------------------------------
HKTest.state.meleeSpeed = 2.4
SpecialsOnCD(2300)
Shooting(3.3, 2300)          -- slow bow: 2.8s free, 2.5s trip -> fits
ST._OnMeleeSwing(2290)       -- swing came off cooldown long ago
local ok, free, need = ST.CanWeave(2300)
check("a slow weapon leaves room to weave", ok == true,
  string.format("free %.2f need %.2f", free or -1, need))

SpecialsOnCD(2400)
Shooting(2.6, 2400)          -- 2.1s free vs a 2.5s trip -> does not fit
ST._OnMeleeSwing(2390)
ok, free, need = ST.CanWeave(2400)
check("a faster weapon does not", ok == false,
  string.format("free %.2f need %.2f", free or -1, need))

-- Late in the cycle the window has gone, even on a slow weapon.
SpecialsOnCD(2500)
Shooting(3.3, 2500)
ST._OnMeleeSwing(2490)
check("weaving is off once the window has passed", ST.CanWeave(2501.5) == false,
  string.format("%.2f free", ST.SafeWindow(2501.5)))

-- A melee swing still on cooldown makes the trip pointless.
SpecialsOnCD(2600)
Shooting(3.3, 2600)
ST._OnMeleeSwing(2599.9)     -- just swung: 2.4s until the next one
ok = ST.CanWeave(2600)
check("no weave when the swing would not be ready on arrival", ok == false)

-- Travel time is the player's own number and must actually matter.
SpecialsOnCD(2700)
Shooting(3.3, 2700)
ST._OnMeleeSwing(2690)
HK.db.shottimer.travel = 1.0
ST.RescanSettings()
check("a quicker player can weave where a slower one cannot",
  ST.CanWeave(2700) == true)
HK.db.shottimer.travel = 4.0
ST.RescanSettings()
check("a slow round trip never fits", ST.CanWeave(2700) == false)
HK.db.shottimer.travel = 2.5
ST.RescanSettings()

-- ---------------------------------------------------------------------------
-- 13) What the player sees
-- ---------------------------------------------------------------------------
SpecialsOnCD(2800)
Shooting(3.3, 2800)
ST._OnMeleeSwing(2790)
At(2800)
ST.OnUpdate()
-- "GO" is the cue now: the bar counts down to the ideal departure and says GO
-- at the moment the shot cycle and the melee swing line up.
check("the bar tells you to go while the trip fits",
  (ST.LabelText() or ""):find("GO") ~= nil, tostring(ST.LabelText()))
At(2802.0)                   -- window gone
ST.OnUpdate()
check("...and stops saying it once it does not",
  (ST.LabelText() or ""):find("WEAVE") == nil, tostring(ST.LabelText()))

-- The marker cannot be drawn honestly on a weapon too fast to weave with.
-- (It is positioned during the redraw now, because in static mode its place on
-- the bar tracks the live swing clock -- so drive a frame before reading it.)
SpecialsOnCD(2900)
Shooting(3.3, 2900)
At(2900); ST.OnUpdate()
check("a slow weapon gets a weave marker", ST.WeaveMarkShown() == true)
Shooting(2.0, 2950)          -- 1.5s free, 2.5s trip: impossible
At(2950); ST.OnUpdate()
check("a weapon too fast to weave shows no marker", ST.WeaveMarkShown() == false)

-- Switching the feature off removes all of it.
SpecialsOnCD(3000)
Shooting(3.3, 3000)
ST._OnMeleeSwing(2990)
HK.db.shottimer.weave = false
ST.RescanSettings()
At(3000)
ST.OnUpdate()
check("weaving off: no marker", ST.WeaveMarkShown() == false)
check("weaving off: no WEAVE cue",
  (ST.LabelText() or ""):find("WEAVE") == nil, tostring(ST.LabelText()))
HK.db.shottimer.weave = true
ST.RescanSettings()

-- ---------------------------------------------------------------------------
-- 14) Combat log: only OUR swings, only real ones
-- ---------------------------------------------------------------------------
HKTest.state.meleeSpeed = 2.4
ST._ClearMelee()
HKTest.state.now = 3100
local myGUID = UnitGUID("player")
HKTest.state.clevent = { 0, "SWING_DAMAGE", false, myGUID }
ST._OnCombatLog()
check("our own melee swing is picked up", ST.MeleeReady(3100) ~= nil)

ST._ClearMelee()
HKTest.state.clevent = { 0, "SWING_DAMAGE", false, "guid-someone-else" }
ST._OnCombatLog()
check("somebody else's swing is ignored", ST.MeleeReady(3100) == nil)

ST._ClearMelee()
HKTest.state.clevent = { 0, "SPELL_DAMAGE", false, myGUID }
ST._OnCombatLog()
check("a spell is not a melee swing", ST.MeleeReady(3100) == nil)

-- A miss still swings the weapon, so it still resets the cycle.
ST._ClearMelee()
HKTest.state.clevent = { 0, "SWING_MISSED", false, myGUID }
ST._OnCombatLog()
check("a missed swing still resets the melee cycle", ST.MeleeReady(3100) ~= nil)
HKTest.state.clevent = nil

check("the weave marker is on by default", HK.defaults.shottimer.weave == true)
check("the default round trip matches the community figure",
  HK.defaults.shottimer.travel == 2.5)


-- ---------------------------------------------------------------------------
-- 15) DEFAULT PLACEMENT
--
-- The bar must not land on top of HunterKit's own icons, and must sit BELOW
-- screen centre so it never covers the player/target frames and the buff and
-- debuff rows you read mid-fight. Checked against the real defaults so moving
-- any frame's default cannot quietly create a collision.
-- ---------------------------------------------------------------------------
local sd = HK.defaults.shottimer
local sLo = sd.offsetY - (sd.height / 2)
local sHi = sd.offsetY + (sd.height / 2)

check("the bar defaults below screen centre, clear of the unit frames",
  sHi < 0, tostring(sd.offsetY))

-- The alert stack lives above centre; the bar must be nowhere near it.
for _, other in ipairs({ "threat", "pulse", "mend" }) do
  local od = HK.defaults[other]
  if od and od.offsetY and (od.size or od.height) then
    local h = od.size or od.height
    local oLo, oHi = od.offsetY - h / 2, od.offsetY + h / 2
    local overlaps = not (sHi < oLo or sLo > oHi)
    check("the bar does not overlap the " .. other .. " icon by default",
      not overlaps,
      string.format("bar %.0f..%.0f vs %s %.0f..%.0f", sLo, sHi, other, oLo, oHi))
  end
end

-- ---------------------------------------------------------------------------
-- 16) "Keep the bar on screen"
-- ---------------------------------------------------------------------------
check("the bar hides itself by default", HK.defaults.shottimer.always == false)

HK.db.shottimer.always = false
ST.RescanSettings()
ST._ClearMelee()
ST._SetRepeating(false)       -- not shooting
HKTest.state.playerCombat = false   -- and not in a fight (see melee rule below)
ST.Refresh()
check("off: an idle bar is hidden", ST.IsShown() == false)

HK.db.shottimer.always = true
ST.RescanSettings()
ST.Refresh()
check("on: the bar stays on screen while idle", ST.IsShown() == true)
check("...and reports itself idle", ST.IsIdle() == true)
check("...and does not burn a frame loop doing nothing",
  ST.IsAnimating() == false)

-- It must still work normally once you actually start shooting.
Shooting(3.0, 4000)
check("...but animates again once shooting", ST.IsAnimating() == true,
  tostring(ST.IsAnimating()))
check("...and is no longer idle", ST.IsIdle() == false)
HK.db.shottimer.always = false
ST.RescanSettings()


-- ---------------------------------------------------------------------------
-- 17) THE SPEEDRUNNER PATTERN
--
-- Pet holds a distant target, you shoot it, and you melee a SECOND target stood
-- next to you. All three cycles -- ranged, melee, specials -- must be legible
-- at once, and the melee row must be there BEFORE the first swing lands (that
-- is the moment you need it most).
-- ---------------------------------------------------------------------------
HK.db.shottimer.weave = true
HK.db.shottimer.showSpecials = true
ST.RescanSettings()

SpecialsOnCD(3200)
ST._ClearMelee()                    -- never swung: just walked up to the target
Shooting(3.3, 3200)
At(3200)
ST.OnUpdate()
check("the melee row is visible before you have ever swung",
  ST.MeleeTrackShown() == true)
check("the specials row is visible too", ST.SpecialPipsShown() == true)
check("the shot bar itself is up", ST.IsShown() == true)

-- All three at once, mid-fight.
ST._OnMeleeSwing(3199)
At(3200)
ST.OnUpdate()
check("ranged, melee and specials are all readable together",
  ST.IsShown() and ST.MeleeTrackShown() and ST.SpecialPipsShown())

-- ---------------------------------------------------------------------------
-- 18) SPECIALS GATE THE WEAVE CUE
-- ---------------------------------------------------------------------------
SpecialsOnCD(3300)
Shooting(3.3, 3300)
ST._OnMeleeSwing(3290)
check("with both specials down, weaving is on", ST.CanWeave(3300) == true)
local down, aimedIn, multiIn = ST.SpecialsDown(3300)
check("...and both report time remaining", down == true and aimedIn > 0 and multiIn > 0,
  string.format("aimed %.1f multi %.1f", aimedIn, multiIn))

-- Aimed comes back up: spend it, do not run to melee.
HKTest.state.cooldowns = { [2643] = { 3300, 10 } }   -- only Multi still down
check("an available Aimed Shot outranks a weave", ST.CanWeave(3300) == false)
check("...and SpecialsDown says so", (ST.SpecialsDown(3300)) == false)

-- Same for Multi.
HKTest.state.cooldowns = { [19434] = { 3300, 6 } }
check("an available Multi-Shot outranks a weave too", ST.CanWeave(3300) == false)

-- The gate is optional: max-weavers weave around their specials.
SpecialsReady()
HK.db.shottimer.specials = false
ST.RescanSettings()
check("with the gate off, raw timing decides", ST.CanWeave(3300) == true)
HK.db.shottimer.specials = true
ST.RescanSettings()

-- A bare global cooldown must not read as "on cooldown", or the row would
-- flicker on every single button press.
HKTest.state.cooldowns = { [19434] = { 3300, 1.5 }, [2643] = { 3300, 1.5 } }
check("the global cooldown is not a real cooldown",
  (ST.SpecialsDown(3300)) == false)
SpecialsOnCD(3300)

-- Switching the row off hides it but leaves the melee strip alone.
HK.db.shottimer.showSpecials = false
ST.RescanSettings()
Shooting(3.3, 3400)
ST._OnMeleeSwing(3390)
At(3400)
ST.OnUpdate()
check("specials row off: pips hidden", ST.SpecialPipsShown() == false)
check("...but the melee strip stays", ST.MeleeTrackShown() == true)
HK.db.shottimer.showSpecials = true
ST.RescanSettings()

-- Weaving off hides the melee row entirely.
HK.db.shottimer.weave = false
ST.RescanSettings()
At(3400)
ST.OnUpdate()
check("weaving off: no melee row", ST.MeleeTrackShown() == false)
HK.db.shottimer.weave = true
ST.RescanSettings()
HKTest.state.cooldowns = {}

check("the specials row is OFF by default -- it is extra clutter",
  HK.defaults.shottimer.showSpecials == false)
check("the specials gate is on by default", HK.defaults.shottimer.specials == true)

-- ---------------------------------------------------------------------------
-- 19) DRAGGING: the bar must stay where it is dropped
--
-- Regression: the drag loop pins the frame with SetPoint("CENTER", UIParent,
-- "BOTTOMLEFT", ...), but ShotTimer had no saveFromScreen, so the generic
-- fallback saved those raw BOTTOMLEFT coords and ApplyPosition re-applied them
-- as CENTRE offsets -- the bar jumped to the upper right on lock.
-- ---------------------------------------------------------------------------
local d = HK.draggables["shottimer"]
check("the shot bar converts its drop point to centre space", 
  d and d.opts and d.opts.saveFromScreen ~= nil)


-- ---------------------------------------------------------------------------
-- 20) THE BAR MUST SURVIVE WALKING INTO MELEE
--
-- Regression: stepping into melee range stops auto-repeat, which hid the whole
-- bar -- exactly when a weaving hunter needs it. The melee row is the reason
-- you are stood there, and the ranged cycle is still running behind it. Other
-- swing-timer addons (Super Swing Timer) keep both bars up for the same reason.
-- ---------------------------------------------------------------------------
HK.db.shottimer.always = false
HK.db.shottimer.weave = true
ST.RescanSettings()

HKTest.state.playerCombat = true
Shooting(3.0, 5000)
check("shooting: the bar is up", ST.IsShown() == true)

-- Walk in: auto-repeat stops, but we are still fighting.
ST._SetRepeating(false)
ST.Refresh()
check("in melee, the bar stays up so you can weave", ST.IsShown() == true)
check("...and the melee row is there", ST.MeleeTrackShown() == true)

-- Out of combat it should still pack itself away.
HKTest.state.playerCombat = false
ST.Refresh()
check("out of combat, the bar goes away again", ST.IsShown() == false)

-- With weaving off there is no reason to hold it up in melee.
HKTest.state.playerCombat = true
HK.db.shottimer.weave = false
ST.RescanSettings()
ST._SetRepeating(false)
ST.Refresh()
check("weaving off: melee does not keep the bar up", ST.IsShown() == false)
HK.db.shottimer.weave = true
ST.RescanSettings()
HKTest.state.playerCombat = false


-- ---------------------------------------------------------------------------
-- 21) SWITCHING A ROW OFF MUST TAKE EFFECT ON THE SAME CLICK
--
-- Regression: unticking "show Aimed/Multi" left the pips on screen until some
-- later animation frame repainted -- and when the bar was idle or the fight had
-- ended, no such frame ever came, so they lingered (sometimes as bare green
-- bars) for seconds. Every teardown path now clears the optional rows.
-- ---------------------------------------------------------------------------
HKTest.state.playerCombat = true
HK.db.shottimer.weave = true
HK.db.shottimer.showSpecials = true
ST.RescanSettings()
SpecialsOnCD(6000)
Shooting(3.3, 6000)
ST._OnMeleeSwing(5990)
At(6000)
ST.OnUpdate()
check("pips are up to start with", ST.SpecialPipsShown() == true)

HK.db.shottimer.showSpecials = false
ST.RescanSettings()                       -- no OnUpdate in between
check("unticking the specials row removes it immediately",
  ST.SpecialPipsShown() == false)

-- The case that actually bit: the bar is up but IDLE (in melee, auto-repeat
-- stopped). There is no animation frame coming to repaint it, so unticking a
-- row has to clear it there and then rather than waiting for one.
HK.db.shottimer.showSpecials = true
ST.RescanSettings()
ST._SetRepeating(false)
At(6050)                                  -- cycle long expired
ST.Refresh()
check("idle in melee: the bar is still up", ST.IsShown() == true)
check("idle in melee: pips are drawn", ST.SpecialPipsShown() == true)
HK.db.shottimer.showSpecials = false
ST.RescanSettings()
check("unticking while the bar is IDLE also removes them at once",
  ST.SpecialPipsShown() == false)
HK.db.shottimer.showSpecials = true
Shooting(3.3, 6060)
ST._OnMeleeSwing(6050)
At(6060)
ST.OnUpdate()

HK.db.shottimer.showSpecials = true
ST.RescanSettings()
At(6000)
ST.OnUpdate()
check("re-ticking brings it back", ST.SpecialPipsShown() == true)

-- Same for the weave/melee row.
check("melee row is up", ST.MeleeTrackShown() == true)
HK.db.shottimer.weave = false
ST.RescanSettings()
check("unticking the weave marker removes the melee row immediately",
  ST.MeleeTrackShown() == false)
check("...and takes the pips with it (they are part of weaving)",
  ST.SpecialPipsShown() == false)
HK.db.shottimer.weave = true
ST.RescanSettings()

-- ---------------------------------------------------------------------------
-- 22) NOTHING MAY LINGER WHEN THE BAR GOES AWAY
--
-- Child textures do NOT hide with their parent frame: an explicitly-shown child
-- keeps its own state. Hiding the bar therefore has to hide them by hand, or
-- they reappear the moment the frame is shown again.
-- ---------------------------------------------------------------------------
SpecialsOnCD(6100)
Shooting(3.3, 6100)
ST._OnMeleeSwing(6090)
At(6100)
ST.OnUpdate()
check("everything is up mid-fight", ST.IsShown() and ST.MeleeTrackShown()
  and ST.SpecialPipsShown())

HKTest.state.playerCombat = false          -- fight ends
ST._SetRepeating(false)
ST.Refresh()
check("the bar goes away", ST.IsShown() == false)
check("...and leaves no melee row behind", ST.MeleeTrackShown() == false)
check("...and no stray pips", ST.SpecialPipsShown() == false)
check("...and no weave marker", ST.WeaveMarkShown() == false)
HKTest.state.playerCombat = false

-- ---------------------------------------------------------------------------
-- 23) THE MELEE TRACK MUST ACTUALLY BE VISIBLE
--
-- It was drawn black at 50% alpha, which against a dark UI is nothing at all --
-- and with no swing observed the fill is empty, so the whole row looked absent.
-- ---------------------------------------------------------------------------
local r, g, b, a = ST.MeleeTrackColor()
check("the melee track is not invisible black",
  (r + g + b) > 0.3, string.format("%.2f,%.2f,%.2f", r or 0, g or 0, b or 0))
check("...and is solid enough to see", (a or 0) >= 0.7, tostring(a))


-- ---------------------------------------------------------------------------
-- 24) THE MELEE BAR MUST FILL LIKE THE RANGED ONE
--
-- Regression: IsIdle() only asked whether the RANGED cycle was running. In
-- melee range auto-repeat stops, so it reported "idle", parked the OnUpdate
-- loop and blanked the fill -- leaving a dead grey strip that never loaded,
-- even though the melee swing behind it was ticking the whole time.
-- ---------------------------------------------------------------------------
HKTest.state.playerCombat = true
HKTest.state.meleeSpeed = 2.4
HK.db.shottimer.weave = true
HK.db.shottimer.always = false
ST.RescanSettings()

-- Shooting: the melee bar advances with the swing.
SpecialsOnCD(7000)
Shooting(3.3, 7000)
ST._OnMeleeSwing(7000)
At(7000.6); ST.OnUpdate()
local w1 = ST.MeleeFillWidth()
At(7001.8); ST.OnUpdate()
local w2 = ST.MeleeFillWidth()
check("at range, the melee bar fills as the swing comes up", w2 > w1,
  string.format("%.1f -> %.1f", w1, w2))

-- Now walk into melee: auto-repeat stops, the ranged cycle dies.
ST._SetRepeating(false)
At(7003)
ST.Refresh()
check("in melee the bar is still up", ST.IsShown() == true)
check("...and is NOT considered idle -- the melee swing is live",
  ST.IsIdle() == false)
check("...so the animation keeps running", ST.IsAnimating() == true)

ST._OnMeleeSwing(7003)
At(7003.6); ST.Refresh()
local m1 = ST.MeleeFillWidth()
At(7004.8); ST.Refresh()
local m2 = ST.MeleeFillWidth()
check("the melee bar loads in melee, just like the ranged bar does",
  m2 > m1 and m1 > 0, string.format("%.1f -> %.1f", m1, m2))

-- It must still go quiet once you stop swinging, or it animates forever.
At(7003 + (2.4 * 3))
ST.Refresh()
check("long after the last swing, the melee cycle is treated as over",
  ST.IsIdle() == true)
check("...and the loop is released", ST.IsAnimating() == false)

HKTest.state.playerCombat = false
ST._ClearMelee()


-- ---------------------------------------------------------------------------
-- 25) A SWING MUST WAKE THE BAR UP BY ITSELF
--
-- Regression: the update loop only runs while something is animating. With no
-- ranged cycle (you walked into melee, or never fired at all) the bar was
-- parked, and nothing re-evaluated that when a swing arrived -- so the melee
-- strip stayed frozen at zero until some unrelated event called Refresh.
-- Toggling a setting was one such event, which is exactly why the timer
-- "started working" only after re-checking the box.
-- ---------------------------------------------------------------------------
HKTest.state.playerCombat = true
HKTest.state.meleeSpeed = 2.4
HK.db.shottimer.weave = true
HK.db.shottimer.always = false
ST.RescanSettings()

-- Melee only: never fired a shot this fight.
ST._SetRepeating(false)
ST._ClearMelee()
At(8000)
ST.Refresh()
check("melee-only: the bar is up", ST.IsShown() == true)
check("...and parked, with nothing to animate yet", ST.IsAnimating() == false)

-- The first swing arrives through the real combat-log path.
At(8000)
HKTest.state.clevent = { 0, "SWING_DAMAGE", false, UnitGUID("player") }
ST._OnCombatLog()
check("a swing wakes the bar up on its own", ST.IsAnimating() == true,
  "no settings toggle should be needed")

At(8000.6); ST.OnUpdate()
local a = ST.MeleeFillWidth()
At(8001.4); ST.OnUpdate()
local b = ST.MeleeFillWidth()
check("...and the melee bar fills from that first swing", b > a and a > 0,
  string.format("%.1f -> %.1f", a, b))
HKTest.state.clevent = nil
HKTest.state.playerCombat = false
ST._ClearMelee()


-- ---------------------------------------------------------------------------
-- 26) A MELEE HIT MUST NOT WIPE THE RANGED TIMER
--
-- Regression: STOP_AUTOREPEAT_SPELL cleared nextAt. Stepping into melee stops
-- auto-repeat, so the ranged bar collapsed to empty the moment the melee weapon
-- connected -- exactly when a weaver needs to see the rest of the shot cycle.
-- In Era the cycles are independent (melee resetting ranged is WotLK-only
-- behaviour), so the prediction stays valid and must keep running.
-- ---------------------------------------------------------------------------
HKTest.state.playerCombat = true
HK.db.shottimer.weave = true
ST.RescanSettings()

Shooting(3.3, 9000)
At(9000.5); ST.OnUpdate()
local beforeFill = ST.FillWidth()
local beforeLabel = ST.LabelText()
check("shooting: the ranged bar is filling", beforeFill > 1,
  string.format("%.1f", beforeFill))

-- Run in and connect with the melee weapon. Drive the REAL event, not the
-- _SetRepeating seam: the bug lived in the STOP_AUTOREPEAT_SPELL handler, so a
-- test that bypasses it proves nothing.
local stopAuto = HK.bus.handlers["STOP_AUTOREPEAT_SPELL"]
check("the stop-autorepeat handler is registered", stopAuto ~= nil)
At(9001.2)
if stopAuto then stopAuto() end
ST.OnUpdate()
local afterFill = ST.FillWidth()
check("the ranged bar survives the melee hit", afterFill > beforeFill,
  string.format("%.1f -> %.1f (label %s -> %s)", beforeFill, afterFill,
    tostring(beforeLabel), tostring(ST.LabelText())))
check("...and still shows a countdown", (ST.LabelText() or "") ~= "",
  tostring(ST.LabelText()))
check("...and the cycle is not considered idle", ST.IsIdle() == false)

-- Once the predicted shot time has passed with nothing new, it does expire
-- rather than counting down forever.
At(9010)
ST.Refresh()
check("a long-expired prediction goes idle", ST.IsIdle() == true)

-- Leaving combat still ends the series outright.
Shooting(3.3, 9020)
local regen = HK.bus.handlers["PLAYER_REGEN_ENABLED"]
if regen then regen() end
check("leaving combat still clears the cycle", ST.IsIdle() == true)
HKTest.state.playerCombat = false


-- ---------------------------------------------------------------------------
-- 27) THE TWO BARS MUST READ THE SAME WAY
--
-- They are stacked on top of each other and mean the same thing -- "this weapon
-- is charging toward its next hit" -- so they must share a visual vocabulary.
-- They had drifted apart: different track shades (black vs slate), a different
-- charging colour (green vs amber), and a "ready" state only the melee bar had.
-- Both now come from one palette; the only differences left are real mechanics.
-- ---------------------------------------------------------------------------
local function SameColor(a, b)
  if not a or not b then return false end
  for i = 1, 4 do
    if math.abs((a[i] or 0) - (b[i] or 0)) > 0.001 then return false end
  end
  return true
end
local function Grab(fn)
  local r, g, b, al = fn()
  if not r then return nil end
  return { r, g, b, al }
end

HKTest.state.playerCombat = true
HKTest.state.meleeSpeed = 2.4
HK.db.shottimer.weave = true
ST.RescanSettings()

check("both bars sit on the same coloured track",
  SameColor(Grab(ST.RangedTrackColor), Grab(ST.MeleeTrackColor)),
  "the unfilled bed must look the same for both")

-- Mid-cycle: both winding up, both must be the same "charging" colour.
Shooting(3.3, 11000)
ST._OnMeleeSwing(11000)
At(11000.5); ST.OnUpdate()
local rCharge = Grab(ST.FillColor)
local mCharge = Grab(ST.MeleeFillColor)
check("a charging ranged bar and a charging melee bar match",
  SameColor(rCharge, mCharge),
  string.format("ranged %s vs melee %s",
    table.concat(rCharge or {}, ","), table.concat(mCharge or {}, ",")))

-- Both must GROW toward the hit, not drain away from it.
local r1, m1 = ST.FillWidth(), ST.MeleeFillWidth()
At(11001.4); ST.OnUpdate()
check("both bars fill toward the hit, in the same direction",
  ST.FillWidth() > r1 and ST.MeleeFillWidth() > m1,
  string.format("ranged %.0f->%.0f melee %.0f->%.0f",
    r1, ST.FillWidth(), m1, ST.MeleeFillWidth()))

-- A melee swing that has come up reads READY; so does a ranged shot about to
-- fire. Same colour for the same meaning.
ST._OnMeleeSwing(11000 - 2.4)          -- swing is due now
At(11000.6); ST.OnUpdate()
local mReady = Grab(ST.MeleeFillColor)
Shooting(3.3, 11010)
At(11010 + 3.3 - 0.2); ST.OnUpdate()   -- inside the 0.5s cast window
local rLocked = Grab(ST.FillColor)
check("a ready melee swing is not drawn as though it were charging",
  not SameColor(mReady, mCharge), "ready and charging must differ")
check("the ranged lockout is its own distinct colour",
  not SameColor(rLocked, rCharge) and not SameColor(rLocked, mReady),
  "the clip warning must not be confusable with anything else")

-- Idle: neither bar leaves a stray fill behind.
ST._SetRepeating(false)
ST._ClearMelee()
At(11100)
ST.Refresh()
check("an idle ranged bar shows no fill", ST.FillWidth() <= 1,
  string.format("%.1f", ST.FillWidth()))
check("an idle melee bar shows no fill", ST.MeleeFillWidth() <= 1,
  string.format("%.1f", ST.MeleeFillWidth()))
HKTest.state.playerCombat = false


-- ---------------------------------------------------------------------------
-- 28) THE PER-FRAME REDRAW MUST NOT DO POINTLESS WORK
--
-- OnUpdate runs on EVERY rendered frame (60-150+ Hz), but almost nothing it
-- draws changes that fast: the countdown shows one decimal so it changes ~10
-- times a second, the pip countdown once a second, and the colours a handful of
-- times per cycle. Re-issuing identical SetWidth/SetVertexColor/SetText calls
-- was the addon's busiest piece of wasted work. Each write is now gated on the
-- value having actually moved.
--
-- This is a BUDGET, not an exact figure: it fails loudly if a future change
-- starts hammering the widgets again, without pinning the implementation.
-- ---------------------------------------------------------------------------
local writes = 0
local Frame = getmetatable(UIParent) and getmetatable(UIParent).__index
if Frame then
  for _, m in ipairs({ "SetWidth", "SetVertexColor", "SetText",
                       "SetFormattedText", "Show", "Hide" }) do
    local real = Frame[m]
    if real then
      Frame[m] = function(...) writes = writes + 1; return real(...) end
    end
  end

  HKTest.state.playerCombat = true
  HK.db.shottimer.weave = true
  HK.db.shottimer.showSpecials = true
  ST.RescanSettings()
  SpecialsOnCD(12000)
  Shooting(3.3, 12000)
  ST._OnMeleeSwing(12000)

  -- Three seconds of a live cycle at 100 fps.
  At(12000); ST.OnUpdate()
  writes = 0
  local FRAMES = 300
  for i = 1, FRAMES do
    At(12000 + i * 0.01)
    ST.OnUpdate()
  end
  local perFrame = writes / FRAMES

  check("the redraw does not rewrite every widget every frame",
    perFrame < 4, string.format("%.1f widget writes per frame", perFrame))

  -- And it must still be drawing the right thing at the end of that run.
  check("...while still showing a live countdown",
    (ST.LabelText() or "") ~= "", tostring(ST.LabelText()))
  check("...and a filled ranged bar", ST.FillWidth() > 1,
    string.format("%.1f", ST.FillWidth()))
  check("...and a filled melee bar", ST.MeleeFillWidth() > 1,
    string.format("%.1f", ST.MeleeFillWidth()))

  HK.db.shottimer.showSpecials = false
  ST.RescanSettings()
  HKTest.state.playerCombat = false
end


-- ---------------------------------------------------------------------------
-- 29) WHEN TO WEAVE, not just whether
--
-- Ranged and melee run at DIFFERENT speeds, so the two cycles drift against
-- each other and the ideal moment to leave moves every cycle. WeaveWindow finds
-- the departure where the round trip fits in the shot cycle AND the swing is up
-- when you arrive.
-- ---------------------------------------------------------------------------
HKTest.state.playerCombat = true
HKTest.state.meleeSpeed = 2.6            -- deliberately not the ranged speed
HK.db.shottimer.weave = true
HK.db.shottimer.travel = 2.5
HK.db.shottimer.specials = false         -- isolate the timing maths
ST.RescanSettings()

SpecialsOnCD(13000)
Shooting(3.3, 13000)

-- Swing landed 1.2s ago on a 2.6s weapon: next swing in 1.4s. You arrive after
-- travel/2 = 1.25s, so leaving in ~0.15s lines the two up.
ST._OnMeleeSwing(13000 - 1.2)
local best, latest = ST.WeaveWindow(13000)
check("it says how long until the ideal departure",
  best ~= nil and math.abs(best - 0.15) < 0.02,
  tostring(best))
check("...and how long that window stays open",
  latest ~= nil and latest > best, tostring(latest))

-- Wait for that moment: now it should say go.
local goNow = ST.WeaveWindow(13000.2)
check("at the right instant it says go now", goNow ~= nil and goNow <= 0.05,
  tostring(goNow))

At(13000.2); ST.OnUpdate()
check("the bar says GO at that moment",
  (ST.LabelText() or ""):find("GO") ~= nil, tostring(ST.LabelText()))

At(13000); ST.OnUpdate()
check("...and counts down to it beforehand",
  (ST.LabelText() or ""):find("weave in") ~= nil, tostring(ST.LabelText()))

-- Too late in the cycle: the trip no longer fits, so no advice at all.
check("no window once the trip cannot fit", ST.WeaveWindow(13002.5) == nil)

-- A swing that only comes up AFTER the last safe departure is unusable: going
-- would mean standing in melee waiting while the shot locks out.
Shooting(3.3, 13100)
ST._OnMeleeSwing(13100)                  -- 2.6s away, far later than the window
check("a swing that lands too late is not advised",
  ST.WeaveWindow(13100) == nil, tostring(ST.WeaveWindow(13100)))
check("...and CanWeave agrees", ST.CanWeave(13100) == false)

-- With no swing ever observed there is no melee clock to line up against, so it
-- must not invent one -- just report that the trip fits.
Shooting(3.3, 13200)
ST._ClearMelee()
local noClock = ST.WeaveWindow(13200)
check("with no observed swing it still reports the plain window",
  noClock == 0, tostring(noClock))

-- Weaving switched off: no advice at all.
HK.db.shottimer.weave = false
ST.RescanSettings()
check("no weave advice when weaving is off", ST.WeaveWindow(13200) == nil)
HK.db.shottimer.weave = true
HK.db.shottimer.specials = true
ST.RescanSettings()
HKTest.state.playerCombat = false


-- ---------------------------------------------------------------------------
-- 30) AN UNTRAINED SPECIAL MUST NOT VETO EVERY WEAVE
--
-- Regression: SpecialsDown required BOTH Aimed and Multi to be on cooldown. A
-- spell you have not trained reports no cooldown, so it read as permanently
-- "ready to spend" and the weave gate vetoed every weave for the whole session.
-- A spell you cannot cast has no business blocking anything.
-- ---------------------------------------------------------------------------
HKTest.state.playerCombat = true
HK.db.shottimer.weave = true
HK.db.shottimer.specials = true
ST.RescanSettings()

-- No Aimed Shot trained; Multi is on cooldown.
HKTest.state.spellKnown = { [19434] = false }
HKTest.state.cooldowns = { [2643] = { 14000, 10 } }
local down, aimedIn = ST.SpecialsDown(14000)
check("an untrained Aimed Shot is not counted as ready", down == true,
  "only the specials you actually have may gate a weave")
check("...and reports no cooldown at all", aimedIn == nil, tostring(aimedIn))

-- Both untrained: nothing to spend, so nothing to wait for.
HKTest.state.spellKnown = { [19434] = false, [2643] = false }
HKTest.state.cooldowns = {}
check("with neither special trained, weaving is never gated",
  (ST.SpecialsDown(14000)) == true)

-- Trained and ready again: the gate works as before.
HKTest.state.spellKnown = {}
check("a trained, ready special still blocks the weave",
  (ST.SpecialsDown(14000)) == false)

-- ---------------------------------------------------------------------------
-- 31) THE BAR SAYS WHY IT IS NOT SUGGESTING A WEAVE
--
-- Falling silent looks like the feature is broken. "shoot" tells you the
-- actionable thing: spend the special you are holding first.
-- ---------------------------------------------------------------------------
HKTest.state.rangedSpeed = 3.3
HKTest.state.cooldowns = {}            -- both specials READY
ST.RescanSettings()
Shooting(3.3, 14100)
ST._OnMeleeSwing(14100 - 1.0)
local _, _, why = ST.WeaveWindow(14100)
check("it reports that a special is why there is no weave",
  why == "specials", tostring(why))
At(14100); ST.OnUpdate()
check("the bar tells you to shoot instead of going silent",
  (ST.LabelText() or ""):find("shoot") ~= nil, tostring(ST.LabelText()))

-- A weapon too fast for the round trip reports a different reason.
HKTest.state.rangedSpeed = 2.6
ST.RescanSettings()
SpecialsOnCD(14200)
Shooting(2.6, 14200)
ST._OnMeleeSwing(14200)
local _, _, why2 = ST.WeaveWindow(14200)
check("a weapon too fast to weave with says so", why2 == "tooslow",
  tostring(why2))

HKTest.state.rangedSpeed = 3.3
HKTest.state.cooldowns = {}
HKTest.state.spellKnown = {}
ST.RescanSettings()
HKTest.state.playerCombat = false


-- ---------------------------------------------------------------------------
-- 32) STATIC WEAVING: already standing in melee
--
-- The whole weave model was built around running out and back, so it charged a
-- 2.5s round trip even when the target was at your feet. That silenced the
-- advice completely for the standard speedrun setup: pet holds a distant mob
-- you shoot with a mouseover macro, while a SECOND mob stands next to you and
-- is your target. You never move, so there is no trip to pay for -- the only
-- question is whether a swing fits before the shot locks out.
-- ---------------------------------------------------------------------------
HKTest.state.playerCombat = true
HKTest.state.rangedSpeed = 3.3
HKTest.state.meleeSpeed = 2.4
HK.db.shottimer.weave = true
HK.db.shottimer.travel = 2.5
-- These scenarios are about the ROUND-TRIP ("normal") weave, which is opt-in:
-- by default the bar only advises a weave you can take without moving.
HK.db.shottimer.travelWeave = true
ST.RescanSettings()

HKTest.state.target = "target"
HKTest.state.targetTooClose = true          -- the adjacent mob is in melee
check("the addon can tell you are already in melee",
  ST.InMeleeOfTarget() == true)

SpecialsOnCD(15000)
Shooting(3.3, 15000)
ST._OnMeleeSwing(15000 - 1.0)               -- swing due in 1.4s

-- 1.4s to the swing, 2.8s of free time: trivially weaveable standing still,
-- but impossible if a 2.5s round trip is (wrongly) charged.
local best, latest = ST.WeaveWindow(15000)
check("standing in melee, it advises the weave",
  best ~= nil, "no round trip to pay for")
check("...counting down to the swing itself",
  best ~= nil and math.abs(best - 1.4) < 0.05, tostring(best))

At(15000); ST.OnUpdate()
check("the bar counts down to the static weave",
  (ST.LabelText() or ""):find("weave in") ~= nil, tostring(ST.LabelText()))

At(15001.4); ST.OnUpdate()
check("and says GO when the swing is up",
  (ST.LabelText() or ""):find("GO") ~= nil, tostring(ST.LabelText()))

-- The SAME timings at range must still charge the full round trip, and so
-- must NOT advise a weave here.
HKTest.state.targetTooClose = false
SpecialsOnCD(15100)
Shooting(3.3, 15100)
ST._OnMeleeSwing(15100 - 1.0)
-- At range the trip IS charged, so the advice is different: you must leave
-- almost immediately (0.15s) to arrive as the swing comes up, and the window
-- slams shut 0.3s later. Standing in melee, the same timings give you the full
-- 1.4s to wait. Same fight, different answer -- which is the point.
local rBest, rLatest = ST.WeaveWindow(15100)
check("at range the round trip is still charged",
  rBest ~= nil and rBest < 0.5 and rLatest ~= nil and rLatest < 0.5,
  string.format("best=%s latest=%s -- must be a tight window, not the 1.4s "
    .. "wait a static weaver gets", tostring(rBest), tostring(rLatest)))
check("...and InMeleeOfTarget says so", ST.InMeleeOfTarget() == false)

-- No target at all: no static weave, fall back to the travel model.
HKTest.state.target = nil
check("no target means no static weave", ST.InMeleeOfTarget() == false)
HKTest.state.target = "target"

-- A dead target is not something you are meleeing.
HKTest.state.targetTooClose = true
HKTest.state.dead = { target = true }
check("a dead target does not count as melee range",
  ST.InMeleeOfTarget() == false)
HKTest.state.dead = {}

HKTest.state.targetTooClose = false
HKTest.state.playerCombat = false
ST.RescanSettings()


-- ---------------------------------------------------------------------------
-- 33) TRAVEL WEAVING IS OPT-IN
--
-- Running out to a distant target and back ("normal" weaving) is a real Era
-- technique, but it is the advanced, movement-heavy case. By default the bar
-- must only ever advise a melee hit you can take WITHOUT MOVING -- so with a
-- target at range it stays quiet no matter how roomy the shot cycle is.
-- ---------------------------------------------------------------------------
check("travel weaving is off by default",
  HK.defaults.shottimer.travelWeave == false)

HKTest.state.playerCombat = true
HKTest.state.rangedSpeed = 3.5           -- deliberately roomy: 3.0s of free time
HKTest.state.meleeSpeed = 2.4
HK.db.shottimer.weave = true
HK.db.shottimer.travel = 2.5
HK.db.shottimer.travelWeave = false      -- the default
ST.RescanSettings()

HKTest.state.target = "target"
HKTest.state.targetTooClose = false      -- target is at RANGE
SpecialsOnCD(16000)
Shooting(3.5, 16000)
ST._OnMeleeSwing(16000 - 1.2)

local best, _, why = ST.WeaveWindow(16000)
check("by default it never tells you to run in", best == nil,
  "a target at range must not produce weave advice")
check("...and says that is why", why == "notinmelee", tostring(why))
check("...and CanWeave agrees", ST.CanWeave(16000) == false)

At(16000); ST.OnUpdate()
check("the bar shows a plain countdown, no weave cue",
  (ST.LabelText() or ""):find("weave") == nil
    and (ST.LabelText() or ""):find("GO") == nil, tostring(ST.LabelText()))

-- Static weaving still works with travel weaving off -- that is the point.
HKTest.state.targetTooClose = true
local sBest = ST.WeaveWindow(16000)
check("a target already in melee is still advised", sBest ~= nil,
  "static weaving must not need the travel option")

-- Switch travel weaving ON and the range case comes back.
HKTest.state.targetTooClose = false
HK.db.shottimer.travelWeave = true
ST.RescanSettings()
check("turning it on restores the round-trip advice",
  ST.WeaveWindow(16000) ~= nil)

HK.db.shottimer.travelWeave = false
HKTest.state.targetTooClose = false
HKTest.state.playerCombat = false
ST.RescanSettings()


-- ---------------------------------------------------------------------------
-- 34) THE STATIC WEAVE NEEDS A VISIBLE MARKER, NOT JUST TEXT
--
-- The blue marker was computed once in ApplySize from the TRAVEL model: "the
-- last moment you could leave for a 2.5s round trip". For a static weaver that
-- number is meaningless -- it sat at ~9% of the bar while the actual swing
-- landed at 42% -- so the only real cue was the label. The marker is now drawn
-- live from whichever model applies, and marks the moment your hit belongs.
-- ---------------------------------------------------------------------------
HKTest.state.playerCombat = true
HKTest.state.rangedSpeed = 3.3
HKTest.state.meleeSpeed = 2.4
HK.db.shottimer.weave = true
HK.db.shottimer.travelWeave = false      -- default: static weaving only
ST.RescanSettings()

HKTest.state.target = "target"
HKTest.state.targetTooClose = true       -- standing in melee
SpecialsOnCD(17000)
Shooting(3.3, 17000)
ST._OnMeleeSwing(17000 - 1.0)            -- swing due in 1.4s of a 3.3s cycle

At(17000); ST.OnUpdate()
check("static weaving shows the marker", ST.WeaveMarkShown() == true)

-- 1.4s into a 3.3s cycle is ~42% along a 220px bar, NOT the ~9% the old
-- travel-derived marker used.
local x = ST.WeaveMarkX()
local w = HK.db.shottimer.width or 220
check("...positioned at the swing, not at a travel departure point",
  x ~= nil and math.abs((x / w) - 0.42) < 0.06,
  string.format("%.0f%% along the bar", (x or 0) / w * 100))

-- It must hold still while the bar fills toward it: the swing lands at a fixed
-- point in this cycle, so a marker that drifted would be lying.
At(17000.7); ST.OnUpdate()
check("...and holds its place as the bar fills",
  math.abs((ST.WeaveMarkX() or -1) - x) < 1,
  string.format("%.1f -> %.1f", x or -1, ST.WeaveMarkX() or -1))

-- On arrival it turns the same "ready" green the bars use.
local rBefore = { ST.WeaveMarkColor() }
At(17001.4); ST.OnUpdate()
local rAfter = { ST.WeaveMarkColor() }
check("the marker goes green when it is time to swing",
  rAfter[1] ~= nil and rAfter[2] > 0.9 and rAfter[1] > 0.4,
  string.format("%.2f,%.2f,%.2f", rAfter[1] or -1, rAfter[2] or -1, rAfter[3] or -1))
check("...having been blue while it was still ahead",
  rBefore[3] ~= nil and rBefore[3] > 0.9 and rBefore[1] < 0.5,
  string.format("%.2f,%.2f,%.2f", rBefore[1] or -1, rBefore[2] or -1, rBefore[3] or -1))

-- With no weave available at all there must be no marker to mislead you.
HKTest.state.targetTooClose = false      -- at range, travel weaving off
At(17000); ST.OnUpdate()
check("no marker when no weave is advised", ST.WeaveMarkShown() == false)

HKTest.state.targetTooClose = false
HKTest.state.playerCombat = false
ST.RescanSettings()


-- ---------------------------------------------------------------------------
-- 35) STATIC WEAVING MUST NOT DEPEND ON WHAT YOU HAVE TARGETED
--
-- The two-mob case: pet tanks a distant mob you shoot, a second mob melees you.
-- InMeleeOfTarget asked only about "target", so the advice appeared ONLY when
-- you happened to target the melee mob. Target the distant one -- or nothing at
-- all, which a mouseover auto-shot macro encourages -- and it went silent,
-- exactly when static weaving is what you are doing.
-- ---------------------------------------------------------------------------
HKTest.state.playerCombat = true
HKTest.state.rangedSpeed = 3.3
HKTest.state.meleeSpeed = 2.4
HK.db.shottimer.weave = true
HK.db.shottimer.travelWeave = false
ST.RescanSettings()

local function TwoMobScene(t)
  SpecialsOnCD(t)
  Shooting(3.3, t)
  ST._OnMeleeSwing(t - 1.0)          -- swing due in 1.4s
  At(t); ST.OnUpdate()
end

-- (a) targeting the melee mob -- the only case that used to work
HKTest.state.target = "target"
HKTest.state.units = {}
HKTest.state.inMelee = { target = true }
TwoMobScene(18000)
local a = ST.WeaveWindow(18000)
check("targeting the melee mob: advice shown", a ~= nil, tostring(a))

-- (b) targeting the DISTANT mob the pet is tanking; the melee mob is the one
--     attacking me, i.e. targettarget
HKTest.state.target = "target"
HKTest.state.units = { targettarget = true }
HKTest.state.inMelee = { target = false, targettarget = true }
TwoMobScene(18100)
local b = ST.WeaveWindow(18100)
check("targeting the DISTANT mob: advice still shown", b ~= nil,
  "a mob is in melee of you regardless of what you have selected")

-- (c) pure mouseover macro: no target at all, melee mob under the cursor
HKTest.state.target = nil
HKTest.state.units = { mouseover = true }
HKTest.state.inMelee = { mouseover = true }
TwoMobScene(18200)
local c = ST.WeaveWindow(18200)
check("shooting via mouseover with no target: advice still shown", c ~= nil,
  "a mouseover macro must not blind the weave advice")

-- (d) the pet's target is the one at your feet
HKTest.state.target = nil
HKTest.state.units = { pettarget = true }
HKTest.state.inMelee = { pettarget = true }
TwoMobScene(18300)
check("the pet's target in melee also counts",
  ST.WeaveWindow(18300) ~= nil)

-- All four situations describe the same fight, so they must agree.
check("...and every route gives the same advice",
  a ~= nil and b ~= nil and c ~= nil
    and math.abs(a - b) < 0.01 and math.abs(a - c) < 0.01,
  string.format("%s / %s / %s", tostring(a), tostring(b), tostring(c)))

-- Nothing actually in melee: no static weave, whatever exists at range.
HKTest.state.target = "target"
HKTest.state.units = { pettarget = true, targettarget = true }
HKTest.state.inMelee = { target = false, pettarget = false,
                         targettarget = false, mouseover = false }
TwoMobScene(18400)
check("with everything at range there is no static weave",
  ST.WeaveWindow(18400) == nil)
check("...and InMeleeOfTarget says so", ST.InMeleeOfTarget() == false)

-- A dead mob at your feet is not a weave target.
HKTest.state.inMelee = { target = true }
HKTest.state.dead = { target = true }
check("a dead mob in melee does not count", ST.InMeleeOfTarget() == false)
HKTest.state.dead = {}

HKTest.state.units = {}
HKTest.state.inMelee = {}
HKTest.state.targetTooClose = false
HKTest.state.playerCombat = false
ST.RescanSettings()


-- ---------------------------------------------------------------------------
-- 8) THE TWO-MOB WEAVE
--
-- One mob standing in your melee, a second one held at range by your pet. This
-- is the setup the "Two-mob weave" macro in Macros.lua exists for, and until
-- now the bar said NOTHING about it: its only weave marker was the travel-weave
-- departure point (run out to melee and back), which is opt-in and rarely
-- applies. So the situation the addon shipped a macro for was the one it would
-- not show.
--
-- What makes pressing that macro correct, derived from what it actually does:
-- `target` alive and in melee (or /startattack hits nothing), `pettarget`
-- alive and a DIFFERENT mob (or every [@pettarget] line is skipped), the melee
-- swing up (or the press only restarts /startattack), and Auto Shot out of its
-- 0.5s lockout (or the /cast !Auto Shot inside the flick is the clip).
-- ---------------------------------------------------------------------------

-- Declares that world. `target` is the mob you are meleeing, `pettarget` the
-- one your pet is holding at range.
local function TwoMobWorld(o)
  o = o or {}
  HKTest.state.target = true
  HKTest.state.targetDead = o.targetDead or nil
  HKTest.state.targetAttackable = o.targetAttackable
  HKTest.state.pet = true
  -- Say so EXPLICITLY rather than by omission. UnitExists falls through to
  -- the threat table when a unit key is absent, and an earlier test file
  -- leaves a pettarget entry on one -- so removing the key would still
  -- report the unit as existing.
  HKTest.state.units = { pettarget = not o.noPetTarget }
  HKTest.state.dead = o.petTargetDead and { pettarget = true } or {}
  HKTest.state.inMelee = o.noMelee and {} or { target = true }
  HKTest.state.guids = o.sameMob
    and { target = "mob-a", pettarget = "mob-a" }
    or  { target = "mob-a", pettarget = "mob-b" }
  HKTest.state.targetSpellInRange = o.oor and 0 or 1
  HKTest.state.playerCombat = true
end

-- A 3.4s weapon with a shot away at t=1000: the shot locks out from 1002.9, so
-- there is a real window in which a 2.4s melee swing can be up while Auto Shot
-- is still free -- which is the only moment the two-mob press is correct.
local db8 = Shooting(3.4, 1000)
local mspd = ST.MeleeSpeed()

TwoMobWorld()
local s8 = ST.TwoMob(1000.5)
check("both mobs are seen", s8.targetLive == true and s8.petLive == true,
  tostring(s8.targetLive) .. "/" .. tostring(s8.petLive))
check("the target really is within melee", s8.inMelee == true)
check("...and it is a DIFFERENT mob from the one the pet holds", s8.distinct == true)
check("so the two-mob setup is live", s8.setup == true)
check("with no melee swing observed yet there is nothing to spend", s8.press == false)

At(1000.2); ST._OnMeleeSwing(1000.2)
s8 = ST.TwoMob(1000.3)
check("a tenth of a second later the swing is still coming", s8.swingUp == false)
check("...so pressing the macro would achieve nothing", s8.press == false)

local swingUp = 1000.2 + mspd
s8 = ST.TwoMob(swingUp + 0.1)
check("the melee swing comes up", s8.swingUp == true, tostring(s8.swingIn))
check("Auto Shot is still outside its lockout there", s8.locked == false)
check("so THAT is the moment to press the two-mob macro", s8.press == true)

-- The lockout veto: the macro flicks your target and casts !Auto Shot, so
-- pressing it inside the 0.5s cast is the very thing that clips.
s8 = ST.TwoMob(1003.2)
check("inside the lockout Auto Shot is locked", s8.locked == true)
check("...and the two-mob press is vetoed even with the swing up",
  s8.swingUp == true and s8.press == false)

-- Every leg of the setup has to hold.
TwoMobWorld({ noPetTarget = true })
check("no pet target means no two-mob setup", ST.TwoMob(1000.5).setup == false)
TwoMobWorld({ petTargetDead = true })
check("a dead pet target means no two-mob setup", ST.TwoMob(1000.5).setup == false)
TwoMobWorld({ sameMob = true })
check("the pet being on YOUR mob is not a second target",
  ST.TwoMob(1000.5).setup == false, "the flick would be a no-op")
TwoMobWorld({ noMelee = true })
check("the melee mob must actually be in melee", ST.TwoMob(1000.5).setup == false)
TwoMobWorld({ targetDead = true })
check("a dead melee mob is not a target", ST.TwoMob(1000.5).setup == false)

-- ---------------------------------------------------------------------------
-- The state strip: the indicator that was missing.
-- ---------------------------------------------------------------------------
TwoMobWorld()
db8.rangeStrip = true
db8.enabled = true
ST.RescanSettings()
At(swingUp + 0.1); ST._OnMeleeSwing(1000.2)
ST.Refresh(); ST.OnUpdate()
check("the strip reports the press", ST.StripText() == "PRESS 2-MOB",
  tostring(ST.StripText()))
check("...and it is actually on screen", ST.StripShown() == true)

TwoMobWorld({ noPetTarget = true })
ST.OnUpdate()
check("one mob in melee and no second target reads MELEE ONLY",
  ST.StripText() == "MELEE ONLY", tostring(ST.StripText()))

TwoMobWorld({ noMelee = true })
ST.OnUpdate()
check("nothing in melee reads RANGE", ST.StripText() == "RANGE",
  tostring(ST.StripText()))

TwoMobWorld({ noMelee = true, oor = true })
ST.OnUpdate()
check("a target past Auto Shot range reads OUT OF RANGE",
  ST.StripText() == "OUT OF RANGE", tostring(ST.StripText()))

db8.rangeStrip = false
ST.RescanSettings(); ST.OnUpdate()
check("unticking the strip takes it off screen", ST.StripShown() == false)
db8.rangeStrip = true
ST.RescanSettings()

-- ---------------------------------------------------------------------------
-- The press icon: a separate frame, because it has to go where your eyes are.
-- ---------------------------------------------------------------------------
check("the two-mob icon frame exists", ST.IconBuilt() == true)
db8.twoMobIcon = false
ST.RescanSettings(); ST.OnUpdate()
check("the icon stays hidden while the option is off", ST.IconShown() == false)

db8.twoMobIcon = true
TwoMobWorld()
ST.RescanSettings()
At(swingUp + 0.1)
ST.OnUpdate()
check("the icon shows once the option is on", ST.IconShown() == true)
check("at full brightness when the press is correct", ST.IconAlpha() == 1.0,
  tostring(ST.IconAlpha()))
check("and says NOW", ST.IconText() == "NOW", tostring(ST.IconText()))

At(1000.3)
ST.OnUpdate()
check("dimmed with a countdown while the swing is still coming",
  (ST.IconAlpha() or 0) < 0.8 and (ST.IconText() or "") ~= "NOW",
  tostring(ST.IconAlpha()) .. " " .. tostring(ST.IconText()))

TwoMobWorld({ noPetTarget = true })
ST.OnUpdate()
check("nearly invisible when there is no setup at all",
  (ST.IconAlpha() or 1) < 0.4, tostring(ST.IconAlpha()))
db8.twoMobIcon = false
ST.RescanSettings(); ST.OnUpdate()

-- ---------------------------------------------------------------------------
-- Bar height: the default went 18 -> 27 (x1.5), and the migration moves only a
-- profile that was still on the untouched default.
-- ---------------------------------------------------------------------------
check("the default bar height is 27", HK.defaults.shottimer.height == 27,
  tostring(HK.defaults.shottimer.height))

HunterKitDB = { dbVersion = 33, shottimer = { height = 18 } }
local HKh = HKTest.LoadAddon(unpack(HKTest.addonFiles))
HKh:Load()
check("an untouched 18px bar is migrated to 27", HKh.db.shottimer.height == 27,
  tostring(HKh.db.shottimer.height))

HunterKitDB = { dbVersion = 33, shottimer = { height = 14 } }
local HKh2 = HKTest.LoadAddon(unpack(HKTest.addonFiles))
HKh2:Load()
check("a height the player chose is never rewritten", HKh2.db.shottimer.height == 14,
  tostring(HKh2.db.shottimer.height))


-- ---------------------------------------------------------------------------
-- The latency end-slice, and the bound on what counts as a clip.
--
-- Regression, shipped in 0.9.71 and reported from game: Redraw drew the slice
-- with SetHeight(h), but `h` is a local of ApplySize -- in Redraw it resolved
-- to the GLOBAL, i.e. nil, and the live client threw
--   bad argument #1 to 'SetHeight' (Usage: self:SetHeight(height))
-- on every single frame. Every check stayed green, because the slice only draws
-- when a clip has actually been measured and NO test ever produced one.
--
-- Asserted here: the height, and that the slice is a small tail rather than
-- most of the bar. (An earlier draft of this claimed the WIDTH formula was also
-- wrong; it was not -- castZoneWidth * secs/CAST_TIME and w * secs/cycle are
-- algebraically identical, and a negative control confirmed the two agree. The
-- 216px-of-220px slice seen in game came entirely from lastDelay being 18.165,
-- i.e. from the unbounded clip measurement tested further down.)
-- ---------------------------------------------------------------------------
local db9 = Shooting(2.035, 1000)
db9.enabled = true
db9.showDelay = true
db9.width = 220
ST.RescanSettings()
At(1002.375)                       -- 0.34s later than predicted: a real clip
ST._OnShotFired(1002.375)
check("a real clip is measured", math.abs((ST.LastDelay() or 0) - 0.34) < 0.02,
  tostring(ST.LastDelay()))
At(1003)
ST.Refresh(); ST.OnUpdate()
check("the latency slice draws without error", ST.LatencyShown() == true)
local expW = math.floor(220 * 0.34 / 2.035)
check("...and it is the size a 0.34s tail should be",
  math.abs((ST.LatencyWidth() or -999) - expW) <= 1,
  string.format("got %s, want ~%d", tostring(ST.LatencyWidth()), expW))
check("...a small tail, not most of the bar",
  (ST.LatencyWidth() or 0) < 110, tostring(ST.LatencyWidth()))

-- A gap where you simply were not shooting is NOT a clip. Without the bound
-- this recorded the whole gap -- lastDelay 18.165, printed as "+18.17s" -- and
-- inflated the clip count. That was pre-existing: the latency slice only made
-- it visible by trying to draw it.
local clips = select(2, ST.Stats())
At(1030)
ST._OnShotFired(1030)
check("a stale prediction is not recorded as a clip", ST.LastDelay() == 0,
  tostring(ST.LastDelay()))
check("...and does not inflate the clip count", select(2, ST.Stats()) == clips,
  string.format("%s vs %s", tostring(select(2, ST.Stats())), tostring(clips)))


-- ---------------------------------------------------------------------------
-- Bar proportions: TWO equal timing bars, and a caption underneath.
--
-- The first cut of this grew everything: at height 27 the state line reached
-- 14px while the melee bar was 9px -- a text line chunkier than the timing bar
-- it was describing. The height request was for the two BARS.
-- ---------------------------------------------------------------------------
local db10 = Shooting(3.0, 1000)
db10.height = 27
db10.width = 220
db10.rangeStrip = true
ST.RescanSettings()
check("the shot bar is the requested height", ST.BarHeight() == 27,
  tostring(ST.BarHeight()))
check("the melee swing bar is the SAME height as the shot bar",
  ST.MeleeBarHeight() == ST.BarHeight(),
  string.format("melee %s vs shot %s", tostring(ST.MeleeBarHeight()),
    tostring(ST.BarHeight())))
check("the state line underneath is a caption, not a fourth bar",
  (ST.StripHeight() or 99) < (ST.MeleeBarHeight() or 0),
  string.format("strip %s vs melee %s", tostring(ST.StripHeight()),
    tostring(ST.MeleeBarHeight())))

db10.height = 54
ST.RescanSettings()
check("the height slider grows the bars", ST.BarHeight() == 54
  and ST.MeleeBarHeight() == 54,
  string.format("%s/%s", tostring(ST.BarHeight()), tostring(ST.MeleeBarHeight())))
check("...and does NOT grow the caption", ST.StripHeight() == 11,
  tostring(ST.StripHeight()))
db10.height = 27
ST.RescanSettings()

-- ---------------------------------------------------------------------------
-- The two-mob decision is two cycles and nothing else: melee auto-attack up,
-- Auto Shot out of its lockout. Aimed and Multi-Shot are spent on the mob you
-- are SHOOTING -- a different decision from whether to swing at the one next to
-- you -- so they must not hide the cue.
-- ---------------------------------------------------------------------------
TwoMobWorld()
HKTest.state.cooldowns = {}            -- no cooldowns: both specials are READY
local db11 = Shooting(3.4, 1000)
At(1000.2); ST._OnMeleeSwing(1000.2)
local tNow = 1000.2 + ST.MeleeSpeed()
check("precondition: a special shot really is available",
  ST.SpecialsDown(tNow) == false, tostring(ST.SpecialsDown(tNow)))
local s11 = ST.TwoMob(tNow)
check("the melee auto-attack is up and Auto Shot is free",
  s11.swingUp == true and s11.locked == false)
check("...so the two-mob press fires even with specials ready",
  s11.press == true, "specials no longer gate the two-mob cue")


-- ---------------------------------------------------------------------------
-- Every LAYER of the bar must be the height of the bar.
--
-- Reported as "the auto shot bar is twice as small as the bar behind it with
-- the red strip part". It was the fill: a texture anchored by a single point
-- with no explicit size falls back to the TEXTURE's own dimensions on the live
-- client, and WHITE8x8 is 8x8. So the fill drew 8px tall inside an 18px bar
-- (roughly half -- hence "twice as small"), and 8px inside the 27px bar that
-- replaced it. Every other layer had a height; this one never did.
--
-- "Did we size it" is not readable from the code, so it is asserted here.
-- ---------------------------------------------------------------------------
local db12 = Shooting(3.0, 1000)
db12.height = 27
db12.width = 220
ST.RescanSettings()
check("the shot bar's fill is the full height of the bar",
  ST.FillHeight() == ST.BarHeight(),
  string.format("fill %s vs bar %s", tostring(ST.FillHeight()),
    tostring(ST.BarHeight())))
check("so is the red lockout zone behind it",
  ST.CastZoneHeight() == ST.BarHeight(),
  tostring(ST.CastZoneHeight()))

-- The hairline at the safe/locked boundary was created, textured and coloured
-- in BuildBar and then never positioned or sized -- invisible since it was
-- added. It marks where the red zone starts, so it belongs inside the bar.
check("the safe/locked hairline is sized, not an 8x8 blob",
  ST.SafeMarkHeight() == ST.BarHeight(), tostring(ST.SafeMarkHeight()))
local smx = ST.SafeMarkX()
check("...and it sits inside the bar, at the lockout boundary",
  type(smx) == "number" and smx > 0 and smx < 220, tostring(smx))

-- And it all follows the height slider together.
db12.height = 40
ST.RescanSettings()
check("every layer follows the height slider",
  ST.FillHeight() == 40 and ST.CastZoneHeight() == 40
  and ST.MeleeBarHeight() == 40 and ST.BarHeight() == 40,
  string.format("%s/%s/%s/%s", tostring(ST.FillHeight()),
    tostring(ST.CastZoneHeight()), tostring(ST.MeleeBarHeight()),
    tostring(ST.BarHeight())))
db12.height = 27
ST.RescanSettings()

-- Put the shared state back for the teardown below.
HKTest.state.units = {}
HKTest.state.inMelee = {}
HKTest.state.guids = {}
HKTest.state.dead = {}
HKTest.state.targetSpellInRange = nil

-- Report this file's tally so tests/test_docs.lua can check the README's
-- advertised check counts against what the suite really runs.
HKTest.report("test_shottimer.lua", passes, #failures)

say(string.format("\n%d passed, %d failed", passes, #failures))
if #failures > 0 then
  for _, f in ipairs(failures) do say("  - " .. f) end
  error(#failures .. " test(s) failed")
end
