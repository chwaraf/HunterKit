--[[==============================================================================
 HunterKit — Pet Mend Marker (F6)
 A Mend Pet icon that floats above your pet's head, nameplate style. It is a
 readout, not a button: it lights up green and solid when the pet is inside Mend
 Pet range, so you know at a glance — without reading a bar — whether a Mend will
 land. When the pet drops to the low-HP threshold (30% by default) it grows,
 pulses and throws an expanding red ring, because that is the moment you actually
 need it. The box colour always carries the range answer (green = in range, red =
 not) so the two signals never fight.

 It never casts anything. Like every other HunterKit module this is display only.

 ANCHORING — read this before changing it.
 The client publishes a unit's on-screen position ONLY through its name plate
 (C_NamePlate.GetNamePlateForUnit). There is no world-to-screen API, and
 UnitPosition() explicitly does not work on pets, so an addon cannot project the
 pet into screen space by itself. So:
   * if a pet plate exists -> anchor over the pet's head (true world anchoring).
     We try three ways to find one: the direct API, the plate the client handed
     us in NAME_PLATE_UNIT_ADDED, and a scan of C_NamePlate.GetNamePlates().
   * if the player has nameplates off, no plate exists. `forcePlate` (opt-in)
     turns on the minimum nameplate CVars this client still has, ladder-style,
     and checks after each step whether a pet plate actually appeared — then
     restores the old values when switched off or at logout, so nothing is
     written to the player's config permanently.
   * otherwise we fall back to the pet unit frame and draw a nameplate-style
     widget (icon + pet name + HP bar) so it still reads like a plate.
==============================================================================]]
local _, HK = ...

local MendMark = {}
HK.MendMark = MendMark

local db
local frame, icon, border, ring, label
local plate, plateBg, plateName, plateBar, plateBarTex
local ticker
local phase = 0
local urgentNow = false
local lastAnchorMode = nil
local eventPlate = nil

-- Mend Pet (136) resolves to the localized name of the rank you actually know.
local MEND_PET_SPELL_ID = 136
local MEND_ICON_FALLBACK = "Interface\\Icons\\Ability_Hunter_MendPet"
local RING_TEX = "Interface\\Cooldown\\star4"

-- Ring/border colours: green = a Mend will land, red = the pet is out of range.
local C_INRANGE = { 0.2, 1, 0.2 }
local C_FAR     = { 1, 0.15, 0.15 }

-- The nameplate CVars, least invasive first. `forcePlate` walks this ladder one
-- step at a time and only escalates if the previous step produced no pet plate.
-- GetCVar returns nil for a CVar the client doesn't have (Midnight dropped the
-- friendly ones), so a missing entry is skipped instead of erroring.
local PLATE_CVAR_LADDER = {
  "nameplateShowFriendlyPets",
  "nameplateShowFriends",
  "nameplateShowAll",
}
local plateStep = 0          -- how many ladder rungs we've enabled
local plateWait = 0          -- ticks since the last step (give the client a beat)

-- Cached spell name. Cleared on SPELLS_CHANGED so learning Mend Pet later is
-- picked up without a /reload.
local mendSpell = nil

-- Forward declarations: BuildFrame wires up OnUpdateAnchor, and the anchor code
-- is defined further down this chunk.
local OnUpdateAnchor

-- ---------------------------------------------------------------------------
-- Small probes (all pcall-guarded: a missing API must never break the marker)
-- ---------------------------------------------------------------------------
local function MendSpellName()
  if mendSpell then return mendSpell end
  local name
  if C_Spell and C_Spell.GetSpellInfo then
    local ok, info = pcall(C_Spell.GetSpellInfo, MEND_PET_SPELL_ID)
    if ok and type(info) == "table" and info.name then name = info.name end
  end
  if not name and GetSpellInfo then
    local ok, n = pcall(GetSpellInfo, MEND_PET_SPELL_ID)
    if ok and type(n) == "string" then name = n end
  end
  if type(name) == "string" and name ~= "" then mendSpell = name end
  return mendSpell
end

