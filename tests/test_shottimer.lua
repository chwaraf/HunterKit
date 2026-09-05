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
At(1300)
ST.OnUpdate()
check("the label counts down the FREE time, not the raw cycle",
  ST.LabelText() == "2.5s", tostring(ST.LabelText()))

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

say(string.format("\n%d passed, %d failed", passes, #failures))
if #failures > 0 then
  for _, f in ipairs(failures) do say("  - " .. f) end
  error(#failures .. " test(s) failed")
end
