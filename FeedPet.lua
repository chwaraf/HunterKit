--[[==============================================================================
 HunterKit — Feed Pet (F1)
 A secure one-click Feed Pet button beside the pet happiness icon. It always
 uses the *best* food in your bags (max happiness tier, then smallest open
 stack), respects pin/exclude lists, and never feeds anything on a timer.
 Out-of-combat only (Feed Pet is OoC-only in Classic).
==============================================================================]]
local _, HK = ...

local FeedPet = {}
HK.FeedPet = FeedPet

local db
local button, iconTex, countText, border, timerText, feeder
local pending = false           -- attribute refresh deferred (combat)
local positionPending = false   -- a move was blocked by combat; replay on regen
local bagsDirty = true          -- food rescan needed (CPU: scan only on real changes)
local initialised = false
-- forward declarations (referenced before their bodies are defined in this chunk)
local ApplyVisibility, UpdateState, RefreshEverything, OnBagUpdate
local bestCache = nil
local diets = {}
local dietsReady = false

local HAPPINESS_COLOR = { [3] = {0.2,1,0.2}, [2] = {1,0.8,0}, [1] = {1,0.2,0.2} }

-- The Feed Pet Effect buff: spell 1539, 20 seconds, 10 bites, and it sits on
-- the PET, not on the player. It is also cancelled outright if the pet deals or
-- takes any damage, which is why this reads the buff rather than counting down
-- a timer of its own -- a timer would keep ticking over a feed that was already
-- wasted.
local FEED_BUFF_ID  = 1539
local FEED_DURATION = 20
local FEED_TICKS    = 10
-- Happiness per bite, by the tier TierFor already computes. The documented
-- split: within 15 levels of the pet 35, at 16-25 levels 17, beyond that 8.
local HAPPINESS_PER_TIER = { [3] = 35, [2] = 17, [1] = 8 }
local QUESTION_ICON = 134400
-- Feed Pet's real icon file (spell 6991) is ability_hunter_beasttraining --
-- NOT "Ability_Hunter_FeedPet", which does not exist: that path rendered
-- NOTHING, leaving the button's semi-transparent background plate with just
-- the count on it. Resolved from the spell itself below; this is only the
-- last-resort constant.
local FEED_PET_ICON = "Interface\\Icons\\ability_hunter_beasttraining"
local DIET_KEYWORDS = { "meat", "fish", "fruit", "fungus", "bread", "cheese" }

local scanTip

-- The "Feed Pet" spell id (6991) resolves to the localized spell name on every
-- client. Secure spell buttons need the localized *name* as the `spell`
-- attribute; a hardcoded "Feed Pet" string breaks on non-English clients.
-- Prefer C_Spell.GetSpellInfo (the current-client form, as the reference
-- Feed-O-Matic uses) and fall back to GetSpellInfo / the bare string.
local FEED_PET_SPELL_ID = 6991
local feedPetSpellName
local function FeedPetSpellName()
  if feedPetSpellName then return feedPetSpellName end
  if C_Spell and C_Spell.GetSpellInfo then
    local info = C_Spell.GetSpellInfo(FEED_PET_SPELL_ID)
    if info and info.name then feedPetSpellName = info.name end
  end
  if not feedPetSpellName and GetSpellInfo then
    feedPetSpellName = GetSpellInfo(FEED_PET_SPELL_ID)
  end
  if type(feedPetSpellName) ~= "string" or feedPetSpellName == "" then
    feedPetSpellName = "Feed Pet"
  end
  return feedPetSpellName
end

-- The Feed Pet spell's icon, resolved through the spell API (fileID on modern
-- clients, texture path on classic) so it can never depend on a guessed file
-- name. Memoised -- the spell's icon never changes within a session.
local feedPetSpellTexture
local function FeedPetSpellTexture()
  if feedPetSpellTexture then return feedPetSpellTexture end
  if C_Spell and C_Spell.GetSpellTexture then
    local ok, tex = pcall(C_Spell.GetSpellTexture, FEED_PET_SPELL_ID)
    if ok and tex then feedPetSpellTexture = tex end
  end
  if not feedPetSpellTexture and GetSpellTexture then
    local ok, tex = pcall(GetSpellTexture, FEED_PET_SPELL_ID)
    if ok and tex then feedPetSpellTexture = tex end
  end
  return feedPetSpellTexture or FEED_PET_ICON
end

-- The frame the feed button anchors to. For the pet-frame parent we prefer the
-- happiness icon (a separate frame just right of the pet portrait, per Classic),
-- so the button sits beside it on the same height instead of on top of it. This
-- must be the SAME frame used by saveFromScreen, or a drag will store an offset
-- measured against a different edge than the one it anchors to.
local function FeedAnchor()
  local parent = _G[db.parent] or UIParent
  if db.parent ~= "UIParent" then
    local happy = _G["PetFrameHappiness"] or _G["PetFrameHappy"]
    if happy then return happy end
  end
  return parent
end

-- ---------------------------------------------------------------------------
-- Init + button
-- ---------------------------------------------------------------------------
-- Invalidate the cached diet list so it re-scans on the next refresh. Called
-- when the pet (Summon/Dismiss) or its pet-bar changes, so a different diet
-- (e.g. a fresh Bear that also eats Bread) is picked up and the food scan stays
-- correct. This is part of the "always find the right food" fix.
local function ResetDiets()
  diets = {}
  dietsReady = false
end

function FeedPet.Init()
  db = HK.db.feed
  if not HK.isHunter then return end -- structural gate (never create frames for others)

  scanTip = CreateFrame("GameTooltip", "HunterKitScanTip", nil, "GameTooltipTemplate")
  scanTip:SetOwner(UIParent, "ANCHOR_NONE")

  -- Owns nothing and draws nothing; it exists only to tick the feed countdown,
  -- and only while a feed is running (see BindFeeder).
  feeder = CreateFrame("Frame", "HunterKitFeedTicker", UIParent)

  BuildButton()

  HK.On("UNIT_PET", function(u)
    if u == "pet" then ResetDiets(); bagsDirty = true end
    RefreshEverything()
  end)
  HK.On("PET_BAR_UPDATE", function()
    ResetDiets()
    bagsDirty = true
    RefreshEverything()
  end)
  HK.On("UNIT_HAPPINESS", function(u) if u == "pet" then RefreshEverything() end end)
  -- The Feed Pet Effect buff appearing, ticking and being cancelled (damage
  -- during the feed drops it outright) all arrive here.
  HK.On("UNIT_AURA", function(u) if u == "pet" then FeedPet.UpdateFeeding() end end)
  HK.On("UNIT_HEALTH", function(u) if u == "pet" then RefreshEverything() end end)
  HK.On("PLAYER_ENTERING_WORLD", function() bagsDirty = true; RefreshEverything() end)
  HK.On("PLAYER_REGEN_DISABLED", RefreshEverything)   -- kill the highlight on combat start
  HK.On("PLAYER_REGEN_ENABLED", function()
    if pending then pending = false end
    bagsDirty = true
    if button and not InCombatLockdown() then
      button:SetSize(db.size, db.size)   -- deferred secure resize
      FeedPet.ApplyPosition()            -- replays any move blocked in combat
    end
    RefreshEverything()            -- re-applies show/hide + macro now that we're safe
  end)
  HK.On("BAG_UPDATE_DELAYED", OnBagUpdate)
end

