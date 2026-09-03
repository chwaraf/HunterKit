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
-- 3b) Secure feed button: no SetSize/SetPoint while in combat
-- ---------------------------------------------------------------------------
-- Regression: ticking "Enable HunterKit" in combat threw ADDON_ACTION_BLOCKED on
-- HunterKitFeedButton:SetSize(). The resize/anchor must defer to regen.
local keepSize = HK.db.feed.size
HK.db.feed.size = 40
HKTest.state.combatLockdown = true
HK.FeedPet.RescanSettings()
check("no secure resize while in combat", HK.FeedPet.ButtonSize() ~= 40,
  tostring(HK.FeedPet.ButtonSize()))
HKTest.state.combatLockdown = false
HKTest.Fire("PLAYER_REGEN_ENABLED")
check("deferred resize applied after combat", HK.FeedPet.ButtonSize() == 40,
  tostring(HK.FeedPet.ButtonSize()))
HK.db.feed.size = keepSize
HKTest.Fire("PLAYER_REGEN_ENABLED")

-- ---------------------------------------------------------------------------
-- 4) Per-state brightness sliders scale the drawn glow
-- ---------------------------------------------------------------------------
SetState("OK")
HK.db.range.brightOK = 50
HK.Range.RescanSettings()
local r, g, b = HK.Range.DrawnColor()
check("brightness slider dims the IN RANGE mark", math.abs(g - 0.5) <= 0.01,
  tostring(g))
HK.db.range.brightOK = 100
HK.Range.RescanSettings()
local r2, g2 = HK.Range.DrawnColor()
check("brightness 100 restores full glow", math.abs(g2 - 1) <= 0.01, tostring(g2))

-- ---------------------------------------------------------------------------
-- 5) Brightness overdrive stacks a second additive pass
-- ---------------------------------------------------------------------------
SetState("OK")
HK.db.range.brightOK = 150
HK.Range.RescanSettings()
local _, g = HK.Range.DrawnColor()
check("overdrive clamps the base colour at full", math.abs(g - 1) <= 0.01, tostring(g))
check("overdrive draws a second additive pass", HK.Range.VisibleShapes() == 2,
  tostring(HK.Range.VisibleShapes()))
HK.db.range.brightOK = 100
HK.Range.RescanSettings()
check("100% is a single pass", HK.Range.VisibleShapes() == 1,
  tostring(HK.Range.VisibleShapes()))

-- ---------------------------------------------------------------------------
-- 6) Low ammo warning: periodic, more persistent as ammo drops, with sound
-- ---------------------------------------------------------------------------
local ammoTicker
for _, t in ipairs(HKTest.tickers) do
  if t.interval == 1 then ammoTicker = t end
end
check("ammo ticker running", ammoTicker ~= nil)
HKTest.state.ammoID = 2515
HKTest.state.items = { [2515] = 800 }
HKTest.state.itemInfo = { [2515] = { name = "Rough Arrow", subclass = 2,
  texture = "Interface\\Icons\\INV_Ammo_Arrow_02" } }
HKTest.state.now = 1000
ammoTicker:Tick()
check("no warning while stocked", not HK.AmmoWarn.IsShown(),
  tostring(HK.AmmoWarn.IsShown()))
