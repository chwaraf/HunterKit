--[[==============================================================================
 HunterKit — tests: Pet Mend Marker
 Loads the REAL Core.lua and MendMark.lua against tests/wow_stub.lua and asserts
 the behaviour the feature promises:

   * shows only with a live pet, a learned Mend Pet, and (by default) combat
   * green + solid when the pet is inside Mend Pet range
   * faded + greyed + red border when it is not
   * urgent (bigger, pulsing ring, "MEND!" label) at or below the HP threshold
   * anchors over the pet's head via the name plate when the client exposes one,
     falls back to the pet unit frame when it doesn't, and hides in "plate" mode
     when there is no plate to anchor to

 Run with tests/run_tests.py.
==============================================================================]]

local passes, failures = 0, {}

-- HKTest.say is the interpreter's print, i.e. it bypasses the stub's capture of
-- the addon's chat output.
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

local function near(a, b, eps)
  return type(a) == "number" and math.abs(a - b) <= (eps or 0.001)
end

-- ---------------------------------------------------------------------------
-- Boot the addon the way the client does
-- ---------------------------------------------------------------------------
local HK = HKTest.LoadAddon("../Core.lua", "../MendMark.lua")
HK:Load()

local marker = HKTest.MarkerFrame()
check("marker frame created on load", marker ~= nil)
check("module registered", HK.modules["MendMark"] ~= nil)
check("db.mend defaults merged", HK.db.mend ~= nil and HK.db.mend.enabled == true,
  HK.db.mend and tostring(HK.db.mend.enabled))
check("default low-HP threshold is 30%", HK.db.mend.hpThreshold == 30)
check("default anchor is auto", HK.db.mend.anchor == "auto")
check("db version migrated to 12", HK.db.dbVersion == 12, tostring(HK.db.dbVersion))

-- BuildFrame creates, in order: icon, ring, then HK.CreateBorder's four strips.
local function iconOf(f) return f.textures[1] end
local function ringOf(f) return f.textures[2] end
local function borderTex(f) return f.textures[3] end
local function labelOf(f) return f.fontstrings[1] end

-- ---------------------------------------------------------------------------
-- 1) Baseline: pet out, in combat, healthy, in range, no name plate
-- ---------------------------------------------------------------------------
HKTest.state.petHP = 550   -- 55%
HKTest.state.playerCombat, HKTest.state.petCombat = true, true
HKTest.state.plate = nil
HK.MendMark.Update()

check("shown with a live pet in combat", HK.MendMark.IsShown())
check("solid (alpha 1) when in range", near(marker:GetAlpha(), 1), marker:GetAlpha())
check("not greyed when in range", iconOf(marker).desaturated ~= true)
check("green border when in range", borderTex(marker).color[2] == 1 and borderTex(marker).color[1] == 0.2,
  borderTex(marker).color and table.concat(borderTex(marker).color, ","))
check("no label when healthy and in range", not labelOf(marker):IsShown())
check("ring hidden when not urgent", not ringOf(marker):IsShown())
check("scale 1 when not urgent", near(marker:GetScale(), 1), marker:GetScale())
check("falls back to the pet frame with no plate (even hidden)", HK.MendMark.AnchorMode() == "petframe",
  HK.MendMark.AnchorMode())
do
  local p = marker.points[1]
  check("anchored above the pet frame",
    p and p[1] == "BOTTOM" and p[2] == _G["PetFrame"] and p[3] == "TOP",
    p and tostring(p[1]) .. "/" .. tostring(p[3]))
  check("uses the saved height offset", p and p[5] == HK.db.mend.offsetY, p and tostring(p[5]))
end

-- The ticker must keep it alive (this is what tracks a moving pet).
local mendTicker
for _, t in ipairs(HKTest.tickers) do
  if near(t.interval, 0.10) then mendTicker = t end
end
check("0.10s ticker running", mendTicker ~= nil)
HKTest.state.petHP = 550
mendTicker:Tick()
check("ticker re-evaluates the marker", HK.MendMark.IsShown())

-- ---------------------------------------------------------------------------
-- 2) Out of range
-- ---------------------------------------------------------------------------
HKTest.state.spellInRange = 0
HK.MendMark.Update()
check("still shown when out of range", HK.MendMark.IsShown())
check("faded when out of range", near(marker:GetAlpha(), 0.45), marker:GetAlpha())
check("greyed when out of range", iconOf(marker).desaturated == true)
check("red border when out of range", borderTex(marker).color[1] == 1 and borderTex(marker).color[2] == 0.15)
check("'TOO FAR' label when out of range", labelOf(marker):GetText() == "TOO FAR", labelOf(marker):GetText())

