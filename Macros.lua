--[[============================================================================
 HunterKit — Macros

 A small library of hunter macros, in their own window so the options panel
 does not get clogged up with them.

 WHY A SEPARATE WINDOW
 ---------------------
 These are reference material, not settings. You come here once, copy a macro
 into your macro frame, and leave. Putting five multi-line text boxes inline
 would have doubled the length of the options list for something you interact
 with rarely, so the options panel gets one button and the macros get their own
 frame.

 HOW COPYING WORKS
 -----------------
 An addon CANNOT write to the player's clipboard: there is no such API, and
 CreateMacro() on a protected/secure path is not something to do behind the
 player's back. What every addon does instead — and what we do here — is put the
 text in a read-only EditBox, select it all on click, and let Ctrl+C do the rest.
 The box is multi-line so macros with several lines survive the round trip
 exactly as written.
==============================================================================]]
local _, HK = ...

local Macros = {}
HK.Macros = Macros

local win, content, scrollArea
local rows = {}

-- ---------------------------------------------------------------------------
-- The library.
--
-- `body` is copied verbatim — do not reformat it, macro text is whitespace and
-- line-order sensitive. `note` explains what the macro is FOR and any caveat
-- worth knowing before you bind it.
-- ---------------------------------------------------------------------------
local LIBRARY = {
  {
    title = "Eagle Eye at the cursor",
    body = "/cast [@cursor] !Eagle Eye",
    note = "Scouts wherever your mouse is pointing instead of making you place "
        .. "the reticle by hand. The ! stops it toggling off if you press it twice.",
  },
  {
    title = "Clean Feign Death",
    body = "/cast !feign death\n/cleartarget\n/stopattack",
    note = "Feigns, then drops your target and stops attacking, so nothing you "
        .. "were doing pulls you straight back into combat. Clearing the target "
        .. "also avoids the auto-shot restart that gives away the feign.",
  },
  {
    title = "Trap drop under pressure",
    body = "#showtooltip\n/stopattack\n/cast Freezing Trap\n"
        .. "/cast [combat] Feign Death\n/petpassive [@pettarget, harm]",
    note = "Stops attacking, lays the trap, feigns if you are in combat so the "
        .. "mob comes off you and walks into it, and sets the pet passive so it "
        .. "does not drag the mob away. Swap Freezing Trap for Frost Trap here if "
        .. "you would rather slow a group than lock one target down.",
  },
  {
    title = "Mouseover attack + pet send",
    body = "#showtooltip 18\n/cast [@mouseover,harm,nodead][] !Auto Shot\n"
        .. "/petattack [@mouseover,harm,nodead][]",
    note = "Starts shooting whatever you are hovering and sends the pet to the "
        .. "same target, without changing your current target. Hover nothing and "
        .. "it falls back to your target. The 18 shows your ranged weapon's icon "
        .. "and ammo count on the button.",
  },
  {
    title = "Auto Shot the pet's target while you melee",
    body = "#showtooltip 18\n/cast [@pettarget,harm,nodead] !Auto Shot\n"
        .. "/startattack",
    note = "Built for the two-mob weave: your pet holds one mob at range while "
        .. "you stand toe to toe with another. Keep the melee mob targeted -- "
        .. "/startattack keeps swinging at it -- and this fires Auto Shot at "
        .. "whatever the pet is tanking, without ever changing your target. The "
        .. "18 puts your ranged weapon's icon and ammo count on the button. "
        .. "HunterKit's weave advice works in this setup whatever you have "
        .. "selected.",
  },
  {
    title = "One-button pet keeper",
    body = "#showtooltip\n/cast [@pet, dead] Revive Pet; [nopet] Call Pet; [pet] Mend Pet",
    note = "One key for the whole pet: revives it if it is dead, calls it if it "
        .. "is away, heals it if it is out and hurt.",
  },
}

-- ---------------------------------------------------------------------------
-- Widgets
-- ---------------------------------------------------------------------------
local ROW_GAP     = 14
local NOTE_W      = 396
local BOX_PAD     = 6

local function CountLines(s)
  local n = 1
  for _ in s:gmatch("\n") do n = n + 1 end
  return n
end

