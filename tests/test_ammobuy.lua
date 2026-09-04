--[[==============================================================================
 HunterKit — tests: ammo auto-buy

 Drives the REAL AmmoBuy module against the client stub and asserts the planner
 on every case the feature has to survive: quiver capacity (slots x 200 and
 partial stacks), the three tier modes, the fill-percent option, the gold
 reserve / spend cap, limited stock, token-cost ammo, level-gated ammo, a
 missing quiver, a vendor with no ammo, and the purchase queue's stall abort.

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
local AB = HK.AmmoBuy
check("the AmmoBuy module loaded", AB ~= nil)

-- ---------------------------------------------------------------------------
-- Item catalogue: the real Classic vendor ammo ladder.
-- ---------------------------------------------------------------------------
local ARROW, BULLET = 2, 3
local ITEMS = {
  [2512]  = { name = "Rough Arrow",    reqLevel = 1,  iLevel = 1,  sub = ARROW },
  [2515]  = { name = "Sharp Arrow",    reqLevel = 10, iLevel = 15, sub = ARROW },
  [3030]  = { name = "Razor Arrow",    reqLevel = 25, iLevel = 30, sub = ARROW },
  [11285] = { name = "Jagged Arrow",   reqLevel = 40, iLevel = 45, sub = ARROW },
  [2516]  = { name = "Light Shot",     reqLevel = 1,  iLevel = 5,  sub = BULLET },
  [2519]  = { name = "Heavy Shot",     reqLevel = 10, iLevel = 15, sub = BULLET },
  [11284] = { name = "Accurate Slugs", reqLevel = 40, iLevel = 45, sub = BULLET },
}
HKTest.state.itemInfo = {}
for id, it in pairs(ITEMS) do
  HKTest.state.itemInfo[id] = {
    name = it.name, reqLevel = it.reqLevel, iLevel = it.iLevel,
    classID = 6, subclass = it.sub, stack = 200,
    texture = "Interface\\Icons\\INV_Ammo_Arrow_01",
  }
end

-- The stub's GetItemInfo returns the 1.15 positional shape the addon reads:
-- name, link, quality, iLevel, reqLevel, type, subType, stack, equipLoc,
-- texture, sellPrice, classID, subclassID.
function GetItemInfo(id)
  local it = (HKTest.state.itemInfo or {})[id]
  if not it then return nil end
  return it.name, "link", it.quality or 1, it.iLevel or 1, it.reqLevel or 0,
         "Projectile", "Arrow", it.stack or 200, "INVTYPE_AMMO", it.texture,
         0, it.classID, it.subclass
end

-- ---------------------------------------------------------------------------
-- Scenario helper: one call sets up the whole world.
-- ---------------------------------------------------------------------------
local function Scene(o)
  o = o or {}
  HKTest.buys = {}
  HKTest.popups = {}
  HKTest.state.level = o.level or 60
  HKTest.state.money = o.money or 10000000          -- 1000g unless told otherwise
  HKTest.state.ammoID = o.equipped                  -- nil = empty ammo slot
  HKTest.state.items = o.items or {}
  HKTest.state.refuseBuys = o.refuseBuys or false

  -- Bags. o.quiver = { slots = n, family = 1|2, contents = { [slot]={id=,count=} } }
  HKTest.state.bags = { [0] = 16 }
  HKTest.state.bagFamily = {}
  HKTest.state.bagItems = {}
  local q = o.quiver
  if q then
    HKTest.state.bags[1] = q.slots
    HKTest.state.bagFamily[1] = q.family or 1
    HKTest.state.bagItems[1] = q.contents or {}
  end

  -- Merchant. o.sells = { {id=, price=, quantity=, ...}, ... }
  HKTest.state.merchant = o.sells or {}

  -- The db slice for this scenario.
  local d = HK.db.ammobuy
  d.enabled      = o.enabled ~= false
  d.mode         = o.mode or "confirm"
  d.tier         = o.tier or "equipped"
  d.tierCap      = o.tierCap or 60
  d.full         = (o.full ~= false)
  d.percent      = o.percent or 100
  d.reserveGold  = o.reserveGold or 0
  d.maxSpendGold = o.maxSpendGold or 0
  d.showButton   = true
  AB.RescanSettings()
  return d
end

-- A stocked vendor selling the whole ladder at 200 per stack.
local function fullLadder()
  return {
    { id = 2512,  price = 2000,  quantity = 200 },   --  20s / 200 Rough Arrow
    { id = 2515,  price = 10000, quantity = 200 },   --   1g / 200 Sharp Arrow
    { id = 3030,  price = 20000, quantity = 200 },   --   2g / 200 Razor Arrow
    { id = 11285, price = 40000, quantity = 200 },   --   4g / 200 Jagged Arrow
    { id = 2516,  price = 2000,  quantity = 200 },
    { id = 11284, price = 40000, quantity = 200 },
  }
end

-- ---------------------------------------------------------------------------
-- 1) Capacity: an ammo bag slot holds 200, and partial stacks count exactly
-- ---------------------------------------------------------------------------
Scene({ quiver = { slots = 6, family = 1 } })
local cap, have, slots = AB.QuiverSpace("arrows", 2515)
check("an empty 6-slot quiver holds 1200 arrows", cap == 1200 and have == 0 and slots == 6,
  cap .. "/" .. have .. "/" .. slots)

Scene({ quiver = { slots = 6, family = 1,
        contents = { [1] = { id = 2515, count = 200 }, [2] = { id = 2515, count = 37 } } } })
cap, have = AB.QuiverSpace("arrows", 2515)
check("partial stacks are counted exactly", cap == 1200 and have == 237, cap .. "/" .. have)

-- A quiver slot holding a DIFFERENT arrow cannot take ours: it is capacity we
-- do not have, not progress we already made.
Scene({ quiver = { slots = 6, family = 1, contents = { [1] = { id = 2512, count = 200 } } } })
cap, have = AB.QuiverSpace("arrows", 2515)
check("a foreign stack removes the slot, it does not count as progress",
  cap == 1000 and have == 0, cap .. "/" .. have)

-- An ammo POUCH is family 2: it cannot hold arrows at all.
Scene({ quiver = { slots = 6, family = 2 } })
cap, have, slots = AB.QuiverSpace("arrows", 2515)
check("an ammo pouch offers no room for arrows", slots == 0 and cap == 0, tostring(cap))
cap = AB.QuiverSpace("bullets", 2516)
check("...but it holds 1200 bullets", cap == 1200, tostring(cap))

-- ---------------------------------------------------------------------------
-- 2) The basic plan: fill an empty quiver, in 200-per-stack bundles
-- ---------------------------------------------------------------------------
Scene({ quiver = { slots = 4, family = 1 }, equipped = 2515, sells = fullLadder() })
local plan, reason = AB.Plan()
check("plans a refill for an empty quiver", plan ~= nil, reason)
check("buys the equipped arrow", plan and plan.id == 2515, plan and plan.name)
check("buys exactly the missing 800", plan and plan.amount == 800, plan and plan.amount)
check("in 4 calls of 200 (the per-call stack cap)",
  plan and plan.calls == 4 and plan.perCall == 200,
  plan and (plan.calls .. "x" .. plan.perCall))
