--[[==============================================================================
 HunterKit — Low Ammo Warning (F5)
 A periodic on-screen + sound warning when the equipped ammo (arrows/bullets)
 runs low. Modelled on the community's ammo trackers (Kals ClassicAmmoCount's
 configurable threshold, the WeakAura "3/2/1 stacks left" milestones) but tuned
 the way the user asked: periodic, and MORE persistent the less ammo is left.

 Audible half (user: DISTINCT and RARE): a quest-failed style sting fires only
 when the situation gets WORSE (first entry into warning, or a tier escalation)
 -- periodic re-warns are visual only. The empty tier speaks instead: short
 bundled voice clips ("No arrows!" / "No ammo!"), with the sting as fallback.
 The client itself has no TTS API, so the clips ship in Media\.
==============================================================================]]
local _, HK = ...

local AmmoWarn = {}
HK.AmmoWarn = AmmoWarn

local db
local frame, icon, cross, label
local lastWarn = 0
local lastTier = 0
local lastVoice = 0
local shownUntil = 0

-- The empty-tier voice must not nag: it speaks at most once per cooldown,
-- while the VISUAL re-warns keep the 10 s period.
local VOICE_COOLDOWN = 30

local ARROW_ICON  = "Interface\\Icons\\INV_Arrow_02"
local BULLET_ICON = "Interface\\Icons\\INV_Ammo_Bullet_03"
local RED_X       = "Interface\\Buttons\\UI-GroupLoot-Pass-Up"
-- Deliberately NOT RaidWarning: that one is common in raids/groups; this sting
-- is distinct and (by policy below) rare.
local WARN_SOUND  = "Sound\\Interface\\igQuestFailed.ogg"
local MEDIA       = "Interface\\AddOns\\HunterKit\\Media\\"
local VOICE = { arrows = MEDIA .. "voice_noarrows.mp3",
                bullets = MEDIA .. "voice_noammo.mp3" }

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
  if PlaySound then pcall(PlaySound, "igQuestFailed") end
end

-- The empty tier speaks: bundled dwarf-style clips. Returns false when the
-- clip is missing from Media (client PlaySoundFile returns false), so the
-- caller can fall back to the sting.
local function VoiceSound(kind)
  local path = VOICE[kind] or VOICE.bullets
  if not PlaySoundFile then return false end
  local ok, played = pcall(PlaySoundFile, path, "Master")
  return ok and played ~= false
end

-- What is equipped in the ammo slot: "arrows" / "bullets" / nil (unknown),
-- plus the item's own icon so the warning shows the real projectile art.
local function AmmoType(id)
  if not id or not GetItemInfo then return nil, nil end
  local ok, name, _, _, _, _, subclass, _, _, _, texture = pcall(GetItemInfo, id)
  if not ok then return nil, nil end
  local low = (type(name) == "string") and name:lower() or ""
  local kind
  if low:find("arrow", 1, true) or subclass == 2 then
    kind = "arrows"
  elseif low:find("shot", 1, true) or low:find("bullet", 1, true) or subclass == 3 then
    kind = "bullets"
  end
  return kind, texture
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

  -- The red X over the equipped projectile's own icon: "no arrows"/"no ammo".
  cross = frame:CreateTexture(nil, "OVERLAY")
  cross:SetAllPoints(frame)
  cross:SetTexture(RED_X)

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
  local kind, tex = AmmoType(id)
  if tier > 0 and now >= lastWarn + PERIOD[tier] then
    lastWarn = now
    shownUntil = now + DURA[tier]
    local c = TIER_COLOR[tier]
    icon:SetTexture(tex or ARROW_ICON)
    if tier == 4 then
      label:SetText(kind == "arrows" and "NO ARROWS!" or "NO AMMO!")
    else
      label:SetText("AMMO: " .. n)
    end
    label:SetTextColor(c[1], c[2], c[3])
    frame:SetShown(true)
    -- Sound policy: sting ONLY on a worsening (first entry or escalation);
    -- the empty tier speaks, but at most once per VOICE_COOLDOWN.
    if db.sound then
      if tier == 4 then
        if now >= lastVoice + VOICE_COOLDOWN then
          lastVoice = now
          if not VoiceSound(kind) then WarnSound() end
        end
      elseif tier > lastTier then
        WarnSound()
      end
    end
  end
  if tier == 0 then lastVoice = 0 end
  lastTier = tier
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
