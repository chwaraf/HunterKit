--[[==============================================================================
 HunterKit — Gun sound replacement (F3)
 Two halves:
   1. Watch the player's UNIT_SPELLCAST_SUCCEEDED and play a custom "pew" the
      moment the Auto Shot (spellID 75) releases — i.e. when the gun actually
      fires — not when the projectile lands.
   2. Mute the stock gunshot with MuteSoundFile() (session-only).
 The engine plays the stock sound in C++ so no Lua hook can intercept it; the
 UNIT_SPELLCAST_SUCCEEDED trigger + mute is the only clean way. We deliberately
 key off the *launch* event (spell 75), NOT the combat-log RANGE_DAMAGE subevent:
 RANGE_DAMAGE is logged when the shot lands on the target, which trails the
 muzzle flash by the projectile travel time — that is why the pew used to lag
 the gun fire by up to ~1s. UNIT_SPELLCAST_SUCCEEDED for Auto Shot fires at the
 moment the missile leaves the weapon, keeping the pew locked to the shot.
 Only Auto Shot (75) is used, so Multi-Shot / Arcane Shot keep their own audible
 spell sounds and are never overridden by the pew.
==============================================================================]]
local _, HK = ...

local Sounds = {}
HK.Sounds = Sounds

local db
local lastPlay, lastVariant = 0, nil
local cachedType
local playedMutes = {}
local mediaCount = 0
local castsSeen, pewsPlayed = 0, 0   -- spell-cast diagnostics
-- forward declarations (defined later in this chunk)
local OnSpellCastSucceeded, NextVariant

local AUTO_SHOT = 75                  -- spellID for Auto Shot (launch moment)

-- ---------------------------------------------------------------------------
-- Init + events
-- ---------------------------------------------------------------------------
function Sounds.Init()
  db = HK.db.sound
  if not HK.isHunter then return end -- structural gate: no CLEU, no mutes

  Sounds.MediaCount()

  -- Fire the pew on the player's Auto Shot RELEASE. `UNIT_SPELLCAST_SUCCEEDED`
  -- with spellID 75 fires the instant the projectile leaves the weapon, which is
  -- the gun-fire moment (the same instant the stock gunshot is heard). This is
  -- the fix for the pew trailing the shot: RANGE_DAMAGE (the old trigger) is the
  -- damage-landing event and trails the muzzle flash by the projectile's travel
  -- time, which is why the pew used to lag the gun by up to ~1s. The audio files
  -- decode once per session on first use; we deliberately do NOT play a cache-warm
  -- pre-load here (it would be audible at login).
  HK.On("UNIT_SPELLCAST_SUCCEEDED", OnSpellCastSucceeded)
  HK.On("PLAYER_EQUIPMENT_CHANGED", function() RangedWeaponInfo(true) end)
  -- Mutes are session-wide in C++ (they survive /reload until a full restart).
  -- If the stock-mute is ON, apply it; if it's OFF, defensively unmute the
  -- configured IDs so a mute left over from a prior toggle or a previous build
  -- is cleaned up. UnmuteSoundFile on a non-muted file is a harmless no-op.
  HK.On("PLAYER_ENTERING_WORLD", function()
    if HK.db.sound.muteOriginal then
      Sounds.ApplyMutes()
    else
      Sounds.UnmuteAll()
    end
  end)
end

function Sounds.RescanSettings()
  db = HK.db.sound
  if db.muteOriginal then
    Sounds.ApplyMutes()
  else
    Sounds.UnmuteAll()             -- turning the mute off restores the stock sound
  end
end

-- ---------------------------------------------------------------------------
-- Auto Shot launch trigger
-- ---------------------------------------------------------------------------
-- `UNIT_SPELLCAST_SUCCEEDED` fires once per player spell cast. We only act on
-- the Auto Shot (spellID 75) — the gun-shot launch moment. Multi-Shot, Arcane
-- Shot, Aimed Shot etc. use different spellIDs, so they pass through untouched
-- and keep their own audible spell sounds (we never override them).
OnSpellCastSucceeded = function(unit, castGUID, spellID)
  if not HK.db.enabled or not db.enabled then return end      -- master + feature off
  if unit ~= "player" then return end                         -- only our own shots
  if spellID ~= AUTO_SHOT then return end                     -- 75 = Auto Shot launch
  castsSeen = castsSeen + 1

  local wt = RangedWeaponInfo()
  -- Only apply the gunsOnly filter when we actually know the weapon is a
  -- non-gun. If we can't determine the type (nil), DON'T block — otherwise a
  -- failed weapon lookup would silently kill the sound.
  if db.gunsOnly and wt and wt ~= "gun" then return end

  local now = GetTime()
  if now - lastPlay < db.minInterval then return end          -- per-shot spam guard
  lastPlay = now

  local v = NextVariant()
  if v then
    pewsPlayed = pewsPlayed + 1
    PlaySoundFile(("Interface\\AddOns\\HunterKit\\Media\\%s.ogg"):format(v), db.channel)
    if HK.debug then
      print("|cff39ff14HunterKit|r pew (" .. v .. ")")
    end
  end
end

