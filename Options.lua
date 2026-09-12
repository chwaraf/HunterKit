--[[==============================================================================
 HunterKit — Options (F5) + minimap button + drag/lock
 A standalone draggable window (NOT the settings-panel API, whose templates
 differ across Classic patches). Every control writes straight into HunterKitDB
 and calls the feature's Refresh(). Also owns the minimap button and the
 /htk lock|unlock + reset position handling.
==============================================================================]]
local _, HK = ...

local db = HK.db
local Options = {}
HK.Options = Options

local win
local refreshFuncs = {}   -- feature -> Refresh() to call on instant apply
local unlockBtn           -- the "Unlock frames"/"Lock frames" button (text alternates)
local UpdateLockButton    -- forward-declared; assigned later (used by BuildWindow)
local draggingFrame = nil -- a frame currently being dragged
local editBanner          -- big red "EDIT MODE" banner shown while frames are unlocked

-- ---------------------------------------------------------------------------
-- A prominent, blinking red "EDIT MODE" banner shown while frames are unlocked so
-- the player clearly knows they're in the drag/reposition mode (and that the feed
-- button won't feed while it's being moved).
-- ---------------------------------------------------------------------------
local function BuildEditBanner()
  if editBanner then return end
  editBanner = CreateFrame("Frame", "HunterKitEditBanner", UIParent)
  editBanner:SetFrameStrata("TOOLTIP")
  editBanner:SetFrameLevel(250)
  editBanner:EnableMouse(false)
  editBanner:SetSize(320, 60)
  editBanner:SetPoint("TOP", UIParent, "TOP", 0, -88)
  editBanner:SetShown(false)   -- hidden immediately; only shown when frames are unlocked

  -- Soft translucent red block (35% alpha) so it's noticed without dominating
  -- the screen; the blinking red "EDIT MODE" text carries the message.
  local bg = editBanner:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetTexture("Interface\\Buttons\\WHITE8x8")
  bg:SetVertexColor(0.5, 0.05, 0.05, 0.35)

  -- Bright red border so it reads as a deliberate banner. Drawn with plain
  -- WHITE8x8 texture strips (NOT SetBackdrop, which needs the BackdropTemplate
  -- mixin and can throw on some clients).
  local T = 2
  local function strip(pa, pb, thick, horiz)
    local t = editBanner:CreateTexture(nil, "ARTWORK")
    t:SetPoint(pa)
    t:SetPoint(pb)
    t:SetTexture("Interface\\Buttons\\WHITE8x8")
    t:SetVertexColor(1, 0, 0, 1)
    if horiz then t:SetHeight(thick) else t:SetWidth(thick) end
    return t
  end
  strip("TOPLEFT", "TOPRIGHT", T, true)      -- top edge
  strip("BOTTOMLEFT", "BOTTOMRIGHT", T, true) -- bottom edge
  strip("TOPLEFT", "BOTTOMLEFT", T, false)    -- left edge
  strip("TOPRIGHT", "BOTTOMRIGHT", T, false)  -- right edge

  local txt = editBanner:CreateFontString(nil, "OVERLAY")
  txt:SetPoint("CENTER", editBanner, "CENTER", 0, 0)
  -- Set the font BEFORE SetText. Calling SetText on a FontString that has no font
  -- yet throws "FontString:SetText(): Font not set" on the live client, which
  -- aborted the rest of BuildEditBanner — so editBanner:SetShown(false) never ran
  -- and the banner stayed visible at login.
  txt:SetFont(STANDARD_TEXT_FONT, 36, "OUTLINE")
  txt:SetTextColor(1, 0.1, 0.1)                  -- red
  txt:SetText("EDIT MODE")
  txt:SetJustifyH("CENTER")
  editBanner:SetShown(false)
  -- gentle blink so it's unmissable but not distracting.
  editBanner:SetScript("OnUpdate", function(self, dt)
    local t = GetTime() or 0
    self:SetAlpha(0.35 + 0.3 * math.abs(math.sin(t * 4)))
  end)
end

-- ---------------------------------------------------------------------------
-- Register the module (loaded after Core so HK.db exists)
-- ---------------------------------------------------------------------------
HK.RegisterModule("Options", { Init = function()
  db = HK.db
  BuildWindow()
  BuildMinimapButton()
  BuildEditBanner()
  if not HK.isHunter then
    -- still allow options so a non-hunter can see why nothing is active
  end
end })

function Options.Toggle()
  if win then win:SetShown(not win:IsShown()) end
end

function Options.SetVisible(v)
  if win then win:SetShown(v) end
end

-- ---------------------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------------------
local function MakeWindow()
  -- BackdropTemplate is required for SetBackdrop on the modern ClassFrameXML.
  win = CreateFrame("Frame", "HunterKitOptions", UIParent, "BackdropTemplate")
  -- 608 wide: 474 of settings pane plus a 134px column of section buttons down
  -- the left edge (see BuildNav). The scrollbar anchors to TOPRIGHT, so it
  -- follows the widening on its own.
  win:SetSize(608, 604)
  win:SetFrameStrata("DIALOG")
  win:SetPoint("CENTER")
  win:SetMovable(true)
  win:EnableMouse(true)
  win:SetClampedToScreen(true)
  win:RegisterForDrag("LeftButton")
  win:SetScript("OnDragStart", function(self) self:StartMoving() end)
  win:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

  win:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 14,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
  })
  win:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
  win:SetBackdropBorderColor(0.6, 0.6, 0.6, 0.8)

  -- title
  local title = win:CreateFontString(nil, "OVERLAY")
  title:SetPoint("TOP", win, "TOP", 0, -16)
  title:SetFontObject(GameFontNormalLarge)
  title:SetText("HunterKit")
  title:SetTextColor(0.25, 1, 0.25)

  -- close button (stable template name on Classic)
  local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", win, "TOPRIGHT", -4, -4)
  close:SetScript("OnClick", function() Options.Toggle() end)

  tinsert(UISpecialFrames, "HunterKitOptions") -- ESC to close

  -- Locking happens when the player closes the options window (X or ESC). This is
  -- the explicit signal to end edit mode — not a timer or cursor position.
  win:SetScript("OnHide", function(self)
    if HK.Positions and not HK.Positions.locked then
      HK.Positions.SetLock(true)
    end
  end)

  -- scroll container for the settings. We drive scrolling with the mouse wheel
  -- via SetVerticalScroll, and let SetScrollChild manage the content position
  -- (do NOT also manually SetPoint the content — that's what broke the layout).
  local scrollArea = CreateFrame("ScrollFrame", "HunterKitOptionsScroll", win)
  scrollArea:SetPoint("TOPLEFT", win, "TOPLEFT", 140, -34)   -- 140 leaves room for the nav column
  scrollArea:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -22, 12) -- leave room for the scrollbar
  scrollArea:SetFrameStrata("DIALOG")
  scrollArea:SetClipsChildren(true)
  scrollArea:EnableMouseWheel(true)

  local content = CreateFrame("Frame", "HunterKitOptionsContent", scrollArea)
  content:SetWidth(436)
  content:SetHeight(1)
  scrollArea:SetScrollChild(content)
  scrollArea.content = content

  -- Visible scrollbar: a track + thumb that reflects scroll range and offset.
  -- NOTE: `GetScrollRange()` is not available on this client (it threw a nil
  -- call), so we derive it from content vs frame height instead.
  local sb = CreateFrame("Frame", "HunterKitOptionsScrollBar", win)
  sb:SetWidth(8)
  sb:SetPoint("TOPLEFT", win, "TOPRIGHT", -16, -34)
  sb:SetPoint("BOTTOMLEFT", win, "BOTTOMRIGHT", -16, 12)
  sb:SetFrameStrata("DIALOG")
  sb:EnableMouse(true)
  sb:SetClampedToScreen(true)
  local track = sb:CreateTexture(nil, "BACKGROUND")
  track:SetAllPoints()
  track:SetTexture("Interface\\Buttons\\WHITE8x8")
  track:SetVertexColor(0.15, 0.15, 0.15, 0.9)
  local thumb = sb:CreateTexture(nil, "ARTWORK")
  thumb:SetTexture("Interface\\Buttons\\WHITE8x8")
  thumb:SetVertexColor(0.6, 0.6, 0.6, 0.9)

  local function clamp(v, lo, hi) if v < lo then return lo end if v > hi then return hi end return v end

  local function UpdateScroll()
    local cH = content:GetHeight() or 0
    local sH = scrollArea:GetHeight() or 0
    local range = math.max(0, cH - sH)
    local cur = scrollArea:GetVerticalScroll() or 0
    cur = clamp(cur, 0, range)
    if (range <= 0) then cur = 0 end
    scrollArea:SetVerticalScroll(cur)

    local sbH = sb:GetHeight() or 1
    local thumbH = sH <= 0 and sbH or math.max(30, (sH / math.max(1, cH)) * sbH)
    thumbH = math.min(thumbH, sbH)
    local maxOff = math.max(0, sbH - thumbH)
    local frac = (range > 0) and (cur / range) or 0
    local top = maxOff * frac   -- at top of content -> thumb at top of the bar
    thumb:ClearAllPoints()
    thumb:SetPoint("TOPLEFT", sb, "TOPLEFT", 0, -top)
    thumb:SetPoint("TOPRIGHT", sb, "TOPRIGHT", 0, -top)
    thumb:SetHeight(thumbH)
  end

  -- wheel
  scrollArea:SetScript("OnMouseWheel", function(self, delta)
    local cH = content:GetHeight() or 0
    local sH = scrollArea:GetHeight() or 0
    local range = math.max(0, cH - sH)
    local cur = scrollArea:GetVerticalScroll() or 0
    local new = clamp(cur - delta * 26, 0, range)
    scrollArea:SetVerticalScroll(new)
    UpdateScroll()
  end)

  -- drag the bar / thumb to scroll
  local function dragUpdate()
    local mx, my = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    my = my / scale
    local sbTop = sb:GetTop()
    local sbH = sb:GetHeight() or 1
    if not sbTop then return end
    local frac = (sbTop - my) / sbH
    local cH = content:GetHeight() or 0
    local sH = scrollArea:GetHeight() or 0
    local range = math.max(0, cH - sH)
    local v = clamp(frac * range, 0, range)
    scrollArea:SetVerticalScroll(v)
    UpdateScroll()
  end
  sb:RegisterForDrag("LeftButton")
  sb:SetScript("OnDragStart", function() sb:SetScript("OnUpdate", dragUpdate) end)
  sb:SetScript("OnDragStop", function() sb:SetScript("OnUpdate", nil) end)

  win.content = content
  win.scroll = scrollArea
  win.UpdateScroll = UpdateScroll
  win:SetClampedToScreen(true)