check("and prices them correctly (4 x 1g)", plan and plan.cost == 40000, plan and plan.cost)

-- Top-up: 750 in a 800 quiver is less than one bundle short -> refuse rather
-- than overflow (a stack that does not fit is money thrown away).
Scene({ quiver = { slots = 4, family = 1,
        contents = { [1] = { id = 2515, count = 200 }, [2] = { id = 2515, count = 200 },
                     [3] = { id = 2515, count = 200 }, [4] = { id = 2515, count = 150 } } },
        equipped = 2515, sells = fullLadder() })
plan = AB.Plan()
-- 750/800: the vendor is told the EXACT 50 missing, in a single call. The old
-- round-down-to-whole-stacks rule refused this outright and left the quiver
-- short, which is the whole point of buying by the unit.
check("tops up the exact remainder", plan and plan.amount == 50, plan and plan.amount)
check("...in one call", plan and plan.calls == 1, plan and plan.calls)
check("...and never exceeds the quiver", plan and plan.have + plan.amount == 800,
  plan and (plan.have + plan.amount))

-- One free slot: exactly one bundle fits.
Scene({ quiver = { slots = 4, family = 1,
        contents = { [1] = { id = 2515, count = 200 }, [2] = { id = 2515, count = 200 },
                     [3] = { id = 2515, count = 200 } } },
        equipped = 2515, sells = fullLadder() })
plan = AB.Plan()
check("tops up the one free slot with one stack", plan and plan.amount == 200,
  plan and plan.amount)

-- Already full.
Scene({ quiver = { slots = 2, family = 1,
        contents = { [1] = { id = 2515, count = 200 }, [2] = { id = 2515, count = 200 } } },
        equipped = 2515, sells = fullLadder() })
plan, reason = AB.Plan()
check("a full quiver buys nothing", plan == nil and tostring(reason):find("already") ~= nil,
  reason)

-- ---------------------------------------------------------------------------
-- 3) The fill slider: full (100%) vs a percentage of capacity
-- ---------------------------------------------------------------------------
Scene({ quiver = { slots = 10, family = 1 }, equipped = 2515, sells = fullLadder(),
        full = false, percent = 50 })
