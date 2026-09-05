--[[==============================================================================
 HunterKit — tests: pet aggro warning (ThreatWatch)

 Drives the REAL ThreatWatch module against the client stub. The module's whole
 job is a judgement call on the numbers the (1.13.5-reinstated) threat API
 returns, so the tests describe threat tables declaratively and assert the
 verdict, the alert, the alarm rate-limiting, and -- just as important for the
 "as light as possible" brief -- that it does NO work when it cannot matter.

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
local HK = HKTest.LoadAddon(unpack(HKTest.addonFiles))
HK:Load()
local TW = HK.ThreatWatch
check("the ThreatWatch module loaded", TW ~= nil)

-- ---------------------------------------------------------------------------
-- Scenario helper. One call describes the whole world.
--
--   o.player / o.pet : that unit's threat on the mob, as a scaled percentage
--                      (nil = not on the threat table at all)
--   o.playerTanking  : the mob has already switched to the player
--   o.petTanking     : the pet is the mob's primary target (default true)
-- ---------------------------------------------------------------------------
local function Scene(o)
  o = o or {}
  HKTest.soundsPlayed = {}
  HKTest.threatCalls = 0
  HKTest.state.now = (HKTest.state.now or 1000) + 100     -- past every cooldown
  HKTest.state.pet = (o.pet ~= false)
  HKTest.state.petDead = o.petDead or false
  HKTest.state.playerCombat = (o.combat ~= false)
  HKTest.state.petCombat = (o.combat ~= false)
  HKTest.state.target = o.target
  HKTest.state.noThreatAPI = o.noThreatAPI or false
  HKTest.state.units = o.units or {}
  HKTest.state.dead = o.dead or {}
  HKTest.state.guids = o.guids or {}
  HKTest.state.names = o.names or {}

  HKTest.state.threat = o.threat
  if HKTest.state.threat == nil and o.playerPct ~= nil then
    HKTest.state.threat = {
      pettarget = {
        player = { scaled = o.playerPct, tanking = o.playerTanking or false,
                   status = o.playerTanking and 3 or 0 },
        pet    = { scaled = o.petPct or 100, tanking = (o.petTanking ~= false),
                   status = 3 },
      },
    }
  end
  HKTest.state.threat = HKTest.state.threat or {}

  local d = HK.db.threat
  d.enabled       = o.enabled ~= false
  d.threshold     = o.threshold or 80
  d.sound         = o.sound ~= false
  d.soundInterval = o.soundInterval or 4
  d.showPct       = o.showPct ~= false
  d.pctMoved      = o.pctMoved or false
  TW.RescanSettings()

  -- Seed the trend so the scene reads as threat that has just CLIMBED to the
  -- stated numbers: run one evaluation against a slightly lower snapshot
  -- first. Without this every scene would look flat and the (now
  -- direction-aware) warning would never fire. Tests that care about the
  -- direction itself pass rising = false and drive the samples by hand.
  local real = HKTest.state.threat
  TW.ResetTrend()
  local drop = (o.rising ~= false) and 10 or 0    -- 0 = flat baseline
  local lower = {}
  for mob, entry in pairs(real) do
    lower[mob] = { pet = entry.pet }
    if entry.player then
      local copy = {}
      for k, v in pairs(entry.player) do copy[k] = v end
      copy.scaled = math.max(0, (tonumber(copy.scaled) or 0) - drop)
      lower[mob].player = copy
    end
  end
  HKTest.state.threat = lower
  TW.Evaluate()
  HKTest.state.threat = real
  HKTest.state.now = HKTest.state.now + 0.5     -- fresh sample, same series
  HKTest.soundsPlayed = {}
  HKTest.threatCalls = 0

  return d
end

-- ---------------------------------------------------------------------------
-- 1) The core judgement
-- ---------------------------------------------------------------------------
Scene({ playerPct = 45 })
local state, why = TW.Evaluate()
check("comfortably below the threshold: no warning", state == nil, state)

Scene({ playerPct = 85 })
state = TW.Evaluate()
check("at 85% of the pull point: warn", state == "warn", tostring(state))

Scene({ playerPct = 80 })
state = TW.Evaluate()
check("the threshold itself warns (>=, not >)", state == "warn", tostring(state))

Scene({ playerPct = 79 })
state = TW.Evaluate()
check("one under the threshold stays quiet", state == nil, tostring(state))

Scene({ playerPct = 95, playerTanking = true })
state = TW.Evaluate()
check("the mob having switched to you is 'pulled', not 'warn'",
  state == "pulled", tostring(state))

-- The threshold is the user's dial, and it must actually move.
Scene({ playerPct = 55, threshold = 50 })
check("a lower threshold warns earlier", TW.Evaluate() == "warn")
Scene({ playerPct = 55, threshold = 90 })
check("a higher threshold stays quiet longer", TW.Evaluate() == nil)

-- ---------------------------------------------------------------------------
-- 2) Only mobs the PET is tanking
--
-- The feature is "your pet is about to lose the mob", so a mob a real tank is
-- holding is none of its business -- warning there would fire on every dungeon
-- pull and train the player to ignore it.
-- ---------------------------------------------------------------------------
Scene({ playerPct = 95, petTanking = false })
state, why = TW.Evaluate()
check("a mob the pet is NOT tanking never warns", state == nil, tostring(state))