end

-- ---------------------------------------------------------------------------
-- Widget factories
-- ---------------------------------------------------------------------------
-- Shape lists come from the module that draws them; fall back to a plain list if
-- that module failed to load, so a broken Range.lua can't take the window down.
local function ShapeNames(state, fallback)
  if HK.Range and HK.Range.StyleNames then
    local ok, list = pcall(HK.Range.StyleNames, state)
    if ok and type(list) == "table" and #list > 0 then return list end
  end
  return fallback
end

-- Every control registers how to re-display itself, so a settings reset can
-- refresh the open window instead of leaving stale values on screen.
local controlRefresh = {}
function Options.RefreshControls()
  for _, fn in ipairs(controlRefresh) do pcall(fn) end
end

-- One tooltip path for every control. AddLine's 5th argument is `wrap` — without
-- it a long help string renders as one clipped line, which is what it did before.
local function AttachTooltip(widget, title, body)
  if not widget or not body or body == "" then return end
  widget:SetScript("OnEnter", function()
    GameTooltip:SetOwner(widget, "ANCHOR_RIGHT")
    GameTooltip:SetText(title, 0.35, 1, 0.35)
    GameTooltip:AddLine(body, 0.9, 0.9, 0.9, true)   -- wrap = true
    GameTooltip:Show()
  end)
  widget:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function MakeHeader(parent, text)
  local h = parent:CreateFontString(nil, "OVERLAY")
  h:SetFontObject(GameFontHighlight)
  h:SetText("|cff39ff14" .. text .. "|r")
  h:SetPoint("TOPLEFT", parent, "TOPLEFT", 2, 0)
  h:SetJustifyH("LEFT")
  h:SetWordWrap(false)
  h:SetHeight(14)
  return h
end

local function MakeCheckbox(parent, y, labelText, get, set, tooltip)
  -- Use the standard options checkbox template, which reliably renders a box
  -- plus a check mark (the template-free Button approach rendered nothing).
  local chk = CreateFrame("CheckButton", nil, parent, "InterfaceOptionsCheckButtonTemplate")
  chk:SetSize(24, 24)
  chk:EnableMouse(true)
  chk:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y)
  chk:SetHitRectInsets(0, 0, 0, 0)
  -- Explicitly draw the standard Blizzard checkbox textures so a visible box and
  -- check mark always appear, even if the template draws nothing on a given
  -- client. (Safe: re-setting these is idempotent and doesn't fight the template.)
  chk:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
  chk:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
  chk:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight")
  chk:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
  chk:SetDisabledCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check-Disabled")
  chk:SetChecked(get())
  chk:SetScript("OnClick", function(self)
    set(self:GetChecked())
  end)
  local txt = chk:CreateFontString(nil, "OVERLAY")
  txt:SetPoint("LEFT", chk, "RIGHT", 8, 0)
  txt:SetFontObject(GameFontNormal)
  txt:SetJustifyH("LEFT")
  txt:SetWordWrap(false)
  txt:SetWidth(math.max(120, (parent:GetWidth() or 436) - 44))
  txt:SetText(labelText)
  txt:SetTextColor(0.9, 0.9, 0.9)
  AttachTooltip(chk, labelText, tooltip)
  controlRefresh[#controlRefresh + 1] = function()
    chk:SetChecked(get() and true or false)
  end
  return chk
end

local sliderCount = 0
-- Layout: the label and its live value share the top row (label left, value
-- right), the slider sits full-width underneath.
--
-- Why not the template's own fontstrings: `$parentText` is empty until you drag
-- (so the value only appeared on interaction), `$parentLow`/`$parentHigh` are
-- centred on the slider's bottom corners — at x=0 half of "Low" hung outside the
-- scroll area and got clipped — and `$parentText` floated over the label. All
-- three are hidden and replaced by our own row.
local SLIDER_LABEL_H = 15
local SLIDER_BAR_H   = 18
local SLIDER_VALUE_W = 88
-- `fmt` optionally formats the displayed number. The slider itself must stay on
-- integers (the widget renders with %d and a fractional step throws), so a
-- value like 2.5s is stored as 25 on the bar and made readable again here.
local function MakeSlider(parent, y, labelText, min, max, step, get, set, tooltip, compact, fmt)
  local function Show(v) return fmt and fmt(v) or string.format("%d", v) end
  sliderCount = sliderCount + 1
  local name = "HunterKitOptSlider" .. sliderCount
  local w = (parent:GetWidth() or 436)

  local lbl = parent:CreateFontString(nil, "OVERLAY")
  lbl:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y)
  lbl:SetFontObject(GameFontNormal)
  lbl:SetJustifyH("LEFT")
  lbl:SetWordWrap(false)
  if compact then
    -- Small slider on the RIGHT of the text: the label owns everything to the
    -- left of it. The bar is 110 wide at -34 from the right edge, so the label
    -- may run up to (width - 34 - 110 - gap). This was hardcoded to 200, which
    -- silently clipped longer labels mid-word with SetWordWrap(false) -- e.g.
    -- "Weave round trip (seconds)" ended at "of a...". Derive it instead.
    lbl:SetWidth(math.max(120, w - 34 - 110 - 12))
  else
    -- The number sits dead centre of the row, so the label may only use the left
    -- half minus that column, or a long label would run underneath the number.
    lbl:SetWidth(math.max(80, math.floor((w - SLIDER_VALUE_W) / 2) - 8))
  end
  lbl:SetText(labelText)
  lbl:SetTextColor(0.9, 0.9, 0.9)

  -- Always visible and centred over the bar: the template's own value text is
  -- empty until you drag, and a right-aligned column collided with long labels.
  local val = parent:CreateFontString(nil, "OVERLAY")
  if compact then
    -- re-anchored next to the bar once the bar exists (below); kept on the same
    -- horizontal line as the bar, right of it, for every row.
    val:SetWidth(30)
  else
    val:SetPoint("TOP", parent, "TOP", 0, y)
  end
  val:SetFontObject(GameFontHighlight)
  val:SetJustifyH("CENTER")
  val:SetWordWrap(false)
  if not compact then val:SetWidth(SLIDER_VALUE_W) end
  val:SetTextColor(0.35, 1, 0.35)
  val:SetText(Show(get()))

  local sl = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
  if compact then
    sl:SetWidth(110)
    sl:SetHeight(SLIDER_BAR_H)
    sl:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -34, y - 2)
  else
    sl:SetWidth(math.max(120, w - 16))
    sl:SetHeight(SLIDER_BAR_H)
    sl:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, y - SLIDER_LABEL_H)
  end
  sl:SetMinMaxValues(min, max)
  sl:SetValueStep(step)
  sl:SetObeyStepOnDrag(true)
  -- Hide the template's own texts BEFORE SetValue: the client fires
  -- OnValueChanged from SetValue, and we don't want it repopulating these.
  for _, suf in ipairs({ "Text", "Low", "High" }) do
    local fs = _G[name .. suf]
    if fs and fs.Hide then fs:Hide() end
  end
  -- SetValue before the handler is attached: the client fires OnValueChanged
  -- from SetValue, and we don't want a write-back (and a refresh of every module)
  -- just for opening the window.
  local syncing = true          -- our own SetValue is not a user edit
  sl:SetValue(get())
  syncing = false
  sl:SetScript("OnValueChanged", function(self)
    val:SetText(Show(self:GetValue()))
    if syncing then return end
    set(self:GetValue())
  end)
  if compact then
    val:ClearAllPoints()
    val:SetPoint("LEFT", sl, "RIGHT", 4, 0)   -- number on the bar's line
  end
  val:SetText(Show(sl:GetValue()))   -- shown from the first frame
  AttachTooltip(sl, labelText, tooltip)
  controlRefresh[#controlRefresh + 1] = function()
    syncing = true
    sl:SetValue(get())
    syncing = false
    val:SetText(Show(sl:GetValue()))
  end
  return sl
end

-- ---------------------------------------------------------------------------
-- Build the settings
-- ---------------------------------------------------------------------------
-- Each feature gets a rule above its title plus extra air below, so the modules
-- read as separate blocks instead of one long list.
local SECTION_RULE_GAP = 7
-- Every section, in order, with the y it was drawn at -- so BuildNav can make
-- a button that scrolls straight to it. Reset on each BuildWindow.
local sectionIndex = {}

local function AddSection(content, y, name)
  sectionIndex[#sectionIndex + 1] = { name = name, y = y }
  local rule = content:CreateTexture(nil, "BACKGROUND")
  rule:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y + SECTION_RULE_GAP)
  rule:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, y + SECTION_RULE_GAP)
  rule:SetHeight(1)
  rule:SetTexture("Interface\\Buttons\\WHITE8x8")
  rule:SetVertexColor(0.30, 0.55, 0.30, 0.85)

  local h = MakeHeader(content, name)
  h:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y - 4)
  return h
end

