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

-- ---------------------------------------------------------------------------
-- 5) Never feed a quest item. It is the one mistake this button can make that
--    the player cannot buy their way out of: feeding it destroys it.
-- ---------------------------------------------------------------------------
local QUEST = 5555
-- Not in the curated DB, so it reaches the tooltip fallback -- and its tooltip
-- mentions "meat", which is exactly what that fallback looks for. Its item
-- level also makes it the BEST tier, so the old code did not merely tolerate
-- it, it preferred it over the real food.
HKTest.state.itemInfo[QUEST] = { name = "Tough Wolf Meat", iLevel = 58, class = "Quest" }
HKTest.state.itemInfo[JERKY] = { name = "Tough Jerky", iLevel = 40, texture = "t" }
HKTest.state.bags = { [0] = 16 }
HKTest.state.bagItems = { [0] = {
  [1] = { id = QUEST, count = 3,
          tip = { "Tough Wolf Meat", "Quest Item", "Stringy meat, still warm." } },
  [2] = { id = JERKY, count = 20 },
} }
HK.db.feed.preferredFoods = {}
HK.db.feed.exclude = {}
HKTest.Fire("UNIT_PET", "pet")

check("IsQuestItem recognises a quest item by its item type",
  FP:IsQuestItem(0, 1, QUEST) == true, tostring(FP:IsQuestItem(0, 1, QUEST)))
check("...and does not flag real food",
  FP:IsQuestItem(0, 2, JERKY) == false, tostring(FP:IsQuestItem(0, 2, JERKY)))

FP.Refresh()
local pick = FP:PickFood()
check("a quest item is never picked over real food",
  pick ~= nil and pick.itemID == JERKY,
  "picked " .. tostring(pick and pick.name) .. " (id " .. tostring(pick and pick.itemID) .. ")")
check("the count still covers the food it did pick", FP.ShownCount() == 20,
  tostring(FP.ShownCount()))

-- A quest item the item cache cannot type (GetItemInfo returns nil for its
-- class, which happens), leaving only the tooltip line to go on.
local QUEST2 = 5556
HKTest.state.itemInfo[QUEST2] = { name = "Discoloured Fang", iLevel = 58 }
HKTest.state.bagItems[0][3] = { id = QUEST2, count = 2,
                                tip = { "Discoloured Fang", "Quest Item" } }
HKTest.Fire("UNIT_PET", "pet")
check("IsQuestItem falls back to the tooltip line",
  FP:IsQuestItem(0, 3, QUEST2) == true, tostring(FP:IsQuestItem(0, 3, QUEST2)))
FP.Refresh()
pick = FP:PickFood()
check("an untyped quest item is not picked either",
  pick ~= nil and pick.itemID == JERKY,
  "picked " .. tostring(pick and pick.name))

-- Pinning must not be a way around it: an old pin, or one saved before this
-- check existed, must not be able to destroy a quest item.
HK.db.feed.preferredFoods = { { id = QUEST, name = "Tough Wolf Meat" } }
HKTest.Fire("UNIT_PET", "pet")
FP.Refresh()
pick = FP:PickFood()
check("a pinned quest item is refused too",
  pick == nil or pick.itemID ~= QUEST,
  "picked " .. tostring(pick and pick.name))
HK.db.feed.preferredFoods = {}

-- ---------------------------------------------------------------------------
-- 6) With no diet known, do not guess. GetDiets is empty for a moment after
--    every login (the pet has not resolved yet), and the old code treated that
--    as "let everything through" -- so the button armed itself with the most
--    level-appropriate item in your bags, whatever it was.
-- ---------------------------------------------------------------------------
local POTION = 6666
HKTest.state.itemInfo[POTION] = { name = "Healing Potion", iLevel = 60 }
HKTest.state.bagItems[0][4] = { id = POTION, count = 5 }
GetPetFoodTypes = function() return nil end      -- pet not resolved yet
HKTest.Fire("UNIT_PET", "pet")
check("the diet really is unknown for this check", next(FP:GetDiets()) == nil,
  tostring(FP:GetDietsString()))