local function MakeRow(parent, y, macro)
  -- Title
  local title = parent:CreateFontString(nil, "OVERLAY")
  title:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y)
  title:SetFontObject(GameFontNormal)
  title:SetText(macro.title)
  title:SetTextColor(0.35, 1, 0.35)
  y = y - 18

  -- The macro text itself, in a selectable box.
  local lines = CountLines(macro.body)
  local boxH = lines * 13 + BOX_PAD * 2

  local bg = CreateFrame("Frame", nil, parent, "BackdropTemplate")
  bg:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y)
  bg:SetSize(NOTE_W + 8, boxH)
  bg:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
  })
  bg:SetBackdropColor(0, 0, 0, 0.6)
  bg:SetBackdropBorderColor(0.35, 0.45, 0.35, 0.9)

  local box = CreateFrame("EditBox", nil, bg)
  box:SetMultiLine(true)
  box:SetAutoFocus(false)
  box:SetFontObject(GameFontHighlightSmall)
  box:SetPoint("TOPLEFT", bg, "TOPLEFT", BOX_PAD, -BOX_PAD)
  box:SetPoint("BOTTOMRIGHT", bg, "BOTTOMRIGHT", -BOX_PAD, BOX_PAD)
  box:SetText(macro.body)
  -- Read-only in effect: any edit is undone, so the text you copy is always the
  -- text we shipped. Cheaper and more predictable than trying to block keys.
  box:SetScript("OnTextChanged", function(self, user)
    if user then self:SetText(macro.body) end
  end)
  -- Click selects everything, so Ctrl+C just works. There is no clipboard API
  -- in WoW; select-and-copy is the only route an addon has.
  box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
  box:SetScript("OnMouseUp", function(self) self:HighlightText() end)
  box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  y = y - boxH - 4

  -- A hint, once per row, so the copy gesture is never a mystery.
  local hint = parent:CreateFontString(nil, "OVERLAY")
  hint:SetPoint("TOPLEFT", parent, "TOPLEFT", 2, y)
  hint:SetFontObject(GameFontDisableSmall)
  hint:SetText("Click the box, then Ctrl+C to copy.")
  y = y - 13

  -- What it does.
  local note = parent:CreateFontString(nil, "OVERLAY")
  note:SetPoint("TOPLEFT", parent, "TOPLEFT", 2, y)
  note:SetWidth(NOTE_W)
  note:SetJustifyH("LEFT")
  note:SetFontObject(GameFontHighlightSmall)
  note:SetWordWrap(true)
  note:SetText(macro.note)
  note:SetTextColor(0.80, 0.80, 0.80)
  y = y - (note:GetStringHeight() or 24) - ROW_GAP

  rows[#rows + 1] = { title = title, box = box, note = note }
  return y
end

local function Build()
  if win then return end
  win = CreateFrame("Frame", "HunterKitMacros", UIParent, "BackdropTemplate")
  win:SetSize(444, 560)
  win:SetFrameStrata("DIALOG")
  win:SetPoint("CENTER", UIParent, "CENTER", 60, 0)
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

  local title = win:CreateFontString(nil, "OVERLAY")
  title:SetPoint("TOP", win, "TOP", 0, -16)
  title:SetFontObject(GameFontNormalLarge)
  title:SetText("HunterKit macros")
  title:SetTextColor(0.25, 1, 0.25)

  local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", win, "TOPRIGHT", -4, -4)
  close:SetScript("OnClick", function() Macros.Hide() end)

  if UISpecialFrames then
    tinsert(UISpecialFrames, "HunterKitMacros")   -- ESC closes it
  end

  scrollArea = CreateFrame("ScrollFrame", "HunterKitMacrosScroll", win)
  scrollArea:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -44)
  scrollArea:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -22, 14)

  content = CreateFrame("Frame", "HunterKitMacrosContent", scrollArea)
  content:SetWidth(404)
  content:SetHeight(1200)
  scrollArea:SetScrollChild(content)

  local y = 0
  for _, m in ipairs(LIBRARY) do
    y = MakeRow(content, y, m)
  end
  local used = math.abs(y) + 20
  content:SetHeight(used)

  -- Wheel scrolling, clamped so it cannot be thrown past the content.
  local maxScroll = math.max(0, used - (560 - 58))
  scrollArea:EnableMouseWheel(true)
  scrollArea:SetScript("OnMouseWheel", function(self, delta)
    local cur = self:GetVerticalScroll() or 0
    local nxt = cur - (delta * 40)
    if nxt < 0 then nxt = 0 elseif nxt > maxScroll then nxt = maxScroll end
    self:SetVerticalScroll(nxt)
  end)

  win:Hide()
end

function Macros.Show()
  Build()
  if win then win:Show() end
end

function Macros.Hide()
  if win then win:Hide() end
end

function Macros.Toggle()
  Build()
  if not win then return end
  if win:IsShown() then win:Hide() else win:Show() end
end

function Macros.IsShown()
  return win ~= nil and win:IsShown() == true
end

-- Test seams.
function Macros.Count() return #LIBRARY end
function Macros.Entry(i) return LIBRARY[i] end
function Macros.Rows() return rows end

HK.RegisterModule("Macros", {})
