--[[==============================================================================
 HunterKit — Low Ammo Warning (F5)
 A periodic on-screen + sound warning when the equipped ammo (arrows/bullets)
 runs low. Modelled on the community's ammo trackers (Kals ClassicAmmoCount's
 configurable threshold, the WeakAura "3/2/1 stacks left" milestones) but tuned
 the way the user asked: periodic, and MORE persistent the less ammo is left.

 There is no TTS API on this client, so the audible half is the raid-warning
 sound (distinct, interrupt-resistant), gated behind its own toggle.
==============================================================================]]
local _, HK = ...

local AmmoWarn = {}
HK.AmmoWarn = AmmoWarn

local db
local frame, icon, label
local lastWarn = 0
local shownUntil = 0

local ARROW_ICON  = "Interface\\Icons\\INV_Arrow_02"
local BULLET_ICON = "Interface\\Icons\\INV_Ammo_Bullet_03"
local WARN_SOUND  = "Sound\\Interface\\RaidWarning.ogg"

-- tier 0 = silent; higher = less ammo = warned more often and for longer.
local PERIOD = { [1] = 90, [2] = 45, [3] = 15, [4] = 10 }
local DURA   = { [1] = 4,  [2] = 8,  [3] = 12, [4] = 20 }

-- ---------------------------------------------------------------------------
-- Ammo discovery: the equipped ammo slot item, then how many are left.
-- GetItemCount covers bags; the equipped stack is added when the bag count is
-- zero so "only what's loaded in the quiver" still reads correctly.
-- ---------------------------------------------------------------------------
local function AmmoSlot()
  if not GetInventorySlotInfo then return nil end
  local ok, slot = pcall(GetInventorySlotInfo, "AmmoSlot")
  return (ok and slot) or nil
end

local function AmmoCount()
  local slot = AmmoSlot()
  if not slot then return nil, nil end
  local id
  if GetInventoryItemID then
    local ok, v = pcall(GetInventoryItemID, "player", slot)
    if ok then id = v end
  end
  if not id then return 0, nil end   -- slot exists but nothing equipped
  local n = 0
  if GetItemCount then
    local ok, c = pcall(GetItemCount, id)
    if ok and type(c) == "number" then n = c end
  end
  if n == 0 and GetInventoryItemCount then
    local ok, ec = pcall(GetInventoryItemCount, "player", slot)
    if ok and type(ec) == "number" and ec > 0 then n = ec end
  end
  return n, id
end

local function TierFor(n, id)
  if id == nil then return 4 end            -- ranged slot fed, ammo slot empty
  local T = db.threshold or 100
  if n > T then return 0 end
  if n > T / 2 then return 1 end
  if n > T / 4 then return 2 end
  if n > 0 then return 3 end
  return 4
end

local TIER_COLOR = {
  [1] = {1, 0.85, 0.2},
  [2] = {1, 0.55, 0.1},
  [3] = {1, 0.15, 0.1},
  [4] = {1, 0.05, 0.05},
}

local function WarnSound()
  if PlaySoundFile then
    local ok = pcall(PlaySoundFile, WARN_SOUND, "Master")
    if ok then return end
  end
  if PlaySound then pcall(PlaySound, "RaidWarning") end
end

-- ---------------------------------------------------------------------------
-- Build / position
-- ---------------------------------------------------------------------------
local function BuildFrame()
  frame = CreateFrame("Frame", "HunterKitAmmoWarn", UIParent)
  frame:SetFrameStrata("HIGH")
  frame:EnableMouse(false)
  frame:SetSize(34, 34)

  icon = frame:CreateTexture(nil, "ARTWORK")
  icon:SetAllPoints(frame)
  icon:SetTexture(ARROW_ICON)
  icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

  label = frame:CreateFontString(nil, "OVERLAY")
  label:SetPoint("TOP", frame, "BOTTOM", 0, -2)
  label:SetFontObject(GameFontNormal)
  label:SetJustifyH("CENTER")
  label:SetShadowColor(0, 0, 0, 1)
  label:SetShadowOffset(1, -1)

  AmmoWarn.ApplyPosition()
  frame:SetShown(false)
end

-- Sits to the RIGHT of the pet-passive warning when that exists (the two are
-- the "your setup needs attention" pair); otherwise its own spot.
function AmmoWarn.ApplyPosition()
  if not frame then return end
  local pulse = _G["HunterKitPassiveAlert"]
  frame:ClearAllPoints()
  if pulse then
    frame:SetPoint("LEFT", pulse, "RIGHT", 10, 0)
  else
    frame:SetPoint("CENTER", UIParent, "CENTER", 220, 120)
  end
end

function AmmoWarn.IsShown()
  return frame ~= nil and frame:IsShown() == true
end

-- ---------------------------------------------------------------------------
-- Tick (1s): decide tier, warn on the tier's period, hide when the flash ends.
-- ---------------------------------------------------------------------------
local function Tick()
  if not frame then return end
  if HK.db.enabled == false or not db.enabled or not HK.isHunter then
    frame:SetShown(false)
    return
  end
  local n, id = AmmoCount()
  if n == nil then
    frame:SetShown(false)
    return
  end
  local tier = TierFor(n, id)
  local now = GetTime()
  if tier > 0 and now >= lastWarn + PERIOD[tier] then
    lastWarn = now
    shownUntil = now + DURA[tier]
    local c = TIER_COLOR[tier]
    icon:SetTexture(id and ARROW_ICON or BULLET_ICON)
    if tier == 4 then
      label:SetText("NO AMMO!")
    else
      label:SetText("AMMO: " .. n)
    end
    label:SetTextColor(c[1], c[2], c[3])
    frame:SetShown(true)
    if db.sound then WarnSound() end
  end
  if now > shownUntil then
    frame:SetShown(false)
  end
end

function AmmoWarn.RescanSettings()
  db = HK.db.ammo
  if not frame then return end
  AmmoWarn.ApplyPosition()
  Tick()
end

function AmmoWarn.Init()
  db = HK.db.ammo
  if not HK.isHunter then return end   -- structural gate

  BuildFrame()

  HK.On("BAG_UPDATE_DELAYED", function() lastWarn = 0; Tick() end)
  HK.On("PLAYER_ENTERING_WORLD", Tick)

  HK.Ticker(1, Tick)
  Tick()
end

HK.RegisterModule("AmmoWarn", { Init = AmmoWarn.Init })
