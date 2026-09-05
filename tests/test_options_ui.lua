--[[==============================================================================
 HunterKit — tests: the Options window itself
 Loads the REAL Core.lua, MendMark.lua and Options.lua against tests/wow_stub.lua
 and builds the settings window, then asserts the layout the user sees:

   * the window is roomy enough for its content
   * every section is visibly separated by a rule
   * each slider shows its number from the first frame (not only once dragged)
   * the numbers sit in their own column and never overlap the labels
   * nothing is clipped off the left edge (the old "…ow" for "Low")
   * tooltips wrap and stay concise

 These used to be untestable: Options.lua only got a syntax check, so MakeWindow
 never ran here. It does now, which is how the layout bugs above were found.

 Run with tests/run_tests.py.
==============================================================================]]

local passes, failures = 0, {}

local say = HKTest.say

local function check(name, cond, detail)
  if cond then
    passes = passes + 1
    say("  ok   " .. name)
  else
    failures[#failures + 1] = name .. (detail and (" — " .. tostring(detail)) or "")
    say("  FAIL " .. name .. (detail and (" — " .. tostring(detail)) or ""))
  end
end

-- ---------------------------------------------------------------------------
-- Build the window
-- ---------------------------------------------------------------------------
HKTest.prints = {}
-- Load EVERY module, in .toc order, exactly as the client does: the settings
-- window offers controls for all of them (the shape dropdowns read their style
-- lists from Range), so a partial load would not be the real thing.
local HK = HKTest.LoadAddon(unpack(HKTest.addonFiles))
HK:Load()
local loadLog = table.concat(HKTest.prints, "\n")

-- HK:Load() pcall-guards each module's Init, so a missing client method inside
-- MakeWindow used to vanish into that pcall. Fail loudly if it ever does again.
check("Options module initialises without error",
  loadLog:find("load error") == nil, loadLog)

local win = _G["HunterKitOptions"]
local content = _G["HunterKitOptionsContent"]
local scrollArea = _G["HunterKitOptionsScroll"]

check("options window exists", win ~= nil)
check("options content exists", content ~= nil)
check("scroll area exists", scrollArea ~= nil)
if not (win and content and scrollArea) then
  
say(string.format("\n%d passed, %d failed", passes, #failures))
  for _, f in ipairs(failures) do say("  - " .. f) end
  error(#failures .. " test(s) failed")
end

-- A `local` that was never declared compiles to a GLOBAL lookup (nil at
-- runtime) -- that exact bug shipped twice, as "attempt to call a nil value".
-- Every global the addon creates on purpose is listed here, so a new accidental
-- one fails the suite instead of failing in the client.
local KNOWN_GLOBALS = {
  HK = true, HunterKitDB = true, SLASH_HUNTERKIT1 = true,
  BuildAlert = true, BuildButton = true, BuildFrame = true,
  BuildMendPlate = true, BuildMinimapButton = true, BuildWindow = true,
  MakeDropdown = true, RangedWeaponInfo = true, RefreshFeed = true,
  RefreshMend = true, RefreshModules = true, RefreshPulse = true,
  RefreshRange = true, RefreshSound = true, RefreshAmmo = true,
  RefreshAmmoBuy = true, RefreshThreat = true, RefreshShotTimer = true,
}
local stray = {}
for _, n in ipairs(HKTest.StrayGlobals()) do
  local v = _G[n]
  local isFrame = type(v) == "table" and v.kind ~= nil   -- named CreateFrame
  if not isFrame and not KNOWN_GLOBALS[n] then stray[#stray + 1] = n end
end
check("loading the addon creates no stray globals", #stray == 0, table.concat(stray, ","))

-- ---------------------------------------------------------------------------
-- 1) The window has to fit its content
-- ---------------------------------------------------------------------------
check("window is wide enough for its content",
  win.width >= content.width + 30, win.width .. " vs " .. content.width)
check("window is tall enough to be usable",
  win.height >= 560, tostring(win.height))
check("window grew past the cramped 392x520",
  win.width >= 460 and win.height > 520,
  win.width .. "x" .. win.height)
check("content leaves room for the scrollbar",
  content.width <= win.width - 36, content.width .. " vs " .. win.width)
check("scroll child is the content frame", scrollArea.scrollChild == content)
check("content is tall enough to scroll", content.height > win.height,
  content.height .. " vs " .. win.height)

-- ---------------------------------------------------------------------------
-- 2) Sections are visibly separate
-- ---------------------------------------------------------------------------
local rules = {}
for _, t in ipairs(content.textures) do
  if t.height == 1 then rules[#rules + 1] = t end
end
-- Master, Feed Pet, Sniper Mark, Pet Mend Marker, Ammo, Ammo auto-buy,
-- Pet aggro warning, Auto Shot timer, Gun Sound, Passive pet alert, Positions,
-- Reset.
check("every section has a divider rule", #rules == 12, tostring(#rules))
local spanning = 0
for _, r in ipairs(rules) do
  local a, b = r.points[1], r.points[2]
  if a and b and a[1] == "TOPLEFT" and a[4] == 0 and b[1] == "TOPRIGHT" and b[4] == 0 then
    spanning = spanning + 1
  end
end
check("divider rules span the full content width", spanning == #rules,
  spanning .. "/" .. #rules)

-- ---------------------------------------------------------------------------
-- 3) Slider rows: value always visible, own column, nothing clipped
-- ---------------------------------------------------------------------------
local sliders = {}
for _, f in ipairs(HKTest.frames) do
  if f.name and f.name:match("^HunterKitOptSlider%d+$") then sliders[#sliders + 1] = f end
end
table.sort(sliders, function(a, b) return a.name < b.name end)
check("the settings window built its sliders", #sliders >= 6, tostring(#sliders))

local LABEL_ROW = 15   -- MakeSlider's SLIDER_LABEL_H

-- Compact sliders (the per-mark brightness ones) sit small on the RIGHT of their
-- label; the full-row rules (value centred over the bar, bar inset from the left
-- edge) apply only to regular sliders.
local function isCompact(sl)
  local p = sl.points[1]
  return p ~= nil and p[1] == "TOPRIGHT"
end

-- The value fontstring belonging to a slider: visible, centred, showing the
-- slider's current number, on the row directly above the bar.
local function ValueTextFor(sl)
  local row = sl.points[1] and sl.points[1][5]
  local want = string.format("%d", sl:GetValue())
  for _, fs in ipairs(content.fontstrings) do
    if fs:IsShown() and fs.justifyH == "CENTER" and fs:GetText() == want then
      local py = fs.points[1] and fs.points[1][5]
      if row and py and math.abs((py - row) - LABEL_ROW) < 2 then return fs end
    end
  end
  return nil
end

local noValue, templateTextVisible, lowVisible, highVisible, overlapping = 0, 0, 0, 0, 0
local valueWidths = {}
for _, sl in ipairs(sliders) do
  if isCompact(sl) then
    -- A slider may format its number (e.g. the weave trip stores tenths but
    -- displays "2.5s"), so match the DIGITS rather than a bare %d -- the point
    -- of this check is that the current value is legible before you touch it,
    -- not that it is rendered in any particular way.
    local want = string.format("%d", sl:GetValue())
    local raw  = tostring(sl:GetValue())
    local found = false
    for _, fs in ipairs(content.fontstrings) do
      local txt = fs:IsShown() and fs:GetText() or nil
      if txt and txt ~= "" and (txt == want or txt == raw
        or txt:gsub("[^%d]", "") == want) then found = true end
    end
    if not found then noValue = noValue + 1 end
  elseif not ValueTextFor(sl) then noValue = noValue + 1 end
  if _G[sl.name .. "Text"] and _G[sl.name .. "Text"]:IsShown() then
    templateTextVisible = templateTextVisible + 1
  end
  if _G[sl.name .. "Low"] and _G[sl.name .. "Low"]:IsShown() then lowVisible = lowVisible + 1 end
  if _G[sl.name .. "High"] and _G[sl.name .. "High"]:IsShown() then highVisible = highVisible + 1 end
end
check("every slider shows its value before any interaction", noValue == 0,
  noValue .. " sliders had no visible value")

-- the number is centred on the row, over the bar
local offCentre = 0
for _, sl in ipairs(sliders) do
  if isCompact(sl) then -- compact values sit right of the bar, not centred
  else
    local fs = ValueTextFor(sl)
    local p = fs and fs.points[1]
    if not p or p[1] ~= "TOP" or (p[4] or 0) ~= 0 then offCentre = offCentre + 1 end
  end
end
check("slider values are centred", offCentre == 0, tostring(offCentre))
check("the template's empty value text is hidden", templateTextVisible == 0,
  tostring(templateTextVisible))
check("the clipped 'Low' labels are hidden", lowVisible == 0, tostring(lowVisible))
check("the clipped 'High' labels are hidden", highVisible == 0, tostring(highVisible))

-- the label may only use the left half minus the value's centred column
for _, sl in ipairs(sliders) do
  local row = sl.points[1] and sl.points[1][5]
  local lbl, val
  for _, fs in ipairs(content.fontstrings) do
    if fs:IsShown() and fs.points[1] and fs.points[1][5] == row then
      if fs.justifyH == "LEFT" then lbl = fs elseif fs.justifyH == "CENTER" then val = fs end
    end
  end
  if isCompact(sl) then -- label left + small bar right: no centred column to guard
  elseif lbl and val and (lbl.width > (content.width - val.width) / 2 - 8) then
    overlapping = overlapping + 1
    valueWidths[#valueWidths + 1] = sl.name .. "(" .. lbl.width .. ">" ..
      math.floor((content.width - val.width) / 2 - 8) .. ")"
  end
end
check("slider labels stop before the centred value", overlapping == 0,
  table.concat(valueWidths, ","))

-- ...which is only safe while the labels themselves stay short.
local longLabel = {}
for _, sl in ipairs(sliders) do
  local row = sl.points[1] and sl.points[1][5]
  for _, fs in ipairs(content.fontstrings) do
    if fs:IsShown() and fs.justifyH == "LEFT" and fs.points[1] and fs.points[1][5] == row then
      local t = tostring(fs:GetText() or "")
      if #t > 24 then longLabel[#longLabel + 1] = t end
    end
  end
end
check("slider labels fit their column", #longLabel == 0, table.concat(longLabel, ","))

-- The scroll area clips its children, so anything anchored left of x=0 in the
-- content loses its first characters -- that is the "…ow" the user saw.
local clipped = {}
for _, fs in ipairs(content.fontstrings) do
  local p = fs.points[1]
  if fs:IsShown() and p and p[1]:find("LEFT") and (p[4] or 0) < 0 then
    clipped[#clipped + 1] = tostring(fs:GetText())
  end
end
check("no content text is anchored off the left edge", #clipped == 0, table.concat(clipped, ","))

-- The bar has to sit inside the content too: at x=0 the template's corner labels
-- (centred on the bar's ends) have nowhere to be drawn.
local tightBar = 0
for _, sl in ipairs(sliders) do
  if isCompact(sl) then -- anchored from the right by design
  else
    local p = sl.points[1]
    if not p or (p[4] or 0) < 4 then tightBar = tightBar + 1 end
  end
end
check("slider bars are inset from the clipping edge", tightBar == 0, tostring(tightBar))

-- the number on screen is the number in the db
local sawMendSize = false
for _, sl in ipairs(sliders) do
  local fs = ValueTextFor(sl)
  if fs and fs:GetText() == string.format("%d", HK.db.mend.size) then sawMendSize = true end
end
check("a slider reports the db's mend icon size", sawMendSize, tostring(HK.db.mend.size))

-- dragging still updates the row it belongs to
local first = sliders[1]
local before = first:GetValue()
first:SetValue(before + 1)
local moved = ValueTextFor(first)
check("dragging a slider updates its value text",
  moved ~= nil and moved:GetText() == string.format("%d", before + 1),
  moved and tostring(moved:GetText()) or "nil")
first:SetValue(before)

-- ---------------------------------------------------------------------------
-- 4) Tooltips: concise and wrapped
-- ---------------------------------------------------------------------------
local function TooltipBody(widget)
  GameTooltip.lines = {}
  local fn = widget:GetScript("OnEnter")
  if not fn then return nil, nil end
  fn(widget)
  local title, body, wrap
  for _, l in ipairs(GameTooltip.lines) do
    if not title then title = l.text elseif not body then body, wrap = l.text, l.wrap end
  end
  local leave = widget:GetScript("OnLeave")
  if leave then leave(widget) end
  return body, wrap
end

local noWrap, tooLong, noTip = 0, 0, 0
local offenders = {}
for _, sl in ipairs(sliders) do
  local body, wrap = TooltipBody(sl)
  if not body then noTip = noTip + 1
  elseif wrap ~= true then
    noWrap = noWrap + 1
    offenders[#offenders + 1] = sl.name
  elseif #body > 220 then
    tooLong = tooLong + 1
    offenders[#offenders + 1] = sl.name .. "(" .. #body .. ")"
  end
end
check("every slider has a tooltip", noTip == 0, tostring(noTip))
check("slider tooltips wrap", noWrap == 0, table.concat(offenders, ","))
check("slider tooltips stay concise", tooLong == 0, table.concat(offenders, ","))

-- checkboxes and the anchor dropdown wrap too
local wrappedCtl, totalCtl = 0, 0
local controls = {}
for _, f in ipairs(HKTest.frames) do
  if f.parent == content and f:GetScript("OnEnter") then controls[#controls + 1] = f end
end
offenders = {}
for _, c in ipairs(controls) do
  local body, wrap = TooltipBody(c)
  if body then
    totalCtl = totalCtl + 1
    if wrap == true then wrappedCtl = wrappedCtl + 1
    else offenders[#offenders + 1] = tostring(c.name or c.kind) end
  end
end
check("the window has tooltipped controls", totalCtl > 0, tostring(totalCtl))
check("every control tooltip wraps", wrappedCtl == totalCtl, table.concat(offenders, ","))

local body = TooltipBody(sliders[#sliders])
check("tooltip text is a readable length", body ~= nil and #body >= 10,
  tostring(body and #body))

-- ---------------------------------------------------------------------------
-- 5) /htk unlock — you get the MOVABLE fallback, and locking cleans up after it
-- ---------------------------------------------------------------------------
local marker = _G["HunterKitMendMarker"]
local widget = _G["HunterKitMendPlate"]
check("the mend marker was built", marker ~= nil)

-- The client refuses drag/clamp state on a frame anchored to a name plate, so
-- model exactly that: the marker is restricted while it hangs off the plate.
local clampCalls = {}
marker.SetClampedToScreen = function(self, on)
  clampCalls[#clampCalls + 1] = { on = on, mode = HK.MendMark.AnchorMode() }
  if HK.MendMark.AnchorMode() == "plate" then
    error("SetClampedToScreen(): Can't clamp restricted regions")
  end
end

-- With frames locked and a real pet plate present, the marker belongs over the
-- pet's head — and that one is not the player's to move.
HKTest.state.plate = CreateFrame("Frame", "OptTestPetPlate", UIParent)
HK.MendMark.Update()
check("locked + plate: anchored over the head",
  HK.MendMark.AnchorMode() == "plate", HK.MendMark.AnchorMode())
check("locked + plate: not the player's to move",
  HK.DraggableActive(HK.draggables["mend"]) == false)

local okUnlock, errUnlock = pcall(HK.Positions.ToggleLock)
HK.MendMark.Update()
check("/htk unlock runs without error", okUnlock, errUnlock)
check("unlocked: shows the movable fallback instead of the head marker",
  HK.MendMark.AnchorMode() == "petframe", HK.MendMark.AnchorMode())
check("unlocked: the marker is draggable",
  HK.DraggableActive(HK.draggables["mend"]) == true)
check("unlocked: the frame was made movable", marker.movable == true,
  tostring(marker.movable))
check("unlocked: drag handlers are bound", marker.scripts["OnDragStart"] ~= nil)
check("unlocked: the fallback widget is what you see", widget:IsShown() == true)
check("unlocked: the head marker is not left on the plate",
  marker.points[1] and marker.points[1][2] ~= HKTest.state.plate,
  tostring(marker.points[1] and marker.points[1][2]))

local okLock, errLock = pcall(HK.Positions.ToggleLock)
HK.MendMark.Update()
check("/htk lock runs without error", okLock, errLock)
check("relocked: back over the pet's head",
  HK.MendMark.AnchorMode() == "plate", HK.MendMark.AnchorMode())
check("relocked: no longer the player's to move",
  HK.DraggableActive(HK.draggables["mend"]) == false)
check("relocked: drag handlers removed", marker.scripts["OnDragStart"] == nil)
check("relocked: no longer movable", marker.movable == false, tostring(marker.movable))
check("relocked: edit-mode fade removed", marker.alpha == 1, tostring(marker.alpha))
check("relocked: marker still on screen", marker:IsShown() == true)

local badClamp = 0
for _, c in ipairs(clampCalls) do
  if c.on == true and c.mode == "plate" then badClamp = badClamp + 1 end
end
check("never clamped while anchored to the name plate", badClamp == 0, tostring(badClamp))

-- The head marker can only exist while the pet is out (a plate needs a live
-- pet), so edit mode must not go looking for one.
HKTest.state.plate = nil
HKTest.state.pet = false
local okNoPet, errNoPet = pcall(function()
  HK.Positions.ToggleLock()
  HK.MendMark.Update()
end)
check("edit mode with no pet: no error", okNoPet, errNoPet)
check("edit mode with no pet: on the UI fallback",
  HK.MendMark.AnchorMode() == "petframe", HK.MendMark.AnchorMode())
check("edit mode with no pet: shown so it can be placed", marker:IsShown() == true)
pcall(HK.Positions.ToggleLock)      -- lock again
HK.MendMark.Update()
check("locked with no pet: hidden", HK.MendMark.IsShown() == false)
HKTest.state.pet = true
HK.MendMark.Update()
check("pet back and locked: on screen again", HK.MendMark.IsShown() == true)

-- ---------------------------------------------------------------------------
-- The feed-icon swap option must actually be in the built window (a user
-- reported not finding it -- an option that exists in code but not on screen
-- is the same as no option at all).
local feedIconOpt = false
for _, f in ipairs(HKTest.frames) do
  for _, fs in ipairs(f.fontstrings or {}) do
    if fs.text == "Use default Feed Pet icon" then feedIconOpt = true end
  end
end
check("feed icon swap option is present in the UI", feedIconOpt)

-- ---------------------------------------------------------------------------
-- 5b) RELEASING THE MOUSE MUST RELEASE THE FRAME
--
-- Regression: OnDragStart pins the frame to the cursor with an OnUpdate loop.
-- OnDragStop used to call the feature's own opts.onUpdate() *instead of*
-- clearing that loop, assuming the callback always installs a script. Two do
-- not (ShotTimer re-binds only while animating, the threat readout only while
-- pulsing), so those frames stayed glued to the cursor after release.
--
-- Driven through the real drag scripts for EVERY registered draggable, so a
-- future frame with a conditional onUpdate cannot regress this either.
-- ---------------------------------------------------------------------------
HK.db.shottimer.enabled = true
if HK.ShotTimer then HK.ShotTimer.RescanSettings() end
HK.db.threat.showPct = true
if HK.ThreatWatch then HK.ThreatWatch.RescanSettings() end

-- Unlock everything (the mend marker aside, which has its own anchor rules).
if HK.Positions.IsLocked and HK.Positions.IsLocked() == false then
  HK.Positions.ToggleLock()
end
pcall(HK.Positions.ToggleLock)      -- -> unlocked

-- Read the frame's current anchor offset. SetPoint APPENDS and ClearAllPoints
-- empties, so after a clear+set the newest point is points[1] -- comparing
-- "points[1]" objects before/after is meaningless. Compare the NUMBERS.
local function anchorOf(f)
  local p = f.points and f.points[#f.points]
  if not p then return "none" end
  return string.format("%s@%.1f,%.1f", tostring(p[1]),
    tonumber(p[4]) or 0, tonumber(p[5]) or 0)
end

local dragged, glued = 0, {}
for name, d in pairs(HK.draggables) do
  local f = d.frame
  if f and f.scripts and f.scripts["OnDragStart"] and HK.DraggableActive(d) then
    dragged = dragged + 1
    HKTest.cursorX, HKTest.cursorY = 400, 400
    f.scripts["OnDragStart"](f)
    check("drag start pins " .. name .. " to the cursor",
      f.scripts["OnUpdate"] ~= nil)
    HKTest.cursorX, HKTest.cursorY = 600, 500
    f.scripts["OnUpdate"](f)
    f.scripts["OnDragStop"](f)

    -- Released. Move the cursor a long way and run whatever loop is still
    -- attached: a feature animation is fine, one that MOVES the frame is the
    -- bug. Compare actual anchor coordinates.
    local before = anchorOf(f)
    HKTest.cursorX, HKTest.cursorY = 1200, 900
    if f.scripts["OnUpdate"] then pcall(f.scripts["OnUpdate"], f, 0.1) end
    local after = anchorOf(f)
    if before ~= after then glued[#glued + 1] = name .. " " .. before .. "->" .. after end
    check("releasing the button unglues " .. name .. " from the cursor",
      before == after, before .. " -> " .. after)
  end
end
check("the drag release test actually exercised some frames", dragged >= 2,
  "dragged " .. tostring(dragged))
check("no frame follows the cursor after release",
  #glued == 0, table.concat(glued, "; "))

pcall(HK.Positions.ToggleLock)      -- back to locked

-- ---------------------------------------------------------------------------
-- 5c) RESET POSITIONS MUST RESET *EVERY* MOVABLE FRAME
--
-- Regression: Positions.Reset() forced defaults for a hardcoded list of four
-- sections, so the shot timer and both threat frames kept their dragged
-- position forever. Now driven from the defaults table.
-- ---------------------------------------------------------------------------
local POS = { "offsetX", "offsetY", "moved", "pinX", "pinY",
              "pctOffsetX", "pctOffsetY", "pctMoved" }

-- Shove every position field of every section to a junk value.
local dirty = {}
for section, sdef in pairs(HK.defaults) do
  if type(sdef) == "table" and type(HK.db[section]) == "table" then
    for _, k in ipairs(POS) do
      if sdef[k] ~= nil then
        HK.db[section][k] = (type(sdef[k]) == "boolean") and true or 999
        dirty[#dirty + 1] = section .. "." .. k
      end
    end
  end
end
check("there are dirty positions to reset", #dirty > 0)

-- Something that must NOT be reset by a *position* reset.
HK.db.threat.threshold = 55
HK.db.shottimer.travel = 3.7

HK.Positions.Reset()

local stillDirty = {}
for section, sdef in pairs(HK.defaults) do
  if type(sdef) == "table" and type(HK.db[section]) == "table" then
    for _, k in ipairs(POS) do
      if sdef[k] ~= nil and HK.db[section][k] ~= sdef[k] then
        stillDirty[#stillDirty + 1] = section .. "." .. k ..
          "=" .. tostring(HK.db[section][k])
      end
    end
  end
end
check("reset restores the position of every movable frame",
  #stillDirty == 0, table.concat(stillDirty, " "))

-- Named explicitly: these are the three that were missed before.
check("reset covers the shot timer", HK.db.shottimer.offsetX == HK.defaults.shottimer.offsetX
  and HK.db.shottimer.offsetY == HK.defaults.shottimer.offsetY
  and HK.db.shottimer.moved == false,
  tostring(HK.db.shottimer.offsetX) .. "," .. tostring(HK.db.shottimer.offsetY))
check("reset covers the threat warning", HK.db.threat.offsetX == HK.defaults.threat.offsetX
  and HK.db.threat.moved == false)
check("reset covers the threat percentage",
  HK.db.threat.pctOffsetX == HK.defaults.threat.pctOffsetX
  and HK.db.threat.pctMoved == false,
  tostring(HK.db.threat.pctOffsetX))

check("a position reset leaves other settings alone",
  HK.db.threat.threshold == 55 and HK.db.shottimer.travel == 3.7,
  tostring(HK.db.threat.threshold) .. " " .. tostring(HK.db.shottimer.travel))


-- ---------------------------------------------------------------------------
-- 5d) LABELS MUST NOT BE CLIPPED MID-WORD
--
-- Regression: compact slider labels were pinned to a hardcoded 200px with
-- SetWordWrap(false), so "Weave round trip (tenths of a sec)" was cut to
-- "...of a". The width is now derived from the space actually left of the bar.
-- Approximated at ~5.6px per character (GameFontNormal, 12pt) -- the stub has
-- no font metrics, so this catches gross overflow rather than exact pixels.
-- ---------------------------------------------------------------------------
local CHAR_W = 5.6
local clipped = {}
for _, fs in ipairs(content.fontstrings) do
  local txt = fs:GetText()
  -- width 0/nil means "auto-size to the text" -- only a font string with an
  -- explicit width can clip.
  if txt and fs.width and fs.width > 0 and fs.wordWrap == false then
    local plain = txt:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    if #plain * CHAR_W > fs.width + 1 then
      clipped[#clipped + 1] = string.format("%q needs ~%.0f has %d",
        plain, #plain * CHAR_W, fs.width)
    end
  end
end
check("no non-wrapping label is too narrow for its text",
  #clipped == 0, table.concat(clipped, "; "))

-- The weave setting reads in seconds, not raw tenths: the stored value is a
-- duration and the player should not have to convert it.
local weaveLabel = false
for _, fs in ipairs(content.fontstrings) do
  local t = fs:GetText()
  if t == "Weave round trip (seconds)" then weaveLabel = true end
end
check("the weave round trip is labelled in seconds", weaveLabel)

-- The shot-bar legend is present and names every colour the bar uses.
local legendBits = { "free time", "lockout", "melee swing", "WEAVE" }
local missing = {}
for _, want in ipairs(legendBits) do
  local found = false
  for _, fs in ipairs(content.fontstrings) do
    local t = fs:GetText()
    if t and t:find(want, 1, true) then found = true end
  end
  if not found then missing[#missing + 1] = want end
end
check("the options explain what each part of the bar means",
  #missing == 0, table.concat(missing, ","))

say(string.format("\n%d passed, %d failed", passes, #failures))
if #failures > 0 then
  for _, f in ipairs(failures) do say("  - " .. f) end
  error(#failures .. " test(s) failed")
end
