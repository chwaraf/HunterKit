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