-- The icon the spell book uses for Mend Pet on this client (icon *paths* were
-- replaced by FileDataIDs in the Midnight UI merge, so ask the client first and
-- only fall back to the literal path).
local function MendIconTexture()
  if C_Spell and C_Spell.GetSpellTexture then
    local ok, t = pcall(C_Spell.GetSpellTexture, MEND_PET_SPELL_ID)
    if ok and t then return t end
  end
  if GetSpellTexture then
    local ok, t = pcall(GetSpellTexture, MEND_PET_SPELL_ID)
    if ok and t then return t end
  end
  return MEND_ICON_FALLBACK
end

-- true = Mend Pet would hit the pet, false = out of range, nil = no answer
-- (spell not learned, no pet, or the client refused). "No answer" hides the
-- marker rather than guessing.
local function MendInRange()
  local spell = MendSpellName()
  if not spell then return nil end
  local ok, v = pcall(IsSpellInRange, spell, "pet")
  if not ok then return nil end
  if v == 1 or v == true then return true end
  if v == 0 or v == false then return false end
  return nil
end

local function PetHPPercent()
  local h = UnitHealth and UnitHealth("pet")
  local m = UnitHealthMax and UnitHealthMax("pet")
  if type(h) ~= "number" or type(m) ~= "number" or m <= 0 then return nil end
  return (h / m) * 100
end

local function PetIsOut()
  if not UnitExists then return false end
  local alive = UnitExists("pet")
  if alive ~= true and alive ~= 1 then return false end
  if UnitIsDeadOrGhost and UnitIsDeadOrGhost("pet") then return false end
  return true
end

local function InFight()
  local a, b
  if UnitAffectingCombat then
    local ok, v = pcall(UnitAffectingCombat, "player"); a = ok and v
    local ok2, v2 = pcall(UnitAffectingCombat, "pet");  b = ok2 and v2
  end
  return a == true or b == true
end

-- ---------------------------------------------------------------------------
-- Finding the pet's name plate (three independent ways, first hit wins)
-- ---------------------------------------------------------------------------
local function PlateUsable(p)
  if type(p) ~= "table" then return false end
  -- Plate frames are recycled between units, so only a SHOWN plate is really on
  -- screen for our pet right now.
  local okShown, shown = pcall(p.IsShown, p)
  if okShown and shown == false then return false end
  return true
end

-- 1) the direct API. `true` asks for friendly plates that are otherwise
--    "forbidden" (instances).
local function PlateForUnit()
  if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then return nil end
  local ok, p = pcall(C_NamePlate.GetNamePlateForUnit, "pet", true)
  if ok and PlateUsable(p) then return p end
  return nil
end

-- 2) the plate the client handed us in NAME_PLATE_UNIT_ADDED. Some clients only
--    report the unit token through that event, not through the query.
local function PlateFromEvent()
  if PlateUsable(eventPlate) then return eventPlate end
  return nil
end

-- 3) scan the visible plates for one whose unit is the pet.
local function PlateFromScan()
  if not (C_NamePlate and C_NamePlate.GetNamePlates) then return nil end
  local ok, plates = pcall(C_NamePlate.GetNamePlates)
  if not ok or type(plates) ~= "table" then return nil end
  for _, p in ipairs(plates) do
    if type(p) == "table" then
      local tok = p.namePlateUnitToken
      if tok == nil and type(p.UnitFrame) == "table" then tok = p.UnitFrame.unit end
      if tok == "pet" and PlateUsable(p) then return p end
    end
  end
  return nil
end

local function PetPlate()
  return PlateForUnit() or PlateFromEvent() or PlateFromScan()
end

-- ---------------------------------------------------------------------------
-- forcePlate — opt-in CVar ladder that makes a pet plate exist
-- ---------------------------------------------------------------------------
-- CVars are locked while in combat, so callers must retry after
-- PLAYER_REGEN_ENABLED.
local function PlateCVarsLocked()
  return InCombatLockdown and InCombatLockdown() == true
end

local function SaveCVar(name)
  local cur = GetCVar(name)
  if cur == nil then return false end                 -- not on this client
  if cur == "1" or cur == 1 then return false end     -- already on
  if db.plateCVars[name] == nil then db.plateCVars[name] = cur end
  return true
end