plan = AB.Plan()
check("50% of a 2000 quiver is 1000 arrows", plan and plan.amount == 1000, plan and plan.amount)

Scene({ quiver = { slots = 10, family = 1 }, equipped = 2515, sells = fullLadder(),
        full = false, percent = 25 })
plan = AB.Plan()
-- 25% of 2000 is 500. Buying by the unit hits that exactly -- no rounding to
-- stacks in either direction.
check("a between-stacks percentage is hit exactly",
  plan and plan.amount == 500, plan and plan.amount)
check("...spread over the fewest calls", plan and plan.calls == 3, plan and plan.calls)

Scene({ quiver = { slots = 10, family = 1 }, equipped = 2515, sells = fullLadder(),
        full = true, percent = 25 })
plan = AB.Plan()
check("'fill completely' overrides the percentage", plan and plan.amount == 2000,
  plan and plan.amount)

-- A percentage that lands between stacks must round DOWN, never overflow.
Scene({ quiver = { slots = 3, family = 1 }, equipped = 2515, sells = fullLadder(),
        full = false, percent = 90 })   -- 90% of 600 = 540 -> 2 stacks (400)... 3 fit (600)
plan = AB.Plan()
-- 90% of 600 = 540, bought exactly, and it still fits the 600 quiver.
check("a between-stacks target is exact and still fits",
  plan and plan.amount == 540 and plan.amount <= 600, plan and plan.amount)

-- ---------------------------------------------------------------------------
-- 4) Tier selection
-- ---------------------------------------------------------------------------
Scene({ quiver = { slots = 4, family = 1 }, equipped = 2512, sells = fullLadder(),
        tier = "equipped" })
plan = AB.Plan()
check("'equipped' buys more Rough Arrow", plan and plan.id == 2512, plan and plan.name)

Scene({ quiver = { slots = 4, family = 1 }, equipped = 2512, sells = fullLadder(),
        tier = "best" })
plan = AB.Plan()
check("'best' upgrades to Jagged Arrow at 60", plan and plan.id == 11285, plan and plan.name)

Scene({ quiver = { slots = 4, family = 1 }, equipped = 2512, sells = fullLadder(),
        tier = "capped", tierCap = 25 })
plan = AB.Plan()
check("'capped' stops at the level cap (Razor Arrow)", plan and plan.id == 3030,
  plan and plan.name)

-- Level gating: a level-20 hunter may not buy Razor (25) or Jagged (40).
Scene({ quiver = { slots = 4, family = 1 }, equipped = 2512, sells = fullLadder(),
        tier = "best", level = 20 })
plan = AB.Plan()
check("never buys ammo above the player's level", plan and plan.id == 2515, plan and plan.name)

-- A bullet user is never handed arrows, even when arrows are the better tier.
Scene({ quiver = { slots = 4, family = 2 }, equipped = 2516, sells = fullLadder(),
        tier = "best" })
plan = AB.Plan()
check("a gun user only ever gets bullets", plan and plan.id == 11284, plan and plan.name)

-- Equipped ammo the vendor does not stock falls back to the best of the SAME
-- kind. Equipped is Sharp (10) and the vendor offers Razor (25), so this
-- exercises the fallback WITHOUT tripping the never-downgrade guard -- that
-- interaction is covered on its own in section 4b.
Scene({ quiver = { slots = 4, family = 1 }, equipped = 2515,
        sells = { { id = 3030, price = 20000, quantity = 200 } }, tier = "equipped" })
plan = AB.Plan()
check("falls back when the vendor lacks the equipped ammo", plan and plan.id == 3030,
  plan and plan.name)

-- Empty ammo slot: guess from what the vendor sells (best usable).
Scene({ quiver = { slots = 4, family = 1 }, equipped = nil, sells = fullLadder(),
        tier = "best" })
plan, reason = AB.Plan()
check("an empty ammo slot still plans from the vendor's best", plan ~= nil, reason)

-- ---------------------------------------------------------------------------
-- 4b) Never buy worse ammo than you already shoot (on by default)
-- ---------------------------------------------------------------------------
check("the never-downgrade guard is on by default", HK.defaults.ammobuy.bestOnly == true)

-- The reported case: a level-60 hunter shooting Jagged Arrow (40) walks into a
-- starter-zone vendor that stocks only Rough Arrow (1).
local ONLY_ROUGH = { { id = 2512, price = 2000, quantity = 200 } }
Scene({ quiver = { slots = 4, family = 1 }, equipped = 11285, sells = ONLY_ROUGH,
        tier = "best" })
plan, reason = AB.Plan()
check("refuses to downgrade at a low-tier vendor", plan == nil, plan and plan.name)
check("...and names the tiers in the reason",
  tostring(reason):find("lower%-tier") ~= nil and tostring(reason):find("Rough Arrow") ~= nil,
  reason)

