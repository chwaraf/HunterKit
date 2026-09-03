--[[==============================================================================
 HunterKit — Sniper Mark (F2)
 A range-state reticle anchored to the target frame. Reflects state only — it
 never takes an action. Uses the same technique as the community's range
 weakauras (IsSpellInRange + CheckInteractDistance), because Classic has no
 exact-distance API and no line-of-sight API.
==============================================================================]]
local _, HK = ...

local Range = {}
HK.Range = Range

local db
local frame, label
local ticker
local lastState = nil
local shownState = nil
local farPending, farPendingN = nil, 0

local autoShot

-- Range-state colours.
local COLORS = {
  OK   = {0.2, 1, 0.2},   -- Auto Shot in range
  DEAD = {1, 0.2, 0.2},   -- too close to shoot (deadzone)
  FAR  = {0.6, 0.6, 0.6}, -- out of range (too far)
}
-- Clear, unambiguous labels. "Too close" and "too far" are genuinely different
-- and must not read the same.
local LABELS = {
  OK   = "IN RANGE",
  DEAD = "TOO CLOSE",
  FAR  = "OUT OF RANGE",
}

-- forward declarations (referenced by Init/BuildFrame before their bodies are
-- defined later in this file's chunk)
local ApplyState, Tick

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------
function Range.Init()
  db = HK.db.range
  if not HK.isHunter then return end -- structural gate

  autoShot = (GetSpellInfo(75))    -- "Auto Shot"  (nil if untrained)

  BuildFrame()

  HK.On("PLAYER_TARGET_CHANGED", Range.Update)
  ticker = HK.Ticker(0.10, Tick)
  Range.Update()
end

function BuildFrame()
  -- Parent to UIParent, never to the target frame. The target frame is a unit
  -- frame; a child of it gets its GetLeft/GetTop in the target frame's coordinate
  -- space, which is a different origin from UIParent. That coordinate-space mix is
  -- what made the mark jump off-screen on drop. We only ANCHOR to the target frame
  -- for position (ApplyPosition), keeping the parent UIParent so drag math is sane.
  frame = CreateFrame("Frame", "HunterKitSniperMark", UIParent)
  frame:SetSize(db.size, db.size)
  frame:EnableMouse(false) -- never intercept clicks
  Range.ApplyPosition()

  -- The mark itself is drawn procedurally (see "Shapes" below): one style per
  -- range state, six styles to choose from per state, no art files.

  label = frame:CreateFontString(nil, "OVERLAY")
  label:SetPoint("CENTER", frame, "BOTTOM", 0, -6)
  label:SetFontObject(GameFontDisableSmall)
  label:SetWidth(96)
  label:SetJustifyH("CENTER")
  label:Hide()

  HK.RegisterDraggable("range", frame, Range.ApplyPosition, function(x, y)
    db.offsetX, db.offsetY = x, y
  end, {
    clickable = true,
    restore = function() Range.Update() end,
    -- Store the mark's on-screen centre as an offset from UIParent's CENTRE
    -- (HK.SaveDragged works entirely in UIParent space, so it round-trips exactly
    -- via ApplyPosition's CENTRE/CENTRE anchor — no unit-frame conversion, no jump).
    saveFromScreen = function()
      HK.SaveDragged(frame, db)
    end,
  })

  -- Font size scales a little with the mark so the label stays legible.
  label:SetFontObject(GameFontDisableSmall)
end

function Range.ApplyPosition()
  if not frame then return end
  local parent = _G[db.parent] or UIParent
  frame:ClearAllPoints()
  -- Once dragged (or a UIParent anchor), pin to the absolute UIParent CENTRE
  -- offset so it stays exactly where dropped; otherwise use the target-frame
  -- anchor.
  if HK.IsPinned(db) then
    frame:SetPoint("CENTER", UIParent, "CENTER", db.offsetX, db.offsetY)
  else
    -- Sit to the RIGHT of the target frame, with the reticle's CENTRE on the
    -- SAME horizontal line as the target portrait's centre (it was offset).
    frame:SetPoint("LEFT", parent, "RIGHT", db.offsetX, db.offsetY)
  end
  frame:SetSize(db.size, db.size)
end

function Range.RescanSettings()
  db = HK.db.range
  if not frame then return end
  Range.ApplyPosition()
  label:SetShown(db.showLabel)
  Range.Update()
end

function Range.IsFrameValid()
  return frame and frame:IsShown()
end

-- ---------------------------------------------------------------------------
-- State computation
-- ---------------------------------------------------------------------------
-- CheckInteractDistance returns true/1 when the unit is within that interaction
-- distance, false/nil otherwise (varies by client). Normalise to a boolean.
local function Interact(unit, index)
  local ok, v = pcall(CheckInteractDistance, unit, index)
  if not ok then return false end
  return v == 1 or v == true
end

-- The decisive, deterministic truth table, validated against the client's own
-- /htk selfcheck values. Only two probes are used, and BOTH are confirmed
-- reliable on the real client (they correctly report "far" when the target is
-- >28 yd away):
--   * Auto Shot IN range             -> you can shoot          (green)
--   * Auto Shot OUT of range but the
--     "Trade" interaction (11 yd) is in range -> too close     (red X)
--   * otherwise                      -> genuinely out of range (too far) (grey)
-- We deliberately do NOT use a spell-based melee probe for "too close": Raptor
-- Strike's IsSpellInRange is broken on this client (it reported "in range" at
-- >28 yd, which is what wrongly showed "TOO CLOSE" when you were far), and Wing
-- Clip's spell ID could not be resolved. CheckInteractDistance's 11 yd "Trade"
-- index is the canonical deadzone probe the range weakauras use and is
-- confirmed to return false here when you're genuinely far.
local function ComputeState()
  if not UnitExists("target") then return nil end
  if not UnitCanAttack("player", "target") then return nil end
  if UnitIsDead("target") then return nil end

  local ranged = (type(autoShot) == "string") and IsSpellInRange(autoShot, "target") or nil

  if ranged == 1 then
    return "OK"
  end
  if Interact("target", 2) then
    return "DEAD"
  end
  return "FAR"
end

-- Diagnostics for /htk selfcheck: dumps the raw range/interaction probes so we
-- can see exactly what the client reports.
function Range.Diagnostic()
  local function s(v)
    if v == nil then return "nil" end
    return tostring(v)
  end
  local ok, ranged = pcall(IsSpellInRange, autoShot or "", "target")
  return string.format(
    "target=%s autoShotInRange=%s interact(trade,2)=%s interact(follow,4)=%s",
    tostring(UnitExists("target")), s(ok and ranged or nil),
    s(Interact("target", 2)), s(Interact("target", 4)))
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------
-- Every mark is drawn from one 1x1 Blizzard texture instead of an art file: 18
-- distinct silhouettes with nothing to ship in Media/, and the three states
-- differ by SHAPE, not only by colour.
--
-- A style is a list of primitives in a unit box (x,y from -1..1, 0,0 = centre):
--   {"seg",  x1, y1, x2, y2, w}   a line; w = thickness as a fraction of the size
--   {"ring", cx, cy, r, w}        a circle outline, drawn from short segments
--   {"dot",  cx, cy, s}           a filled square; s = side as a fraction
local LINE_TEX = "Interface\\Buttons\\WHITE8x8"
local RING_SEGMENTS = 24
-- WoW is Lua 5.1 (math.atan2); the fallback is only for the test harness, where
-- 5.3+ renamed it.
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

-- Path prefix for the bundled mark art. Art textures are white-on-alpha so the
-- per-state SetVertexColor tints them; procedural primitives stay vector-crisp.
local MEDIA = "Interface\\AddOns\\HunterKit\\Media\\"
local function art(path) return { { "art", MEDIA .. path } } end

-- The three families are deliberately different in character so the state reads
-- at a glance even without the colour:
--   IN RANGE    open, angular, centred  — "the shot is available"
--   TOO CLOSE   closed, heavy, blocking — "back up"
--   OUT OF RANGE broken, thin, hollow   — "no shot"
-- Every style is bundled .tga art: the old crosshair marks plus a modern sci-fi
-- set; the procedural primitives below remain as the engine's fallback but no
-- shipped style needs them. The first entry of each state is the default: the
-- bold outlined cross family (plus / cross / broken) that the user picked as the
-- house style; the classic thin marks stay one click away.
local STYLES = {
  OK = {
    plus      = art("mark-ok-plus.tga"),
    crosshair = art("crosshair.tga"),
    reticle   = art("mark-ok-reticle.tga"),
    chevrons  = art("mark-ok-chevrons.tga"),
    diamond   = art("mark-ok-diamond.tga"),
    ticks     = art("mark-ok-ticks.tga"),
  },
  DEAD = {
    x     = art("crosshair-x.tga"),
    hexx  = art("mark-dead-hexx.tga"),
    cross = art("mark-dead-cross.tga"),
    block = art("mark-dead-block.tga"),
    bars  = art("mark-dead-bars.tga"),
    burst = art("mark-dead-burst.tga"),
  },
  FAR = {
    rings = art("crosshair-outline.tga"),
    dashed  = art("mark-far-dashring.tga"),
    halo    = art("mark-far-halo.tga"),
    sides   = art("mark-far-sides.tga"),
    slashes = art("mark-far-slashes.tga"),
    ban     = art("mark-far-ban.tga"),
  },
}

-- Dropdown order; first entry is the default (and the fallback for unknown saves).
local STYLE_ORDER = {
  OK   = { "plus", "crosshair", "reticle", "chevrons", "diamond", "ticks" },
  DEAD = { "cross", "x", "hexx", "block", "bars", "burst" },
  FAR  = { "ban", "rings", "dashed", "halo", "sides", "slashes" },
}

-- Texture pool: primitives are created once and reused, so switching style
-- costs no allocations after the first draw.
local pool, poolUsed = {}, 0

local function NextTex()
  poolUsed = poolUsed + 1
  local t = pool[poolUsed]
  if not t then
    t = frame:CreateTexture(nil, "ARTWORK")
    t:SetTexture(LINE_TEX)
    t:SetBlendMode("ADD")
    pool[poolUsed] = t
  end
  return t
end

local function DrawArt(path, r, g, b)
  local t = NextTex()
  t:ClearAllPoints()
  t:SetAllPoints(frame)
  t:SetTexture(path)
  -- ADD, exactly like the classic marks: the black surround contributes nothing
  -- and the white art adds its tint at full strength, so the mark reads bright
  -- on any background (BLEND left the generated art washed out).
  t:SetBlendMode("ADD")
  if t.SetRotation then t:SetRotation(0) end
  t:SetVertexColor(r, g, b, 1)
  t:Show()
end

local function DrawSeg(x1, y1, x2, y2, w, size, r, g, b)
  local t = NextTex()
  local dx, dy = (x2 - x1) * size / 2, (y2 - y1) * size / 2
  t:ClearAllPoints()
  t:SetSize(math.max(1, math.sqrt(dx * dx + dy * dy)), math.max(1, w * size))
  t:SetPoint("CENTER", frame, "CENTER", (x1 + x2) * size / 4, (y1 + y2) * size / 4)
  if t.SetRotation then t:SetRotation(atan2(dy, dx)) end
  t:SetBlendMode("ADD")
  t:SetVertexColor(r, g, b, 1)
  t:Show()
end

local function DrawRing(cx, cy, radius, w, size, r, g, b)
  local step = (2 * math.pi) / RING_SEGMENTS
  for i = 0, RING_SEGMENTS - 1 do
    local a1, a2 = i * step, (i + 1) * step
    DrawSeg(cx + radius * math.cos(a1), cy + radius * math.sin(a1),
            cx + radius * math.cos(a2), cy + radius * math.sin(a2),
            w, size, r, g, b)
  end
end

local function DrawDot(cx, cy, s, size, r, g, b)
  local t = NextTex()
  t:ClearAllPoints()
  t:SetSize(math.max(1, s * size), math.max(1, s * size))
  t:SetPoint("CENTER", frame, "CENTER", cx * size / 2, cy * size / 2)
  if t.SetRotation then t:SetRotation(0) end
  t:SetBlendMode("ADD")
  t:SetVertexColor(r, g, b, 1)
  t:Show()
end

local function DrawStyle(prims, size, r, g, b)
  for i = 1, poolUsed do pool[i]:Hide() end
  poolUsed = 0
  if not prims then return end
  for _, p in ipairs(prims) do
    if p[1] == "seg" then DrawSeg(p[2], p[3], p[4], p[5], p[6], size, r, g, b)
    elseif p[1] == "ring" then DrawRing(p[2], p[3], p[4], p[5], size, r, g, b)
    elseif p[1] == "dot" then DrawDot(p[2], p[3], p[4], size, r, g, b)
    elseif p[1] == "art" then DrawArt(p[2], r, g, b) end
  end
end

local lastStyle = nil
local lastR, lastG, lastB = 1, 1, 1

local function StyleFor(state)
  local key
  if state == "OK" then key = db.markOK
  elseif state == "DEAD" then key = db.markDead
  else key = db.markFar end
  if STYLES[state] and STYLES[state][key] then return key end
  return STYLE_ORDER[state][1]
end

-- Test/diagnostic surface: what is on screen, and what could be.
function Range.CurrentStyle() return lastStyle end
function Range.DrawnColor() return lastR, lastG, lastB end
function Range.StyleNames(state) return STYLE_ORDER[state] or STYLE_ORDER.FAR end
function Range.Primitives(state, name)
  return STYLES[state] and STYLES[state][name]
end
function Range.VisibleShapes()
  local n = 0
  for i = 1, poolUsed do if pool[i]:IsShown() then n = n + 1 end end
  return n
end

ApplyState = function(state)
  local c = COLORS[state] or COLORS.FAR
  local style = StyleFor(state)
  lastStyle = style
  frame:SetAlpha(1)
  -- Per-state brightness slider (10..100%): with the ADDitive blend, scaling the
  -- vertex colour scales the glow exactly.
  local key = state == "OK" and "brightOK" or state == "DEAD" and "brightDead" or "brightFar"
  local br = (db[key] or 100) / 100
  lastR, lastG, lastB = c[1] * br, c[2] * br, c[3] * br
  DrawStyle(STYLES[state] and STYLES[state][style], db.size or 60, lastR, lastG, lastB)

  if db.showLabel then
    label:SetText(LABELS[state] or "")
    label:SetShown(true)
  else
    label:Hide()
  end
end

-------------------------------------------------------------------------------
Tick = function()
  if HK.db.enabled == false or not HK.db.range.enabled then return end -- self-pause
  Range.Update()
end

function Range.Update()
  if not frame then return end
  -- While editing, leave the frame exactly where the user put it: don't re-draw or
  -- hide it, and don't re-evaluate range (it would hide an out-of-combat/no-target
  -- mark and fight the drag).
  if HK.Editing() then return end
  if HK.db.enabled == false or not HK.db.range.enabled then
    frame:SetShown(false)
    lastState, shownState = nil, nil
    farPending, farPendingN = nil, 0
    return
  end
  local s = ComputeState()
  lastState = s
  if not s then
    frame:SetShown(false)
    shownState, farPending, farPendingN = nil, nil, 0
    return
  end
  frame:SetShown(true)
  if s == shownState then
    farPending, farPendingN = nil, 0
    ApplyState(s)
    return
  end
  -- The range probes can misreport for a single tick while you move (the server
  -- lags your position), and the most visible false reading is a one-tick
  -- OUT OF RANGE flash when crossing from TOO CLOSE into IN RANGE. Entering FAR
  -- therefore needs two consecutive agreeing ticks; every other change applies
  -- at once so the mark never feels laggy.
  if s == "FAR" then
    if farPending then farPendingN = farPendingN + 1 else farPending, farPendingN = true, 1 end
    if farPendingN >= 2 then
      shownState = s
      farPending, farPendingN = nil, 0
      ApplyState(s)
    end
  else
    farPending, farPendingN = nil, 0
    shownState = s
    ApplyState(s)
  end
end

HK.RegisterModule("Range", { Init = Range.Init })