-- Enable one more rung of the ladder. Returns true if it changed something.
local function ApplyPlateStep()
  if not db.forcePlate then return false end
  if not (SetCVar and GetCVar) then return false end
  if PlateCVarsLocked() then return false end
  local name = PLATE_CVAR_LADDER[plateStep + 1]
  if not name then return false end
  local had = SaveCVar(name)
  pcall(SetCVar, name, "1")
  plateStep = plateStep + 1
  plateWait = 0
  HK.Dbg("mend forcePlate step", tostring(plateStep), name, "saved=" .. tostring(had))
  return true
end

-- Put the CVars back the way we found them. Values are persisted in the db so a
-- /reload with the option off can still undo them.
local function RestorePlateCVars()
  if not (SetCVar and GetCVar) then return end
  if type(db) ~= "table" or type(db.plateCVars) ~= "table" then return end
  if PlateCVarsLocked() then return end
  local n = 0
  for name, val in pairs(db.plateCVars or {}) do
    -- Only forget a saved value once it's actually back; a blocked SetCVar keeps
    -- the original around for the next attempt.
    if pcall(SetCVar, name, val) then
      db.plateCVars[name] = nil
      n = n + 1
    end
  end
  plateStep = 0
  if n > 0 then HK.Dbg("mend forcePlate restored", tostring(n), "cvars") end
end

-- Called every tick: escalate the ladder while no pet plate has shown up.
local function MaintainPlateCVars()
  if not db.forcePlate then
    if next(db.plateCVars or {}) then RestorePlateCVars() end
    plateStep = 0
    return
  end
  if PlateCVarsLocked() then return end
  if plateStep >= #PLATE_CVAR_LADDER then return end
  if PetPlate() then return end          -- already have one: stop escalating
  if not PetIsOut() then return end      -- no pet out: no plate to wait for
  plateWait = plateWait + 1
  if plateWait >= 10 then ApplyPlateStep() end   -- ~1s per rung at a 0.10s tick
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------
local function BuildFrame()
  -- Parented to UIParent (never to the plate: plate frames are recycled and are
  -- forbidden in instances), anchored to whatever anchor we resolve each tick.
  frame = CreateFrame("Frame", "HunterKitMendMarker", UIParent)
  frame:SetFrameStrata("HIGH")
  frame:SetFrameLevel(250)
  frame:EnableMouse(false)      -- never intercept clicks (world clicks matter!)
  frame:SetClampedToScreen(false) -- it must follow the pet off-screen, not clamp
  frame:SetSize(db.size, db.size)

  icon = frame:CreateTexture(nil, "ARTWORK")
  icon:SetAllPoints(frame)
  icon:SetTexture(MendIconTexture())
  icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

  -- Expanding ring shown while the pet is under the low-HP threshold.
  ring = frame:CreateTexture(nil, "BACKGROUND")
  ring:SetTexture(RING_TEX)
  ring:SetBlendMode("ADD")
  ring:SetVertexColor(1, 0.35, 0.2, 1)
  ring:SetPoint("CENTER", frame, "CENTER", 0, 0)
  ring:SetSize(db.size, db.size)
  ring:Hide()

  -- Coloured box around the icon: green = in range, red = too far.
  border = HK.CreateBorder(frame, 2)

  label = frame:CreateFontString(nil, "OVERLAY")
  label:SetPoint("BOTTOM", frame, "TOP", 0, 2)
  -- Font first, text later: SetText on a FontString with no font throws
  -- "FontString:SetText(): Font not set" on the live client.
  if STANDARD_TEXT_FONT then
    label:SetFont(STANDARD_TEXT_FONT, 13, "OUTLINE")
  else
    label:SetFontObject(GameFontNormalSmall)
  end
  label:SetJustifyH("CENTER")
  label:SetShadowColor(0, 0, 0, 1)
  label:SetShadowOffset(1, -1)
  label:Hide()

  BuildMendPlate()

  frame:SetScript("OnUpdate", OnUpdateAnchor)
  frame:SetShown(false)
end