check("with no diet known, an unlisted item is not offered as food",
  FP:MatchesDiet(0, 4, POTION) == false, tostring(FP:MatchesDiet(0, 4, POTION)))
check("...but a known pet food still is",
  FP:MatchesDiet(0, 2, JERKY) == true, tostring(FP:MatchesDiet(0, 2, JERKY)))
FP.Refresh()
pick = FP:PickFood()
check("a potion is never what the button arms itself with",
  pick == nil or pick.itemID ~= POTION, "picked " .. tostring(pick and pick.name))

GetPetFoodTypes = function() return "Meat" end   -- restore for the next run
HKTest.Fire("UNIT_PET", "pet")

-- Report this file's tally so tests/test_docs.lua can check the README's
-- advertised check counts against what the suite really runs.

-- ---------------------------------------------------------------------------
-- 7) The container API answering with no stack count.
--
-- THIS is the reported "shows 1 when more", and it survived the earlier fix
-- because that fix was aimed at the totals table -- and the table was never the
-- problem. The per-slot numbers feeding it were.
--
-- When HK.GetBagItemCount returns nil, PickFood's `or 1` counts EVERY stack as
-- one: a stack of 20 reads 1, and 1 + 20 reads 2. The totals table then
-- faithfully summed garbage and the button displayed it. The fix reconciles
-- each total against GetItemCount -- the client's own per-item total, and what
-- AmmoBuy.lua and AmmoWarn.lua have always used.
-- ---------------------------------------------------------------------------
PutFood(JERKY, "Tough Jerky", 55, { 20 })
HKTest.state.noStackCount = true
check("precondition: the container API gives no per-slot count here",
  HK.GetBagItemCount(0, 1) == nil, tostring(HK.GetBagItemCount(0, 1)))

HKTest.state.items = { [JERKY] = 20 }
FP.Refresh()
check("a single stack of 20 reads 20, not 1", FP.ShownCount() == 20,
  tostring(FP.ShownCount()))

PutFood(JERKY, "Tough Jerky", 55, { 1, 20 })
HKTest.state.noStackCount = true
HKTest.state.items = { [JERKY] = 21 }
FP.Refresh()
check("two stacks read their real total, not 2", FP.ShownCount() == 21,
  tostring(FP.ShownCount()))

-- GetItemCount can answer 0 for a moment after a bag change (AmmoWarn documents
-- this, post-hearthstone). The scan is the fallback in that window, so the
-- worst case is an under-count from the scan -- never a wrong 1 over a good API.
HKTest.state.noStackCount = false
HKTest.state.items = {}
FP.Refresh()
check("when GetItemCount is cold the scan still counts every stack",
  FP.ShownCount() == 21, tostring(FP.ShownCount()))

HKTest.state.noStackCount = false
HKTest.state.items = {}

-- ---------------------------------------------------------------------------
-- 8) Counting foods TOGETHER, and only the ones this pet eats.
--
-- The button's number used to be the inventory total of the ONE item the pick
-- happened to land on. A hunter carrying eight different appropriate-level
-- meats with a single item in each -- which is exactly what looting produces --
-- saw "1", with no way to know they were holding eight feeds. And a pin made
-- for one pet kept being offered to the next one, diet or no diet.
-- ---------------------------------------------------------------------------
local WOLF, STEAK = 769, 1015      -- both Meat in the curated DB
local FISH = 787                   -- Slitherskin Mackerel: Meat pets refuse it

