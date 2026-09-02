--[[==============================================================================
 HunterKit — tests: Pet Mend Marker
 Loads the REAL Core.lua and MendMark.lua against tests/wow_stub.lua and asserts
 the behaviour the feature promises:

   * shows only with a live pet, a learned Mend Pet, and (by default) combat
   * green + solid when the pet is inside Mend Pet range
   * faded + greyed + red border when it is not
   * urgent (bigger, pulsing ring, "MEND!" label) at or below the HP threshold
   * anchors over the pet's head via the name plate when the client exposes one,
     falls back to the pet unit frame when it doesn't, and hides in "plate" mode
     when there is no plate to anchor to

 Run with tests/run_tests.py.
==============================================================================]]

local passes, failures = 0, {}

-- HKTest.say is the interpreter's print, i.e. it bypasses the stub's capture of
-- the addon's chat output.
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

local function near(a, b, eps)
  return type(a) == "number" and math.abs(a - b) <= (eps or 0.001)
end

-- ---------------------------------------------------------------------------
-- Boot the addon the way the client does
-- ---------------------------------------------------------------------------
local HK = HKTest.LoadAddon("../Core.lua", "../MendMark.lua")
HK:Load()

local marker = HKTest.MarkerFrame()
check("marker frame created on load", marker ~= nil)
check("module registered", HK.modules["MendMark"] ~= nil)
check("db.mend defaults merged", HK.db.mend ~= nil and HK.db.mend.enabled == true,
  HK.db.mend and tostring(HK.db.mend.enabled))
check("default low-HP threshold is 30%", HK.db.mend.hpThreshold == 30)
check("default anchor is auto", HK.db.mend.anchor == "auto")
check("db version migrated to 12", HK.db.dbVersion == 12, tostring(HK.db.dbVersion))

-- BuildFrame creates, in order: icon, ring, then HK.CreateBorder's four strips.
local function iconOf(f) return f.textures[1] end
local function ringOf(f) return f.textures[2] end
local function borderTex(f) return f.textures[3] end
local function labelOf(f) return f.fontstrings[1] end

-- ---------------------------------------------------------------------------
-- 1) Baseline: pet out, in combat, healthy, in range, no name plate
-- ---------------------------------------------------------------------------
HKTest.state.petHP = 550   -- 55%
HKTest.state.playerCombat, HKTest.state.petCombat = true, true
HKTest.state.plate = nil
HK.MendMark.Update()

check("shown with a live pet in combat", HK.MendMark.IsShown())
check("solid (alpha 1) when in range", near(marker:GetAlpha(), 1), marker:GetAlpha())
check("not greyed when in range", iconOf(marker).desaturated ~= true)
check("green border when in range", borderTex(marker).color[2] == 1 and borderTex(marker).color[1] == 0.2,
  borderTex(marker).color and table.concat(borderTex(marker).color, ","))
check("no label when healthy and in range", not labelOf(marker):IsShown())
check("ring hidden when not urgent", not ringOf(marker):IsShown())
check("scale 1 when not urgent", near(marker:GetScale(), 1), marker:GetScale())
check("falls back to the pet frame with no plate (even hidden)", HK.MendMark.AnchorMode() == "petframe",
  HK.MendMark.AnchorMode())
do
  local p = marker.points[1]
  check("anchored above the pet frame",
    p and p[1] == "BOTTOM" and p[2] == _G["PetFrame"] and p[3] == "TOP",
    p and tostring(p[1]) .. "/" .. tostring(p[3]))
  check("uses the saved height offset", p and p[5] == HK.db.mend.offsetY, p and tostring(p[5]))
end

-- The ticker must keep it alive (this is what tracks a moving pet).
local mendTicker
for _, t in ipairs(HKTest.tickers) do
  if near(t.interval, 0.10) then mendTicker = t end
end
check("0.10s ticker running", mendTicker ~= nil)
HKTest.state.petHP = 550
mendTicker:Tick()
check("ticker re-evaluates the marker", HK.MendMark.IsShown())

-- ---------------------------------------------------------------------------
-- 2) Out of range
-- ---------------------------------------------------------------------------
HKTest.state.spellInRange = 0
HK.MendMark.Update()
check("still shown when out of range", HK.MendMark.IsShown())
check("faded when out of range", near(marker:GetAlpha(), 0.45), marker:GetAlpha())
check("greyed when out of range", iconOf(marker).desaturated == true)
check("red border when out of range", borderTex(marker).color[1] == 1 and borderTex(marker).color[2] == 0.15)
check("'TOO FAR' label when out of range", labelOf(marker):GetText() == "TOO FAR", labelOf(marker):GetText())