-- The pet not being on the threat table at all (never touched the mob).
Scene({ threat = { pettarget = { player = { scaled = 99, tanking = false } } } })
check("no pet threat on the mob means no warning", TW.Evaluate() == nil)

-- The player not being on the threat table: Blizzard returns nothing, which is
-- also how "your pet is fighting it but you have done nothing" reads. A player
-- with no threat cannot pull.
Scene({ threat = { pettarget = { pet = { scaled = 100, tanking = true } } } })
state, why = TW.Evaluate()
check("no player threat means no warning", state == nil, tostring(state))

-- ...but 'pulled' still wins even if the pet is not tanking, because the mob
-- demonstrably IS on you.
Scene({ threat = { pettarget = {
  player = { scaled = 100, tanking = true, status = 3 },
  pet    = { scaled = 40, tanking = false, status = 0 } } } })
check("already tanking it yourself always reports 'pulled'",
  TW.Evaluate() == "pulled")

-- ---------------------------------------------------------------------------
-- 3) Which units are checked, and how cheaply
-- ---------------------------------------------------------------------------
-- The danger can be on the player's own target rather than the pet's.
Scene({ target = true, guids = { pettarget = "A", target = "B" },
        names = { target = "Boar" },
        threat = { target = {
          player = { scaled = 92, tanking = false },
          pet    = { scaled = 100, tanking = true } } } })
local st, pct, unit, name = TW.Evaluate()
check("a mob on the player's own target is caught too", st == "warn", tostring(st))
check("...and is named in the verdict", name == "Boar", tostring(name))

-- Same mob under both unit tokens: it must be asked about ONCE.
Scene({ target = true, guids = { pettarget = "SAME", target = "SAME" },
        threat = { pettarget = {
                     player = { scaled = 90, tanking = false },
                     pet    = { scaled = 100, tanking = true } },
                   target = {
                     player = { scaled = 90, tanking = false },
                     pet    = { scaled = 100, tanking = true } } } })
HKTest.threatCalls = 0
TW.Evaluate()
check("the same mob under two unit tokens is only queried once",
  HKTest.threatCalls <= 2, tostring(HKTest.threatCalls))

-- The whole evaluation is a handful of calls, never a nameplate sweep.
Scene({ target = true, guids = { pettarget = "A", target = "B" },
        threat = { pettarget = {
                     player = { scaled = 90, tanking = false },
                     pet    = { scaled = 100, tanking = true } },
                   target = {
                     player = { scaled = 10, tanking = false },
                     pet    = { scaled = 100, tanking = true } } } })
HKTest.threatCalls = 0
TW.Evaluate()
check("two distinct mobs cost at most four threat calls",
  HKTest.threatCalls <= 4, tostring(HKTest.threatCalls))

-- The worst situation wins when several mobs qualify.
Scene({ target = true, guids = { pettarget = "A", target = "B" },
        threat = { pettarget = {
                     player = { scaled = 85, tanking = false },
                     pet    = { scaled = 100, tanking = true } },
                   target = {
                     player = { scaled = 100, tanking = true, status = 3 },
                     pet    = { scaled = 50, tanking = false } } } })
check("when one mob has already switched, 'pulled' outranks 'warn'",
  TW.Evaluate() == "pulled")

-- Two warnings: the closest call is the one reported.
Scene({ target = true, guids = { pettarget = "A", target = "B" },
        names = { pettarget = "Near", target = "Closer" },
        threat = { pettarget = {
                     player = { scaled = 82, tanking = false },
                     pet    = { scaled = 100, tanking = true } },
                   target = {
                     player = { scaled = 97, tanking = false },
                     pet    = { scaled = 100, tanking = true } } } })
st, pct, unit, name = TW.Evaluate()
check("the closest call is the one reported", math.floor(pct) == 97, tostring(pct))

-- ---------------------------------------------------------------------------
-- 4) Refusals: the situations where the feature must simply do nothing
-- ---------------------------------------------------------------------------
Scene({ playerPct = 99, enabled = false })
state, why = TW.Evaluate()
check("disabled: no verdict", state == nil and tostring(why):find("off") ~= nil, why)