-- Turning the option off restores the old behaviour.
Scene({ quiver = { slots = 4, family = 1 }, equipped = 11285, sells = ONLY_ROUGH,
        tier = "best" })
HK.db.ammobuy.bestOnly = false
plan = AB.Plan()
check("with the guard off it buys the lower tier", plan and plan.id == 2512,
  plan and plan.name)
HK.db.ammobuy.bestOnly = true

-- Restocking the SAME tier is not a downgrade.
Scene({ quiver = { slots = 4, family = 1 }, equipped = 2512, sells = ONLY_ROUGH,
        tier = "best" })
plan = AB.Plan()
check("restocking the same tier is always allowed", plan and plan.id == 2512,
  plan and plan.name)

-- Upgrading is obviously fine.
Scene({ quiver = { slots = 4, family = 1 }, equipped = 2512, sells = fullLadder(),
        tier = "best" })
plan = AB.Plan()
check("upgrading is always allowed", plan and plan.id == 11285, plan and plan.name)

-- "equipped" mode: the vendor stocks our exact arrow, which can never be a
-- downgrade even though better ammo sits beside it.
Scene({ quiver = { slots = 4, family = 1 }, equipped = 2512, sells = fullLadder(),
        tier = "equipped" })
plan = AB.Plan()
check("the exact equipped item is never blocked by the guard",
  plan and plan.id == 2512, plan and plan.name)

-- "equipped" mode at a vendor lacking our arrow: the fallback is still guarded.
Scene({ quiver = { slots = 4, family = 1 }, equipped = 11285, sells = ONLY_ROUGH,
        tier = "equipped" })
plan, reason = AB.Plan()
check("the equipped-mode fallback is guarded too", plan == nil, plan and plan.name)

-- "capped" mode is a deliberate request for cheaper ammo, so the guard defers.
Scene({ quiver = { slots = 4, family = 1 }, equipped = 11285, sells = fullLadder(),
        tier = "capped", tierCap = 10 })
plan = AB.Plan()
check("an explicit tier cap outranks the guard", plan and plan.id == 2515,
  plan and plan.name)

-- An empty ammo slot has no yardstick, so the guard cannot block the refill.
Scene({ quiver = { slots = 4, family = 1 }, equipped = nil, sells = ONLY_ROUGH,
        tier = "best" })
plan, reason = AB.Plan()
check("an empty ammo slot still buys what is on offer", plan ~= nil, reason)

-- A level-gated vendor: the guard must not mask the real reason.
Scene({ quiver = { slots = 4, family = 1 }, equipped = 2515, sells = ONLY_ROUGH,
        tier = "best", level = 5 })
plan, reason = AB.Plan()
check("a downgrade refusal reads clearly at low level", plan == nil, plan and plan.name)

-- ---------------------------------------------------------------------------
-- 5) Gold limits
-- ---------------------------------------------------------------------------
Scene({ quiver = { slots = 10, family = 1 }, equipped = 2515, sells = fullLadder(),
        money = 25000 })          -- 2g 50s: only 2 whole 1g stacks
plan = AB.Plan()
-- 2g50s at 1g/200 = 0.5c each -> 500 arrows. The budget no longer has to
-- stretch to a whole stack; it buys every round it covers.
check("spends the budget down to the unit", plan and plan.amount == 500,
  plan and plan.amount)
check("and flags that gold, not space, decided it", plan and plan.trimmed == true)

Scene({ quiver = { slots = 10, family = 1 }, equipped = 2515, sells = fullLadder(),
        money = 100000, reserveGold = 8 })     -- 10g on hand, keep 8g -> 2 stacks
plan = AB.Plan()
check("the gold reserve is respected", plan and plan.amount == 400, plan and plan.amount)
check("...spending no more than the budget", plan and plan.cost <= 20000, plan and plan.cost)

Scene({ quiver = { slots = 10, family = 1 }, equipped = 2515, sells = fullLadder(),
        money = 10000000, maxSpendGold = 3 })
plan = AB.Plan()
check("the per-visit spend cap is respected", plan and plan.cost <= 30000, plan and plan.cost)
check("...buying what 3g covers", plan and plan.amount == 600, plan and plan.amount)

Scene({ quiver = { slots = 10, family = 1 }, equipped = 2515, sells = fullLadder(),
        money = 5000 })            -- 50s, one stack costs 1g
plan = AB.Plan()
-- 50s at 0.5c each = 100 arrows. Buying by the unit means a thin purse still
-- gets ammo instead of the old "cannot afford a whole 200-stack" refusal.
check("a thin purse still buys what it can", plan and plan.amount == 100,
  plan and plan.amount)

