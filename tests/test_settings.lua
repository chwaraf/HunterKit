--[[==============================================================================
 HunterKit — tests: sniper-mark shapes and the settings reset
 Loads the REAL addon against tests/wow_stub.lua (all modules, .toc order) and
 asserts:

   * each of the three range states offers six distinct shapes, and the shape
     actually follows the dropdown (it didn't: the shape table was built at load
     time from three textures that did not exist yet, so it was empty and every
     style resolved to the same fallback)
   * Reset ALL settings restores every default, keeps the db slices the modules
     already hold, and re-displays the open window
   * the reset button needs two clicks, and its armed state expires

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
local HK = HKTest.LoadAddon(unpack(HKTest.addonFiles))
HK:Load()
check("every module initialises without error",
  table.concat(HKTest.prints, "\n"):find("load error") == nil,
  table.concat(HKTest.prints, "\n"))

local content = _G["HunterKitOptionsContent"]

-- ---------------------------------------------------------------------------
-- 1) Sniper mark: six distinct shapes per range state
-- ---------------------------------------------------------------------------
HKTest.state.target = true
HK.db.range.enabled = true

local STATES = { "OK", "DEAD", "FAR" }
for _, state in ipairs(STATES) do
  local names = HK.Range.StyleNames(state)
  check(state .. " offers six shapes", #names == 6, tostring(#names))
  local seen, dupes = {}, 0
  for _, n in ipairs(names) do
    local prims = HK.Range.Primitives(state, n)
    if type(prims) ~= "table" or #prims == 0 then
      check(state .. "/" .. n .. " draws something", false, "no primitives")
    end
    local parts = {}
    for _, p in ipairs(prims or {}) do parts[#parts + 1] = table.concat(p, ",") end
    local sig = table.concat(parts, "|")
    if seen[sig] then dupes = dupes + 1 end
    seen[sig] = n
  end
  check(state .. " shapes are all distinct", dupes == 0, dupes .. " duplicates")
end

-- The shape on screen must follow the saved choice. This is the regression: the
-- old shape table was empty, so every state fell back to its default art.
local function SetState(which)
  HKTest.state.targetSpellInRange = (which == "OK") and 1 or 0
  HKTest.state.targetTooClose = (which == "DEAD")
end

SetState("OK")
HK.db.range.markOK = "diamond"
HK.Range.RescanSettings()
check("IN RANGE uses the chosen shape", HK.Range.CurrentStyle() == "diamond",
  tostring(HK.Range.CurrentStyle()))
HK.db.range.markOK = "ticks"
HK.Range.RescanSettings()
check("changing the shape redraws it", HK.Range.CurrentStyle() == "ticks",
  tostring(HK.Range.CurrentStyle()))
check("the mark is actually drawn", HK.Range.VisibleShapes() > 0,
  tostring(HK.Range.VisibleShapes()))

SetState("DEAD")
HK.db.range.markDead = "burst"
HK.Range.RescanSettings()
check("TOO CLOSE uses the chosen shape", HK.Range.CurrentStyle() == "burst",
  tostring(HK.Range.CurrentStyle()))

SetState("FAR")
HK.db.range.markFar = "slashes"
HK.Range.RescanSettings()
HK.Range.Update() -- entering FAR needs a second agreeing tick (debounce)
check("OUT OF RANGE uses the chosen shape", HK.Range.CurrentStyle() == "slashes",
  tostring(HK.Range.CurrentStyle()))

HK.db.range.markFar = "not-a-shape"
HK.Range.RescanSettings()
check("an unknown saved shape falls back", HK.Range.CurrentStyle() == "ban",
  tostring(HK.Range.CurrentStyle()))

-- every style draws at its own size
HK.db.range.markFar = "rings"
HK.db.range.size = 96
HK.Range.RescanSettings()
local wide = HK.Range.VisibleShapes()
check("a resized mark still draws", wide > 0, tostring(wide))

-- Regression: a one-tick OUT OF RANGE misread must never flash on screen while
-- crossing between TOO CLOSE and IN RANGE (the probes can lag the server's
-- position for a single tick).
HK.db.range.markOK = "crosshair"
SetState("OK")
HK.Range.Update()
check("crosses into IN RANGE immediately", HK.Range.CurrentStyle() == "crosshair",
  tostring(HK.Range.CurrentStyle()))
SetState("FAR")
HK.Range.Update() -- a lone misread tick
check("a lone FAR tick does not flash", HK.Range.CurrentStyle() == "crosshair",
  tostring(HK.Range.CurrentStyle()))
SetState("OK")
HK.Range.Update()
check("still IN RANGE after the misread", HK.Range.CurrentStyle() == "crosshair",
  tostring(HK.Range.CurrentStyle()))

-- ---------------------------------------------------------------------------
-- 2) Reset ALL settings
-- ---------------------------------------------------------------------------
SetState("FAR")
HK.db.range.size = 99
HK.db.range.markOK = "ticks"
HK.db.range.markFar = "slashes"
HK.db.range.moved = true
HK.db.range.offsetX = 123
HK.db.mend.size = 71
HK.db.mend.enabled = false
HK.db.feed.size = 47
HK.db.sound.enabled = false
local rangeSlice = HK.db.range          -- identity the module already holds
local mendSlice = HK.db.mend

HK.ResetAll()
HK.Range.Update() -- second tick confirms the FAR state after the reset

check("sizes restored", HK.db.range.size == HK.defaults.range.size
  and HK.db.mend.size == HK.defaults.mend.size
  and HK.db.feed.size == HK.defaults.feed.size,
  HK.db.range.size .. "/" .. HK.db.mend.size .. "/" .. HK.db.feed.size)
check("shapes restored", HK.db.range.markOK == HK.defaults.range.markOK
  and HK.db.range.markFar == HK.defaults.range.markFar)
check("toggles restored", HK.db.mend.enabled == true and HK.db.sound.enabled == true)
check("saved positions restored", HK.db.range.moved == false
  and HK.db.range.offsetX == HK.defaults.range.offsetX,
  tostring(HK.db.range.moved) .. "/" .. tostring(HK.db.range.offsetX))
check("the db slices the modules hold survived",
  HK.db.range == rangeSlice and HK.db.mend == mendSlice)
check("the sniper mark re-read the reset", HK.Range.CurrentStyle() == "ban",
  tostring(HK.Range.CurrentStyle()))

-- ---------------------------------------------------------------------------
-- 3) The Reset ALL settings button: two clicks, and the arm expires
-- ---------------------------------------------------------------------------
local resetBtn
for _, f in ipairs(HKTest.frames) do
  if f.parent == content and f.GetText and f:GetText() == "Reset ALL settings" then
    resetBtn = f
  end
end
check("the window has a Reset ALL settings button", resetBtn ~= nil)

if resetBtn then
  local click = resetBtn:GetScript("OnClick")
  check("the button is clickable", click ~= nil)

  HK.db.range.size = 99
  HK.db.mend.size = 71
  click(resetBtn)
  check("the first click only arms it", HK.db.range.size == 99
    and resetBtn:GetText() == "Click again to CONFIRM",
  tostring(HK.db.range.size) .. "/" .. tostring(resetBtn:GetText()))

  HKTest.RunDelayed()                    -- the 5-second disarm fires
  check("the armed state expires on its own",
    resetBtn:GetText() == "Reset ALL settings", tostring(resetBtn:GetText()))
  check("an expired confirm changes nothing", HK.db.range.size == 99,
    tostring(HK.db.range.size))

  click(resetBtn)                        -- arm
  click(resetBtn)                        -- confirm
  check("the second click resets everything",
    HK.db.range.size == HK.defaults.range.size
      and HK.db.mend.size == HK.defaults.mend.size,
    HK.db.range.size .. "/" .. HK.db.mend.size)
  check("the button disarms after resetting",
    resetBtn:GetText() == "Reset ALL settings", tostring(resetBtn:GetText()))

  -- the open window must show the restored numbers, not the old ones
  local shownDefault = false
  for _, fs in ipairs(content.fontstrings) do
    if fs:IsShown() and fs:GetText() == tostring(HK.defaults.mend.size) then
      shownDefault = true
    end
  end
  check("the window re-displays the restored values", shownDefault)
end

-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- 3) The master switch hides every feature, not just the mend marker
-- ---------------------------------------------------------------------------
-- Regression: unchecking "Enable HunterKit" used to hide only the mend marker;
-- the sniper mark, feed button and passive alert kept running because their
-- modules only looked at their own per-feature toggle.
HKTest.state.pet = true
HK.db.enabled = true
SetState("OK")
HK.Range.RescanSettings()
HK.FeedPet.RescanSettings()
check("master on: mark shown", HK.Range.IsFrameValid(),
  tostring(HK.Range.IsFrameValid()))
