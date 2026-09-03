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
   * if the player has nameplates off, no plate exists. An opt-in "Force pet
     name plate" CVar ladder was tried and removed in 0.9.1: on clients that
     publish no pet plate even with every nameplate CVar on it could never
     work, and it held the player's nameplate settings hostage. CVars that an
     older build changed are still restored on load/logout.
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
local lastAnchorSource = nil
local eventPlate = nil

-- Mend Pet (136) resolves to the localized name of the rank you actually know.
local MEND_PET_SPELL_ID = 136
local MEND_ICON_FALLBACK = "Interface\\Icons\\Ability_Hunter_MendPet"
local RING_TEX = "Interface\\Cooldown\\star4"

-- Ring/border colours: green = a Mend will land, red = the pet is out of range.
local C_INRANGE = { 0.2, 1, 0.2 }
local C_FAR     = { 1, 0.15, 0.15 }

-- The "Force pet name plate" CVar ladder was removed in 0.9.1 (it could never
-- produce a pet plate on clients that publish none, and it held the player's
-- nameplate CVars hostage). CVars that older builds changed are still restored
-- on load/logout via db.plateCVars.
-- CVars to PROBE by name. C_Console.GetAllCommands() only lists registered
-- *console commands*, so several real nameplate CVars are missing from it -- that
-- is how an earlier diagnostic wrongly reported the friendly ones as absent.
local PLATE_CVAR_CANDIDATES = {
  "nameplateShowAll",
  "nameplateShowEnemies",
  "nameplateShowFriends",
  "nameplateShowEnemyMinions",
  "nameplateShowEnemyPets",
  "nameplateShowFriendlyMinions",
  "nameplateShowFriendlyPets",
  "nameplateShowFriendlyGuardians",
  "nameplateShowFriendlyTotems",
  "nameplateShowFriendlyNPCs",
  "nameplateShowOnlyNames",
  "nameplateShowSelf",
  "nameplateMaxDistance",
}

-- Cached spell name. Cleared on SPELLS_CHANGED so learning Mend Pet later is
-- picked up without a /reload.
local mendSpell = nil

-- Forward declarations. BuildFrame runs before these bodies exist in the chunk,
-- and a closure that references a local declared LATER compiles to a GLOBAL
-- lookup (nil at runtime) — which is exactly the "attempt to call a nil value"
-- that /htk reset hit when it invoked the registered apply().
local OnUpdateAnchor, Update, ResolveAnchor

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

-- 4) the pre-C_NamePlate layout: NamePlate1..N children of WorldFrame, with the
--    unit token on the child unit frame. TBC/Wrath-lineage clients use this.
local function PlateFromLegacyScan()
  if type(WorldFrame) ~= "table" or not WorldFrame.GetChildren then return nil end
  local ok, kids = pcall(function() return { WorldFrame:GetChildren() } end)
  if not ok or type(kids) ~= "table" then return nil end
  for _, f in ipairs(kids) do
    if type(f) == "table" and f.GetName then
      local nm = f:GetName()
      if type(nm) == "string" and nm:match("^NamePlate%d+$") then
        local unit = f.unit
        if unit == nil and type(f.UnitFrame) == "table" then unit = f.UnitFrame.unit end
        if unit == nil then
          local okc, child = pcall(f.GetChildren, f)
          if okc and type(child) == "table" then unit = child.unit end
        end
        if unit == "pet" and PlateUsable(f) then return f end
      end
    end
  end
  return nil
end

local function PetPlate()
  return PlateForUnit() or PlateFromEvent() or PlateFromScan() or PlateFromLegacyScan()
end

-- ---------------------------------------------------------------------------
-- Direct screen-position APIs (no plate needed), if this client has one
-- ---------------------------------------------------------------------------
-- Probed by name at runtime. Most clients have none of these; a client that does
-- gives us the pet's on-screen position with nameplates completely off, which is
-- exactly what the plate-only rule otherwise forbids. `/htk mend` prints the raw
-- values so the convention can be checked against what's on screen.
local WORLD_POS_APIS = { "GetUnitNamePosition", "GetUnitScreenPosition" }

local function WorldScreenPos()
  for _, name in ipairs(WORLD_POS_APIS) do
    local fn = _G[name]
    if type(fn) == "function" then
      local ok, x, y = pcall(fn, "pet")
      if ok and type(x) == "number" and type(y) == "number" then
        return x, y, name
      end
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Leftover CVar cleanup (the force-plate ladder was removed in 0.9.1)
-- ---------------------------------------------------------------------------
-- CVars are locked while in combat; a blocked restore retries on the next call
-- (PLAYER_REGEN_ENABLED and every tick re-run it).
local function PlateCVarsLocked()
  return InCombatLockdown and InCombatLockdown() == true