-- fading is optional
HK.db.mend.dimWhenFar = false
HK.MendMark.Update()
check("fade is optional (alpha 1 when off)", near(marker:GetAlpha(), 1), marker:GetAlpha())
HK.db.mend.dimWhenFar = true
HKTest.state.spellInRange = 1
HK.MendMark.Update()

-- ---------------------------------------------------------------------------
-- 3) Urgent: pet below the low-HP threshold
-- ---------------------------------------------------------------------------
HKTest.state.petHP = 200    -- 20%
HK.MendMark.Update()
HKTest.Animate(1, 0.1)
check("urgent ring shown below threshold", ringOf(marker):IsShown())
check("marker grows when urgent", marker:GetScale() > 1, marker:GetScale())
check("'MEND!' label when urgent", labelOf(marker):GetText() == "MEND!", labelOf(marker):GetText())
check("urgent label is orange/red", labelOf(marker).textColor[1] == 1)

-- the threshold is inclusive: exactly 30% counts as urgent
HKTest.state.petHP = 300
HK.MendMark.Update()
HKTest.Animate(1, 0.1)
check("exactly at threshold is urgent", ringOf(marker):IsShown())
-- 31% is not
HKTest.state.petHP = 310
HK.MendMark.Update()
HKTest.Animate(1, 0.1)
check("above threshold is not urgent", not ringOf(marker):IsShown())
check("scale resets when no longer urgent", near(marker:GetScale(), 1), marker:GetScale())

-- a custom threshold is honoured
HK.db.mend.hpThreshold = 50
HKTest.state.petHP = 450
HK.MendMark.Update()
HKTest.Animate(1, 0.1)
check("custom threshold honoured (45% <= 50%)", ringOf(marker):IsShown())
HK.db.mend.hpThreshold = 30
HK.MendMark.Update()

-- urgent beats "only in combat": a hurt pet shows out of combat too
HKTest.state.petHP = 200
HKTest.state.playerCombat, HKTest.state.petCombat = false, false
HK.MendMark.Update()
check("hurt pet shows out of combat", HK.MendMark.IsShown())
-- the pulse can be switched off
HK.db.mend.urgentPulse = false
HKTest.Animate(1, 0.1)
check("pulse can be disabled", not ringOf(marker):IsShown() and near(marker:GetScale(), 1))
HK.db.mend.urgentPulse = true
HKTest.state.petHP = 550

-- hidden mid-pulse must unwind the animation, not come back grown
HKTest.state.playerCombat = true
HKTest.state.petHP = 150
HK.MendMark.Update()
HKTest.Animate(1, 0.1)
check("scaled up while urgent", marker:GetScale() > 1, marker:GetScale())
HKTest.state.pet = false
HK.MendMark.Update()
check("hidden mid-pulse resets the scale", near(marker:GetScale(), 1), marker:GetScale())
check("hidden mid-pulse hides the ring", not ringOf(marker):IsShown())
HKTest.state.pet = true
HKTest.state.petHP = 550
HK.MendMark.Update()

-- ---------------------------------------------------------------------------
-- 4) Visibility gates
-- ---------------------------------------------------------------------------
HKTest.state.playerCombat, HKTest.state.petCombat = false, false
HK.MendMark.Update()
check("hidden out of combat when healthy", not HK.MendMark.IsShown())

HKTest.state.playerCombat = true
HK.db.mend.combatOnly = false
HK.MendMark.Update()
check("shown out of combat when 'only in combat' is off", HK.MendMark.IsShown())
HK.db.mend.combatOnly = true

HK.db.mend.enabled = false
HK.MendMark.Update()
check("hidden when the feature is disabled", not HK.MendMark.IsShown())
HK.db.mend.enabled = true
HK.MendMark.Update()

HK.db.enabled = false
HK.MendMark.Update()
check("hidden when the master switch is off", not HK.MendMark.IsShown())
HK.db.enabled = true
HK.MendMark.Update()

HKTest.state.pet = false
HK.MendMark.Update()
check("hidden with no pet", not HK.MendMark.IsShown())
HKTest.state.pet = true

