--[[==============================================================================
 HunterKit — Passive Alert (F4)
 While the pet is in Passive, a big Ability Seal pulses center-screen above the
 character (sonar rings + bouncing icon + label), plus an optional glow on the
 passive pet-bar button. Always-on while Passive — no combat exceptions. This is
 a Detection/display module only; it never changes stance.
==============================================================================]]
local _, HK = ...

local PassivePulse = {}
HK.PassivePulse = PassivePulse

local db
local PASSIVE_SEAL = "Interface\\Icons\\Ability_Seal"
local PASSIVE_SEAL_ID = 132311   -- Ability_Seal FileDataID (the passive stance icon)
local passiveSlot = nil
local slotResolved = false

-- True if a GetPetActionInfo value represents the Passive stance. The texture
-- may be a path string ("Interface\\Icons\\Ability_Seal") on older clients or a
-- numeric FileDataID (132311) after the Midnight merge. We also accept the
-- action NAME matching "passive" (some clients expose the stance as a named
-- token rather than the seal icon).
local function IsPassiveTexture(tex)
  if type(tex) == "number" then return tex == PASSIVE_SEAL_ID end
  if type(tex) == "string" then return tex:lower():find("ability_seal", 1, true) ~= nil end
  return false
end
local function IsPassiveName(name)
  return type(name) == "string" and name:lower():find("passive", 1, true) ~= nil
end

local alert, icon, label, ring1, ring2, glow
local timer, phase = 0, 0
local wasOn = false
-- forward declarations (these are referenced across the file before their
-- bodies are defined in the same chunk, so they must be declared up front)
local OnUpdate, Refresh, RefreshPetBarGlow

local function PetHasBar()
  return PetHasActionBar() == true or PetHasActionBar() == 1
end