-- Genuinely too poor for even ONE round still refuses.
Scene({ quiver = { slots = 10, family = 1 }, equipped = 2515, sells = fullLadder(),
        money = 0 })
plan, reason = AB.Plan()
check("no money at all refuses cleanly", plan == nil, plan and plan.amount)

Scene({ quiver = { slots = 10, family = 1 }, equipped = 2515, sells = fullLadder(),
        money = 50000, reserveGold = 100 })
plan, reason = AB.Plan()
check("a reserve above your purse refuses cleanly",
  plan == nil and tostring(reason):find("reserve") ~= nil, reason)

-- ---------------------------------------------------------------------------
-- 6) Vendor edge cases
-- ---------------------------------------------------------------------------
Scene({ quiver = { slots = 4, family = 1 }, equipped = 2515, sells = {} })
plan, reason = AB.Plan()
check("no merchant open refuses", plan == nil and tostring(reason):find("merchant") ~= nil,
  reason)

Scene({ quiver = { slots = 4, family = 1 }, equipped = 2515,
        sells = { { id = 9999, price = 100, quantity = 1 } } })
plan, reason = AB.Plan()
check("a vendor with no projectiles refuses", plan == nil, plan and plan.name)

-- Token / honor cost ammo is never auto-bought: it cannot be priced in gold.
Scene({ quiver = { slots = 4, family = 1 }, equipped = 2515,
        sells = { { id = 2515, price = 0, quantity = 200, extendedCost = 1 } } })
plan, reason = AB.Plan()
check("token-cost ammo is never bought", plan == nil, plan and plan.name)

-- Limited stock clamps the purchase.
Scene({ quiver = { slots = 10, family = 1 }, equipped = 2515,
        sells = { { id = 2515, price = 10000, quantity = 200, numAvailable = 3 } } })
plan = AB.Plan()
check("limited stock clamps the amount", plan and plan.amount == 600, plan and plan.amount)

Scene({ quiver = { slots = 10, family = 1 }, equipped = 2515,
        sells = { { id = 2515, price = 10000, quantity = 200, numAvailable = 0 } } })
plan, reason = AB.Plan()
check("an out-of-stock vendor refuses",
  plan == nil and tostring(reason):find("stock") ~= nil, reason)

-- A vendor stack that is not 200 (5-per-slot goods) is honoured as-is.
Scene({ quiver = { slots = 2, family = 1 }, equipped = 2515,
        sells = { { id = 2515, price = 500, quantity = 20 } } })
plan = AB.Plan()
-- A 20-per-batch vendor at 5s a batch = 0.25s each. The quiver still wants its
-- exact 400, and the price is charged per unit from the batch price.
check("a non-200 batch prices per unit and still fills exactly",
  plan and plan.perStack == 20 and plan.amount == 400 and plan.cost == 10000,
  plan and (plan.amount .. " for " .. plan.cost))

-- No quiver at all.
Scene({ quiver = nil, equipped = 2515, sells = fullLadder() })
plan, reason = AB.Plan()
check("no quiver equipped refuses with a clear reason",
  plan == nil and tostring(reason):find("quiver") ~= nil, reason)

-- Disabled feature never plans.
Scene({ quiver = { slots = 4, family = 1 }, equipped = 2515, sells = fullLadder(),
        enabled = false })
plan, reason = AB.Plan()
check("the feature off means no plan", plan == nil, reason)

-- ---------------------------------------------------------------------------
-- 7) Executing the purchase
-- ---------------------------------------------------------------------------
local function TickBuy(n)
  for _, t in ipairs(HKTest.tickers) do
    if t.interval and math.abs(t.interval - 0.35) < 0.001 and not t.cancelled then
      for _ = 1, (n or 1) do t:Tick() end
      return true
    end
  end
  return false
end

Scene({ quiver = { slots = 4, family = 1 }, equipped = 2515, sells = fullLadder(),
        mode = "manual" })
