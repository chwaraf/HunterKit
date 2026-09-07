--[[==============================================================================
 HunterKit — tests: syntax + docs freshness
 * every addon file must parse (this is a compile check only — the modules that
   need the full client, like Options.lua, are not executed here)
 * the .toc must list every root .lua file, and nothing that doesn't exist
 * the .toc version must match HK.version
 * every /htk subcommand Core.lua defines must appear in the README
 * the newest CHANGELOG entry must match the current version
 * the shipped mark art must exist as PNG (and no .tga/.blp may ship)
 * the README's Development section must describe THIS suite: its stated version,
   a row and a current check count for every test file, and a correct total

 Run with tests/run_tests.py (HKTest.addonFiles and HKTest.testFiles are
 injected by the runner). This file runs LAST: the README count checks read the
 tallies the other files reported via HKTest.report.
==============================================================================]]

local say = HKTest.say
local passes, failures = 0, {}

local function check(name, cond, detail)
  if cond then
    passes = passes + 1
    say("  ok   " .. name)
  else
    failures[#failures + 1] = name .. (detail and (" — " .. tostring(detail)) or "")
    say("  FAIL " .. name .. (detail and (" — " .. tostring(detail)) or ""))
  end
end

local function read(path)
  local f, err = io.open(path, "r")
  if not f then return nil, err end
  -- "a" is the 5.2+ spelling, "*a" the 5.1 one; the harness may run on either.
  local ok, s = pcall(function() return f:read("a") end)
  if not ok or s == nil then s = f:read("*a") end
  f:close()
  return s
end

-- ---------------------------------------------------------------------------
-- 1) Every addon file parses
-- ---------------------------------------------------------------------------
for _, f in ipairs(HKTest.addonFiles or {}) do
  local chunk, err = loadfile(f)
  check(f .. " parses", chunk ~= nil, err)
end

-- ---------------------------------------------------------------------------
-- 2) .toc <-> files on disk
-- ---------------------------------------------------------------------------
local toc = read("../HunterKit.toc") or ""
local listed = {}
for line in toc:gmatch("[^\r\n]+") do
  if not line:match("^%s*##") and line:match("%.lua%s*$") then
    listed[line:gsub("%s+$", "")] = true
  end
end
for _, f in ipairs(HKTest.addonFiles or {}) do
  local base = f:match("([^/]+)$") or f
  check(".toc lists " .. base, listed[base] == true)
end
for name in pairs(listed) do
  local f = io.open("../" .. name, "r")
  check(".toc entry exists: " .. name, f ~= nil)
  if f then f:close() end
end

-- ---------------------------------------------------------------------------
-- 3) Version agreement: .toc == HK.version == newest CHANGELOG entry
-- ---------------------------------------------------------------------------
if not HK then HKTest.LoadAddon("../Core.lua") end
local tocVersion = toc:match("##%s*Version:%s*([%d%.]+)")
check(".toc version matches HK.version", tocVersion == HK.version,
  tostring(tocVersion) .. " vs " .. tostring(HK.version))

local changelog = read("../CHANGELOG.md") or ""
local firstEntry = changelog:match("%[%s*(%d+%.%d+%.%d+)%s*%]")
check("CHANGELOG top entry matches HK.version", firstEntry == HK.version,
  tostring(firstEntry) .. " vs " .. tostring(HK.version))

-- ---------------------------------------------------------------------------
-- 4) Every /htk subcommand is documented
-- ---------------------------------------------------------------------------
local core = read("../Core.lua") or ""
local readme = read("../README.md") or ""
local cmds = {}
for cmd in core:gmatch('msg%s*==%s*"([%w%-]+)"') do
  cmds[cmd] = true
end
local documented = 0
for cmd in pairs(cmds) do
  local ok = readme:find("/htk " .. cmd, 1, true) ~= nil
  check("README documents /htk " .. cmd, ok)
  if ok then documented = documented + 1 end
end
check("at least one /htk command found in Core.lua", documented > 0)

-- The new feature must be described in the README, not just shipped.
check("README documents the pet mend marker", readme:find("Pet Mend Marker", 1, true) ~= nil)
check("CHANGELOG documents the pet mend marker",
  changelog:find("Pet Mend Marker", 1, true) ~= nil)