-- The nameplate-style widget drawn under the icon when we're NOT anchored to a
-- real plate: pet name + a thin HP bar, so the fallback reads like a plate
-- instead of a bare icon. Hidden whenever a real pet plate is carrying us,
-- because that plate already shows the name and health.
function BuildMendPlate()
  plate = CreateFrame("Frame", "HunterKitMendPlate", frame)
  plate:SetPoint("TOP", frame, "BOTTOM", 0, -3)
  plate:SetSize(96, 22)
  plate:EnableMouse(false)

  plateBg = plate:CreateTexture(nil, "BACKGROUND")
  plateBg:SetAllPoints(plate)
  plateBg:SetTexture("Interface\\Buttons\\WHITE8x8")
  plateBg:SetVertexColor(0, 0, 0, 0.55)

  plateName = plate:CreateFontString(nil, "OVERLAY")
  plateName:SetPoint("TOP", plate, "TOP", 0, -2)
  if STANDARD_TEXT_FONT then
    plateName:SetFont(STANDARD_TEXT_FONT, 11, "OUTLINE")
  else
    plateName:SetFontObject(GameFontNormalSmall)
  end
  plateName:SetJustifyH("CENTER")
  plateName:SetTextColor(0.85, 0.95, 1)
  plateName:SetText("")

  plateBar = plate:CreateTexture(nil, "ARTWORK")
  plateBar:SetPoint("BOTTOMLEFT", plate, "BOTTOMLEFT", 3, 3)
  plateBar:SetHeight(5)
  plateBar:SetWidth(90)
  plateBar:SetTexture("Interface\\Buttons\\WHITE8x8")
  plateBar:SetVertexColor(0.15, 0.15, 0.15, 0.9)

  plateBarTex = plate:CreateTexture(nil, "OVERLAY")
  plateBarTex:SetPoint("LEFT", plateBar, "LEFT", 0, 0)
  plateBarTex:SetHeight(5)
  plateBarTex:SetWidth(90)
  plateBarTex:SetTexture("Interface\\Buttons\\WHITE8x8")
  plateBarTex:SetVertexColor(0.2, 1, 0.2, 1)

  plate:Hide()
end

-- ---------------------------------------------------------------------------
-- Anchor
-- ---------------------------------------------------------------------------
-- Returns the mode actually used ("plate" / "petframe" / "none"). Re-resolved
-- every tick: the pet moves, and plate frames come and go.
local function ApplyAnchor()
  local mode = db.anchor or "auto"
  local ox, oy = db.offsetX or 0, db.offsetY or 0

  if mode ~= "petframe" then
    local p = PetPlate()
    if p then
      -- Anchoring to a forbidden (instance) plate can throw; fall through to the
      -- pet frame instead of erroring out.
      local ok = pcall(function()
        frame:ClearAllPoints()
        frame:SetPoint("BOTTOM", p, "TOP", ox, oy)
      end)
      if ok then
        lastAnchorMode = "plate"
        return lastAnchorMode
      end
    elseif mode == "plate" then
      -- "Plate only" was asked for and the client exposes none: stay hidden
      -- rather than silently moving the marker somewhere else.
      lastAnchorMode = "none"
      return lastAnchorMode
    end
  end

  -- UI fallback: the pet unit frame. Deliberately used even when the player has
  -- hidden it in Edit Mode (a hidden frame keeps its layout, so the anchor still
  -- resolves) — otherwise the marker would disappear for exactly the players the
  -- README tells to hide their pet frame.
  local pf = _G["PetFrame"]
  if pf then
    frame:ClearAllPoints()
    frame:SetPoint("BOTTOM", pf, "TOP", ox, oy)
    lastAnchorMode = "petframe"
    return lastAnchorMode
  end

  lastAnchorMode = "none"
  return lastAnchorMode
end

-- ---------------------------------------------------------------------------
-- Per-frame animation (only while the pet is under the low-HP threshold)
-- ---------------------------------------------------------------------------
OnUpdateAnchor = function(self, dt)
  if not self:IsShown() then return end
  if not urgentNow or not db.urgentPulse then
    ring:Hide()
    self:SetScale(1)
    if label then label:SetAlpha(1) end
    return
  end

  phase = phase + (dt or 0)
  local cycle = db.urgentCycle or 0.55
  local p = (phase % cycle) / cycle
  local wave = math.abs(math.sin(p * math.pi))   -- 0..1..0

  self:SetScale(1 + 0.14 * wave)
  ring:SetShown(true)
  local w = icon:GetWidth() or db.size
  local h = icon:GetHeight() or db.size
  ring:SetSize(w * (1.5 + 0.9 * p), h * (1.5 + 0.9 * p))
  ring:SetAlpha((1 - p) * 0.85)
  if label and label:IsShown() then label:SetAlpha(0.65 + 0.35 * wave) end
