--[[==============================================================================
 HunterKit — Pet Aggro Warning ("your pet is about to lose the mob to you")

 Warns, before it happens, that YOUR threat is closing on YOUR PET's threat on a
 mob the pet is currently tanking -- the moment to stop shooting, Feign Death,
 or let Growl catch up.

 ------------------------------------------------------------------------------
 WHY THIS DOES NOT PARSE THE COMBAT LOG
 ------------------------------------------------------------------------------
 The famous answer to "threat in Classic" is LibThreatClassic2 / ThreatClassic2 /
 Details TinyThreat: rebuild every unit's threat from COMBAT_LOG_EVENT_UNFILTERED
 by applying per-spell threat coefficients, talents, buffs and stance modifiers,
 then addon-comm the result around the group. That machinery exists because the
 threat API was cut from the 1.13.0 launch client.

 It was PUT BACK. Patch 1.13.5 (2020-07-07) "Reinstated Threat API and increased
 the combat log range in dungeons and raids - to reduce the need for addon
 comms", adding three functions and two events:

     UnitThreatSituation, UnitDetailedThreatSituation, UnitThreatPercentageOfLead
     UNIT_THREAT_LIST_UPDATE, UNIT_THREAT_SITUATION_UPDATE

 Warcraft Wiki's game-type table lists all of them as live in classic era
 (1.15.x) and in bcc anniversary (2.5.x), which is exactly this addon's target
 (## Interface: 11509). So the server will simply TELL us the threat numbers.

 That matters enormously for the "as light as possible but still reliable" brief:

   * a combat-log estimator must process every damage/heal/aura event in the
     zone, hold a coefficient table per class and spell, watch talents and
     buffs, and STILL only guesses -- it silently mis-reads anything it has no
     coefficient for, and it cannot see other players at all unless they run a
     compatible addon.
   * the server's own numbers are exact, cost one function call, need no comms,
     no coefficient table, and cannot drift.

 This module therefore registers ZERO combat-log events and keeps no per-spell
 data whatsoever.

 ------------------------------------------------------------------------------
 THE MEASUREMENT
 ------------------------------------------------------------------------------
 UnitDetailedThreatSituation(unit, mobUnit) returns

     isTanking, status, scaledPercentage, rawPercentage, threatValue

 `scaledPercentage` is precisely the question this feature asks. Blizzard: "The
 unit's threat percentage against mobUnit. At 100% the unit will become the
 primary target. This value is also scaled the closer the unit is to the
 mobUnit."

 So it already folds in the melee/ranged pull rule that every Classic threat
 guide quotes -- 110% of the tank's threat to pull in melee, 130% at range --
 including the awkward middle case where a hunter steps forward mid-fight and
 their pull threshold silently drops from 130% to 110%. A hand-rolled
 `myThreat / petThreat` ratio would have to model that distance scaling itself,
 and would be wrong every time the hunter moved. We let the server do it.

 The warning condition is then exactly:

     the PET is the mob's primary target        (petIsTanking)
     AND the PLAYER's scaledPercentage >= the threshold

 and the "too late" condition is `playerIsTanking` -- the mob has already
 switched to you.

 ------------------------------------------------------------------------------
 WHICH MOBS ARE CHECKED, AND WHY ONLY THOSE
 ------------------------------------------------------------------------------
 Threat is per-mob, so something must be polled. The candidates are "target",
 "pettarget", and nameplateN.

 This module checks "pettarget" and "target" ONLY -- two calls, deduplicated by
 GUID, so usually two and often one. Rationale: the mob that can rip off the pet
 is by definition a mob the pet is tanking, and the pet's own target is that mob.
 "target" is added because a hunter frequently shoots a second mob the pet is
 also holding. Sweeping up to 40 nameplates would multiply the cost by twenty for
 mobs the pet mostly is not tanking, and nameplate range in Classic is short
 enough that it is not even a reliable superset.

 ------------------------------------------------------------------------------
 HOW OFTEN
 ------------------------------------------------------------------------------
 Event-driven first: UNIT_THREAT_LIST_UPDATE fires whenever the server sends new
 threat data. But the wiki documents that it fires for "target" and "nameplateX"
 and NOT for units like "targettarget" -- and in practice not for "pettarget" --
 "therefore, threat addons ... may need to periodically poll". So there is also
 a slow backstop ticker.

 The ticker only exists while it can possibly matter: the player is in combat and
 has a living pet. Out of combat, or with no pet, it is cancelled outright, so the
 idle cost of this module is exactly zero. Evaluations are throttled to
 MIN_INTERVAL regardless of how many events arrive, so an event storm in a raid
 cannot turn into a work storm.
==============================================================================]]
local _, HK = ...

local ThreatWatch = {}
HK.ThreatWatch = ThreatWatch

local db

-- The mob units worth asking about (see the header). Order matters: pettarget
-- is the likelier answer, so it is asked first and usually makes the second
-- call a GUID-deduplicated no-op.
local MOB_UNITS = { "pettarget", "target" }

local MIN_INTERVAL = 0.15   -- hard floor between evaluations, however many events
-- Backstop poll while in combat with a pet. Deliberately NOT equal to any other
-- module's ticker interval, so a ticker can always be identified by its rate.
local POLL_INTERVAL = 0.40
local HIDE_AFTER    = 2.5   -- keep the alert up this long after the danger ends

-- Alert states, worst last -- Pick() relies on this ordering.
local STATE_RANK = { warn = 1, pulled = 2 }

local ICON_WARN   = "Interface\\Icons\\Ability_Physical_Taunt"
local ICON_PULLED = "Interface\\Icons\\Ability_Hunter_FeignDeath"

local frame, icon, label, sub
local lastEval, lastSound = 0, -3600
local current, shownUntil = nil, 0
local ticker = nil

-- ---------------------------------------------------------------------------
-- Client API compat. Every call is pcall-guarded: a client without the threat
-- API must degrade to "feature unavailable", never throw mid-combat.
-- ---------------------------------------------------------------------------
local function Call(fn, ...)
  if type(fn) ~= "function" then return nil end
  local res = { pcall(fn, ...) }
  if not res[1] then return nil end
  return unpack(res, 2, #res)
end

-- Is the reinstated (1.13.5+) threat API actually present on this client?
-- Checked at call time rather than cached at load, because the addon may load
-- before the function table is fully populated on some clients.
function ThreatWatch.HasAPI()
  return type(UnitDetailedThreatSituation) == "function"
end

-- ---------------------------------------------------------------------------
-- One mob's verdict.
--
-- Returns state, pct  |  nil
--   "pulled" -- the player is already the mob's primary target (too late)
--   "warn"   -- the PET is tanking and the player is at/over the threshold
--
-- `scaledPercentage` is nil whenever the unit is not on that mob's threat
-- table, which is also how Blizzard reports "the pet is fighting it but you
-- have done nothing to it". That is the correct time to stay silent: a player
-- with no threat cannot pull anything.
-- ---------------------------------------------------------------------------
local function JudgeMob(unit)
  local myTanking, _, myScaled = Call(UnitDetailedThreatSituation, "player", unit)
  if myScaled == nil then return nil end
  myScaled = tonumber(myScaled) or 0

  if myTanking then return "pulled", 100 end

  -- Only a mob the PET is holding can be "lost by the pet". If a real tank (or
  -- another player) has it, the pet is not the one about to lose it and this
  -- feature has no opinion -- that is a threat meter's job, not a pet warning.
  local petTanking = Call(UnitDetailedThreatSituation, "pet", unit)
  if not petTanking then return nil end

  local threshold = tonumber(db and db.threshold) or 80
  if myScaled >= threshold then return "warn", myScaled end
  return nil
end

-- ---------------------------------------------------------------------------
-- The whole judgement. Pure apart from reading the client, so tests drive it
-- directly and the slash diagnostic prints exactly what the alert acts on.
--
-- Returns state, pct, unit, mobName  |  nil, reason
-- ---------------------------------------------------------------------------
function ThreatWatch.Evaluate()
  if not db or db.enabled == false then return nil, "pet aggro warning is off" end
  if HK.db.enabled == false then return nil, "HunterKit is off" end
  if not HK.isHunter then return nil, "not a hunter" end
  if not ThreatWatch.HasAPI() then
    -- Pre-1.13.5 client, or a stripped environment. Say so plainly rather than
    -- quietly never warning.
    return nil, "this client has no threat API (needs 1.13.5+)"
  end
  if not Call(UnitExists, "pet") then return nil, "no pet" end
  if Call(UnitIsDeadOrGhost, "pet") then return nil, "pet is dead" end
  if not Call(UnitAffectingCombat, "player") and not Call(UnitAffectingCombat, "pet") then
    return nil, "not in combat"
  end

  local bestState, bestPct, bestUnit
  local seen = {}
  for _, unit in ipairs(MOB_UNITS) do
    if Call(UnitExists, unit) and not Call(UnitIsDead, unit)
       and Call(UnitCanAttack, "player", unit) then
      -- Deduplicate by GUID: "pettarget" and "target" are the same mob most of
      -- the time, and asking twice is pure waste. A client with no UnitGUID
      -- falls back to asking both, which is merely redundant, never wrong.
      local guid = Call(UnitGUID, unit)
      if guid == nil or not seen[guid] then
        if guid then seen[guid] = true end
        local state, pct = JudgeMob(unit)
        if state then
          local rank, bestRank = STATE_RANK[state], STATE_RANK[bestState or ""] or 0
          -- Worst state wins; within the same state, the closest call wins.
          if rank > bestRank or (rank == bestRank and (pct or 0) > (bestPct or 0)) then
            bestState, bestPct, bestUnit = state, pct, unit
          end
        end
      end
    end
  end

  if not bestState then return nil, "pet threat is safe" end
  return bestState, bestPct, bestUnit, Call(UnitName, bestUnit)
end

-- ---------------------------------------------------------------------------
-- The alert widget
-- ---------------------------------------------------------------------------
local function Build()
  if frame or not CreateFrame then return end
  frame = CreateFrame("Frame", "HunterKitThreatAlert", UIParent)
  frame:SetFrameStrata("HIGH")
  frame:SetSize(64, 64)
  frame:Hide()

  icon = frame:CreateTexture(nil, "ARTWORK")
  icon:SetAllPoints(frame)
  icon:SetTexture(ICON_WARN)

  label = frame:CreateFontString(nil, "OVERLAY")
  -- Font BEFORE text: SetText on a font-less FontString throws
  -- "FontString:SetText(): Font not set" on the live client.
  label:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 18, "OUTLINE")
  label:SetPoint("BOTTOM", frame, "TOP", 0, 4)
  label:SetText("")

  sub = frame:CreateFontString(nil, "OVERLAY")
  sub:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
  sub:SetPoint("TOP", frame, "BOTTOM", 0, -3)
  sub:SetText("")

  ThreatWatch.ApplyPosition()

  HK.RegisterDraggable("threat", frame, ThreatWatch.ApplyPosition, function(x, y)
    db.offsetX, db.offsetY = x, y
  end, {
    saveFromScreen = function() HK.SaveDragged(frame, db) end,
  })
end

function ThreatWatch.ApplyPosition()
  if not frame or not db then return end
  local size = tonumber(db.size) or 56
  frame:SetSize(size, size)
  frame:ClearAllPoints()
  frame:SetPoint("CENTER", UIParent, "CENTER",
    tonumber(db.offsetX) or 0, tonumber(db.offsetY) or 120)
end

-- The audible half. Rate-limited independently of the visual, because the
-- visual may legitimately stay up for a whole fight while a sound repeating at
-- that rate would be unbearable.
local function Alarm(state)
  if not db or db.sound == false then return end
  local now = tonumber(Call(GetTime)) or 0
  local gap = tonumber(db.soundInterval) or 4
  if now - lastSound < gap then return end
  lastSound = now
  -- PlaySound with a UI sound kit is the cheapest option and needs no shipped
  -- media; PlaySoundFile is the fallback for clients/stubs without SOUNDKIT.
  local kit = SOUNDKIT and (state == "pulled" and SOUNDKIT.RAID_WARNING
                                              or SOUNDKIT.IG_QUEST_FAILED)
  if kit and PlaySound then
    Call(PlaySound, kit, db.channel or "Master")
  elseif PlaySoundFile then
    Call(PlaySoundFile, "Sound\\Interface\\RaidWarning.ogg", db.channel or "Master")
  end
end

local function Show(state, pct, mobName)
  if not frame then return end
  if state == "pulled" then
    icon:SetTexture(ICON_PULLED)
    label:SetText("|cffff2020AGGRO — Feign Death!|r")
    sub:SetText(mobName and ("on " .. mobName) or "")
  else
    icon:SetTexture(ICON_WARN)
    label:SetFormattedText("|cffffcc00Pet losing aggro — %d%%|r", math.floor(pct or 0))
    sub:SetText(mobName and ("on " .. mobName) or "")
  end
  frame:Show()
  shownUntil = (tonumber(Call(GetTime)) or 0) + HIDE_AFTER
end

local function Hide()
  if frame then frame:Hide() end
  current = nil
end

-- ---------------------------------------------------------------------------
-- The tick. Throttled, and cheap enough to be called from anything.
-- ---------------------------------------------------------------------------
local function Evaluate(force)
  local now = tonumber(Call(GetTime)) or 0
  if not force and (now - lastEval) < MIN_INTERVAL then return end
  lastEval = now

  -- Edit mode: hold the frame visible so it can be dragged into place.
  if HK.Editing and HK.Editing() then
    if frame then
      icon:SetTexture(ICON_WARN)
      label:SetText("|cffffcc00Pet losing aggro — 85%|r")
      sub:SetText("(preview)")
      frame:Show()
    end
    return
  end

  local state, pct, _, mobName = ThreatWatch.Evaluate()
  if state then
    -- Only re-alarm on a NEW state (safe -> warn, or warn -> pulled), never on
    -- every tick that the same state persists.
    if state ~= current then
      current = state
      Alarm(state)
    end
    Show(state, pct, mobName)
    return
  end

  -- Danger over. Linger briefly rather than blinking out the instant a number
  -- dips back under the threshold, which would strobe on a borderline fight.
  current = nil
  if frame and frame:IsShown() and now >= shownUntil then Hide() end
end
ThreatWatch.Tick = Evaluate

-- ---------------------------------------------------------------------------
-- The ticker exists ONLY while it can matter (in combat, pet alive). This is
-- the whole "as light as possible" story: out of combat the module costs
-- nothing at all -- no timer, no polling, only the cheap event handlers.
-- ---------------------------------------------------------------------------
local function ShouldPoll()
  if not db or db.enabled == false then return false end
  if not HK.isHunter or not ThreatWatch.HasAPI() then return false end
  if not Call(UnitExists, "pet") or Call(UnitIsDeadOrGhost, "pet") then return false end
  return Call(UnitAffectingCombat, "player") == true
      or Call(UnitAffectingCombat, "pet") == true
end

local function SyncTicker()
  local want = ShouldPoll()
  if want and not ticker then
    ticker = HK.Ticker(POLL_INTERVAL, function() Evaluate() end)
  elseif not want and ticker then
    if ticker.Cancel then pcall(ticker.Cancel, ticker) end
    ticker = nil
    Hide()
  end
end
ThreatWatch.SyncTicker = SyncTicker
function ThreatWatch.IsPolling() return ticker ~= nil end
function ThreatWatch.IsShown() return frame ~= nil and frame:IsShown() == true end

-- ---------------------------------------------------------------------------
-- Diagnostics (/htk threat)
-- ---------------------------------------------------------------------------
function ThreatWatch.PrintDiag()
  print("|cff39ff14HunterKit|r pet aggro warning diagnostics:")
  print("  threat API: " .. (ThreatWatch.HasAPI()
    and "present (1.13.5+ reinstated API)" or "MISSING -- feature cannot run"))
  print("  polling: " .. tostring(ticker ~= nil))
  for _, unit in ipairs(MOB_UNITS) do
    if Call(UnitExists, unit) then
      local myTank, myStatus, myScaled = Call(UnitDetailedThreatSituation, "player", unit)
      local petTank, petStatus, petScaled = Call(UnitDetailedThreatSituation, "pet", unit)
      print(string.format("  %s (%s): you %s%% status=%s tanking=%s | pet %s%% status=%s tanking=%s",
        unit, tostring(Call(UnitName, unit)),
        tostring(myScaled and math.floor(myScaled) or "-"), tostring(myStatus), tostring(myTank),
        tostring(petScaled and math.floor(petScaled) or "-"), tostring(petStatus), tostring(petTank)))
    else
      print("  " .. unit .. ": none")
    end
  end
  local state, pct, unit, name = ThreatWatch.Evaluate()
  if state then
    print(string.format("  verdict: %s at %d%% on %s (%s)", state, math.floor(pct or 0),
      tostring(name), tostring(unit)))
  else
    print("  verdict: no warning -- " .. tostring(pct))
  end
end

function ThreatWatch.RescanSettings()
  db = HK.db.threat
  ThreatWatch.ApplyPosition()
  SyncTicker()
  Evaluate(true)
end

function ThreatWatch.Init()
  db = HK.db.threat
  if not HK.isHunter then return end       -- structural gate: no hunter, no feature

  Build()

  -- Event-driven where the client cooperates...
  HK.On("UNIT_THREAT_LIST_UPDATE", function() Evaluate() end)
  HK.On("UNIT_THREAT_SITUATION_UPDATE", function() Evaluate() end)

  -- ...and the ticker's lifecycle, which is what keeps the idle cost at zero.
  HK.On("PLAYER_REGEN_DISABLED", function() SyncTicker(); Evaluate(true) end)
  HK.On("PLAYER_REGEN_ENABLED", function() SyncTicker() end)
  HK.On("UNIT_PET", function() SyncTicker() end)
  HK.On("PLAYER_ENTERING_WORLD", function() SyncTicker() end)

  SyncTicker()
end

HK.RegisterModule("ThreatWatch", { Init = ThreatWatch.Init })