-- ---------------------------------------------------------------------------
-- Passive slot resolution (scan, don't hardcode)
-- ---------------------------------------------------------------------------
-- Parse one GetPetActionInfo call into a table, capturing enough positions to
-- be robust to the return signature differing across clients:
--   * some clients return name, texture, isToken, isActive, ...
--   * others return name, subtext, texture, isToken, isActive, ...
-- We therefore scan positions 2..3 for the texture and positions 4..5 for the
-- active flag, and match on whichever lands on a real value. This is the whole
-- "no passiv warning" fix: reading a fixed slot read texture/isActive from the
-- wrong position on this client.
local function ParsePetAction(i)
  local t = { GetPetActionInfo(i) }        -- varargs -> table, safe even if sparse
  local name = t[1]
  local tex = t[2]
  if (tex == nil or tex == "") then tex = t[3] end
  -- isActive sits at position 4 OR 5 depending on whether a subtext field exists
  local isActive = t[4]
  if isActive == nil or isActive == "" then isActive = t[5] end
  return name, tex, isActive, t
end

function PassivePulse.GetSlot()
  if slotResolved then return passiveSlot end
  if not PetHasBar() then return nil end
  local max = NUM_PET_ACTION_SLOTS or 10
  for i = 1, max do
    local name, tex = ParsePetAction(i)
    if IsPassiveTexture(tex) or IsPassiveName(name) then
      passiveSlot = i
      slotResolved = true
      return i
    end
  end
  return nil
end

-- Returns (isPassiveActive, texture).
local function PetPassiveInfo()
  if not PetHasBar() then return false end
  local max = NUM_PET_ACTION_SLOTS or 10
  local isActiveNow, tex = false, nil
  for i = 1, max do
    local name, texture, isActive = ParsePetAction(i)
    if IsPassiveTexture(texture) or IsPassiveName(name) then
      if isActive == true then
        isActiveNow = true
        -- remember which slot is passive so optional features (pet-bar glow)
        -- can target the right button
        passiveSlot = i
      end
      if not tex then tex = texture end
    end
  end
  slotResolved = (passiveSlot ~= nil)
  return isActiveNow, tex
end

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------
function PassivePulse.Init()
  db = HK.db.pulse
  if not HK.isHunter then return end -- structural gate

  BuildAlert()

  HK.On("PET_BAR_UPDATE", Refresh)
  HK.On("PET_BAR_UPDATE_USABLE", Refresh)
  HK.On("PLAYER_ENTERING_WORLD", Refresh)

  Refresh()
end

function BuildAlert()
  alert = CreateFrame("Frame", "HunterKitPassiveAlert", UIParent)
  alert:SetFrameStrata("HIGH")
  alert:EnableMouse(false)
  alert:SetClampedToScreen(true)
  alert:SetWidth(db.size)
  alert:SetHeight(db.size)

  -- No dark backdrop: the alert frame matches the seal icon exactly so it reads
  -- clean. The sonar rings expand beyond (children aren't clipped) and the label
  -- hangs below.
  icon = alert:CreateTexture(nil, "ARTWORK")
  icon:SetPoint("CENTER", alert, "CENTER", 0, 0)
  icon:SetSize(db.size, db.size)
  icon:SetTexture(PASSIVE_SEAL)
  icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)

  local function mkRing()
    local r = alert:CreateTexture(nil, "ARTWORK")
    r:SetTexture("Interface\\Cooldown\\star4")
    r:SetBlendMode("ADD")
    r:SetVertexColor(1, 0.9, 0.3, 1)
    -- Centre-anchor on the seal so the ring expands symmetrically outward from
    -- its centre (SetAllPoints here anchored the ring to the top-left, making it
    -- grow off-centre and look out of place).
    r:SetPoint("CENTER", icon, "CENTER", 0, 0)
    r:SetSize(db.size, db.size)
    r:Hide()
    return r
  end
  ring1 = mkRing()
  ring2 = mkRing()

  label = alert:CreateFontString(nil, "OVERLAY")
  label:SetPoint("TOP", alert, "BOTTOM", 0, -4)
  label:SetFontObject(GameFontNormalLarge)
  -- Red "PET PASSIVE!" warning directly below the pulsing seal icon, as
  -- requested. The seal icon (Ability_Seal, 132311) is always used.
  label:SetText("PET PASSIVE!")
  label:SetTextColor(1, 0.05, 0.05)
  label:SetJustifyH("CENTER")
  -- outline reads clearly over any backdrop / scene
  label:SetShadowColor(0, 0, 0, 1)
  label:SetShadowOffset(1, -1)

  alert:SetScript("OnUpdate", OnUpdate)

  HK.RegisterDraggable("pulse", alert, PassivePulse.ApplyPosition, function(x, y)
    db.offsetX, db.offsetY = x, y
  end, {
    restore = function() Refresh() end,
    -- Re-bind the pulse animation OnUpdate loop after a drag / lock cycle, so it
    -- keeps pulsing (the drag handlers blank the frame's script otherwise).
    onUpdate = function() alert:SetScript("OnUpdate", OnUpdate) end,
    -- Store the alert's on-screen centre as an offset from UIParent's CENTRE, in
    -- UIParent space, so it round-trips exactly (no jump on lock).
    saveFromScreen = function()
      HK.SaveDragged(alert, db)
    end,
  })

  -- lay out now that icon and label exist
  PassivePulse.ApplyPosition()
  alert:SetShown(false)
end

function PassivePulse.ApplyPosition()
  if not alert then return end
  alert:ClearAllPoints()
  alert:SetPoint("CENTER", UIParent, "CENTER", db.offsetX, db.offsetY)
  alert:SetSize(db.size, db.size)
  icon:SetSize(db.size, db.size)
  label:SetShown(db.label)
end

function PassivePulse.RescanSettings()
  db = HK.db.pulse
  if not alert then return end
  PassivePulse.ApplyPosition()
  Refresh()
end

-- ---------------------------------------------------------------------------
-- Per-frame pulse (fully portable; no client-specific animation signatures)
-- ---------------------------------------------------------------------------
OnUpdate = function(self, dt)
  if not self:IsShown() then return end
  phase = phase + dt
  local cycle = db.cycle or 0.9
  local p = (phase % cycle) / cycle          -- 0..1

  -- rings: expanding 1.0 -> 2.4, alpha 0.8 -> 0, staggered by half a cycle
  if db.rings then
    ring1:SetShown(true); ring2:SetShown(true)
    local function ringRend(r, ap)
      local s = 1.0 + 1.4 * ap
      local a = (1 - ap) * 0.8
      r:SetSize(icon:GetWidth() * s, icon:GetHeight() * s)
      r:SetAlpha(a)
    end
    ringRend(ring1, p)
    ringRend(ring2, (p + 0.5) % 1)
  else
    ring1:Hide(); ring2:Hide()
  end

  -- bounce (ping-pong) on the icon
  local bounce = math.abs(math.sin(p * math.pi))    -- 0..1..0
  icon:SetScale(1.0 + 0.12 * bounce)

  -- label alpha rides the wave
  if db.label then
    label:SetAlpha(0.7 + 0.3 * bounce)
  end
end

-- ---------------------------------------------------------------------------
-- Driver
-- ---------------------------------------------------------------------------
Refresh = function()
  if not alert then return end
  db = HK.db.pulse
  if HK.Editing() then
    -- While editing, leave the alert where the user put it (never reposition or
    -- hide it) so the drag owns its position.
    if not InCombatLockdown() then alert:SetShown(true) end
    return
  end
  local on = PetPassiveInfo()
  local show = on and db.enabled and HK.isHunter and HK.db.enabled ~= false
  alert:SetShown(show and true or false)
  if show then
    -- Always show the Ability_Seal icon (the pet Passive stance icon), as
    -- requested. Do not override it with whatever the pet bar reports — the
    -- seal is the icon the user wants for this alert.
    icon:SetTexture(PASSIVE_SEAL)
    if phase == 0 then phase = 0.0001 end        -- kick the OnUpdate pulse
    wasOn = true
  else
    if wasOn then
      wasOn = false
      phase = 0
      icon:SetScale(1)
      ring1:Hide(); ring2:Hide()
    end
    alert:SetAlpha(1)
  end
  RefreshPetBarGlow(on)
end

RefreshPetBarGlow = function(on)
  if not db.smallGlowOnPetBar then
    if glow then glow:SetShown(false) end
    return
  end
  local slot = PassivePulse.GetSlot()
  local petBtn = slot and _G["PetActionButton" .. slot]
  if not petBtn then
    if glow then glow:SetShown(false) end
    return
  end
  if not glow then
    glow = HK.CreateBorder(petBtn, 2)
    glow:SetVertexColor(1, 0.85, 0.25, 1)
  end
  glow:SetShown(on and true or false)
end

function PassivePulse.Refresh()
  Refresh()
end

function PassivePulse.IsShown()
  return alert and alert:IsShown()
end

HK.RegisterModule("PassivePulse", { Init = PassivePulse.Init })
