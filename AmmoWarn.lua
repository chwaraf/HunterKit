--[[==============================================================================
 HunterKit — Low Ammo Warning (F5)
 A periodic on-screen + sound warning when the equipped ammo (arrows/bullets)
 runs low. Modelled on the community's ammo trackers (Kals ClassicAmmoCount's
 configurable threshold, the WeakAura "3/2/1 stacks left" milestones) but tuned
 the way the user asked: periodic, and MORE persistent the less ammo is left.

 Audible half (user: DISTINCT and RARE): short bundled voice clips speak the
 situation -- "Low arrows!"/"Low ammo!" when the count gets WORSE (first
 entry or tier escalation), "No arrows!"/"No ammo!" when the slot is empty,
 at most once per 60 s while low and 45 s when empty (both divided by the
 Warn frequency option; 45 s is the floor for ANY voice), matching the
 equipped projectile. VOICE ONLY: no
 game sound is ever played (user), and it is OFF BY DEFAULT. Periodic
 re-warns are visual only. No TTS API on the client, so the clips ship in
 Media\ as .ogg (the engine's mp3 decoder cut words off).
==============================================================================]]
local _, HK = ...

local AmmoWarn = {}
HK.AmmoWarn = AmmoWarn

local db
local frame, icon, cross, label
-- Start deeply negative, NOT at 0: GetTime() counts from client start, so on
-- a fresh login "now >= 0 + PERIOD" stays false and the first warning (and
-- voice) would sit silent for up to a full period -- the "no warning when the
-- addon first loads" bug. -3600 means "never warned yet, warn at once".
local lastWarn = -3600
local lastVoice = -3600
local shownUntil = 0
-- Inventory-sync gate: right after login/reload BOTH GetInventoryItemID and
-- GetInventorySlotLink transiently return nil while the client syncs. Reading
-- that as "nothing equipped" fired a false "NO AMMO" warning (and voice) with
-- a full quiver. Until the inventory has PROVABLY synced, a nil slot read
-- means "unknown" -- never zero.
local invReady = false
local pewTicks = 0

-- Voice cooldowns, scaled by the frequency option: 45 s is the user's floor
-- for ANY voice (the icon may repeat more often; the voice must not spam).
-- Cooldown-driven, NOT escalation-driven: the old "only when the tier gets
-- worse" rule was fragile on the live client (bag-update-driven re-warns,
-- cold sound cache) and the user often never heard the low call at all.
local VOICE_COOLDOWN = 45
local LOW_VOICE_COOLDOWN = 60

local ARROW_ICON  = "Interface\\Icons\\INV_Arrow_02"
local BULLET_ICON = "Interface\\Icons\\INV_Ammo_Bullet_03"
local RED_X       = "Interface\\Buttons\\UI-GroupLoot-Pass-Up"
local MEDIA       = "Interface\\AddOns\\HunterKit\\Media\\"
-- .ogg, NOT .mp3: the classic-era engine's mp3 decoder is flaky -- every mp3
-- take stopped mid-word in game, even untouched ones. Ogg vorbis is what
-- addon sounds universally ship as and decodes reliably on every client.
local VOICE = { arrows      = MEDIA .. "voice_noarrows.ogg",
                bullets     = MEDIA .. "voice_noammo.ogg",
                low_arrows  = MEDIA .. "voice_lowarrows.ogg",
                low_bullets = MEDIA .. "voice_lowammo.ogg" }

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

-- Is the inventory API awake yet? During a loading screen every slot reads nil;
-- once the client has synced, the main-hand (or any equipped slot) answers. We
-- ask about a slot we do NOT warn on, so this is a pure liveness probe.
local function SlotApiAwake()
  if not GetInventoryItemID then return false end
  for _, s in ipairs({ 16, 17, 5, 1 }) do     -- main hand, off hand, chest, head
    local ok, v = pcall(GetInventoryItemID, "player", s)
    if ok and v then return true end
  end
  -- Nothing equipped anywhere is possible but vanishingly rare on a hunter with
  -- a ranged weapon; fall back to the link API before giving up.
  if GetInventorySlotLink then
    local ok, link = pcall(GetInventorySlotLink, "player", 16)
    if ok and type(link) == "string" then return true end
  end
  return false