Scene({ playerPct = 99, pet = false })
state, why = TW.Evaluate()
check("no pet: no verdict", state == nil and why == "no pet", why)

Scene({ playerPct = 99, petDead = true })
state, why = TW.Evaluate()
check("dead pet: no verdict", state == nil and why == "pet is dead", why)

Scene({ playerPct = 99, combat = false })
state, why = TW.Evaluate()
check("out of combat: no verdict", state == nil and why == "not in combat", why)

-- A dead mob is not a threat, however high the stale numbers read.
Scene({ playerPct = 99, dead = { pettarget = true } })
check("a dead mob never warns", TW.Evaluate() == nil)

-- The master switch pauses this like every other feature.
Scene({ playerPct = 99 })
HK.db.enabled = false
state, why = TW.Evaluate()
check("the master switch pauses it", state == nil and tostring(why):find("HunterKit is off"), why)
HK.db.enabled = true

-- ---------------------------------------------------------------------------
-- 5) A client WITHOUT the threat API
--
-- The feature is built on the API Blizzard reinstated in 1.13.5. On anything
-- older (or a stripped environment) it must degrade to a clear explanation and
-- must never throw inside combat.
-- ---------------------------------------------------------------------------
local realUDTS = UnitDetailedThreatSituation
UnitDetailedThreatSituation = nil
Scene({ playerPct = 99 })
check("no threat API: HasAPI() says so", TW.HasAPI() == false)
state, why = TW.Evaluate()
check("no threat API: refuses with an explanation",
  state == nil and tostring(why):find("threat API") ~= nil, why)
check("no threat API: does not poll", TW.IsPolling() == false)
UnitDetailedThreatSituation = realUDTS
check("the API coming back is detected", TW.HasAPI() == true)

-- A client whose threat call THROWS must not take the addon with it.
Scene({ playerPct = 99, noThreatAPI = true })
local ok = pcall(TW.Evaluate)
check("a throwing threat API is survived", ok == true)

-- ---------------------------------------------------------------------------
-- 6) The alert widget
-- ---------------------------------------------------------------------------
local alert = _G["HunterKitThreatAlert"]
check("the alert frame exists", alert ~= nil)

Scene({ playerPct = 90 })
TW.Tick(true)
check("a warning shows the alert", TW.IsShown() == true)

Scene({ playerPct = 20 })
TW.Tick(true)
HKTest.state.now = HKTest.state.now + 60      -- past the linger window
TW.Tick(true)
check("the alert clears once the danger passes", TW.IsShown() == false)

-- The linger: a borderline fight must not strobe the alert on and off.
Scene({ playerPct = 90 })
TW.Tick(true)
check("alert up while warned", TW.IsShown() == true)
HKTest.state.threat.pettarget.player.scaled = 20     -- dips under, briefly
TW.Tick(true)
check("a momentary dip does not blink the alert out", TW.IsShown() == true)

-- ---------------------------------------------------------------------------
-- 7) The alarm, and its rate limiting
-- ---------------------------------------------------------------------------
-- Note: Scene() applies the settings, which evaluates once -- and that first
-- evaluation IS the threshold crossing, so the alarm belongs to it. Clearing
-- the record afterwards would hide the very sound under test.
Scene({ playerPct = 90 })
TW.Tick(true)
local firstSounds = #HKTest.soundsPlayed
check("crossing the threshold makes a sound", firstSounds >= 1, tostring(firstSounds))