HKTest.state.petDead = true
HK.MendMark.Update()
check("hidden with a dead pet", not HK.MendMark.IsShown())
HKTest.state.petDead = false
HK.MendMark.Update()
check("shown again once the pet is alive", HK.MendMark.IsShown())

-- Mend Pet not learned yet -> nothing to indicate
HKTest.state.spellName = nil
HK.MendMark.Update()
check("hidden when Mend Pet is not learned", not HK.MendMark.IsShown())

-- learning it (SPELLS_CHANGED clears the cached name) must bring it back
HKTest.state.spellName = "Mend Pet"
HKTest.Fire("SPELLS_CHANGED")
check("SPELLS_CHANGED picks up a newly trained Mend Pet", HK.MendMark.IsShown())

-- UNIT_HEALTH is the event that drives the urgent switch
HKTest.state.petHP = 900
HKTest.Fire("UNIT_HEALTH", "pet")
check("UNIT_HEALTH(pet) refreshes the marker", not ringOf(marker):IsShown())
HKTest.state.petHP = 100
HKTest.Fire("UNIT_HEALTH", "pet")
HKTest.Animate(1, 0.1)
check("UNIT_HEALTH(pet) flips it to urgent", ringOf(marker):IsShown())
HKTest.state.petHP = 550
HKTest.Fire("UNIT_HEALTH", "pet")

-- ---------------------------------------------------------------------------
-- 4b) Edit mode (/htk unlock) previews it so the sliders can be tuned
-- ---------------------------------------------------------------------------
HKTest.state.playerCombat, HKTest.state.petCombat = false, false
HKTest.state.petHP = 1000
HK.Positions = { locked = false }
HK.MendMark.Update()
check("edit mode shows it out of combat and healthy", HK.MendMark.IsShown())
HK.Positions = { locked = true }
HK.MendMark.Update()
check("locking again hides it", not HK.MendMark.IsShown())
HKTest.state.pet = false
HK.Positions = { locked = false }
HK.MendMark.Update()
check("edit mode previews it with no pet out", HK.MendMark.IsShown())
HK.Positions = { locked = true }
HKTest.state.pet = true
HKTest.state.playerCombat = true
HK.MendMark.Update()

-- ---------------------------------------------------------------------------
-- 5) Anchoring: name plate (world) vs pet frame (UI fallback)
-- ---------------------------------------------------------------------------
local plate = CreateFrame("Frame", "TestPetNamePlate", UIParent)
plate:SetSize(100, 40)
HKTest.state.plate = plate
HK.MendMark.Update()
check("anchors over the head when a plate exists", HK.MendMark.AnchorMode() == "plate",
  HK.MendMark.AnchorMode())
do
  local p = marker.points[1]
  check("marker sits above the plate", p and p[1] == "BOTTOM" and p[2] == plate and p[3] == "TOP")
end

-- a plate frame the client is recycling (hidden) must not be used
plate:Hide()
HK.MendMark.Update()
check("ignores a hidden plate frame", HK.MendMark.AnchorMode() == "petframe",
  HK.MendMark.AnchorMode())
plate:Show()

-- "plate" mode with no plate available stays hidden instead of moving
HK.db.mend.anchor = "plate"
HKTest.state.plate = nil
HK.MendMark.Update()
check("'plate' mode hides with no plate", not HK.MendMark.IsShown())
check("'plate' mode reports anchor=none", HK.MendMark.AnchorMode() == "none")
HKTest.state.plate = plate
HK.MendMark.Update()
check("'plate' mode shows with a plate", HK.MendMark.IsShown())

-- "petframe" mode never uses the plate
HK.db.mend.anchor = "petframe"
HK.MendMark.Update()
check("'petframe' mode ignores the plate", HK.MendMark.AnchorMode() == "petframe",
  HK.MendMark.AnchorMode())
HK.db.mend.anchor = "auto"
HKTest.state.plate = nil

-- ---------------------------------------------------------------------------
-- 5b) Finding the plate: event cache, scan, and the opt-in CVar ladder
-- ---------------------------------------------------------------------------
HKTest.state.playerCombat = true
HKTest.state.petHP = 1000
HKTest.state.plate = nil
HKTest.state.scanPlate = nil
HKTest.TickMarker(1)

local evtPlate = CreateFrame("Frame", "EventPetPlate", UIParent)
evtPlate:SetSize(100, 40)
HKTest.Fire("NAME_PLATE_UNIT_ADDED", "pet", evtPlate)
check("uses the plate from NAME_PLATE_UNIT_ADDED", HK.MendMark.AnchorMode() == "plate",
  HK.MendMark.AnchorMode())
