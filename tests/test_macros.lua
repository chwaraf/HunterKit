--[[============================================================================
 HunterKit — tests: the macro library (Macros.lua)

 These are text we hand the player to paste into their macro frame, so the tests
 are about the TEXT being correct and safe, not about widgets. A wrong macro is
 worse than no macro: it looks authoritative and misbehaves in combat.
==============================================================================]]
local HK = HKTest.LoadAddon(unpack(HKTest.addonFiles))
HKTest.state.isHunter = true
HK:Load()

local passes, failures = 0, {}
local function say(s) print(s) end
local function check(name, ok, detail)
  if ok then
    passes = passes + 1
    say("  ok   " .. name)
  else
    failures[#failures + 1] = name .. (detail and (" — " .. detail) or "")
    say("  FAIL " .. name .. (detail and (" — " .. detail) or ""))
  end
end

local M = HK.Macros
check("the macro library loaded", M ~= nil)
check("it has macros in it", M.Count() > 0, tostring(M.Count()))

-- ---------------------------------------------------------------------------
-- Every macro is complete and explained
-- ---------------------------------------------------------------------------
for i = 1, M.Count() do
  local e = M.Entry(i)
  local tag = "#" .. i .. " " .. tostring(e and e.title)
  check(tag .. ": has a title",
    type(e.title) == "string" and #e.title > 0)
  check(tag .. ": has a body",
    type(e.body) == "string" and #e.body > 0)
  check(tag .. ": has an explanation",
    type(e.note) == "string" and #e.note > 20)
  -- Macros have a hard 255-character limit in the client.
  check(tag .. ": fits the client's 255-char macro limit",
    #e.body <= 255, tostring(#e.body))
  -- Leading/trailing whitespace survives a copy and breaks the first command.
  check(tag .. ": no stray leading or trailing whitespace",
    e.body == e.body:match("^%s*(.-)%s*$"))
end

-- ---------------------------------------------------------------------------
-- NOTHING MAY TARGET OR ATTACK A CORPSE
--
-- Regression: the two-mob weave macro ended with a bare `/targetlasttarget`.
-- When the melee mob died, the macro correctly flicked to the pet's live mob to
-- shoot it -- and then that last unconditional line flicked straight back onto
-- the corpse. You were left targeting a dead mob and swinging at it.
--
-- Any command that picks a target or starts an attack must therefore say what
-- it does about dead units: either it requires `nodead`, or it handles `dead`
-- explicitly (e.g. `/cleartarget [dead]`).
-- ---------------------------------------------------------------------------
local TARGETING = { "/target", "/targetlasttarget", "/startattack",
                    "/petattack", "/targetenemy", "/assist" }

local function IsTargeting(line)
  for _, cmd in ipairs(TARGETING) do
    -- match the command followed by end-of-line or a space, so /targetlasttarget
    -- is not mistaken for /target.
    if line == cmd or line:sub(1, #cmd + 1) == cmd .. " " then return true end
  end
  return false
end

local offenders = {}
for i = 1, M.Count() do
  local e = M.Entry(i)
  for line in (e.body .. "\n"):gmatch("(.-)\n") do
    local l = line:match("^%s*(.-)%s*$")
    if IsTargeting(l) and not l:find("dead", 1, true) then
      offenders[#offenders + 1] = e.title .. ": " .. l
    end
  end
end
check("no macro targets or attacks without considering dead units",
  #offenders == 0, table.concat(offenders, " | "))

-- The specific shape that bit: a bare `/targetlasttarget` with no conditions.
local bare = {}
for i = 1, M.Count() do
  local e = M.Entry(i)
  for line in (e.body .. "\n"):gmatch("(.-)\n") do
    local l = line:match("^%s*(.-)%s*$")
    if l == "/targetlasttarget" then bare[#bare + 1] = e.title end
  end
end
check("no macro ends up back on the corpse via a bare /targetlasttarget",
  #bare == 0, table.concat(bare, ","))

-- ---------------------------------------------------------------------------
-- Auto Shot cannot be redirected with [@unit]
--
-- Auto Shot always fires at your REAL target; an [@unit] clause on it looks
-- like it retargets and does not. Every reference macro in the community guides
-- uses a bare `/cast !Auto Shot` and switches target instead.
-- ---------------------------------------------------------------------------
local misaimed = {}
for i = 1, M.Count() do
  local e = M.Entry(i)
  for line in (e.body .. "\n"):gmatch("(.-)\n") do
    local l = line:match("^%s*(.-)%s*$")
    if l:lower():find("auto shot", 1, true) and l:find("@", 1, true) then
      misaimed[#misaimed + 1] = e.title .. ": " .. l
    end
  end
end
check("no macro pretends to aim Auto Shot with [@unit]",
  #misaimed == 0, table.concat(misaimed, " | "))

-- ---------------------------------------------------------------------------
-- THE TWO-MOB WEAVE MUST DEGRADE TO PLAIN MELEE
--
-- With no pet target there is nothing to shoot, so the macro must simply swing
-- and stop -- not flick the target around, and not start Auto Shot on whatever
-- happens to be selected. `/stopmacro` is what makes that work: everything
-- ranged lives BELOW it, so the bail-out has to come after the melee line and
-- before the first target switch.
-- ---------------------------------------------------------------------------
local weave
for i = 1, M.Count() do
  local e = M.Entry(i)
  if e.title:find("Two%-mob weave") then weave = e end
end
check("the two-mob weave macro exists", weave ~= nil)

if weave then
  local lines = {}
  for line in (weave.body .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line:match("^%s*(.-)%s*$")
  end
  local function IndexOf(pattern)
    for i, l in ipairs(lines) do
      if l:find(pattern) then return i end
    end
    return nil
  end

  local iMelee   = IndexOf("^/startattack")
  local iStop    = IndexOf("^/stopmacro")
  local iSwitch  = IndexOf("^/target ")
  local iShot    = IndexOf("Auto Shot")
  local iBack    = IndexOf("^/targetlasttarget")

  check("it starts your melee swing", iMelee ~= nil)
  check("it can bail out early", iStop ~= nil)
  check("...bailing out only AFTER the melee swing has started",
    iMelee and iStop and iStop > iMelee,
    string.format("melee at %s, stopmacro at %s", tostring(iMelee), tostring(iStop)))
  check("...and BEFORE anything touches your target",
    iStop and iSwitch and iStop < iSwitch,
    string.format("stopmacro at %s, first /target at %s",
      tostring(iStop), tostring(iSwitch)))
  check("...and before Auto Shot", iStop and iShot and iStop < iShot)
  check("...and before the flick back", iStop and iBack and iStop < iBack)

  -- The bail-out has to cover every "no usable pet target" case, or the macro
  -- would flick to a corpse / a friendly / nothing at all.
  local stop = lines[iStop] or ""
  check("the bail-out covers a missing pet target",
    stop:find("noexists", 1, true) ~= nil, stop)
  check("...a dead pet target", stop:find("dead", 1, true) ~= nil, stop)
  check("...and a friendly pet target",
    stop:find("noharm", 1, true) ~= nil, stop)

  -- Raptor Strike was removed on request: plain auto attack only.
  check("it does not cast Raptor Strike",
    weave.body:find("Raptor", 1, true) == nil)
end

-- ---------------------------------------------------------------------------
-- The window itself
-- ---------------------------------------------------------------------------
M.Show()
check("the macro window opens", M.IsShown() == true)
check("...with a row per macro", #M.Rows() == M.Count(),
  #M.Rows() .. " vs " .. M.Count())

-- The copy boxes must hold the macro text verbatim: that is the whole feature.
local mismatched = {}
for i, row in ipairs(M.Rows()) do
  local want = M.Entry(i).body
  if row.box:GetText() ~= want then
    mismatched[#mismatched + 1] = tostring(M.Entry(i).title)
  end
end
check("every copy box holds its macro exactly", #mismatched == 0,
  table.concat(mismatched, ","))

-- Editing a box must not corrupt what you copy.
local box = M.Rows()[1].box
box:SetText("junk")
local handler = box.scripts and box.scripts["OnTextChanged"]
if handler then handler(box, true) end
check("a box repairs itself if edited",
  box:GetText() == M.Entry(1).body, tostring(box:GetText()))

M.Hide()
check("the macro window closes", M.IsShown() == false)

say(string.format("\n%d passed, %d failed", passes, #failures))
if #failures > 0 then
  for _, f in ipairs(failures) do say("  - " .. f) end
  error(#failures .. " test(s) failed")
end