check("master on: feed button shown", HK.FeedPet.IsButtonValid(),
  tostring(HK.FeedPet.IsButtonValid()))

HK.db.enabled = false
HK.Range.RescanSettings()
HK.FeedPet.RescanSettings()
check("master off hides the mark", not HK.Range.IsFrameValid(),
  tostring(HK.Range.IsFrameValid()))
check("master off hides the feed button", not HK.FeedPet.IsButtonValid(),
  tostring(HK.FeedPet.IsButtonValid()))

HK.db.enabled = true
HK.Range.RescanSettings()
HK.FeedPet.RescanSettings()
check("master on restores the mark", HK.Range.IsFrameValid(),
  tostring(HK.Range.IsFrameValid()))

-- ---------------------------------------------------------------------------
-- 4) Feed button anchor: under the pet's name when shown, else the avatar
-- ---------------------------------------------------------------------------
HK.db.feed.followName = true
local feedPlate = CreateFrame("Frame", "FeedTestPlate", UIParent)
feedPlate:SetSize(100, 30)
feedPlate.namePlateUnitToken = "pet"
HKTest.state.scanPlate = feedPlate
HK.FeedPet.RescanSettings()
check("feed button hangs under the pet's name when shown",
  HK.FeedPet.AnchorKind() == "plate", tostring(HK.FeedPet.AnchorKind()))
HKTest.state.scanPlate = nil
HK.FeedPet.RescanSettings()
check("feed button defaults to under the pet avatar",
  HK.FeedPet.AnchorKind() == "frame", tostring(HK.FeedPet.AnchorKind()))

say(string.format("\n%d passed, %d failed", passes, #failures))
if #failures > 0 then
  for _, f in ipairs(failures) do say("  - " .. f) end
  error(#failures .. " test(s) failed")
end