NextVariant = function()
  local variants = db.variants
  if not variants or #variants == 0 then return nil end
  local v = variants[math.random(#variants)]
  if db.noRepeat and #variants > 1 then
    local guard = 0
    while v == lastVariant and guard < 100 do
      v = variants[math.random(#variants)]
      guard = guard + 1
    end
  end
  lastVariant = v
  return v
end

-- Classify the ranged weapon into "gun" / "bow" / "crossbow" / nil.
-- Prefers the numeric itemClass/subclass (C_Item/GetItemInfoInstant on the new
-- client: weapon=2, gun=3, bow=2, crossbow=18), and falls back to the localized
-- item-type strings from GetItemInfo so it works even if GetItemInfoInstant is
-- absent or returns unexpected values. Returns a string or nil (unknown).
function RangedWeaponInfo(refresh)
  if refresh then cachedType = nil end
  if cachedType then return cachedType end
  local itemID = GetInventoryItemID("player", 18)   -- 18 = ranged slot
  if not itemID then return nil end
  local wt
  if GetItemInfoInstant then
    local ok, _, _, _, _, _, classID, subClassID = pcall(GetItemInfoInstant, itemID)
    if ok and classID == 2 then
      if subClassID == 3 then wt = "gun"
      elseif subClassID == 2 then wt = "bow"
      elseif subClassID == 18 then wt = "crossbow"
      end
    end
  end
  if not wt then
    local _, _, _, _, _, _, itemSubType = HK.GetItemInfo(itemID)
    if itemSubType then
      local s = itemSubType:lower()
      if s:find("gun") then wt = "gun"
      elseif s:find("crossbow") then wt = "crossbow"
      elseif s:find("bow") then wt = "bow"
      end
    end
  end
  cachedType = wt
  return wt
end

-- ---------------------------------------------------------------------------
-- Muting the stock gunshot
-- ---------------------------------------------------------------------------
function Sounds.ApplyMutes()
  if not HK.isHunter then return end
  if not db.muteOriginal then return end
  for _, fid in ipairs(db.mutedFileIDs) do
    if type(fid) == "number" and not playedMutes[fid] then
      local ok = pcall(MuteSoundFile, fid)
      if ok then playedMutes[fid] = true end
    end
  end
end

function Sounds.UnmuteAll()
  -- Unmute every ID we muted this session...
  for fid in pairs(playedMutes) do
    pcall(UnmuteSoundFile, fid)
    playedMutes[fid] = nil
  end
  -- ...plus best-effort restore of the configured mute IDs, in case we muted
  -- them in a previous session (the mute persists across reloads). Unmuting a
  -- file that isn't muted is a no-op, so this is safe.
  for _, fid in ipairs(db.mutedFileIDs or {}) do
    if type(fid) == "number" then pcall(UnmuteSoundFile, fid) end
  end
end

-- ---------------------------------------------------------------------------
-- Preview + introspection
-- ---------------------------------------------------------------------------
function Sounds.Preview()
  if not HK.isHunter then
    print("|cffff0000HunterKit|r not a hunter — no sound preview.")
    return
  end
  local variants = db.variants or {}
  for i, v in ipairs(variants) do
    C_Timer.After((i - 1) * 0.35, function()
      PlaySoundFile(("Interface\\AddOns\\HunterKit\\Media\\%s.ogg"):format(v), db.channel)
    end)
  end
end

function Sounds.MediaCount()
  if mediaCount > 0 then return mediaCount end
  local variants = db.variants or {}
  mediaCount = #variants
  return mediaCount
end

function Sounds.MutedCount()
  local n = 0
  local seen = {}
  for _, fid in ipairs(db.mutedFileIDs or {}) do
    if type(fid) == "number" and not seen[fid] then seen[fid] = true; n = n + 1 end
  end
  return n
end

-- /htk gunlist — prints exactly which FileDataIDs HunterKit is configured to
-- mute, so the player can confirm in-game and cross-check against the IDs their
-- client actually uses for the gun fire/load sounds.
function Sounds.PrintGunList()
  if not HK.isHunter then
    print("|cff39ff14HunterKit|r not a hunter — no gun mute configured.")
    return
  end
  local d = HK.db.sound
  print("|cff39ff14HunterKit|r gun mute: " .. (d.muteOriginal and "ON" or "OFF")
    .. " | " .. Sounds.MutedCount() .. " IDs:")
  local seen = {}
  for _, fid in ipairs(d.mutedFileIDs or {}) do
    if type(fid) == "number" and not seen[fid] then
      seen[fid] = true
      print("   " .. fid)
    end
  end
end

-- Diagnostic for /htk selfcheck: report the ranged-weapon detection and whether
-- the pew path would fire, plus the mute state. This tells us if the Auto Shot
-- launch event is even reaching us (the crux of "no pew / no gun sound change").
function Sounds.Diagnostic()
  local wt = RangedWeaponInfo(true)
  local weapon = wt or "none"
  local gunOK = (db.gunsOnly and wt == "gun") or (not db.gunsOnly)
  return string.format("ranged=%s | gunsOnly=%s | passesFilter=%s | muteOrig=%s | mutedIDs=%d | autoShotCasts=%d | pews=%d",
    weapon, tostring(db.gunsOnly), tostring(gunOK), tostring(db.muteOriginal),
    Sounds.MutedCount(), castsSeen, pewsPlayed)
end

HK.RegisterModule("Sounds", { Init = Sounds.Init })