HKTest.Fire("NAME_PLATE_UNIT_REMOVED", "pet")
HKTest.TickMarker(1)
check("drops it on NAME_PLATE_UNIT_REMOVED", HK.MendMark.AnchorMode() == "petframe",
  HK.MendMark.AnchorMode())

local scanPlate = CreateFrame("Frame", "ScannedPetPlate", UIParent)
scanPlate:SetSize(100, 40)
scanPlate.namePlateUnitToken = "pet"
HKTest.state.scanPlate = scanPlate
HKTest.TickMarker(1)
check("finds the pet plate via C_NamePlate.GetNamePlates()",
  HK.MendMark.AnchorMode() == "plate", HK.MendMark.AnchorMode())
HKTest.state.scanPlate = nil
HKTest.TickMarker(1)

-- opt-in CVar ladder: nothing is touched until the player asks for it
check("forcePlate is off by default", HK.db.mend.forcePlate == false)
check("no nameplate cvars touched by default", next(HK.db.mend.plateCVars) == nil)
HK.db.mend.forcePlate = true
HK.MendMark.RescanSettings()
check("forcePlate waits before touching cvars",
  HKTest.state.cvars.nameplateShowFriendlyPets == "0")
HKTest.TickMarker(10)
check("forcePlate turns on the pet-nameplate cvar",
  HKTest.state.cvars.nameplateShowFriendlyPets == "1")
check("previous cvar value saved for restore",
  HK.db.mend.plateCVars.nameplateShowFriendlyPets == "0",
  tostring(HK.db.mend.plateCVars.nameplateShowFriendlyPets))
check("marker then anchors over the pet's head",
  HK.MendMark.AnchorMode() == "plate", HK.MendMark.AnchorMode())

-- combat locks CVars: the ladder must wait, not error
HK.db.mend.forcePlate = false
HK.MendMark.RescanSettings()
HKTest.state.combatLockdown = true
HK.db.mend.forcePlate = true
HK.MendMark.RescanSettings()
HKTest.TickMarker(30)
check("cvars untouched while in combat lockdown",
  HKTest.state.cvars.nameplateShowFriendlyPets == "0")
HKTest.state.combatLockdown = false
HK.db.mend.forcePlate = false
HK.MendMark.RescanSettings()
HKTest.TickMarker(1)

-- escalation: pet CVar alone is not enough on this (modelled) client
HKTest.state.petPlateNeedsFriends = true
HK.db.mend.forcePlate = true
HK.MendMark.RescanSettings()
HKTest.TickMarker(10)
check("ladder step 1 alone leaves it on the pet frame",
  HK.MendMark.AnchorMode() == "petframe", HK.MendMark.AnchorMode())
HKTest.TickMarker(10)
-- rung 2 is the friendly-minions CVar: that (together with friendly) is what
-- publishes a pet plate on Classic Era, and it is still not enough alone here.
check("ladder rung 2 is nameplateShowFriendlyMinions",
  HKTest.state.cvars.nameplateShowFriendlyMinions == "1",
  tostring(HKTest.state.cvars.nameplateShowFriendlyMinions))
check("minions alone still leaves it on the pet frame",
  HK.MendMark.AnchorMode() == "petframe", HK.MendMark.AnchorMode())
HKTest.TickMarker(10)
check("ladder escalates to nameplateShowFriends",
  HKTest.state.cvars.nameplateShowFriends == "1")
check("world anchoring after escalation",
  HK.MendMark.AnchorMode() == "plate", HK.MendMark.AnchorMode())
HKTest.TickMarker(30)
check("ladder stops once a pet plate exists",
  HKTest.state.cvars.nameplateShowAll == "0", tostring(HKTest.state.cvars.nameplateShowAll))
HK.db.mend.forcePlate = false
HK.MendMark.RescanSettings()
check("unticking restores every cvar it touched",
  HKTest.state.cvars.nameplateShowFriendlyPets == "0"
    and HKTest.state.cvars.nameplateShowFriendlyMinions == "0"
    and HKTest.state.cvars.nameplateShowFriends == "0",
  HKTest.state.cvars.nameplateShowFriendlyPets .. "/"
    .. HKTest.state.cvars.nameplateShowFriendlyMinions .. "/"
    .. HKTest.state.cvars.nameplateShowFriends)