HKTest.state.items[2515] = 60
HKTest.state.now = 2000
ammoTicker:Tick()
check("warns when low", HK.AmmoWarn.IsShown(), tostring(HK.AmmoWarn.IsShown()))
check("warning sound played", #HKTest.soundsPlayed > 0, tostring(#HKTest.soundsPlayed))
check("low tiers speak the situation: bundled 'low ammo' voice clip",
  HKTest.soundsPlayed[#HKTest.soundsPlayed] ==
    "Interface\\AddOns\\HunterKit\\Media\\voice_lowammo.ogg",
  tostring(HKTest.soundsPlayed[#HKTest.soundsPlayed]))
local s1 = #HKTest.soundsPlayed
HKTest.state.now = 2010
ammoTicker:Tick()
check("periodic: no re-warn inside the period", #HKTest.soundsPlayed == s1,
  tostring(#HKTest.soundsPlayed))
HKTest.state.now = 2100
ammoTicker:Tick()
check("re-warn after the period is visual only (sound stays rare)",
  HK.AmmoWarn.IsShown() and #HKTest.soundsPlayed == s1,
  tostring(HK.AmmoWarn.IsShown()) .. "/" .. tostring(#HKTest.soundsPlayed))
HKTest.state.items[2515] = 10
HKTest.state.now = 3000
ammoTicker:Tick()
check("escalation sounds again", #HKTest.soundsPlayed == s1 + 1,
  tostring(#HKTest.soundsPlayed))
HKTest.state.items[2515] = 0
HKTest.state.now = 4000
ammoTicker:Tick()
check("empty ammo is the most persistent tier", HK.AmmoWarn.IsShown(),
  tostring(HK.AmmoWarn.IsShown()))
check("empty tier speaks: bundled voice clip for the equipped ammo",
  HKTest.soundsPlayed[#HKTest.soundsPlayed] ==
    "Interface\\AddOns\\HunterKit\\Media\\voice_noarrows.ogg",
  tostring(HKTest.soundsPlayed[#HKTest.soundsPlayed]))
local v1 = #HKTest.soundsPlayed
HKTest.state.now = 4011
ammoTicker:Tick()
check("voice does not nag: silent re-warn inside the 30 s cooldown",
  HK.AmmoWarn.IsShown() and #HKTest.soundsPlayed == v1,
  tostring(HK.AmmoWarn.IsShown()) .. "/" .. tostring(#HKTest.soundsPlayed))
HKTest.state.now = 4041
ammoTicker:Tick()
check("voice returns once the cooldown is over", #HKTest.soundsPlayed == v1 + 1,
  tostring(#HKTest.soundsPlayed))
local aw = _G["HunterKitAmmoWarn"]
check("icon is the equipped ammo's own art",
  aw.textures[1].texture == "Interface\\Icons\\INV_Ammo_Arrow_02",
  tostring(aw.textures[1].texture))
check("red X crosses the icon",
  aw.textures[2].texture == "Interface\\Buttons\\UI-GroupLoot-Pass-Up",
  tostring(aw.textures[2].texture))
HKTest.state.items = nil
HKTest.state.ammoID = nil

-- ---------------------------------------------------------------------------
-- 7) Feed button: total food count in the icon + highlight rule
--    (highlight ON only when the pet is BELOW happy AND out of combat)
-- ---------------------------------------------------------------------------
local fb = _G["HunterKitFeedButton"]
check("feed button exists", fb ~= nil)
HKTest.state.pet = true
HKTest.state.petHP = 900
HKTest.state.playerCombat, HKTest.state.petCombat = false, false
HKTest.state.combatLockdown = false
HKTest.state.happiness = 2
HKTest.state.bags = { [0] = 3 }
HKTest.state.bagItems = { [0] = { [1] = { id = 1113, count = 20 },
                                   [2] = { id = 1113, count = 15 },
                                   [3] = { id = 1114, count = 50 } } }
HKTest.state.itemInfo[1113] = { name = "Tough Hunk of Bread", iLevel = 5,
  texture = "Interface\\Icons\\INV_Misc_Food_01" }
HKTest.state.itemInfo[1114] = { name = "Fresh Bread", iLevel = 5,
  texture = "Interface\\Icons\\INV_Misc_Food_02" }
HK.db.feed.enabled = true
HK.db.feed.hungryOnly = false
HK.FeedPet.Refresh()
check("feed icon shows the picked food", fb.textures[1].texture ==
  "Interface\\Icons\\INV_Misc_Food_01", tostring(fb.textures[1].texture))
check("count = total of the picked food across its stacks",
  fb.fontstrings[1]:GetText() == "35", tostring(fb.fontstrings[1]:GetText()))
check("count font does not depend on a possibly-missing font object",
  fb.fontstrings[1].font == "Fonts\\ARIALN.TTF" and
  fb.fontstrings[1].fontOutline == "OUTLINE",
  tostring(fb.fontstrings[1].font))
check("highlight on: below happy, out of combat",
  fb.textures[2].color[2] == 0.8 and fb.textures[2].color[4] == 1,
  table.concat(fb.textures[2].color, ","))
check("icon tint doubles as the highlight when hungry",
  fb.textures[1].color[2] == 0.8, table.concat(fb.textures[1].color, ","))
HKTest.state.happiness = 3
HK.FeedPet.Refresh()
check("highlight off when the pet is happy", fb.textures[2].color[4] == 0,
  table.concat(fb.textures[2].color, ","))
check("icon untinted when happy", fb.textures[1].color[1] == 1 and
  fb.textures[1].color[2] == 1, table.concat(fb.textures[1].color, ","))
HKTest.state.happiness = 2
HKTest.state.combatLockdown = true
HK.FeedPet.Refresh()
check("highlight off in combat even when hungry", fb.textures[2].color[4] == 0,
  table.concat(fb.textures[2].color, ","))
HKTest.state.combatLockdown = false
HKTest.state.happiness = nil
HKTest.state.bags = nil
HKTest.state.bagItems = nil

say(string.format("\n%d passed, %d failed", passes, #failures))
if #failures > 0 then
  for _, f in ipairs(failures) do say("  - " .. f) end
  error(#failures .. " test(s) failed")
end