-- Several DIFFERENT foods in one bag, each with its own stack sizes.
local function PutFoods(list)
  local slots, n = {}, 0
  for _, f in ipairs(list) do
    HKTest.state.itemInfo[f.id] = { name = f.name, iLevel = f.level, texture = "t" }
    for _, c in ipairs(f.stacks) do
      n = n + 1
      slots[n] = { id = f.id, count = c }
    end
  end
  HKTest.state.bags = { [0] = math.max(16, n) }
  HKTest.state.bagItems = { [0] = slots }
  HK.db.feed.preferredFoods = {}
  HK.db.feed.exclude = {}
  HKTest.state.noStackCount = false
  HKTest.state.items = {}
  HKTest.Fire("UNIT_PET", "pet")
  FP.Refresh()
end

-- (a) The headline case: three different foods, one item each, same level.
PutFoods({
  { id = JERKY, name = "Tough Jerky",       level = 55, stacks = { 1 } },
  { id = WOLF,  name = "Stringy Wolf Meat", level = 55, stacks = { 1 } },
  { id = STEAK, name = "Lean Wolf Steak",   level = 55, stacks = { 1 } },
})
check("three single foods of the same level are counted together",
  FP.ShownCount() == 3, tostring(FP.ShownCount()))
check("...and the tooltip can say that was three different foods",
  FP.ShownKinds() == 3, tostring(FP.ShownKinds()))

-- (b) Food this pet does not eat never enters the number, however much of it
--     you are carrying. A Meat pet with 20 mackerel has one feed, not 21.
PutFoods({
  { id = JERKY, name = "Tough Jerky",          level = 55, stacks = { 1 } },
  { id = FISH,  name = "Slitherskin Mackerel", level = 55, stacks = { 20 } },
})
check("food the pet cannot eat is not counted",
  FP.ShownCount() == 1, tostring(FP.ShownCount()))
check("...and is not counted as a kind either",
  FP.ShownKinds() == 1, tostring(FP.ShownKinds()))

-- (c) "Similar level" means the happiness TIER, which is the only grouping the
--     game itself recognises: within 15 levels a bite is 35 happiness, at
--     16-25 it is 17, beyond that 8. Cheap grey food is not a feed you can
--     stand in for a real one, so it stays out of the number.
PutFoods({
  { id = JERKY, name = "Tough Jerky",       level = 55, stacks = { 2 } },
  { id = WOLF,  name = "Stringy Wolf Meat", level = 20, stacks = { 40 } },
})
check("lower-level food is not added to the best tier's number",
  FP.ShownCount() == 2, tostring(FP.ShownCount()))

-- (d) Grouping is per FOOD, not per slot: two stacks of one item are one food,
--     and TotalOf must run once per item or every stack would be raised to the
--     whole inventory total and then added together.
PutFoods({
  { id = JERKY, name = "Tough Jerky",       level = 55, stacks = { 1, 20 } },
  { id = WOLF,  name = "Stringy Wolf Meat", level = 55, stacks = { 4 } },
})
check("two stacks of one food plus another food (1 + 20 + 4 = 25)",
  FP.ShownCount() == 25, tostring(FP.ShownCount()))
check("...counted as two foods, not three",
  FP.ShownKinds() == 2, tostring(FP.ShownKinds()))

-- (e) The pick rule is untouched: best tier, then the smallest open stack.
local pick = FP:PickFood()
check("the pick still takes the smallest open stack of the best tier",
  pick ~= nil and pick.itemID == JERKY and pick.count == 1,
  "picked " .. tostring(pick and pick.name) .. " x" .. tostring(pick and pick.count))

-- (f) A pin made for a different pet. Pin mackerel for the crab, summon the
--     bear, and the button used to keep arming itself with the mackerel --
--     naming it in the tooltip and feeding it on click.
PutFoods({
  { id = JERKY, name = "Tough Jerky",          level = 55, stacks = { 5 } },
  { id = FISH,  name = "Slitherskin Mackerel", level = 55, stacks = { 5 } },
})
HK.db.feed.preferredFoods = { { id = FISH, name = "Slitherskin Mackerel" } }
FP.Refresh()
pick = FP:PickFood()
check("a pinned food this pet cannot eat is not picked",
  pick ~= nil and pick.itemID ~= FISH,
  "picked " .. tostring(pick and pick.name))
