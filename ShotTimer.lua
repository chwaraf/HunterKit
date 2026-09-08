--[[==============================================================================
 HunterKit — Auto Shot timer / weave bar

 WHAT THE BAR IS FOR
 -------------------
 In Classic, Auto Shot is not a melee-style swing: it is a 0.5s CAST followed by
 a weapon-speed cooldown. That single fact is the whole feature:

     shot fires ──────── recovery (weapon speed) ────────┬─ 0.5s cast ─┬─ shot
                 <------ free: move, weave, cast -------> <-- LOCKED -->

 During the recovery you may move and use abilities freely at no cost. During
 the last 0.5s you must be standing still and not starting a cast, or the shot
 is "clipped" -- pushed back, and the damage is simply lost. So the bar shows
 two regions: a long SAFE stretch and a short RED lockout at the end. The advice
 every hunter guide gives -- "weave right AFTER the shot goes off, never just
 before the next one" -- falls straight out of the picture.

 Sources for the mechanics (see README): the 0.5s cast is fixed and does not
 scale with weapon speed, which is exactly why slow ranged weapons are preferred
 -- a 3.0s bow leaves 2.5s of free time, a 1.8s one leaves only 1.3s.

 WHY IT ALSO MEASURES
 --------------------
 Theory is not enough here, and this is the part cheap implementations get
 wrong. Latency, spell batching and the server's own re-shot timer all move the
 real boundary, and the honest number differs per player and per weapon. So the
 bar does not only predict: after every shot it compares when the shot was
 EXPECTED against when it actually happened, and reports the difference as
 "+0.34s". That figure is ground truth. If it reads +0.00 you are clean; if it
 keeps reading +0.3 you are clipping and can see it, which is precisely the
 feedback the popular WeakAuras give and the reason good hunters use them.

 MELEE WEAVING
 -------------
 A hunter has TWO independent attack cycles -- the ranged one above and an
 ordinary melee swing -- and in Classic Era they do NOT reset each other. That
 is what makes weaving possible: run in, land a Raptor Strike in the free part
 of the shot cycle, run back out, and the Auto Shot fires on schedule as if you
 had never moved. It is worth real damage and is the skill ceiling of the class.

 IMPORTANT -- this is version-specific and widely gotten wrong. In WotLK
 Blizzard deliberately linked the two (a melee swing resets the ranged timer and
 vice versa), which killed weaving there; a 2022 blue post confirms that as
 intended 3.3.5 behaviour. Era is the older, UNLINKED model. This module targets
 Era, so it treats the cycles as independent -- but it never *assumes* the swing
 landed on time: the melee bar is driven by observed swings from the combat log,
 so if a server did link them the bar would show that rather than lie.

 The weave window is not simply "the green part". A round trip costs travel time
 out and back, so the bar marks the point after which leaving would not get you
 home before the shot. Community timing for a good hunter with a speed buff is
 ~2.5s round trip, which is why weaving is only safe on slow weapons and why
 every guide says never to weave while hasted.

 COST
 ----
 Event-driven. The OnUpdate that animates the bar is attached only while the bar
 is actually on screen, and detached the moment auto-repeat stops. No combat log.
==============================================================================]]
local _, HK = ...

local ShotTimer = {}
HK.ShotTimer = ShotTimer

local db

-- Auto Shot's cast time is a FIXED 0.5s in Classic. It is not derived from the
-- weapon and it does not scale with weapon speed -- only with ranged haste,
-- which the client already folds into UnitRangedDamage's speed for the
-- cooldown, but NOT into this cast. Keep them separate.
local AUTO_SHOT      = 75          -- spellID: Auto Shot
local CAST_TIME      = 0.5         -- seconds the shot itself takes to release
local MIN_SPEED      = 0.4         -- floor; guards against a nonsense API read
local MAX_SPEED      = 10          -- ceiling; ditto
local DEFAULT_SPEED  = 2.8         -- only until the first real reading

-- Shots that RESET the auto-shot timer when they land. Aimed Shot restarts the
-- cycle (documented behaviour since 2.0.1), so the bar has to restart with it
-- or it would show a shot that is never coming.
local AIMED_SHOT_IDS = {
  [19434] = true, [20900] = true, [20901] = true,
  [20902] = true, [20903] = true, [20904] = true,
}

-- Shots worth announcing as "weaveable" -- the ones with a cast time, which are
-- the only ones that can clip by their own duration rather than just by the GCD.
local MULTI_SHOT_IDS = {
  [2643] = true, [14288] = true, [14289] = true, [14290] = true, [25294] = true,
}

-- Melee weaving. DEFAULT_TRAVEL is the round trip a competent hunter manages
-- (out to melee, swing, back to range) -- the figure the Classic hunter guides
-- quote with a movement buff. It is a user setting because it depends on your
-- speed buff and how far out you stand; the bar is only honest if this matches
-- reality, so the option tooltip says so plainly.
-- The two shots that gate weaving. Bouk's Era guide: weave a Raptor Strike
-- "when both Aimed and Multi-Shot are on CD" -- if either is ready, you should
-- be spending it rather than running to melee. Ranks share a cooldown, so the
-- rank-1 id is enough for GetSpellCooldown.
local SPELL_AIMED = 19434
local SPELL_MULTI = 2643
-- After this many swing-lengths with no observed swing we stop treating the
-- melee cycle as live. Two gives a full swing of slack for a missed combat-log
-- line before the bar goes quiet, without animating forever after you walk away.
-- ---------------------------------------------------------------------------
-- One palette for BOTH cycles.
--
-- The ranged and melee bars had grown separate hardcoded colours: different
-- track shades (black 0.55 vs slate 0.90) and a "ready" state that only the
-- melee bar had. Two bars stacked on top of each other that mean the same
-- thing -- "this weapon is charging toward its next hit" -- must be read the
-- same way, or the player has to learn two vocabularies at a glance.
--
-- The rule is now identical for both: CHARGING while the swing is coming up,
-- READY the moment it is available to spend, LOCKED while acting would cost
-- you the shot (ranged only -- melee has no cast lockout in Era).
-- ---------------------------------------------------------------------------
local COL_TRACK    = { 0.10, 0.10, 0.12, 0.85 }   -- unfilled bed, both bars
local COL_CHARGING = { 0.20, 0.90, 0.30, 0.90 }   -- winding up
local COL_READY    = { 0.55, 1.00, 0.55, 1.00 }   -- available to spend
local COL_LOCKED   = { 1.00, 0.30, 0.10, 0.95 }   -- acting now clips the shot
local COL_ZONE     = { 0.75, 0.12, 0.12, 0.55 }   -- the lockout region
local COL_PIP_DOWN = { 0.35, 0.35, 0.38, 0.90 }   -- special on cooldown
local COL_PIP_READY= { 0.30, 0.90, 0.30, 0.95 }   -- special ready to spend
local COL_WEAVE    = { 0.40, 0.75, 1.00, 0.95 }   -- weave marker, still ahead

-- The state strip (0.9.71). One colour per RangeState, so the strip and the
-- icon speak the same language as the bars: green = act now, blue = set up and
-- waiting, amber = partial, grey = nothing to do, red = something is wrong.
local COL_TWOGO    = { 0.30, 1.00, 0.45, 1.00 }   -- press the two-mob macro NOW
local COL_TWO      = { 0.40, 0.75, 1.00, 0.95 }   -- set up, waiting on a cycle
local COL_INMELEE  = { 0.90, 0.70, 0.20, 0.90 }   -- melee mob, no second target
local COL_SHOOTING = { 0.45, 0.45, 0.50, 0.85 }   -- nothing in melee
local COL_OOR      = { 1.00, 0.30, 0.10, 0.95 }   -- target out of Auto Shot range
-- The latency slice: the measured, honest tail of the lockout. See Redraw.
local COL_LATENCY  = { 1.00, 0.85, 0.20, 0.70 }

-- Last-drawn cache for the per-frame redraw. OnUpdate runs on EVERY rendered
-- frame (60-150+ Hz), but almost nothing it draws changes that fast: the label
-- shows one decimal so it changes ~10x/sec, and the colours change a handful of
-- times per cycle. Re-issuing identical SetWidth/SetVertexColor/SetText calls is
-- the addon's single busiest piece of pointless work, so each one is now gated
-- on the value having actually moved. Widths are compared at sub-pixel
-- resolution -- finer than that cannot be seen.
local lastFillW, lastMeleeW = -1, -1
local lastFillCol, lastMeleeCol
local lastLabel, lastDelayStr
-- 0.9.71 widgets are cached the same way: the strip changes state a few times
-- per cycle and the icon a couple of times a second, not every frame.
local lastStripCol, lastStripTxt, lastLatW = nil, nil, -1
local lastRecoTxt, lastIconCol, lastIconTxt, lastIconA

local function Paint(tex, c)
  if tex and c then tex:SetVertexColor(c[1], c[2], c[3], c[4]) end
end

-- Paint only if the colour actually differs from what is already there.
local function PaintIf(tex, c, prev)
  if not tex or not c then return prev end
  if prev == c then return prev end
  tex:SetVertexColor(c[1], c[2], c[3], c[4])
  return c
end

-- Show/Hide are not free either, and they were being called every frame on
-- widgets whose visibility changes a few times per fight.
local function ShownIf(tex, want)
  if not tex then return end
  if (tex:IsShown() == true) ~= want then
    if want then tex:Show() else tex:Hide() end
  end
end

local function SetWidthIf(tex, w, prev)
  if not tex then return prev end
  if math.abs(w - prev) < 0.5 then return prev end   -- sub-pixel: invisible
  tex:SetWidth(w)
  return w
end

local MELEE_IDLE_AFTER = 2
local DEFAULT_TRAVEL = 2.5
local MELEE_MIN_SPEED = 0.5
local MELEE_MAX_SPEED = 10