-- Staying in the same state must NOT re-alarm on every tick.
for _ = 1, 20 do TW.Tick(true) end
check("holding at the same state does not spam the alarm",
  #HKTest.soundsPlayed == firstSounds,
  #HKTest.soundsPlayed .. " vs " .. firstSounds)

-- Escalating warn -> pulled is a NEW state and is worth a fresh alarm.
HKTest.state.now = HKTest.state.now + 30
HKTest.state.threat.pettarget.player.tanking = true
HKTest.state.threat.pettarget.player.scaled = 100
TW.Tick(true)
check("escalating to a full pull alarms again",
  #HKTest.soundsPlayed > firstSounds, tostring(#HKTest.soundsPlayed))

-- Sound off means silent, however dire the situation.
Scene({ playerPct = 99, sound = false })
HKTest.soundsPlayed = {}
TW.Tick(true)
check("sound disabled stays silent", #HKTest.soundsPlayed == 0,
  tostring(#HKTest.soundsPlayed))
check("...but the visual warning still shows", TW.IsShown() == true)

-- ---------------------------------------------------------------------------
-- 8) The cost story: no work when it cannot matter
--
-- This is the "as light as possible" requirement expressed as a test. The
-- ticker must exist only while the player is in combat with a living pet.
-- ---------------------------------------------------------------------------
Scene({ playerPct = 10, combat = false })
check("out of combat: not polling", TW.IsPolling() == false)

Scene({ playerPct = 10, combat = true })
check("in combat with a pet: polling", TW.IsPolling() == true)

Scene({ playerPct = 10, combat = true, pet = false })
check("no pet: not polling even in combat", TW.IsPolling() == false)

Scene({ playerPct = 10, combat = true, petDead = true })
check("dead pet: not polling", TW.IsPolling() == false)

-- Disabling the WARNING alone must NOT stop the poll any more: the percentage
-- readout is a separate feature that still needs fresh numbers. Only when BOTH
-- halves are off does the module go fully idle.
Scene({ playerPct = 10, combat = true, enabled = false })
check("warning off but readout on: still polling", TW.IsPolling() == true)
Scene({ playerPct = 10, combat = true, enabled = false, showPct = false })
check("both halves off: not polling", TW.IsPolling() == false)

-- Leaving combat must tear the ticker down again, not leak one per fight.
Scene({ playerPct = 10, combat = true })
check("combat starts the ticker", TW.IsPolling() == true)
HKTest.state.playerCombat = false
HKTest.state.petCombat = false
HKTest.Fire("PLAYER_REGEN_ENABLED")
check("leaving combat stops the ticker", TW.IsPolling() == false)
check("...and hides the alert", TW.IsShown() == false)

-- Repeated combat cycles must not accumulate tickers.
local before = #HKTest.tickers
for _ = 1, 5 do
  HKTest.state.playerCombat = true
  HKTest.Fire("PLAYER_REGEN_DISABLED")
  HKTest.state.playerCombat = false
  HKTest.state.petCombat = false
  HKTest.Fire("PLAYER_REGEN_ENABLED")
end
local live = 0
for _, t in ipairs(HKTest.tickers) do if not t.cancelled then live = live + 1 end end
check("combat cycles do not leak tickers", TW.IsPolling() == false)

-- ThreatWatch itself registers NO combat-log event -- the entire reason it is
-- cheap. The bus is shared addon-wide, so this cannot be asserted by checking
-- the bus is empty (ShotTimer legitimately registers one to see melee swings);
-- what matters is that no threat evaluation is driven by the combat log.
local clHandler = HK.bus.handlers["COMBAT_LOG_EVENT_UNFILTERED"]
if clHandler then
  HKTest.threatCalls = 0
  HKTest.state.clevent = { 0, "SWING_DAMAGE", false, "guid-player" }
  for _ = 1, 20 do clHandler() end
  check("combat-log traffic drives no threat work", HKTest.threatCalls == 0,
    tostring(HKTest.threatCalls))
  HKTest.state.clevent = nil
else
  check("no combat-log event is registered", true)
end

-- Throttling: a burst of threat events must not become a burst of work.
Scene({ playerPct = 90 })
HKTest.threatCalls = 0
for _ = 1, 50 do HKTest.Fire("UNIT_THREAT_LIST_UPDATE", "target") end
check("an event storm is throttled into almost no work",
  HKTest.threatCalls <= 4, tostring(HKTest.threatCalls))

-- ---------------------------------------------------------------------------
-- 9) Wiring
-- ---------------------------------------------------------------------------
check("it listens for threat list updates",
  HK.bus.handlers["UNIT_THREAT_LIST_UPDATE"] ~= nil)
check("it listens for threat situation updates",
  HK.bus.handlers["UNIT_THREAT_SITUATION_UPDATE"] ~= nil)
check("it tracks combat entry", HK.bus.handlers["PLAYER_REGEN_DISABLED"] ~= nil)
check("it tracks pet changes", HK.bus.handlers["UNIT_PET"] ~= nil)

-- ---------------------------------------------------------------------------
-- 10) The live aggro percentage readout by the player frame
-- ---------------------------------------------------------------------------
local pctFrame = _G["HunterKitThreatPct"]
check("the percentage readout frame exists", pctFrame ~= nil)

-- It sits centred directly ABOVE the player frame: our BOTTOM to the frame's
-- TOP. Anchoring by a corner left it hanging off to one side.
local pp = pctFrame and pctFrame.points[1]
check("the readout sits above the middle of the player frame",
  pp and pp[1] == "BOTTOM" and pp[2] == _G["PlayerFrame"] and pp[3] == "TOP",
  pp and (tostring(pp[1]) .. "->" .. tostring(pp[2] and pp[2].name) .. "/" .. tostring(pp[3])))

-- It must never eat clicks meant for the player frame underneath it.
check("the readout does not intercept mouse clicks",
  pctFrame.mouseEnabled ~= true, tostring(pctFrame.mouseEnabled))

-- The number itself, at a range of threat levels.
Scene({ playerPct = 42 })
TW.Tick(true)
check("the readout shows the live percentage", TW.IsReadoutShown() == true)
check("...with the actual number", TW.ReadoutText() == "42%", tostring(TW.ReadoutText()))

Scene({ playerPct = 7 })
TW.Tick(true)
check("a low percentage is still shown (not only scary ones)",
  TW.ReadoutText() == "7%", tostring(TW.ReadoutText()))

-- THE REGRESSION THIS SPLIT EXISTS FOR: the readout must work while the
-- interrupting warning is switched OFF, which is now the default pairing.
Scene({ playerPct = 55, enabled = false })
TW.Tick(true)
check("the readout works with the warning disabled", TW.IsReadoutShown() == true,
  tostring(TW.ReadoutText()))
check("...and the warning alert stays hidden", TW.IsShown() == false)

-- ...and vice versa: turning the readout off must not affect the warning.
Scene({ playerPct = 95, enabled = true, showPct = false })
TW.Tick(true)
check("the readout can be switched off on its own", TW.IsReadoutShown() == false)
check("...while the warning still fires", TW.IsShown() == true)

-- Colour ramp: green safe, amber closing, red at/over the pull point. Tied to
-- the SAME threshold the warning uses, so the colour and the warning can never
-- disagree with each other.
local function ColorOf(pct, threshold)
  Scene({ playerPct = pct, threshold = threshold or 80, enabled = false })
  TW.Tick(true)
  local c = TW.ReadoutColor()
  if not c then return "none" end
  local r, g, b = c[1] or 0, c[2] or 0, c[3] or 0
  if r > 0.9 and g < 0.2 and b < 0.2 then return "red" end
  if r > 0.9 and g > 0.2 and g < 0.5 then return "orange" end
  if r > 0.9 and g > 0.7 then return "amber" end
  if g > 0.9 and r < 0.5 then return "green" end
  return string.format("%.2f/%.2f/%.2f", r, g, b)
end

check("a safe percentage reads green", ColorOf(20) == "green", ColorOf(20))
check("closing on the threshold reads amber", ColorOf(65) == "amber", ColorOf(65))
check("at the threshold reads orange", ColorOf(85) == "orange", ColorOf(85))
check("having pulled reads red", ColorOf(100) == "red", ColorOf(100))
-- The ramp follows the user's threshold, it is not hardcoded to 80.
check("a lower threshold reddens the ramp earlier",
  ColorOf(55, 50) == "orange", ColorOf(55, 50))
check("...and a higher one keeps it calm longer",
  ColorOf(55, 95) == "green", ColorOf(55, 95))

-- No danger at all: nothing to show.
Scene({ playerPct = 30, combat = false })
TW.Tick(true)
check("out of combat the readout hides", TW.IsReadoutShown() == false)

Scene({ playerPct = 30, pet = false })
TW.Tick(true)
check("with no pet the readout hides", TW.IsReadoutShown() == false)

-- A mob a real TANK is holding still shows a percentage -- the readout is a
-- plain "how hot am I", not the pet-specific warning, so it must not go blank
-- just because the pet is not the one tanking.
Scene({ playerPct = 60, petTanking = false })
TW.Tick(true)
check("the readout reports threat even when the pet is not tanking",
  TW.IsReadoutShown() == true and TW.ReadoutText() == "60%",
  tostring(TW.ReadoutText()))
check("...while the pet-specific warning correctly stays silent", TW.IsShown() == false)

-- Having actually pulled reads as 100%.
Scene({ playerPct = 100, playerTanking = true })
TW.Tick(true)
check("holding aggro yourself reads 100%", TW.ReadoutText() == "100%",
  tostring(TW.ReadoutText()))

-- Leaving combat clears the number rather than freezing a stale one on screen.
Scene({ playerPct = 88 })
TW.Tick(true)
check("number on screen during combat", TW.IsReadoutShown() == true)
HKTest.state.playerCombat = false
HKTest.state.petCombat = false
HKTest.Fire("PLAYER_REGEN_ENABLED")
check("leaving combat clears the number", TW.IsReadoutShown() == false)

-- No threat API: the readout must stay hidden, not show a bogus 0%.
UnitDetailedThreatSituation = nil
Scene({ playerPct = 50 })
TW.Tick(true)
check("no threat API: the readout hides rather than lying",
  TW.IsReadoutShown() == false)
UnitDetailedThreatSituation = realUDTS

-- ---------------------------------------------------------------------------
-- 10b) The readout goes BIG and PULSES once it reaches the warn threshold
-- ---------------------------------------------------------------------------
-- Below the threshold: normal size, and crucially NO per-frame work.
Scene({ playerPct = 50, threshold = 80 })
TW.Tick(true)
check("a calm number is normal size", TW.ReadoutScale() == 1, tostring(TW.ReadoutScale()))
check("a calm number is not flagged hot", TW.IsReadoutHot() == false)
check("a calm number runs NO OnUpdate loop", TW.IsReadoutPulsing() == false)