end

-- Put back every CVar an older build saved, then forget it.
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
  if n > 0 then HK.Dbg("mend restored", tostring(n), "leftover nameplate cvars") end
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
  HK.SafeClamp(frame, false)    -- it must follow the pet off-screen, not clamp
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

  -- Over-the-head anchoring is impossible on clients that publish neither a pet
  -- plate nor a screen position, so the UI fallback must at least go where the
  -- player wants it. Drag it with /htk unlock; the drop point is stored in
  -- pinX/pinY (kept apart from offsetX/offsetY, which is the gap above the
  -- anchor's top edge and is still used in plate mode).
  HK.RegisterDraggable("mend", frame, function() Update() end, function(x, y)
    db.pinX, db.pinY = x, y
  end, {
    -- Only the UI fallback is the player's to move. While the marker floats over
    -- the pet's head (plate/screen anchor) it must keep following the pet — and
    -- a frame anchored to a name plate is a restricted region, so lock/unlock
    -- must leave it alone entirely.
    --
    -- Update() first, on purpose: Positions.SetLock acts on this answer in the
    -- same instant, and the frame must already be off the protected plate by
    -- then. Otherwise unlock would clamp/drag a plate-anchored frame for the
    -- ~100ms until the ticker re-anchors it — which is the client error this
    -- guard exists to prevent.
    draggableIf = function()
      Update()
      return ResolveAnchor() == "petframe"
    end,
    restore = function() Update() end,
    -- Re-bind the pulse loop; the drag handlers blank the frame's OnUpdate.
    onUpdate = function() frame:SetScript("OnUpdate", OnUpdateAnchor) end,
    saveFromScreen = function()
      local tmp = {}
      HK.SaveDragged(frame, tmp)      -- measures in UIParent space, Y-up
      db.pinX, db.pinY, db.moved = tmp.offsetX, tmp.offsetY, true
    end,
  })
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
-- Decide where the marker belongs WITHOUT touching it, so /htk mend can report
-- the answer even while the marker is hidden (it used to print mode=nil and then
-- advise about a fallback it had never resolved).
-- Returns: mode ("plate"|"screen"|"petframe"|"none"), then the target:
--   plate    -> the plate frame
--   screen   -> x, y, apiName
--   petframe -> the pet unit frame
ResolveAnchor = function()
  local mode = db.anchor or "auto"

  -- Edit mode (/htk unlock) always uses the draggable UI fallback.
  --
  -- The over-the-head marker hangs off the pet's name plate, which is a
  -- protected frame: the client refuses drag/clamp state on anything anchored to
  -- it ("Can't clamp restricted regions", plus taint), and this module re-applies
  -- the plate anchor every tick anyway — so a drag there could neither be started
  -- nor kept. Showing the immovable head marker during edit mode would leave the
  -- player dragging nothing, so while unlocked we resolve to the fallback, which
  -- IS the player's to move. Head anchoring resumes the moment frames are locked.
  if HK.Editing() then
    local pf = _G["PetFrame"]
    if pf then return "petframe", pf end
    -- No pet frame at all (an addon removed it): fall through rather than hiding
    -- the marker, so unlocking still shows something.
  end

  if mode == "petframe" then
    local pf = _G["PetFrame"]
    if pf then return "petframe", pf end
    return "none"
  end

  local p = PetPlate()
  if p then return "plate", p end
  if mode == "plate" then return "none" end

  -- A direct screen-position API beats any UI fallback: true world anchoring with
  -- nameplates off. Y is assumed to be pixels measured from the TOP-left; /htk
  -- mend prints the raw pair so it can be checked against what's on screen.
  local wx, wy, src = WorldScreenPos()
  if wx then return "screen", wx, wy, src end

  local pf = _G["PetFrame"]
  if pf then return "petframe", pf end
  return "none"
end

-- Re-resolved every tick: the pet moves, and plate frames come and go. Returns
-- the mode actually applied.
local function ApplyAnchor()
  local ox, oy = db.offsetX or 0, db.offsetY or 0
  local mode, a, b, c = ResolveAnchor()
  lastAnchorSource = nil     -- only set by the screen-position path

  if mode == "plate" then
    -- Anchoring to a forbidden (instance) plate can throw; fall through to the
    -- pet frame instead of erroring out.
    local ok = pcall(function()
      frame:ClearAllPoints()
      frame:SetPoint("BOTTOM", a, "TOP", ox, oy)
    end)
    if ok then
      lastAnchorMode = "plate"
      return lastAnchorMode
    end
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

  if mode == "screen" then
    local scale = (UIParent.GetEffectiveScale and UIParent:GetEffectiveScale()) or 1
    local sh = (GetScreenHeight and GetScreenHeight()) or (UIParent and UIParent:GetHeight()) or 0
    frame:ClearAllPoints()
    frame:SetPoint("BOTTOM", UIParent, "BOTTOMLEFT", a / scale, sh - (b / scale) + oy)
    lastAnchorMode = "screen"
    lastAnchorSource = c
    return lastAnchorMode
  end

  if mode == "petframe" then
    frame:ClearAllPoints()
    if HK.IsPinned(db) then
      -- Dragged: stay exactly where the player dropped it (absolute UIParent
      -- CENTRE offset, the same scheme the feed button and sniper mark use).
      frame:SetPoint("CENTER", UIParent, "CENTER", db.pinX or 0, db.pinY or 0)
    else
      frame:SetPoint("BOTTOM", a, "TOP", ox, oy)
    end
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

-- Which anchor mode the frame's clamp state was last set for (see Update).
local clampedFor = nil

Update = function()
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
  -- Keep the clamp in step with what the frame is anchored to: never clamped
  -- while it hangs off a name plate (the client refuses the call, and it has to
  -- follow the pet off-screen anyway), clamped while it is the draggable
  -- fallback in edit mode so it cannot be dropped off-screen. Only on a mode
  -- change — not ten times a second.
  if mode ~= clampedFor then
    HK.SafeClamp(frame, mode ~= "plate" and editing or false)
    clampedFor = mode
  end
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
  RestorePlateCVars()   -- no-op unless an older build left CVars to put back
  Update()
end

function MendMark.RescanSettings()
  db = HK.db.mend
  if not frame then return end
  icon:SetTexture(MendIconTexture())
  RestorePlateCVars()
  Update()
end

function MendMark.IsShown()
  return frame ~= nil and frame:IsShown() == true
end

function MendMark.AnchorMode()
  return lastAnchorMode
end

-- Which world-position API produced the current anchor (nil unless mode=screen).
function MendMark.AnchorSource()
  return lastAnchorSource
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
-- all, plus leftover changes older builds made. Printed by /htk mend so "why isn't it over
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

-- Capability report: what THIS client actually offers for world anchoring. This
-- exists because the answer differs between clients (Era vs TBC-lineage vs the
-- Midnight UI merge) and guessing at it is how you ship the wrong thing.
function MendMark.Capabilities()
  local out = {}

  local apis = {}
  for _, name in ipairs(WORLD_POS_APIS) do
    if type(_G[name]) == "function" then
      local ok, x, y = pcall(_G[name], "pet")
      apis[#apis + 1] = name .. "=" .. (ok and (tostring(x) .. "," .. tostring(y)) or "ERR")
    else
      apis[#apis + 1] = name .. "=absent"
    end
  end
  out[#out + 1] = "  screen-pos APIs: " .. table.concat(apis, "  ")

  local paths = {
    GetNamePlateForUnit = PlateForUnit(),
    ["NAME_PLATE_UNIT_ADDED"] = PlateFromEvent(),
    GetNamePlates = PlateFromScan(),
    ["NamePlateN scan"] = PlateFromLegacyScan(),
  }
  local found = {}
  for _, name in ipairs({ "GetNamePlateForUnit", "NAME_PLATE_UNIT_ADDED", "GetNamePlates", "NamePlateN scan" }) do
    found[#found + 1] = name .. "=" .. (paths[name] and "plate" or "none")
  end
  out[#out + 1] = "  pet plate via:   " .. table.concat(found, "  ")

  local n = 0
  if C_NamePlate and C_NamePlate.GetNamePlates then
    local ok, plates = pcall(C_NamePlate.GetNamePlates)
    if ok and type(plates) == "table" then n = #plates end
  end
  out[#out + 1] = "  plates visible:  " .. tostring(n) .. "   anchor now: " .. tostring(lastAnchorMode)
    .. (lastAnchorSource and (" (" .. lastAnchorSource .. ")") or "")

  local up = "n/a"
  if UnitPosition then
    local ok, x, y, z = pcall(UnitPosition, "pet")
    up = ok and string.format("%.1f,%.1f,%.1f", x or -1, y or -1, z or -1) or "refused"
  end
  local facing = "n/a"
  if GetPlayerFacing then
    local ok, f = pcall(GetPlayerFacing)
    facing = ok and string.format("%.2f", f or -1) or "refused"
  end
  out[#out + 1] = "  UnitPosition(pet)=" .. up .. "  GetPlayerFacing=" .. facing

  return table.concat(out, "\n")
end

-- Every nameplate CVar this client actually has, so "which setting would give my
-- pet a plate?" is answerable instead of guessed.
function MendMark.NameplateCVarDump()
  local seen, names = {}, {}
  local function add(n)
    if type(n) ~= "string" then return end
    n = (n:gsub("^/", ""))
    if n:lower():find("nameplate", 1, true) and not seen[n] then
      seen[n] = true
      names[#names + 1] = n
    end
  end

  -- 1) Probe a candidate list directly. GetCVar returns nil for a CVar this
  --    client does not have, so absence here is a real absence.
  for _, n in ipairs(PLATE_CVAR_CANDIDATES) do
    if GetCVar and pcall(GetCVar, n) and GetCVar(n) ~= nil then add(n) end
  end
  -- 2) Plus anything nameplate-ish registered as a console command.
  if C_Console and C_Console.GetAllCommands then
    local ok, list = pcall(C_Console.GetAllCommands)
    if ok and type(list) == "table" then
      for _, e in ipairs(list) do
        local n
        if type(e) == "string" then n = e
        elseif type(e) == "table" then n = e.command or e.name or e.cvar end
        add(n)
      end
    end
  end
  if #names == 0 then return "(no nameplate CVars found)" end
  table.sort(names)
  local out = {}
  for _, n in ipairs(names) do
    local ok, v = pcall(GetCVar, n)
    local val = tostring(ok and v or "?")
    -- "*" = a value HunterKit changed for the force-plate ladder (restored on
    -- untick / logout).
    if type(db) == "table" and type(db.plateCVars) == "table" and db.plateCVars[n] ~= nil then
      val = val .. " (was " .. tostring(db.plateCVars[n]) .. ")*"
    end
    out[#out + 1] = n .. "=" .. val
  end
  return table.concat(out, "  ")
end

-- Why the marker is not on screen right now (nil when it should be showing).
function MendMark.HiddenReason()
  if not frame then return "not initialised" end
  if HK.db.enabled == false then return "HunterKit master switch is off" end
  if not db.enabled then return "the mend marker is disabled" end
  if not HK.isHunter then return "not a hunter" end
  if not PetIsOut() then return "no pet out" end
  if MendInRange() == nil then return "Mend Pet is not learned" end
  local hp = PetHPPercent()
  local urgent = (hp ~= nil) and (hp <= (db.hpThreshold or 30))
  if db.combatOnly and not InFight() and not urgent then
    return "out of combat and the pet is above the threshold (Only in combat is on)"
  end
  return nil
end

function MendMark.PrintDiag()
  print("|cff39ff14HunterKit — Pet Mend Marker|r")
  print("  " .. MendMark.Diagnostic())
  local reason = MendMark.HiddenReason()
  if reason then print("  hidden because: " .. reason) end
  -- Report the anchor even while hidden: resolve it without moving anything.
  local rm = ResolveAnchor()
  print("  anchor would be: " .. tostring(rm)
    .. (lastAnchorMode and ("  (applied: " .. lastAnchorMode .. ")") or "  (not applied yet)"))
  print("  cvars (* = changed by an older HunterKit, restored on load/logout): " .. MendMark.PlateCVars())
  print(MendMark.Capabilities())
  print("  nameplate cvars: " .. MendMark.NameplateCVarDump())
  if rm == "plate" then
    print("  Anchored over the pet's head via its name plate.")
  elseif rm == "screen" then
    print("  Anchored to the client's own screen position for the pet (no plate needed).")
  else
    print("  This client publishes no pet plate right now, so the marker uses the UI")
    print("  fallback. /htk unlock and drag it wherever you want it (the spot is saved).")
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
    -- CVars are locked in combat: restore leftovers once we're out.
    RestorePlateCVars()
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

  RestorePlateCVars()

  ticker = HK.Ticker(0.10, Tick)
  Update()
end

HK.RegisterModule("MendMark", { Init = MendMark.Init })