local frame, track, fill, safeMark, castZone, tick, label, delayText
local onUpdateBound = false
local specialRow = nil

-- Timing state. All absolute GetTime() stamps, never durations, so a missed
-- frame can never accumulate drift.
local shotAt        = nil    -- when the last Auto Shot actually released
local nextAt        = nil    -- when the next one is predicted to release
local castStartedAt = nil    -- when the 0.5s cast began (server-confirmed)
local speed         = DEFAULT_SPEED
local repeating     = false  -- auto-repeat is on (START/STOP_AUTOREPEAT_SPELL)
local lastDelay     = 0      -- measured clip on the previous shot, seconds
local delayShownAt  = 0
local shotCount, clipCount = 0, 0

-- Melee cycle. Tracked from OBSERVED swings (combat log), never assumed: the
-- client offers no "time of next swing" call, so the only honest anchor is a
-- swing that actually happened.
local meleeSpeed   = 2.4
local meleeSwungAt = nil
local weaveMark, meleeFill, meleeTrack

-- 0.9.71 widgets. `rangeStrip` is the state line under the melee strip; `reco`
-- is the "what to press next" row; `latencySlice` is the measured tail of the
-- lockout. The two-mob icon is its OWN frame, because it has to be draggable
-- independently of the bar -- the whole point is putting it somewhere in your
-- peripheral vision, which is rarely next to a combat bar.
local rangeStrip, rangeStripText, reco, latencySlice
local iconFrame, iconTex, iconText, iconCd

local DELAY_HOLD  = 2.5      -- seconds the "+0.34s" readout lingers
local CLIP_EPSILON = 0.08    -- below this, a delay is latency noise, not a clip

-- Every client call is wrapped: a single missing API must not break the bar.
-- Forwards ALL return values -- an earlier version truncated at three, which
-- silently dropped the 4th field of CombatLogGetCurrentEventInfo (the source
-- GUID) and made every melee swing look like somebody else's.
local function Call(fn, ...)
  if type(fn) ~= "function" then return nil end
  -- n is captured from the SAME call -- never call fn twice to count its
  -- returns, these are live client calls. `n` is explicit because the result
  -- list can contain nils, and both #r and table.maxn stop at the first hole.
  local r = table.pack and table.pack(pcall(fn, ...)) or { pcall(fn, ...) }
  if not r[1] then return nil end
  local n = r.n or #r
  -- pcall succeeded but fn returned NOTHING (n == 1 is just the `true`). Return
  -- an explicit nil: expanding to zero values would make the caller's argument
  -- vanish, and e.g. tonumber() with no argument throws rather than returning
  -- nil. A wrapper meant to make calls safe must never hand back "no value".
  if n < 2 then return nil end
  return unpack(r, 2, n)
end

-- ---------------------------------------------------------------------------
-- Weapon speed
--
-- UnitRangedDamage returns the CURRENT ranged speed with haste already applied
-- (quiver, Rapid Fire, Aspect of the Hawk procs), which is what the cooldown
-- actually uses. Re-read it per shot rather than caching at login: a Hawk proc
-- landing mid-fight changes the answer, and a bar that ignores that is worse
-- than no bar.
-- ---------------------------------------------------------------------------
local function ReadSpeed()
  local s = Call(UnitRangedDamage, "player")
  s = tonumber(s)
  if not s or s < MIN_SPEED or s > MAX_SPEED then return nil end
  return s
end

function ShotTimer.Speed() return speed end

-- ---------------------------------------------------------------------------
-- The model
--
-- Returns: remaining (seconds until the shot releases), total (the full cycle),
-- and locked (true once we are inside the final 0.5s and must hold still).
-- Everything the display needs, with no widget knowledge.
-- ---------------------------------------------------------------------------
function ShotTimer.Progress(now)
  now = tonumber(now) or (tonumber(Call(GetTime)) or 0)
  if not nextAt then return nil end
  local remaining = nextAt - now
  local total = speed
  if remaining < 0 then remaining = 0 end
  return remaining, total, (remaining <= CAST_TIME)
end

-- The free window: how long you can still safely start something. This is the
-- number the feature exists to communicate, so it is a first-class accessor
-- rather than something only the bar knows.
function ShotTimer.SafeWindow(now)
  local remaining = ShotTimer.Progress(now)
  if not remaining then return nil end
  local free = remaining - CAST_TIME
  if free < 0 then free = 0 end
  return free
end

function ShotTimer.IsLocked(now)
  local _, _, locked = ShotTimer.Progress(now)
  return locked == true
end

-- ---------------------------------------------------------------------------
-- MELEE: the second, independent cycle
-- ---------------------------------------------------------------------------
local function ReadMeleeSpeed()
  local m = Call(UnitAttackSpeed, "player")
  m = tonumber(m)
  if not m or m < MELEE_MIN_SPEED or m > MELEE_MAX_SPEED then return nil end
  return m
end

function ShotTimer.MeleeSpeed() return meleeSpeed end

-- Time until the melee weapon can swing again, or nil if we have never seen a
-- swing (in which case we genuinely do not know, and say so rather than guess).
function ShotTimer.MeleeReady(now)
  if not meleeSwungAt then return nil end
  now = tonumber(now) or (tonumber(Call(GetTime)) or 0)
  local remaining = (meleeSwungAt + meleeSpeed) - now
  if remaining < 0 then remaining = 0 end
  return remaining
end

-- ---------------------------------------------------------------------------
-- THE WEAVE DECISION
--
-- Can I run in, swing, and be back before the shot? Only if the whole round
-- trip fits inside the free part of the ranged cycle:
--
--     travel out + swing + travel back  <=  time until the shot locks me
--
-- `travel` is the full round trip, so the test is simply travel <= free window.
-- Returns: ok (boolean), free (seconds of free time), need (seconds required).
--
-- Deliberately conservative on two counts. It requires the melee weapon to be
-- READY -- weaving into a swing that is still on cooldown spends the trip and
-- lands nothing -- and it compares the trip against the free window computed
-- from the CURRENT (haste-adjusted) weapon speed, so a haste proc shrinks the
-- window and vetoes the weave by itself. There is no separate haste test (and
-- `db.shottimer.noHaste` is not read anywhere); every guide's "never weave
-- while hasted" falls out of the arithmetic instead.
-- ---------------------------------------------------------------------------
-- Special-shot cooldowns
--
-- Weaving is only correct when you have nothing better to press. These read the
-- live cooldowns rather than modelling them: ranks, talents and Quick Shots all
-- change the numbers, and the client already knows the truth.
-- ---------------------------------------------------------------------------
-- Seconds until a special shot is usable again, or nil if you do not have it.
--
-- The nil matters: an UNKNOWN spell must not read as "ready". A hunter who has
-- not trained Aimed Shot (or does not keep it on their bars) would otherwise
-- look permanently ready to spend it, and the weave gate below would veto every
-- single weave for the whole session.
local function SpellReadyIn(id, now)
  if IsSpellKnown then
    local ok, known = pcall(IsSpellKnown, id)
    if ok and known == false then return nil end
  end
  if GetSpellInfo and not Call(GetSpellInfo, id) then return nil end
  local start, duration = Call(GetSpellCooldown, id)
  start = tonumber(start) or 0
  duration = tonumber(duration) or 0
  -- A 1.5s global is not "on cooldown" for this purpose; only a real cooldown
  -- should stop you weaving, or the row would flicker on every button press.
  if start <= 0 or duration <= 1.6 then return 0 end
  local left = (start + duration) - now
  if left < 0 then left = 0 end
  return left
end

-- ready, aimedIn, multiIn -- `ready` is true when BOTH specials are down, which
-- is the moment weaving is the right call.
-- down, aimedIn, multiIn -- `down` is true when every special you actually HAVE
-- is on cooldown. A spell you have not learned is skipped rather than counted as
-- ready: it cannot be spent, so it has no business vetoing a weave.
function ShotTimer.SpecialsDown(now)
  now = now or (tonumber(Call(GetTime)) or 0)
  local a = SpellReadyIn(SPELL_AIMED, now)
  local m = SpellReadyIn(SPELL_MULTI, now)
  local down = true
  if a ~= nil and a <= 0 then down = false end
  if m ~= nil and m <= 0 then down = false end
  return down, a, m
end

-- ---------------------------------------------------------------------------
function ShotTimer.CanWeave(now)
  now = tonumber(now) or (tonumber(Call(GetTime)) or 0)
  local free = ShotTimer.SafeWindow(now)
  local static = ShotTimer.InMeleeOfTarget()
  -- No travel cost when the target is already in melee (static weaving), and
  -- no weave at all at range unless travel weaving is switched on.
  local travel = static and 0 or (tonumber(db and db.travel) or DEFAULT_TRAVEL)
  if not free then return false, nil, travel end
  if not static and not (db and db.travelWeave == true) then
    return false, free, travel
  end

  -- The melee swing must be READY by the time you arrive, or the trip buys
  -- nothing -- you would stand in melee waiting for a swing that is not up.
  --
  -- Ranged and melee run at different speeds and drift against each other, so
  -- "is there room" is not enough: the two cycles have to line up. You reach
  -- melee after travel/2, and must be back before the shot locks out, so the
  -- swing has to land inside that window. Being early is fine (you wait a
  -- moment); being late means the swing never happens.
  local meleeIn = ShotTimer.MeleeReady(now)
  if meleeIn then
    local arrive = travel / 2
    if meleeIn > arrive + (free - travel) then
      -- The swing comes up after the last moment you could still act on it.
      return false, free, travel
    end
  end

  -- Never suggest a weave while a special shot is available: Aimed or Multi is
  -- worth more than a Raptor Strike, and running to melee would waste it. Only
  -- gated when the option is on, so a player who wants the raw timing can see
  -- it. (Optional because "max weaving" deliberately weaves around the specials
  -- rather than only between them.)
  if db and db.specials ~= false then
    local down = ShotTimer.SpecialsDown(now)
    if not down then return false, free, travel end
  end
  return (free >= travel), free, travel