-- ---------------------------------------------------------------------------
-- A miniature, to-scale picture of the shot bar, with a key naming every part.
--
-- The colours are the only vocabulary this feature has, and a tooltip you have
-- to hover to find is a poor place to teach it. Drawing the actual bar next to
-- the settings that change it means the words "lockout zone" and "weave marker"
-- have something to point at. Colours are kept in step with ShotTimer.lua by
-- hand -- there is no shared palette yet, and inventing one for six values
-- would be more indirection than it is worth.
-- ---------------------------------------------------------------------------
local LEGEND_BAR_H = 16
local function AddShotBarLegend(content, y)
  local w = (content:GetWidth() or 436)
  local barW = w - 8

  -- Colours copied from ShotTimer.lua's palette BY HAND. There is no shared
  -- table, and inventing one for a dozen values would be more indirection than
  -- it is worth -- but that makes this the file to check whenever a colour
  -- changes there. (The red swatch here had already drifted from COL_ZONE.)
  local C_TRACK    = { 0.10, 0.10, 0.12, 0.85 }
  local C_CHARGING = { 0.20, 0.90, 0.30, 0.90 }
  local C_ZONE     = { 0.75, 0.12, 0.12, 0.55 }
  local C_WEAVE    = { 0.40, 0.75, 1.00, 0.95 }
  local C_CLIP     = { 1.00, 0.85, 0.20, 0.70 }
  local C_TWOGO    = { 0.30, 1.00, 0.45, 1.00 }

  local function tex(layer, parent, point, ax, ay, ww, hh, c)
    local t = content:CreateTexture(nil, layer)
    t:SetPoint("TOP" .. point, parent, "TOP" .. point, ax, ay)
    t:SetSize(ww, hh)
    t:SetTexture("Interface\\Buttons\\WHITE8x8")
    t:SetVertexColor(c[1], c[2], c[3], c[4])
    return t
  end

  -- The shot bar, and every layer drawn on it, in the order they stack.
  local bar = tex("ARTWORK", content, "LEFT", 4, y, barW, LEGEND_BAR_H, C_TRACK)
  tex("OVERLAY", bar, "LEFT", 0, 0, barW * 0.62, LEGEND_BAR_H, C_CHARGING)
  -- The clip slice sits immediately LEFT of the red zone and extends it.
  tex("OVERLAY", bar, "RIGHT", -(barW * 0.16), 0, barW * 0.10, LEGEND_BAR_H, C_CLIP)
  tex("OVERLAY", bar, "RIGHT", -(barW * 0.16), 0, 2, LEGEND_BAR_H, { 1, 1, 1, 0.85 })
  tex("OVERLAY", bar, "RIGHT", 0, 0, barW * 0.16, LEGEND_BAR_H, C_ZONE)
  tex("OVERLAY", bar, "LEFT", barW * 0.50, 0, 2, LEGEND_BAR_H, C_WEAVE)

  -- The melee swing bar: the SAME height as the shot bar, which is how the real
  -- one draws since 0.9.73. This picture used to show it a third as tall, which
  -- stopped being a to-scale picture the moment that changed.
  local melee = tex("OVERLAY", bar, "LEFT", 0, -LEGEND_BAR_H - 2, barW, LEGEND_BAR_H, C_TRACK)
  tex("OVERLAY", melee, "LEFT", 0, 0, barW * 0.45, LEGEND_BAR_H, C_CHARGING)

  -- The state strip under the two bars.
  local strip = tex("OVERLAY", melee, "LEFT", 0, -LEGEND_BAR_H - 2, barW, 11, C_TWOGO)

  local pictureH = LEGEND_BAR_H * 2 + 11 + 4

  local lines = {
    { "|cff33e64dGreen|r", "free time -- move, weave, cast" },
    { "|cffbf1f1fRed|r", "the 0.5s lockout: acting here clips the shot" },
    { "|cffffffffWhite hairline|r", "where the lockout begins" },
    { "|cffffd933Yellow, left of the red|r", "how late your LAST shot landed. Not a latency reading -- nothing reads your connection. It is the measured clip, the same figure as +0.34s, shown for the one cycle after a late shot." },
    { "|cff66bfffBlue line|r", "where your melee hit belongs in the cycle" },
    { "|cff8cff8cLine turns green|r", "swing now" },
    { "|cff33e64dSecond bar, same height|r", "your melee swing -- same colours, same meaning" },
    { "|cff8cff8cPale green|r", "that weapon is ready to swing or fire now" },
    { "|cff66ccffWEAVE / GO / weave in 1.2s|r", "the countdown: when to act, or that you should" },
    { "|cffd9b333shoot|r", "a special shot is up -- spend it instead of weaving" },
    { "|cffff4040+0.34s|r", "how late the last shot really landed" },
    { "|cff55dd55Aimed / Multi pips|r", "green = ready to spend, dark = on cooldown" },
    { "|cff4dff73State strip: PRESS 2-MOB|r", "pet holds a second mob, melee swing up, Auto Shot free -- press the two-mob macro" },
    { "|cff66ccff2-MOB - SWING 1.2s|r", "the setup is live, waiting on the swing" },
    { "|cffe6b333MELEE ONLY|r", "something is in melee, no second mob to shoot" },
    { "|cff737380RANGE|r", "nothing in melee -- you are simply shooting" },
    { "|cfff04d4dOUT OF RANGE|r", "your target is past Auto Shot range" },
    { "|cff4dff73Press icon: NOW|r", "bright = press the two-mob macro; dimmed with a countdown = set up, swing coming" },
    { "|cff9fd8ffWhat to press next|r", "opt-in row naming the button worth pressing" },
  }
  local ly = y - pictureH - 12
  for _, row in ipairs(lines) do
    local fs = content:CreateFontString(nil, "OVERLAY")
    fs:SetPoint("TOPLEFT", content, "TOPLEFT", 8, ly)
    fs:SetWidth(w - 16)
    fs:SetJustifyH("LEFT")
    fs:SetFontObject(GameFontHighlightSmall)
    fs:SetWordWrap(true)
    fs:SetText(row[1] .. "  " .. row[2])
    fs:SetTextColor(0.82, 0.82, 0.82)
    -- Wrapped rows need their real height back, or a long one overwrites the
    -- next. 14 is the single-line pitch; anything longer is measured.
    local h = (fs.GetStringHeight and fs:GetStringHeight()) or 0
    ly = ly - math.max(14, h + 4)
  end
  return ly - 4
end

-- ---------------------------------------------------------------------------
-- The section index: a column of buttons down the left edge, one per section,
-- each scrolling the window straight to it.
--
-- Thirteen sections in one scrolling pane means finding "Ammo auto-buy" is a
-- scroll-and-scan every time you open the window. This makes it one click, and
-- doubles as a table of contents for what the addon actually does.
-- ---------------------------------------------------------------------------
local NAV_W, NAV_H, NAV_GAP, NAV_TOP = 124, 19, 21, -34
local navButtons = {}