check("...and is not what the button offers to feed",
  FP.lastFood == nil or FP.lastFood.itemID ~= FISH,
  tostring(FP.lastFood and FP.lastFood.name))
check("...and the number still counts only the real food",
  FP.ShownCount() == 5, tostring(FP.ShownCount()))
HK.db.feed.preferredFoods = {}
FP.Refresh()

-- (g) The other side of that line. Right after every login the pet's diet has
--     not resolved, so GetPetFoodTypes has nothing to say. There is no evidence
--     to overrule a pin with, so the pin stands -- even for a food the DB would
--     place outside the diet once the pet does resolve. Refusing here would make
--     pins look broken for the first minute of every session.
PutFoods({
  { id = FISH, name = "Slitherskin Mackerel", level = 55, stacks = { 5 } },
})
HK.db.feed.preferredFoods = { { id = FISH, name = "Slitherskin Mackerel" } }
GetPetFoodTypes = function() return nil end
HKTest.Fire("UNIT_PET", "pet")
FP.Refresh()
pick = FP:PickFood()
check("with no diet resolved, silence does not overrule a pin",
  pick ~= nil and pick.itemID == FISH, "picked " .. tostring(pick and pick.name))
-- ...and once the diet resolves, the same pin IS overruled.
GetPetFoodTypes = function() return "Meat" end
HKTest.Fire("UNIT_PET", "pet")
FP.Refresh()
pick = FP:PickFood()
check("...but once the diet resolves, the same pin is refused",
  pick == nil or pick.itemID ~= FISH, "picked " .. tostring(pick and pick.name))
GetPetFoodTypes = function() return "Meat" end
HK.db.feed.preferredFoods = {}
HKTest.Fire("UNIT_PET", "pet")
FP.Refresh()

-- ---------------------------------------------------------------------------
-- 9) The hover tooltip's happiness line.
--
-- It claimed a Happy pet could not be fed at all -- "Pet is Happy (full) -- the
-- game won't feed it now". Happy is a THRESHOLD, not the cap: there is
-- happiness headroom above green, the game takes the food and keeps granting it
-- until the real ceiling (where a tick drops to about 1 and the rest is
-- wasted). The one thing that genuinely blocks a feed is COMBAT, and the
-- tooltip never mentioned it -- so it warned about the case that still works
-- and stayed silent about the one that does not.
-- ---------------------------------------------------------------------------
local function TooltipText()
  GameTooltip.lines = {}
  local fb = _G["HunterKitFeedButton"]
  fb:GetScript("OnEnter")(fb)
  local out = {}
  for _, l in ipairs(GameTooltip.lines) do out[#out + 1] = l.text or "" end
  return table.concat(out, " | ")
end

PutFood(JERKY, "Tough Jerky", 55, { 5 })

HKTest.state.happiness = 3
HKTest.state.combatLockdown = false
local tip = TooltipText()
check("a happy pet is not told it cannot be fed",
  tip:find("won't feed", 1, true) == nil, tip)
check("...and the tooltip no longer calls Happy \"full\"",
  tip:find("(full)", 1, true) == nil, tip)
check("...it warns that feeding a happy pet now wastes food",
  tip:find("wastes food", 1, true) ~= nil, tip)

HKTest.state.combatLockdown = true
tip = TooltipText()
check("combat is named as the thing that actually blocks a feed",
  tip:find("In combat", 1, true) ~= nil, tip)
check("...and the happy-pet advice gives way to it",
  tip:find("wastes food", 1, true) == nil, tip)

HKTest.state.combatLockdown = false
HKTest.state.happiness = 1
tip = TooltipText()
check("an unhappy pet is told to feed it now",
  tip:find("feed it now", 1, true) ~= nil, tip)

HKTest.state.happiness = 2
tip = TooltipText()
check("a content pet still says it will feed on click",
  tip:find("will feed on click", 1, true) ~= nil, tip)

HKTest.state.happiness = 2
HKTest.state.combatLockdown = false

-- ---------------------------------------------------------------------------
-- 10) Teaching the button, and showing what it is NOT counting.
--
-- There is no API for a food's diet type -- the Feed Me author states it
-- outright, and every maintained feeder ships a hand-curated table and admits
-- it is incomplete. Cooked food is the hole that matters, because cooked food
-- is what a hunter carries. So the button can be taught by dropping food on it,
-- and shift-hover shows the gap so the player can see what to drop.
-- ---------------------------------------------------------------------------
local ROAST, STEW, NAMEFOOD = 9001, 9002, 9003
local fb10 = _G["HunterKitFeedButton"]
local function MarkEdible(id)
  HKTest.state.itemInfo[id].class = "Consumable"
  HKTest.state.itemInfo[id].subclass = "Food & Drink"