function BuildButton()
  -- Parent to UIParent, NEVER to the pet frame. The pet frame is a protected
  -- unit frame, and a child of it can have clicks swallowed. UIParent is neutral.
  -- We anchor to `db.parent` only for POSITION, not as an actual parent.
  --
  -- This is a SECURE action button (SecureActionButtonTemplate). Left-click casts
  -- the "Feed Pet" spell (type1 = "spell") and feeds it the chosen food via the
  -- secure target-item/target-bag/target-slot attributes, so no protected
  -- function is ever called from addon/tainted code — that is what caused the
  -- previous ADDON_ACTION_FORBIDDEN error when we tried CastSpellByName/
  -- UseContainerItem from a plain button's OnClick. Feeding is player-initiated.
  button = CreateFrame("Button", "HunterKitFeedButton", UIParent, "SecureActionButtonTemplate")
  button:SetSize(db.size, db.size)
  button:EnableMouse(true)                 -- must be clickable
  button:SetFrameStrata("HIGH")
  button:SetFrameLevel(50)
  button:SetClampedToScreen(true)

  button:SetNormalTexture("Interface\\Buttons\\WHITE8x8")
  button:GetNormalTexture():SetVertexColor(0.08, 0.08, 0.08, 0.6) -- subtle bg
  button:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
  button:SetPushedTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")

  -- secure left-click casts "Feed Pet" (spell 6991). The food it feeds is
  -- chosen via the secure target-item/target-bag/target-slot attributes, set in
  -- RefreshMacro when we know the best food. THIS is how the reference single-
  -- click feed addon (Feed-O-Matic / LibSpellButton) does it: a spell button with
  -- a target item, NOT a `/cast`+`/use` macro. A `/use` macro is unreliable
  -- (macrotext is deprioritised/limited and can feed the food to the player).
  button:RegisterForClicks("AnyDown", "AnyUp")
  button:SetAttribute("type1", "spell")
  button:SetAttribute("spell", FeedPetSpellName())

  FeedPet.ApplyPosition()

  iconTex = button:CreateTexture(nil, "ARTWORK")
  iconTex:SetAllPoints()
  iconTex:SetTexture(QUESTION_ICON)
  iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)

  -- Border BEFORE the font work below: if anything after this point ever
  -- fails on a live client, the highlight must still exist (it died once
  -- somewhere after the fontstring, leaving the button permanently dull).
  border = HK.CreateBorder(button, 2)

  countText = button:CreateFontString(nil, "OVERLAY")
  countText:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
  -- Blizzard's item-count look WITHOUT depending on a font-object name that may
  -- not exist on every client (NumberFontNormalSmallOutline is NOT defined on
  -- all classic builds -- passing the nil global here broke the rest of
  -- BuildButton and left the button on the "?" icon). Set the font file +
  -- OUTLINE directly, the same recipe the default action-button counts use,
  -- and fall back to a font object that certainly exists.
  if not countText:SetFont("Fonts\\ARIALN.TTF", 11, "OUTLINE") then
    countText:SetFontObject(GameFontHighlightSmall)
  end
  countText:SetJustifyH("RIGHT")

  -- Seconds left on the feed, to the RIGHT of the button. Outside the frame on
  -- purpose: the count already owns the bottom-right corner, and two numbers in
  -- one corner is two numbers you cannot read at a glance.
  timerText = button:CreateFontString(nil, "OVERLAY")
  timerText:SetPoint("LEFT", button, "RIGHT", 3, 0)
  if not timerText:SetFont("Fonts\\ARIALN.TTF", 12, "OUTLINE") then
    timerText:SetFontObject(GameFontHighlightSmall)
  end
  timerText:SetJustifyH("LEFT")
  timerText:Hide()

  -- hover tooltip: shows what the click will feed so the player knows the action
  button:SetScript("OnEnter", function()
    local f = FeedPet.lastFood
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    GameTooltip:SetText("HunterKit — Feed Pet", 0.2, 1, 0.2)
    if f and f.name then
      GameTooltip:AddLine("Will feed: " .. f.name, 1, 1, 1)
      -- The button's number is a GROUP total now, so saying "x3" next to one
      -- food's name would read as "3 of this". Spell out what was counted.
      local shown, kinds = FeedPet.ShownCount() or 0, FeedPet.ShownKinds() or 1
      if shown > 0 then
        if kinds > 1 then
          GameTooltip:AddLine(string.format(
            "%d feedable in your bags, across %d different foods of this level.",
            shown, kinds), 0.8, 0.8, 0.8)
        else
          GameTooltip:AddLine(string.format("%d in your bags.", shown), 0.8, 0.8, 0.8)
        end
      end
    else
      GameTooltip:AddLine("No food in bags — will cast Feed Pet.", 1, 1, 1)
    end
    -- This used to claim a Happy pet could not be fed at all ("(full) -- the
    -- game won't feed it now"). It can. Happy is a THRESHOLD, not the cap:
    -- there is happiness headroom above green, the game accepts the food and
    -- keeps granting it until the real ceiling, where a tick drops to ~1 and
    -- the rest is simply wasted. The thing that genuinely blocks a feed is
    -- COMBAT, which this line never mentioned -- so the tooltip warned about
    -- the one case that still works and stayed silent about the one that does
    -- not. The button is armed either way, so the useful advice is about food.
    local hp = (GetPetHappiness and GetPetHappiness()) or nil
    if not hp then
      GameTooltip:AddLine("No pet summoned.", 1, 0.6, 0.6)
    elseif InCombatLockdown() then
      GameTooltip:AddLine("In combat — pets will not eat. Feeding is out-of-combat only.",
        1, 0.4, 0.4)
    else
      local htxt = ({"Unhappy", "Content", "Happy"})[hp] or "?"
      if hp >= 3 then
        GameTooltip:AddLine("Pet is " .. htxt ..
          " — it will still eat, but there is little happiness left to gain, so feeding now mostly wastes food.",
          1, 0.85, 0.3)
      elseif hp == 1 then
        GameTooltip:AddLine("Pet is " .. htxt ..
          " — feed it now: an unhappy pet hits 25% softer and can run off.", 1, 0.4, 0.4)
      else
        GameTooltip:AddLine("Pet is " .. htxt .. " — will feed on click.", 0.4, 1, 0.4)
      end
    end
    -- Shift-hover: what the button is NOT counting. There is no API for a
    -- food's diet type, so the curated DB has holes -- cooked food especially --
    -- and the honest response is to show the gap rather than guess at it.
    -- Feeding again while the buff is running does not stack -- it replaces a
    -- feed that is already paying out, so the second food is simply lost.
    if FeedPet.IsFeeding() then
      GameTooltip:AddLine("Already eating — feeding again wastes the food.", 1, 0.7, 0.3)
    end
    if IsShiftKeyDown and IsShiftKeyDown() then
      local others = FeedPet:OtherConsumables()
      GameTooltip:AddLine(" ")
      if #others == 0 then
        GameTooltip:AddLine("Nothing else in your bags looks edible.", 0.7, 0.7, 0.7)
      else
        GameTooltip:AddLine("Not counted — drop one here to teach the button:", 1, 0.85, 0.3)
        for i = 1, math.min(#others, 8) do
          GameTooltip:AddLine("  " .. others[i].name .. " x" .. others[i].count, 0.8, 0.8, 0.8)
        end
        if #others > 8 then
          GameTooltip:AddLine("  +" .. (#others - 8) .. " more", 0.6, 0.6, 0.6)
        end
      end
    elseif db.learnDrop ~= false then
      GameTooltip:AddLine("Drop a food here to pin it · shift-hover for foods not counted",
        0.6, 0.6, 0.6)
    end
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", function() GameTooltip:Hide() end)
  -- EnableMouse(true) is already set above; this is the other half of the drop
  -- gesture -- what happens when the item is released over the button.
  button:SetScript("OnReceiveDrag", function() FeedPet:ReceiveDrop() end)

  -- drag / reposition. `blankSecure` lets unlock-mode blank the secure macro so
  -- a left-press-drag never accidentally feeds. saveFromScreen computes the
  -- offset correctly from the button's on-screen position so it stays where the
  -- player dropped it (relative to the anchor frame), instead of the broken
  -- GetPoint() coords that pushed it over the pet frame.
  HK.RegisterDraggable("feed", button, FeedPet.ApplyPosition, function(x, y)
    db.offsetX, db.offsetY = x, y
  end, {
    clickable = true, blankSecure = true,
    -- edit mode unregisters these and locks re-registers them, so pressing/
    -- dragging the feed button during repositioning never casts Feed Pet.
    clickRegistration = { "AnyDown", "AnyUp" },
    restore = function() UpdateState() end,
    -- Store the button's on-screen centre as an offset from UIParent's CENTRE
    -- (HK.SaveDragged computes it entirely in UIParent space, so it round-trips
    -- exactly via ApplyPosition's CENTRE/CENTRE anchor — no unit-frame coordinate
    -- conversion, so the button cannot jump on lock).
    saveFromScreen = function()
      HK.SaveDragged(button, db)
    end,
  })

  -- CRITICAL: Do NOT override OnClick on this secure button. The
  -- SecureActionButtonTemplate dispatches its secure action (type1="spell" +
  -- target-item) through its own protected OnClick handler. If we install an
  -- addon OnClick script, the secure dispatch can be blocked on the live client
  -- and the feed never runs — exactly why the button "did nothing". The reference
  -- single-click feed addon (Feed-O-Matic / LibSpellButton) adds its custom
  -- behavior with a POSTCLICK script instead, which fires AFTER the secure action
  -- without touching it. We mirror that: PostClick opens the pin menu on
  -- right-click and logs on debug; the secure left-click is left to the template.
  button:SetScript("PostClick", function(self, btn, down)
    if btn == "RightButton" then
      -- AnyDown/AnyUp fires PostClick on BOTH the press and the release. Only
      -- act on the release, or the menu is opened on press and instantly closed
      -- on release (the "opens then closes right away" bug).
      if not down then FeedPet:ShowMenu() end
      return
    end
    if down then return end   -- AnyDown/AnyUp fires twice; log only the release
    -- Verbose feed log, gated behind /htk debug so normal use stays clean. The
    -- hover tooltip already shows the food + pet happiness state.
    if HK.debug then
      local f = FeedPet.lastFood
      local hp = (GetPetHappiness and GetPetHappiness()) or nil
      local pet = UnitExists("pet")
      print("|cff39ff14HunterKit|r feed click: " .. tostring(btn)
        .. " | pet=" .. tostring(pet)
        .. " | happy=" .. tostring(hp or "?")
        .. " | spell=" .. tostring(self:GetAttribute("spell"))
        .. " | target-item=" .. tostring(self:GetAttribute("target-item"))
        .. " | food=" .. tostring(f and f.name or "nil"))
    end
  end)

  -- keep the best-food macro current as soon as the button exists
  FeedPet:RefreshMacro()
  initialised = true
end

function FeedPet.ApplyPosition()
  if not button then return end
  -- The feed button is a SECURE frame: moving it in combat is a protected
  -- action and throws ADDON_ACTION_BLOCKED. Every caller used to have to
  -- remember that (RescanSettings did, "reset positions" did not, and it threw
  -- on ClearAllPoints). Guarding here means no caller can get it wrong, and the
  -- move is replayed on PLAYER_REGEN_ENABLED, which already re-applies position.
  if InCombatLockdown and InCombatLockdown() then
    positionPending = true
    return
  end
  positionPending = false
  button:ClearAllPoints()
  -- Once the user has dragged it (or selected a UIParent anchor), pin it to the
  -- absolute UIParent CENTRE offset so it stays exactly where dropped. Otherwise
  -- use the default happy-icon anchor.
  if HK.IsPinned(db) then
    button:SetPoint("CENTER", UIParent, "CENTER", db.offsetX, db.offsetY)
    return
  end
  -- Sit to the right of the pet frame. Prefer anchoring to the happiness icon so
  -- the feed button's CENTRE lands on the SAME height as the happiness icon and
  -- sits fully to its right (the happiness icon is a separate frame just right of
  -- the pet portrait — anchoring to the pet frame's own right edge put the button
  -- ON the happiness icon, which is what looked overlapping).
  button:SetPoint("LEFT", FeedAnchor(), "RIGHT", db.offsetX, db.offsetY)
end

function FeedPet.IsButtonValid()
  return button and button:IsShown()
end

-- /htk feed — prints the current one-click feed action so the player knows
-- exactly what the button will do (and can confirm the macro is set correctly).
function FeedPet:PrintFeed()
  if not button then
    print("|cff39ff14HunterKit|r feed button not built (not a hunter, or init not run).")
    return
  end
  local spell, ti
  if button.GetAttribute then
    spell = button:GetAttribute("spell")
    ti = button:GetAttribute("target-item")
  end
  local f = self.lastFood
  if f then
    -- Report the SAME number the button shows. The button counts every feedable
    -- food at this tier, not just the stack the click will feed, and a
    -- diagnostic that disagreed with the UI would be worse than no diagnostic.
    local total, kinds = self:CountAtTier(f.tier)
    print(("|cff39ff14HunterKit|r feed: %s (bag %d slot %d, tier %d) | %d feedable at this tier across %d food(s) | click feeds a stack of %d | casts %s on item %s")
      :format(f.name or "?", f.bag or "?", f.slot or "?", f.tier or "?",
        total, kinds, f.count or 1, tostring(spell), tostring(ti)))
  else
    print("|cff39ff14HunterKit|r feed: no food found in bags | casts " .. tostring(spell))
  end
  -- The foods the player taught the button, because "why is my food not
  -- counted" is otherwise unanswerable from outside the addon.
  local taught = {}
  for _, e in ipairs(db.learned or {}) do
    taught[#taught + 1] = tostring(e.name or e.id)
      .. (self:IsLearned(e.id) and "" or " (not for this pet)")
  end
  print(("|cff39ff14HunterKit|r feed: %d taught food(s): %s")
    :format(#taught, #taught > 0 and table.concat(taught, ", ") or "none -- drag one onto the button"))
end

-- Diagnostic for /htk selfcheck. Reports the real anchor state so we can see
-- exactly what the client is doing (no guessing from my side).
function FeedPet.Diagnostic()
  if not button then return "(button not built)" end
  local ok, pt, rel, _, x, y = pcall(button.GetPoint, button, 1)
  local relname
  if ok and rel then
    local rok, n = pcall(function() return rel:GetName() end)
    relname = (rok and n) or "?"
  else
    relname = "?" end
  local function str(v) if v == nil then return "nil" end return tostring(v) end
  local paren
  local pok, pn = pcall(function() return button:GetParent():GetName() end)
  paren = pok and pn or "?"
  return string.format("anchor=%s rel=%s x=%s y=%s lvl=%s strata=%s parent=%s shown=%s mouse=%s",
    str(pt), tostring(relname), str(x), str(y),
    str(button:GetFrameLevel()), str(button:GetFrameStrata()),
    tostring(paren), str(button:IsShown()), str(button:IsMouseEnabled()))
end

function FeedPet.RescanSettings()
  db = HK.db.feed
  if not button then return end
  -- SECURE button: SetSize/SetPoint are protected actions in combat and throw
  -- ADDON_ACTION_BLOCKED; defer both to PLAYER_REGEN_ENABLED.
  if not InCombatLockdown() then
    button:SetSize(db.size, db.size)
    FeedPet.ApplyPosition()
  end
  -- Apply visibility on toggle: unchecking "Enable feed button" must hide it.
  UpdateState()
  -- RefreshMacro is a FeedPet method (not a local), so call it on the table.
  FeedPet:RefreshMacro()
end

function FeedPet.ButtonSize() return button and button:GetWidth() or nil end

-- ---------------------------------------------------------------------------
-- Diet detection
-- ---------------------------------------------------------------------------
function FeedPet:GetDiets()
  if dietsReady then return diets end
  diets = {}
  if not HK.isHunter or not UnitExists("pet") then
    return diets
  end
  -- GetPetFoodTypes returns MULTIPLE string values, e.g. "Meat", "Fish", ...
  -- (NOT a comma-joined single string). Capture all of them into a set keyed by
  -- the lowercased diet name. Robust to BOTH shapes: split any value that is a
  -- comma-joined string (e.g. "Meat, Fish") and also accept bare multi-values.
  local ok, a, b, c, d, e, f = pcall(GetPetFoodTypes)
  if ok then
    for _, token in ipairs({ a, b, c, d, e, f }) do
      if type(token) == "string" then
        for raw in (token .. ""):gmatch("[^,]+") do
          local t = raw:gsub("^%s+", ""):gsub("%s+$", ""):lower()
          if t ~= "" then diets[t] = true end
        end
      end
    end
  end
  dietsReady = true
  return diets
end

function FeedPet:GetDietsString()
  local t = {}
  for k in pairs(self:GetDiets()) do t[#t+1] = k:gsub("^%l", string.upper) end
  return table.concat(t, ", ")
end

-- ---------------------------------------------------------------------------
-- Foods the player has TAUGHT the button
--
-- There is no API for a food's diet type. Not a weak one, none at all: the
-- Feed Me author put it plainly -- "No ingame method seems to detect what type
-- of food it is" -- and every maintained feeder (Feed-O-Matic, Lazy Feed Pet)
-- ships a hand-curated item table and admits it is incomplete. Cooked food is
-- the hole that matters, because cooked food is what a hunter actually carries.
--
-- So instead of guessing item IDs, the button can be taught: drop a food on it
-- and the addon remembers that THIS PET eats it. The diet list in force at the
-- moment of the drop travels with the entry, so switching to a pet that cannot
-- eat the food does not resurrect it.
-- ---------------------------------------------------------------------------

-- Is this a food the player taught us, for the pet that is out right now?
function FeedPet:IsLearned(itemID)
  if not itemID then return false end
  for _, e in ipairs(db.learned or {}) do
    if e.id == itemID then
      -- No diet recorded: the pet had not resolved when it was dropped, so
      -- there was nothing to record. Take the player's word for it.
      if not e.diets or #e.diets == 0 then return true end
      local ds = self:GetDiets()
      if not next(ds) then return true end
      for _, d in ipairs(e.diets) do
        if ds[d] then return true end
      end
      return false
    end
  end
  return false
end

-- The diet name a taught food was recorded under, or nil. Used for display and
-- by ContradictsDiet; matching goes through IsLearned, which also has to answer
-- "the player said so and we recorded no diet".
function FeedPet:LearnedType(itemID)
  for _, e in ipairs(db.learned or {}) do
    if e.id == itemID and e.diets and e.diets[1] then
      return e.diets[1]:gsub("^%l", string.upper)
    end
  end
  return nil
end

function FeedPet:Learn(itemID, name)
  if not itemID then return end
  db.learned = db.learned or {}
  local diets = {}
  for k in pairs(self:GetDiets()) do diets[#diets + 1] = k end
  for _, e in ipairs(db.learned) do
    if e.id == itemID then
      e.name = name or e.name
      e.diets = diets
      return
    end
  end
  db.learned[#db.learned + 1] = { id = itemID, name = name, diets = diets }
end

function FeedPet:Unlearn(itemID)
  local kept = {}
  for _, e in ipairs(db.learned or {}) do
    if e.id ~= itemID then kept[#kept + 1] = e end
  end
  db.learned = kept
end

-- Test/diagnostic seams: assert on what the PLAYER taught, not on internals.
function FeedPet.LearnedCount() return #(db and db.learned or {}) end
function FeedPet.HasLearned(id)
  for _, e in ipairs(db and db.learned or {}) do
    if e.id == id then return true end
  end
  return false
end

-- The item's diet type name, from the curated FoodDB or from what the player
-- taught the button, or nil if it isn't a known pet food.
function FeedPet:FoodType(itemID)
  if not itemID then return nil end
  local taught = self:LearnedType(itemID)
  if taught then return taught end
  if HK.FOOD_BY_ITEM and HK.FOOD_BY_ITEM[itemID] then
    return HK.FOOD_BY_ITEM[itemID]
  end
  return nil
end

-- Is this a QUEST ITEM? Feeding one destroys it, and it is the one mistake
-- this button can make that the player cannot buy their way out of -- so this
-- is checked on every path that can arm the button, and it errs toward
-- excluding.
--
-- Two signals, cheapest first:
--   1. the item's TYPE (6th return of GetItemInfo). Localised, so it is
--      compared against Blizzard's own ITEM_CLASS_QUEST constant when the
--      client provides one, with the English spelling as a fallback.
--   2. the "Quest Item" line in the tooltip, for the items whose type the
--      cache does not answer for. Only reached when (1) is inconclusive, so
--      the common case costs no tooltip scan.
function FeedPet:IsQuestItem(bag, slot, itemID)
  local questWord = "quest"
  if type(ITEM_CLASS_QUEST) == "string" then questWord = ITEM_CLASS_QUEST:lower() end

  local ok, class = pcall(function() return (select(6, HK.GetItemInfo(itemID))) end)
  if ok and type(class) == "string" and class ~= "" then
    local c = class:lower()
    -- Trust the cache when it answers: a known non-quest type is a definite no,
    -- which keeps the tooltip scan off the hot path.
    return c == questWord or c == "quest" or c:find("quest", 1, true) ~= nil
  end

  if not scanTip then return false end
  scanTip:ClearLines()
  scanTip:SetBagItem(bag, slot)
  for i = 2, scanTip:NumLines() do
    local line = _G["HunterKitScanTipTextLeft" .. i]
    local text = line and line:GetText()
    if text then
      local t = text:lower():gsub("^%s+", ""):gsub("%s+$", "")
      if t == questWord or t == "quest" or t == "quest item" then return true end
    end
  end
  return false
end

-- Does the curated DB positively place this food OUTSIDE the pet's diet?
-- Narrower than MatchesDiet on purpose -- see FindBestStackByID. Answers true
-- only when both sides are known: the pet has a resolved diet list, and the DB
-- names a type for this item that is not in it. Costs no tooltip scan.
function FeedPet:ContradictsDiet(itemID)
  local ds = self:GetDiets()
  if not next(ds) then return false end       -- diet unknown: no evidence
  local ftype = self:FoodType(itemID)
  if not ftype then return false end          -- not a listed food: no evidence
  return ds[ftype:lower()] ~= true
end

function FeedPet:MatchesDiet(bag, slot, itemID)
  -- A food the player dropped on the button. Checked before everything else:
  -- it is the only signal here that is not a guess.
  if self:IsLearned(itemID) then return true end
  local ds = self:GetDiets()
  local ftype = self:FoodType(itemID)
  if not next(ds) then
    -- Diet unknown. That is not a rare edge case: GetPetFoodTypes has nothing
    -- to say for a moment after every login, until the pet resolves.
    --
    -- This used to return TRUE -- "don't hard-exclude" -- which meant every
    -- item in your bags was a candidate and the button armed itself with the
    -- most level-appropriate one, quest item or potion or whatever it was.
    -- The asymmetry is what matters: feeding something the pet cannot eat
    -- merely fizzles, while feeding a quest item destroys it. So with no diet
    -- known, only the curated DB's known pet foods are offered.
    return ftype ~= nil
  end
  -- Primary: is this an item in the curated FoodDB that this pet's diet allows?
  if ftype then
    return ds[ftype:lower()] == true
  end
  -- Fallback: scan the item tooltip for the diet keywords (for foods the DB
  -- doesn't list, e.g. raw meat/fish or odd vendor foods).
  --
  -- From line 1, unlike the quest scan below, which starts at 2. Here the name
  -- is the most informative line on the tooltip -- half of Classic's foods are
  -- called some kind of meat or fish, and skipping the name was quietly
  -- discarding the best evidence available for an unlisted item. (The quest
  -- scan must keep skipping it: an item merely NAMED something must not be
  -- mistaken for a quest item, and that error destroys the item.)
  if not scanTip then return false end
  scanTip:ClearLines()
  scanTip:SetBagItem(bag, slot)
  for i = 1, scanTip:NumLines() do
    local line = _G["HunterKitScanTipTextLeft" .. i]
    local text = line and line:GetText()
    if text then
      local low = text:lower()
      for keyword in pairs(ds) do
        if low:find(keyword, 1, true) then return true end
      end
    end
    local right = _G["HunterKitScanTipTextRight" .. i]
    local rtext = right and right:GetText()
    if rtext then
      local low = rtext:lower()
      for keyword in pairs(ds) do
        if low:find(keyword, 1, true) then return true end
      end
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Pick the best food
-- ---------------------------------------------------------------------------
function FeedPet:IsExcluded(itemID)
  if not itemID then return false end
  for _, e in ipairs(db.exclude) do
    if e.id == itemID then return true end
  end
  return false
end

local function TierFor(petLevel, foodLevel)
  local gap = petLevel - foodLevel
  if gap <= 15 then return 3 end -- 35/tick
  if gap <= 25 then return 2 end -- 17/tick
  return 1                       -- 8/tick (or refused if way below)
end

function FeedPet:FindBestStackByID(itemID, petLevel)
  local best
  for bag = 0, 4 do
    for slot = 1, HK.GetBagNumSlots(bag) do
      -- A pin is a deliberate choice, but it is not a licence to destroy a
      -- quest item: pins saved by an older build, or made before this check
      -- existed, must not be able to eat one. The menu no longer offers quest
      -- items either, so this only guards the upgrade path.
      -- A pin is a deliberate choice, but it was made for a PET, and the pet
      -- can change: pin mackerel for the crab, summon the bear, and the button
      -- kept arming itself with fish the bear cannot eat -- naming it in the
      -- tooltip and feeding it on click.
      --
      -- Deliberately NOT the full MatchesDiet. That answers "is there evidence
      -- this pet can eat it", which is right for the bag scan, where an
      -- unrecognised item should never be offered. But a pin is the PLAYER's
      -- evidence, and it should only be overruled by something better than
      -- silence: the curated DB naming a diet type this pet does not have. A
      -- food the DB does not list -- most foods, it is finite -- or a moment
      -- when the pet's diet has not resolved yet leaves the pin alone.
      if HK.GetBagItemID(bag, slot) == itemID
         and not self:ContradictsDiet(itemID)
         and not self:IsQuestItem(bag, slot, itemID) then
        local count = HK.GetBagItemCount(bag, slot)
        count = count or 1
        local name, _, _, iLevel = HK.GetItemInfo(itemID)
        if name and iLevel then
          if not best or count < best.count then
            best = { bag = bag, slot = slot, itemID = itemID, name = name,
                     icon = select(10, HK.GetItemInfo(itemID)), tier = TierFor(petLevel, iLevel), count = count }
          end
        end
      end
    end
  end
  return best
end

-- How much of an item you are actually carrying.
--
-- The authoritative answer is GetItemCount: the client's own "how many of this
-- item are in my bags", and exactly what AmmoBuy.lua and AmmoWarn.lua already
-- use. FeedPet did NOT use it -- it summed per-slot stack counts from the
-- container API instead, which is a reimplementation of the same question and
-- depends on which container call the client answers with. When that call did
-- not answer, `HK.GetBagItemCount` returned nil, every stack fell back to
-- `or 1`, and the button read "1" over a stack of 20. That is the reported bug,
-- and it is why it survived a fix that was aimed at the totals table: the table
-- was fine, the per-slot numbers feeding it were not.
--
-- We take the MAX of the two rather than trusting either alone. GetItemCount
-- can answer 0 for a second or two after a bag change (AmmoWarn documents
-- exactly this, post-hearthstone), and the scan can under-count when the
-- container API is cold. Neither ever OVER-reports, so the max is the honest
-- number whenever either source is working.
local function TotalOf(itemID, scanned)
  scanned = tonumber(scanned) or 0
  local fromAPI = 0
  if GetItemCount then
    local ok, n = pcall(GetItemCount, itemID)
    if ok and type(n) == "number" and n > fromAPI then fromAPI = n end
  end
  return math.max(fromAPI, scanned)
end

function FeedPet:PickFood()
  local petLevel = UnitLevel("pet") or UnitLevel("player")
  local best
  local totals = {}   -- how much of EVERY itemID the bags hold
  -- Only the food THIS PET can eat, keyed by itemID, with the happiness tier it
  -- scores at. Nothing reaches this table without passing the diet, exclusion
  -- and quest checks, so it is the honest "what could I feed" set -- and it is
  -- what the button's number is summed from.
  local feedable = {}
  for bag = 0, 4 do
    for slot = 1, HK.GetBagNumSlots(bag) do
      local itemID = HK.GetBagItemID(bag, slot)
      if itemID then
        -- Count the inventory FIRST, and unconditionally.
        --
        -- How much of an item you own is an inventory fact. Whether this addon
        -- is willing to feed it is a *different* question, and it depends on
        -- three things that can each fail transiently: the pet's diet list,
        -- the exclusion list, and GetItemInfo (nil for any item the client has
        -- not cached yet -- routine right after a login or a zone).
        --
        -- The count used to be accumulated INSIDE those checks, so whenever
        -- they rejected an item the totals table had no entry for it and the
        -- button fell back to the single stack that happened to get picked:
        -- "1" when you were carrying a stack of 1 and a stack of 20 of the same
        -- food. The pin path made it worse -- FindBestStackByID skips the diet
        -- check entirely, so a pinned food the curated DB does not list hit
        -- this on every single refresh.
        local count = HK.GetBagItemCount(bag, slot) or 1
        totals[itemID] = (totals[itemID] or 0) + count

        -- Last gate, and the one that costs the most: a quest item is never
        -- feedable, whatever its diet or level says. Checked after the cheap
        -- filters so the tooltip scan only runs for real food candidates.
        if not self:IsExcluded(itemID) and self:MatchesDiet(bag, slot, itemID)
           and not self:IsQuestItem(bag, slot, itemID) then
          local name, _, _, iLevel, _, _, _, _, _, icon = HK.GetItemInfo(itemID)
          if name and iLevel then
            local tier = TierFor(petLevel, iLevel)
            local ft = self:FoodType(itemID)
            -- Accumulate per itemID, not per slot: two stacks of the same food
            -- are one food, and both stacks belong to its total.
            local seen = feedable[itemID]
            if seen then
              seen.count = seen.count + count
            else
              feedable[itemID] = { tier = tier, count = count, name = name }
            end
            if not best or tier > best.tier
               or (tier == best.tier and count < best.count) then
              best = { bag = bag, slot = slot, itemID = itemID, name = name,
                       icon = icon, tier = tier, count = count, foodType = ft }
            end
          end
        end
      end
    end
  end
  -- Every stack of every item, keyed by itemID. The button's number reads this
  -- and nothing else, so it is right no matter which path picked the food.
  -- Each entry is reconciled against GetItemCount before it is published -- see
  -- TotalOf for why the scan alone is not trusted.
  for id, scanned in pairs(totals) do
    totals[id] = TotalOf(id, scanned)
  end
  -- The same reconciliation for the feedable set -- and deliberately ONE call
  -- per distinct item rather than per stack. TotalOf raises a scan up to the
  -- client's inventory figure, so running it per stack would inflate every
  -- stack of a food to the whole inventory total and then add them together.
  for id, f in pairs(feedable) do
    f.count = TotalOf(id, f.count)
  end
  self.foodTotals = totals
  self.feedableByItem = feedable
  -- pinned food override
  for _, pin in ipairs(db.preferredFoods) do
    local hit = self:FindBestStackByID(pin.id, petLevel)
    if hit then return hit end
  end
  return best
end

-- How many feeds the button can perform at the quality it is about to feed.
--
-- The button's number used to be the inventory total of the ONE item the pick
-- happened to land on. Eight different appropriate-level meats with a single
-- item in each therefore read "1" -- true of the stack it would feed, and no
-- answer at all to "how much food do I have".
--
-- Foods are counted together by happiness TIER, which is the only grouping that
-- means anything here: within 15 levels of the pet a bite is worth 35
-- happiness, at 16-25 it is worth 17, beyond that 8. Foods in the same tier
-- really are interchangeable; foods a tier down really are not, so they are
-- left out rather than inflating the number.
--
-- Only food THIS PET can eat is ever in the sum, because feedableByItem only
-- gains an entry that already passed the diet, exclusion and quest checks.
function FeedPet:CountAtTier(tier)
  local n, kinds = 0, 0
  for _, f in pairs(self.feedableByItem or {}) do
    if f.tier == tier then
      n = n + (f.count or 0)
      kinds = kinds + 1
    end
  end
  return n, kinds
end

-- The button's item-count readout: how much of the PICKED food the bags hold
-- (all its stacks, not just the one the click will feed).
function FeedPet.SetCount(n)
  if not countText then return end
  FeedPet.shownCount = n
  -- While the pet is eating this string is showing the happiness per bite, not
  -- the count. Remember the count and leave the string alone; UpdateFeeding
  -- puts it back when the feed ends.
  if FeedPet.feedSecondsLeft then return end
  countText:SetText(tostring(n))
  if n > 0 then
    countText:SetTextColor(1, 0.82, 0, 1)
  else
    countText:SetTextColor(1, 0.2, 0.2, 1)
  end
end

-- The number the button is displaying right now. Exposed so the tests (and
-- /htk feed) can assert on what the PLAYER sees rather than on the internals
-- that produced it -- the count has been wrong twice now, and both times the
-- internals looked plausible.
function FeedPet.ShownCount() return FeedPet.shownCount end

-- How many DIFFERENT foods made up that number. The tooltip uses it to say
-- "5 feedable, across 3 different foods" instead of implying five of one item.
function FeedPet.ShownKinds() return FeedPet.shownKinds end

-- ---------------------------------------------------------------------------
-- Drop a food on the button to teach it
-- ---------------------------------------------------------------------------

-- Quest check that needs no bag slot, for the drop path where the item is on
-- the cursor and there is nothing to SetBagItem. Deliberately class-only: with
-- no tooltip to fall back on, the honest answer is "not proven a quest item",
-- and the pin/menu paths still run the full check before anything is fed.
function FeedPet:QuestByID(itemID)
  local ok, class = pcall(function() return (select(6, HK.GetItemInfo(itemID))) end)
  if not ok or type(class) ~= "string" or class == "" then return false end
  local c = class:lower()
  return c == "quest" or c:find("quest", 1, true) ~= nil
end

-- The item the cursor is holding, as an itemID. Classic answers "item", link;
-- newer clients answer "item", id. Both shapes are read, and anything else is
-- refused -- guessing here would pin the wrong item.
local function CursorItemID()
  if not GetCursorInfo then return nil end
  local ok, kind, a = pcall(GetCursorInfo)
  if not ok or kind ~= "item" then return nil end
  if type(a) == "number" then return a end
  if type(a) == "string" then return tonumber(a:match("item:(%d+)")) end
  return nil
end

local function Say(msg)
  print("|cff39ff14HunterKit|r feed: " .. msg)
end

function FeedPet:ReceiveDrop()
  if db.learnDrop == false then return end
  local id = CursorItemID()
  -- Always release the cursor, even on a refusal: leaving the player holding an
  -- item the button declined to take is worse than a message.
  if ClearCursor then pcall(ClearCursor) end
  if not id then return end
  if self:QuestByID(id) then
    Say("that is a quest item -- it was not pinned, feeding one destroys it.")
    return
  end
  local name = HK.GetItemInfo(id) or ("item " .. tostring(id))
  local fresh = not FeedPet.HasLearned(id)
  self:Learn(id, name)
  if not self:IsPinned(id) then
    db.preferredFoods = db.preferredFoods or {}
    db.preferredFoods[#db.preferredFoods + 1] = { id = id, name = name }
  end
  bagsDirty = true
  RefreshEverything()
  Say((fresh and "learned " or "updated ") .. name ..
      " -- pinned. Right-click the button for the list.")
end

function FeedPet:IsPinned(itemID)
  for _, e in ipairs(db.preferredFoods or {}) do
    if e.id == itemID then return true end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- What the addon is NOT counting
-- ---------------------------------------------------------------------------

-- Is this item plausibly something you could eat? The subclass name is
-- localised, so this is a HINT, not a gate: it only decides what the
-- shift-hover list offers, where a false positive costs nothing and a false
-- negative hides the very food the player came looking for.
local function LooksEdible(itemID)
  local ok, sub = pcall(function() return (select(7, HK.GetItemInfo(itemID))) end)
  if not ok or type(sub) ~= "string" then return false end
  return sub:lower():find("food", 1, true) ~= nil
end

-- Every edible-looking item in the bags that is NOT being counted as feedable.
-- This is the honest answer to a database that can never be complete: show the
-- blind spot instead of guessing at it, and let the player close it with one
-- drag.
function FeedPet:OtherConsumables()
  local out, seen = {}, {}
  local feedable = self.feedableByItem or {}
  for bag = 0, 4 do
    for slot = 1, HK.GetBagNumSlots(bag) do
      local itemID = HK.GetBagItemID(bag, slot)
      if itemID and not feedable[itemID] and not seen[itemID] then
        seen[itemID] = true
        local name = HK.GetItemInfo(itemID)
        if name and LooksEdible(itemID) and not self:IsQuestItem(bag, slot, itemID) then
          out[#out + 1] = { id = itemID, name = name,
                            count = (self.foodTotals and self.foodTotals[itemID]) or 1 }
        end
      end
    end
  end
  table.sort(out, function(a, b) return (a.count or 0) > (b.count or 0) end)
  return out
end

-- ---------------------------------------------------------------------------
-- While the pet is eating
-- ---------------------------------------------------------------------------

-- Seconds left on the pet's Feed Pet Effect, or nil when it is not eating.
-- Prefers the modern C_UnitAuras struct and falls back to UnitAura, the same way
-- HK.GetItemInfo handles the two container APIs.
local function FeedBuffRemaining()
  local now = tonumber(GetTime and GetTime() or 0) or 0
  if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
    for i = 1, 40 do
      local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, "pet", i, "HELPFUL")
      if not ok or not a then break end
      if a.spellId == FEED_BUFF_ID then
        local left = (a.expirationTime or 0) - now
        return (left > 0) and left or nil
      end
    end
    return nil
  end
  if UnitAura then
    for i = 1, 40 do
      local ok, name, _, _, _, _, exp, _, _, spellID =
        pcall(UnitAura, "pet", i, "HELPFUL")
      if not ok or not name then break end
      if spellID == FEED_BUFF_ID then
        local left = (exp or 0) - now
        return (left > 0) and left or nil
      end
    end
  end
  return nil
end

-- The countdown needs a tick, and a permanent per-frame loop for a buff that
-- lasts 20 seconds now and then is waste -- so the ticker is bound only while
-- the pet is actually eating.
local feederBound = false
local function BindFeeder(on)
  if not feeder then return end
  if on == feederBound then return end
  feederBound = on
  feeder:SetScript("OnUpdate", on and function() FeedPet.UpdateFeeding() end or nil)
end

function FeedPet.UpdateFeeding()
  if not countText then return end
  local left = FeedBuffRemaining()
  FeedPet.feedSecondsLeft = left
  if left then
    local tier = FeedPet.lastFood and FeedPet.lastFood.tier
    -- The per-bite figure is the documented value for the food's tier, not a
    -- measurement: there is no API for what a bite just granted.
    local per = HAPPINESS_PER_TIER[tier] or 35
    FeedPet.feedPerTick = per
    countText:SetText("+" .. per)
    countText:SetTextColor(0.4, 1, 0.4, 1)
    if timerText then
      timerText:SetText(string.format("%ds", math.ceil(left)))
      timerText:Show()
    end
    BindFeeder(true)
  else
    FeedPet.feedPerTick = nil
    if timerText then timerText:SetText(""); timerText:Hide() end
    BindFeeder(false)
    -- Hand the string back to the count.
    FeedPet.SetCount(FeedPet.shownCount or 0)
  end
end

-- Test/diagnostic seams: assert on what is on screen.
function FeedPet.IsFeeding() return FeedPet.feedSecondsLeft ~= nil end
function FeedPet.FeedSecondsLeft() return FeedPet.feedSecondsLeft end
function FeedPet.FeedPerTick() return FeedPet.feedPerTick end
function FeedPet.FeedTimerText() return timerText and timerText.text or nil end
-- The RAW count string, not the number. While the pet eats it holds "+35", so
-- asserting on ShownCount would prove nothing about what is on screen.
function FeedPet.CountText() return countText and countText.text or nil end
function FeedPet.Ticking() return feederBound end



-- ---------------------------------------------------------------------------
-- Macro + visuals
-- ---------------------------------------------------------------------------
function FeedPet:RefreshMacro()
  if not button then return end
  if InCombatLockdown() then pending = true; return end
  -- Always ensure the secure left-click action is armed (a prior unlock/blank
  -- may have cleared type1; re-arm it on every refresh so a lock cycle restores
  -- the feed action). The button casts "Feed Pet" and feeds it the food selected
  -- by the secure target-item/target-bag/target-slot attributes — the same
  -- mechanism the reference single-click feed addon (Feed-O-Matic / LibSpellButton)
  -- uses. This is far more reliable than a `/cast`+`/use` macro, which is
  -- deprecated/limited for this purpose and can feed the food to the player.
  button:SetAttribute("type1", "spell")
  button:SetAttribute("spell", FeedPetSpellName())
  local food = self:PickFood()
  if food and food.itemID and food.bag then
    -- Feed Pet the exact scanned stack. `target-item` is a "bag slot" string;
    -- the secure button resolves it against the bag/slot and feeds the pet.
    button:SetAttribute("target-item", ("%d %d"):format(food.bag, food.slot))
    button:SetAttribute("target-bag", food.bag)
    button:SetAttribute("target-slot", food.slot)
    local icon = (db.useSpellIcon and FeedPetSpellTexture()) or food.icon or QUESTION_ICON
    iconTex:SetTexture(icon)
    iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    -- The number is how much FOOD AT THIS QUALITY the bags hold: every stack of
    -- every food this pet can eat that scores the same happiness tier, not just
    -- the one item the pick landed on. Both fallbacks only fire if the food came
    -- from somewhere the bag scan never saw, which should not happen.
    local total, kinds = self:CountAtTier(food.tier)
    if total <= 0 then
      total = (self.foodTotals and self.foodTotals[food.itemID]) or food.count or 0
      kinds = 1
    end
    FeedPet.shownKinds = kinds
    FeedPet.SetCount(total)
  else
    -- no food in bags: fall back to the game's own Feed Pet (picks a food itself)
    button:ClearAttribute("target-item")
    button:ClearAttribute("target-bag")
    button:ClearAttribute("target-slot")
    iconTex:SetTexture(db.useSpellIcon and FeedPetSpellTexture() or QUESTION_ICON)
    iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    FeedPet.SetCount(0)
  end
  self.lastFood = food
  bagsDirty = false
end

UpdateState = function()
  if not button then return end
  -- While editing, leave the button where the user put it (don't reposition or
  -- hide it from pet events) — the drag owns its position.
  if HK.Editing() then
    -- still force it visible so it's grabbable, but never move/re-hide it.
    if not InCombatLockdown() then button:SetShown(true) end
    return
  end
  local show = HK.db.enabled ~= false and db.enabled and UnitExists("pet") and not UnitIsDead("pet")
  -- "Show only when hungry": hide the feed button once the pet is HAPPY
  -- (happiness >= 3), so it is only visible when there is something worth
  -- feeding for. Content is 2 and is deliberately still shown -- a content pet
  -- is exactly the one you feed to get it back to green.
  if show and db.hungryOnly then
    local h = GetPetHappiness()
    if h and h >= 3 then show = false end
  end
  ApplyVisibility(show)
  -- Icon + count refresh FIRST: whatever happens with the highlight below must
  -- never stop the button from showing the picked food and its amount.
  -- CPU: the full bag scan (PickFood) runs ONLY when something real changed
  -- (bags, pet, login, combat end, options) -- NOT on every UNIT_HEALTH tick,
  -- which fired the whole scan per damage event in combat before.
  if not InCombatLockdown() then
    if pending or bagsDirty then
      pending = false
      FeedPet:RefreshMacro()
    end
  else
    pending = true
  end
  -- Highlight rule (user): ON only when the pet is BELOW happy (content or
  -- unhappy) AND we are out of combat. Feeding is impossible in combat and a
  -- happy pet needs no attention, so glowing in those cases is just noise.
  -- The icon itself tints too: a 1-2px border alone proved too easy to miss
  -- (and the icon can never be nil, unlike anything created later).
  local h = GetPetHappiness()
  if h and h < 3 and not InCombatLockdown() then
    -- NEEDS FOOD: the icon lights up -- full brightness, full colour, plus
    -- the happiness-coloured border.
    local c = HAPPINESS_COLOR[h] or {1, 1, 1}
    if border then border:SetVertexColor(c[1], c[2], c[3], 1) end
    if iconTex then
      if iconTex.SetDesaturated then pcall(iconTex.SetDesaturated, iconTex, false) end
      iconTex:SetVertexColor(1, 1, 1, 1)
    end
  else
    -- Happy or in combat: the icon recedes -- desaturated + dimmed (uniform
    -- on any artwork, since the tint rides on greyscale), border hidden.
    if border then border:SetVertexColor(0, 0, 0, 0) end
    if iconTex then
      if iconTex.SetDesaturated then pcall(iconTex.SetDesaturated, iconTex, true) end
      iconTex:SetVertexColor(0.6, 0.6, 0.6, 1)
    end
  end
  -- Last, so it wins the count string: while the pet is eating the button shows
  -- the happiness per bite, and a refresh mid-feed must not put the count back.
  FeedPet.UpdateFeeding()
end

-- Update feed button visibility. Secure frames can't be shown/hidden from
-- tainted code while in combat, so we defer the change to the end of combat
-- (PLAYER_REGEN_ENABLED re-runs RefreshEverything). Also avoids the
-- ADDON_ACTION_BLOCKED taint on HunterKitFeedButton:SetShown().
ApplyVisibility = function(show)
  if InCombatLockdown() then return end   -- safe; re-applied on regen
  button:SetShown(show and true or false)
end

RefreshEverything = function()
  if not initialised then return end
  if HK.db.enabled == false or not HK.db.feed.enabled then
    ApplyVisibility(false)
    return
  end
  FeedPet:GetDiets()          -- cache / refresh diet list
  UpdateState()
end

function FeedPet.Refresh()
  bagsDirty = true      -- manual/options refresh: force the food rescan
  RefreshEverything()
end

OnBagUpdate = function()
  -- bags changed; that (and only that) triggers the full food rescan
  bagsDirty = true
  RefreshEverything()
end

-- ---------------------------------------------------------------------------
-- Right-click menu (pin / never on found foods)
-- ---------------------------------------------------------------------------
local menuFrame
function FeedPet:ShowMenu()
  if InCombatLockdown() then return end
  -- Toggle: if the menu is already open, right-clicking the icon again closes it.
  if menuFrame then
    menuFrame:Hide(); menuFrame = nil
    return
  end

  local food = self:PickFood()
  local petLevel = UnitLevel("pet") or UnitLevel("player")
  local items = {}
  for bag = 0, 4 do
    for slot = 1, HK.GetBagNumSlots(bag) do
      local itemID = HK.GetBagItemID(bag, slot)
      if itemID and not self:IsExcluded(itemID) and self:MatchesDiet(bag, slot, itemID)
         and not self:IsQuestItem(bag, slot, itemID) then
        local name = HK.GetItemInfo(itemID)
        local count = HK.GetBagItemCount(bag, slot)
        local _, _, _, iLevel = HK.GetItemInfo(itemID)
        if name and iLevel then
          items[#items + 1] = { id = itemID, name = name, count = count or 1, tier = TierFor(petLevel, iLevel) }
        end
      end
    end
  end

  menuFrame = CreateFrame("Frame", "HunterKitFeedMenu", UIParent)
  menuFrame:SetWidth(240)
  menuFrame:SetHeight(math.max(90, math.min(370, 18 + #items * 30)))
  menuFrame:SetPoint("RIGHT", button, "LEFT", -8, 0)
  menuFrame:SetFrameStrata("FULLSCREEN_DIALOG")
  menuFrame:SetClampedToScreen(true)

  local bg = menuFrame:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
  bg:SetVertexColor(0, 0, 0, 0.95)

  local title = menuFrame:CreateFontString(nil, "OVERLAY")
  title:SetPoint("TOPLEFT", 10, -8)
  title:SetFontObject(GameFontNormalLarge)
  title:SetText("Feed — click a food to pin/unpin")

  local y = -30
  for _, it in ipairs(items) do
    local row = CreateFrame("Button", nil, menuFrame)
    row:SetHeight(26)
    row:EnableMouse(true)
    row:SetPoint("TOPLEFT", 8, y)
    row:SetPoint("TOPRIGHT", -8, y)
    row:SetScript("OnClick", function(self, btn)
      if btn == "LeftButton" then
        -- click toggles: unpin a pinned food, pin an unpinned one. A pinned
        -- food is used *exclusively* (PickFood returns it first, overriding the
        -- best-food scan) — that's the quick way to force a specific food. The
        -- old behaviour called PinItem which early-returned if already pinned,
        -- so there was NO way to unpin from the menu; that's the fix.
        if FeedPet:IsPinned(it.id) then
          FeedPet:UnpinItem(it.id)
        else
          FeedPet:PinItem(it.id, it.name)
        end
        FeedPet:HideMenu()
      end
    end)
    local txt = row:CreateFontString(nil, "OVERLAY")
    txt:SetPoint("LEFT", 6, 0)
    txt:SetFontObject(GameFontNormal)
    txt:SetText(string.format("%s x%d  (%d/tick)", it.name, it.count, it.tier == 3 and 35 or (it.tier == 2 and 17 or 8)))
    local pin = row:CreateFontString(nil, "OVERLAY")
    pin:SetPoint("RIGHT", -8, 0)
    pin:SetFontObject(GameFontHighlight)
    -- show the actual action this row will take (pin / unpin)
    local pinned = FeedPet:IsPinned(it.id)
    pin:SetText(pinned and "UNPIN" or "Pin")
    pin:SetTextColor(pinned and 1 or 0.2, pinned and 0.3 or 1, 0.2)
    y = y - 30
  end

  if #items == 0 then
    local none = menuFrame:CreateFontString(nil, "OVERLAY")
    none:SetPoint("TOPLEFT", 10, -30)
    none:SetFontObject(GameFontNormal)
    none:SetText("No edible food in bags.")
  end

  menuFrame:SetScript("OnMouseDown", function(self, btn) if btn == "RightButton" then FeedPet:HideMenu() end end)
  menuFrame:SetScript("OnHide", function() menuFrame = nil end)
  menuFrame:Show()
end

function FeedPet:HideMenu()
  if menuFrame then menuFrame:Hide(); menuFrame = nil end
end

function FeedPet:IsPinned(itemID)
  for _, p in ipairs(db.preferredFoods) do if p.id == itemID then return true end end
  return false
end

function FeedPet:PinItem(itemID, name)
  for _, p in ipairs(db.preferredFoods) do if p.id == itemID then return end end
  table.insert(db.preferredFoods, { id = itemID, name = name })
end

function FeedPet:UnpinItem(itemID)
  local out = {}
  for _, p in ipairs(db.preferredFoods) do if p.id ~= itemID then out[#out+1] = p end end
  db.preferredFoods = out
end

function FeedPet:AddExclude(itemID, name)
  for _, e in ipairs(db.exclude) do if e.id == itemID then return end end
  table.insert(db.exclude, { id = itemID, name = name })
end

function FeedPet:RemoveExclude(itemID)
  local out = {}
  for _, e in ipairs(db.exclude) do if e.id ~= itemID then out[#out+1] = e end end
  db.exclude = out
end

function FeedPet:WarnTooltip(self)
  -- filled in via GameTooltip hook in Options if enabled
end

-- ---------------------------------------------------------------------------
-- Register with Core so HK:Load() runs our Init.
-- ---------------------------------------------------------------------------
HK.RegisterModule("FeedPet", { Init = FeedPet.Init })