-- At the threshold: 1.5x and animating.
Scene({ playerPct = 80, threshold = 80 })
TW.Tick(true)
check("reaching the threshold flags it hot", TW.IsReadoutHot() == true)
check("...and starts the pulse loop", TW.IsReadoutPulsing() == true)
check("...at the hot size", (TW.ReadoutScale() or 0) > 1.05,
  tostring(TW.ReadoutScale()))
-- The emphasis must be a SWELL, not a jump: a big multiplier on a number
-- anchored to the player frame reads as the readout leaping across the screen.
check("...but only modestly bigger, so it does not lurch",
  (TW.ReadoutScale() or 0) < 1.3, tostring(TW.ReadoutScale()))
check("...and the FRAME is never scaled, or the anchor offsets move with it",
  math.abs((TW.ReadoutFrameScale() or 0) - 1) < 0.001,
  tostring(TW.ReadoutFrameScale()))

-- One under the threshold must NOT emphasise (>= not >, matching the warning).
Scene({ playerPct = 79, threshold = 80 })
TW.Tick(true)
check("one under the threshold stays small", TW.IsReadoutHot() == false,
  tostring(TW.ReadoutScale()))

-- It follows the USER'S threshold from the UI, not a hardcoded 80.
Scene({ playerPct = 55, threshold = 50 })
TW.Tick(true)
check("a lower configured threshold emphasises earlier", TW.IsReadoutHot() == true)
Scene({ playerPct = 55, threshold = 95 })
TW.Tick(true)
check("a higher configured threshold keeps it calm", TW.IsReadoutHot() == false)

