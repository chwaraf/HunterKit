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

local frame, track, fill, safeMark, castZone, tick, label, delayText
local onUpdateBound = false

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

local DELAY_HOLD  = 2.5      -- seconds the "+0.34s" readout lingers
local CLIP_EPSILON = 0.08    -- below this, a delay is latency noise, not a clip

-- Every client call is wrapped: a single missing API must not break the bar.
local function Call(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, a, b, c = pcall(fn, ...)
  if not ok then return nil end
  return a, b, c
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
    { onUpdate = function()
        -- RegisterDraggable blanks OnUpdate across a drag/lock cycle; re-bind
        -- if we were animating (the trap PassivePulse.lua documents).
        if onUpdateBound and frame then frame:SetScript("OnUpdate", ShotTimer.OnUpdate) end
      end })
end

function ShotTimer.ApplyPosition()
  if not frame then return end
  frame:ClearAllPoints()
  local x = tonumber(db and db.offsetX) or 0
  local y = tonumber(db and db.offsetY) or -140
  if db and db.moved then
    frame:SetPoint("CENTER", UIParent, "CENTER", x, y)
  else
    frame:SetPoint("CENTER", UIParent, "CENTER", x, y)
  end
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
        label:SetFormattedText("%.1fs", free)
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
  if not repeating then return false end
  return nextAt ~= nil
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

  HK.On("UNIT_SPELLCAST_SUCCEEDED", OnSpellSucceeded)
  HK.On("UNIT_SPELLCAST_START", OnSpellStarted)

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

HK.RegisterModule("ShotTimer", { Init = ShotTimer.Init })