end

-- ---------------------------------------------------------------------------
-- Look
-- ---------------------------------------------------------------------------
local function ApplyLook(inRange, urgent)
  local dim = (inRange == false) and db.dimWhenFar
  local size = db.size

  frame:SetSize(size, size)
  icon:SetSize(size, size)
  icon:SetDesaturated(dim and true or false)
  frame:SetAlpha(dim and 0.45 or 1)

  local c = inRange and C_INRANGE or C_FAR
  border:SetVertexColor(c[1], c[2], c[3], 1)

  if db.showLabel then
    if urgent then
      label:SetText("MEND!")
      label:SetTextColor(1, 0.45, 0.1)
      label:SetShown(true)
    elseif inRange == false then
      label:SetText("TOO FAR")
      label:SetTextColor(0.75, 0.75, 0.75)
      label:SetShown(true)
    else
      label:Hide()
    end
  else
    label:Hide()
  end
end

-- Nameplate-style widget: name + HP bar, only while we're not on a real plate.
local function ApplyPlate(hp)
  if not plate then return end
  if lastAnchorMode == "plate" or not db.plateStyle then
    plate:Hide()
    return
  end
  local w = math.max(72, (db.size or 34) * 2.6)
  plate:SetSize(w, 22)
  plateBar:SetWidth(w - 6)
  plateBarTex:SetWidth(math.max(0, (w - 6) * ((hp or 100) / 100)))
  -- green -> yellow -> red as the pet loses health
  local frac = math.max(0, math.min(1, (hp or 100) / 100))
  local r = frac < 0.5 and 1 or (1 - frac) * 2
  local g = frac < 0.5 and frac * 2 or 1
  plateBarTex:SetVertexColor(r, g, 0.15, 1)
  plateName:SetText(UnitName and UnitName("pet") or "Pet")
  plate:SetAlpha(frame:GetAlpha() or 1)
  plate:SetShown(true)
end

-- ---------------------------------------------------------------------------
-- Driver
-- ---------------------------------------------------------------------------
-- The single hide path: also unwinds the urgent animation, so a marker hidden
-- mid-pulse can't come back next time still scaled up with a ring on it.
local function Hide()
  urgentNow = false
  phase = 0
  frame:SetScale(1)
  if ring then ring:Hide() end
  if plate then plate:Hide() end
  frame:SetShown(false)
end

local function Update()
  if not frame then return end
  db = HK.db.mend
  if HK.db.enabled == false or not db.enabled or not HK.isHunter then
    RestorePlateCVars()
    Hide()
    return
  end

  -- Edit mode (/htk unlock) always shows the marker — even out of combat with a
  -- healthy pet — so the size/height sliders can actually be tuned. Same rule the
  -- other modules follow.
  local editing = HK.Editing()

  if not PetIsOut() and not editing then
    Hide()
    return
  end

  -- Nothing to indicate if Mend Pet isn't learned (MendInRange() == nil).
  local inRange = MendInRange()
  if inRange == nil then
    inRange = true          -- edit-mode preview needs a state to draw
    if not editing then
      Hide()
      return
    end
  end

  local hp = PetHPPercent()
  urgentNow = (hp ~= nil) and (hp <= (db.hpThreshold or 30))

  -- "Only in combat" is the default; a hurt pet is always worth showing.
  if db.combatOnly and not InFight() and not urgentNow and not editing then
    Hide()
    return
  end

  ApplyLook(inRange, urgentNow)
  local mode = ApplyAnchor()
  if mode == "none" then
    Hide()
    return
  end
  ApplyPlate(hp)
  frame:SetShown(true)
end

function MendMark.Update()
  Update()
end

-- Called by the ticker: cheap, and keeps the marker glued to a moving pet.
local function Tick()
  if not frame then return end
  MaintainPlateCVars()
  Update()
end

function MendMark.RescanSettings()
  db = HK.db.mend
  if not frame then return end
  icon:SetTexture(MendIconTexture())
  if not db.forcePlate then RestorePlateCVars() end
  plateStep = 0
  plateWait = 0
  Update()
end

function MendMark.IsShown()
  return frame ~= nil and frame:IsShown() == true
end

function MendMark.AnchorMode()
  return lastAnchorMode
end