end

local function AmmoCount()
  local slot = AmmoSlot()
  if not slot then return nil, nil end
  local id
  if GetInventoryItemID then
    local ok, v = pcall(GetInventoryItemID, "player", slot)
    if ok then id = v end
  end
  -- Belt & braces: if the id API comes back empty, parse the slot link.
  -- Otherwise a client quirk reads as "nothing equipped" and the warning
  -- shouts "No ammo!" (tier 4) while the quiver is still half full.
  if not id and GetInventorySlotLink then
    local ok, link = pcall(GetInventorySlotLink, "player", slot)
    if ok and type(link) == "string" then
      id = tonumber(link:match("item:(%d+)"))
    end
  end
  if id then invReady = true end     -- a real read: the inventory has synced
  if not id then
    -- No ammo id. That is only "nothing equipped" if the inventory API is
    -- actually answering right now. During a loading screen (hearthstone, zone
    -- change) EVERY slot reads nil for a few frames, and invReady may still be
    -- set from before the load -- so the flag alone is not enough. Re-prove
    -- liveness against a slot we never warn on before believing the empty read.
    if not invReady or not SlotApiAwake() then
      invReady = false               -- went cold again; make it re-prove itself
      return nil, nil                -- no opinion, no warning
    end
    return 0, nil end                -- slot exists but nothing equipped
  local n = 0
  if GetItemCount then
    local ok, c = pcall(GetItemCount, id)
    if ok and type(c) == "number" then n = c end
  end
  if n == 0 and GetInventoryItemCount then
    local ok, ec = pcall(GetInventoryItemCount, "player", slot)
    if ok and type(ec) == "number" and ec > 0 then n = ec end
  end

  -- A count of ZERO for ammo that is still EQUIPPED is a contradiction, and
  -- always a stale cache -- never a real state.
  --
  -- This is the other half of the loading-screen problem, and why the false
  -- "NO AMMO" survived the previous two fixes: those guarded the SLOT api (id
  -- reads nil), but after a hearthstone the id comes back fine while
  -- GetItemCount still answers 0 for a second or two.
  --
  -- The client just told us the item id of the thing in the ammo slot, so that
  -- item exists and its count is at least 1. When you genuinely fire your last
  -- arrow the slot EMPTIES and the id goes nil -- which is the `not id` branch
  -- above, and still warns correctly. So "valid id, zero count" can only be the
  -- bag cache lagging, and reporting it as an empty quiver is never right.
  if n == 0 then return nil, id end   -- no opinion; the next tick will know

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
-- Memoised per item id: GetItemInfo is the only non-trivial call in the 1 s
-- tick path, and the equipped ammo id changes rarely (CPU-friendly ticks).
local typeId, typeKind, typeTex
local function AmmoType(id)
  if not id then return nil, nil end
  if id == typeId then return typeKind, typeTex end
  if not GetItemInfo then return nil, nil end
  local ok, name, _, _, _, _, subclass, _, _, _, texture = pcall(GetItemInfo, id)
  if not ok then return nil, nil end
  -- Item cache not warm yet (login): return "unknown" WITHOUT caching it, so
  -- the next tick retries. Caching the miss pinned arrows to the generic
  -- fallback icon/voice for the whole session.
  if type(name) ~= "string" or name == "" then return nil, nil end
  local low = name:lower()
  local kind
  if low:find("arrow", 1, true) or subclass == 2 then
    kind = "arrows"
  elseif low:find("shot", 1, true) or low:find("bullet", 1, true) or subclass == 3 then
    kind = "bullets"
  end
  typeId, typeKind, typeTex = id, kind, texture
  return kind, texture
end