check("saved cvar list cleared after restore", next(HK.db.mend.plateCVars) == nil)
HKTest.state.petPlateNeedsFriends = false
HKTest.TickMarker(1)

-- the ladder must not climb just because the pet went away
HKTest.state.pet = false
HK.db.mend.forcePlate = true
HK.MendMark.RescanSettings()
HKTest.TickMarker(30)
check("ladder idle with no pet out", HKTest.state.cvars.nameplateShowFriendlyPets == "0",
  HKTest.state.cvars.nameplateShowFriendlyPets)
HKTest.state.pet = true
HK.db.mend.forcePlate = false
HK.MendMark.RescanSettings()
HKTest.TickMarker(1)

-- logout puts the CVars back even while the option stays on (session-scoped)
HK.db.mend.forcePlate = true
HK.MendMark.RescanSettings()
HKTest.TickMarker(10)
check("forced before logout", HKTest.state.cvars.nameplateShowFriendlyPets == "1")
HKTest.Fire("PLAYER_LOGOUT")
check("PLAYER_LOGOUT restores the cvars", HKTest.state.cvars.nameplateShowFriendlyPets == "0",
  HKTest.state.cvars.nameplateShowFriendlyPets)
HK.db.mend.forcePlate = false
HKTest.TickMarker(1)

-- a client that rejects the SetCVar itself must not loop or error
HK.db.mend.plateCVars["nameplateShowFriendlyPets"] = "0"
local realSet = SetCVar
SetCVar = function(n, v) error("SetCVar is blocked") end
HK.MendMark.RescanSettings()
HKTest.TickMarker(3)
check("survives a blocked SetCVar", HK.MendMark.IsShown())
check("kept the saved value for a later retry",
  HK.db.mend.plateCVars.nameplateShowFriendlyPets == "0",
  tostring(HK.db.mend.plateCVars.nameplateShowFriendlyPets))
SetCVar = realSet
HK.MendMark.RescanSettings()
check("restores once SetCVar works again",
  HK.db.mend.plateCVars.nameplateShowFriendlyPets == nil
    and HKTest.state.cvars.nameplateShowFriendlyPets == "0")

-- a client with none of those CVars must not error out
local realCVars = HKTest.state.cvars
HKTest.state.cvars = {}
HK.db.mend.forcePlate = true
HK.MendMark.RescanSettings()
HKTest.TickMarker(30)
check("survives a client with no nameplate cvars", HK.MendMark.IsShown())
HKTest.state.cvars = realCVars
HK.db.mend.forcePlate = false
HK.MendMark.RescanSettings()
HKTest.TickMarker(1)

-- ---------------------------------------------------------------------------
-- 5c) Nameplate-style widget (fallback only)
-- ---------------------------------------------------------------------------
local widget = HKTest.PlateWidget()
check("nameplate-style widget exists", widget ~= nil)
HKTest.state.plate = nil
HK.db.mend.plateStyle = true
HKTest.state.petHP = 1000
HK.MendMark.Update()
check("widget shown in the pet-frame fallback", widget:IsShown())
check("widget shows the pet's name", widget.fontstrings[1]:GetText() == "Fang",
  widget.fontstrings[1]:GetText())
HKTest.state.petHP = 500
HK.MendMark.Update()
local barFull = widget.textures[2]:GetWidth()
local barNow = widget.textures[3]:GetWidth()
check("widget HP bar tracks pet health", barNow < barFull and barNow > 0,
  tostring(barNow) .. "/" .. tostring(barFull))
HKTest.state.plate = plate
HK.MendMark.Update()
check("widget hidden when anchored to a real plate", not widget:IsShown())
HKTest.state.plate = nil
HK.db.mend.plateStyle = false
HK.MendMark.Update()
check("widget can be switched off", not widget:IsShown())
HK.db.mend.plateStyle = true
HK.MendMark.Update()

-- ---------------------------------------------------------------------------
-- 5d) Non-nameplate world anchoring paths
-- ---------------------------------------------------------------------------
-- legacy layout: a NamePlateN child of WorldFrame carrying unit = "pet"
local legacyUnitFrame = CreateFrame("Frame", nil, nil)
legacyUnitFrame.unit = "pet"
local legacyPlate = CreateFrame("Frame", "NamePlate7", WorldFrame)
legacyPlate:SetSize(100, 40)
function legacyPlate:GetChildren() return legacyUnitFrame end
HKTest.state.plate = nil
HKTest.TickMarker(1)
check("finds the pet through the legacy NamePlateN scan",
  HK.MendMark.AnchorMode() == "plate", HK.MendMark.AnchorMode())
