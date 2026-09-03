--[[==============================================================================
 HunterKit — tests: syntax + docs freshness
 * every addon file must parse (this is a compile check only — the modules that
   need the full client, like Options.lua, are not executed here)
 * the .toc must list every root .lua file, and nothing that doesn't exist
 * the .toc version must match HK.version
 * every /htk subcommand Core.lua defines must appear in the README
 * the newest CHANGELOG entry must match the current version

 Run with tests/run_tests.py (HKTest.addonFiles is injected by the runner).
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

-- Texture guard: the client only ever rendered the uncompressed 32-bit TGAs
-- reliably (BLP1 showed green squares, and hand-rolled BLP2 did not render
-- either -- 0.9.21-0.9.26). Every shipped texture must be an uncompressed
-- true-colour TGA: image type 2, 32 bits per pixel.
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
    local fh = io.open("../Media/" .. n .. ".tga", "rb")
    check("texture " .. n .. ".tga exists", fh ~= nil)
    if fh then
      local hdr = fh:read(18)
      fh:close()
      local imgType, bpp = hdr:byte(3), hdr:byte(17)
      check("texture " .. n .. ".tga is uncompressed 32-bit RGBA",
        imgType == 2 and bpp == 32,
        string.format("type=%s bpp=%s", tostring(imgType), tostring(bpp)))
    end
  end
  check("no stray .blp files ship",
    io.open("../Media/mark-ok-plus.blp", "rb") == nil)
end

say(string.format("\n%d passed, %d failed", passes, #failures))
if #failures > 0 then
  for _, f in ipairs(failures) do say("  - " .. f) end
  error(#failures .. " doc/syntax test(s) failed")
end
