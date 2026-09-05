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

-- Readout emphasis once the number reaches the warning threshold: it grows to
-- 1.5x and pulses, so it catches the eye without the player having to read it.
-- The scale is applied to the FRAME (the FontString is anchored to it), which
-- scales the glyphs cleanly at any font size and cannot fight the anchor.
local PCT_HOT_SCALE = 1.5
local PCT_PULSE_HZ  = 3.4        -- radians/sec feed for the sine (~0.55 s cycle)
local PCT_PULSE_AMP = 0.12       -- +/- fraction of the hot scale

local ICON_WARN   = "Interface\\Icons\\Ability_Physical_Taunt"
local ICON_PULLED = "Interface\\Icons\\Ability_Hunter_FeignDeath"

local frame, icon, label, sub
local readout, readoutText
local pctHot, pctPulseT = false, 0
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
-- MEASUREMENT ONLY -- no threshold is applied here.
--
-- Split deliberately from the warning decision: the percentage readout has to
-- show a live number the whole fight, including (in fact, especially) while it
-- is comfortably low, whereas the warning only speaks past a threshold. Folding
-- the threshold in here, as an earlier cut did, meant the readout could only
-- ever display numbers that were already alarming.
--
-- Returns pct, isPulled, petTanking  |  nil
local function MeasureMob(unit)
  local myTanking, _, myScaled, _, myThreat =
    Call(UnitDetailedThreatSituation, "player", unit)
  if myScaled == nil then return nil end
  myScaled = tonumber(myScaled) or 0
  myThreat = tonumber(myThreat) or 0
  if myTanking then return 100, true, false, myThreat end

  -- Is the PET the one holding this mob? Only then can the pet "lose" it.
  local petTanking = Call(UnitDetailedThreatSituation, "pet", unit)
  return myScaled, false, (petTanking and true or false), myThreat
end

