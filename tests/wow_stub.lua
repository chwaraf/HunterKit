--[[==============================================================================
 HunterKit — test harness: minimal World of Warcraft API stub
 Enough of the client API for Core.lua and MendMark.lua to load and run outside
 the game. Run with tests/run_tests.py (see README → Development). Nothing here is
 loaded by the addon; HunterKit.toc does not list this file.
==============================================================================]]

local frames = {}          -- every frame the code creates, by object and by name
HKTest = { frames = frames, prints = {}, tickers = {}, state = {} }

-- WoW's client is Lua 5.1, where `unpack` is a global. A modern interpreter used
-- to run this harness (5.2+) moved it to table.unpack; provide it either way.
if not unpack and table.unpack then unpack = table.unpack end

-- ---------------------------------------------------------------------------
-- Frame / texture / fontstring stubs
-- ---------------------------------------------------------------------------
local Frame = {}
Frame.__index = Frame

local function newFrame(kind, name, parent, template)
  local f = setmetatable({
    kind = kind, name = name, parent = parent, template = template,
    shown = true, alpha = 1, scale = 1, width = 0, height = 0,
    points = {}, scripts = {}, textures = {}, fontstrings = {},
    events = {}, attrs = {}, calls = {},
  }, Frame)
  frames[#frames + 1] = f
  if name then _G[name] = f end
  return f
end

function Frame:Record(op, ...)
  local c = self.calls
  c[#c + 1] = { op = op, args = { ... } }
end

function Frame:SetPoint(a, b, c, d, e) self.points[#self.points + 1] = { a, b, c, d, e } end
function Frame:ClearAllPoints() self.points = {} end
function Frame:GetPoint(i) return self.points[i] and unpack(self.points[i]) end
function Frame:SetSize(w, h) self.width, self.height = w, h end
function Frame:SetWidth(w) self.width = w end
function Frame:SetHeight(h) self.height = h end
function Frame:GetWidth() return self.width end
function Frame:GetHeight() return self.height end
function Frame:GetCenter() return (self.width or 0) / 2, (self.height or 0) / 2 end
function Frame:GetLeft() return 0 end
function Frame:GetBottom() return 0 end
function Frame:GetRect() return 0, 0, self.width, self.height end
function Frame:SetShown(v) self.shown = v and true or false end
function Frame:Show() self.shown = true end
function Frame:Hide() self.shown = false end
function Frame:IsShown() return self.shown end
function Frame:IsVisible() return self.shown end
function Frame:SetAlpha(a) self.alpha = a end
function Frame:SetRotation(r) self.rotation = r end
function Frame:GetNormalTexture()
  self.normalTex = self.normalTex or newFrame("Texture", nil, self)
  return self.normalTex
end
function Frame:SetNormalTexture(t) self.normalTexture = t end
function Frame:GetHighlightTexture() return self:GetNormalTexture() end
function Frame:GetPushedTexture() return self:GetNormalTexture() end
function Frame:GetScrollRange() return 0 end
function Frame:GetRotation() return self.rotation or 0 end
function Frame:SetBlendMode(m) self.blendMode = m end
function Frame:GetAlpha() return self.alpha end
function Frame:SetScale(s) self.scale = s end
function Frame:GetScale() return self.scale end
function Frame:SetFrameStrata(s) self.strata = s end
function Frame:SetFrameLevel(l) self.level = l end
function Frame:EnableMouse(v) self.mouse = v end
function Frame:SetClampedToScreen(v)
  -- The client refuses (and taints) when the frame is anchored to a protected
  -- region such as a name plate. `restricted` models that.
  if self.restricted then
    error("Action[ClampedToScreen] failed because[Can't clamp restricted regions]")
  end
  self.clamped = v
end
function Frame:SetMovable(v) self.movable = v end
function Frame:RegisterForDrag() end
function Frame:RegisterEvent(e) self.events[e] = true end
function Frame:UnregisterEvent(e) self.events[e] = nil end
function Frame:SetScript(h, fn) self.scripts[h] = fn end
function Frame:GetScript(h) return self.scripts[h] end
function Frame:SetAttribute(k, v) self.attrs[k] = v end
function Frame:GetAttribute(k) return self.attrs[k] end
function Frame:ClearAttribute(k) self.attrs[k] = nil end
function Frame:GetFrameLevel() return self.frameLevel or 1 end
function Frame:GetFrameStrata() return self.frameStrata or "MEDIUM" end
function Frame:IsMouseEnabled() return self.mouse and true or false end
function Frame:RegisterForClicks(...) self.clicks = { ... } end
function Frame:UnregisterAllClicks() self.clicks = {} end
function Frame:GetName() return self.name end
function Frame:GetParent() return self.parent end
function Frame:IsForbidden() return false end
function Frame:SetHitRectInsets() end
function Frame:SetBackdrop() end
function Frame:SetBackdropColor() end
function Frame:SetBackdropBorderColor() end
function Frame:SetTexture(t) self.texture = t; self:Record("SetTexture", t) end
function Frame:SetDesaturated(d) self.desaturated = d end
function Frame:SetTexCoord(...) self:Record("SetTexCoord", ...) end
function Frame:SetBlendMode(m) self.blend = m end
function Frame:SetVertexColor(r, g, b, a)
  self.color = { r, g, b, a }
  self:Record("SetVertexColor", r, g, b, a)
end
function Frame:SetDesaturated(v) self.desaturated = v and true or false; self:Record("SetDesaturated", self.desaturated) end
function Frame:GetDesaturated() return self.desaturated end
function Frame:SetAllPoints() end
function Frame:SetFont(f, s, o) self.font = f; self.fontSize = s; self.fontOutline = o end
function Frame:SetFontObject(o) self.fontObject = o end
function Frame:SetText(t) self.text = t; self:Record("SetText", t) end
function Frame:GetText() return self.text end
function Frame:SetTextColor(r, g, b, a) self.textColor = { r, g, b, a } end
function Frame:SetJustifyH(j) self.justifyH = j end
function Frame:SetJustifyV(j) self.justifyV = j end
function Frame:SetWordWrap(v) self.wordWrap = v and true or false end
function Frame:SetNonSpaceWrap(v) self.nonSpaceWrap = v and true or false end
function Frame:SetMaxLines(n) self.maxLines = n end
function Frame:SetSpacing(n) self.spacing = n end
function Frame:GetStringWidth() return self.width or 0 end
function Frame:SetShadowColor() end
function Frame:SetShadowOffset() end

-- Widget methods the options window uses. Deliberately explicit: a missing
-- method must still surface as an error, not be silently swallowed.
function Frame:SetClipsChildren(v) self.clipsChildren = v end
function Frame:SetScrollChild(c) self.scrollChild = c end
function Frame:GetScrollChild() return self.scrollChild end
function Frame:SetVerticalScroll(v) self.vscroll = v end
function Frame:GetVerticalScroll() return self.vscroll or 0 end
function Frame:EnableMouseWheel(v) self.mouseWheel = v end
function Frame:SetMinMaxValues(a, b) self.minValue, self.maxValue = a, b end
function Frame:GetMinMaxValues() return self.minValue, self.maxValue end
function Frame:SetValueStep(v) self.valueStep = v end
function Frame:SetObeyStepOnDrag(v) self.obeyStep = v end
function Frame:SetValue(v)
  self.value = v
  if self.scripts and self.scripts["OnValueChanged"] then self.scripts["OnValueChanged"](self, v) end
end
function Frame:GetValue() return self.value end
function Frame:GetTop() return (self.height or 0) end
function Frame:SetChecked(v) self.checked = v and true or false end
function Frame:GetChecked() return self.checked end
function Frame:SetNormalTexture() end
function Frame:SetPushedTexture() end
function Frame:SetHighlightTexture() end
function Frame:SetCheckedTexture() end
function Frame:SetDisabledCheckedTexture() end
function Frame:SetHitRectInsets() end
function Frame:RegisterForClicks() end
function Frame:SetFormattedText(fmt, ...) self.text = string.format(fmt, ...) end
function Frame:GetEffectiveScale() return 1 end

function Frame:CreateTexture(name, layer)
  local t = newFrame("Texture", name, self)
  t.layer = layer
  self.textures[#self.textures + 1] = t
  return t
end

function Frame:CreateFontString(name, layer)
  local t = newFrame("FontString", name, self)
  t.layer = layer
  self.fontstrings[#self.fontstrings + 1] = t
  return t
end

function CreateFrame(kind, name, parent, template)
  local f = newFrame(kind, name, parent, template)
  -- OptionsSliderTemplate ships three fontstrings; the real client creates them
  -- with the frame, and their clipping/overlap is exactly what the tests assert on.
  -- A scanning tooltip (FeedPet reads food tooltips through one). No lines means
  -- "no food found", which is the honest answer for an empty stub bag.
  if kind == "GameTooltip" then
    f.tipLines = {}
    function f:SetOwner() end
    function f:ClearLines() self.tipLines = {} end
    function f:NumLines() return #self.tipLines end
    function f:SetBagItem() end
    function f:SetHyperlink() end
    function f:SetInventoryItem() end
    function f:SetSpellByID() end
  end
  if template == "OptionsSliderTemplate" and name then
    for _, suf in ipairs({ "Text", "Low", "High" }) do
      local fs = newFrame("FontString", name .. suf, f)
      fs.shown = true
    end
    _G[name .. "Text"]:SetPoint("BOTTOM", f, "TOP", 0, 0)
    _G[name .. "Low"]:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, 0)
    _G[name .. "High"]:SetPoint("TOPRIGHT", f, "BOTTOMRIGHT", 0, 0)
  end
  return f
end

-- ---------------------------------------------------------------------------
-- Client globals the two modules under test touch
-- ---------------------------------------------------------------------------
UIParent = newFrame("Frame", "UIParent", nil)
UIParent.width, UIParent.height = 1920, 1080
function UIParent:GetEffectiveScale() return 1 end

-- The default-UI pet unit frame the marker falls back to when the client exposes
-- no pet name plate. Hidden here on purpose: Edit Mode lets players hide it, and
-- the marker must still anchor to its layout.
PetFrame = newFrame("Frame", "PetFrame", UIParent)
PetFrame:SetSize(120, 40)
PetFrame:Hide()

-- Tooltip stub that records every line so tests can assert on wrapping.
GameTooltip = newFrame("Frame", "GameTooltip", UIParent)
GameTooltip.lines = {}
function GameTooltip:SetOwner() end
function GameTooltip:SetText(t) self.lines[#self.lines + 1] = { text = t } end
function GameTooltip:AddLine(t, r, g, b, wrap)
  self.lines[#self.lines + 1] = { text = t, wrap = wrap }
end
function GameTooltip:Show() end
function GameTooltip:Hide() self.lines = {} end

Minimap = newFrame("Frame", "Minimap", UIParent)
UISpecialFrames = {}
function tinsert(t, v) t[#t + 1] = v end

STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
SlashCmdList = {}

-- Live state the tests poke at.
HKTest.state = {
  isHunter = true,
  pet = true,
  petDead = false,
  petHP = 500,
  petHPMax = 1000,
  playerCombat = true,
  petCombat = true,
  spellInRange = 1,          -- 1 = in range, 0 = out of range, nil = no answer
  spellName = "Mend Pet",
  spellTexture = "Interface\\Icons\\Ability_Hunter_MendPet",
  plate = nil,
  scanPlate = nil,       -- only discoverable via C_NamePlate.GetNamePlates()
  target = false,          -- a target exists (sniper mark tests turn this on)
  targetDead = false,
  targetAttackable = true,
  targetSpellInRange = 1,  -- 1 = Auto Shot in range, 0/nil = not
  targetTooClose = false,  -- inside the melee deadzone
  petPlateNeedsFriends = false,  -- models a client where the pet CVar alone is not enough
  combatLockdown = false,
  cvars = {
    nameplateShowFriends = "0",
    nameplateShowAll = "0",
    nameplateShowEnemies = "1",
    nameplateShowFriendlyPets = "0",
    nameplateShowFriendlyMinions = "0",
    nameplateShowOnlyNames = "0",
    nameplateMaxDistance = "60",
  },
}

function PetHasActionBar() return true end
function CheckInteractDistance(unit, dist)
  if unit == "target" then return HKTest.state.targetTooClose and true or false end
  return false
end
function GetPetActionInfo() return nil end
function UnitIsDead(u)
  if u == "target" then return HKTest.state.targetDead and true or false end
  return false
end
function UnitLevel() return HKTest.state.level or 60 end
function UnitCanAttack(a, b)
  if b == "target" then return HKTest.state.targetAttackable ~= false end
  return false
end
function GetInventorySlotInfo(n) return n == "AmmoSlot" and 100 or nil end
function GetInventorySlotLink(unit, slot)
  if slot == 100 then return HKTest.state.ammoLink end
  return nil
end
function GetInventoryItemID(unit, slot)
  if slot == 100 then return HKTest.state.ammoID or nil end
  return nil
end
function GetInventoryItemCount(unit, slot)
  if slot == 100 then return HKTest.state.ammoEquipped or 0 end
  return 0
end
function GetItemCount(id) return (HKTest.state.items or {})[id] or 0 end
function GetItemInfo(id)
  local it = (HKTest.state.itemInfo or {})[id]
  if not it then return nil end
  return it.name, nil, it.quality or 1, it.iLevel or 1, nil, nil,
         it.subclass, nil, nil, it.texture
end
function GetContainerNumSlots(bag) return (HKTest.state.bags or {})[bag] or 0 end
function GetContainerItemLink() return nil end
function GetContainerItemInfo(bag, slot)
  local it = ((HKTest.state.bagItems or {})[bag] or {})[slot]
  if not it then return nil end
  return nil, it.count or 1, nil, nil, nil, nil, it.link, nil, nil, it.id
end

-- The MODERN container API, shaped exactly like the live client's struct
-- (stackCount / itemID / hyperlink -- NOT itemCount). Core prefers this path
-- when C_Container exists, so tests must run the SAME code path as 1.15.x;
-- without it the itemCount/stackCount field-name bug was invisible here.
C_Container = {
  GetContainerNumSlots = function(bag) return (HKTest.state.bags or {})[bag] or 0 end,
  GetContainerItemInfo = function(bag, slot)
    local it = ((HKTest.state.bagItems or {})[bag] or {})[slot]
    if not it then return nil end
    return { stackCount = it.count or 1, itemID = it.id, hyperlink = it.link }
  end,
  UseContainerItem = function() end,
}
function GetContainerItemID(bag, slot)
  local it = ((HKTest.state.bagItems or {})[bag] or {})[slot]
  return it and it.id or nil
end
function UseContainerItem() end
-- ---------------------------------------------------------------------------
-- Merchant / money / bag-family stubs (ammo auto-buy)
-- ---------------------------------------------------------------------------
function GetMoney() return HKTest.state.money or 0 end

-- HKTest.state.bagFamily[bag] = bit field (1 = quiver, 2 = ammo pouch)
local function bagFree(bag)
  local n = (HKTest.state.bags or {})[bag] or 0
  local used = 0
  for _ in pairs(((HKTest.state.bagItems or {})[bag] or {})) do used = used + 1 end
  return n - used, ((HKTest.state.bagFamily or {})[bag] or 0)
end
function GetContainerNumFreeSlots(bag) return bagFree(bag) end
C_Container.GetContainerNumFreeSlots = function(bag) return bagFree(bag) end

-- HKTest.state.merchant = { { id=, price=, quantity=, numAvailable=,
--                            isPurchasable=, isUsable=, extendedCost= }, ... }
function GetMerchantNumItems() return #(HKTest.state.merchant or {}) end
function GetMerchantItemLink(i)
  local m = (HKTest.state.merchant or {})[i]
  return m and ("|Hitem:" .. m.id .. "::::::::60:::|h[x]|h") or nil
end
function GetMerchantItemInfo(i)
  local m = (HKTest.state.merchant or {})[i]
  if not m then return nil end
  local info = (HKTest.state.itemInfo or {})[m.id] or {}
  return info.name, info.texture, m.price or 0, m.quantity or 1,
         m.numAvailable == nil and -1 or m.numAvailable,
         m.isPurchasable ~= false, m.isUsable ~= false, m.extendedCost
end
-- Models the server: the purchase costs money and lands in the ammo bags.
HKTest.buys = {}
function BuyMerchantItem(index, qty)
  qty = qty or 1
  local m = (HKTest.state.merchant or {})[index]
  if not m then error("BuyMerchantItem: no such merchant index " .. tostring(index)) end
  HKTest.buys[#HKTest.buys + 1] = { index = index, qty = qty, id = m.id }
  if HKTest.state.refuseBuys then return end
  local units = qty * (m.quantity or 1)
  HKTest.state.money = (HKTest.state.money or 0) - qty * (m.price or 0)
  HKTest.state.items = HKTest.state.items or {}
  HKTest.state.items[m.id] = (HKTest.state.items[m.id] or 0) + units
end

StaticPopupDialogs = {}
HKTest.popups = {}
function StaticPopup_Show(which, text, _, data)
  HKTest.popups[#HKTest.popups + 1] = { which = which, text = text, data = data }
  return { which = which, data = data }
end
function StaticPopup_Hide() end

-- The merchant window the Refill button parents itself to.
MerchantFrame = newFrame("Frame", "MerchantFrame", UIParent)

function GetCursorPosition() return HKTest.cursorX or 0, HKTest.cursorY or 0 end
function PlaySoundFile(f) HKTest.soundsPlayed[#HKTest.soundsPlayed + 1] = f end
function MuteSoundFile(id) HKTest.mutedSounds[#HKTest.mutedSounds + 1] = id end

function UnitClass() return "Testhunter", (HKTest.state.isHunter and "HUNTER" or "WARRIOR") end
function UnitExists(u)
  if u == "pet" then return HKTest.state.pet and true or false end
  if u == "target" then return HKTest.state.target and true or false end
  return false
end
function UnitIsDeadOrGhost(u) return (u == "pet" and HKTest.state.petDead) and true or false end
function UnitHealth(u) return (u == "pet") and HKTest.state.petHP or 1 end
function UnitHealthMax(u) return (u == "pet") and HKTest.state.petHPMax or 1 end
function UnitAffectingCombat(u)
  if u == "pet" then return HKTest.state.petCombat and true or false end
  return HKTest.state.playerCombat and true or false
end
function IsSpellInRange(spell, unit)
  if spell == nil then return nil end
  if unit == "target" then return HKTest.state.targetSpellInRange end
  if HKTest.state.spellName == nil then return nil end
  return HKTest.state.spellInRange
end
function GetSpellInfo(id)
  if id == 136 then return HKTest.state.spellName end
  if id == 75 then return "Auto Shot" end
  return nil
end
function GetSpellTexture(id)
  if id == 136 then return HKTest.state.spellTexture end
  return nil
end
function GetPetHappiness() return HKTest.state.happiness or 3, 100, 0 end
function GetSpellTexture(id)
  if id == 6991 then return "Interface\\Icons\\ability_hunter_beasttraining" end
  return nil
end
function UnitName(u) return (u == "pet") and "Fang" or "Testhunter" end
function UnitPosition(u)
  if u ~= "pet" then return 100, 200, 0, 1 end
  if HKTest.state.petPosition == false then return nil end   -- client refuses pets
  return 101.5, 202.5, 0.5, 1
end
function GetPlayerFacing() return 1.25 end
function GetScreenHeight() return 1080 end

-- The pre-C_NamePlate layout: NamePlateN children of WorldFrame.
WorldFrame = newFrame("Frame", "WorldFrame", UIParent)
function WorldFrame:GetChildren()
  local out = {}
  for _, f in ipairs(HKTest.frames) do
    if f.name and f.name:match("^NamePlate%d+$") then out[#out + 1] = f end
  end
  return table.unpack and table.unpack(out) or unpack(out)
end
function InCombatLockdown() return HKTest.state.combatLockdown == true end
function GetCVar(n)
  local c = HKTest.state.cvars
  if not c then return nil end
  return c[n]                       -- nil models a CVar this client doesn't have
end
function SetCVar(n, v)
  local c = HKTest.state.cvars
  if not c or c[n] == nil then error("SetCVar: unknown cvar " .. tostring(n)) end
  c[n] = tostring(v)
  return true
end
function GetTime() return HKTest.state.now or 0 end

C_Spell = {
  GetSpellInfo = function(id)
    if id == 136 and HKTest.state.spellName then return { name = HKTest.state.spellName } end
    return nil
  end,
  GetSpellTexture = function(id)
    if id == 136 then return HKTest.state.spellTexture end
    return nil
  end,
}

-- Models the client: a pet plate exists if one was handed to us explicitly, or
-- once the pet-nameplate CVars allow friendly pet plates.
AutoPetPlate = newFrame("Frame", "AutoPetNamePlate", UIParent)
AutoPetPlate:SetSize(100, 40)
AutoPetPlate.namePlateUnitToken = "pet"

C_NamePlate = {
  GetNamePlateForUnit = function(unit, includeForbidden)
    if unit ~= "pet" then return nil end
    if HKTest.state.plate then return HKTest.state.plate end
    local c = HKTest.state.cvars
    if c.nameplateShowFriendlyPets == "1"
       and (not HKTest.state.petPlateNeedsFriends or c.nameplateShowFriends == "1") then
      return AutoPetPlate
    end
    return nil
  end,
  GetNamePlates = function()
    local out = {}
    if HKTest.state.plate then out[#out + 1] = HKTest.state.plate end
    if HKTest.state.scanPlate then out[#out + 1] = HKTest.state.scanPlate end
    return out
  end,
}

-- Models C_Console.GetAllCommands(): one entry per CVar the client has.
C_Console = {
  GetAllCommands = function()
    local out = {}
    for n in pairs(HKTest.state.cvars) do
      out[#out + 1] = { command = n, help = "" }
    end
    return out
  end,
}

C_Timer = {
  NewTicker = function(interval, fn)
    local t = { interval = interval, fn = fn, cancelled = false }
    HKTest.tickers[#HKTest.tickers + 1] = t
    t.Tick = function(self) if not self.cancelled then self.fn() end end
    return t
  end,
  -- Queued, not run inline: the real client fires these later, and a delayed
  -- callback that runs immediately hides ordering bugs from the tests.
  After = function(d, fn)
    HKTest.delayed[#HKTest.delayed + 1] = { delay = d, fn = fn }
  end,
}

local realPrint = print
-- The addon writes to the chat frame, which is `print` in-game. Capture it so
-- tests can assert on what the user would see; HKTest.say bypasses the capture
-- and is what the test's own reporting uses.
HKTest.say = realPrint
function print(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
  local line = table.concat(parts, "\t")
  HKTest.prints[#HKTest.prints + 1] = line
  if HKTest.echo then realPrint(line) end
end

-- ---------------------------------------------------------------------------
-- Loader: run the addon's files the way the client does (varargs = name, ns)
-- ---------------------------------------------------------------------------
-- Globals that exist before the addon loads. A `local` that was never declared
-- (the bug that produced "attempt to call a nil value (global 'Update')") shows
-- up here as an accidental global assignment or read, so tests can fail on it
-- instead of the client doing it mid-raid.
-- Recorded for assertions.
HKTest.soundsPlayed = {}
HKTest.mutedSounds = {}

-- C_Timer.After callbacks, which tests fire by hand.
HKTest.delayed = {}

--- Run (and clear) every queued C_Timer.After callback.
function HKTest.RunDelayed()
  local q = HKTest.delayed
  HKTest.delayed = {}
  for _, e in ipairs(q) do e.fn() end
  return #q
end

HKTest.baselineGlobals = {}
for k in pairs(_G) do HKTest.baselineGlobals[k] = true end

function HKTest.StrayGlobals()
  local out = {}
  for k in pairs(_G) do
    if not HKTest.baselineGlobals[k] then out[#out + 1] = k end
  end
  table.sort(out)
  return out
end

function HKTest.LoadAddon(...)
  HK = {}
  local paths = { ... }
  for _, path in ipairs(paths) do
    local chunk, err = loadfile(path)
    if not chunk then error("load failed: " .. path .. ": " .. tostring(err)) end
    local ok, lerr = pcall(chunk, "HunterKit", HK)
    if not ok then error("chunk failed: " .. path .. ": " .. tostring(lerr)) end
  end
  return HK
end

-- Fire a registered bus event exactly like the client would.
function HKTest.Fire(event, ...)
  local fn = HK.bus and HK.bus.handlers and HK.bus.handlers[event]
  if fn then return fn(...) end
  return nil
end

function HKTest.MarkerFrame()
  return _G["HunterKitMendMarker"]
end

function HKTest.PlateWidget()
  return _G["HunterKitMendPlate"]
end

-- Run n marker ticks (the 0.10s ticker callback).
function HKTest.TickMarker(n)
  for _, t in ipairs(HKTest.tickers) do
    if t.interval and math.abs(t.interval - 0.10) < 0.0001 then
      for _ = 1, (n or 1) do t:Tick() end
      return true
    end
  end
  return false
end

-- Run N animation frames of the marker's OnUpdate at dt seconds each.
function HKTest.Animate(n, dt)
  local f = HKTest.MarkerFrame()
  local up = f and f.scripts and f.scripts["OnUpdate"]
  if not up then return false end
  for _ = 1, n do up(f, dt or 0.016) end
  return true
end