end

PutFoods({ { id = ROAST, name = "Roasted Quail", level = 55, stacks = { 12 } } })
MarkEdible(ROAST)
check("a cooked dish is not in the curated DB", FP:FoodType(ROAST) == nil,
  tostring(FP:FoodType(ROAST)))
check("...so it is not counted as feedable", FP.ShownCount() == 0,
  tostring(FP.ShownCount()))

-- (a) drop it on the button
HKTest.state.cursor = { value = ROAST }
fb10:GetScript("OnReceiveDrag")(fb10)
check("dropping a food on the button teaches it", FP.HasLearned(ROAST) == true,
  tostring(FP.HasLearned(ROAST)))
check("...and pins it to the right-click list", FP:IsPinned(ROAST) == true,
  tostring(FP:IsPinned(ROAST)))
check("...and releases the cursor", HKTest.state.cursor == nil,
  tostring(HKTest.state.cursor))
check("...and it is now counted", FP.ShownCount() == 12, tostring(FP.ShownCount()))

-- (b) the diet recorded at the moment of the drop travels with the entry
GetPetFoodTypes = function() return "Fish" end
HKTest.Fire("UNIT_PET", "pet")
FP.Refresh()
check("a pet that cannot eat it no longer counts it", FP.ShownCount() == 0,
  tostring(FP.ShownCount()))
GetPetFoodTypes = function() return "Meat" end
HKTest.Fire("UNIT_PET", "pet")
FP.Refresh()
check("...and switching back restores it", FP.ShownCount() == 12,
  tostring(FP.ShownCount()))

-- (c) a quest item is never learned: feeding one destroys it
HKTest.state.cursor = { value = QUEST }
fb10:GetScript("OnReceiveDrag")(fb10)
check("a quest item on the cursor is refused", FP.HasLearned(QUEST) == false,
  tostring(FP.HasLearned(QUEST)))
check("...and the cursor is still released", HKTest.state.cursor == nil,
  tostring(HKTest.state.cursor))

-- (d) the gesture is an option, and turning it off must not swallow the item --
--     the player may be dragging it somewhere else entirely.
HK.db.feed.learnDrop = false
HKTest.state.cursor = { value = STEW }
fb10:GetScript("OnReceiveDrag")(fb10)
check("the option turns the gesture off", FP.HasLearned(STEW) == false,
  tostring(FP.HasLearned(STEW)))
check("...and leaves the player holding the item", HKTest.state.cursor ~= nil,
  tostring(HKTest.state.cursor))
HKTest.state.cursor = nil
HK.db.feed.learnDrop = true

-- (e) the tooltip scan now reads the item's NAME, not just the lines under it.
--     Half of Classic's foods are called some kind of meat or fish, and the old
--     loop started at line 2 -- quietly discarding the best evidence available
--     for an item the DB does not list.
PutFoods({ { id = NAMEFOOD, name = "Stringy Bat Meat", level = 55, stacks = { 7 } } })
MarkEdible(NAMEFOOD)
HKTest.state.bagItems[0][1].tip = { "Stringy Bat Meat",
  "Use: Restores 1320 health over 30 sec." }
