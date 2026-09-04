--[[==============================================================================
 HunterKit — Ammo Auto-Buy (quiver / ammo pouch refill at a vendor)

 Opens a merchant, works out how many arrows/bullets are missing from the
 AMMO-SPECIFIC bags (quiver for arrows, ammo pouch for bullets), and buys
 exactly that many -- the EXACT count, in as few vendor calls as allowed.

 The whole feature is a planner (`AmmoBuy.Plan`) plus an executor
 (`AmmoBuy.Execute`). The planner is pure: it reads the client and returns a
 table (or nil + a human reason), which is what the tests drive and what the
 confirm popup prints. Nothing is ever bought without a plan.

 Everything the design has to survive, and where it is handled:

   * no quiver/pouch equipped                -> Plan: reason "no quiver"
   * pouch equipped but arrows in the slot   -> family match, reason "no quiver"
   * nothing in the ammo slot                -> fall back to the best usable
                                                projectile of EITHER kind that
                                                the merchant sells
   * merchant doesn't sell that ammo         -> reason "vendor has no ammo"
   * merchant sells better ammo than you use -> tier mode decides (see below)
   * ammo above your level                   -> filtered by required level and
                                                the client's own isUsable flag
   * token / honor / currency cost ammo      -> extendedCost items are skipped
   * limited stock (numAvailable)            -> purchase clamped to stock
   * not enough gold                         -> buy as many UNITS as the money
                                                (minus the reserve, minus the
                                                per-visit cap) pays for
   * quiver already full / over target       -> reason "already full"
   * a partial stack in the quiver           -> capacity math is count-based
                                                (slots x 200), so top-ups work
   * vendor stack size that isn't 200        -> perStack comes from the merchant
                                                (GetMerchantItemInfo quantity)
   * client refuses a buy mid-run            -> the queue watches the bag count
                                                and aborts after 3 no-progress
                                                attempts instead of looping
   * merchant window closed mid-run          -> MERCHANT_CLOSED cancels the queue
   * dead / ghost / no merchant open         -> Plan refuses outright
   * a second trigger while a run is live    -> re-entrancy guard

 Buys are spaced by a timer (never a tight loop): the server applies each
 purchase asynchronously and the bag count has to catch up before the next one
 is judged.
==============================================================================]]
local _, HK = ...

local AmmoBuy = {}
HK.AmmoBuy = AmmoBuy

local db

-- Bag family bits (Classic): 1 = Quiver (arrows), 2 = Ammo Pouch (bullets).
local FAMILY_QUIVER = 1
local FAMILY_POUCH  = 2

-- Item class 6 = Projectile; subclasses 2 = Arrow, 3 = Bullet.
local CLASS_PROJECTILE = 6
local SUBCLASS_ARROW   = 2
local SUBCLASS_BULLET  = 3

-- Vendors sell basic ammo 200 to a purchase, and 200 is also the stack cap, so
-- one BuyMerchantItem call may never move more than this many units.
local MAX_PER_BUY = 200

local BUY_INTERVAL = 0.35   -- seconds between purchases (server round-trip)
-- How many consecutive no-progress ticks before the run gives up.
--
-- This used to be 3, i.e. about a second of patience. On a laggy realm the
-- server simply had not applied the purchase yet, the bag count had not moved,
-- and a perfectly healthy refill aborted after the first stack or two --
-- reported as "buys too little". Progress is now also credited when the money
-- went down (the buy DID land, the bag count just has not caught up), and the
-- patience is several seconds, which costs nothing when things are healthy
-- because a real refusal still ends the run.
local MAX_STALLS   = 8

local COLOR = "|cff39ff14HunterKit|r "

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------
local function Say(...)
  print(COLOR .. table.concat({ ... }, " "))
end

-- Lua 5.1 on the client has no bit library guaranteed in every context, and the
-- family field is a small bitfield -- plain arithmetic is portable and exact.
local function HasBit(value, bit)
  value = tonumber(value) or 0
  if value < 0 then return false end
  return math.floor(value / bit) % 2 == 1
end

