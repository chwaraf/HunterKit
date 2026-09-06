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
-- lands nothing -- and it refuses while hasted, because every guide is emphatic
-- that a hasted cycle is too short to weave and doing so loses damage.
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
  local travel = tonumber(db and db.travel) or DEFAULT_TRAVEL
  if not free then return false, nil, travel end

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
function ShotTimer.WeaveWindow(now)
  now = tonumber(now) or (tonumber(Call(GetTime)) or 0)
  if not db or db.weave == false then return nil end
  local free = ShotTimer.SafeWindow(now)
  if not free then return nil end
  local travel = tonumber(db.travel) or DEFAULT_TRAVEL
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
local function ApplySize()
  if not frame then return end
  local w = tonumber(db and db.width) or 220
  local h = tonumber(db and db.height) or 18
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

  -- The two special-shot pips, on their own row under the melee strip so the
  -- shot bar, the melee swing and the specials read top-to-bottom.
  if specialRow then
    local pipH = math.max(3, math.floor(h / 3))
    local pipW = math.max(16, math.floor(w * 0.12))
    local top = -(mh + 4)
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

  -- The weave marker's position: the round trip measured back from the shot.
  -- Anything left of this line is a safe departure.
  if weaveMark then
    local travel = tonumber(db and db.travel) or DEFAULT_TRAVEL
    local latest = speed - CAST_TIME - travel      -- seconds into the cycle
    weaveMark:ClearAllPoints()
    weaveMark:SetSize(2, h)
    if latest > 0 then
      weaveMark:SetPoint("TOPLEFT", frame, "TOPLEFT",
        w * (latest / math.max(speed, MIN_SPEED)), 0)
      weaveMark:Show()
    else
      -- The trip does not fit in this weapon's cycle at all: no honest place to
      -- put the line, so do not draw one.
      weaveMark:Hide()
    end
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
    if delta > CLIP_EPSILON then
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
function ShotTimer.WeaveMarkShown() return weaveMark ~= nil and weaveMark:IsShown() == true end

HK.RegisterModule("ShotTimer", { Init = ShotTimer.Init })