-- fading is optional
HK.db.mend.dimWhenFar = false
HK.MendMark.Update()
check("fade is optional (alpha 1 when off)", near(marker:GetAlpha(), 1), marker:GetAlpha())
HK.db.mend.dimWhenFar = true
HKTest.state.spellInRange = 1
HK.MendMark.Update()

-- ---------------------------------------------------------------------------
-- 3) Urgent: pet below the low-HP threshold
-- ---------------------------------------------------------------------------
HKTest.state.petHP = 200    -- 20%
HK.MendMark.Update()
HKTest.Animate(1, 0.1)
check("urgent ring shown below threshold", ringOf(marker):IsShown())
check("marker grows when urgent", marker:GetScale() > 1, marker:GetScale())
check("'MEND!' label when urgent", labelOf(marker):GetText() == "MEND!", labelOf(marker):GetText())
check("urgent label is orange/red", labelOf(marker).textColor[1] == 1)

-- the threshold is inclusive: exactly 30% counts as urgent
HKTest.state.petHP = 300
HK.MendMark.Update()
HKTest.Animate(1, 0.1)
check("exactly at threshold is urgent", ringOf(marker):IsShown())
-- 31% is not
HKTest.state.petHP = 310
HK.MendMark.Update()
HKTest.Animate(1, 0.1)
check("above threshold is not urgent", not ringOf(marker):IsShown())
check("scale resets when no longer urgent", near(marker:GetScale(), 1), marker:GetScale())

-- a custom threshold is honoured
HK.db.mend.hpThreshold = 50
HKTest.state.petHP = 450
HK.MendMark.Update()
HKTest.Animate(1, 0.1)
check("custom threshold honoured (45% <= 50%)", ringOf(marker):IsShown())
HK.db.mend.hpThreshold = 30
HK.MendMark.Update()

-- urgent beats "only in combat": a hurt pet shows out of combat too
HKTest.state.petHP = 200
HKTest.state.playerCombat, HKTest.state.petCombat = false, false
HK.MendMark.Update()
check("hurt pet shows out of combat", HK.MendMark.IsShown())
-- the pulse can be switched off
HK.db.mend.urgentPulse = false
HKTest.Animate(1, 0.1)
check("pulse can be disabled", not ringOf(marker):IsShown() and near(marker:GetScale(), 1))
HK.db.mend.urgentPulse = true
HKTest.state.petHP = 550

-- hidden mid-pulse must unwind the animation, not come back grown
HKTest.state.playerCombat = true
HKTest.state.petHP = 150
HK.MendMark.Update()
HKTest.Animate(1, 0.1)
check("scaled up while urgent", marker:GetScale() > 1, marker:GetScale())
HKTest.state.pet = false
HK.MendMark.Update()
check("hidden mid-pulse resets the scale", near(marker:GetScale(), 1), marker:GetScale())
check("hidden mid-pulse hides the ring", not ringOf(marker):IsShown())
HKTest.state.pet = true
HKTest.state.petHP = 550
HK.MendMark.Update()

-- ---------------------------------------------------------------------------
-- 4) Visibility gates
-- ---------------------------------------------------------------------------
HKTest.state.playerCombat, HKTest.state.petCombat = false, false
HK.MendMark.Update()
check("hidden out of combat when healthy", not HK.MendMark.IsShown())

HKTest.state.playerCombat = true
HK.db.mend.combatOnly = false
HK.MendMark.Update()
check("shown out of combat when 'only in combat' is off", HK.MendMark.IsShown())
HK.db.mend.combatOnly = true

HK.db.mend.enabled = false
HK.MendMark.Update()
check("hidden when the feature is disabled", not HK.MendMark.IsShown())
HK.db.mend.enabled = true
HK.MendMark.Update()

HK.db.enabled = false
HK.MendMark.Update()
check("hidden when the master switch is off", not HK.MendMark.IsShown())
HK.db.enabled = true
HK.MendMark.Update()

HKTest.state.pet = false
HK.MendMark.Update()
check("hidden with no pet", not HK.MendMark.IsShown())
HKTest.state.pet = true

HKTest.state.petDead = true
HK.MendMark.Update()
check("hidden with a dead pet", not HK.MendMark.IsShown())
HKTest.state.petDead = false
HK.MendMark.Update()
check("shown again once the pet is alive", HK.MendMark.IsShown())

-- Mend Pet not learned yet -> nothing to indicate
HKTest.state.spellName = nil
HK.MendMark.Update()
check("hidden when Mend Pet is not learned", not HK.MendMark.IsShown())

-- learning it (SPELLS_CHANGED clears the cached name) must bring it back
HKTest.state.spellName = "Mend Pet"
HKTest.Fire("SPELLS_CHANGED")
check("SPELLS_CHANGED picks up a newly trained Mend Pet", HK.MendMark.IsShown())