function AmmoBuy.MoneyString(copper)
  copper = math.max(0, math.floor(tonumber(copper) or 0))
  local g = math.floor(copper / 10000)
  local s = math.floor((copper % 10000) / 100)
  local c = copper % 100
  local out = {}
  if g > 0 then out[#out + 1] = g .. "g" end
  if g > 0 or s > 0 then out[#out + 1] = s .. "s" end
  out[#out + 1] = c .. "c"
  return table.concat(out, " ")
end

-- ---------------------------------------------------------------------------
-- Client API compat (all pcall-guarded: a missing API must degrade to "unknown"
-- and make the planner refuse, never throw inside a merchant frame).
-- ---------------------------------------------------------------------------
local function Call(fn, ...)
  if type(fn) ~= "function" then return nil end
  local res = { pcall(fn, ...) }
  if not res[1] then return nil end
  return unpack(res, 2, #res)
end

-- freeSlots, bagFamily for a bag index.
-- freeSlots, bagFamily for a bag index.
--
-- Two independent sources, because neither is reliable alone:
--   * GetContainerNumFreeSlots returns the family, but it reports 0 for a bag
--     it cannot classify AND 0 legitimately means "general purpose" -- so a
--     zero can never be trusted as a final answer.
--   * GetItemFamily on the equipped bag item is authoritative for a quiver, and
--     is what actually works when the container call comes back 0.
-- A quiver read as family 0 was seen by the addon as an ordinary bag, so it
-- found NO ammo bags at all -- the "doesn't recognise quiver space" report.
local function BagInfo(bag)
  local free, family
  if C_Container and C_Container.GetContainerNumFreeSlots then
    free, family = Call(C_Container.GetContainerNumFreeSlots, bag)
  end
  if family == nil and GetContainerNumFreeSlots then
    free, family = Call(GetContainerNumFreeSlots, bag)
  end
  if (family == nil or family == 0) then
    -- Ask the bag ITEM what family it belongs to. Bag N lives in inventory slot
    -- ContainerIDToInventoryID(N); GetItemFamily on its link gives the same
    -- bitfield the container API should have returned.
    local invID = Call(ContainerIDToInventoryID, bag)
    if invID then
      local link = Call(GetInventoryItemLink, "player", invID)
      if link then
        local fam = Call(GetItemFamily, link)
        if type(fam) == "number" and fam > 0 then family = fam end
      end
    end
  end
  return free, family
end

local function PlayerLevel()
  return tonumber(Call(UnitLevel, "player")) or 1
end

local function Money()
  return tonumber(Call(GetMoney)) or 0
end

-- name, itemLevel, reqLevel, classID, subclassID, stackCount, texture
local function ItemFacts(item)
  local name, _, _, iLevel, reqLevel, _, _, stack, _, texture, _, classID, subclassID =
    HK.GetItemInfo(item)
  if type(name) ~= "string" or name == "" then return nil end
  -- Older/odd clients can leave classID nil; fall back to the name so a plan is
  -- still possible instead of the feature silently doing nothing.
  if classID == nil then
    local low = name:lower()
    if low:find("arrow", 1, true) then
      classID, subclassID = CLASS_PROJECTILE, SUBCLASS_ARROW
    elseif low:find("shot", 1, true) or low:find("bullet", 1, true)
        or low:find("slug", 1, true) or low:find("shell", 1, true)
        or low:find("pellet", 1, true) then
      classID, subclassID = CLASS_PROJECTILE, SUBCLASS_BULLET
    end
  end
  return {
    name = name, iLevel = tonumber(iLevel) or 0, reqLevel = tonumber(reqLevel) or 0,
    classID = classID, subclassID = subclassID, stack = tonumber(stack) or 1,
    texture = texture,
  }
end

local function KindOfSubclass(sub)
  if sub == SUBCLASS_ARROW then return "arrows" end
  if sub == SUBCLASS_BULLET then return "bullets" end
  return nil
end

local function FamilyForKind(kind)
  return kind == "arrows" and FAMILY_QUIVER or FAMILY_POUCH
end

-- ---------------------------------------------------------------------------
-- What is in the ammo slot right now (id, kind). nil when the slot is empty or
-- the inventory has not synced yet -- the planner treats both as "no opinion"
-- and falls back to the best usable ammo the vendor has.
-- ---------------------------------------------------------------------------
function AmmoBuy.EquippedAmmo()
  local slot = Call(GetInventorySlotInfo, "AmmoSlot")
  if not slot then return nil, nil end
  local id = Call(GetInventoryItemID, "player", slot)
  if not id then
    local link = Call(GetInventorySlotLink, "player", slot)
    if type(link) == "string" then id = tonumber(link:match("item:(%d+)")) end
  end
  if not id then return nil, nil end
  local facts = ItemFacts(id)
  if not facts then return id, nil, nil end
  -- The third return is the equipped ammo's required level: the yardstick the
  -- "never downgrade" guard compares vendor offers against.
  return id, KindOfSubclass(facts.subclassID), facts.reqLevel
end

-- ---------------------------------------------------------------------------
-- What the player can actually SHOOT: "arrows", "bullets", or nil (no ranged
-- weapon, or the client did not answer).
--
-- Weapon subclasses: 2 = Bow, 3 = Gun, 18 = Crossbow. Bows and crossbows eat
-- arrows, guns eat bullets, and buying the other kind is money set on fire --
-- the ammo cannot even be equipped. The ammo slot is the primary signal, but it
-- is empty exactly when the player has run dry, which is precisely when a
-- refill is wanted, so the weapon is the fallback that keeps that case safe
-- instead of guessing from whatever the vendor happens to stock.
-- ---------------------------------------------------------------------------
local CLASS_WEAPON      = 2
local SUBCLASS_BOW      = 2
local SUBCLASS_GUN      = 3
local SUBCLASS_CROSSBOW = 18

function AmmoBuy.WeaponKind()
  local slot = Call(GetInventorySlotInfo, "RangedSlot")
  if not slot then return nil end
  local link = Call(GetInventoryItemLink, "player", slot)
  if type(link) ~= "string" then return nil end
  local facts = ItemFacts(link)
  if not facts then return nil end
  if facts.classID ~= nil and facts.classID ~= CLASS_WEAPON then return nil end
  local sub = facts.subclassID
  if sub == SUBCLASS_BOW or sub == SUBCLASS_CROSSBOW then return "arrows" end
  if sub == SUBCLASS_GUN then return "bullets" end
  -- classID was nil (cold cache): the name is the last resort, and only when it
  -- is unambiguous.
  local low = (facts.name or ""):lower()
  if low:find("bow", 1, true) or low:find("crossbow", 1, true) then return "arrows" end
  if low:find("gun", 1, true) or low:find("rifle", 1, true)
     or low:find("blunderbuss", 1, true) or low:find("musket", 1, true) then return "bullets" end
  return nil
end

-- ---------------------------------------------------------------------------
-- Quiver / ammo pouch capacity.
--
-- Only bags whose FAMILY matches the ammo kind count: an ammo pouch cannot hold
-- arrows, so filling "the quiver" with bullets in it is not a thing. Capacity is
-- slots x 200 (an ammo bag slot always stacks to 200), and `have` is the real
-- summed stack counts -- which makes partial stacks fall out of the arithmetic
-- for free.
--
-- Returns: capacity, have, slots, bags (list of bag indices)
-- ---------------------------------------------------------------------------
-- `perSlot` is the STACK SIZE OF THE AMMO ITSELF, not a hardcoded 200. Every
-- basic vendor projectile stacks to 200, but quest/engineering/special ammo
-- does not (Thorium Headed Arrow stacks to 200, but some special shot stacks to
-- 20), and assuming 200 there computed a capacity several times the real one --
-- which the "already full" arithmetic then read as a huge deficit, or, once
-- clamped by real room, as a tiny one. Ask the item and fall back to 200.
function AmmoBuy.QuiverSpace(kind, itemID, perSlot)
  perSlot = tonumber(perSlot) or 0
  if perSlot <= 0 then
    local facts = itemID and ItemFacts(itemID) or nil
    perSlot = (facts and facts.stack) or MAX_PER_BUY
  end
  if perSlot <= 1 then perSlot = MAX_PER_BUY end

  local family = FamilyForKind(kind)
  local slots, have, bags = 0, 0, {}
  for bag = 1, (NUM_BAG_SLOTS or 4) do
    local _, fam = BagInfo(bag)
    -- A quiver reports family 1 and an ammo pouch 2. Some clients report the
    -- family only through GetItemFamily on the equipped bag, so BagInfo falls
    -- back to that; without it every bag looked family-less and the addon saw
    -- NO quiver at all.
    if fam and HasBit(fam, family) then
      local n = HK.GetBagNumSlots(bag) or 0
      if n > 0 then
        slots = slots + n
        bags[#bags + 1] = bag
        for slot = 1, n do
          local id = HK.GetBagItemID(bag, slot)
          -- Only the ammo we are actually buying counts towards `have`: a quiver
          -- holding a DIFFERENT arrow type still occupies the slot, so its stack
          -- must NOT be treated as progress towards our target, but its slot is
          -- unusable for us. Model that by subtracting the occupied capacity.
          if id == itemID then
            have = have + (tonumber(HK.GetBagItemCount(bag, slot)) or 0)
          elseif id ~= nil then
            slots = slots - 1     -- foreign stack: that slot cannot take our ammo
          end
        end
      end
    end
  end
  return slots * perSlot, have, slots, bags
end

-- ---------------------------------------------------------------------------
-- Merchant scan: every projectile on offer, with everything needed to judge it.
-- ---------------------------------------------------------------------------
function AmmoBuy.ScanMerchant()
  local out = {}
  local n = tonumber(Call(GetMerchantNumItems)) or 0
  if n <= 0 then return out end
  local level = PlayerLevel()
  for i = 1, n do
    local link = Call(GetMerchantItemLink, i)
    local id = type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
    if id then
      local facts = ItemFacts(id)
      if facts and facts.classID == CLASS_PROJECTILE then
        local name, _, price, quantity, numAvailable, isPurchasable, isUsable, extendedCost =
          Call(GetMerchantItemInfo, i)
        -- extendedCost: bought with honor/tokens/currency, not gold. There is no
        -- safe way to price those, so they are never auto-bought.
        local hasExtended = extendedCost and extendedCost ~= 0 and extendedCost ~= false
        price = tonumber(price) or 0
        quantity = math.max(1, tonumber(quantity) or 1)
        local kind = KindOfSubclass(facts.subclassID)
        -- LEVEL SAFETY, two independent gates, because either can be wrong:
        --   * facts.reqLevel <= level -- the item's own requirement vs ours.
        --     Authoritative when GetItemInfo is warm, but reqLevel reads 0
        --     while the cache is cold, which would let anything through...
        --   * isUsable -- the client's own verdict for THIS character, which
        --     stays correct even then (it is what greys the vendor icon out).
        -- Both must agree, so ammo above the character's level is never bought.
        -- `nameKnown` additionally refuses to judge an item whose info has not
        -- loaded at all, rather than guessing from a reqLevel of 0.
        local nameKnown = type(name) == "string" and name ~= ""
        if kind and nameKnown and not hasExtended and price > 0
           and isPurchasable ~= false and isUsable ~= false
           and facts.reqLevel <= level then
          out[#out + 1] = {
            index = i, id = id, name = name or facts.name, kind = kind,
            price = price, perStack = quantity,
            unit = price / quantity,
            numAvailable = tonumber(numAvailable) or -1,
            reqLevel = facts.reqLevel, iLevel = facts.iLevel,
            texture = facts.texture, maxStack = facts.stack,
          }
        end
      end
    end
  end
  return out
end

-- Does this vendor deal in projectiles AT ALL?
--
-- Deliberately looser than ScanMerchant: this asks only "is ammo on the shelf",
-- ignoring level, price, stock and token cost. It decides whether the Refill
-- button is even relevant, and a general-goods vendor or a weaponsmith must
-- never show it. A vendor who DOES sell ammo you cannot use yet still gets the
-- button, so its tooltip can tell you why (e.g. "requires level 40") instead of
-- the button silently vanishing and leaving you guessing.
function AmmoBuy.SellsAmmo()
  local n = tonumber(Call(GetMerchantNumItems)) or 0
  for i = 1, n do
    local link = Call(GetMerchantItemLink, i)
    local id = type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
    if id then
      local facts = ItemFacts(id)
      if facts and facts.classID == CLASS_PROJECTILE
         and KindOfSubclass(facts.subclassID) then
        return true
      end
    end
  end
  return false
end

-- Rank: higher required level first (that IS the ammo tier in Classic), then
-- item level, then the cheaper one -- deterministic, so the same vendor always
-- produces the same plan.
local function Better(a, b)
  if a.reqLevel ~= b.reqLevel then return a.reqLevel > b.reqLevel end
  if a.iLevel ~= b.iLevel then return a.iLevel > b.iLevel end
  if a.unit ~= b.unit then return a.unit < b.unit end
  return a.index < b.index
end

-- ---------------------------------------------------------------------------
-- Choose WHAT to buy.
--   "equipped" : more of what is in the ammo slot; falls back to best usable
--   "best"     : the highest tier the vendor sells that the player may use
--   "capped"   : "best", but never above db.tierCap (stay on cheap ammo)
-- ---------------------------------------------------------------------------
-- Returns pick, nil  |  nil, reason
--
-- `wantReq` is the required level of the ammo currently in the slot -- the
-- yardstick for the "never downgrade" guard (see below).
function AmmoBuy.Choose(offers, wantKind, wantID, wantReq)
  local mode = db.tier or "equipped"
  local cap = tonumber(db.tierCap) or 60

  local function pool(kind)
    local p = {}
    for _, o in ipairs(offers) do
      if (kind == nil or o.kind == kind) and (mode ~= "capped" or o.reqLevel <= cap) then
        p[#p + 1] = o
      end
    end
    table.sort(p, Better)
    return p
  end

  -- "Never buy worse than what I already shoot."
  --
  -- Measured against the EQUIPPED ammo's required level, deliberately NOT
  -- against a hardcoded ladder of what the player's level theoretically allows.
  -- A level-60 hunter's best possible arrow is Wicked (55), but the overwhelming
  -- majority of vendors stop at Jagged (40) -- a ladder test would refuse almost
  -- everywhere and make the feature useless. The equipped tier is the yardstick
  -- the player actually cares about, and it self-calibrates: restocking the same
  -- tier is always allowed, upgrading is always allowed, and only a genuine
  -- downgrade is refused.
  --
  -- In "capped" mode the player has explicitly asked to stay on cheap ammo, so
  -- their cap outranks this guard and it is skipped.
  local function guard(pick)
    if not pick then return nil end
    if db.bestOnly == false or mode == "capped" then return pick end
    if not wantReq or pick.reqLevel >= wantReq then return pick end
    return nil, string.format(
      "this vendor only sells lower-tier %s (%s, level %d) than the level-%d ammo you use",
      pick.kind, pick.name, pick.reqLevel, wantReq)
  end

  if mode == "equipped" and wantID then
    for _, o in ipairs(offers) do
      if o.id == wantID then return o end     -- same item: never a downgrade
    end
    -- The vendor doesn't stock what we shoot; fall through to the best of the
    -- SAME kind so a bullet user is never handed arrows.
  end

  local same = pool(wantKind)
  if same[1] then return guard(same[1]) end
  if wantKind ~= nil then
    -- Nothing of our kind. Only guess the kind when the ammo slot was empty
    -- (wantKind nil) -- otherwise refuse rather than buy the wrong projectile.
    return nil
  end
  local any = pool(nil)
  return guard(any[1])
end

-- ---------------------------------------------------------------------------
-- The plan
-- ---------------------------------------------------------------------------
-- Returns plan, nil  |  nil, reason
function AmmoBuy.Plan()
  if not db or db.enabled == false then return nil, "auto-buy is off" end
  if HK.db.enabled == false then return nil, "HunterKit is off" end
  if not HK.isHunter then return nil, "not a hunter" end
  if (tonumber(Call(GetMerchantNumItems)) or 0) <= 0 then
    return nil, "no merchant open"
  end

  local wantID, wantKind, wantReq = AmmoBuy.EquippedAmmo()
  -- Ammo slot empty (just ran dry -- the very moment a refill matters most):
  -- ask the RANGED WEAPON what it fires rather than letting the vendor decide.
  -- Without this the fallback picked the "best" projectile of either kind on
  -- the shelf, which for a bow-user at a gun vendor meant a quiver's worth of
  -- bullets that can never be equipped.
  if not wantKind then wantKind = AmmoBuy.WeaponKind() end
  local offers = AmmoBuy.ScanMerchant()
  if #offers == 0 then return nil, "this vendor sells no usable ammo" end

  local pick, refused = AmmoBuy.Choose(offers, wantKind, wantID, wantReq)
  if not pick then
    -- `refused` is set when ammo WAS on offer but the never-downgrade guard
    -- rejected it: say that plainly rather than the misleading "sells no ammo".
    return nil, refused or ("this vendor sells no usable " .. (wantKind or "ammo"))
  end

  -- Size the quiver by the stack size of the ammo we are about to buy, taken
  -- from the item itself rather than assumed to be 200.
  local capacity, have, slots = AmmoBuy.QuiverSpace(pick.kind, pick.id, pick.maxStack)
  if slots <= 0 then
    return nil, (pick.kind == "arrows" and "no quiver equipped (or it is full of other items)")
                 or "no ammo pouch equipped (or it is full of other items)"
  end

  -- Fill target: "full" is 100% of the ammo bags, otherwise the percent slider.
  local pct = db.full and 100 or math.max(1, math.min(100, tonumber(db.percent) or 100))
  local target = math.floor(capacity * pct / 100)
  local need = target - have
  if need <= 0 then
    return nil, string.format("already at %d/%d %s (%d%% target)", have, capacity, pick.kind, pct)
  end

  -- The amount is the EXACT number of units missing -- no rounding to stacks.
  --
  -- BuyMerchantItem(index, quantity) takes a count of ITEMS, not of stacks
  -- (that changed in 4.1 and Classic Era runs the modern engine -- it is why
  -- the well-known `/run BuyMerchantItem(1,200)` macro yields 200 arrows from
  -- one call). So the vendor can be told to hand over precisely 750 arrows to
  -- top a quiver up, and there is no reason to leave a partial slot empty or to
  -- overshoot a fill percentage.
  --
  -- `perStack` is the merchant's BATCH size and only matters for pricing: the
  -- merchant's `price` is the price per batch, so the unit price is
  -- price / batch. Cost is charged per unit from there.
  local perStack = pick.perStack
  local unitPrice = pick.price / perStack
  local amount = math.min(need, capacity - have)   -- never exceed real room

  -- Limited stock. `numAvailable` counts purchasable BATCHES, so the unit
  -- ceiling is that times the batch size. (Ammo is virtually always unlimited
  -- (-1); when a capped vendor does under-deliver, the queue's stall detector
  -- catches it and stops cleanly.)
  if pick.numAvailable and pick.numAvailable >= 0 then
    amount = math.min(amount, pick.numAvailable * perStack)
    if amount <= 0 then return nil, "the vendor is out of stock" end
  end

  -- Money: keep the reserve, respect the per-visit cap. Because we buy by the
  -- unit, the budget no longer has to stretch to a whole stack -- it buys
  -- however many individual rounds it covers.
  local money = Money()
  local reserve = math.max(0, math.floor((tonumber(db.reserveGold) or 0) * 10000))
  local capSpend = math.max(0, math.floor((tonumber(db.maxSpendGold) or 0) * 10000))
  local budget = money - reserve
  if capSpend > 0 then budget = math.min(budget, capSpend) end
  if budget <= 0 then
    return nil, "gold reserve reached (" .. AmmoBuy.MoneyString(money) .. " on hand)"
  end
  local affordable = math.floor(budget / unitPrice)
  local trimmed = affordable < amount
  amount = math.min(amount, affordable)
  if amount <= 0 then
    return nil, string.format("not enough gold: %s each, budget is %s",
      AmmoBuy.MoneyString(math.ceil(unitPrice)), AmmoBuy.MoneyString(budget))
  end

  -- One BuyMerchantItem call may not exceed the item's max stack size, so a
  -- big refill is split into that many chunks: 2000 arrows is 10 calls of 200,
  -- not 2000 calls of one. Prefer the merchant's own answer, fall back to the
  -- item's stack size, then to the 200 every basic projectile uses.
  local perCall = tonumber(Call(GetMerchantItemMaxStack, pick.index)) or 0
  if perCall <= 1 then perCall = pick.maxStack or 0 end
  if perCall <= 1 then perCall = MAX_PER_BUY end
  perCall = math.min(perCall, MAX_PER_BUY)

  return {
    index    = pick.index,
    id       = pick.id,
    name     = pick.name,
    kind     = pick.kind,
    texture  = pick.texture,
    perStack = perStack,           -- the merchant's batch size (pricing unit)
    perCall  = perCall,            -- max units a single BuyMerchantItem may move
    calls    = math.ceil(amount / perCall),
    amount   = amount,             -- EXACT units to buy
    cost     = math.floor(amount * unitPrice + 0.5),
    have     = have,
    capacity = capacity,
    target   = target,
    percent  = pct,
    trimmed  = trimmed,      -- true when gold, not space, decided the amount
  }
end

function AmmoBuy.Describe(plan)
  return string.format("%d x %s for %s -- quiver %d/%d -> %d",
    plan.amount, plan.name, AmmoBuy.MoneyString(plan.cost),
    plan.have, plan.capacity, math.min(plan.capacity, plan.have + plan.amount))
end

-- ---------------------------------------------------------------------------
-- The purchase queue
--
-- One BuyMerchantItem per tick, never a loop: the server answers asynchronously
-- and the bag count has to move before the next buy is judged. If it does not
-- move MAX_STALLS times in a row (bags full, out of stock, out of money, a
-- silent client refusal), the run aborts and says so instead of spinning.
-- ---------------------------------------------------------------------------
local run = nil     -- { plan, done, stalls, lastCount, ticker }

function AmmoBuy.IsRunning() return run ~= nil end

-- Progress probe only. This is the ALL-BAGS count, not the quiver count, and
-- that is deliberate: the question here is "did the purchase land anywhere",
-- and ammo the client put in a normal bag (quiver full mid-run) still counts as
-- the server having answered. The quiver arithmetic lives in the planner.
local function BagCountOf(id)
  return tonumber(Call(GetItemCount, id)) or 0
end

local function Finish(msg)
  if not run then return end
  local plan, done = run.plan, run.done
  if run.ticker and run.ticker.Cancel then pcall(run.ticker.Cancel, run.ticker) end
  run = nil
  if msg then
    Say(msg)
  elseif plan then
    Say(string.format("bought %d %s.", done, plan.name))
  end
end

function AmmoBuy.Cancel(reason)
  if run then Finish(reason or "purchase cancelled.") end
end

local function Step()
  if not run then return end
  local plan = run.plan
  -- The merchant can close (or the player walk away) at any moment.
  if (tonumber(Call(GetMerchantNumItems)) or 0) <= 0 then
    Finish(string.format("vendor closed -- stopped after %d %s.", run.done, plan.kind))
    return
  end
  if run.done >= plan.amount then
    Finish(nil)
    return
  end

  -- Progress check on the PREVIOUS buy. `lastCount` is always the count taken
  -- immediately BEFORE that buy was issued, so "the count has not moved" really
  -- does mean the purchase never landed. (Sampling it after the call instead
  -- compared the post-buy count with itself and read every healthy purchase as
  -- a stall, which aborted the run after the very first stack.)
  if run.done > 0 then
    local now = BagCountOf(plan.id)
    -- Two independent progress signals, because the bag count alone is not
    -- trustworthy on a laggy realm: the gold LEAVES the player the instant the
    -- server accepts the purchase, while the item arriving in the bag (and the
    -- container cache updating) can trail by several ticks. Judging on the bag
    -- count alone read those frames as stalls and aborted a healthy refill part
    -- way through -- the "buys too little" report.
    local spent = run.lastMoney and Money() < run.lastMoney
    if now <= run.lastCount and not spent then
      run.stalls = run.stalls + 1
      if run.stalls >= MAX_STALLS then
        Finish(string.format("stopped after %d %s -- the purchase stopped going through (bags full, out of stock or out of gold).", run.done, plan.kind))
        return
      end
      return       -- give the server another tick before trying again
    end
    run.stalls = 0
  end

  -- Buy as many UNITS as one call is allowed to move (a full 200-arrow stack
  -- for basic ammo), not one item and not one stack-count. `run.done` counts
  -- units, so an 800-arrow refill is 4 calls, and a 137-arrow top-up is 1.
  local left = plan.amount - run.done
  local buyNow = math.min(plan.perCall, left)

  -- Re-check gold every step: the player may have spent elsewhere (repair,
  -- another addon) between ticks.
  local unitPrice = plan.cost / plan.amount
  if Money() < unitPrice * buyNow then
    Finish(string.format("stopped after %d -- out of gold.", run.done))
    return
  end

  -- Sample the count AND the purse BEFORE the call: both are the baseline the
  -- next tick judges progress against.
  run.lastCount = BagCountOf(plan.id)
  run.lastMoney = Money()
  if BuyMerchantItem then
    local ok = pcall(BuyMerchantItem, plan.index, buyNow)
    if not ok then
      Finish("the client refused the purchase -- stopped after " .. run.done .. ".")
      return
    end
  end
  run.done = run.done + buyNow
end

function AmmoBuy.Execute(plan)
  if run then return false, "a refill is already running" end
  if type(plan) ~= "table" then return false, "no plan" end
  run = { plan = plan, done = 0, stalls = 0, lastCount = BagCountOf(plan.id),
          lastMoney = Money() }
  Say("refilling: " .. AmmoBuy.Describe(plan))
  Step()                                   -- first buy immediately
  if run then run.ticker = HK.Ticker(BUY_INTERVAL, Step) end
  return true
end

-- ---------------------------------------------------------------------------
-- Confirmation popup (mode = "confirm")
-- ---------------------------------------------------------------------------
local POPUP = "HUNTERKIT_AMMO_BUY"
local function EnsurePopup()
  if type(StaticPopupDialogs) ~= "table" or StaticPopupDialogs[POPUP] then return end
  StaticPopupDialogs[POPUP] = {
    text = "%s",
    button1 = "Buy",
    button2 = "Cancel",
    OnAccept = function(self, data)
      if data then AmmoBuy.Execute(data) end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,      -- avoids tainting Blizzard's own popup slots
  }
end

-- ---------------------------------------------------------------------------
-- Entry point. `manual` = the user asked for it (button / slash), so a refusal
-- is reported out loud; automatic triggers stay quiet unless they can act.
-- ---------------------------------------------------------------------------
function AmmoBuy.Refill(manual)
  if run then
    if manual then Say("a refill is already running.") end
    return false
  end
  local plan, reason = AmmoBuy.Plan()
  if not plan then
    if manual then Say(reason or "nothing to buy.") end
    return false, reason
  end
  local mode = db.mode or "confirm"
  if manual or mode == "auto" then
    if plan.trimmed then
      Say("gold limit reached -- buying what the budget covers.")
    end
    return AmmoBuy.Execute(plan)
  end
  EnsurePopup()
  if StaticPopup_Show then
    local shown = StaticPopup_Show(POPUP, "Refill ammo?\n" .. AmmoBuy.Describe(plan), nil, plan)
    if shown then return true end
  end
  -- No popup available (stripped UI): fall back to telling the player.
  Say("ready to buy " .. AmmoBuy.Describe(plan) .. " -- /htk buy to confirm.")
  return false
end

-- ---------------------------------------------------------------------------
-- Merchant frame button ("Refill ammo"), always available in every mode so a
-- manual buy is one click away.
-- ---------------------------------------------------------------------------
local button
local function UpdateButton()
  if not button then return end
  if not db or db.enabled == false or db.showButton == false or not HK.isHunter then
    button:Hide()
    return
  end
  -- Only ever appear at a vendor that actually deals in arrows/bullets. On a
  -- food merchant or a weaponsmith the button is meaningless clutter sitting on
  -- top of Blizzard's frame, so it is hidden outright rather than shown
  -- disabled.
  if not AmmoBuy.SellsAmmo() then
    button:Hide()
    return
  end
  button:Show()
  local plan, reason = AmmoBuy.Plan()
  if plan then
    button:SetText("Refill ammo (" .. plan.amount .. ")")
    button.tip = AmmoBuy.Describe(plan)
  else
    button:SetText("Refill ammo")
    button.tip = reason or ""
  end
end
AmmoBuy.UpdateButton = UpdateButton

-- Anchor the button directly BENEATH the player-money display in the merchant
-- window's bottom-left, which is where the eye already is when deciding whether
-- to spend. MerchantMoneyFrame is the standard widget on every client that has
-- this window; MerchantMoneyInset is its container. Both are looked up at build
-- time (not cached at file scope) because the merchant UI is loaded on demand,
-- and we fall back to the frame's own bottom-left corner if neither exists so a
-- reskinning addon can never leave the button unanchored.
-- Anchor BOTH horizontal edges, never just one.
--
-- The previous version pinned only TOPLEFT to the money frame and kept a fixed
-- 130px width, so the button's right edge ran past the merchant window: the
-- money widget sits well into the frame, and 130px from there overflows it.
-- Pinning left AND right makes the width follow the anchor instead of fighting
-- it, so the button can never extend beyond the vendor frame at any UI scale or
-- with any reskinning addon.
local FRAME_PAD = 12       -- breathing room kept inside the merchant frame

-- Read an edge coordinate without ever throwing: a frame that has not been laid
-- out yet returns nil, and reskinning addons replace these widgets wholesale.
local function Edge(frame, which)
  if type(frame) ~= "table" or type(frame[which]) ~= "function" then return nil end
  return tonumber(Call(frame[which], frame))
end

local function AnchorButton()
  if not button then return end
  button:ClearAllPoints()
  local inset = _G["MerchantMoneyInset"]
  local money = _G["MerchantMoneyFrame"]
  if inset and inset.GetObjectType then
    -- Match the money inset's exact width: that block is already sized to sit
    -- neatly inside the frame's bottom-left, so the button lines up with it.
    button:SetPoint("TOPLEFT", inset, "BOTTOMLEFT", 0, -3)
    button:SetPoint("TOPRIGHT", inset, "BOTTOMRIGHT", 0, -3)
  elseif money and money.GetObjectType then
    button:SetPoint("TOPLEFT", money, "BOTTOMLEFT", 0, -6)
    button:SetPoint("TOPRIGHT", money, "BOTTOMRIGHT", 0, -6)
  else
    -- No money widget (heavily reskinned UI): inset from both edges of the
    -- merchant frame itself, which is still guaranteed to be inside it.
    button:SetPoint("BOTTOMLEFT", MerchantFrame, "BOTTOMLEFT", FRAME_PAD, 32)
    button:SetPoint("BOTTOMRIGHT", MerchantFrame, "BOTTOMRIGHT", -FRAME_PAD, 32)
    return
  end

  -- OVERFLOW CLAMP.
  --
  -- Anchoring to the money widget assumes that widget sits neatly inside the
  -- merchant frame. On several clients (and under any addon that rescales or
  -- re-parents the money block) it does NOT: MerchantMoneyInset is wider than
  -- the visible frame area, or is offset, and the button inherits that and
  -- pokes out past the frame's right edge -- exactly what was reported.
  --
  -- So after anchoring, MEASURE. If either edge has escaped the merchant
  -- frame, throw the anchor away and pin to the frame itself, which cannot
  -- overflow by construction. Measuring beats guessing, and a client that
  -- cannot answer (nil edges, pre-layout) simply keeps the money anchor.
  -- Measure the ANCHOR, not the button: the button's own rectangle is only
  -- valid after the next layout pass, whereas the widget we just pinned to has
  -- real coordinates right now -- and since both our edges are glued to it, its
  -- overflow IS our overflow.
  local anchor = (inset and inset.GetObjectType) and inset or money
  local fl, fr = Edge(MerchantFrame, "GetLeft"), Edge(MerchantFrame, "GetRight")
  local bl, br = Edge(anchor, "GetLeft"), Edge(anchor, "GetRight")
  -- A frame that has not been laid out yet reports zero width; there is nothing
  -- to measure against, so leave the anchor alone rather than "correcting" it
  -- against a degenerate rectangle.
  if fl and fr and bl and br and (fr - fl) > 1 and (br - bl) > 1 then
    if br > fr - FRAME_PAD * 0.5 or bl < fl + FRAME_PAD * 0.5 then
      button:ClearAllPoints()
      button:SetPoint("TOPLEFT", MerchantFrame, "BOTTOMLEFT", FRAME_PAD, 30)
      button:SetPoint("TOPRIGHT", MerchantFrame, "BOTTOMRIGHT", -FRAME_PAD, 30)
    end
  end
end

local function BuildButton()
  if button or not MerchantFrame then return end
  button = CreateFrame("Button", "HunterKitRefillAmmo", MerchantFrame, "UIPanelButtonTemplate")
  -- Height only: the width comes from anchoring both horizontal edges in
  -- AnchorButton(), so a fixed width can never push it past the frame.
  button:SetHeight(22)
  AnchorButton()
  button:SetText("Refill ammo")
  button:SetScript("OnClick", function() AmmoBuy.Refill(true) end)
  button:SetScript("OnEnter", function(self)
    if not GameTooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("HunterKit — refill ammo")
    if self.tip and self.tip ~= "" then
      GameTooltip:AddLine(self.tip, 0.9, 0.9, 0.9, true)
    end
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  button:Hide()
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------
-- Retry the automatic refill until the client can actually answer.
--
-- THE AUTO-FILL BUG: this used to be a single shot 0.3 s after MERCHANT_SHOW.
-- At that moment GetItemInfo is frequently still cold for items the player has
-- not seen this session, so ItemFacts returns nil, ScanMerchant finds zero
-- projectiles, and the refill gives up with "this vendor sells no usable ammo"
-- -- silently, because an automatic trigger must not spam refusals. Clicking
-- the button a second later worked because the cache had filled in by then,
-- which is exactly the "button fine, auto broken" report.
--
-- The fix is to keep looking while the answer can still change. GET_ITEM_INFO_
-- RECEIVED would be the event-driven way, but it does not fire for items
-- already cached, so a short poll is both simpler and strictly more reliable.
local AUTO_TRIES    = 12     -- ~6 s of attempts
local AUTO_INTERVAL = 0.5
local autoToken = 0          -- invalidates in-flight retries when the vendor closes

-- Is this refusal one the client might still take back?
--
-- Everything here means "I have not been told yet", not "no": the merchant list
-- arrives a frame or two after MERCHANT_SHOW, and GetItemInfo is cold for any
-- item the player has not seen this session. A real answer -- already full, no
-- quiver, too poor, wrong tier -- is final and must NOT be retried.
local function Retryable(reason)
  if reason == nil then return true end
  reason = tostring(reason)
  return reason:find("no usable", 1, true) ~= nil
      or reason:find("no merchant open", 1, true) ~= nil
end

local function TryAutoRefill(token, tries)
  if token ~= autoToken then return end                 -- a newer visit superseded us
  if run then return end                                 -- already buying

  -- The merchant's item list is populated asynchronously, so at the first tick
  -- it is routinely still empty. Bailing out here (as this used to) abandoned
  -- the whole automatic refill on any vendor that was a few frames slow, while
  -- clicking the button later worked -- half of the "auto-fill doesn't" report.
  -- Fall through to the retry instead.
  local plan, reason
  if (tonumber(Call(GetMerchantNumItems)) or 0) > 0 then
    plan, reason = AmmoBuy.Plan()
  end
  if plan then
    AmmoBuy.Refill(false)
    UpdateButton()
    return
  end

  local retryable = Retryable(reason)
  if retryable and tries < AUTO_TRIES and C_Timer and C_Timer.After then
    C_Timer.After(AUTO_INTERVAL, function() TryAutoRefill(token, tries + 1) end)
  else
    UpdateButton()
  end
end

local function OnMerchantShow()
  BuildButton()
  -- Re-anchor every time: Blizzard's merchant UI can load after our first
  -- build, and reskinning addons move the money frame between openings.
  AnchorButton()
  UpdateButton()
  if not db or db.enabled == false or not HK.isHunter then return end
  local mode = db.mode or "confirm"
  if mode == "manual" then return end
  autoToken = autoToken + 1
  local token = autoToken
  if C_Timer and C_Timer.After then
    C_Timer.After(0.3, function() TryAutoRefill(token, 1) end)
  else
    AmmoBuy.Refill(false)
  end
end

function AmmoBuy.PrintDiag()
  local wantID, wantKind = AmmoBuy.EquippedAmmo()
  Say("ammo auto-buy diagnostics:")
  print("  equipped: " .. tostring(wantID) .. " (" .. tostring(wantKind) .. ")")
  print("  ranged weapon fires: " .. tostring(AmmoBuy.WeaponKind()))
  if wantKind then
    local cap, have, slots, bags = AmmoBuy.QuiverSpace(wantKind, wantID)
    print(string.format("  ammo bags: %d slots, %d/%d %s (bags: %s)", slots, have, cap,
      wantKind, #bags > 0 and table.concat(bags, ",") or "NONE FOUND"))
  end
  -- Per-bag family report: the fastest way to see why a quiver was missed.
  for bag = 1, (NUM_BAG_SLOTS or 4) do
    local free, fam = BagInfo(bag)
    local n = HK.GetBagNumSlots(bag) or 0
    if n > 0 then
      print(string.format("    bag %d: %d slots, family %s%s", bag, n, tostring(fam),
        (fam == FAMILY_QUIVER and " (quiver)") or (fam == FAMILY_POUCH and " (pouch)") or ""))
    end
  end
  print("  money: " .. AmmoBuy.MoneyString(Money()))
  local offers = AmmoBuy.ScanMerchant()
  print("  vendor projectiles: " .. #offers)
  for _, o in ipairs(offers) do
    print(string.format("    [%d] %s  req%d  %s/%d", o.index, o.name, o.reqLevel,
      AmmoBuy.MoneyString(o.price), o.perStack))
  end
  local plan, reason = AmmoBuy.Plan()
  print("  plan: " .. (plan and AmmoBuy.Describe(plan) or ("none -- " .. tostring(reason))))
end

function AmmoBuy.RescanSettings()
  db = HK.db.ammobuy
  UpdateButton()
end

function AmmoBuy.Init()
  db = HK.db.ammobuy
  if not HK.isHunter then return end      -- structural gate: no hunter, no feature

  HK.On("MERCHANT_SHOW", OnMerchantShow)
  HK.On("MERCHANT_CLOSED", function()
    autoToken = autoToken + 1     -- cancel any in-flight auto-refill retries
    AmmoBuy.Cancel(run and string.format("vendor closed -- stopped after %d.", run.done) or nil)
    if button then button:Hide() end
  end)
  HK.On("BAG_UPDATE_DELAYED", function()
    if button and button:IsShown() then UpdateButton() end
  end)
end

HK.RegisterModule("AmmoBuy", { Init = AmmoBuy.Init })
