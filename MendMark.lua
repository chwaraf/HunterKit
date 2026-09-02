--[[==============================================================================
 HunterKit — Pet Mend Marker (F6)
 A Mend Pet icon that floats above your pet's head. It is a readout, not a
 button: it lights up green and solid when the pet is inside Mend Pet range, so
 you know at a glance — without reading a bar — whether a Mend will land. When
 the pet drops to the low-HP threshold (30% by default) it grows, pulses and
 throws an expanding red ring, because that is the moment you actually need it.
 The box colour always carries the range answer (green = in range, red = not) so
 the two signals never fight.

 It never casts anything. Like every other HunterKit module this is display only.

 Anchoring (see README → "Pet Mend Marker"): the client only exposes a unit's
 world position while that unit has a name plate, so we anchor to the pet's plate
 when one exists and fall back to the pet unit frame otherwise. There is no
 world-to-screen API in Classic Era — no addon can place a frame at a world
 position the client doesn't publish.
==============================================================================]]
local _, HK = ...

local MendMark = {}
HK.MendMark = MendMark

local db
local frame, icon, border, ring, label
local ticker
local phase = 0
local urgentNow = false
local lastAnchorMode = nil

-- Mend Pet (136) resolves to the localized name of the rank you actually know.
local MEND_PET_SPELL_ID = 136
local MEND_ICON_FALLBACK = "Interface\\Icons\\Ability_Hunter_MendPet"
local RING_TEX = "Interface\\Cooldown\\star4"

-- Ring/border colours: green = a Mend will land, red = the pet is out of range.
local C_INRANGE = { 0.2, 1, 0.2 }
local C_FAR     = { 1, 0.15, 0.15 }

-- Cached spell name. Cleared on SPELLS_CHANGED so learning Mend Pet later is
-- picked up without a /reload.
local mendSpell = nil

-- Forward declaration: BuildFrame wires this up as the frame's OnUpdate, but its
-- body is defined further down this chunk.
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

-- The pet's name plate, if the client currently has one for it. `true` asks for
-- friendly plates that are otherwise "forbidden" (instances). Plate frames are
-- recycled between units, so only a SHOWN plate is really our pet's.
local function PetPlate()
  if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then return nil end
  local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, "pet", true)
  if not ok or type(plate) ~= "table" then return nil end
  local okShown, shown = pcall(plate.IsShown, plate)
  if okShown and shown == false then return nil end
  return plate
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

  frame:SetScript("OnUpdate", OnUpdateAnchor)
  frame:SetShown(false)
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
    local plate = PetPlate()
    if plate then
      -- Anchoring to a forbidden (instance) plate can throw; fall through to the
      -- pet frame instead of erroring out.
      local ok = pcall(function()
        frame:ClearAllPoints()
        frame:SetPoint("BOTTOM", plate, "TOP", ox, oy)
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
  frame:SetShown(false)
end

local function Update()
  if not frame then return end
  db = HK.db.mend
  if HK.db.enabled == false or not db.enabled or not HK.isHunter then
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
  frame:SetShown(true)
end

function MendMark.Update()
  Update()
end

-- Called by the ticker: cheap, and keeps the marker glued to a moving pet.
local function Tick()
  if not frame then return end
  Update()
end

function MendMark.RescanSettings()
  db = HK.db.mend
  if not frame then return end
  icon:SetTexture(MendIconTexture())
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
    "enabled=%s pet=%s spell=%s inRange=%s hp=%s%% threshold=%s%% anchor=%s(mode=%s) shown=%s",
    tostring(db and db.enabled), tostring(PetIsOut()), tostring(mendSpell or MendSpellName()),
    tostring(MendInRange()),
    hp and string.format("%.0f", hp) or "?",
    tostring(db and db.hpThreshold),
    tostring(db and db.anchor), tostring(lastAnchorMode), tostring(MendMark.IsShown()))
end

-- The nameplate CVars that decide whether the client publishes a pet plate at
-- all. Printed by /htk mend so "why isn't it over the head?" is answerable.
function MendMark.PlateCVars()
  if not GetCVar then return "(GetCVar unavailable)" end
  local names = {
    "nameplateShowFriends", "nameplateShowAll", "nameplateShowEnemies",
    "nameplateShowOnlyNames", "nameplateMaxDistance",
  }
  local out = {}
  for _, n in ipairs(names) do
    local ok, v = pcall(GetCVar, n)
    out[#out + 1] = n .. "=" .. tostring(ok and v or "?")
  end
  return table.concat(out, "  ")
end

function MendMark.PrintDiag()
  print("|cff39ff14HunterKit — Pet Mend Marker|r")
  print("  " .. MendMark.Diagnostic())
  print("  cvars: " .. MendMark.PlateCVars())
  if lastAnchorMode ~= "plate" then
    print("  No pet name plate from the client, so the marker is anchored to the pet unit frame.")
    print("  True over-the-head anchoring needs a pet plate: Options → Nameplates → show friendly nameplates, or set Anchor = Plate.")
  end
end

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------
function MendMark.Init()
  db = HK.db.mend
  if not HK.isHunter then return end   -- structural gate

  BuildFrame()

  HK.On("UNIT_HEALTH", function(u) if u == "pet" then Update() end end)
  HK.On("UNIT_MAXHEALTH", function(u) if u == "pet" then Update() end end)
  HK.On("UNIT_PET", function(u) if u == "player" then Update() end end)
  HK.On("PLAYER_REGEN_ENABLED", Update)
  HK.On("PLAYER_REGEN_DISABLED", Update)
  HK.On("NAME_PLATE_UNIT_ADDED", Update)
  HK.On("NAME_PLATE_UNIT_REMOVED", Update)
  HK.On("PLAYER_ENTERING_WORLD", Update)
  HK.On("SPELLS_CHANGED", function()
    mendSpell = nil                    -- re-resolve (may have just been trained)
    Update()
  end)

  ticker = HK.Ticker(0.10, Tick)
  Update()
end

HK.RegisterModule("MendMark", { Init = MendMark.Init })