-- retire it (the stub keeps every frame it ever created)
legacyPlate.name = "RetiredPlate7"
HKTest.TickMarker(1)
check("stops using a plate that is no longer a NamePlateN",
  HK.MendMark.AnchorMode() == "petframe", HK.MendMark.AnchorMode())

-- a direct screen-position API needs no plate at all
_G["GetUnitNamePosition"] = function(u)
  if u ~= "pet" then return nil end
  return HKTest.state.screenPos and 900, 400 or nil
end
HKTest.state.screenPos = true
HKTest.TickMarker(1)
check("uses a screen-position API when the client has one",
  HK.MendMark.AnchorMode() == "screen", HK.MendMark.AnchorMode())
check("reports which API produced it", HK.MendMark.AnchorSource() == "GetUnitNamePosition",
  tostring(HK.MendMark.AnchorSource()))
do
  local p = marker.points[1]
  -- 400px down from the top of a 1080-high screen = 680 up from the bottom,
  -- plus the user's "height above head" offset.
  check("converts screen coords to a UIParent anchor",
    p and p[1] == "BOTTOM" and p[2] == UIParent and p[3] == "BOTTOMLEFT"
      and near(p[5], 680 + HK.db.mend.offsetY),
    p and tostring(p[5]))
end
_G["GetUnitNamePosition"] = nil
HKTest.state.screenPos = nil
HKTest.TickMarker(1)
check("falls back when the API stops answering",
  HK.MendMark.AnchorMode() == "petframe", HK.MendMark.AnchorMode())
check("stale screen-source is cleared", HK.MendMark.AnchorSource() == nil,
  tostring(HK.MendMark.AnchorSource()))

-- capability report names the paths it tried
local caps = HK.MendMark.Capabilities()
check("capability report covers screen-pos APIs", caps:find("GetUnitNamePosition=absent") ~= nil, caps)
check("capability report covers plate discovery", caps:find("GetNamePlateForUnit=") ~= nil)
check("capability report covers UnitPosition(pet)", caps:find("UnitPosition%(pet%)=") ~= nil)

-- ---------------------------------------------------------------------------
-- 5e) The 1.15.9 case: no plate, no screen API, no usable CVar
-- ---------------------------------------------------------------------------
local fullCVars = HKTest.state.cvars
HKTest.state.cvars = { nameplateShowAll = "1", nameplateShowEnemies = "1", nameplateMaxDistance = "41" }
HKTest.state.plate = nil
HKTest.state.playerCombat, HKTest.state.petCombat = false, false
HKTest.state.petHP = 1000
HK.MendMark.Update()
check("hidden out of combat with a healthy pet", not HK.MendMark.IsShown())
check("hidden reason explains it",
  (HK.MendMark.HiddenReason() or ""):find("out of combat") ~= nil,
  tostring(HK.MendMark.HiddenReason()))
do
  HKTest.prints = {}
  pcall(SlashCmdList["HUNTERKIT"], "mend")
  local all = table.concat(HKTest.prints, "\n")
  check("report resolves the anchor while hidden",
    all:find("anchor would be: petframe") ~= nil, all)
  check("report prints the hidden reason", all:find("hidden because:") ~= nil)
  check("report says head anchoring is unavailable on this client",
    all:find("not%s+available here") ~= nil or all:find("not available here") ~= nil, all)
  check("report lists every nameplate cvar the client has",
    all:find("nameplateMaxDistance=41") ~= nil, all)
  check("report does not suggest force-plate when it cannot help",
    all:find("Force pet name plate' %(1 CVar") == nil and all:find("Tick Options") == nil, all)
end
check("no ladder rung is usable on that client", HK.MendMark.LadderCVarsUsable() == 0,
  tostring(HK.MendMark.LadderCVarsUsable()))

-- with a usable rung available, it does suggest the option
HKTest.state.cvars.nameplateShowFriends = "0"
check("a usable rung is counted", HK.MendMark.LadderCVarsUsable() == 1)
HKTest.prints = {}
pcall(SlashCmdList["HUNTERKIT"], "mend")
check("report suggests force-plate when a rung exists",
  table.concat(HKTest.prints, "\n"):find("Tick Options") ~= nil)