end

-- ---------------------------------------------------------------------------
-- WHEN to leave for melee.
--
-- CanWeave answers "is a weave possible right now". This answers the question a
-- weaving hunter actually has: the ranged and melee weapons run at different
-- speeds and drift against each other, so the ideal departure is the moment
-- where the round trip fits in the shot cycle AND your melee swing is up when
-- you arrive. That instant moves every cycle as the two clocks slide apart.
--
-- Returns secondsUntilBestDeparture (0 = go now), or nil when this shot cycle
-- has no honest window at all. Never guesses: with no observed swing there is
-- no melee clock to line up against, so it falls back to "as soon as the trip
-- fits", which is the old behaviour.
-- ---------------------------------------------------------------------------
-- Are you ALREADY standing in melee of your current target?
--
-- This is the "static weaving" case from Bouk's guide, and the one the round
-- trip model completely missed: pet holds a distant mob you shoot with a
-- mouseover macro, while a SECOND mob stands next to you and is your target.
-- You never move, so there is no travel cost -- the only question is whether a
-- swing fits before the shot locks out.
--
-- Uses the same 11 yd "Trade" interaction probe Range.lua settled on. Raptor
-- Strike's IsSpellInRange is unreliable on this client (it reports in-range at
-- 28+ yd), so it is deliberately not used here either.
-- Every unit the client will answer distance questions about. Order is cheapest
-- and likeliest first; the scan stops at the first hit.
--
--   target      -- the obvious one, and the only one the old code looked at
--   mouseover   -- you are shooting through a mouseover macro, so the melee mob
--                  may be under your cursor rather than targeted
--   pettarget   -- the pet is tanking one mob; if THAT is the one at your feet
--                  it still counts, and if it is the distant one this simply
--                  reports false, which is correct
--   targettarget -- the mob attacking whatever you are targeting; catches the
--                  case where you target the distant mob and the melee one is
--                  hitting you
local MELEE_UNITS = { "target", "mouseover", "pettarget", "targettarget" }

local function UnitIsMeleeable(unit)
  if not UnitExists or not Call(UnitExists, unit) then return false end
  if UnitCanAttack and not Call(UnitCanAttack, "player", unit) then return false end
  if UnitIsDead and Call(UnitIsDead, unit) then return false end
  if not CheckInteractDistance then return false end
  local v = Call(CheckInteractDistance, unit, 2)   -- 2 = Trade, ~11 yd
  return v == 1 or v == true
end

-- Is ANY attackable mob standing in melee of you?
--
-- This used to ask only about "target", which broke the standard two-mob setup:
-- pet tanks a distant mob you shoot with a mouseover macro, while a second mob
-- melees you. If you targeted the distant mob -- or nothing at all, which a
-- mouseover macro encourages -- the addon concluded you were not in melee and
-- went silent, exactly when static weaving is what you are doing.
--
-- The client gives no "is anything in melee of me" API, so we scan the handful
-- of units it will answer for. Four CheckInteractDistance calls at most, only
-- while a weave is being evaluated, and it stops at the first hit.
function ShotTimer.InMeleeOfTarget()
  for _, unit in ipairs(MELEE_UNITS) do
    if UnitIsMeleeable(unit) then return true, unit end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- THE TWO-MOB WEAVE
--
-- The setup: your pet holds mob B at range, and you stand in MELEE of mob A,
-- swinging at it between shots. That is worth real damage -- a melee swing and
-- an Auto Shot on two different mobs, off two independent cycles -- and it is
-- the reason the "Two-mob weave" macro exists in Macros.lua: Auto Shot cannot
-- be aimed with [@unit], it always shoots your actual target, so the macro
-- flicks your target to the pet's mob, restarts Auto Shot, and flicks back.
--
-- Until now the bar gave you nothing for this. Its only weave marker was the
-- TRAVEL weave departure point -- run out to melee and back -- which is opt-in
-- and, as the author put it, something you "never use levelling". So the
-- situation the addon had a macro for was the one situation it would not
-- show. This model is that indicator.
--
-- What makes a press CORRECT, derived from what the macro actually does:
--   1. `target` is a live attackable mob AND within melee, or /startattack has
--      nothing to hit and the press achieves nothing.
--   2. `pettarget` is a live attackable mob, or every [@pettarget] line in the
--      macro is skipped and it degrades to a plain melee swing.
--   3. it is a DIFFERENT mob -- if the pet is on your own target the flick is a
--      no-op and you are just standing in melee.
--   4. your melee swing is up, else the press only restarts /startattack.
--   5. Auto Shot is NOT in its 0.5s lockout, or the /cast !Auto Shot inside
--      the flick is the very thing that clips.
--
-- All five are read live from the client. Nothing here models or guesses.
-- ---------------------------------------------------------------------------
local RAPTOR_STRIKE = 2973      -- rank 1; ranks share a cooldown

-- Live and attackable, without the melee-range part of UnitIsMeleeable.
local function UnitAttackable(unit)
  if not UnitExists or not Call(UnitExists, unit) then return false end
  if UnitCanAttack and not Call(UnitCanAttack, "player", unit) then return false end
  if UnitIsDead and Call(UnitIsDead, unit) then return false end
  return true
end

-- Same unit? Used to tell "pet is on a second mob" from "pet is on my mob".
-- A false negative here (two different mobs read as the same) would suppress a
-- valid cue; a false positive would show one you cannot use. GUID is exact, so
-- prefer it and fall back to comparing names only if the API is absent.
local function SameUnit(a, b)
  if not UnitExists or not Call(UnitExists, a) or not Call(UnitExists, b) then
    return false
  end
  if UnitGUID then
    local ga, gb = Call(UnitGUID, a), Call(UnitGUID, b)
    if ga and gb then return ga == gb end
  end
  if UnitIsUnit then
    local v = Call(UnitIsUnit, a, b)
    if v ~= nil then return v == true or v == 1 end
  end
  local na, nb = Call(UnitName, a), Call(UnitName, b)
  return na ~= nil and na == nb
end

-- The full two-mob picture, as a table so every consumer -- strip, icon, reco
-- row, tests -- reasons from ONE evaluation instead of four drifting ones.
function ShotTimer.TwoMob(now)
  now = tonumber(now) or (tonumber(Call(GetTime)) or 0)
  local s = {}
  s.targetLive = UnitAttackable("target")
  s.petLive    = UnitAttackable("pettarget")
  -- The macro acts on `target`, so that specific unit must be in melee -- not
  -- merely "some mob is", which is what InMeleeOfTarget() answers.
  s.inMelee    = s.targetLive and (UnitIsMeleeable("target") == true)
  s.distinct   = s.targetLive and s.petLive and (not SameUnit("target", "pettarget"))
  s.swingIn    = ShotTimer.MeleeReady(now)      -- nil = no swing observed yet
  s.swingUp    = (s.swingIn ~= nil) and (s.swingIn <= 0) or false
  s.locked     = ShotTimer.IsLocked(now) == true
  s.free       = ShotTimer.SafeWindow(now)
  -- Raptor is commented out in the shipped macro, so it never gates the cue;
  -- it is reported so the reco row can suggest it when the player uncomments.
  s.raptorIn   = SpellReadyIn(RAPTOR_STRIKE, now)

  -- Both mobs, and they are different mobs. This is the SETUP being available
  -- at all, independent of any timing.
  s.setup = (s.inMelee == true) and (s.distinct == true)
  -- And the moment to actually press it.
  s.press = s.setup and s.swingUp and (not s.locked)
  return s
end

-- One word for the strip: the state you are in, so it reads at a glance
-- instead of you having to work it out from two bars and a marker.
--   twogo - two mobs set up AND the press is correct right now
--   two   - two mobs set up, waiting on the melee swing or the shot window
--   melee - something is in melee of you but there is no second mob to shoot
--   oor   - your target is out of Auto Shot range
--   range - nothing in melee; you are simply shooting
function ShotTimer.RangeState(now)
  local s = ShotTimer.TwoMob(now)
  if s.setup then return (s.press and "twogo" or "two"), s end
  if ShotTimer.InMeleeOfTarget() then return "melee", s end
  -- Only call the range API when there is a target to ask about.
  if s.targetLive and IsSpellInRange then
    local v = Call(IsSpellInRange, "Auto Shot", "target")
    if v == 0 or v == false then return "oor", s end
  end
  return "range", s
end

function ShotTimer.WeaveWindow(now)
  now = tonumber(now) or (tonumber(Call(GetTime)) or 0)
  if not db or db.weave == false then return nil end
  local free = ShotTimer.SafeWindow(now)
  if not free then return nil end
  -- Standing in melee already? Then there is no trip to pay for.
  --
  -- The whole model was built around running out and back, so it kept charging
  -- a 2.5s round trip even when the target was at your feet -- which silenced
  -- the advice entirely during static weaving. With no travel, a swing only has
  -- to land before the shot locks out.
  local static = ShotTimer.InMeleeOfTarget()
  -- Travel weaving is opt-in. With it off we only ever advise a weave you can
  -- take without moving, so the bar never suggests running out to a target at
  -- range -- the round-trip logic below simply never gets a chance to run.
  if not static and db.travelWeave ~= true then
    return nil, nil, "notinmelee"
  end
  local travel = static and 0 or (tonumber(db.travel) or DEFAULT_TRAVEL)
  -- Report WHY there is no window, so the caller can say something useful
  -- instead of falling silent: "tooslow" = this weapon's cycle is too short for
  -- the round trip at all, "specials" = you have a better button to press.
  if free < travel then return nil, nil, "tooslow" end
  if db.specials ~= false and not ShotTimer.SpecialsDown(now) then
    return nil, nil, "specials"
  end

  -- Latest departure that still gets you home before the lockout.
  local latest = free - travel
  local meleeIn = ShotTimer.MeleeReady(now)
  if not meleeIn then
    return 0, latest, nil                       -- no melee clock yet: go now
  end

  -- Earliest departure whose ARRIVAL coincides with the swing being ready.
  -- Leaving before this just means standing in melee doing nothing.
  local best = meleeIn - (travel / 2)
  if best < 0 then best = 0 end                 -- swing already up: go now
  if best > latest then return nil, nil, "swing" end  -- swing lands too late
  return best, latest, nil