-- UNIT_HEALTH is the event that drives the urgent switch
HKTest.state.petHP = 900
HKTest.Fire("UNIT_HEALTH", "pet")
check("UNIT_HEALTH(pet) refreshes the marker", not ringOf(marker):IsShown())
HKTest.state.petHP = 100
HKTest.Fire("UNIT_HEALTH", "pet")
HKTest.Animate(1, 0.1)
check("UNIT_HEALTH(pet) flips it to urgent", ringOf(marker):IsShown())
HKTest.state.petHP = 550
HKTest.Fire("UNIT_HEALTH", "pet")

-- ---------------------------------------------------------------------------
-- 4b) Edit mode (/htk unlock) previews it so the sliders can be tuned
-- ---------------------------------------------------------------------------
HKTest.state.playerCombat, HKTest.state.petCombat = false, false
HKTest.state.petHP = 1000
HK.Positions = { locked = false }
HK.MendMark.Update()
check("edit mode shows it out of combat and healthy", HK.MendMark.IsShown())
HK.Positions = { locked = true }
HK.MendMark.Update()
check("locking again hides it", not HK.MendMark.IsShown())
HKTest.state.pet = false
HK.Positions = { locked = false }
HK.MendMark.Update()
check("edit mode previews it with no pet out", HK.MendMark.IsShown())
HK.Positions = { locked = true }
HKTest.state.pet = true
HKTest.state.playerCombat = true
HK.MendMark.Update()

-- ---------------------------------------------------------------------------
-- 5) Anchoring: name plate (world) vs pet frame (UI fallback)
-- ---------------------------------------------------------------------------
local plate = CreateFrame("Frame", "TestPetNamePlate", UIParent)
plate:SetSize(100, 40)
HKTest.state.plate = plate
HK.MendMark.Update()
check("anchors over the head when a plate exists", HK.MendMark.AnchorMode() == "plate",
  HK.MendMark.AnchorMode())
do
  local p = marker.points[1]
  check("marker sits above the plate", p and p[1] == "BOTTOM" and p[2] == plate and p[3] == "TOP")
end

-- a plate frame the client is recycling (hidden) must not be used
plate:Hide()
HK.MendMark.Update()
check("ignores a hidden plate frame", HK.MendMark.AnchorMode() == "petframe",
  HK.MendMark.AnchorMode())
plate:Show()

-- "plate" mode with no plate available stays hidden instead of moving
HK.db.mend.anchor = "plate"
HKTest.state.plate = nil
HK.MendMark.Update()
check("'plate' mode hides with no plate", not HK.MendMark.IsShown())
check("'plate' mode reports anchor=none", HK.MendMark.AnchorMode() == "none")
HKTest.state.plate = plate
HK.MendMark.Update()
check("'plate' mode shows with a plate", HK.MendMark.IsShown())

-- "petframe" mode never uses the plate
HK.db.mend.anchor = "petframe"
HK.MendMark.Update()
check("'petframe' mode ignores the plate", HK.MendMark.AnchorMode() == "petframe",
  HK.MendMark.AnchorMode())
HK.db.mend.anchor = "auto"
HKTest.state.plate = nil

-- ---------------------------------------------------------------------------
-- 6) Diagnostics + slash command must not error
-- ---------------------------------------------------------------------------
HKTest.prints = {}
local ok, err = pcall(SlashCmdList["HUNTERKIT"], "mend")
check("/htk mend runs without error", ok, err)
check("/htk mend prints a diagnostic", HKTest.prints[1] ~= nil and HKTest.prints[1]:find("Mend Marker") ~= nil,
  HKTest.prints[1])
local diag = HK.MendMark.Diagnostic()
check("diagnostic reports the range state", diag:find("inRange=true") ~= nil, diag)
check("diagnostic reports the anchor mode", diag:find("mode=petframe") ~= nil, diag)
check("plate cvars are readable", HK.MendMark.PlateCVars():find("nameplateShowFriends=") ~= nil)

HKTest.prints = {}
ok, err = pcall(HK.SelfCheck, HK)
check("/htk selfcheck runs without error", ok, err)
local foundMendProbe = false
for _, line in ipairs(HKTest.prints) do
  if line:find("mend marker") then foundMendProbe = true end
end
check("selfcheck has a mend marker probe", foundMendProbe)

HKTest.prints = {}
ok, err = pcall(SlashCmdList["HUNTERKIT"], "help")
check("/htk help runs without error", ok, err)
local foundHelpLine = false
for _, line in ipairs(HKTest.prints) do
  if line:find("/htk mend") then foundHelpLine = true end
end
check("help lists /htk mend", foundHelpLine)

-- ---------------------------------------------------------------------------
say(string.format("\n%d passed, %d failed", passes, #failures))
if #failures > 0 then
  for _, f in ipairs(failures) do say("  - " .. f) end
  error(#failures .. " test(s) failed")
end
