--[[==============================================================================
 HunterKit — tests: the feed button (FeedPet)

 Focused on the number painted on the button, because that number has been
 wrong twice: 0.9.13 fixed it reading the wrong struct field (itemCount instead
 of stackCount), and this suite exists for the second way it breaks -- the
 count being derived from the FOOD PICK instead of from the INVENTORY.

 Those are different questions. Which stack to feed depends on the pet's diet,
 the exclusion list and the item cache; how much of that food you own depends on
 none of them. Routing the count through the pick meant a pinned food (the pin
 path skips the diet check) or a transiently unreadable tooltip showed ONE
 stack's count -- "1" when you had a stack of 1 and a stack of 20.

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
HKTest.state.pet = true
HKTest.state.happiness = 2          -- below happy: the button is live
HKTest.state.level = 60
HKTest.state.itemInfo = HKTest.state.itemInfo or {}

local HK = HKTest.LoadAddon(unpack(HKTest.addonFiles))
HK:Load()
local FP = HK.FeedPet

check("FeedPet loaded", FP ~= nil)
check("the feed button exists", _G["HunterKitFeedButton"] ~= nil)

-- The stub defines no GetPetFoodTypes, and FeedPet:GetDiets treats "no diets
-- known" as "let everything through" -- which would silently disable the diet
-- filter these tests depend on. Give the pet a real diet.
GetPetFoodTypes = function() return "Meat" end
HKTest.Fire("UNIT_PET", "pet")     -- ResetDiets + mark the bags dirty
check("the pet's diet is known", FP:GetDiets().meat == true,
  tostring(FP:GetDietsString()))

-- Two helper stacks in bag 0. Bag 0 is the backpack, always present.
local function PutFood(id, name, iLevel, stacks)
  HKTest.state.itemInfo[id] = { name = name, iLevel = iLevel, texture = "t" }
  local slots = {}
  for i, n in ipairs(stacks) do slots[i] = { id = id, count = n } end
  HKTest.state.bags = { [0] = math.max(16, #stacks) }
  HKTest.state.bagItems = { [0] = slots }
  HK.db.feed.preferredFoods = {}
  HK.db.feed.exclude = {}
  HKTest.Fire("UNIT_PET", "pet")
  FP.Refresh()
end

-- ---------------------------------------------------------------------------
-- 1) The baseline: a food the curated DB knows, unpinned. This worked before
--    and must keep working.
-- ---------------------------------------------------------------------------
local JERKY = 117                       -- Tough Jerky, in FOOD_BY_TYPE["Meat"]
check("the test food really is in the curated DB", FP:FoodType(JERKY) == "Meat",
  tostring(FP:FoodType(JERKY)))

PutFood(JERKY, "Tough Jerky", 55, { 1, 20 })
check("a known food shows every stack (1 + 20 = 21)", FP.ShownCount() == 21,
  tostring(FP.ShownCount()))
check("...and it picks the smallest open stack to feed",
  FP:PickFood().count == 1, tostring(FP:PickFood() and FP:PickFood().count))

PutFood(JERKY, "Tough Jerky", 55, { 5 })
check("a single stack shows its own size", FP.ShownCount() == 5,
  tostring(FP.ShownCount()))

-- ---------------------------------------------------------------------------
-- 2) The bug: the SAME food, pinned. The pin path (FindBestStackByID) does not
--    run the diet check, so if the diet check also rejected the item, the
--    per-food totals table had no entry for it and the button fell back to the
--    single stack the pin resolved to.
-- ---------------------------------------------------------------------------
local ODD = 7777                        -- NOT in FOOD_BY_ITEM
check("the second test food is not in the curated DB", FP:FoodType(ODD) == nil,
  tostring(FP:FoodType(ODD)))
PutFood(ODD, "Mystery Meat", 55, { 1, 20 })
-- The stub's scanning tooltip has no lines, which is exactly what the live
-- client returns for an item whose data is not cached yet -- the case the
-- tooltip fallback in MatchesDiet exists for, and the case where it fails.
check("an unlisted food the tooltip cannot describe does not match the diet",
  FP:MatchesDiet(0, 1, ODD) == false, tostring(FP:MatchesDiet(0, 1, ODD)))

HK.db.feed.preferredFoods = { { id = ODD, name = "Mystery Meat" } }
HKTest.Fire("UNIT_PET", "pet")
FP.Refresh()
local picked = FP:PickFood()
check("the pinned food is what gets picked", picked and picked.itemID == ODD,
  tostring(picked and picked.itemID))
check("pinned food: the count is every stack (1 + 20 = 21), not the one stack",
  FP.ShownCount() == 21, "showed " .. tostring(FP.ShownCount()) .. ", bags hold 21")

-- Unpinning an unlisted food leaves nothing the addon recognises as feedable,
-- so the button correctly shows the "?" icon and 0. The point of this check is
-- that the number tracks the pick instead of going stale at the pinned total.
HK.db.feed.preferredFoods = {}
HKTest.Fire("UNIT_PET", "pet")
FP.Refresh()
check("unpinned: nothing recognised as food shows 0, not a stale number",
  FP.ShownCount() == 0, tostring(FP.ShownCount()))
check("...and the totals table still knows the bags hold 21 of it",
  FP.foodTotals and FP.foodTotals[ODD] == 21,
  tostring(FP.foodTotals and FP.foodTotals[ODD]))

-- ---------------------------------------------------------------------------
-- 3) Three stacks, and a stack the diet check rejects mid-scan. The count must
--    be the inventory total whatever the pick logic made of it.
-- ---------------------------------------------------------------------------
PutFood(JERKY, "Tough Jerky", 55, { 7, 13, 20 })
check("three stacks are all counted (7 + 13 + 20 = 40)", FP.ShownCount() == 40,
  tostring(FP.ShownCount()))

-- ---------------------------------------------------------------------------
-- 4) Nothing to feed: the button must say 0, not a stale number.
-- ---------------------------------------------------------------------------
HKTest.state.bagItems = { [0] = {} }
HKTest.Fire("UNIT_PET", "pet")
FP.Refresh()
check("empty bags show 0", FP.ShownCount() == 0, tostring(FP.ShownCount()))

-- Report this file's tally so tests/test_docs.lua can check the README's
-- advertised check counts against what the suite really runs.
HKTest.report("test_feedpet.lua", passes, #failures)

say(string.format("\n%d passed, %d failed", passes, #failures))
if #failures > 0 then
  for _, f in ipairs(failures) do say("  - " .. f) end
  error(#failures .. " test(s) failed")
end