end

function ShotTimer.LastDelay() return lastDelay end
function ShotTimer.Stats() return shotCount, clipCount end

function ShotTimer.ResetStats()
  shotCount, clipCount, lastDelay = 0, 0, 0
end

-- ---------------------------------------------------------------------------
-- Widgets
-- ---------------------------------------------------------------------------
local function ApplyIconPosition()
  if not iconFrame then return end
  iconFrame:ClearAllPoints()
  if db and db.iconMoved == true then
    iconFrame:SetPoint("CENTER", UIParent, "CENTER",
      tonumber(db.iconOffsetX) or 0, tonumber(db.iconOffsetY) or 0)
  elseif frame then
    iconFrame:SetPoint("LEFT", frame, "RIGHT", 6, 0)
  else
    iconFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  end
end

local function ApplySize()
  if not frame then return end
  local w = tonumber(db and db.width) or 220
  local h = tonumber(db and db.height) or 27   -- matches HK.defaults.shottimer
  frame:SetSize(w, h)
  if track then track:SetSize(w, h) end
  -- The red lockout is a FIXED 0.5s, so its share of the bar changes with the
  -- weapon: on a slow bow it is a thin sliver, on a fast one it eats half the
  -- bar. Drawing it to scale is the point -- it shows, at a glance, why slow
  -- ranged weapons are easier to play.
  if castZone then
    local frac = CAST_TIME / math.max(speed, MIN_SPEED)
    if frac > 1 then frac = 1 end
    castZone:SetSize(math.max(1, w * frac), h)
  end

  -- The melee strip sits just below the shot bar, a third of its height.
  local mh = math.max(3, math.floor(h / 3))
  if meleeTrack then
    meleeTrack:ClearAllPoints()
    meleeTrack:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, -2)
    meleeTrack:SetSize(w, mh)
  end
  if meleeFill then
    meleeFill:ClearAllPoints()
    meleeFill:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, -2)
    meleeFill:SetSize(1, mh)
  end

  -- Rows below the shot bar, top to bottom: melee strip, state strip, special
  -- pips, reco row. Each pushes the next one down, so adding or hiding a row
  -- cannot leave a gap or an overlap.
  local rowTop = -(mh + 4)

  -- The state strip. Taller than the pips on purpose: it is the line you read
  -- to know whether the two-mob weave is live, so it has to be legible without
  -- squinting mid-fight.
  local rsH = math.max(12, math.floor(h * 0.55))
  if rangeStrip then
    rangeStrip:ClearAllPoints()
    rangeStrip:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, rowTop)
    rangeStrip:SetSize(w, rsH)
  end
  if rangeStripText then
    rangeStripText:ClearAllPoints()
    rangeStripText:SetPoint("CENTER", rangeStrip, "CENTER", 0, 0)
  end
  if rangeStrip and (db and db.rangeStrip ~= false) then rowTop = rowTop - rsH - 3 end

  -- The two special-shot pips, on their own row under the melee strip so the
  -- shot bar, the melee swing and the specials read top-to-bottom.
  if specialRow then
    local pipH = math.max(3, math.floor(h / 3))
    local pipW = math.max(16, math.floor(w * 0.12))
    local top = rowTop
    for i = 1, 2 do
      local pip = specialRow[i]
      local fs = specialRow[i .. "text"]
      if pip then
        pip:ClearAllPoints()
        pip:SetSize(pipW, pipH)
        pip:SetPoint("TOPLEFT", frame, "BOTTOMLEFT",
          (i - 1) * (pipW + 46), top - 2)
      end
      if fs then
        fs:ClearAllPoints()
        fs:SetPoint("LEFT", pip, "RIGHT", 3, 0)
      end
    end
  end

  if reco then
    reco:ClearAllPoints()
    reco:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 2, rowTop - 4)
  end

  -- The weave marker is positioned in Redraw, not here: in static mode its
  -- place on the bar depends on the live melee swing clock, which moves every
  -- frame. Only its size is fixed.
  if weaveMark then
    weaveMark:SetSize(3, h)
  end

  -- The icon tracks the bar's height so the two always look like one kit, and
  -- the taller default (0.9.71) gives it enough face to read the spell art.
  if iconFrame then
    local isz = math.max(24, h + 2)
    iconFrame:SetSize(isz, isz)
    ApplyIconPosition()
  end
end

-- Two small pips under the melee strip: Aimed and Multi. Green = ready (spend
-- it), dark = on cooldown (weaving is the right call). They exist so the three
-- cycles a weaving hunter juggles -- ranged, melee, specials -- are all legible
-- in one glance, which is the whole point of the bar.
local function BuildSpecialPips()
  if not frame then return end
  specialRow = {}
  for i = 1, 2 do
    local pip = frame:CreateTexture(nil, "OVERLAY")
    pip:SetTexture("Interface\\Buttons\\WHITE8x8")
    specialRow[i] = pip
    local fs = frame:CreateFontString(nil, "OVERLAY")
    fs:SetFontObject(GameFontNormalSmall)
    fs:SetJustifyH("LEFT")
    specialRow[i .. "text"] = fs
  end
end

-- The two-mob icon: a separate, independently draggable frame that lights when
-- pressing the "Two-mob weave" macro is the correct move.
--
-- Separate on purpose. A combat bar sits where the bar wants to sit; a press
-- cue has to go wherever YOUR eyes already are, which is almost never next to
-- it. So it gets its own drag handle under /htk unlock, and until you move it
-- it parks itself just right of the bar so it is at least findable.
local function BuildTwoMobIcon()
  if iconFrame then return end
  iconFrame = CreateFrame("Frame", "HunterKitTwoMobIcon", UIParent)
  iconFrame:SetFrameStrata("MEDIUM")
  iconFrame:EnableMouse(false)
  iconFrame:Hide()

  iconTex = iconFrame:CreateTexture(nil, "ARTWORK")
  iconTex:SetPoint("TOPLEFT", iconFrame, "TOPLEFT", 1, -1)
  iconTex:SetPoint("BOTTOMRIGHT", iconFrame, "BOTTOMRIGHT", -1, 1)
  -- Raptor Strike's own icon when the client can supply it: this is the melee
  -- half of the two-mob weave, and a recognisable spell icon reads faster than
  -- a generic sword.
  local tex = GetSpellTexture and Call(GetSpellTexture, RAPTOR_STRIKE)
  iconTex:SetTexture(tex or "Interface\\Icons\\Ability_MeleeDamage")

  iconText = iconFrame:CreateFontString(nil, "OVERLAY")
  iconText:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
  iconText:SetPoint("CENTER", iconFrame, "CENTER", 0, 0)
  iconText:SetText("")

  HK.CreateBorder(iconFrame)
  ApplyIconPosition()

  HK.RegisterDraggable("twomobicon", iconFrame,
    function() ApplyIconPosition() end,
    function(x, y) db.iconOffsetX, db.iconOffsetY, db.iconMoved = x, y, true end,
    { -- Only take part in lock/unlock while the option is on, so an invisible
      -- frame never shows a drag handle.
      draggableIf = function() return db and db.twoMobIcon == true end,
      saveFromScreen = function() HK.SaveDragged(iconFrame, db) end })
end