-- Diagnostics for /htk selfcheck and /htk mend: the raw values behind the icon.
function MendMark.Diagnostic()
  local hp = PetHPPercent()
  return string.format(
    "enabled=%s pet=%s spell=%s inRange=%s hp=%s%% threshold=%s%% anchor=%s(mode=%s) plate=%s shown=%s",
    tostring(db and db.enabled), tostring(PetIsOut()), tostring(mendSpell or MendSpellName()),
    tostring(MendInRange()),
    hp and string.format("%.0f", hp) or "?",
    tostring(db and db.hpThreshold),
    tostring(db and db.anchor), tostring(lastAnchorMode),
    tostring(PetPlate() ~= nil), tostring(MendMark.IsShown()))
end

-- The nameplate CVars that decide whether the client publishes a pet plate at
-- all, plus what forcePlate changed. Printed by /htk mend so "why isn't it over
-- the head?" is answerable without guesswork.
function MendMark.PlateCVars()
  if not GetCVar then return "(GetCVar unavailable)" end
  local names = {
    "nameplateShowFriends", "nameplateShowAll", "nameplateShowEnemies",
    "nameplateShowFriendlyPets", "nameplateShowOnlyNames", "nameplateMaxDistance",
  }
  local out = {}
  for _, n in ipairs(names) do
    local ok, v = pcall(GetCVar, n)
    if ok and v ~= nil then
      local mark = (db and db.plateCVars and db.plateCVars[n] ~= nil) and "*" or ""
      out[#out + 1] = n .. "=" .. tostring(v) .. mark
    end
  end
  return table.concat(out, "  ")
end

function MendMark.PrintDiag()
  print("|cff39ff14HunterKit — Pet Mend Marker|r")
  print("  " .. MendMark.Diagnostic())
  print("  cvars (* = changed by HunterKit, restored on disable/logout): " .. MendMark.PlateCVars())
  if lastAnchorMode == "plate" then
    print("  Anchored over the pet's head via its name plate.")
  else
    print("  No pet name plate from the client, so the marker is anchored to the pet unit frame.")
    print("  For true over-the-head anchoring either enable friendly nameplates,")
    print("  or tick Options → Pet Mend Marker → 'Force pet name plate' (HunterKit turns on the")
    print("  minimum nameplate CVars and puts them back when you untick it).")
  end
end

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------
function MendMark.Init()
  db = HK.db.mend
  if not HK.isHunter then return end   -- structural gate
  if type(db.plateCVars) ~= "table" then db.plateCVars = {} end

  BuildFrame()

  HK.On("UNIT_HEALTH", function(u) if u == "pet" then Update() end end)
  HK.On("UNIT_MAXHEALTH", function(u) if u == "pet" then Update() end end)
  HK.On("UNIT_PET", function(u) if u == "player" then Update() end end)
  HK.On("PLAYER_REGEN_ENABLED", function()
    -- CVars are locked in combat: (re)apply or restore once we're out.
    if db.forcePlate then plateWait = 10 else RestorePlateCVars() end
    Update()
  end)
  HK.On("PLAYER_REGEN_DISABLED", Update)
  HK.On("NAME_PLATE_UNIT_ADDED", function(unit, p)
    if unit == "pet" then eventPlate = p end
    Update()
  end)
  HK.On("NAME_PLATE_UNIT_REMOVED", function(unit)
    if unit == "pet" then eventPlate = nil end
    Update()
  end)
  HK.On("PLAYER_ENTERING_WORLD", Update)
  -- Restore before SavedVariables are written, so a forced CVar never ends up
  -- persisted in the player's config if the addon is switched off.
  -- Session-scoped by design: put the CVars back before SavedVariables are
  -- written, so a forced plate never ends up persisted in the player's config.
  -- Next login the ladder simply re-applies (Init + the ticker). If combat blocks
  -- the restore, the originals stay in db.plateCVars and are restored later.
  HK.On("PLAYER_LOGOUT", RestorePlateCVars)
  HK.On("SPELLS_CHANGED", function()
    mendSpell = nil                    -- re-resolve (may have just been trained)
    Update()
  end)

  if not db.forcePlate then RestorePlateCVars() end

  ticker = HK.Ticker(0.10, Tick)
  Update()
end

HK.RegisterModule("MendMark", { Init = MendMark.Init })
