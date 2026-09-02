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
function Frame:GetAlpha() return self.alpha end
function Frame:SetScale(s) self.scale = s end
function Frame:GetScale() return self.scale end
function Frame:SetFrameStrata(s) self.strata = s end
function Frame:SetFrameLevel(l) self.level = l end
function Frame:EnableMouse(v) self.mouse = v end
function Frame:SetClampedToScreen(v) self.clamped = v end
function Frame:SetMovable(v) self.movable = v end
function Frame:RegisterForDrag() end
function Frame:RegisterEvent(e) self.events[e] = true end
function Frame:UnregisterEvent(e) self.events[e] = nil end
function Frame:SetScript(h, fn) self.scripts[h] = fn end
function Frame:GetScript(h) return self.scripts[h] end
function Frame:SetAttribute(k, v) self.attrs[k] = v end
function Frame:GetAttribute(k) return self.attrs[k] end
function Frame:GetName() return self.name end
function Frame:GetParent() return self.parent end
function Frame:IsForbidden() return false end
function Frame:SetHitRectInsets() end
function Frame:SetBackdrop() end
function Frame:SetBackdropColor() end
function Frame:SetBackdropBorderColor() end
function Frame:SetTexture(t) self.texture = t; self:Record("SetTexture", t) end
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
function Frame:SetShadowColor() end
function Frame:SetShadowOffset() end

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
  return newFrame(kind, name, parent, template)
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
  petPlateNeedsFriends = false,  -- models a client where the pet CVar alone is not enough
  combatLockdown = false,
  cvars = {
    nameplateShowFriends = "0",
    nameplateShowAll = "0",
    nameplateShowEnemies = "1",
    nameplateShowFriendlyPets = "0",
    nameplateShowOnlyNames = "0",
    nameplateMaxDistance = "60",
  },
}

function UnitClass() return "Testhunter", (HKTest.state.isHunter and "HUNTER" or "WARRIOR") end
function UnitExists(u) return (u == "pet" and HKTest.state.pet) and true or false end
function UnitIsDeadOrGhost(u) return (u == "pet" and HKTest.state.petDead) and true or false end
function UnitHealth(u) return (u == "pet") and HKTest.state.petHP or 1 end
function UnitHealthMax(u) return (u == "pet") and HKTest.state.petHPMax or 1 end
function UnitAffectingCombat(u)
  if u == "pet" then return HKTest.state.petCombat and true or false end
  return HKTest.state.playerCombat and true or false
end
function IsSpellInRange(spell, unit)
  if spell == nil or unit ~= "pet" then return nil end
  if HKTest.state.spellName == nil then return nil end
  return HKTest.state.spellInRange
end
function GetSpellInfo(id)
  if id == 136 then return HKTest.state.spellName end
  return nil
end
function GetSpellTexture(id)
  if id == 136 then return HKTest.state.spellTexture end
  return nil
end
function GetPetHappiness() return 3, 100, 0 end
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

C_Timer = {
  NewTicker = function(interval, fn)
    local t = { interval = interval, fn = fn, cancelled = false }
    HKTest.tickers[#HKTest.tickers + 1] = t
    t.Tick = function(self) if not self.cancelled then self.fn() end end
    return t
  end,
  After = function(d, fn) fn() end,
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