HKTest.state.cvars = fullCVars

-- ---------------------------------------------------------------------------
-- 5f) Dragging the UI fallback somewhere useful
-- ---------------------------------------------------------------------------
HKTest.state.playerCombat = true
HK.db.mend.moved = true
HK.db.mend.pinX, HK.db.mend.pinY = -200, 60
HK.MendMark.Update()
do
  local p = marker.points[1]
  check("dragged marker pins to an absolute screen spot",
    p and p[1] == "CENTER" and p[2] == UIParent and p[3] == "CENTER"
      and p[4] == -200 and p[5] == 60,
    p and (tostring(p[1]) .. " " .. tostring(p[4]) .. "," .. tostring(p[5])))
end
check("registered as draggable", HK.draggables["mend"] ~= nil)
HK.db.mend.moved = false
HK.MendMark.Update()
do
  local p = marker.points[1]
  check("undragged marker returns to the pet frame",
    p and p[1] == "BOTTOM" and p[2] == _G["PetFrame"], p and tostring(p[1]))
end

-- Every registered draggable must have callbacks that actually RUN. This is
-- what Options.SetLock/Reset invokes, and a closure that references a local
-- declared later in the chunk compiles to a nil global — which is exactly how
-- /htk reset produced "attempt to call a nil value" on the live client.
for key, d in pairs(HK.draggables) do
  local ok, err = pcall(function()
    if d.apply then d.apply() end
    if d.save then d.save(0, 0) end
    if d.opts then
      if d.opts.restore then d.opts.restore() end
      if d.opts.onUpdate then d.opts.onUpdate() end
      if d.opts.saveFromScreen then d.opts.saveFromScreen() end
    end
  end)
  check("draggable '" .. key .. "' callbacks all run", ok, err)
end
check("saveFromScreen stored a pinned position",
  HK.db.mend.moved == true and type(HK.db.mend.pinX) == "number",
  tostring(HK.db.mend.pinX))
HK.db.mend.moved = false
HK.MendMark.Update()

-- the real Reset path from Options.lua: iterate the draggables and call apply
do
  local ok, err = pcall(function()
    for _, d in pairs(HK.draggables) do
      if d.apply then d.apply() end
    end
  end)
  check("Options-style Reset apply() loop runs", ok, err)
end

-- ---------------------------------------------------------------------------
-- 5g) Restricted regions: a plate-anchored marker must not be lock/unlock-touched
-- ---------------------------------------------------------------------------
-- Only the UI fallback is the player's to move.
HKTest.state.plate = nil
HKTest.state.playerCombat = true
HK.MendMark.Update()
check("draggable while on the UI fallback",
  HK.DraggableActive(HK.draggables["mend"]) == true)
HKTest.state.plate = plate
HK.MendMark.Update()
check("not draggable while over the pet's head",
  HK.DraggableActive(HK.draggables["mend"]) == false,
  tostring(HK.DraggableActive(HK.draggables["mend"])))
_G["GetUnitNamePosition"] = function(u) if u == "pet" then return 900, 400 end end
HKTest.state.plate = nil
HK.MendMark.Update()
check("not draggable while on a screen-position anchor",
  HK.DraggableActive(HK.draggables["mend"]) == false)
_G["GetUnitNamePosition"] = nil
HK.MendMark.Update()

-- A plate-anchored frame refuses SetClampedToScreen; HK.SafeClamp must absorb it.
HKTest.state.plate = plate
HK.MendMark.Update()
marker.restricted = true
do
  local ok, err = pcall(marker.SetClampedToScreen, marker, true)
  check("stub reproduces the client's restricted-region error", not ok, err)
  check("HK.SafeClamp absorbs it", HK.SafeClamp(marker, true) == false)
end

-- The SetLock guard, using the same helpers Options.lua calls: skip the frame
-- entirely when it isn't draggable, and never clamp it unguarded.
marker.movable = "untouched"
for _, unlock in ipairs({ true, false }) do
  local ok, err = pcall(function()
    for key, d in pairs(HK.draggables) do
      local f = d.frame
      if f and not HK.DraggableActive(d) then f = nil end
      if f then
        f:SetMovable(unlock)
        f:EnableMouse(unlock)
        HK.SafeClamp(f, true)
      end
    end
  end)
  check("SetLock guard survives a restricted marker (unlock=" .. tostring(unlock) .. ")", ok, err)
end
check("restricted marker was skipped, not touched", marker.movable == "untouched",
  tostring(marker.movable))