-- Texture guard: shipped art is PNG (as of 0.9.28) -- lossless, 9x smaller
-- than the old TGAs, and the format addons universally use on this client.
-- The BLP detour (0.9.21-0.9.27) failed twice: BLP1 showed green squares
-- and a hand-rolled BLP2 used the wrong 156-byte header (working BLPs use
-- 148: width at byte 12, mip offsets at byte 20, 1024-byte palette gap
-- before mip0, full mip chain -- see the autopsy in tools/tga_to_blp.py).
-- Every shipped texture must exist as a PNG and carry the PNG magic.
do
  local textures = {
    "crosshair", "crosshair-x", "crosshair-outline",
    "mark-ok-reticle", "mark-ok-plus", "mark-ok-ticks", "mark-ok-diamond",
    "mark-ok-chevrons",
    "mark-far-ban", "mark-far-halo", "mark-far-dashring", "mark-far-sides",
    "mark-far-slashes",
    "mark-dead-cross", "mark-dead-block", "mark-dead-burst", "mark-dead-bars",
    "mark-dead-hexx",
  }
  for _, n in ipairs(textures) do
    local fh = io.open("../Media/" .. n .. ".png", "rb")
    check("texture " .. n .. ".png exists", fh ~= nil)
    if fh then
      local magic = fh:read(8)
      fh:close()
      check("texture " .. n .. ".png carries the PNG magic",
        magic == "\137PNG\r\n\26\n", tostring(magic))
    end
  end
  check("no stray .tga files ship",
    io.open("../Media/mark-ok-plus.tga", "rb") == nil)
  check("no stray .blp files ship",
    io.open("../Media/mark-ok-plus.blp", "rb") == nil)
end

-- ---------------------------------------------------------------------------
-- 6) The README's Development section must describe THIS suite
-- ---------------------------------------------------------------------------
-- The repo's rule is "every change updates the docs in the same commit", and the
-- README's Development section is part of those docs. It drifted badly once --
-- it advertised "465 checks, in five files" while the suite really ran 944
-- checks across eight, with three test files missing from the table entirely --
-- so the numbers are now checked like any other documented claim.

local readmeVersion = readme:match("Current version: %*%*(%d+%.%d+%.%d+)%*%*")
check("README states the current version", readmeVersion == HK.version,
  tostring(readmeVersion) .. " vs " .. tostring(HK.version))

-- The mark art moved TGA -> PNG in 0.9.28 and the README kept saying .tga for
-- 39 releases. Both halves are checked: PNG is stated, and the old wording is gone.
check("README describes the mark art as PNG, not TGA",
  readme:find("`%.png`", 1, false) ~= nil
    and readme:find("ship as white%-on%-alpha `%.tga`", 1, false) == nil)

local testFiles = HKTest.testFiles or {}
check("the harness named its test files", #testFiles > 0)
local documentedFiles = 0
for _, name in ipairs(testFiles) do
  local esc = name:gsub("%.", "%%.")
  local n = tonumber(readme:match("`" .. esc .. "`%s*%((%d+)%)"))
  check("README documents " .. name, n ~= nil)
  if n then documentedFiles = documentedFiles + 1 end
  -- test_docs.lua IS this file: its own tally is not final until the last check
  -- below has run, so its number is verified by the total check instead.
  local ran = HKTest.counts[name]
  if n and ran and name ~= "test_docs.lua" then
    check("README's count for " .. name .. " is current", n == ran.passes,
      "README says " .. n .. ", the suite ran " .. ran.passes)
  end
end
check("every test file is in the README's table", documentedFiles == #testFiles,
  documentedFiles .. "/" .. #testFiles)

-- MUST stay the last check in this file: it accounts for itself, so the expected
-- total is "everything recorded so far, plus this one".
local ranTotal = 0
for _, name in ipairs(testFiles) do
  local c = HKTest.counts[name]
  if c then ranTotal = ranTotal + c.passes end
end
local expectTotal = ranTotal + passes + 1
local readmeTotal, readmeFileCount =
  readme:match("%*%*(%d+) checks%*%*, in %*%*(%d+)%*%* files")
check("README's total check count is current",
  tonumber(readmeTotal) == expectTotal and tonumber(readmeFileCount) == #testFiles,
  string.format("README says %s checks in %s files; the suite ran %d in %d",
    tostring(readmeTotal), tostring(readmeFileCount), expectTotal, #testFiles))

HKTest.report("test_docs.lua", passes, #failures)

say(string.format("\n%d passed, %d failed", passes, #failures))
if #failures > 0 then
  for _, f in ipairs(failures) do say("  - " .. f) end
  error(#failures .. " doc/syntax test(s) failed")
end
