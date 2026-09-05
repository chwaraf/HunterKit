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
  return unpack(r, 2, r.n or #r)
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
local function SpellReadyIn(id, now)
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
function ShotTimer.SpecialsDown(now)
  now = now or (tonumber(Call(GetTime)) or 0)
  local a = SpellReadyIn(SPELL_AIMED, now)
  local m = SpellReadyIn(SPELL_MULTI, now)
  return (a > 0 and m > 0), a, m
end

-- ---------------------------------------------------------------------------
function ShotTimer.CanWeave(now)
  now = tonumber(now) or (tonumber(Call(GetTime)) or 0)
  local free = ShotTimer.SafeWindow(now)
  local travel = tonumber(db and db.travel) or DEFAULT_TRAVEL
  if not free then return false, nil, travel end

  -- The melee swing must be off cooldown by the time we arrive, or the trip
  -- buys nothing.
  local meleeIn = ShotTimer.MeleeReady(now)
  if meleeIn and meleeIn > (travel / 2) then
    return false, free, travel
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
  track:SetTexture("Interface\\Buttons\\WHITE8X8")
  track:SetVertexColor(0, 0, 0, 0.55)

  -- The lockout zone, pinned to the RIGHT edge: the bar fills left-to-right
  -- toward the shot, so "the end" is where the danger is.
  castZone = frame:CreateTexture(nil, "BORDER")
  castZone:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
  castZone:SetTexture("Interface\\Buttons\\WHITE8X8")
  castZone:SetVertexColor(0.75, 0.12, 0.12, 0.55)

  fill = frame:CreateTexture(nil, "ARTWORK")
  fill:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
  fill:SetTexture("Interface\\Buttons\\WHITE8X8")
  fill:SetVertexColor(0.2, 0.9, 0.3, 0.9)

  -- A hairline at the safe/locked boundary. The eye tracks a line crossing a
  -- mark far better than it judges a colour change.
  safeMark = frame:CreateTexture(nil, "OVERLAY")
  safeMark:SetTexture("Interface\\Buttons\\WHITE8X8")
  safeMark:SetVertexColor(1, 1, 1, 0.85)

  -- The weave marker: the last moment you could still leave and get back in
  -- time. Left of it, going is safe; right of it, you would clip the shot.
  weaveMark = frame:CreateTexture(nil, "OVERLAY")
  weaveMark:SetTexture("Interface\\Buttons\\WHITE8X8")
  weaveMark:SetVertexColor(0.4, 0.75, 1, 0.95)

  -- A thin second strip underneath for the MELEE cycle. Separate on purpose:
  -- in Era the two cycles are independent, and drawing them as one bar would
  -- imply a relationship the game does not have.
  meleeTrack = frame:CreateTexture(nil, "BACKGROUND")
  meleeTrack:SetTexture("Interface\\Buttons\\WHITE8X8")
  meleeTrack:SetVertexColor(0, 0, 0, 0.5)
  meleeFill = frame:CreateTexture(nil, "ARTWORK")
  meleeFill:SetTexture("Interface\\Buttons\\WHITE8X8")
  meleeFill:SetVertexColor(0.85, 0.7, 0.2, 0.9)

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
local function Redraw(now)
  if not frame or not frame:IsShown() then return end
  local remaining, total, locked = ShotTimer.Progress(now)
  local w = tonumber(db.width) or 220

  if remaining then
    -- Fill grows toward the shot, so the bar is "charging up" to fire.
    local done = 1 - (remaining / math.max(total, MIN_SPEED))
    if done < 0 then done = 0 elseif done > 1 then done = 1 end
    fill:SetWidth(math.max(1, w * done))
    if locked then
      fill:SetVertexColor(1, 0.3, 0.1, 0.95)     -- hold still
    else
      fill:SetVertexColor(0.2, 0.9, 0.3, 0.9)    -- free to act
    end

    if db.showText ~= false then
      local free = remaining - CAST_TIME
      if free > 0 then
        -- While a weave actually fits, say so: that is the one moment the
        -- player has a decision to make, and the number alone does not tell
        -- them whether it is enough.
        if db.weave ~= false and ShotTimer.CanWeave(now) then
          label:SetFormattedText("|cff66ccffWEAVE|r %.1fs", free)
        else
          label:SetFormattedText("%.1fs", free)
        end
      else
        label:SetText("hold")
      end
    else
      label:SetText("")
    end
  else
    fill:SetWidth(1)
    label:SetText("")
  end

  -- The melee cycle. The TRACK is always visible while weaving is enabled, even
  -- before we have seen a swing -- the speedrunner pattern is to shoot a distant
  -- target the pet is holding while meleeing a second one, so at the moment you
  -- most need to know where the melee bar is, you have not swung yet. Hiding the
  -- whole widget until the first swing made it look like the feature was
  -- missing. Only the FILL depends on having observed a swing; with none seen we
  -- show an empty track rather than invent a position we cannot know.
  if meleeTrack then
    if db.weave ~= false then
      meleeTrack:Show()
      local mIn = ShotTimer.MeleeReady(now)
      if mIn then
        local done = 1 - (mIn / math.max(meleeSpeed, MELEE_MIN_SPEED))
        if done < 0 then done = 0 elseif done > 1 then done = 1 end
        meleeFill:SetWidth(math.max(1, w * done))
        -- Green once the swing is actually available to spend.
        if mIn <= 0 then
          meleeFill:SetVertexColor(0.3, 0.9, 0.3, 0.9)
        else
          meleeFill:SetVertexColor(0.85, 0.7, 0.2, 0.9)
        end
        meleeFill:Show()
      else
        -- No swing observed yet: an empty track, honestly blank.
        meleeFill:Hide()
      end
    else
      meleeFill:Hide(); meleeTrack:Hide()
      if weaveMark then weaveMark:Hide() end
    end
  end

  -- The special-shot pips. Dark means on cooldown, which is exactly when a
  -- weave is the correct use of the gap.
  if specialRow then
    if db.weave ~= false and db.showSpecials ~= false then
      local _, aimedIn, multiIn = ShotTimer.SpecialsDown(now)
      local pairsIn = { { "Aimed", aimedIn }, { "Multi", multiIn } }
      for i = 1, 2 do
        local pip, fs = specialRow[i], specialRow[i .. "text"]
        local left = pairsIn[i][2] or 0
        if left > 0 then
          pip:SetVertexColor(0.35, 0.35, 0.38, 0.9)      -- on cooldown
          fs:SetFormattedText("|cff9a9a9a%s %.0fs|r", pairsIn[i][1], left)
        else
          pip:SetVertexColor(0.30, 0.90, 0.30, 0.95)     -- ready: spend it
          fs:SetFormattedText("|cff55dd55%s|r", pairsIn[i][1])
        end
        pip:Show(); fs:Show()
      end
    else
      for i = 1, 2 do
        if specialRow[i] then specialRow[i]:Hide() end
        if specialRow[i .. "text"] then specialRow[i .. "text"]:Hide() end
      end
    end
  end

  -- The measured clip from the previous shot, held briefly then faded out.
  if db.showDelay ~= false and delayShownAt > 0
     and (now - delayShownAt) < DELAY_HOLD and lastDelay > CLIP_EPSILON then
    delayText:SetFormattedText("|cffff4040+%.2fs|r", lastDelay)
  else
    delayText:SetText("")
  end
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
  if not repeating then return false end
  return nextAt ~= nil
end

-- Whether a live cycle is actually running behind the bar. Distinct from
-- ShouldShow: with `always` on, the bar is visible while completely idle.
function ShotTimer.IsIdle()
  return not (repeating and nextAt ~= nil)
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
      fill:SetVertexColor(0.2, 0.9, 0.3, 0.9)
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
      BindOnUpdate(false)
    else
      ShotTimer.OnUpdate()
    end
  else
    BindOnUpdate(false)
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
  meleeSpeed = ReadMeleeSpeed() or meleeSpeed
  meleeSwungAt = tonumber(Call(GetTime)) or 0
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
  end
  ShotTimer.Refresh()
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
    nextAt = nil
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
function ShotTimer.MeleeTrackShown()
  return meleeTrack ~= nil and meleeTrack:IsShown() == true
end
function ShotTimer.SpecialPipsShown()
  return specialRow ~= nil and specialRow[1] ~= nil
    and specialRow[1]:IsShown() == true
end
function ShotTimer.WeaveMarkShown() return weaveMark ~= nil and weaveMark:IsShown() == true end

HK.RegisterModule("ShotTimer", { Init = ShotTimer.Init })