FP.Refresh()                      -- the scan has to run WITH the tooltip present
check("an unlisted food matches the diet on its name alone",
  FP.ShownCount() == 7, tostring(FP.ShownCount()))

-- (f) shift-hover shows what is not being counted
PutFoods({
  { id = JERKY, name = "Tough Jerky",  level = 55, stacks = { 3 } },
  { id = STEW,  name = "Hunter's Stew", level = 55, stacks = { 9 } },
})
MarkEdible(STEW)
HKTest.state.shift = true
local tip10 = TooltipText()
check("shift-hover names the food that is not counted",
  tip10:find("Hunter's Stew", 1, true) ~= nil, tip10)
check("...and says what to do about it",
  tip10:find("drop one here", 1, true) ~= nil, tip10)
-- Only the part under the heading: the picked food is named higher up in the
-- tooltip as "Will feed:", so asserting on the whole string would fail for the
-- wrong reason.
local uncounted = tip10:match("Not counted.*") or ""
check("...and lists only what is NOT counted",
  uncounted:find("Hunter's Stew", 1, true) ~= nil and
  uncounted:find("Tough Jerky", 1, true) == nil, uncounted)
HKTest.state.shift = false
tip10 = TooltipText()
check("without shift the list stays out of the way",
  tip10:find("Hunter's Stew", 1, true) == nil, tip10)

-- (g) both cursor shapes. Classic answers "item", link; newer clients answer
--     "item", id. Reading only one would silently ignore every drop on the
--     other client.
HKTest.state.cursor = { value = "|cffffffff|Hitem:9002::::::::60:::::|h[Hunter's Stew]|h|r" }
fb10:GetScript("OnReceiveDrag")(fb10)
check("an item LINK on the cursor is read as well as an id",
  FP.HasLearned(STEW) == true, tostring(FP.HasLearned(STEW)))

-- (h) Taught while the pet had not resolved yet. GetPetFoodTypes has nothing to
--     say for a moment after every login, so there is no diet to record -- and
--     the player's word still has to stand, or the gesture would appear to work
--     and then silently stop counting the food a minute later.
local BACON = 9004
PutFoods({ { id = BACON, name = "Crisp Bacon Strips", level = 55, stacks = { 4 } } })
MarkEdible(BACON)
GetPetFoodTypes = function() return nil end
HKTest.Fire("UNIT_PET", "pet")
check("precondition: the diet is unresolved here", next(FP:GetDiets()) == nil,
  FP:GetDietsString())
HKTest.state.cursor = { value = BACON }
fb10:GetScript("OnReceiveDrag")(fb10)
GetPetFoodTypes = function() return "Meat" end
HKTest.Fire("UNIT_PET", "pet")
FP.Refresh()
check("the button remembers the food it was taught", FP:IsLearned(BACON) == true,
  tostring(FP:IsLearned(BACON)))
-- Unpin it first. ReceiveDrop pins as well as teaches, and the pin path
-- honours the player's word on its own -- so with the pin still in place the
-- count would come from the pin and prove nothing about the taught diet.
HK.db.feed.preferredFoods = {}
FP.Refresh()
check("food taught while the diet was unresolved is still feedable",
  FP.ShownCount() == 4, tostring(FP.ShownCount()))
GetPetFoodTypes = function() return "Meat" end
HKTest.Fire("UNIT_PET", "pet")

HKTest.state.shift = false
HKTest.state.cursor = nil
HK.db.feed.learnDrop = true

HKTest.report("test_feedpet.lua", passes, #failures)

say(string.format("\n%d passed, %d failed", passes, #failures))
if #failures > 0 then
  for _, f in ipairs(failures) do say("  - " .. f) end
  error(#failures .. " test(s) failed")
end