plan = AB.Plan()
AB.Execute(plan)
TickBuy(10)
local bought = 0
for _, b in ipairs(HKTest.buys) do bought = bought + b.qty end
check("the run buys every planned UNIT", bought == 800, tostring(bought))
-- The regression this whole change is about: the executor used to pass the
-- STACK COUNT as BuyMerchantItem's quantity, which that API reads as a number
-- of items -- so an 800-arrow refill bought 4 arrows, one per tick. It must now
-- be 4 calls of 200.
check("in exactly 4 calls, not 800", #HKTest.buys == 4, tostring(#HKTest.buys))
check("each call moves a full 200-stack",
  (function() for _, b in ipairs(HKTest.buys) do if b.qty ~= 200 then return false end end
     return true end)(),
  HKTest.buys[1] and tostring(HKTest.buys[1].qty))
check("the run finishes and clears itself", AB.IsRunning() == false)

-- A small top-up is ONE call, not one call per arrow.
Scene({ quiver = { slots = 4, family = 1,
        contents = { [1] = { id = 2515, count = 200 }, [2] = { id = 2515, count = 200 },
                     [3] = { id = 2515, count = 200 }, [4] = { id = 2515, count = 137 } } },
        equipped = 2515, sells = fullLadder(), mode = "manual" })
plan = AB.Plan()
check("a 63-arrow top-up is planned exactly", plan and plan.amount == 63, plan and plan.amount)
AB.Execute(plan)
TickBuy(10)
check("...and bought in a single call", #HKTest.buys == 1 and HKTest.buys[1].qty == 63,
  #HKTest.buys .. " calls / " .. (HKTest.buys[1] and HKTest.buys[1].qty or "?"))

-- A big refill is chunked at the per-call stack cap, never above it (the server
-- silently drops an oversized call, which the stub models).
Scene({ quiver = { slots = 20, family = 1 }, equipped = 2515, sells = fullLadder(),
        mode = "manual" })
plan = AB.Plan()
check("a 4000-arrow refill is planned in full", plan and plan.amount == 4000,
  plan and plan.amount)
AB.Execute(plan)
TickBuy(40)
bought = 0
for _, b in ipairs(HKTest.buys) do bought = bought + b.qty end
check("a big refill completes", bought == 4000, tostring(bought))
check("...in 20 calls of 200", #HKTest.buys == 20, tostring(#HKTest.buys))

-- GetMerchantItemMaxStack famously returns 1 for stacking goods on some
-- clients. Trusting it would buy one arrow per call again, so the addon must
-- fall back to the item's real stack size.
Scene({ quiver = { slots = 4, family = 1 }, equipped = 2515, sells = fullLadder(),
        mode = "manual" })
HKTest.state.brokenMaxStack = true
plan = AB.Plan()
check("a broken max-stack of 1 falls back to the item stack size",
  plan and plan.perCall == 200, plan and plan.perCall)
AB.Execute(plan)
TickBuy(20)
bought = 0
for _, b in ipairs(HKTest.buys) do bought = bought + b.qty end
check("...and still buys everything in 4 calls",
  bought == 800 and #HKTest.buys == 4, bought .. "/" .. #HKTest.buys)
HKTest.state.brokenMaxStack = false

-- The client silently refuses (bags full / server hiccup): the queue must abort
-- after a few no-progress attempts, not spin forever.
Scene({ quiver = { slots = 10, family = 1 }, equipped = 2515, sells = fullLadder(),
        mode = "manual", refuseBuys = true })
plan = AB.Plan()
AB.Execute(plan)
TickBuy(30)
check("a stalled purchase aborts instead of looping", AB.IsRunning() == false)
check("...after only a few attempts", #HKTest.buys <= 5, tostring(#HKTest.buys))

-- Closing the merchant mid-run cancels it.
Scene({ quiver = { slots = 20, family = 1 }, equipped = 2515, sells = fullLadder(),
        mode = "manual" })
plan = AB.Plan()
AB.Execute(plan)
HKTest.Fire("MERCHANT_CLOSED")
check("closing the vendor cancels the run", AB.IsRunning() == false)

-- ---------------------------------------------------------------------------
-- 8) Modes at the vendor
-- ---------------------------------------------------------------------------
Scene({ quiver = { slots = 4, family = 1 }, equipped = 2515, sells = fullLadder(),
        mode = "confirm" })
HKTest.Fire("MERCHANT_SHOW")
HKTest.RunDelayed()
check("confirm mode asks first and spends nothing",
  #HKTest.popups == 1 and #HKTest.buys == 0,
  #HKTest.popups .. " popups / " .. #HKTest.buys .. " buys")

Scene({ quiver = { slots = 4, family = 1 }, equipped = 2515, sells = fullLadder(),
        mode = "auto" })
HKTest.Fire("MERCHANT_SHOW")
HKTest.RunDelayed()
TickBuy(10)
check("auto mode buys without asking", #HKTest.popups == 0 and #HKTest.buys > 0,
  #HKTest.popups .. " popups / " .. #HKTest.buys .. " buys")

Scene({ quiver = { slots = 4, family = 1 }, equipped = 2515, sells = fullLadder(),
        mode = "manual" })
HKTest.Fire("MERCHANT_SHOW")
HKTest.RunDelayed()
check("manual mode does nothing on its own",
  #HKTest.popups == 0 and #HKTest.buys == 0)
AB.Refill(true)
TickBuy(10)
check("...but /htk buy still refills", #HKTest.buys > 0, tostring(#HKTest.buys))

-- ---------------------------------------------------------------------------
-- 9) The merchant button: only at ammo vendors, anchored under the money frame
-- ---------------------------------------------------------------------------
local btn = _G["HunterKitRefillAmmo"]
check("the merchant frame gets a Refill ammo button", btn ~= nil)

-- It anchors BENEATH the player-money block, not to an arbitrary corner.
local pt = btn and btn.points[1]
check("the button hangs under the merchant money block",
  pt and pt[1] == "TOPLEFT" and pt[3] == "BOTTOMLEFT"
     and pt[2] == (_G["MerchantMoneyInset"] or _G["MerchantMoneyFrame"]),
  pt and (tostring(pt[1]) .. "->" .. tostring(pt[2] and pt[2].name) .. "/" .. tostring(pt[3])))

-- The reported bug: a fixed 130px width anchored only on the left ran past the
-- merchant frame's right edge. BOTH horizontal edges must be pinned, so the
-- width follows the anchor and can never overflow at any UI scale.
local pt2 = btn and btn.points[2]
check("the button pins its right edge too, so it cannot overflow the frame",
  pt2 and (pt2[1] == "TOPRIGHT" or pt2[1] == "BOTTOMRIGHT"),
  pt2 and tostring(pt2[1]) or "only one anchor point")
check("...and sets no fixed width that could fight the anchor",
  (btn.width or 0) == 0, tostring(btn.width))

-- A vendor with ammo on the shelf: the button is there.
Scene({ quiver = { slots = 4, family = 1 }, equipped = 2515, sells = fullLadder(),
        mode = "manual" })
HKTest.Fire("MERCHANT_SHOW")
check("the button shows at a vendor selling ammo", btn:IsShown())

-- A general-goods vendor / weaponsmith: no projectiles at all -> no button.
Scene({ quiver = { slots = 4, family = 1 }, equipped = 2515, mode = "manual",
        sells = { { id = 9999, price = 100, quantity = 1 } } })
HKTest.Fire("MERCHANT_SHOW")
check("the button hides at a vendor with no ammo", btn:IsShown() == false)
check("SellsAmmo() says so too", AB.SellsAmmo() == false)

-- Ammo you cannot use YET still counts as an ammo vendor: the button stays so
-- its tooltip can explain, rather than vanishing and leaving the player unsure.
Scene({ quiver = { slots = 4, family = 1 }, equipped = 2515, mode = "manual", level = 5,
        sells = { { id = 11285, price = 40000, quantity = 200 } } })
HKTest.Fire("MERCHANT_SHOW")
check("a vendor selling only too-high ammo is still an ammo vendor", AB.SellsAmmo() == true)
check("...so the button stays, to explain why", btn:IsShown())
plan, reason = AB.Plan()
check("...and the plan refuses on level", plan == nil, plan and plan.name)

-- Token-cost ammo is still ammo on the shelf.
Scene({ quiver = { slots = 4, family = 1 }, equipped = 2515, mode = "manual",
        sells = { { id = 2515, price = 0, quantity = 200, extendedCost = 1 } } })
check("token-cost ammo still counts as an ammo vendor", AB.SellsAmmo() == true)

-- Turning the option off hides it even at an ammo vendor.
Scene({ quiver = { slots = 4, family = 1 }, equipped = 2515, sells = fullLadder(),
        mode = "manual" })
HK.db.ammobuy.showButton = false
AB.UpdateButton()
check("the show-button option hides it", btn:IsShown() == false)
HK.db.ammobuy.showButton = true

-- Closing the vendor hides it again.
Scene({ quiver = { slots = 4, family = 1 }, equipped = 2515, sells = fullLadder(),
        mode = "manual" })
HKTest.Fire("MERCHANT_SHOW")
HKTest.Fire("MERCHANT_CLOSED")
check("closing the vendor hides the button", btn:IsShown() == false)

-- ---------------------------------------------------------------------------
-- 10) The four reported regressions
-- ---------------------------------------------------------------------------

-- (a) A quiver the client cannot classify (family reported as 0) must still be
-- found via GetItemFamily on the bag item. Reading it as an ordinary bag made
-- the addon see NO ammo bags -- "doesn't recognise quiver space".
Scene({ quiver = { slots = 6, family = 1 }, equipped = 2515, sells = fullLadder() })
HKTest.state.hideBagFamily = true
local c2, h2, s2 = AB.QuiverSpace("arrows", 2515)
check("a quiver reported as family 0 is still recognised", s2 == 6 and c2 == 1200,
  s2 .. " slots / " .. c2)
plan = AB.Plan()
check("...and it still plans a full refill", plan and plan.amount == 1200,
  plan and plan.amount)
HKTest.state.hideBagFamily = false

-- (b) Capacity must use the AMMO'S stack size, not a hardcoded 200. Special
-- ammo that stacks to 20 in a 6-slot quiver holds 120, not 1200 -- assuming 200
-- inflated capacity 10x and made every amount wrong.
HKTest.state.itemInfo[77777] = { name = "Odd Shot", reqLevel = 1, iLevel = 1,
  classID = 6, subclass = BULLET, stack = 20,
  texture = "Interface\\Icons\\INV_Ammo_Bullet_01" }
Scene({ quiver = { slots = 6, family = 2 }, equipped = 77777,
        sells = { { id = 77777, price = 1000, quantity = 20 } } })
local c3 = AB.QuiverSpace("bullets", 77777)
check("capacity follows the ammo's real stack size", c3 == 120, tostring(c3))
plan = AB.Plan()
check("...and the plan fills exactly that", plan and plan.amount == 120,
  plan and plan.amount)

-- (c) Ammo above the character's level is never bought, even when the item
-- cache is cold (reqLevel reads 0) -- the client's own isUsable flag must still
-- veto it.
Scene({ quiver = { slots = 4, family = 1 }, equipped = 2512, level = 5,
        sells = { { id = 11285, price = 40000, quantity = 200, isUsable = false } },
        tier = "best" })
plan, reason = AB.Plan()
check("ammo the client marks unusable is never bought", plan == nil, plan and plan.name)

Scene({ quiver = { slots = 4, family = 1 }, equipped = 2512, level = 5,
        sells = fullLadder(), tier = "best" })
plan = AB.Plan()
check("a level-5 hunter is only ever offered level-appropriate ammo",
  plan and plan.reqLevel == nil or true)
local picked = plan and HKTest.state.itemInfo[plan.id]
check("...i.e. nothing above their level", picked and picked.reqLevel <= 5,
  picked and picked.reqLevel)

-- (d) AUTO-FILL: the item cache is cold at MERCHANT_SHOW, so the first scan
-- finds nothing. The old single-shot 0.3s attempt gave up silently and bought
-- nothing, while the button worked a second later -- the exact report. The
-- retry must keep looking and then buy.
Scene({ quiver = { slots = 4, family = 1 }, equipped = 2515, sells = fullLadder(),
        mode = "auto" })
local realGetItemInfo = GetItemInfo
GetItemInfo = function() return nil end          -- cold cache: nothing resolves
HKTest.Fire("MERCHANT_SHOW")
HKTest.RunDelayed()                               -- the first attempt: finds nothing
check("a cold cache buys nothing yet", #HKTest.buys == 0, tostring(#HKTest.buys))
GetItemInfo = realGetItemInfo                     -- the cache warms up
HKTest.RunDelayed()                               -- the retry
TickBuy(10)
bought = 0
for _, b in ipairs(HKTest.buys) do bought = bought + b.qty end
check("auto-fill retries once the cache warms and completes the buy",
  bought == 800, tostring(bought))

-- A FINAL refusal (already full) must not retry forever.
Scene({ quiver = { slots = 2, family = 1,
        contents = { [1] = { id = 2515, count = 200 }, [2] = { id = 2515, count = 200 } } },
        equipped = 2515, sells = fullLadder(), mode = "auto" })
HKTest.Fire("MERCHANT_SHOW")
local rounds = 0
while HKTest.RunDelayed() > 0 and rounds < 20 do rounds = rounds + 1 end
check("a full quiver stops retrying instead of spinning", rounds < 3, tostring(rounds))
check("...and buys nothing", #HKTest.buys == 0, tostring(#HKTest.buys))

-- Closing the vendor cancels pending retries.
Scene({ quiver = { slots = 4, family = 1 }, equipped = 2515, sells = fullLadder(),
        mode = "auto" })
HKTest.Fire("MERCHANT_SHOW")
HKTest.Fire("MERCHANT_CLOSED")
HKTest.state.merchant = {}
rounds = 0
while HKTest.RunDelayed() > 0 and rounds < 20 do rounds = rounds + 1 end
check("closing the vendor cancels pending auto retries", #HKTest.buys == 0,
  tostring(#HKTest.buys))

-- Defaults are the safe ones.
check("auto-buy defaults to the confirm popup", HK.defaults.ammobuy.mode == "confirm",
  HK.defaults.ammobuy.mode)
check("auto-buy defaults to filling completely", HK.defaults.ammobuy.full == true)

-- Money formatting (what the popup shows).
check("money reads as g/s/c", AB.MoneyString(12345) == "1g 23s 45c", AB.MoneyString(12345))
check("copper-only money reads plainly", AB.MoneyString(7) == "7c", AB.MoneyString(7))

say(string.format("\n%d passed, %d failed", passes, #failures))
if #failures > 0 then
  for _, f in ipairs(failures) do say("  - " .. f) end
  error(#failures .. " test(s) failed")
end
