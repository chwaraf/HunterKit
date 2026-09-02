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
local frame, label, reticle, xMark, outlineMark
local ticker
local lastState = nil

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
local ApplyState, ShowStyle, Tick

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

  -- A single graphic reticle (Media/crosshair.tga) tinted per state.
  reticle = frame:CreateTexture(nil, "ARTWORK")
  reticle:SetTexture("Interface\\AddOns\\HunterKit\\Media\\crosshair.tga")
  reticle:SetAllPoints(frame)
  reticle:SetBlendMode("ADD")

  -- A matching bold X for the close/dead zone (colourblind-safe shape-code).
  xMark = frame:CreateTexture(nil, "ARTWORK")
  xMark:SetTexture("Interface\\AddOns\\HunterKit\\Media\\crosshair-x.tga")
  xMark:SetAllPoints(frame)
  xMark:SetBlendMode("ADD")
  xMark:Hide()

  -- OUT OF RANGE uses a bare outline-only reticle (no cross, no centre dot) so it
  -- reads as "no shot available" and is clearly distinct from the full green
  -- crosshair that appears when IN RANGE.
  outlineMark = frame:CreateTexture(nil, "ARTWORK")
  outlineMark:SetTexture("Interface\\AddOns\\HunterKit\\Media\\crosshair-outline.tga")
  outlineMark:SetAllPoints(frame)
  outlineMark:SetBlendMode("ADD")
  outlineMark:Hide()

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
-- Available mark shapes -> the texture that draws them (all three are direct
-- children of `frame`, so showing one and hiding the rest is enough).
local SHAPES = {
  crosshair = reticle,
  x         = xMark,
  rings     = outlineMark,
}

-- Pick the mark shape for a state from the saved per-state style (markOK /
-- markDead / markFar), falling back to the classic mapping if the stored value is
-- missing or unknown (e.g. a user who still has the old saved db).
local function StyleFor(state)
  local style
  if state == "OK" then      style = db.markOK
  elseif state == "DEAD" then style = db.markDead
  else                       style = db.markFar end
  if not SHAPES[style] then
    if state == "DEAD" then style = "x"
    elseif state == "FAR" then style = "rings"
    else style = "crosshair" end
  end
  return style
end

ShowStyle = function(style)
  for name, tex in pairs(SHAPES) do
    if name == style then tex:Show() else tex:Hide() end
  end
end

ApplyState = function(state)
  local c = COLORS[state] or COLORS.FAR
  local r, g, b = c[1], c[2], c[3]
  local style = StyleFor(state)
  -- Tint every shape the same state colour (only the visible one shows).
  reticle:SetVertexColor(r, g, b, 1)
  xMark:SetVertexColor(r, g, b, 1)
  outlineMark:SetVertexColor(r, g, b, 1)
  frame:SetAlpha(1)
  ShowStyle(style)

  if db.showLabel then
    label:SetText(LABELS[state] or "")
    label:SetShown(true)
  else
    label:Hide()
  end
end

-------------------------------------------------------------------------------
Tick = function()
  if not HK.db.range.enabled then return end -- self-pause (cheap no-op)
  Range.Update()
end

function Range.Update()
  if not frame then return end
  -- While editing, leave the frame exactly where the user put it: don't re-draw or
  -- hide it, and don't re-evaluate range (it would hide an out-of-combat/no-target
  -- mark and fight the drag).
  if HK.Editing() then return end
  if not HK.db.range.enabled then
    frame:SetShown(false)
    lastState = nil
    return
  end
  local s = ComputeState()
  lastState = s
  if s then
    frame:SetShown(true)
    ApplyState(s)
  else
    frame:SetShown(false)
  end
end

HK.RegisterModule("Range", { Init = Range.Init })