-- ---------------------------------------------------------------------------
-- HOW MUCH MORE DAMAGE WOULD PULL IT
--
-- Derived from the two numbers the server already gives us, with no assumption
-- about melee vs ranged and no per-spell modelling:
--
--   scaledPct = myThreat / pullPoint * 100      (Blizzard's definition)
--     =>  pullPoint = myThreat * 100 / scaledPct
--     =>  gap       = pullPoint - myThreat = myThreat * (100 / scaledPct - 1)
--
-- `myThreat` cancels out of the ratio, so the 110%/130% distance rule that
-- Blizzard folded into scaledPct is inherited for free -- step into melee and
-- the gap shrinks by itself. Verified algebraically against a worked pet-tank
-- case at both 1.10 and 1.30 modifiers.
--
-- UNITS. The game's threat guides are all written in the 1-damage-=-1-threat
-- normalisation, but the values the API hands back are NOT in those units:
-- from 3.0 onward the engine stores threat at 100x damage (integer math is
-- cheaper than floating point), so 500 damage reads back as 50000. Dividing by
-- THREAT_PER_DAMAGE puts the figure back into damage, which is the only unit a
-- player can act on. Without this the readout showed numbers ~100x too large --
-- "120k" where the honest answer was "1.2k".
--
-- The percentage is unaffected: it is a ratio, so the normalisation cancels.
--
-- Hunters carry no stance/spec multiplier on ordinary shots, so after the
-- rescale the gap reads directly as damage. It is an honest approximation, not
-- a promise: Growl landing, a pet crit, or the mob's own threat drops all move
-- the target while you are reading it.
--
-- Returns gap in threat/damage, or nil when it cannot be known.
-- ---------------------------------------------------------------------------
local GAP_MIN_PCT      = 1        -- below this, 100/pct explodes into nonsense
local GAP_MAX          = 9999999  -- sanity ceiling; above this reads as unknown
local THREAT_PER_DAMAGE = 100     -- API threat units per 1 point of damage

function ThreatWatch.DamageToPull(myThreat, scaledPct)
  myThreat = tonumber(myThreat) or 0
  scaledPct = tonumber(scaledPct) or 0
  if myThreat <= 0 then return nil end          -- no threat yet: nothing to scale
  if scaledPct <= GAP_MIN_PCT then return nil end
  if scaledPct >= 100 then return 0 end          -- already at/over the pull point
  local gap = myThreat * (100 / scaledPct - 1) / THREAT_PER_DAMAGE
  if gap < 0 or gap > GAP_MAX then return nil end
  return gap
end

-- Compact number for a readout that sits next to a unit frame: 940, 1.2k, 15k.
function ThreatWatch.ShortNum(n)
  n = tonumber(n) or 0
  if n >= 10000 then return string.format("%dk", math.floor(n / 1000 + 0.5)) end
  if n >= 1000 then return string.format("%.1fk", n / 1000) end
  return tostring(math.floor(n + 0.5))
end

-- ---------------------------------------------------------------------------
-- The number the readout shows: the highest aggro percentage across the mobs
-- we watch, plus whether it is already ours and the raw threat behind it.
--
-- Unlike the WARNING, this does not require the pet to be tanking -- if a real
-- tank is holding the mob you still want to see how close you are getting.
-- Returns pct, pulled, threat (all nil when there is nothing to report).
-- ---------------------------------------------------------------------------
function ThreatWatch.CurrentPct()
  if not ThreatWatch.HasAPI() then return nil end
  if not Call(UnitAffectingCombat, "player") then return nil end
  -- This is a PET module: with no living pet there is no pet-vs-player threat
  -- story to tell, so the readout stays out of the way entirely.
  if not Call(UnitExists, "pet") or Call(UnitIsDeadOrGhost, "pet") then return nil end

  local bestPct, bestPulled, bestThreat
  local seen = {}
  for _, unit in ipairs(MOB_UNITS) do
    if Call(UnitExists, unit) and not Call(UnitIsDead, unit)
       and Call(UnitCanAttack, "player", unit) then
      local guid = Call(UnitGUID, unit)
      if guid == nil or not seen[guid] then
        if guid then seen[guid] = true end
        local pct, pulled, _, myThreat = MeasureMob(unit)
        if pct and (bestPct == nil or pct > bestPct) then
          bestPct, bestPulled, bestThreat = pct, pulled, myThreat
        end
      end
    end
  end
  return bestPct, bestPulled, bestThreat
end

-- ---------------------------------------------------------------------------
-- TREND: is my threat climbing or falling?
--
-- Tracked on the PERCENTAGE rather than the raw threat value, because the
-- percentage is what the threshold is expressed in and it already accounts for
-- the pet's threat moving too: pet out-threating you shows as your percentage
-- falling, which is exactly the "danger receding" case that must stay silent.
--
-- RISE_EPSILON exists because these numbers jitter by a fraction between
-- server updates; without it, noise around a plateau reads as a rise and the
-- warning stutters. A change smaller than this counts as flat, not rising.
--
-- TREND_STALE_AFTER discards a sample from a previous fight (or from before a
-- target swap): comparing against a minutes-old percentage would invent a huge
-- fake rise on the first tick of the next pull.
-- ---------------------------------------------------------------------------
local RISE_EPSILON      = 0.5    -- percentage points; below this is "flat"
local TREND_STALE_AFTER = 3      -- seconds; older samples are not comparable

local prevPct, prevPctAt, prevKey = nil, 0, nil

-- Returns rising (bool), delta (percentage points, nil when not comparable).
local function UpdateTrend(pct, key, now)
  local rising, delta = false, nil
  -- `key` identifies WHAT is being measured (the mob). A different mob is a
  -- different series, so its history must not be compared against.
  if prevPct ~= nil and prevKey == key and (now - prevPctAt) <= TREND_STALE_AFTER then
    delta = pct - prevPct
    rising = delta > RISE_EPSILON
  end
  prevPct, prevPctAt, prevKey = pct, now, key
  return rising, delta
end

-- Exposed so the diagnostic (and tests) can see the trend the warning acted on.
function ThreatWatch.Trend()
  return prevPct, prevKey
end
function ThreatWatch.ResetTrend()
  prevPct, prevPctAt, prevKey = nil, 0, nil
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

  -- ONE pass over the mobs, collecting the measurements. Deliberately not a
  -- CurrentPct() call followed by a judging loop: that measured every mob
  -- twice per evaluation, doubling the only cost this module has.
  local now = tonumber(Call(GetTime)) or 0
  local mobs, seen = {}, {}
  local topPct, topKey = nil, nil
  for _, unit in ipairs(MOB_UNITS) do
    if Call(UnitExists, unit) and not Call(UnitIsDead, unit)
       and Call(UnitCanAttack, "player", unit) then
      -- Deduplicate by GUID: "pettarget" and "target" are the same mob most of
      -- the time, and asking twice is pure waste. A client with no UnitGUID
      -- falls back to asking both, which is merely redundant, never wrong.
      local guid = Call(UnitGUID, unit)
      if guid == nil or not seen[guid] then
        if guid then seen[guid] = true end
        local pct, pulled, petTanking = MeasureMob(unit)
        if pct then
          mobs[#mobs + 1] = { unit = unit, pct = pct, pulled = pulled,
                              petTanking = petTanking }
          if topPct == nil or pct > topPct then
            topPct, topKey = pct, guid or unit
          end
        end
      end
    end
  end

  -- Establish the trend ONCE per evaluation, from the dominant mob, and keyed
  -- to it so a target swap starts a fresh series rather than comparing two
  -- different fights. Shared across the mobs below so the verdict cannot
  -- depend on which unit happened to be judged first.
  local rising = false
  if topPct then
    rising = UpdateTrend(topPct, topKey, now)
  else
    ThreatWatch.ResetTrend()
  end

  local threshold = tonumber(db.threshold) or 80
  local bestState, bestPct, bestUnit
  for _, m in ipairs(mobs) do
    local state
    if m.pulled then
      -- Losing the mob outright is reported whatever the direction: it is a
      -- fact, not a forecast.
      state = "pulled"
    elseif m.petTanking and m.pct >= threshold and rising then
      state = "warn"
    end
    if state then
      local rank, bestRank = STATE_RANK[state], STATE_RANK[bestState or ""] or 0
      -- Worst state wins; within the same state, the closest call wins.
      if rank > bestRank or (rank == bestRank and (m.pct or 0) > (bestPct or 0)) then
        bestState, bestPct, bestUnit = state, m.pct, m.unit
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

-- ---------------------------------------------------------------------------
-- The live percentage readout, sitting above and to the RIGHT of the player
-- frame.
--
-- A separate widget from the warning alert on purpose: this one is a quiet,
-- always-on number you glance at, the other is a deliberate interruption. They
-- have separate enables, and the number is useful precisely when the warning is
-- off -- which is now the default pairing.
--
-- Parented to UIParent, never to PlayerFrame, for the same reason Range.lua
-- gives: a child of a unit frame measures its coordinates in that frame's
-- space, which breaks the drag maths. We only ANCHOR to PlayerFrame.
-- ---------------------------------------------------------------------------
-- The pulse loop. Runs ONLY while the number is "hot" (at/over the warning
-- threshold): PctOnUpdate is attached on the way into hot and detached on the
-- way out, so a calm readout costs no per-frame work at all. That matters --
-- OnUpdate fires every rendered frame, which is the one place in this addon
-- where sloppiness would actually show up in a framerate.
local function PctOnUpdate(self, dt)
  pctPulseT = pctPulseT + (dt or 0.03)
  self:SetScale(PCT_HOT_SCALE * (1 + PCT_PULSE_AMP * math.sin(pctPulseT * PCT_PULSE_HZ)))
end

-- Enter/leave the emphasised state. Idempotent: called every evaluation, but
-- only does work on an actual transition.
local function SetPctHot(hot)
  if not readout then return end
  if hot == pctHot then return end
  pctHot = hot
  if hot then
    pctPulseT = 0
    readout:SetScript("OnUpdate", PctOnUpdate)
    readout:SetScale(PCT_HOT_SCALE)
  else
    readout:SetScript("OnUpdate", nil)
    readout:SetScale(1)
  end
end

local function BuildReadout()
  if readout or not CreateFrame then return end
  readout = CreateFrame("Frame", "HunterKitThreatPct", UIParent)
  readout:SetFrameStrata("MEDIUM")
  -- Wide enough for "12.3k 100%": the damage gap sits in front of the number.
  readout:SetSize(110, 18)
  readout:EnableMouse(false)          -- never intercept clicks on the player frame

  readoutText = readout:CreateFontString(nil, "OVERLAY")
  -- Font BEFORE text (SetText on a font-less FontString throws on the client).
  readoutText:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
  readoutText:SetPoint("CENTER", readout, "CENTER", 0, 0)
  readoutText:SetText("")

  ThreatWatch.ApplyReadoutPosition()

  HK.RegisterDraggable("threatpct", readout, ThreatWatch.ApplyReadoutPosition,
    function(x, y) db.pctOffsetX, db.pctOffsetY = x, y end, {
      -- The drag handlers blank the frame's OnUpdate, which would silently kill
      -- the pulse after a lock/unlock cycle (PassivePulse hit exactly this).
      -- Re-bind it, but only if we were mid-pulse when the drag started.
      onUpdate = function()
        if pctHot then readout:SetScript("OnUpdate", PctOnUpdate) end
      end,
      saveFromScreen = function()
        -- Save in UIParent space, and record that it is now user-placed so the
        -- PlayerFrame anchor stops overriding it.
        local fx, fy = readout:GetCenter()
        local uw = (UIParent:GetWidth() or 0) / 2
        local uh = (UIParent:GetHeight() or 0) / 2
        db.pctOffsetX = (fx or 0) - uw
        db.pctOffsetY = (fy or 0) - uh
        db.pctMoved = true
      end,
    })
  readout:Hide()
end

function ThreatWatch.ApplyReadoutPosition()
  if not readout or not db then return end
  readout:ClearAllPoints()
  if db.pctMoved then
    -- Dragged: pin absolutely so it stays exactly where it was dropped.
    readout:SetPoint("CENTER", UIParent, "CENTER",
      tonumber(db.pctOffsetX) or 0, tonumber(db.pctOffsetY) or 0)
    return
  end
  -- Default: above and to the RIGHT of the player frame. Anchoring our
  -- BOTTOMLEFT to the frame's TOPRIGHT puts the number outside the portrait
  -- artwork instead of on top of it, whatever the frame's size or scale.
  local anchor = _G["PlayerFrame"]
  if anchor and anchor.GetObjectType then
    readout:SetPoint("BOTTOMLEFT", anchor, "TOPRIGHT",
      tonumber(db.pctOffsetX) or -34, tonumber(db.pctOffsetY) or -16)
  else
    -- No player frame (heavily reskinned UI): fall back to a sane screen spot
    -- rather than leaving the widget unanchored.
    readout:SetPoint("CENTER", UIParent, "CENTER",
      tonumber(db.pctOffsetX) or 0, tonumber(db.pctOffsetY) or 160)
  end
end

-- Colour ramp for the number: green while safe, amber as it closes on the
-- warning threshold, red once it is at or past it (or you already have aggro).
-- The ramp is tied to the SAME threshold the warning uses, so the colour and
-- the warning always agree with each other.
local function PctColor(pct, pulled)
  if pulled or pct >= 100 then return 1, 0.1, 0.1 end
  local threshold = tonumber(db and db.threshold) or 80
  if pct >= threshold then return 1, 0.35, 0.1 end
  if pct >= threshold * 0.75 then return 1, 0.82, 0 end
  return 0.2, 1, 0.2
end

local function UpdateReadout()
  if not readout then return end
  if not db or db.showPct == false or not HK.isHunter then
    readout:Hide()
    return
  end

  -- Edit mode: hold a sample value on screen so it can be dragged into place.
  if HK.Editing and HK.Editing() then
    SetPctHot(false)          -- never animate a frame the player is dragging
    readoutText:SetText("64%")
    readoutText:SetTextColor(1, 0.82, 0)
    readout:Show()
    return
  end

  local pct, pulled, threat = ThreatWatch.CurrentPct()
  if pct == nil then
    -- Out of combat, no pet, or no threat on anything: show nothing at all
    -- rather than a stale or zero number.
    SetPctHot(false)          -- and stop the pulse loop with it
    readout:Hide()
    return
  end

  -- "1.2k 74%" -- how much more damage would pull it, in front of the
  -- percentage. Dimmed and smaller-feeling than the percentage because it is
  -- the supporting detail, not the headline. Omitted entirely (rather than
  -- shown as 0 or a guess) whenever it cannot be derived honestly.
  local head = ""
  if db.showGap ~= false then
    local gap = ThreatWatch.DamageToPull(threat, pct)
    if gap and gap > 0 then
      head = "|cff9d9d9d" .. ThreatWatch.ShortNum(gap) .. "|r "
    end
  end
  readoutText:SetFormattedText("%s%d%%", head, math.floor(pct))
  readoutText:SetTextColor(PctColor(pct, pulled))
  -- Emphasise from the SAME threshold the warning uses (and always once you
  -- actually hold aggro), so the size, the colour and the warning all agree.
  local threshold = tonumber(db.threshold) or 80
  SetPctHot(pulled == true or pct >= threshold)
  readout:Show()
end
ThreatWatch.UpdateReadout = UpdateReadout
function ThreatWatch.ReadoutText()
  return readout and readout:IsShown() and readoutText and readoutText.text or nil
end
function ThreatWatch.IsReadoutShown()
  return readout ~= nil and readout:IsShown() == true
end
-- Exposed for tests and diagnostics: the colour currently applied to the number.
function ThreatWatch.ReadoutColor()
  return readoutText and readoutText.textColor or nil
end
-- Exposed for tests: is the number currently emphasised, and at what scale.
function ThreatWatch.IsReadoutHot() return pctHot == true end
function ThreatWatch.ReadoutScale()
  return readout and (readout:GetScale() or 1) or nil
end
function ThreatWatch.IsReadoutPulsing()
  return readout ~= nil and readout:GetScript("OnUpdate") ~= nil
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

-- Deliberately PLAIN (user: the warning was overcomplicated).
--
-- Two words and nothing else. The old alert stacked a percentage, an advice
-- clause and a mob name under an icon -- four things to parse at the one moment
-- you have no attention to spare, and all of it redundant: the exact percentage
-- is already on the readout by your player frame, and you know what you are
-- shooting. What the alert has to convey is a single bit -- "back off now" --
-- so that is all it says.
local function Show(state, pct, mobName)
  if not frame then return end
  if state == "pulled" then
    icon:SetTexture(ICON_PULLED)
    label:SetText("|cffff2020AGGRO|r")
  else
    icon:SetTexture(ICON_WARN)
    label:SetText("|cffffcc00THREAT|r")
  end
  sub:SetText("")
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

  -- The readout is its own feature with its own enable, so it refreshes on
  -- every tick regardless of what the warning decides below (including when the
  -- warning is switched off entirely, which is the default).
  UpdateReadout()

  -- Edit mode: hold the frame visible so it can be dragged into place.
  if HK.Editing and HK.Editing() then
    if frame then
      icon:SetTexture(ICON_WARN)
      label:SetText("|cffffcc00THREAT|r")
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
  if not db then return false end
  -- EITHER feature can justify the ticker. The warning is off by default now,
  -- so gating the poll on `db.enabled` alone would leave the percentage readout
  -- permanently frozen for everyone using the defaults.
  if db.enabled == false and db.showPct == false then return false end
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
    UpdateReadout()      -- combat over: drop the number too, don't freeze it
  end
end
ThreatWatch.SyncTicker = SyncTicker
function ThreatWatch.IsPolling() return ticker ~= nil end
function ThreatWatch.IsShown() return frame ~= nil and frame:IsShown() == true end

-- The alert's current wording (testable, and handy from /htk threat).
function ThreatWatch.AlertText()
  return (frame and frame:IsShown() and label and label.text) or nil
end

-- ---------------------------------------------------------------------------
-- Diagnostics (/htk threat)
-- ---------------------------------------------------------------------------
function ThreatWatch.PrintDiag()
  print("|cff39ff14HunterKit|r pet aggro warning diagnostics:")
  print("  threat API: " .. (ThreatWatch.HasAPI()
    and "present (1.13.5+ reinstated API)" or "MISSING -- feature cannot run"))
  print("  polling: " .. tostring(ticker ~= nil))
  print(string.format("  warning: %s | percentage readout: %s",
    (db and db.enabled ~= false) and "on" or "off",
    (db and db.showPct ~= false) and "on" or "off"))
  local livePct, livePulled, liveThreat = ThreatWatch.CurrentPct()
  print("  live aggro %: " .. (livePct and (math.floor(livePct) .. "%"
    .. (livePulled and " (you have aggro)" or "")) or "none"))
  if livePct then
    local gap = ThreatWatch.DamageToPull(liveThreat, livePct)
    print(string.format("  my threat: %d | damage to pull: %s",
      math.floor(liveThreat or 0), gap and ThreatWatch.ShortNum(gap) or "unknown"))
    local last = ThreatWatch.Trend()
    print("  trend: last sample " .. (last and string.format("%.1f%%", last) or "none")
      .. " (a warning needs threat RISING, not merely high)")
  end
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
  ThreatWatch.ApplyReadoutPosition()
  SyncTicker()
  Evaluate(true)
end

function ThreatWatch.Init()
  db = HK.db.threat
  if not HK.isHunter then return end       -- structural gate: no hunter, no feature

  Build()
  BuildReadout()

  -- Event-driven where the client cooperates...
  HK.On("UNIT_THREAT_LIST_UPDATE", function() Evaluate() end)
  HK.On("UNIT_THREAT_SITUATION_UPDATE", function() Evaluate() end)

  -- ...and the ticker's lifecycle, which is what keeps the idle cost at zero.
  HK.On("PLAYER_REGEN_DISABLED", function() SyncTicker(); Evaluate(true) end)
  -- Leaving combat or losing the pet ends the series: the next fight must not
  -- be compared against the last one's final percentage.
  HK.On("PLAYER_REGEN_ENABLED", function()
    ThreatWatch.ResetTrend()
    SyncTicker()
  end)
  HK.On("UNIT_PET", function()
    ThreatWatch.ResetTrend()
    SyncTicker()
  end)
  HK.On("PLAYER_ENTERING_WORLD", function()
    -- The player frame may not have existed when we first anchored.
    ThreatWatch.ApplyReadoutPosition()
    SyncTicker()
  end)

  SyncTicker()
  UpdateReadout()
end

HK.RegisterModule("ThreatWatch", { Init = ThreatWatch.Init })