-- Actually holding aggro always emphasises, whatever the threshold.
Scene({ playerPct = 100, playerTanking = true, threshold = 95 })
TW.Tick(true)
check("holding aggro always emphasises", TW.IsReadoutHot() == true)

-- The pulse actually MOVES the scale, and stays around 1.5x.
Scene({ playerPct = 90, threshold = 80 })
TW.Tick(true)
local pctF = _G["HunterKitThreatPct"]
local drive = pctF:GetScript("OnUpdate")
local seen, lo, hi = {}, 99, -99
for i = 1, 12 do
  drive(pctF, 0.05)
  local sc = TW.ReadoutScale()
  seen[#seen + 1] = sc
  lo, hi = math.min(lo, sc), math.max(hi, sc)
end
check("the pulse animates the scale", hi > lo, string.format("%.3f..%.3f", lo, hi))
check("...as a gentle swell, never a lurch", lo > 1.0 and hi < 1.35,
  string.format("%.3f..%.3f", lo, hi))

-- The whole point of the rewrite: the readout must not MOVE while it pulses.
local ppBefore = pctF.points[#pctF.points]
for i = 1, 8 do drive(pctF, 0.05) end
local ppAfter = pctF.points[#pctF.points]
check("the number stays put while it pulses",
  ppBefore[1] == ppAfter[1] and ppBefore[4] == ppAfter[4]
    and ppBefore[5] == ppAfter[5],
  string.format("%s %s,%s -> %s %s,%s", tostring(ppBefore[1]),
    tostring(ppBefore[4]), tostring(ppBefore[5]), tostring(ppAfter[1]),
    tostring(ppAfter[4]), tostring(ppAfter[5])))
check("...and the frame scale never budges",
  math.abs((TW.ReadoutFrameScale() or 0) - 1) < 0.001)

-- Cooling off must stop the loop AND restore the size -- otherwise the number
-- would be left permanently enlarged, or burning a frame handler forever.
Scene({ playerPct = 90, threshold = 80 })
TW.Tick(true)
check("hot before cooling", TW.IsReadoutHot() == true)
HKTest.state.threat.pettarget.player.scaled = 20
TW.Tick(true)
check("dropping below the threshold stops the pulse", TW.IsReadoutPulsing() == false)
check("...and restores normal size", TW.ReadoutScale() == 1, tostring(TW.ReadoutScale()))

-- Leaving combat while hot must also tear the animation down.
Scene({ playerPct = 95, threshold = 80 })
TW.Tick(true)
check("hot during combat", TW.IsReadoutPulsing() == true)
HKTest.state.playerCombat = false
HKTest.state.petCombat = false
HKTest.Fire("PLAYER_REGEN_ENABLED")
check("leaving combat stops the pulse loop", TW.IsReadoutPulsing() == false)
check("...and leaves the frame at normal scale", TW.ReadoutScale() == 1,
  tostring(TW.ReadoutScale()))

-- The emphasis is independent of the interrupting warning, which is off by
-- default -- the number must still grow and pulse on its own.
Scene({ playerPct = 90, threshold = 80, enabled = false })
TW.Tick(true)
check("emphasis works with the warning disabled", TW.IsReadoutHot() == true)
check("...and the warning alert stays hidden", TW.IsShown() == false)

-- Dragging: once moved it pins absolutely instead of following the player frame.
Scene({ playerPct = 50, pctMoved = true })
HK.db.threat.pctOffsetX, HK.db.threat.pctOffsetY = 120, 240
TW.ApplyReadoutPosition()
local mp = pctFrame.points[1]
check("a dragged readout pins to UIParent, not the player frame",
  mp and mp[2] == UIParent and mp[4] == 120 and mp[5] == 240,
  mp and (tostring(mp[2] and mp[2].name) .. " " .. tostring(mp[4]) .. "," .. tostring(mp[5])))
HK.db.threat.pctMoved = false
TW.ApplyReadoutPosition()

-- Defaults are sane and safe.
check("the interrupting warning is OFF by default", HK.defaults.threat.enabled == false)
check("the percentage readout is ON by default", HK.defaults.threat.showPct == true)
check("the default threshold leaves room to react",
  HK.defaults.threat.threshold == 80, HK.defaults.threat.threshold)
check("the alarm is rate-limited by default",
  (HK.defaults.threat.soundInterval or 0) >= 2)

-- Diagnostics must never throw, in any state.
Scene({ playerPct = 90 })
check("/htk threat runs without error", pcall(TW.PrintDiag) == true)
Scene({ playerPct = 10, pet = false })
check("/htk threat runs with no pet", pcall(TW.PrintDiag) == true)
UnitDetailedThreatSituation = nil
check("/htk threat runs with no threat API", pcall(TW.PrintDiag) == true)
UnitDetailedThreatSituation = realUDTS


-- ---------------------------------------------------------------------------
-- 11) DIRECTION: high threat alone is not a warning -- it has to be climbing.
--
-- The point of the redesign. A hunter easing off, or a pet catching up with
-- Growl, walks the percentage back DOWN through the threshold; the old code
-- shouted just as loudly on the way down as on the way up, which is the noise
-- this group exists to prevent.
-- ---------------------------------------------------------------------------

-- Re-points the scene's threat at a new player percentage and re-evaluates, so
-- the module sees a genuine second sample in the same series.
local function Move(mob, toPct)
  HKTest.state.now = HKTest.state.now + 0.5      -- fresh, not stale
  HKTest.state.threat[mob].player.scaled = toPct
  return TW.Evaluate()
end

Scene({ playerPct = 90, rising = false })
state = Move("pettarget", 80)
check("falling 90 -> 80 does NOT warn", state == nil, tostring(state))

Scene({ playerPct = 90, rising = false })
state = Move("pettarget", 95)
check("rising 90 -> 95 does warn", state == "warn", tostring(state))

Scene({ playerPct = 70, rising = false })
state = Move("pettarget", 85)
check("rising through the threshold warns", state == "warn", tostring(state))

-- Flat is not rising: a plateau at 95% must not re-trigger on every tick.
Scene({ playerPct = 95, rising = false })
state = Move("pettarget", 95.2)
check("a plateau (95 -> 95.2) is not a rise", state == nil, tostring(state))

Scene({ playerPct = 95, rising = false })
state = Move("pettarget", 96)
check("a 1-point climb beats the noise floor", state == "warn", tostring(state))

-- Direction only gates the WARNING. Actually losing the mob is a fact.
Scene({ playerPct = 100, playerTanking = true, rising = false })
state = Move("pettarget", 100)
check("already pulled reports regardless of direction", state == "pulled",
  tostring(state))

-- A target swap must not compare two different mobs' percentages.
Scene({ playerPct = 30, rising = false, guids = { pettarget = "A" } })
HKTest.state.guids.pettarget = "B"
state = Move("pettarget", 90)
check("a target swap starts a fresh series (no fake rise)", state == nil,
  tostring(state))

-- A stale sample from a previous fight must not read as a rise either.
Scene({ playerPct = 30, rising = false })
HKTest.state.now = HKTest.state.now + 60
HKTest.state.threat.pettarget.player.scaled = 90
state = TW.Evaluate()
check("a stale sample is not comparable", state == nil, tostring(state))

-- ---------------------------------------------------------------------------
-- 12) DAMAGE TO PULL: the figure in front of the percentage
-- ---------------------------------------------------------------------------
-- The API reports threat at 100x damage, so these come back in DAMAGE: at half
-- the pull point the gap equals your own threat (100000 units = 1000 damage).
check("at half the pull point, the gap equals your own threat, in damage",
  math.abs(TW.DamageToPull(100000, 50) - 1000) < 0.01,
  tostring(TW.DamageToPull(100000, 50)))
check("at 80% the gap is a quarter of your threat",
  math.abs(TW.DamageToPull(400000, 80) - 1000) < 0.01,
  tostring(TW.DamageToPull(400000, 80)))
-- The regression this guards: raw API units must never reach the screen.
check("a raid-sized threat value reads as damage, not 100x damage",
  math.abs(TW.DamageToPull(500000, 50) - 5000) < 0.01,
  tostring(TW.DamageToPull(500000, 50)))
check("at the pull point the gap is zero", TW.DamageToPull(500000, 100) == 0,
  tostring(TW.DamageToPull(500000, 100)))
check("no threat yet: no honest figure", TW.DamageToPull(0, 50) == nil)
check("a percentage too small to divide by: no figure",
  TW.DamageToPull(100000, 0) == nil)
check("nonsense inputs do not produce a nonsense number",
  TW.DamageToPull(nil, nil) == nil)

check("plain numbers stay plain", TW.ShortNum(940) == "940", TW.ShortNum(940))
check("thousands get one decimal", TW.ShortNum(1234) == "1.2k", TW.ShortNum(1234))
check("five figures drop the decimal", TW.ShortNum(15400) == "15k",
  TW.ShortNum(15400))

-- ...and it reaches the readout, in front of the percentage.
Scene({ threat = { pettarget = {
          player = { scaled = 50, tanking = false, value = 200000 },
          pet    = { scaled = 100, tanking = true } } } })
TW.UpdateReadout()
local txt = TW.ReadoutText()
check("the readout carries the damage that would pull", txt:find("2%.0k") ~= nil, txt)
check("...and still the percentage", txt:find("50%%") ~= nil, txt)
check("...with the gap in FRONT of the percentage",
  txt:find("2%.0k") < txt:find("50%%"), txt)

HK.db.threat.showGap = false
TW.RescanSettings()
TW.UpdateReadout()
check("the gap can be switched off, leaving the bare percentage",
  TW.ReadoutText() == "50%", tostring(TW.ReadoutText()))
HK.db.threat.showGap = true
TW.RescanSettings()

-- ---------------------------------------------------------------------------
-- 13) A SIMPLER ALERT: one word, no essay
-- ---------------------------------------------------------------------------
Scene({ playerPct = 70, rising = false,
        names = { pettarget = "Ragged Timberling" } })