local function BuildBar()
  if frame then return end
  frame = CreateFrame("Frame", "HunterKitShotTimer", UIParent)
  frame:SetFrameStrata("MEDIUM")
  frame:EnableMouse(false)
  frame:Hide()

  track = frame:CreateTexture(nil, "BACKGROUND")
  track:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
  track:SetTexture("Interface\\Buttons\\WHITE8x8")
  Paint(track, COL_TRACK)

  -- The lockout zone, pinned to the RIGHT edge: the bar fills left-to-right
  -- toward the shot, so "the end" is where the danger is.
  castZone = frame:CreateTexture(nil, "BORDER")
  castZone:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
  castZone:SetTexture("Interface\\Buttons\\WHITE8x8")
  Paint(castZone, COL_ZONE)

  fill = frame:CreateTexture(nil, "ARTWORK")
  fill:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
  fill:SetTexture("Interface\\Buttons\\WHITE8x8")
  Paint(fill, COL_CHARGING)

  -- A hairline at the safe/locked boundary. The eye tracks a line crossing a
  -- mark far better than it judges a colour change.
  safeMark = frame:CreateTexture(nil, "OVERLAY")
  safeMark:SetTexture("Interface\\Buttons\\WHITE8x8")
  safeMark:SetVertexColor(1, 1, 1, 0.85)

  -- The weave marker: the last moment you could still leave and get back in
  -- time. Left of it, going is safe; right of it, you would clip the shot.
  weaveMark = frame:CreateTexture(nil, "OVERLAY")
  weaveMark:SetTexture("Interface\\Buttons\\WHITE8x8")
  weaveMark:SetVertexColor(0.4, 0.75, 1, 0.95)

  -- A thin second strip underneath for the MELEE cycle. Separate on purpose:
  -- in Era the two cycles are independent, and drawing them as one bar would
  -- imply a relationship the game does not have.
  -- The track was black at 50% alpha, which is invisible against a dark UI --
  -- so with no swing observed yet (an empty fill) the whole melee row looked
  -- like it simply was not there. This is the "no melee weapon timer" report.
  -- A lighter, clearly-visible slate makes the empty row read as a real,
  -- waiting bar rather than nothing at all.
  meleeTrack = frame:CreateTexture(nil, "BACKGROUND")
  meleeTrack:SetTexture("Interface\\Buttons\\WHITE8x8")
  Paint(meleeTrack, COL_TRACK)
  meleeFill = frame:CreateTexture(nil, "ARTWORK")
  meleeFill:SetTexture("Interface\\Buttons\\WHITE8x8")
  Paint(meleeFill, COL_CHARGING)

  label = frame:CreateFontString(nil, "OVERLAY")
  label:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
  label:SetPoint("LEFT", frame, "LEFT", 4, 0)
  label:SetText("")

  -- The measured clip. Sits to the right, out of the bar's way.
  delayText = frame:CreateFontString(nil, "OVERLAY")
  delayText:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
  delayText:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 2, 3)
  delayText:SetText("")

  -- The lockout's measured tail. castZone is drawn from the FIXED 0.5s cast,
  -- but the honest boundary is 0.5s plus your own latency -- which is exactly
  -- what the "+0.34s" readout measures. Super Swing Timer calls this a latency
  -- end-slice and it is the difference between a bar that is theoretically
  -- right and one that matches what actually happens on your connection. Drawn
  -- inside the red zone, extending right from its left edge by the measured
  -- clip, so it only appears once you HAVE a measurement.
  latencySlice = frame:CreateTexture(nil, "OVERLAY")
  latencySlice:SetTexture("Interface\\Buttons\\WHITE8x8")
  Paint(latencySlice, COL_LATENCY)

  -- The state strip: one line that says where you are. This is the indicator
  -- the two-mob weave never had.
  rangeStrip = frame:CreateTexture(nil, "BACKGROUND")
  rangeStrip:SetTexture("Interface\\Buttons\\WHITE8x8")
  Paint(rangeStrip, COL_SHOOTING)
  rangeStripText = frame:CreateFontString(nil, "OVERLAY")
  rangeStripText:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
  rangeStripText:SetJustifyH("CENTER")
  rangeStripText:SetText("")

  -- "What to press next", the Fluffy Hunter Bars idea: rather than only
  -- showing clocks, say which button is worth pressing. Opt-in, because it
  -- restates the special pips for players who already read those.
  reco = frame:CreateFontString(nil, "OVERLAY")
  reco:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
  reco:SetJustifyH("LEFT")
  reco:SetText("")

  HK.CreateBorder(frame)
  ApplySize()
  ShotTimer.ApplyPosition()

  HK.RegisterDraggable("shottimer", frame,
    function() ShotTimer.ApplyPosition() end,
    function(x, y)
      db.offsetX, db.offsetY, db.moved = x, y, true
    end,
    { -- MUST convert the drop point into UIParent-CENTRE space before saving.
      -- The drag loop pins the frame with SetPoint("CENTER", UIParent,
      -- "BOTTOMLEFT", ...); without this the generic fallback saved those raw
      -- BOTTOMLEFT coordinates and ApplyPosition re-applied them as CENTRE
      -- offsets, so on lock the bar jumped by half the screen -- up and to the
      -- right, from wherever you dropped it. HK.SaveDragged does the conversion.
      saveFromScreen = function() HK.SaveDragged(frame, db) end,
      onUpdate = function()
        -- RegisterDraggable blanks OnUpdate across a drag/lock cycle; re-bind
        -- if we were animating (the trap PassivePulse.lua documents).
        if onUpdateBound and frame then frame:SetScript("OnUpdate", ShotTimer.OnUpdate) end
      end })
end

function ShotTimer.ApplyPosition()
  if not frame then return end
  frame:ClearAllPoints()
  -- One anchor for both cases: the saved offset is always measured from
  -- UIParent's CENTRE (see HK.SaveDragged), whether it came from the default or
  -- from a drag. Both branches of the old if/else were identical anyway.
  local x = tonumber(db and db.offsetX) or HK.defaults.shottimer.offsetX
  local y = tonumber(db and db.offsetY) or HK.defaults.shottimer.offsetY
  frame:SetPoint("CENTER", UIParent, "CENTER", x, y)
  -- The icon follows the bar until the player drags it somewhere of their own.
  ApplyIconPosition()
end

-- ---------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------
-- Hide every child texture/font string that is NOT part of the plain bar.
--
-- Textures do NOT hide with their parent frame in the WoW API -- Hide() on the
-- frame stops it drawing, but a child that was explicitly Show()n keeps its own
-- shown state, and re-showing the parent brings the stale children straight
-- back. That is why switching a row off (or ending a fight) could leave green
-- pips hanging on screen for a few seconds until something else redrew. Every
-- teardown path routes through here so nothing can be forgotten.
local function HideExtras()
  if meleeFill then meleeFill:Hide() end
  if meleeTrack then meleeTrack:Hide() end
  if weaveMark then weaveMark:Hide() end
  -- 0.9.71 widgets hide with the rest, so an idle bar leaves nothing behind.
  if rangeStrip then rangeStrip:Hide() end
  if rangeStripText then rangeStripText:Hide() end
  if reco then reco:Hide() end
  if latencySlice then latencySlice:Hide() end
  if iconFrame then iconFrame:Hide() end
  lastStripCol, lastStripTxt, lastLatW = nil, nil, -1
  lastRecoTxt, lastIconCol, lastIconTxt, lastIconA = nil, nil, nil, nil
  if specialRow then
    for i = 1, 2 do
      if specialRow[i] then specialRow[i]:Hide() end
      if specialRow[i .. "text"] then specialRow[i .. "text"]:Hide() end
    end
  end
end

-- The special-shot pips. Dark means on cooldown, which is exactly when a weave
-- is the correct use of the gap. Split out of Redraw so that every path which
-- can change their visibility -- a live redraw, the idle bar, and a settings
-- change -- goes through the same code.
local function DrawSpecialPips(now)
  if not specialRow then return end
  if db.weave == false or db.showSpecials == false then
    for i = 1, 2 do
      ShownIf(specialRow[i], false)
      ShownIf(specialRow[i .. "text"], false)
    end
    return
  end
  local _, aimedIn, multiIn = ShotTimer.SpecialsDown(now)
  local names = { "Aimed", "Multi" }
  local lefts = { aimedIn, multiIn }
  for i = 1, 2 do
    local pip, fs = specialRow[i], specialRow[i .. "text"]
    local left = lefts[i]
    if left == nil then
      -- Not trained: hide the pip rather than implying it is ready to press.
      ShownIf(pip, false); ShownIf(fs, false)
      left = nil
    end
    -- The countdown is whole seconds, so this text changes once a second while
    -- OnUpdate runs every frame. Cache both it and the colour.
    local txt, col
    if left == nil then
      txt = nil
    elseif left > 0 then
      col = COL_PIP_DOWN
      txt = string.format("|cff9a9a9a%s %.0fs|r", names[i], left)
    else
      col = COL_PIP_READY
      txt = string.format("|cff55dd55%s|r", names[i])
    end
    if txt then
      specialRow[i .. "col"] = PaintIf(pip, col, specialRow[i .. "col"])
      if txt ~= specialRow[i .. "txt"] then
        fs:SetText(txt); specialRow[i .. "txt"] = txt
      end
      ShownIf(pip, true); ShownIf(fs, true)
    end
  end
end

