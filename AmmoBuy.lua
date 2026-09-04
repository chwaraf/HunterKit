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
local MAX_STALLS   = 3      -- consecutive no-progress buys before we give up

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
local function BagInfo(bag)
  local free, family
  if C_Container and C_Container.GetContainerNumFreeSlots then
    free, family = Call(C_Container.GetContainerNumFreeSlots, bag)
  end
  if family == nil and GetContainerNumFreeSlots then
    free, family = Call(GetContainerNumFreeSlots, bag)
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
  return id, facts and KindOfSubclass(facts.subclassID) or nil
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
function AmmoBuy.QuiverSpace(kind, itemID)
  local family = FamilyForKind(kind)
  local slots, have, bags = 0, 0, {}
  for bag = 1, 4 do
    local _, fam = BagInfo(bag)
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
  return slots * MAX_PER_BUY, have, slots, bags
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
        if kind and not hasExtended and price > 0
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
function AmmoBuy.Choose(offers, wantKind, wantID)
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

  if mode == "equipped" and wantID then
    for _, o in ipairs(offers) do
      if o.id == wantID then return o end
    end
    -- The vendor doesn't stock what we shoot; fall through to the best of the
    -- SAME kind so a bullet user is never handed arrows.
  end

  local same = pool(wantKind)
  if same[1] then return same[1] end
  if wantKind ~= nil then
    -- Nothing of our kind. Only guess the kind when the ammo slot was empty
    -- (wantKind nil) -- otherwise refuse rather than buy the wrong projectile.
    return nil
  end
  local any = pool(nil)
  return any[1]
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

  local wantID, wantKind = AmmoBuy.EquippedAmmo()
  local offers = AmmoBuy.ScanMerchant()
  if #offers == 0 then return nil, "this vendor sells no usable ammo" end

  local pick = AmmoBuy.Choose(offers, wantKind, wantID)
  if not pick then
    return nil, "this vendor sells no usable " .. (wantKind or "ammo")
  end

  local capacity, have, slots = AmmoBuy.QuiverSpace(pick.kind, pick.id)
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
    if now <= run.lastCount then
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

  -- Sample the count BEFORE the call: that is the baseline the next tick judges.
  run.lastCount = BagCountOf(plan.id)
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
  run = { plan = plan, done = 0, stalls = 0, lastCount = BagCountOf(plan.id) }
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
local function AnchorButton()
  if not button then return end
  button:ClearAllPoints()
  local money = _G["MerchantMoneyFrame"]
  local inset = _G["MerchantMoneyInset"]
  if money and money.GetObjectType then
    button:SetPoint("TOPLEFT", money, "BOTTOMLEFT", 0, -6)
  elseif inset and inset.GetObjectType then
    button:SetPoint("TOPLEFT", inset, "BOTTOMLEFT", 4, -4)
  else
    button:SetPoint("BOTTOMLEFT", MerchantFrame, "BOTTOMLEFT", 22, 32)
  end
end

local function BuildButton()
  if button or not MerchantFrame then return end
  button = CreateFrame("Button", "HunterKitRefillAmmo", MerchantFrame, "UIPanelButtonTemplate")
  button:SetSize(130, 22)
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
local function OnMerchantShow()
  BuildButton()
  -- Re-anchor every time: Blizzard's merchant UI can load after our first
  -- build, and reskinning addons move the money frame between openings.
  AnchorButton()
  UpdateButton()
  if not db or db.enabled == false or not HK.isHunter then return end
  local mode = db.mode or "confirm"
  if mode == "manual" then return end
  -- One tick late: at MERCHANT_SHOW the merchant list and the item cache are
  -- still filling in, so an immediate scan can see zero items (or unnamed ones)
  -- and wrongly report "this vendor sells no usable ammo".
  if C_Timer and C_Timer.After then
    C_Timer.After(0.3, function()
      if (tonumber(Call(GetMerchantNumItems)) or 0) > 0 then
        AmmoBuy.Refill(false)
        UpdateButton()
      end
    end)
  else
    AmmoBuy.Refill(false)
  end
end

function AmmoBuy.PrintDiag()
  local wantID, wantKind = AmmoBuy.EquippedAmmo()
  Say("ammo auto-buy diagnostics:")
  print("  equipped: " .. tostring(wantID) .. " (" .. tostring(wantKind) .. ")")
  if wantKind then
    local cap, have, slots = AmmoBuy.QuiverSpace(wantKind, wantID)
    print(string.format("  ammo bags: %d slots, %d/%d %s", slots, have, cap, wantKind))
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
    AmmoBuy.Cancel(run and string.format("vendor closed -- stopped after %d.", run.done) or nil)
    if button then button:Hide() end
  end)
  HK.On("BAG_UPDATE_DELAYED", function()
    if button and button:IsShown() then UpdateButton() end
  end)
end

HK.RegisterModule("AmmoBuy", { Init = AmmoBuy.Init })