-- ---------------------------------------------------------------------------
-- Build / position
-- ---------------------------------------------------------------------------
local function BuildFrame()
  frame = CreateFrame("Frame", "HunterKitAmmoWarn", UIParent)
  frame:SetFrameStrata("HIGH")
  HK.RegisterWidget("ammo", frame)
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

  -- Pulse while shown (user): the whole warning breathes at ~1 Hz so it
  -- reads as an active alert, not a stale icon. OnUpdate only runs while
  -- the frame is shown, so it costs nothing between warnings.
  local pulseT = 0
  frame:SetScript("OnUpdate", function(self, elapsed)
    pulseT = pulseT + (elapsed or 0.03)
    self:SetScale(1 + 0.12 * math.sin(pulseT * 6.0))
  end)

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
  -- Safety net for a genuinely EMPTY ammo slot: if no sync proof ever
  -- arrives, believe the empty read after ~10 ticks so that case still warns.
  if not invReady then
    pewTicks = pewTicks + 1
    -- Only believe a persistently-empty read once the slot API is answering at
    -- all. If it is still returning nil we are mid-sync, not out of ammo, and
    -- the counter must not run the gate down. GetInventoryItemID answers for
    -- ANY equipped item, so the ranged slot being empty is a real answer while
    -- the whole API being cold is not.
    if pewTicks > 10 and SlotApiAwake() then invReady = true end
  end
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
  local freq = math.max(1, db.frequency or 1)   -- user's frequency multiplier
  local kind, tex = AmmoType(id)
  if tier > 0 and now >= lastWarn + PERIOD[tier] / freq then
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
    -- Sound policy: ONLY the bundled voice -- never a game sound (user).
    -- Cooldown-driven so the low call is GUARANTEED to be heard while the
    -- situation lasts: low tiers speak at most once per LOW_VOICE_COOLDOWN,
    -- the empty tier per VOICE_COOLDOWN, both scaled by the frequency option.
    if db.sound then
      local cd = (tier == 4 and VOICE_COOLDOWN or LOW_VOICE_COOLDOWN) / freq
      if now >= lastVoice + cd then
        lastVoice = now
        if tier == 4 then
          VoiceSound(kind == "arrows" and "arrows" or "bullets")
        else
          VoiceSound(kind == "arrows" and "low_arrows" or "low_bullets")
        end
      end
    end
  end
  if tier == 0 then
    -- Fresh-episode arming: when the ammo is back above the threshold, clear
    -- the warn timer too, so the NEXT time the threshold is reached the
    -- warning (and its voice) fires that very tick -- no waiting out a
    -- period left over from the previous episode.
    lastWarn = 0
    lastVoice = 0
  end
  if now > shownUntil then
    frame:SetShown(false)
  end
end

-- (Re)arm after login/reload/zone: forget any previous episode so a player
-- who logs in already low on ammo is warned on the very first tick.
function AmmoWarn.Rearm()
  lastWarn = -3600
  lastVoice = -3600
  invReady = false   -- new world entry: inventory must prove itself again
  pewTicks = 0
  Tick()
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

  -- NEITHER of these may declare the inventory ready by itself.
  --
  -- Both fire during a loading screen (hearthstone, zone change) while
  -- GetInventoryItemID/GetInventorySlotLink still return nil. Forcing
  -- invReady = true there defeated the very gate that exists to stop a nil read
  -- being treated as "nothing equipped" -- which is how a false "NO AMMO!"
  -- appeared after hearthing with a full quiver. Only a REAL slot read may set
  -- the flag (see AmmoCount), so these just prompt a re-check.
  HK.On("BAG_UPDATE_DELAYED", function() lastWarn = 0; Tick() end)
  -- UNIT_INVENTORY_CHANGED, not ..._UPDATE: the latter has never existed, and
  -- RegisterEvent throws on an unknown name, which aborted this whole module.
  HK.On("UNIT_INVENTORY_CHANGED", Tick)
  HK.On("PLAYER_ENTERING_WORLD", AmmoWarn.Rearm)

  HK.Ticker(1, Tick)
  Tick()
end

HK.RegisterModule("AmmoWarn", { Init = AmmoWarn.Init })
