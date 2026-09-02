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
  win:SetSize(474, 604)
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
  scrollArea:SetPoint("TOPLEFT", win, "TOPLEFT", 14, -34)
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
local function MakeSlider(parent, y, labelText, min, max, step, get, set, tooltip)
  sliderCount = sliderCount + 1
  local name = "HunterKitOptSlider" .. sliderCount
  local w = (parent:GetWidth() or 436)

  local lbl = parent:CreateFontString(nil, "OVERLAY")
  lbl:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y)
  lbl:SetFontObject(GameFontNormal)
  lbl:SetJustifyH("LEFT")
  lbl:SetWordWrap(false)
  lbl:SetWidth(math.max(120, w - 76))
  lbl:SetText(labelText)
  lbl:SetTextColor(0.9, 0.9, 0.9)

  -- Always visible, right-aligned, in its own column: it can never collide with
  -- the label or with the row below.
  local val = parent:CreateFontString(nil, "OVERLAY")
  val:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -4, y)
  val:SetFontObject(GameFontHighlight)
  val:SetJustifyH("RIGHT")
  val:SetWordWrap(false)
  val:SetWidth(64)
  val:SetTextColor(0.35, 1, 0.35)
  val:SetText(tostring(get()))

  local sl = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
  sl:SetWidth(math.max(120, w - 16))
  sl:SetHeight(SLIDER_BAR_H)
  sl:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, y - SLIDER_LABEL_H)
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
  sl:SetValue(get())
  sl:SetScript("OnValueChanged", function(self)
    val:SetText(string.format("%d", self:GetValue()))
    set(self:GetValue())
  end)
  val:SetText(string.format("%d", sl:GetValue()))   -- shown from the first frame
  AttachTooltip(sl, labelText, tooltip)
  return sl
end

-- ---------------------------------------------------------------------------
-- Build the settings
-- ---------------------------------------------------------------------------
-- Each feature gets a rule above its title plus extra air below, so the modules
-- read as separate blocks instead of one long list.
local SECTION_RULE_GAP = 7
local function AddSection(content, y, name)
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

function BuildWindow()
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
    "Hide the button once the pet is content.")
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
  MakeDropdown(content, y, "IN RANGE mark", { "crosshair", "rings", "x" },
    function() return db.range.markOK or "crosshair" end,
    function(v) db.range.markOK = v; RefreshRange() end,
    "Shape while Auto Shot is in range (green).")
  y = y - ROW
  MakeDropdown(content, y, "TOO CLOSE mark", { "x", "crosshair", "rings" },
    function() return db.range.markDead or "x" end,
    function(v) db.range.markDead = v; RefreshRange() end,
    "Shape when the target is too close (red).")
  y = y - ROW
  MakeDropdown(content, y, "OUT OF RANGE mark", { "rings", "crosshair", "x" },
    function() return db.range.markFar or "rings" end,
    function(v) db.range.markFar = v; RefreshRange() end,
    "Shape when the target is out of range (grey).")
  y = y - ROW
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
  MakeCheckbox(content, y, "Force pet name plate", function() return db.mend.forcePlate end,
    function(v) db.mend.forcePlate = v; RefreshMend() end,
    "No pet-only setting exists: the finest the client offers is friendly + minions, which also shows other players' pets. Ticking it turns the least it can on and restores your values on untick or logout. /htk mend reports what your client allows.")
  y = y - CHK
  MakeCheckbox(content, y, "Nameplate style bar", function() return db.mend.plateStyle end,
    function(v) db.mend.plateStyle = v; RefreshMend() end,
    "Pet name + HP bar under the icon, only when no real plate is there.")
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

  -- Pulse
  AddSection(content, y, "Passive Alert")
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
    RefreshFeed(); RefreshRange(); RefreshSound(); RefreshPulse(); RefreshMend()
  end
end
function RefreshFeed() if HK.FeedPet and HK.FeedPet.RescanSettings then HK.FeedPet.RescanSettings() end end
function RefreshRange() if HK.Range and HK.Range.RescanSettings then HK.Range.RescanSettings() end end
function RefreshPulse() if HK.PassivePulse and HK.PassivePulse.RescanSettings then HK.PassivePulse.RescanSettings() end end
function RefreshMend() if HK.MendMark and HK.MendMark.RescanSettings then HK.MendMark.RescanSettings() end end
function RefreshSound() if HK.Sounds and HK.Sounds.RescanSettings then HK.Sounds.RescanSettings() end end

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
    -- Skip frames that aren't the player's to move right now (the mend marker
    -- while it's floating over the pet's head). Touching their drag state is both
    -- meaningless and, on restricted anchors, an error.
    if f and not HK.DraggableActive(dd) then
      HK.Dbg("SetLock skip (not draggable now)", key)
      f = nil
    end
    if f then
      local clickable = dd.opts.clickable
      local mouse = clickable or unlock
      f:SetMovable(unlock)
      f:EnableMouse(mouse)
      -- pcall-guarded: a frame anchored to a name plate refuses to be clamped
      -- ("Can't clamp restricted regions") and would taint the whole loop.
      HK.SafeClamp(f, true)
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
        f:SetScript("OnDragStop", function(self)
          draggingFrame = nil
          -- Re-bind the feature's own persistent OnUpdate loop (e.g. the passive
          -- pulse animation) so a drag doesn't leave the frame's script blanked.
          if dd.opts.onUpdate then
            dd.opts.onUpdate()
          else
            self:SetScript("OnUpdate", nil)
          end
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
      end
    end
  end
  if unlock == false and HK.FeedPet and HK.FeedPet.RefreshMacro then
    HK.FeedPet:RefreshMacro()   -- colon: RefreshMacro is a method, needs `self`
    -- After locking, restore proper per-feature visibility (edit mode forced
    -- everything shown).
    if HK.Range then HK.Range.Update() end
    if HK.PassivePulse then HK.PassivePulse.Refresh() end
  end
  UpdateLockButton()
end

function Positions.Reset()
  if not HK.db then return end
  -- Restore the position/size fields to defaults. MergeDefaults only fills keys
  -- that are nil, so a previously-saved offset would never be reset — that was
  -- the reason the feed button could get stuck somewhere odd. Force the default
  -- position fields here; leave food prefs / sound / other settings untouched.
  local defs = HK.defaults
  local function force(section, keys)
    local s = HK.db[section]
    if s and defs[section] then
      for _, k in ipairs(keys) do s[k] = defs[section][k] end
    end
  end
  force("feed",  { "offsetX", "offsetY", "parent", "size" })
  force("range", { "offsetX", "offsetY", "parent", "size" })
  force("pulse", { "offsetX", "offsetY", "size" })
  force("mend",  { "offsetX", "offsetY", "size", "pinX", "pinY" })
  -- Clear the "user dragged this" flag so each frame returns to its default
  -- anchor-frame position (rather than staying pinned to the absolute spot).
  for _, sec in ipairs({ "feed", "range", "pulse", "mend" }) do
    if HK.db[sec] then HK.db[sec].moved = false end
  end
  -- refresh positions
  for _, d in pairs(HK.draggables) do
    if d.apply then d.apply() end
  end
  if HK.FeedPet then HK.FeedPet.RescanSettings() end
  if HK.Range then HK.Range.RescanSettings() end
  if HK.PassivePulse then HK.PassivePulse.RescanSettings() end
  if HK.MendMark then HK.MendMark.RescanSettings() end
  print("|cff39ff14HunterKit|r positions reset to defaults.")
end