marker.movable = nil
marker.restricted = nil
HKTest.state.plate = nil
HK.MendMark.Update()

-- ---------------------------------------------------------------------------
-- 5h) forcePlate gives up honestly instead of doing nothing forever
-- ---------------------------------------------------------------------------
-- Model a client where NO rung produces a pet plate: the friendly CVars exist
-- (so the ladder can enable them) but nothing comes of it. The option must then
-- restore the CVars, switch itself off and say so once -- not hold the player's
-- nameplate settings hostage while silently doing nothing.
do
  local savedCVars = HKTest.state.cvars
  HKTest.state.cvars = {
    -- no nameplateShowFriendlyPets: this client does not have the pet-only rung
    nameplateShowAll = "1", nameplateShowEnemies = "1", nameplateMaxDistance = "41",
    nameplateShowFriends = "0", nameplateShowFriendlyMinions = "0",
  }
  HKTest.state.plate, HKTest.state.scanPlate = nil, nil
  HKTest.state.pet = true
  HKTest.state.combatLockdown = false
  HK.db.mend.forcePlate = true
  HK.MendMark.RescanSettings()
  HKTest.prints = {}

  HKTest.TickMarker(35)                  -- ~3.5s: the ladder has climbed
  check("the ladder enabled the friendly rung",
    HKTest.state.cvars.nameplateShowFriends == "1",
    tostring(HKTest.state.cvars.nameplateShowFriends))
  check("it stays on while it is still trying", HK.db.mend.forcePlate == true)

  HKTest.TickMarker(85)                  -- the grace period after the last rung
  check("forcePlate switched itself off when it could not help",
    HK.db.mend.forcePlate == false, tostring(HK.db.mend.forcePlate))
  check("the nameplate cvars were put back",
    HKTest.state.cvars.nameplateShowFriends == "0"
      and HKTest.state.cvars.nameplateShowFriendlyMinions == "0",
    tostring(HKTest.state.cvars.nameplateShowFriends) .. "/"
      .. tostring(HKTest.state.cvars.nameplateShowFriendlyMinions))
  check("the saved cvar list was cleared", next(HK.db.mend.plateCVars) == nil)

  local said = 0
  for _, line in ipairs(HKTest.prints) do
    if line:find("switched itself off") then said = said + 1 end
  end
  check("it explained itself", said == 1, tostring(said))
  HKTest.TickMarker(100)
  said = 0
  for _, line in ipairs(HKTest.prints) do
    if line:find("switched itself off") then said = said + 1 end
  end
  check("it says it once, not every tick", said == 1, tostring(said))
  HKTest.state.cvars = savedCVars
end

-- ---------------------------------------------------------------------------
-- 6) Diagnostics + slash command must not error
-- ---------------------------------------------------------------------------
HKTest.prints = {}
local ok, err = pcall(SlashCmdList["HUNTERKIT"], "mend")
check("/htk mend runs without error", ok, err)
check("/htk mend prints a diagnostic", HKTest.prints[1] ~= nil and HKTest.prints[1]:find("Mend Marker") ~= nil,
  HKTest.prints[1])
local diag = HK.MendMark.Diagnostic()
check("diagnostic reports the range state", diag:find("inRange=true") ~= nil, diag)
check("diagnostic reports the anchor mode", diag:find("mode=petframe") ~= nil, diag)
check("plate cvars are readable", HK.MendMark.PlateCVars():find("nameplateShowFriends=") ~= nil)

HKTest.prints = {}
ok, err = pcall(HK.SelfCheck, HK)
check("/htk selfcheck runs without error", ok, err)
local foundMendProbe = false
for _, line in ipairs(HKTest.prints) do
  if line:find("mend marker") then foundMendProbe = true end
end
check("selfcheck has a mend marker probe", foundMendProbe)

HKTest.prints = {}
ok, err = pcall(SlashCmdList["HUNTERKIT"], "help")
check("/htk help runs without error", ok, err)
local foundHelpLine = false
for _, line in ipairs(HKTest.prints) do
  if line:find("/htk mend") then foundHelpLine = true end
end
check("help lists /htk mend", foundHelpLine)

-- ---------------------------------------------------------------------------
say(string.format("\n%d passed, %d failed", passes, #failures))
if #failures > 0 then
  for _, f in ipairs(failures) do say("  - " .. f) end
  error(#failures .. " test(s) failed")
end