local function BuildNav()
  navButtons = {}
  if not win or #sectionIndex == 0 then return end
  local scroll = win.scroll
  for i, e in ipairs(sectionIndex) do
    local b = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    b:SetSize(NAV_W, NAV_H)
    b:SetPoint("TOPLEFT", win, "TOPLEFT", 8, NAV_TOP - (i - 1) * NAV_GAP)
    b:SetText(e.name)
    -- The template's font is sized for a 24px button; at 19px with names like
    -- "Pet aggro warning" it clips, so drop it a step.
    -- Guarded on the METHOD, not just the result: a client without
    -- GetFontString must still get a working button, merely with the default
    -- label size.
    if b.GetFontString then
      local fs = b:GetFontString()
      if fs and fs.SetFont then
        fs:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 10, "")
      end
    end
    -- Content coordinates run DOWNWARD-NEGATIVE and AddSection draws the header
    -- 4px below the y it was handed, so the scroll offset that puts that header
    -- at the top of the pane is (4 - y). UpdateScroll clamps it to the real
    -- range, so the last few sections land as far down as they can go rather
    -- than overscrolling into blank space.
    b:SetScript("OnClick", function()
      if not scroll then return end
      scroll:SetVerticalScroll(math.max(0, 4 - e.y))
      if win.UpdateScroll then win.UpdateScroll() end
    end)
    AttachTooltip(b, e.name, "Jump to the " .. e.name .. " settings.")
    navButtons[#navButtons + 1] = b
  end
end

-- The section buttons, in the order the sections appear. Exposed so the tests
-- can assert the index matches the window's real contents and that clicking one
-- actually scrolls -- neither is visible from the outside otherwise.
function Options.SectionNav()
  local out = {}
  for i, b in ipairs(navButtons) do
    out[i] = { name = b.text, button = b, y = sectionIndex[i] and sectionIndex[i].y }
  end
  return out
end
function Options.ScrollOffset()
  return win and win.scroll and win.scroll:GetVerticalScroll() or nil
end

function BuildWindow()
  controlRefresh = {}
  sectionIndex = {}
  MakeWindow()

  local content = win.content
  local y = 0
  local nextY = function(offset) y = y - offset end

  -- Spacing scheme: a section header (title + rule) takes HDR, a checkbox CHK, a
  -- slider or dropdown row ROW (label line + control + gap).
  local HDR = 30
  local CHK = 26
  local ROW = 46

  -- master enabled
  AddSection(content, y, "Master")
  y = y - HDR
  MakeCheckbox(content, y, "Enable HunterKit", function() return db.enabled end,
    function(v) db.enabled = v; RefreshModules() end,
    "Off hides every HunterKit frame and sound.")
  y = y - CHK

  if not HK.isHunter then
    local note = content:CreateFontString(nil, "OVERLAY")
    note:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y - 18)
    note:SetFontObject(GameFontNormal)
    note:SetText("|cffff8800Not a hunter — hunter features are disabled.|r")
    y = y - 36
  end

  -- Feed
  AddSection(content, y, "Feed Pet")
  y = y - HDR
  MakeCheckbox(content, y, "Enable feed button", function() return db.feed.enabled end,
    function(v) db.feed.enabled = v; RefreshFeed() end,
    "One-click Feed Pet beside the happiness icon. Right-click to pick food.")
  y = y - CHK
  MakeCheckbox(content, y, "Only when hungry", function() return db.feed.hungryOnly end,
    function(v) db.feed.hungryOnly = v; RefreshFeed() end,
    "Hide the button once the pet is Happy. A Content pet still shows it — that is the one you feed to get back to green.")
  y = y - CHK
  MakeCheckbox(content, y, "Learn food dropped on the button", function() return db.feed.learnDrop end,
    function(v) db.feed.learnDrop = v end,
    "Drag any food onto the feed button to pin it and teach the button that your pet eats it. There is no game API for what diet a food belongs to, so the built-in list can never cover every cooked dish — this closes the gap. Hold Shift over the button to see the foods it is not counting. Quest items are always refused.")
  y = y - CHK
  MakeCheckbox(content, y, "Use default Feed Pet icon", function() return db.feed.useSpellIcon end,
    function(v) db.feed.useSpellIcon = v; RefreshFeed() end,
    "Replace the chosen food's icon on the button with the default Feed Pet spell icon. The count of available food stays on the button either way.")
  y = y - CHK
  MakeSlider(content, y, "Button size", 24, 48, 1, function() return db.feed.size end,
    function(v) db.feed.size = v; RefreshFeed() end, "Size of the feed button, in pixels.")
  y = y - ROW
  MakeDropdown(content, y, "Anchor", { "PetFrame", "UIParent" },
    function() return db.feed.parent end,
    function(v) db.feed.parent = v; RefreshFeed() end,
    "PetFrame = by the happiness icon. UIParent = free/drag, for when an addon hides the pet frame.")
  y = y - ROW

  -- Range
  AddSection(content, y, "Sniper Mark")
  y = y - HDR
  MakeCheckbox(content, y, "Enable range mark", function() return db.range.enabled end,
    function(v) db.range.enabled = v; RefreshRange() end,
    "Reticle by the target frame: in range, too close or out of range.")
  y = y - CHK
  MakeSlider(content, y, "Mark size", 20, 96, 1, function() return db.range.size end,
    function(v) db.range.size = v; RefreshRange() end, "Size of the reticle, in pixels.")
  y = y - ROW
  -- Shape/brightness grid (user sketch): SHAPE cycle-buttons on the left with the
  -- state name beside them, BRIGHTNESS sliders on the right, one row per state.
  local function ShapeRow(labelText, options, get, set, tip, bGet, bSet)
    local row = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    row:SetSize(150, 22)
    row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y - 4)
    row:SetText(get() or "")
    row:SetScript("OnClick", function()
      local cur = get()
      local idx = 1
      for i, o in ipairs(options) do if o == cur then idx = i end end
      local nxt = options[(idx % #options) + 1]
      set(nxt)
      row:SetText(nxt)
    end)
    AttachTooltip(row, labelText .. " shape", tip)
    controlRefresh[#controlRefresh + 1] = function() row:SetText(get() or "") end
    local st = content:CreateFontString(nil, "OVERLAY")
    st:SetPoint("LEFT", row, "RIGHT", 10, 0)
    st:SetFontObject(GameFontNormal)
    st:SetJustifyH("LEFT")
    st:SetWordWrap(false)
    st:SetText(labelText)
    st:SetTextColor(0.9, 0.9, 0.9)
    MakeSlider(content, y, "", 0, 200, 5, bGet, bSet,
      "Glow intensity of the " .. labelText .. " mark.", true)
    y = y - CHK
  end
  local hShape = content:CreateFontString(nil, "OVERLAY")
  hShape:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
  hShape:SetFontObject(GameFontNormal)
  hShape:SetJustifyH("LEFT")
  hShape:SetText("SHAPE")
  local hBright = content:CreateFontString(nil, "OVERLAY")
  hBright:SetPoint("TOPRIGHT", content, "TOPRIGHT", -34, y)
  hBright:SetFontObject(GameFontNormal)
  hBright:SetJustifyH("LEFT")
  hBright:SetText("BRIGHTNESS")
  y = y - 20
  ShapeRow("IN RANGE", ShapeNames("OK", { "crosshair", "diamond", "brackets" }),
    function() return db.range.markOK or "plus" end,
    function(v) db.range.markOK = v; RefreshRange() end,
    "Shape while Auto Shot is in range (green). Click to cycle the six styles.",
    function() return db.range.brightOK or 100 end,
    function(v) db.range.brightOK = v; RefreshRange() end)
  ShapeRow("TOO CLOSE", ShapeNames("DEAD", { "x", "block", "circle" }),
    function() return db.range.markDead or "cross" end,
    function(v) db.range.markDead = v; RefreshRange() end,
    "Shape when the target is too close (red). Click to cycle the six styles.",
    function() return db.range.brightDead or 100 end,
    function(v) db.range.brightDead = v; RefreshRange() end)
  ShapeRow("OUT OF RANGE", ShapeNames("FAR", { "rings", "dashed", "halo" }),
    function() return db.range.markFar or "ban" end,
    function(v) db.range.markFar = v; RefreshRange() end,
    "Shape when the target is out of range (grey). Click to cycle the six styles.",
    function() return db.range.brightFar or 100 end,
    function(v) db.range.brightFar = v; RefreshRange() end)
  MakeCheckbox(content, y, "Show range label", function() return db.range.showLabel end,
    function(v) db.range.showLabel = v; RefreshRange() end, "Spell the state out under the mark.")
  y = y - CHK
  MakeDropdown(content, y, "Anchor", { "TargetFrame", "UIParent" },
    function() return db.range.parent end,
    function(v) db.range.parent = v; RefreshRange() end,
    "TargetFrame = beside the target. UIParent = free/drag, for when an addon hides the target frame.")
  y = y - ROW

  -- Pet Mend Marker
  AddSection(content, y, "Pet Mend Marker")
  y = y - HDR
  MakeCheckbox(content, y, "Enable mend marker", function() return db.mend.enabled end,
    function(v) db.mend.enabled = v; RefreshMend() end,
    "Mend Pet icon over your pet. Solid green = a Mend will land, faded red = too far.")
  y = y - CHK
  MakeSlider(content, y, "Icon size", 20, 72, 1, function() return db.mend.size end,
    function(v) db.mend.size = v; RefreshMend() end, "Size of the marker, in pixels.")
  y = y - ROW
  MakeSlider(content, y, "Height above head", -20, 80, 1, function() return db.mend.offsetY end,
    function(v) db.mend.offsetY = v; RefreshMend() end,
    "Gap above the anchor. Ignored once you drag the marker (/htk unlock).")
  y = y - ROW
  MakeSlider(content, y, "Urgent below % HP", 5, 100, 5, function() return db.mend.hpThreshold end,
    function(v) db.mend.hpThreshold = v; RefreshMend() end,
    "At or below this HP the marker grows, pulses and shows a red ring.")
  y = y - ROW
  MakeCheckbox(content, y, "Show only below threshold", function() return db.mend.onlyBelow end,
    function(v) db.mend.onlyBelow = v; RefreshMend() end,
    "Hide the marker entirely while the pet is above the HP threshold, instead of showing it calm.")
  y = y - CHK
  MakeCheckbox(content, y, "Urgent pulse", function() return db.mend.urgentPulse end,
    function(v) db.mend.urgentPulse = v; RefreshMend() end,
    "Grow, pulse and red ring while the pet is low.")
  y = y - CHK
  MakeCheckbox(content, y, "Only in combat", function() return db.mend.combatOnly end,
    function(v) db.mend.combatOnly = v; RefreshMend() end,
    "Hide out of combat; a low pet always shows.")
  y = y - CHK
  MakeCheckbox(content, y, "Fade when out of range", function() return db.mend.dimWhenFar end,
    function(v) db.mend.dimWhenFar = v; RefreshMend() end,
    "Grey and fade while the pet is out of range.")
  y = y - CHK
  MakeCheckbox(content, y, "Label", function() return db.mend.showLabel end,
    function(v) db.mend.showLabel = v; RefreshMend() end,
    "'MEND!' when low, 'TOO FAR' when out of range.")
  y = y - CHK
  MakeDropdown(content, y, "Anchor", { "auto", "plate", "petframe" },
    function() return db.mend.anchor end,
    function(v) db.mend.anchor = v; RefreshMend() end,
    "auto = over the head when a pet plate exists, else above the pet frame. plate = head only. petframe = UI frame only.")
  y = y - ROW
  MakeCheckbox(content, y, "Nameplate style bar", function() return db.mend.plateStyle end,
    function(v) db.mend.plateStyle = v; RefreshMend() end,
    "Pet name + HP bar under the icon, only when no real plate is there.")
  y = y - CHK

  -- Ammo
  AddSection(content, y, "Ammo")
  y = y - HDR
  MakeCheckbox(content, y, "Enable low ammo warning", function() return db.ammo.enabled end,
    function(v) db.ammo.enabled = v; RefreshAmmo() end,
    "Periodic on-screen warning (right of the passive alert) when your equipped ammo runs low: the equipped projectile icon under a red X. The less ammo, the more often and the longer it shows.")
  y = y - CHK
  MakeSlider(content, y, "Warn below", 10, 500, 10, function() return db.ammo.threshold or 200 end,
    function(v) db.ammo.threshold = v; RefreshAmmo() end,
    "Warn when the equipped ammo count drops to this or lower.", true)
  y = y - CHK
  MakeSlider(content, y, "Warn frequency", 1, 4, 1, function() return db.ammo.frequency or 1 end,
    function(v) db.ammo.frequency = v; RefreshAmmo() end,
    "How often the warnings repeat: 1x is the default rhythm (low ~90 s, empty ~10 s), 4x repeats four times as often. Voice cooldowns scale with it.", true)
  y = y - CHK
  MakeCheckbox(content, y, "Warning sound", function() return db.ammo.sound end,
    function(v) db.ammo.sound = v end,
    "Voice only -- no game sounds. Bundled clips speak the situation: \"Low arrows!\"/\"Low ammo!\" while low (at most once a minute), \"No arrows!\"/\"No ammo!\" when the slot is empty (at most once every 30 s); the frequency option scales both. Off by default.")
  y = y - CHK

  -- Ammo auto-buy
  AddSection(content, y, "Ammo auto-buy")
  y = y - HDR
  MakeCheckbox(content, y, "Enable ammo auto-buy", function() return db.ammobuy.enabled end,
    function(v) db.ammobuy.enabled = v; RefreshAmmoBuy() end,
    "Refill your quiver / ammo pouch from a vendor. Works out exactly how many arrows or bullets are missing and buys precisely that many -- a 63-arrow top-up costs one click, not a whole spare stack. Gold reserve and spend cap are always respected.")
  y = y - CHK
  MakeDropdown(content, y, "When at a vendor", { "confirm", "auto", "manual" },
    function() return db.ammobuy.mode end,
    function(v) db.ammobuy.mode = v; RefreshAmmoBuy() end,
    "confirm = a popup asks before spending (default). auto = buys silently as soon as the merchant opens. manual = only the 'Refill ammo' button or /htk buy.")
  y = y - ROW
  MakeDropdown(content, y, "Ammo tier", { "equipped", "best", "capped" },
    function() return db.ammobuy.tier end,
    function(v) db.ammobuy.tier = v; RefreshAmmoBuy() end,
    "equipped = more of what is in your ammo slot (falls back to the best of the same kind if the vendor lacks it). best = the highest tier you can use. capped = best, but never above the level cap below.")
  y = y - ROW
  MakeCheckbox(content, y, "Only buy highest usable ammo",
    function() return db.ammobuy.bestOnly end,
    function(v) db.ammobuy.bestOnly = v; RefreshAmmoBuy() end,
    "Never buy ammo weaker than what you already shoot. Low-level vendors often stock only Rough Arrow / Light Shot -- with this ticked the refill refuses there and tells you why, instead of downgrading your quiver. Restocking the same tier or upgrading is always allowed. Ignored in 'capped' tier mode, where you have deliberately asked for cheaper ammo. On by default.")
  y = y - CHK
  MakeSlider(content, y, "Tier level cap", 1, 70, 1, function() return db.ammobuy.tierCap or 60 end,
    function(v) db.ammobuy.tierCap = v; RefreshAmmoBuy() end,
    "Only used by the 'capped' tier mode: never buy ammo whose required level is above this. Handy for staying on cheap arrows while levelling.", true)
  y = y - CHK
  MakeCheckbox(content, y, "Fill completely (100%)", function() return db.ammobuy.full end,
    function(v) db.ammobuy.full = v; RefreshAmmoBuy() end,
    "Fill every slot of the quiver / ammo pouch. Untick to use the percentage slider below instead.")
  y = y - CHK
  MakeSlider(content, y, "Fill to", 5, 100, 5, function() return db.ammobuy.percent or 100 end,
    function(v) db.ammobuy.percent = v; RefreshAmmoBuy() end,
    "How full to keep the quiver / pouch, as a percentage of its total capacity (slots x 200). Ignored while 'Fill completely' is ticked.", true)
  y = y - CHK
  MakeSlider(content, y, "Keep gold in reserve", 0, 100, 1,
    function() return db.ammobuy.reserveGold or 0 end,
    function(v) db.ammobuy.reserveGold = v; RefreshAmmoBuy() end,
    "Never spend your last gold: the refill stops once your money would drop below this. 0 = no reserve.", true)
  y = y - CHK
  MakeSlider(content, y, "Max spend per visit", 0, 100, 1,
    function() return db.ammobuy.maxSpendGold or 0 end,
    function(v) db.ammobuy.maxSpendGold = v; RefreshAmmoBuy() end,
    "Hard cap on what a single refill may cost, in gold. 0 = no cap. If the budget is short it buys as many rounds as it covers.", true)
  y = y - CHK
  MakeCheckbox(content, y, "Merchant 'Refill ammo' button",
    function() return db.ammobuy.showButton end,
    function(v) db.ammobuy.showButton = v; RefreshAmmoBuy() end,
    "Show a Refill ammo button on the vendor window. It shows the exact amount it would buy in its tooltip, or the reason it cannot.")
  y = y - CHK

  -- Pet aggro warning
  AddSection(content, y, "Pet aggro warning")
  y = y - HDR
  MakeCheckbox(content, y, "Show aggro % by the player frame",
    function() return db.threat.showPct end,
    function(v) db.threat.showPct = v; RefreshThreat() end,
    "A live threat percentage above and to the right of your player frame while you are in combat with a pet: green while safe, amber as it climbs, red once you are at the pull point. At the 'Warn at' threshold below it grows to 1.5x and pulses. 100% is the moment the mob turns on you. Quiet and passive -- no sound, no popup. Unlock the frames (/htk unlock) to drag it.")
  y = y - CHK
  MakeCheckbox(content, y, "Show damage-to-pull before the %",
    function() return db.threat.showGap end,
    function(v) db.threat.showGap = v; RefreshThreat() end,
    "Prefixes the percentage with roughly how much more damage you could deal before taking the mob, e.g. \"1.2k 74%\". Derived from the game's own threat numbers; a hunter's shots are about 1 threat per 1 damage, so it reads directly as damage. An estimate -- Growl landing or a pet crit moves the target.")
  y = y - CHK
  MakeCheckbox(content, y, "Also warn me on screen (sound + alert)",
    function() return db.threat.enabled end,
    function(v) db.threat.enabled = v; RefreshThreat() end,
    "Off by default. A plain THREAT flash and a sound when your threat is CLIMBING and reaches the threshold on a mob the pet is tanking -- silent while it falls back, so easing off stops the warning. Shows AGGRO if the mob does switch to you.")
  y = y - CHK
  MakeSlider(content, y, "Warn at", 40, 100, 5,
    function() return db.threat.threshold or 80 end,
    function(v) db.threat.threshold = v; RefreshThreat() end,
    "Where the warning fires and the percentage readout turns red, grows and pulses. 100% is the instant the mob turns on you, so leave headroom. Melee vs ranged distance is already accounted for.", true)
  y = y - CHK
  MakeCheckbox(content, y, "Play a warning sound",
    function() return db.threat.sound end,
    function(v) db.threat.sound = v; RefreshThreat() end,
    "A short alert when the warning first appears, and a louder one if the mob actually switches to you. Repeats no more often than the interval below.")
  y = y - CHK
  MakeSlider(content, y, "Sound repeat interval", 2, 15, 1,
    function() return db.threat.soundInterval or 4 end,
    function(v) db.threat.soundInterval = v; RefreshThreat() end,
    "Minimum seconds between warning sounds, so a long fight spent near the threshold cannot turn into a siren.", true)
  y = y - CHK
  MakeSlider(content, y, "Warning size", 32, 96, 4,
    function() return db.threat.size or 56 end,
    function(v) db.threat.size = v; RefreshThreat() end,
    "Size of the on-screen warning icon. Unlock the frames (/htk unlock) to drag it where you want it.", true)
  y = y - CHK

  -- Weapon timers: the bar covers ranged AND melee swings, not just Auto Shot.
  AddSection(content, y, "Weapon timers")
  y = y - HDR
  MakeCheckbox(content, y, "Show the weapon timers bar",
    function() return db.shottimer.enabled end,
    function(v) db.shottimer.enabled = v; RefreshShotTimer() end,
    "A bar showing your Auto Shot cycle while you are firing. Green means you are free to move and weave in a shot; the red zone at the end is the 0.5s where doing anything clips the shot and loses the damage; a white hairline marks where that lockout begins; and a yellow slice left of the red appears for one cycle after a late shot, sized to how late it was. A state line underneath reads your situation at a glance, and the bar can be kept on screen with the option below. Appears only while auto-shooting. The picture under these settings names every part.")
  y = y - CHK
  MakeCheckbox(content, y, "Keep the bar on screen",
    function() return db.shottimer.always end,
    function(v) db.shottimer.always = v; RefreshShotTimer() end,
    "Normally the bar appears when you start shooting and leaves when you stop. Turn this on to keep it in place all the time, so it never moves or surprises you. It shows an idle track when you are not firing.")
  y = y - CHK
  MakeCheckbox(content, y, "Show how much you clipped",
    function() return db.shottimer.showDelay end,
    function(v) db.shottimer.showDelay = v; RefreshShotTimer() end,
    "After each shot, shows how late it actually landed, e.g. +0.34s -- measured as (when the shot really fired) minus (when the bar predicted it), never predicted. Latency can move that number, but so can spell batching, the server's re-shot timer, and above all acting inside the lockout, so read it as how much you CLIPPED rather than as a latency figure. A steady +0.00 means you are clean. The same figure is drawn as the yellow slice on the bar.")
  y = y - CHK
  MakeCheckbox(content, y, "Show the free-time countdown",
    function() return db.shottimer.showText end,
    function(v) db.shottimer.showText = v; RefreshShotTimer() end,
    "Counts down the time you still have to act before the shot locks you in place. It also changes wording when there is something to decide: GO when a weave fits right now, \"weave in 1.2s\" while one is coming, \"shoot\" when a special shot is up and worth spending first, and \"hold\" inside the lockout.")
  y = y - CHK
  MakeCheckbox(content, y, "Melee swing timer",
    function() return db.shottimer.weave end,
    function(v) db.shottimer.weave = v; RefreshShotTimer() end,
    "Adds a second bar tracking your melee swing -- the same height as the shot bar, because in the two-mob setup the two cycles matter equally. Also adds a blue line on the shot bar marking where a melee hit belongs in the cycle: with running in and out switched OFF (the default) that is the moment your swing comes up while a mob is already at your feet; with it ON it is the last moment you could still leave and get back in time. In Classic Era the melee and ranged timers are independent, which is what makes weaving possible at all.")
  y = y - CHK
  MakeCheckbox(content, y, "Also weave by running in and out",
    function() return db.shottimer.travelWeave end,
    function(v) db.shottimer.travelWeave = v; RefreshShotTimer() end,
    "Off by default. Leave it off and the bar never tells you to go running anywhere. It will STILL show the blue marker and read WEAVE when a mob is already within swing distance -- that is the static weave, and it is intended. Note this means any attackable mob within the ~11yd melee probe, not only your target: your mouseover, your pet's target, and whatever is attacking your target all count, because in the two-mob setup any of those can be the mob standing at your feet. So the marker can come and go as mobs drift in and out of range while travel weaving is off -- that is the static weave switching on and off, not this setting leaking. Turn it on for \"normal\" weaving -- running out to a distant target between shots and back before the lockout -- which is a real technique but needs the round trip below to match how fast you actually move.")
  y = y - CHK
  -- Stored in tenths on the bar (the widget formats with %d, so a fractional
  -- step would crash it) but DISPLAYED in seconds via the formatter -- the
  -- setting is a duration, so making the player convert tenths in their head
  -- was needless friction.
  MakeSlider(content, y, "Weave round trip (seconds)", 10, 50, 5,
    function() return (db.shottimer.travel or 2.5) * 10 end,
    function(v) db.shottimer.travel = v / 10; RefreshShotTimer() end,
    "Only used when \"weave by running in and out\" is on: the full trip out to melee and back. 2.5s is a good hunter with a movement buff. Ignored when the target is already in melee.",
    true, function(v) return string.format("%.1fs", v / 10) end)
  y = y - CHK
  MakeCheckbox(content, y, "Show Aimed / Multi-Shot cooldowns",
    function() return db.shottimer.showSpecials end,
    function(v) db.shottimer.showSpecials = v; RefreshShotTimer() end,
    "Adds a row under the bar showing whether Aimed Shot and Multi-Shot are ready. Green means spend it; dark means it is on cooldown, which is exactly when a melee weave is the right use of the gap.")
  y = y - CHK
  MakeCheckbox(content, y, "Only suggest weaving when specials are down",
    function() return db.shottimer.specials end,
    function(v) db.shottimer.specials = v; RefreshShotTimer() end,
    "Hides the WEAVE cue while Aimed or Multi-Shot is ready, since either is worth more than a Raptor Strike. Turn off if you weave around your specials rather than only between them.")
  y = y - CHK
  MakeCheckbox(content, y, "Show the two-mob weave state strip",
    function() return db.shottimer.rangeStrip end,
    function(v) db.shottimer.rangeStrip = v; RefreshShotTimer() end,
    "One line under the bar saying which situation you are in. |cff4dff73PRESS 2-MOB|r = your pet is holding a second mob and your melee swing is up: press the two-mob macro now. |cff66ccff2-MOB - SWING 1.2s|r = the setup is live, waiting on the swing. |cffe6b333MELEE ONLY|r = something is in melee but there is no second mob to shoot. |cff909098RANGE|r = nothing in melee. |cffff4d4dOUT OF RANGE|r = your target is past Auto Shot range. This is the indicator for standing in melee of one mob while your pet holds another -- the setup the two-mob macro exists for, which the bar used to say nothing about.")
  y = y - CHK
  MakeCheckbox(content, y, "Show the two-mob press icon",
    function() return db.shottimer.twoMobIcon end,
    function(v) db.shottimer.twoMobIcon = v; RefreshShotTimer() end,
    "A separate icon that lights up bright green with NOW on it at the exact moment pressing the two-mob macro is correct: your target is in melee, your pet has a DIFFERENT live target, your melee swing is up, and Auto Shot is not in its 0.5s lockout. Dimmed with a countdown while the setup is live but the swing is still coming, and nearly invisible otherwise -- so a flash means press. Drag it into your peripheral vision with /htk unlock; it parks beside the bar until you do.")
  y = y - CHK
  MakeCheckbox(content, y, "Show a 'what to press next' row",
    function() return db.shottimer.recoRow end,
    function(v) db.shottimer.recoRow = v; RefreshShotTimer() end,
    "Instead of only showing clocks, says which button is worth pressing: the two-mob macro first, then Aimed Shot, Multi-Shot, Raptor Strike when you are in melee, or weave/hold. The approach Fluffy Hunter Bars takes -- worth having while you are learning the rotation, easy to switch off once it is automatic.")
  y = y - CHK - 4
  y = AddShotBarLegend(content, y)
  MakeSlider(content, y, "Bar width", 120, 400, 10,
    function() return db.shottimer.width or 220 end,
    function(v) db.shottimer.width = v; RefreshShotTimer() end,
    "Width of the shot bar in pixels. Unlock the frames (/htk unlock) to drag it.", true)
  y = y - CHK
  MakeSlider(content, y, "Bar height", 8, 60, 3,
    function() return db.shottimer.height or 27 end,
    function(v) db.shottimer.height = v; RefreshShotTimer() end,
    "Height of the shot bar in pixels. The melee and state strips scale with it, so taller makes the whole stack easier to read mid-fight. Default 27, was 18 before 0.9.71.", true)
  y = y - CHK

  -- Sound
  AddSection(content, y, "Gun Sound")
  y = y - HDR
  MakeCheckbox(content, y, "Replace gun shot sound", function() return db.sound.enabled end,
    function(v)
      db.sound.enabled = v
      db.sound.muteOriginal = v
      RefreshSound()
    end,
    "Pew on each shot, stock gunshot muted. Untick to restore it at once.")
  y = y - CHK
  MakeCheckbox(content, y, "Pew on special shots", function() return db.sound.specials end,
    function(v) db.sound.specials = v end,
    "Arcane Shot, Multi-Shot and Aimed Shot pew too. Untick for auto shot only.")
  y = y - CHK

  -- Pulse
  AddSection(content, y, "Passive pet alert")
  y = y - HDR
  MakeCheckbox(content, y, "Enable passive alert", function() return db.pulse.enabled end,
    function(v) db.pulse.enabled = v; RefreshPulse() end,
    "Centre-screen pulse while the pet is Passive.")
  y = y - CHK
  MakeSlider(content, y, "Icon size", 48, 128, 2, function() return db.pulse.size end,
    function(v) db.pulse.size = v; RefreshPulse() end, "Size of the alert icon, in pixels.")
  y = y - ROW
  MakeCheckbox(content, y, "Sonar rings", function() return db.pulse.rings end,
    function(v) db.pulse.rings = v end, "Expanding sonar rings behind the icon.")
  y = y - CHK
  MakeCheckbox(content, y, "Label", function() return db.pulse.label end,
    function(v) db.pulse.label = v; RefreshPulse() end, "'PET PASSIVE!' under the icon.")
  y = y - CHK

  -- Macros -- a button, not a wall of text. The macros live in their own window
  -- (Macros.lua): they are reference material you visit once and copy from, not
  -- settings, and five multi-line boxes inline would double the length of this
  -- list for something you rarely touch.
  AddSection(content, y, "Macros")
  y = y - HDR
  local macroBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
  macroBtn:SetWidth(180); macroBtn:SetHeight(24)
  macroBtn:SetText("Open macro library")
  macroBtn:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
  macroBtn:SetScript("OnClick", function()
    if HK.Macros then HK.Macros.Toggle() end
  end)
  AttachTooltip(macroBtn, "Macro library",
    "Hunter macros worth having, each with a short explanation. Click a macro to select it, then Ctrl+C to copy it into your macro window.")
  y = y - 30

  -- Display priority. One master layer for every HunterKit frame, a fine level,
  -- and a per-widget override for the ones that need to differ from the rest.
  AddSection(content, y, "Display priority")
  y = y - HDR

  -- The per-widget list gets "Follow master" instead of the global's "Current":
  -- the two mean different things. There, Current = the layer it was built with;
  -- here, the widget defers to whatever the master row says.
  local WIDGET_PRESETS = { { key = "inherit", label = "Follow master" } }
  for _, p in ipairs(HK.PRIORITY_PRESETS) do
    if p.key ~= "inherit" then WIDGET_PRESETS[#WIDGET_PRESETS + 1] = p end
  end

  local WIDGET_LABEL = {
    ammo       = "Ammo warning",
    feed       = "Feed button",
    mend       = "Mend marker",
    pulse      = "Passive pet alert",
    range      = "Sniper mark",
    shottimer  = "Weapon timer bars",
    threat     = "Pet aggro alert",
    threatpct  = "Threat readout",
    twomobicon = "Two-mob press icon",
  }

  local function LabelOf(options, key)
    for _, o in ipairs(options) do if o.key == key then return o.label end end
    return options[1].label
  end

  -- Click-to-cycle, the same control the sniper-mark shapes already use: the
  -- window is hand-built, there is no dropdown template to lean on, and the
  -- current value stays on screen instead of hiding behind a click.
  local function CycleRow(labelText, options, get, set, tip)
    local row = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    row:SetSize(150, 22)
    row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y - 4)
    row:SetText(LabelOf(options, get()))
    row:SetScript("OnClick", function()
      local cur, idx = get(), 1
      for i, o in ipairs(options) do if o.key == cur then idx = i end end
      local nxt = options[(idx % #options) + 1]
      set(nxt.key)
      row:SetText(nxt.label)
    end)
    AttachTooltip(row, labelText, tip)
    controlRefresh[#controlRefresh + 1] = function()
      row:SetText(LabelOf(options, get()))
    end
    local st = content:CreateFontString(nil, "OVERLAY")
    st:SetPoint("LEFT", row, "RIGHT", 10, 0)
    st:SetFontObject(GameFontNormal)
    st:SetJustifyH("LEFT")
    st:SetWordWrap(false)
    st:SetText(labelText)
    st:SetTextColor(0.9, 0.9, 0.9)
    y = y - CHK
  end

  CycleRow("All HunterKit frames", HK.PRIORITY_PRESETS,
    function() return db.priority.strata end,
    function(v) db.priority.strata = v; HK.ApplyPriority() end,
    "How high every HunterKit bar, icon and mark draws against the rest of your UI. |cff4dff73Current|r leaves each frame exactly on the layer it was built with, so nothing changes until you ask it to. |cff9fd8ffAlways on top|r sits above every normal panel but still under fullscreen ones such as the world map -- drawing over the map is a bug, not a feature, so it is deliberately not offered.")
  MakeSlider(content, y, "Extra frame level", 0, 200, 5,
    function() return db.priority.level end,
    function(v) db.priority.level = v; HK.ApplyPriority() end,
    "Added to each frame's own level inside its layer. Only matters against OTHER addons drawing in the same layer: raise it to sit above them. HunterKit's own frames keep their relative order at any value.")
  y = y - ROW

  for _, key in ipairs(HK.WidgetNames()) do
    CycleRow(WIDGET_LABEL[key] or key, WIDGET_PRESETS,
      function() return (db.priority.widgets and db.priority.widgets[key]) or "inherit" end,
      function(v)
        db.priority.widgets = db.priority.widgets or {}
        db.priority.widgets[key] = v
        HK.ApplyPriority(key)
      end,
      "Overrides the master layer for this one frame. Follow master means it uses whatever the row at the top of this section says.")
  end

  -- Positions
  AddSection(content, y, "Positions")
  y = y - HDR
  unlockBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
  unlockBtn:SetWidth(140); unlockBtn:SetHeight(24)
  unlockBtn:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
  unlockBtn:SetScript("OnClick", function() HK.Positions.ToggleLock() end)
  -- reflect the current lock state on the button (alternates as you toggle).
  UpdateLockButton()
  y = y - ROW
  local resetBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
  resetBtn:SetWidth(140); resetBtn:SetHeight(24)
  resetBtn:SetText("Reset positions")
  resetBtn:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
  resetBtn:SetScript("OnClick", function() HK.Positions.Reset() end)
  y = y - ROW

  -- Reset everything. Two-step so a stray click can't wipe the settings, and the
  -- armed state expires on its own.
  AddSection(content, y, "Reset")
  y = y - HDR
  local resetAll = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
  resetAll:SetWidth(200); resetAll:SetHeight(24)
  resetAll:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
  resetAll:SetText("Reset ALL settings")
  local armed = false
  local function Disarm()
    armed = false
    resetAll:SetText("Reset ALL settings")
  end
  resetAll:SetScript("OnClick", function()
    if not armed then
      armed = true
      resetAll:SetText("Click again to CONFIRM")
      C_Timer.After(5, function() if armed then Disarm() end end)
      return
    end
    Disarm()
    HK.ResetAll()
    Options.RefreshControls()   -- bring this window back in line with the db
  end)
  AttachTooltip(resetAll, "Reset ALL settings",
    "Restores every HunterKit setting — sizes, shapes, toggles and saved positions — to its default. Your key bindings and the game's own options are untouched.")
  y = y - ROW

  BuildNav()
  content:SetHeight(math.max(1, -y))
  if win.UpdateScroll then win.UpdateScroll() end
  return win
end

-- ---------------------------------------------------------------------------
-- Small dropdown helper (simple button that cycles through options)
-- ---------------------------------------------------------------------------
function MakeDropdown(parent, y, labelText, options, get, set, tooltip)
  local row = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  row:SetSize(170, 24)
  row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y)
  row:SetText(get() or "")
  row:SetScript("OnClick", function()
    local cur = get()
    local idx = 1
    for i, o in ipairs(options) do if o == cur then idx = i end end
    local next = options[((idx) % #options) + 1]
    set(next)
    row:SetText(next)
  end)
  local txt = row:CreateFontString(nil, "OVERLAY")
  txt:SetPoint("LEFT", row, "RIGHT", 8, 0)
  txt:SetFontObject(GameFontNormal)
  txt:SetJustifyH("LEFT")
  txt:SetWordWrap(false)
  txt:SetWidth(math.max(120, (parent:GetWidth() or 436) - 190))
  txt:SetText(labelText)
  txt:SetTextColor(0.9, 0.9, 0.9)
  AttachTooltip(row, labelText, tooltip)
  controlRefresh[#controlRefresh + 1] = function() row:SetText(get() or "") end
  return row
end

-- ---------------------------------------------------------------------------
-- Refresh helpers (call each feature's Refresh)
-- ---------------------------------------------------------------------------
function RefreshModules()
  if HK.db.enabled == false then
    -- hide everything
    if HK.FeedPet and HK.FeedPet.Refresh then HK.FeedPet.Refresh() end
    if HK.Range and HK.Range.Update then HK.Range.Update() end
    if HK.PassivePulse and HK.PassivePulse.Refresh then HK.PassivePulse.Refresh() end
    if HK.MendMark and HK.MendMark.Update then HK.MendMark.Update() end
  else
    RefreshFeed(); RefreshRange(); RefreshSound(); RefreshPulse(); RefreshAmmo(); RefreshAmmoBuy(); RefreshMend(); RefreshThreat(); RefreshShotTimer()
  end
end
function RefreshFeed() if HK.FeedPet and HK.FeedPet.RescanSettings then HK.FeedPet.RescanSettings() end end
function RefreshRange() if HK.Range and HK.Range.RescanSettings then HK.Range.RescanSettings() end end
function RefreshPulse() if HK.PassivePulse and HK.PassivePulse.RescanSettings then HK.PassivePulse.RescanSettings() end end
function RefreshMend() if HK.MendMark and HK.MendMark.RescanSettings then HK.MendMark.RescanSettings() end end
function RefreshSound() if HK.Sounds and HK.Sounds.RescanSettings then HK.Sounds.RescanSettings() end end
function RefreshAmmo() if HK.AmmoWarn and HK.AmmoWarn.RescanSettings then HK.AmmoWarn.RescanSettings() end end
function RefreshAmmoBuy() if HK.AmmoBuy and HK.AmmoBuy.RescanSettings then HK.AmmoBuy.RescanSettings() end end
function RefreshThreat() if HK.ThreatWatch and HK.ThreatWatch.RescanSettings then HK.ThreatWatch.RescanSettings() end end
function RefreshShotTimer() if HK.ShotTimer and HK.ShotTimer.RescanSettings then HK.ShotTimer.RescanSettings() end end

-- ---------------------------------------------------------------------------
-- Minimap button
-- ---------------------------------------------------------------------------
local mm
function BuildMinimapButton()
  if not db.ui.minimapShow then return end
  local btn = CreateFrame("Button", "HunterKitMinimapButton", Minimap)
  btn:SetSize(26, 26)
  btn:SetFrameStrata("MEDIUM")
  btn:SetFrameLevel(8)

  local icon = btn:CreateTexture(nil, "ARTWORK")
  icon:SetAllPoints()
  icon:SetTexture("Interface\\Icons\\Ability_Seal")
  icon:SetTexCoord(0.12, 0.88, 0.12, 0.88)

  btn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight")
  btn:SetScript("OnClick", function(self, b)
    if b == "RightButton" then HK.Positions.ToggleLock()
    else Options.Toggle() end
  end)
  btn:SetScript("OnEnter", function()
    GameTooltip:SetOwner(btn, "ANCHOR_LEFT"); GameTooltip:SetText("HunterKit")
    GameTooltip:AddLine("Left: options  |  Right: lock/unlock", 1,1,1); GameTooltip:Show()
  end)
  btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  -- orbit math
  local angle = math.rad(db.ui.minimapAngle or 210)
  btn:SetPoint("TOPLEFT", Minimap, "TOPLEFT", 54 + 80 * math.cos(angle), 54 - 80 * math.sin(angle))

  btn:RegisterForDrag("LeftButton")
  btn:SetScript("OnDragStart", function()
    btn:SetScript("OnUpdate", function()
      local x, y = GetCursorPosition()
      local mx, my = Minimap:GetCenter()
      x, y = x / UIParent:GetEffectiveScale(), y / UIParent:GetEffectiveScale()
      local dx, dy = x - mx, y - my
      local deg = math.deg(math.atan2(dy, dx))
      db.ui.minimapAngle = deg
      local rad = math.rad(deg + 90)
      btn:SetPoint("TOPLEFT", Minimap, "TOPLEFT", 54 + 80 * math.cos(rad), 54 - 80 * math.sin(rad))
    end)
  end)
  btn:SetScript("OnDragStop", function() btn:SetScript("OnUpdate", nil) end)

  mm = btn
end

-- ---------------------------------------------------------------------------
-- Positions (lock / unlock / reset)
-- ---------------------------------------------------------------------------
local Positions = {}
HK.Positions = Positions
Positions.locked = true

-- Reflect the lock state on the toggle button ("Unlock frames" <-> "Lock frames").
UpdateLockButton = function()
  if not unlockBtn then return end
  unlockBtn:SetText(Positions.locked and "Unlock frames" or "Lock frames")
end

-- Edit mode ends when the player presses "Lock frames" OR closes the options
-- window (X / ESC). It does NOT auto-lock from a timer or cursor — that caused
-- it to lock mid-arranging. The window's OnHide re-locks (see MakeWindow).
function Positions.ToggleLock()
  Positions.SetLock(not Positions.locked)
end

function Positions.Dragging()
  return draggingFrame ~= nil
end

function Positions.SetLock(locked)
  if locked == Positions.locked then
    UpdateLockButton()
    return
  end
  Positions.locked = locked
  local unlock = not locked
  draggingFrame = nil
  -- Big red EDIT MODE banner: shown while frames are unlocked, hidden on lock.
  if editBanner then editBanner:SetShown(unlock) end
  HK.Dbg("SetLock", "locked=" .. tostring(locked))
  for key, d in pairs(HK.draggables) do
    -- Capture the draggable and its frame in a fresh local so the closures below
    -- reference THIS frame (not the loop variable) on every client.
    local dd = d
    local name = key
    local f = dd.frame
    -- A frame that isn't the player's to move right now (the mend marker while
    -- it floats over the pet's head) must not have its drag state touched: on a
    -- restricted anchor the client throws and taints.
    --
    -- But that state FLIPS within a session: the marker is the draggable UI
    -- fallback while unlocked and is back on the protected name plate the moment
    -- you lock. So "not movable now" may only skip the SETUP -- a frame we
    -- already made draggable still has to be cleaned up, or it keeps its drag
    -- handlers, its mouse-enabled state and its faded edit-mode alpha forever.
    local active = f ~= nil and HK.DraggableActive(dd)
    if f and not active and not dd.dragSetup then
      HK.Dbg("SetLock skip (not draggable now)", key)
      f = nil
    end
    if f and unlock and not active then
      HK.Dbg("SetLock: nothing to make movable now", key)
      f = nil
    end
    if f then
      local clickable = dd.opts.clickable
      local mouse = clickable or unlock
      f:SetMovable(unlock)
      f:EnableMouse(mouse)
      -- pcall-guarded: a frame anchored to a name plate refuses to be clamped
      -- ("Can't clamp restricted regions") and would taint the whole loop. On
      -- lock, only clamp what is draggable now -- the mend marker sets its own
      -- clamp to match the anchor it just took.
      if unlock or active then HK.SafeClamp(f, true) end
      if unlock then
        -- blank secure click for clickable frames (avoid feeding while dragging).
        -- The feed button now uses a spell + target-item combo (not a macro), so
        -- clear those attributes too, or a left-press while dragging could feed.
        if dd.opts.blankSecure and not InCombatLockdown() then
          pcall(function()
            f:SetAttribute("type1", nil)
            f:SetAttribute("macrotext1", "")
            f:SetAttribute("spell", nil)
            f:SetAttribute("target-item", nil)
            f:SetAttribute("target-bag", nil)
            f:SetAttribute("target-slot", nil)
          end)
          -- Also stop it responding to clicks entirely while in edit mode so
          -- that pressing (or dragging) the feed button never casts Feed Pet.
          if f.UnregisterAllClicks then f:UnregisterAllClicks() end
        end
        -- Show every frame while in edit mode so it's grabbable, even one that
        -- would normally be hidden (e.g. a sniper mark with no target). Faded so
        -- you can tell it's in edit mode. (Skip show/hide on a secure frame while
        -- in combat to avoid taint — edit mode is out-of-combat anyway.)
        if not InCombatLockdown() then f:Show() end
        -- Showing the frame is not enough for a feature that PAINTS itself
        -- procedurally: the sniper mark draws nothing until it has a range
        -- state, so with no target the frame was shown but completely empty and
        -- the mark looked absent from edit mode. `preview` lets a module draw a
        -- representative sample. Mirrors `restore`, which runs on lock.
        --
        -- Runs BEFORE the fade: a module's own draw code may reset the frame's
        -- alpha, which would undo the edit-mode dimming if we faded first.
        if dd.opts.preview then pcall(dd.opts.preview) end
        f:SetAlpha(math.min(f:GetAlpha() or 1, 0.6))

        -- Fully manual, cursor-pinned drag. We do NOT use StartMoving/StopMovingOrSizing:
        -- those reset the frame's anchor, which is exactly what made icons jump.
        -- Instead we ClearAllPoints + pin the frame to the cursor via OnUpdate every
        -- frame, then on release convert the on-screen centre (UIParent space) into
        -- an offset against the frame it anchors to and re-apply.
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", function(self)
          local x, y = GetCursorPosition()
          local scale = UIParent:GetEffectiveScale() or 1
          HK.Dbg("drag START", name, "cursor=" .. tostring(x) .. "," .. tostring(y),
            "scale=" .. tostring(scale), HK.Geom(self))
          -- Grab offset (cursor minus frame centre). Both GetCursorPosition and
          -- the frame centre (HK.AbsCenter) use the same bottom-left / Y-up
          -- coordinate space, so this keeps the frame under the cursor exactly.
          local cx, cy = HK.AbsCenter(self)
          local grabX = (x / scale) - cx
          local grabY = (y / scale) - cy
          draggingFrame = self
          self:SetScript("OnUpdate", function(fr)
            local nx, ny = GetCursorPosition()
            local s = UIParent:GetEffectiveScale() or 1
            fr:ClearAllPoints()
            fr:SetPoint("CENTER", UIParent, "BOTTOMLEFT",
              (nx / s) - grabX, (ny / s) - grabY)
          end)
        end)
        dd.dragSetup = true
        f:SetScript("OnDragStop", function(self)
          draggingFrame = nil
          -- ALWAYS detach the cursor-pinning loop installed by OnDragStart,
          -- BEFORE giving the feature a chance to re-bind its own.
          --
          -- This used to be an either/or: a frame with an `onUpdate` option got
          -- opts.onUpdate() called INSTEAD of the clear. That silently assumed
          -- every such callback unconditionally sets a script. Two of them do
          -- not -- ShotTimer re-binds only `if onUpdateBound`, the threat
          -- readout only `if pctHot` -- so when the bar was not animating,
          -- nothing replaced the drag loop and the frame stayed pinned to the
          -- cursor forever, still following it after the mouse button was
          -- released. Clearing first makes the re-bind purely additive, so a
          -- conditional callback is safe.
          self:SetScript("OnUpdate", nil)
          if dd.opts.onUpdate then dd.opts.onUpdate() end
          -- Store the offset for the anchor-based apply, but DO NOT re-apply here:
          -- the frame is already exactly where the user dropped it (pinned to the
          -- cursor). Re-applying against the anchor right now can momentarily move
          -- it. The anchor-based position is applied on lock (below), reproducing
          -- the same absolute spot.
          if dd.opts.saveFromScreen then
            dd.opts.saveFromScreen()
          else
            local _, _, _, x, y = self:GetPoint()
            if dd.save then dd.save(x or 0, y or 0) end
          end
          HK.Dbg("drag STOP ", name, HK.Geom(self),
            ("savedOff=(%s,%s) moved=%s"):format(
              tostring(HK.db[name] and HK.db[name].offsetX),
              tostring(HK.db[name] and HK.db[name].offsetY),
              tostring(HK.db[name] and HK.db[name].moved)))
        end)
      else
        f:RegisterForDrag()
        f:SetScript("OnDragStart", nil)
        f:SetScript("OnDragStop", nil)
        f:SetScript("OnUpdate", nil)
        f:SetAlpha(1)
        -- Restore click handling that edit mode disabled (feed button re-registers
        -- its clicks, but only if not in combat).
        if dd.opts.clickRegistration and f.RegisterForClicks and not InCombatLockdown() then
          f:RegisterForClicks(unpack(dd.opts.clickRegistration))
        end
        -- Re-bind any persistent feature OnUpdate loop (passive pulse). The drag
        -- handlers above blanked it; without this the pulse animation dies after
        -- the first edit.
        if dd.opts.onUpdate then dd.opts.onUpdate() end
        -- restore normal visibility for this feature (feed shows if pet+enabled,
        -- sniper shows with a target, passive only when passive, etc.)
        if dd.opts.restore then dd.opts.restore() end
        if dd.apply then dd.apply() end
        HK.Dbg("lock apply ", key, HK.Geom(f),
          ("off=(%s,%s) moved=%s pinned=%s"):format(
            tostring(HK.db[key] and HK.db[key].offsetX),
            tostring(HK.db[key] and HK.db[key].offsetY),
            tostring(HK.db[key] and HK.db[key].moved),
            tostring(HK.db[key] and HK.IsPinned(HK.db[key]))))
        dd.dragSetup = nil
      end
    end
  end
  if unlock == false then
    if HK.FeedPet and HK.FeedPet.RefreshMacro then
      HK.FeedPet:RefreshMacro() -- colon: RefreshMacro is a method, needs `self`
    end
    -- After locking, restore proper per-feature visibility: edit mode forces
    -- every frame visible as a drag target, and each feature has to be given
    -- the chance to put itself away again.
    --
    -- This list must cover EVERY module with an edit-mode preview. It used to
    -- be nested inside the FeedPet branch (so it did not run at all without a
    -- feed macro) and named only two modules, which is why the threat warning
    -- icon stayed on screen after relocking -- nothing ever told it to
    -- re-evaluate, and its own linger check only fires after a real alert.
    if HK.Range then HK.Range.Update() end
    if HK.PassivePulse then HK.PassivePulse.Refresh() end
    if HK.ThreatWatch and HK.ThreatWatch.Tick then HK.ThreatWatch.Tick(true) end
    if HK.ShotTimer and HK.ShotTimer.Refresh then HK.ShotTimer.Refresh() end
    if HK.MendMark and HK.MendMark.Update then HK.MendMark.Update() end
  end
  UpdateLockButton()
end

function Positions.Reset()
  if not HK.db then return end
  -- Restore the position/size fields to defaults. MergeDefaults only fills keys
  -- that are nil, so a previously-saved offset would never be reset — that was
  -- the reason the feed button could get stuck somewhere odd. Force the default
  -- position fields here; leave food prefs / sound / other settings untouched.
  -- Every position-ish key is restored by NAME rather than from a hardcoded
  -- per-section list. The old code listed four sections explicitly, so each new
  -- movable frame (the shot timer and both threat frames) was silently left out
  -- of "reset positions" until someone remembered to add it. Driving this from
  -- the defaults table means a new draggable is covered the day it is added.
  --
  -- Only position/size fields are touched: food prefs, sounds and thresholds
  -- must survive a position reset.
  local defs = HK.defaults
  local POS_KEYS = {
    offsetX = true, offsetY = true, parent = true, size = true,
    pinX = true, pinY = true, moved = true,
    pctOffsetX = true, pctOffsetY = true, pctMoved = true,
    width = true, height = true,
  }
  for section, sdef in pairs(defs) do
    local s = HK.db[section]
    if type(s) == "table" and type(sdef) == "table" then
      for k, v in pairs(sdef) do
        if POS_KEYS[k] then s[k] = v end
      end
    end
  end
  -- Re-apply every position. pcall'd individually: one frame that refuses to
  -- move (a secure frame in combat, a restricted anchor) must not abort the
  -- reset for all the others. The modules themselves defer their own protected
  -- work to PLAYER_REGEN_ENABLED, so anything skipped here lands when combat
  -- ends rather than being lost.
  for name, d in pairs(HK.draggables) do
    if d.apply then
      local ok, err = pcall(d.apply)
      if not ok then HK.Dbg("reset: " .. tostring(name) .. " apply failed: " .. tostring(err)) end
    end
  end
  -- Every registered module, rather than a hardcoded list that goes stale each
  -- time one is added (this list had already missed ThreatWatch and ShotTimer
  -- once). Individually pcall'd for the same reason as the applies above.
  for name in pairs(HK.modules) do
    local m = HK[name]
    if m and m.RescanSettings then
      local ok, err = pcall(m.RescanSettings)
      if not ok then HK.Dbg("reset: " .. tostring(name) .. " rescan failed: " .. tostring(err)) end
    end
  end

  if InCombatLockdown and InCombatLockdown() then
    -- Be honest rather than silently half-applying: the feed button is secure
    -- and physically cannot be moved mid-fight.
    print("|cff39ff14HunterKit|r positions reset — the feed button will move when you leave combat.")
  else
    print("|cff39ff14HunterKit|r positions reset to defaults.")
  end
end