local function Redraw(now)
  if not frame or not frame:IsShown() then return end
  local remaining, total, locked = ShotTimer.Progress(now)
  local w = tonumber(db.width) or 220
  -- Needed by the latency slice below. This was missing: SetHeight(h) resolved
  -- `h` to the GLOBAL (nil, since `h` is a local of ApplySize) and the live
  -- client rejects that -- "bad argument #1 to 'SetHeight'" -- every frame.
  local h = tonumber(db.height) or 27

  if remaining then
    -- Fill grows toward the shot, so the bar is "charging up" to fire.
    local done = 1 - (remaining / math.max(total, MIN_SPEED))
    if done < 0 then done = 0 elseif done > 1 then done = 1 end
    lastFillW = SetWidthIf(fill, math.max(1, w * done), lastFillW)
    -- Same three-state rule as the melee bar below.
    local c
    if locked then
      c = COL_LOCKED                             -- acting now clips the shot
    elseif remaining <= CAST_TIME then
      c = COL_READY                              -- about to fire
    else
      c = COL_CHARGING                           -- winding up, free to act
    end
    lastFillCol = PaintIf(fill, c, lastFillCol)

    if db.showText ~= false then
      local free = remaining - CAST_TIME
      local txt
      if free > 0 then
        -- While a weave actually fits, say so: that is the one moment the
        -- player has a decision to make, and the number alone does not tell
        -- them whether it is enough.
        --
        -- The two weapons run at different speeds and drift apart, so "GO" and
        -- a countdown to the ideal departure is far more use than a flat yes:
        -- it tells you WHEN the shot cycle and the swing actually line up.
        local best, _, why = ShotTimer.WeaveWindow(now)
        if db.weave ~= false and best then
          if best <= 0.05 and ShotTimer.CanWeave(now) then
            txt = string.format("|cff66ccffGO|r %.1fs", free)
          elseif best <= 0.05 then
            txt = string.format("%.1fs", free)
          else
            txt = string.format("|cff9fd8ffweave in %.1fs|r", best)
          end
        elseif db.weave ~= false and why == "specials" then
          -- Say WHY rather than going quiet: a silent bar looks broken, and
          -- "spend your shot first" is actionable.
          txt = string.format("|cffd9b333shoot|r %.1fs", free)
        else
          txt = string.format("%.1fs", free)
        end
      else
        txt = "hold"
      end
      -- One decimal means this string only changes ~10x a second, but OnUpdate
      -- runs every frame. Skip the write when it has not moved.
      if txt ~= lastLabel then label:SetText(txt); lastLabel = txt end
    elseif lastLabel ~= "" then
      label:SetText(""); lastLabel = ""
    end
  else
    -- No live ranged cycle: an empty bed, exactly like the melee bar shows when
    -- it has seen no swing. Hiding the fill (rather than leaving a 1px sliver)
    -- makes the two bars read identically when idle.
    ShownIf(fill, false)
    lastFillW = -1
    if lastLabel ~= "" then label:SetText(""); lastLabel = "" end
  end
  if remaining then ShownIf(fill, true) end

  -- The melee cycle. The TRACK is always visible while weaving is enabled, even
  -- before we have seen a swing -- the speedrunner pattern is to shoot a distant
  -- target the pet is holding while meleeing a second one, so at the moment you
  -- most need to know where the melee bar is, you have not swung yet. Hiding the
  -- whole widget until the first swing made it look like the feature was
  -- missing. Only the FILL depends on having observed a swing; with none seen we
  -- show an empty track rather than invent a position we cannot know.
  if meleeTrack then
    if db.weave ~= false then
      ShownIf(meleeTrack, true)
      local mIn = ShotTimer.MeleeReady(now)
      if mIn then
        local done = 1 - (mIn / math.max(meleeSpeed, MELEE_MIN_SPEED))
        if done < 0 then done = 0 elseif done > 1 then done = 1 end
        lastMeleeW = SetWidthIf(meleeFill, math.max(1, w * done), lastMeleeW)
        -- Green once the swing is actually available to spend.
        lastMeleeCol = PaintIf(meleeFill,
          (mIn <= 0) and COL_READY or COL_CHARGING, lastMeleeCol)
        ShownIf(meleeFill, true)
      else
        -- No swing observed yet: an empty track, honestly blank.
        meleeFill:Hide()
        lastMeleeW = -1
      end
    else
      meleeFill:Hide(); meleeTrack:Hide()
      if weaveMark then weaveMark:Hide() end
    end
  end

  -- ---------------------------------------------------------------------
  -- The weave marker: WHERE on the shot cycle your melee hit belongs.
  --
  -- Two different meanings depending on how you weave, and it used to only
  -- ever draw the first:
  --   * running in ("normal" weave) -- the LAST moment you can leave and still
  --     get home before the lockout.
  --   * standing in melee (static)  -- the moment your SWING comes up, which
  --     is the only thing you are waiting for. The old marker drew the travel
  --     departure point here, which is meaningless when you never move, so
  --     static weavers had a line sitting at a nonsense place on the bar.
  -- ---------------------------------------------------------------------
  if weaveMark then
    if db.weave == false then
      ShownIf(weaveMark, false)
    else
      local cycle = math.max(total or MIN_SPEED, MIN_SPEED)
      local best = ShotTimer.WeaveWindow(now)
      local at
      if best and remaining then
        -- Seconds from the START of this cycle to the advised moment. `remaining`
        -- can read a hair above the nominal cycle length right after a shot
        -- (the server's timing is not perfectly aligned with ours), which would
        -- push this slightly negative -- clamp rather than lose the marker.
        at = (cycle - remaining) + best
        if at < 0 then at = 0 end
      end
      -- at == 0 is legitimate ("go now, right at the start of the cycle"), so
      -- only reject a marker that would fall off the end of the bar.
      if at and at >= 0 and at < cycle then
        weaveMark:ClearAllPoints()
        -- Clamp to the bar so a marker at 0 is still visible rather than
        -- clipped against the left edge.
        local x = w * (at / cycle)
        if x < 1 then x = 1 elseif x > w - 3 then x = w - 3 end
        weaveMark:SetPoint("TOPLEFT", frame, "TOPLEFT", x, 0)
        -- Green once you should go, blue while it is still ahead of you: the
        -- same ready/charging language the bars themselves use.
        Paint(weaveMark, (best <= 0.05) and COL_READY or COL_WEAVE)
        ShownIf(weaveMark, true)
      else
        ShownIf(weaveMark, false)
      end
    end
  end

  -- ---------------------------------------------------------------------
  -- The state strip: one legible line saying which situation you are in.
  --
  -- This is the indicator the two-mob weave never had. The old bar could only
  -- ever mark the travel-weave departure point, so a hunter standing in melee
  -- of one mob with the pet on a second one got nothing at all -- the single
  -- most common weaving setup was the one it stayed silent about.
  -- ---------------------------------------------------------------------
  if rangeStrip then
    if db.rangeStrip == false then
      ShownIf(rangeStrip, false); ShownIf(rangeStripText, false)
    else
      local st, s = ShotTimer.RangeState(now)
      local col, txt
      if st == "twogo" then
        col, txt = COL_TWOGO, "PRESS 2-MOB"
      elseif st == "two" then
        -- Set up but not yet time. Say WHAT you are waiting on: a bare "2-MOB"
        -- that never changes teaches you nothing about when to press.
        col = COL_TWO
        if not s.swingUp and s.swingIn then
          txt = string.format("2-MOB - SWING %.1fs", s.swingIn)
        elseif s.locked then
          txt = "2-MOB - SHOT LOCKED"
        else
          txt = "2-MOB READY"
        end
      elseif st == "melee" then
        col, txt = COL_INMELEE, "MELEE ONLY"
      elseif st == "oor" then
        col, txt = COL_OOR, "OUT OF RANGE"
      else
        col, txt = COL_SHOOTING, "RANGE"
      end
      lastStripCol = PaintIf(rangeStrip, col, lastStripCol)
      if txt ~= lastStripTxt then rangeStripText:SetText(txt); lastStripTxt = txt end
      ShownIf(rangeStrip, true); ShownIf(rangeStripText, true)
    end
  end

  -- ---------------------------------------------------------------------
  -- "What to press next", the Fluffy Hunter Bars idea: do not only show
  -- clocks, say which button is worth pressing. The two-mob macro ranks first
  -- because it is worth a whole extra melee swing on a second mob.
  -- ---------------------------------------------------------------------
  if reco then
    if db.recoRow == false then
      ShownIf(reco, false)
    else
      local rtxt
      local st, s = ShotTimer.RangeState(now)
      if st == "twogo" then
        rtxt = "|cff4dff73PRESS 2-MOB MACRO|r"
      elseif st == "two" then
        rtxt = "|cff66ccff2-mob set - wait for the swing|r"
      else
        local down, a, m = ShotTimer.SpecialsDown(now)
        if a ~= nil and a <= 0 then
          rtxt = "|cffff9d33AIMED SHOT|r"
        elseif m ~= nil and m <= 0 then
          rtxt = "|cff66b3ffMULTI-SHOT|r"
        elseif s.raptorIn ~= nil and s.raptorIn <= 0 and st == "melee" then
          rtxt = "|cff4dff73RAPTOR STRIKE|r"
        elseif down then
          rtxt = "|cff9fd8ffweave|r"
        else
          rtxt = "|cff909098hold|r"
        end
      end
      if rtxt ~= lastRecoTxt then reco:SetText(rtxt); lastRecoTxt = rtxt end
      ShownIf(reco, true)
    end
  end

  -- ---------------------------------------------------------------------
  -- The latency end-slice. The red lockout is drawn from the FIXED 0.5s cast,
  -- but the boundary that actually costs you damage is 0.5s plus YOUR latency
  -- -- precisely what the "+0.34s" readout measures. Painting that measured
  -- tail into the bar turns a number you have to read into a region you can
  -- see, which is what Super Swing Timer does with its latency slice.
  --
  -- Geometry: the bar fills left-to-right toward the shot, so the danger
  -- region hangs off the RIGHT edge and the extra latency pushes its start
  -- further LEFT. The slice therefore sits immediately left of the red zone
  -- and EXTENDS it, rather than overlapping it.
  --
  -- Width is scaled against the WHOLE cycle: the bar spans `speed` seconds
  -- over `w` pixels. (An earlier form of this wrote it as castZoneWidth *
  -- secs/CAST_TIME -- algebraically the same thing, CAST_TIME cancels. Kept in
  -- the direct form because it is the one you can read off the bar.)
  --
  -- The clamp is `cyc`, not a fixed 2s: on a fast weapon 2s of "latency" would
  -- draw a slice wider than the bar itself. Bounding the clip measurement to
  -- one cycle (see OnShotFired) already makes that unreachable, so this is the
  -- belt to those braces -- but a slice must never outgrow its bar.
  -- ---------------------------------------------------------------------
  if latencySlice and castZone then
    local cyc = math.max(speed, MIN_SPEED)
    local secs = (lastDelay > CLIP_EPSILON) and lastDelay or 0
    if secs > cyc then secs = cyc end              -- never wider than the bar
    local lw = math.floor(w * (secs / cyc))
    lastLatW = SetWidthIf(latencySlice, lw, lastLatW)
    if lw >= 1 then
      latencySlice:ClearAllPoints()
      latencySlice:SetPoint("TOPRIGHT", castZone, "TOPLEFT", 0, 0)
      latencySlice:SetHeight(h)
      ShownIf(latencySlice, true)
    else
      ShownIf(latencySlice, false)
    end
  end

  -- ---------------------------------------------------------------------
  -- The two-mob icon. Lit and bright only when pressing the macro is correct;
  -- dimmed but visible while the setup exists, so you can see it coming
  -- rather than having it pop into existence.
  -- ---------------------------------------------------------------------
  if iconFrame then
    if db.twoMobIcon ~= true then
      ShownIf(iconFrame, false)
    else
      local s = ShotTimer.TwoMob(now)
      local col, txt, alpha
      if s.press then
        col, txt, alpha = COL_TWOGO, "NOW", 1.0
      elseif s.setup then
        -- Waiting on a cycle: show the countdown, dimmed.
        col, alpha = COL_TWO, 0.55
        if s.swingIn and not s.swingUp then
          txt = string.format("%.1f", s.swingIn)
        else
          txt = ""
        end
      else
        col, txt, alpha = COL_SHOOTING, "", 0.28
      end
      lastIconCol = PaintIf(iconTex, col, lastIconCol)
      if txt ~= lastIconTxt then iconText:SetText(txt); lastIconTxt = txt end
      if alpha ~= lastIconA then iconFrame:SetAlpha(alpha); lastIconA = alpha end
      ShownIf(iconFrame, true)
    end
  end

  DrawSpecialPips(now)

  -- The measured clip from the previous shot, held briefly then faded out.
  local dtxt = ""
  if db.showDelay ~= false and delayShownAt > 0
     and (now - delayShownAt) < DELAY_HOLD and lastDelay > CLIP_EPSILON then
    dtxt = string.format("|cffff4040+%.2fs|r", lastDelay)
  end
  if dtxt ~= lastDelayStr then delayText:SetText(dtxt); lastDelayStr = dtxt end
end

function ShotTimer.OnUpdate()
  local now = tonumber(Call(GetTime)) or 0
  Redraw(now)
end

local function BindOnUpdate(on)
  if not frame then return end
  if on == onUpdateBound then return end          -- idempotent
  onUpdateBound = on
  frame:SetScript("OnUpdate", on and ShotTimer.OnUpdate or nil)
end

-- ---------------------------------------------------------------------------
-- Visibility
--
-- The bar is meaningless when you are not shooting, and a permanent empty bar
-- is just clutter -- so it appears with auto-repeat and leaves with it.
-- ---------------------------------------------------------------------------
local function ShouldShow()
  if not db or not db.enabled then return false end
  if not HK.isHunter then return false end
  if HK.Editing and HK.Editing() then return true end
  -- "Keep the bar on screen" -- a fixed readout rather than one that appears
  -- and vanishes. It still only ANIMATES while a cycle is running (see
  -- Refresh); when idle it shows an empty, full-length track so you can see
  -- where it is and how much lockout a shot will cost.
  if db.always then return true end

  -- Stay up in melee while weaving is enabled.
  --
  -- Stepping into melee range STOPS auto-repeat, which used to hide the whole
  -- bar -- precisely when a weaving hunter needs it most. The melee half of the
  -- display is the entire point of standing there, and the ranged cycle is
  -- still running behind it (Era does not link them), so hiding everything the
  -- moment you close the distance defeats the feature. Super Swing Timer solves
  -- the same problem with a short hold-over to stop the bar flickering between
  -- cycles; we keep it up for the whole of combat instead, which is simpler and
  -- has no flicker at all.
  if db.weave ~= false and Call(UnitAffectingCombat, "player") == true then
    return true
  end

  if not repeating then return false end
  return nextAt ~= nil
end

-- Whether ANY cycle is running behind the bar. Distinct from ShouldShow: with
-- `always` on, the bar is visible while completely idle.
--
-- This must consider the MELEE cycle too, not just the ranged one. In melee
-- range auto-repeat stops, so the ranged cycle is dead -- but the melee swing
-- is very much alive, and that is the whole reason a weaving hunter is stood
-- there. Judging "idle" on the ranged cycle alone parked the update loop and
-- left the melee bar frozen at zero: a dead grey strip that never filled. It is
-- only truly idle when neither cycle has anything to animate.
function ShotTimer.IsIdle()
  -- A prediction outlives auto-repeat (see STOP_AUTOREPEAT_SPELL), so "is the
  -- ranged cycle live" is about the CLOCK, not the auto-repeat flag.
  if nextAt ~= nil and (tonumber(Call(GetTime)) or 0) < nextAt then return false end
  if repeating and nextAt ~= nil then return false end
  if db and db.weave ~= false and meleeSwungAt ~= nil then
    -- A swing we have observed is still counting down (or has just come up and
    -- the bar should be sitting full/green rather than blank).
    local now = tonumber(Call(GetTime)) or 0
    if (now - meleeSwungAt) < (MELEE_IDLE_AFTER * math.max(meleeSpeed, MELEE_MIN_SPEED)) then
      return false
    end
  end
  return true
end

function ShotTimer.Refresh()
  if not frame then return end
  local show = ShouldShow()
  if show then
    ApplySize()
    frame:Show()
    BindOnUpdate(true)
    if HK.Editing and HK.Editing() then
      -- A static, readable sample so the bar can be dragged into place.
      fill:SetWidth((tonumber(db.width) or 220) * 0.6)
      Paint(fill, COL_CHARGING)
      label:SetText("1.2s")
      delayText:SetText("|cffff4040+0.34s|r")
      BindOnUpdate(false)          -- never animate a frame being dragged
    elseif ShotTimer.IsIdle() then
      -- Shown but idle (the "keep it on screen" option). Draw an empty track
      -- with the lockout zone still to scale, so the bar reads as "ready" and
      -- keeps its meaning, and stop the OnUpdate loop -- there is nothing to
      -- animate, and a permanent per-frame loop for a static bar is waste.
      fill:SetWidth(0.001)
      label:SetText(db.showText and "|cff808080ready|r" or "")
      delayText:SetText("")
      -- Keep the melee track visible (empty) so the parked bar shows its full
      -- layout rather than silently losing a row.
      if meleeFill then meleeFill:Hide() end
      if meleeTrack then
        if db.weave ~= false then meleeTrack:Show() else meleeTrack:Hide() end
      end
      DrawSpecialPips(tonumber(Call(GetTime)) or 0)
      BindOnUpdate(false)
    else
      ShotTimer.OnUpdate()
    end
  else
    BindOnUpdate(false)
    HideExtras()      -- child textures do NOT hide with their parent
    frame:Hide()
  end
end

-- ---------------------------------------------------------------------------
-- Events: the shot cycle
-- ---------------------------------------------------------------------------

-- The shot released. This is the anchor for everything: it is the only moment
-- the server tells us the truth about where we are in the cycle.
local function OnShotFired(now)
  now = now or (tonumber(Call(GetTime)) or 0)

  -- Measure the clip BEFORE moving the prediction on. `nextAt` still holds what
  -- we expected, so the difference is the honest cost of whatever the player
  -- did during the last cycle. This is the number the feature is really for.
  if nextAt then
    local delta = now - nextAt
    -- A clip is bounded by the cycle it belongs to: the worst real case is
    -- roughly the cast plus your latency, and even a fully missed shot cannot
    -- be more than a cycle late. A LARGER delta is not a clip at all -- it
    -- means auto-repeat was off (you stopped shooting, swapped target, died,
    -- logged in) and `nextAt` is simply stale from the last cycle.
    --
    -- Without this bound, resuming after any pause printed the whole gap as a
    -- clip: "+18.17s", and counted it, which is exactly what the 0.9.71
    -- latency slice then tried to draw. `speed` here is still the PREVIOUS
    -- cycle's, which is the one `nextAt` was derived from.
    if delta > CLIP_EPSILON and delta <= speed then
      lastDelay = delta
      delayShownAt = now
      clipCount = clipCount + 1
    else
      lastDelay = 0
    end
  end
  shotCount = shotCount + 1

  -- Re-read the speed every shot: haste procs change it mid-fight, and using a
  -- stale value would silently mis-place the lockout zone.
  speed = ReadSpeed() or speed
  shotAt = now
  nextAt = now + speed
  castStartedAt = nil
  ApplySize()               -- the lockout's share moves with the speed
  ShotTimer.Refresh()
end

-- The 0.5s cast began -- server-confirmed, so it is a better anchor for the
-- lockout than our own prediction. If the server started the cast later than we
-- expected (movement, the re-shot timer), believe the server.
local function OnCastStarted(now)
  now = now or (tonumber(Call(GetTime)) or 0)
  castStartedAt = now
  local predicted = now + CAST_TIME
  -- Only ever push the prediction LATER. Pulling it earlier on a fast client
  -- would make the bar jump backwards, which reads as a bug.
  if not nextAt or predicted > nextAt then nextAt = predicted end
  ShotTimer.Refresh()
end

-- Aimed Shot restarts the auto-shot cycle: a full weapon-speed wait begins when
-- it lands. Without this the bar would count down to a shot that never comes.
local function OnTimerReset(now)
  now = now or (tonumber(Call(GetTime)) or 0)
  speed = ReadSpeed() or speed
  shotAt = now
  nextAt = now + speed
  castStartedAt = nil
  ShotTimer.Refresh()
end

-- ---------------------------------------------------------------------------
-- Melee swings, observed from the combat log.
--
-- There is no API for "when does my melee swing next". The only honest source
-- is a swing that actually landed, so we watch our own SWING_ events. Note this
-- also means a MISS or a PARRY still counts -- the weapon swung, which is what
-- resets the cycle, regardless of whether it connected.
-- ---------------------------------------------------------------------------
local playerGUID

local function OnCombatLog()
  if not db or db.weave == false then return end
  local ts, sub, _, srcGUID = Call(CombatLogGetCurrentEventInfo)
  if not sub then return end
  if not playerGUID then playerGUID = Call(UnitGUID, "player") end
  if srcGUID ~= playerGUID then return end
  -- SWING_DAMAGE and SWING_MISSED between them cover every outcome of an
  -- actual melee swing; spell casts use SPELL_ prefixes and are ignored.
  if sub ~= "SWING_DAMAGE" and sub ~= "SWING_MISSED" then return end
  local wasIdle = ShotTimer.IsIdle()
  meleeSpeed = ReadMeleeSpeed() or meleeSpeed
  meleeSwungAt = tonumber(Call(GetTime)) or 0

  -- A swing STARTS the melee cycle, so it has to wake the bar up.
  --
  -- The update loop is only attached while something is animating. With no
  -- ranged cycle running (you walked into melee, or never fired at all) the bar
  -- was parked, and nothing re-evaluated that when a swing arrived -- so the
  -- melee strip sat frozen at zero until some UNRELATED event happened to call
  -- Refresh. Toggling a setting was one such event, which is why re-checking
  -- the box "fixed" it. The first swing of a cycle now refreshes directly.
  if wasIdle then ShotTimer.Refresh() end
end

local function OnSpellSucceeded(unit, _, spellID)
  if unit ~= "player" then return end
  if spellID == AUTO_SHOT then
    OnShotFired()
  elseif AIMED_SHOT_IDS[spellID] then
    OnTimerReset()
  end
end

local function OnSpellStarted(unit, _, spellID)
  if unit ~= "player" then return end
  if spellID == AUTO_SHOT then OnCastStarted() end
end

-- ---------------------------------------------------------------------------
-- Diagnostics
-- ---------------------------------------------------------------------------
function ShotTimer.PrintDiag()
  print("|cff33ff99HunterKit|r shot timer:")
  print("  enabled: " .. tostring(db and db.enabled))
  print("  auto-repeat: " .. tostring(repeating))
  print(string.format("  ranged speed: %.2fs (cast %.2fs, free %.2fs)",
    speed, CAST_TIME, math.max(0, speed - CAST_TIME)))
  local remaining, _, locked = ShotTimer.Progress()
  if remaining then
    print(string.format("  next shot in: %.2fs%s", remaining,
      locked and " (LOCKED -- hold still)" or ""))
  else
    print("  next shot in: not shooting")
  end
  print(string.format("  shots: %d, clipped: %d, last clip: +%.2fs",
    shotCount, clipCount, lastDelay))
  if db and db.weave ~= false then
    local mIn = ShotTimer.MeleeReady()
    print(string.format("  melee speed: %.2fs, swing ready in: %s",
      meleeSpeed, mIn and string.format("%.2fs", mIn) or "no swing seen yet"))
    local ok, free, need = ShotTimer.CanWeave()
    print(string.format("  weave: %s (need %.2fs round trip, have %s)",
      ok and "YES -- go now" or "no", need,
      free and string.format("%.2fs", free) or "n/a"))
  end
end

function ShotTimer.RescanSettings()
  db = HK.db.shottimer
  if frame then
    ApplySize()
    ShotTimer.ApplyPosition()
    -- Clear every optional row BEFORE redrawing. Unticking "show Aimed/Multi"
    -- (or the weave marker) used to leave the pips on screen until the next
    -- animation frame happened to run -- and if the bar was idle or the fight
    -- had ended there was no next frame, so they simply stayed. Wiping first
    -- and letting the redraw re-add only what is still enabled makes a settings
    -- change take effect on the same click.
    HideExtras()
  end
  ShotTimer.Refresh()
  -- Refresh() only repaints when a cycle is live; force one so a settings
  -- change is visible at once even mid-cooldown.
  if frame and frame:IsShown() and not (HK.Editing and HK.Editing())
     and not ShotTimer.IsIdle() then
    ShotTimer.OnUpdate()
  end
end

function ShotTimer.Init()
  db = HK.db.shottimer
  if not HK.isHunter then return end          -- structural gate

  BuildBar()
  BuildSpecialPips()
  BuildTwoMobIcon()

  HK.On("UNIT_SPELLCAST_SUCCEEDED", OnSpellSucceeded)
  HK.On("UNIT_SPELLCAST_START", OnSpellStarted)
  -- The ONE combat-log registration in the addon, and only while weaving is on:
  -- there is no other way to observe a melee swing.
  HK.On("COMBAT_LOG_EVENT_UNFILTERED", OnCombatLog)

  -- Auto-repeat toggling is what shows and hides the bar.
  HK.On("START_AUTOREPEAT_SPELL", function()
    repeating = true
    speed = ReadSpeed() or speed
    ShotTimer.Refresh()
  end)
  HK.On("STOP_AUTOREPEAT_SPELL", function()
    repeating = false
    -- Do NOT clear nextAt.
    --
    -- Stepping into melee stops auto-repeat, and wiping the predicted shot time
    -- here collapsed the ranged bar to empty the instant your melee weapon
    -- connected -- which is precisely when a weaving hunter needs to see how
    -- much of the shot cycle is left. In Classic Era the two cycles are
    -- independent: a melee swing does not reset the ranged timer (that linkage
    -- is WotLK behaviour, confirmed by Blizzard for 3.3.5 only). The prediction
    -- stays valid, so the bar keeps counting down and simply expires on its own
    -- if no further shot lands. Super Swing Timer made the same change --
    -- it "no longer hard-resets the ranged timer on transient stop events".
    ShotTimer.Refresh()
  end)

  -- A new weapon changes the whole geometry of the bar.
  HK.On("PLAYER_EQUIPMENT_CHANGED", function()
    speed = ReadSpeed() or speed
    meleeSpeed = ReadMeleeSpeed() or meleeSpeed
    ApplySize()
  end)

  HK.On("PLAYER_ENTERING_WORLD", function()
    speed = ReadSpeed() or speed
    ShotTimer.Refresh()
  end)

  -- Leaving combat ends the series; stale predictions must not survive it.
  HK.On("PLAYER_REGEN_ENABLED", function()
    repeating = false
    nextAt = nil
    ShotTimer.Refresh()
  end)

  speed = ReadSpeed() or DEFAULT_SPEED
  meleeSpeed = ReadMeleeSpeed() or meleeSpeed
  playerGUID = Call(UnitGUID, "player")
  ApplySize()
  ShotTimer.Refresh()
end

-- Test/diagnostic seams: let a caller drive the cycle without a live client.
ShotTimer._OnShotFired = OnShotFired
ShotTimer._OnCastStarted = OnCastStarted
ShotTimer._OnTimerReset = OnTimerReset
function ShotTimer._SetRepeating(v) repeating = v and true or false end
function ShotTimer.IsShown() return frame ~= nil and frame:IsShown() == true end
function ShotTimer.FillWidth() return fill and fill:GetWidth() or 0 end
function ShotTimer.LabelText() return label and label.text or nil end
function ShotTimer.DelayText() return delayText and delayText.text or nil end
-- Test seams for the 0.9.71 widgets, so the state strip, the reco row and the
-- two-mob icon can be asserted the same way the bar itself is. Each returns
-- what is actually on screen rather than recomputing what ought to be.
function ShotTimer.StripText() return rangeStripText and rangeStripText.text or nil end
function ShotTimer.StripShown() return rangeStrip ~= nil and rangeStrip:IsShown() == true end
function ShotTimer.RecoText() return reco and reco.text or nil end
function ShotTimer.IconBuilt() return iconFrame ~= nil end
function ShotTimer.IconShown() return iconFrame ~= nil and iconFrame:IsShown() == true end
function ShotTimer.IconAlpha() return iconFrame and iconFrame.alpha or nil end
function ShotTimer.IconText() return iconText and iconText.text or nil end
function ShotTimer.LatencyWidth() return latencySlice and latencySlice:GetWidth() or nil end
function ShotTimer.LatencyShown()
  return latencySlice ~= nil and latencySlice:IsShown() == true
end
function ShotTimer.IsAnimating() return onUpdateBound end
function ShotTimer._OnMeleeSwing(t)
  meleeSpeed = ReadMeleeSpeed() or meleeSpeed
  meleeSwungAt = t or (tonumber(Call(GetTime)) or 0)
end
function ShotTimer._ClearMelee() meleeSwungAt = nil end
ShotTimer._OnCombatLog = OnCombatLog
-- Test seam: how far the melee fill has progressed, in pixels.
function ShotTimer.RangedTrackColor()
  if not track then return nil end
  return track:GetVertexColor()
end
function ShotTimer.FillColor()
  if not fill or not fill:IsShown() then return nil end
  return fill:GetVertexColor()
end
function ShotTimer.MeleeFillColor()
  if not meleeFill or not meleeFill:IsShown() then return nil end
  return meleeFill:GetVertexColor()
end
function ShotTimer.MeleeFillWidth()
  if not meleeFill or not meleeFill:IsShown() then return 0 end
  return meleeFill:GetWidth() or 0
end
function ShotTimer.MeleeTrackColor()
  if not meleeTrack then return nil end
  return meleeTrack:GetVertexColor()
end
function ShotTimer.MeleeTrackShown()
  return meleeTrack ~= nil and meleeTrack:IsShown() == true
end
function ShotTimer.SpecialPipsShown()
  return specialRow ~= nil and specialRow[1] ~= nil
    and specialRow[1]:IsShown() == true
end
-- Test seams: where the weave marker sits, and what colour it is.
function ShotTimer.WeaveMarkX()
  if not weaveMark or not weaveMark:IsShown() then return nil end
  local p = weaveMark.points and weaveMark.points[#weaveMark.points]
  return p and tonumber(p[4]) or nil
end
function ShotTimer.WeaveMarkColor()
  if not weaveMark or not weaveMark:IsShown() then return nil end
  return weaveMark:GetVertexColor()
end
function ShotTimer.WeaveMarkShown() return weaveMark ~= nil and weaveMark:IsShown() == true end

HK.RegisterModule("ShotTimer", { Init = ShotTimer.Init })