HKTest.state.now = HKTest.state.now + 0.5
HKTest.state.threat.pettarget.player.scaled = 88
TW.Tick(true)
local text = TW.AlertText() or ""
check("the warning says THREAT and nothing more",
  text:find("THREAT") ~= nil, text)
-- Strip the colour escape before looking for digits: |cffffcc00 is full of them.
local bare = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
check("...no percentage in the alert (it is already on the readout)",
  bare:find("%d") == nil, bare)
check("...and no mob name to read mid-fight",
  text:find("Timberling") == nil, text)

Scene({ playerPct = 100, playerTanking = true, rising = false })
HKTest.state.now = HKTest.state.now + 0.5
HKTest.state.threat.pettarget.player.scaled = 100
TW.Tick(true)
text = TW.AlertText() or ""
check("losing the mob says AGGRO", text:find("AGGRO") ~= nil, text)


-- ---------------------------------------------------------------------------
-- THE EDIT-MODE PREVIEW MUST GO AWAY WHEN YOU RELOCK
--
-- Regression: unlocking forces the warning icon up as a drag target, but
-- nothing hid it again on relock -- the linger check only fires once a REAL
-- alert has set shownUntil, which a preview never does. The icon stayed on
-- screen until the next genuine threat event.
-- ---------------------------------------------------------------------------
local alertFrame = _G["HunterKitThreatAlert"]
HK.db.threat.enabled = true
TW.RescanSettings()

Scene({ playerPct = 10, threshold = 80 })     -- nothing alarming at all
TW.Tick(true)
check("no alert when nothing is wrong", alertFrame:IsShown() == false)

pcall(HK.Positions.ToggleLock)                -- unlock -> preview
check("unlocking previews the warning so you can place it",
  alertFrame:IsShown() == true)

pcall(HK.Positions.ToggleLock)                -- relock
check("relocking clears the preview", alertFrame:IsShown() == false,
  "the preview must not linger after you lock frames")

-- And a real alert still works after a preview cycle.
Scene({ playerPct = 95, threshold = 80 })
TW.Tick(true)
check("a genuine warning still shows after previewing",
  alertFrame:IsShown() == true)
Scene({ playerPct = 10, threshold = 80 })

check("the readout defaults to centred above the player frame",
  HK.defaults.threat.pctOffsetX == 0)

say(string.format("\n%d passed, %d failed", passes, #failures))
if #failures > 0 then
  for _, f in ipairs(failures) do say("  - " .. f) end
  error(#failures .. " test(s) failed")
end
