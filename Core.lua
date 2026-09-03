--[[==============================================================================
 HunterKit — Core
 Namespace setup, SavedVariables schema/migration, event registry, slash
 commands, class gating, portability helpers. No game actions are taken here.
==============================================================================]]

local ADDON_NAME, HK = ...

HK.version = "0.9.3"

-- ---------------------------------------------------------------------------
-- Defaults (schema). This is the source of truth for the options window and
-- the SavedVariables merge. Keep every key here; new keys land via merge.
-- ---------------------------------------------------------------------------
HK.defaults = {
  enabled   = true,
  dbVersion = 16,
  firstRun  = true,

  ui = {
    minimapShow  = true,
    minimapAngle = 210,
  },

  feed = {
    enabled        = true,
    size           = 28,
    offsetX        = 12,           -- clear gap to the right of the happiness icon
    offsetY        = 0,
    parent         = "PetFrame",
    moved          = false,        -- true once the user drags it (then pinned absolutely)
    preferredFoods = {},
    exclude        = {},
    rule           = "best",
    hungryOnly     = false,        -- show the button only when the pet is hungry (<3)
  },

  range = {
    enabled      = true,
    size         = 60,   -- 50% bigger than the old 40 default
    offsetX      = 14,   -- clears the elite target-frame artwork (was 6)
    offsetY      = 0,
    parent       = "TargetFrame",
    moved        = false,          -- true once the user drags it (then pinned absolutely)
    showLabel    = false,
    markOK       = "plus",         -- mark style for IN RANGE (bold cross family)
    markDead     = "cross",        -- mark style for TOO CLOSE (the loved cross)
    markFar      = "ban",          -- mark style for OUT OF RANGE
    brightOK     = 100,            -- per-state mark brightness, percent
    brightDead   = 100,
    brightFar    = 100,
  },

  sound = {
    enabled      = true,
    gunsOnly     = true,
    -- The original gunshot is SILENCED by default. The addon plays the pew in
    -- its place via the combat log. (The mute is applied with MuteSoundFile,
    -- which is session-wide in C++ — see Sounds.lua for the caveat.)
    muteOriginal = true,
    minInterval  = 0.15,
    channel      = "SFX",
    noRepeat     = true,
    variants     = { "pew-1", "pew-2", "pew-3", "pew-4" },
    -- Gun auto-shot fire/load WEAPON sounds ONLY. This is the set that silences
    -- the gun's own "bang" (the auto-shot) without touching hunter spell shots:
    --   - SoundKit 15071 "MachineGun" -> GunFire01/02/03 = 567721, 567718, 567722
    --   - SoundKit 1147  "GunPrecastOneShot" -> GunLoad01/02/03 = 567719, 567720, 567723
    -- We intentionally do NOT mute the `spell_hu_blunderbuss_weaponfire_01..06`
    -- set (921248-921258): that is a hunter *spell-cast* weapon-fire sound that is
    -- SHARED by Multi-Shot / Arcane Shot, so muting it silences those spells too.
    mutedFileIDs = {
      567718, 567719, 567720, 567721, 567722, 567723,
    },
  },

  pulse = {
    enabled           = true,
    size              = 72,
    offsetX           = 0,
    offsetY           = 150,
    moved             = false,       -- true once the user drags it (then pinned absolutely)
    cycle             = 0.9,
    rings             = true,
    label             = true,
    smallGlowOnPetBar = false,
  },

  mend = {
    enabled     = true,
    size        = 34,
    offsetX     = 0,
    offsetY     = 4,       -- gap above the anchor (name plate / pet frame) top edge
    pinX        = 0,       -- dragged position (absolute UIParent CENTRE offset)
    pinY        = 0,
    moved       = false,   -- true once dragged; then the UI fallback is pinned
    hpThreshold = 30,      -- % of max HP at or below which the marker goes urgent
    urgentPulse = true,    -- grow + pulse + expanding ring while urgent
    urgentCycle = 0.55,    -- seconds per urgent pulse
    combatOnly  = true,    -- hide out of combat (a pet below the threshold still shows)
    dimWhenFar  = true,    -- grey + fade when the pet is outside Mend Pet range
    showLabel   = true,    -- "MEND!" when urgent, "TOO FAR" when out of range
    anchor      = "auto",  -- auto | plate (world only) | petframe (always UI)
    plateStyle  = true,    -- nameplate-style name + HP bar under the icon when
                           -- we're NOT anchored to a real pet plate
    -- Opt-in: turn on the minimum nameplate CVars so the client publishes a pet
    -- plate and the marker can anchor over the pet's head with the player's own
    -- nameplate settings left alone. Previous values are stored here and restored
    -- on disable/logout, so nothing is written to the config permanently.
    plateCVars  = {},      -- leftover CVar values older builds changed; restored
  },
}
HK.DBNAME = "HunterKitDB"

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------
function HK.MergeDefaults(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" then
      if type(dst[k]) ~= "table" then dst[k] = {} end
      HK.MergeDefaults(dst[k], v)
    elseif dst[k] == nil then
      dst[k] = v
    end
  end
end

function HK.DeepCopy(t, seen)
  seen = seen or {}
  if type(t) ~= "table" then return t end
  if seen[t] then return seen[t] end
  local out = {}
  seen[t] = out
  for k, v in pairs(t) do out[k] = HK.DeepCopy(v, seen) end
  return out
end

-- Create a 4-rect set of thin textures forming a colored border on `frame`.
-- The closure keeps them all in sync. Returns an object with :SetVertexColor
-- and :SetShown. Reused by the feed button, sniper mark bar, and passive glow.
function HK.CreateBorder(frame, thickness)
  thickness = thickness or 1
  local function mk(anchorA, anchorB)
    local tex = frame:CreateTexture(nil, "OVERLAY")
    tex:SetPoint(anchorA)
    tex:SetPoint(anchorB)
    tex:SetTexture("Interface\\Buttons\\WHITE8x8")
    tex:SetVertexColor(0, 0, 0, 0.6)
    return tex
  end
  local top = mk("TOPLEFT", "TOPRIGHT");  top:SetHeight(thickness)
  local bottom = mk("BOTTOMLEFT", "BOTTOMRIGHT"); bottom:SetHeight(thickness)
  local left = mk("TOPLEFT", "BOTTOMLEFT"); left:SetWidth(thickness)
  local right = mk("TOPRIGHT", "BOTTOMRIGHT"); right:SetWidth(thickness)
  local tex = { top, bottom, left, right }
  local obj = {
    SetVertexColor = function(self, r, g, b, a)
      for _, t in ipairs(tex) do t:SetVertexColor(r, g, b, a or 1) end
    end,
    SetShown = function(self, shown)
      for _, t in ipairs(tex) do t:SetShown(shown) end
    end,
    GetIsShown = function() return top:IsShown() end,
  }
  return obj
end

-- Return a frame's (left, bottom, width, height) in UIParent coordinate space.
-- Frames can be children of the frame they're anchored to (e.g. a sniper mark
-- that is a child of TargetFrame), in which case GetLeft/GetBottom are in the
-- PARENT's coordinate system — not UIParent's. Comparing those against another
-- frame with a different parent mixes coordinate systems and makes a dragged
-- frame "jump" off-screen on release. This walks the parent chain and converts
-- to UIParent space, so any two frames can be compared correctly.
--
-- IMPORTANT: In WoW, GetLeft/GetTop/GetBottom/GetRight and GetCenter are measured
-- FROM THE BOTTOM-LEFT of the parent (Y-up, positive = up), and SetPoint offsets
-- are also Y-up (positive = up). So the X/Y here are directly compatible with
-- SetPoint offsets — no sign flip is needed.
function HK.AbsRect(f)
  -- Every measurement is pcall-guarded: a frame anchored into a restricted
  -- region (e.g. a name plate) makes GetRect/GetLeft HARD-error with "Can't
  -- measure restricted regions", which used to blow up lock/unlock mid-toggle.
  local ok, l, b, w, h = pcall(f.GetRect, f)
  if not ok or l == nil then
    l, b, w, h = 0, 0, 0, 0
    local v
    ok, v = pcall(f.GetLeft, f);   if ok and v then l = v end
    ok, v = pcall(f.GetBottom, f); if ok and v then b = v end
    ok, v = pcall(f.GetWidth, f);  if ok and v then w = v end
    ok, v = pcall(f.GetHeight, f); if ok and v then h = v end
  end
  local p = f:GetParent()
  while p and p ~= UIParent and p.GetLeft do
    local okp, pl = pcall(p.GetLeft, p)
    if not okp or not pl then break end
    local okb, pb = pcall(p.GetBottom, p)
    l = l + pl
    b = b + ((okb and pb) or 0)
    p = p:GetParent()
  end
  return l, b, w, h
end

-- Return a frame's (centreX, centreY) in UIParent coordinate space, in the SAME
-- Y-up convention that GetCursorPosition() and SetPoint offsets use. This is the
-- one coordinate space where a dragged frame's on-screen centre round-trips
-- exactly through SetPoint on release.
function HK.AbsCenter(f)
  local l, b, w, h = HK.AbsRect(f)
  return l + w / 2, b + h / 2
end

-- ---------------------------------------------------------------------------
-- Container API compat.
-- The Midnight UI merge (Classic 1.15.9 / TBC 2.5.6) moved the legacy global
-- bag functions into the C_Container namespace AND changed the return shape of
-- GetContainerItemInfo from positional multi-values to a table (itemID,
-- itemCount, icon, ...). The old globals no longer exist on this client, so we
-- prefer C_Container and fall back to the globals (for safe multi-client use).
-- ---------------------------------------------------------------------------
local CCont = C_Container

function HK.GetBagNumSlots(bag)
  if CCont and CCont.GetContainerNumSlots then
    local ok, n = pcall(CCont.GetContainerNumSlots, bag)
    if ok and n then return n end
  end
  if GetContainerNumSlots then return GetContainerNumSlots(bag) end
  return 0
end

function HK.GetBagItemID(bag, slot)
  if CCont and CCont.GetContainerItemInfo then
    local ok, info = pcall(CCont.GetContainerItemInfo, bag, slot)
    if ok and info then return info.itemID end
  end
  if GetContainerItemID then return GetContainerItemID(bag, slot) end
  if GetContainerItemInfo then return select(10, GetContainerItemInfo(bag, slot)) end
  return nil
end

function HK.GetBagItemCount(bag, slot)
  if CCont and CCont.GetContainerItemInfo then
    local ok, info = pcall(CCont.GetContainerItemInfo, bag, slot)
    if ok and info then return info.itemCount end
  end
  if GetContainerItemInfo then return select(2, GetContainerItemInfo(bag, slot)) end
  return nil
end

function HK.GetBagItemLink(bag, slot)
  if CCont and CCont.GetContainerItemInfo then
    local ok, info = pcall(CCont.GetContainerItemInfo, bag, slot)
    if ok and info then return info.hyperlink end
  end
  if GetContainerItemLink then return GetContainerItemLink(bag, slot) end
  if GetContainerItemInfo then return select(7, GetContainerItemInfo(bag, slot)) end
  return nil
end

-- GetItemInfo compat: prefers the legacy global (still present on Classic) and
-- falls back to C_Item.GetItemInfo (same positional signature) if it's gone.
function HK.GetItemInfo(item)
  if GetItemInfo then return GetItemInfo(item) end
  if C_Item and C_Item.GetItemInfo then return C_Item.GetItemInfo(item) end
  return nil
end

-- UseContainerItem compat: the Midnight UI merge moved this into C_Container too.
-- Prefer it, fall back to the legacy global.
function HK.UseContainerItem(bag, slot)
  if C_Container and C_Container.UseContainerItem then
    return C_Container.UseContainerItem(bag, slot)
  end
  if UseContainerItem then return UseContainerItem(bag, slot) end
end

-- ---------------------------------------------------------------------------
-- Event registry (one shared bus frame). HK.Off(ev, fn) stops it.
-- ---------------------------------------------------------------------------
local bus = CreateFrame("Frame")
bus.handlers = {}
bus:SetScript("OnEvent", function(self, event, ...)
  local fn = bus.handlers[event]
  if fn then return fn(...) end
end)
HK.bus = bus

function HK.On(event, fn)
  bus:RegisterEvent(event)
  local prev = bus.handlers[event]
  if prev then
    bus.handlers[event] = function(...) prev(...); fn(...) end
  else
    bus.handlers[event] = fn
  end
end

function HK.Off(event)
  bus.handlers[event] = nil
  bus:UnregisterEvent(event)
end

-- True while the player is in "edit mode" (frames unlocked for dragging). Feature
-- modules check this to (a) force their frame visible and (b) NOT reposition or
-- hide it from their own update ticks/events while the user is dragging — that
-- fighting is what made icons re-attach/hide right after being dropped.
function HK.Editing()
  local P = HK.Positions
  return P ~= nil and P.locked == false
end

-- Verbose drag/geometry logging, gated behind /htk debug. When the on-screen
-- frames still "jump" on the live client this prints the real cursor, the frame's
-- on-screen centre, the anchor it saved against, and the offset it ended up with,
-- for every drag event — so the actual geometry is captured instead of guessed.
function HK.Dbg(...)
  if HK.debug then
    print("|cff39ff14HunterKit|r [debug]", ...)
  end
end

-- Return a readable snapshot of a frame's on-screen geometry in UIParent space.
-- Used by /htk debug to show what the client is really doing when a frame moves.
function HK.Geom(f)
  if not f then return "nil" end
  local function g(m, ...)
    local ok, v = pcall(m, ...)
    return ok and v or "?"
  end
  local l, b, w, h = HK.AbsRect(f)
  local pn
  local okp, p = pcall(f.GetParent, f)
  if okp and p then local roko, n = pcall(p.GetName, p); pn = (roko and n) or "?" end
  return string.format("rect=(%s,%s,%s,%s) center=(%s,%s) point=%s parent=%s shown=%s",
    tostring(l), tostring(b), tostring(w), tostring(h),
    tostring(l + w/2), tostring(b + h/2), tostring(g(f.GetPoint, f, 1)), tostring(pn),
    tostring(g(f.IsShown, f)))
end

-- ---------------------------------------------------------------------------
-- Module registry
-- ---------------------------------------------------------------------------
HK.modules = HK.modules or {}
function HK.RegisterModule(name, mod)
  HK.modules[name] = mod
end

-- Timer: returns a cancelable handle. Early-return inside the callback is the
-- "pause" mechanism; call :Cancel() to stop it outright.
function HK.Ticker(interval, fn)
  return C_Timer.NewTicker(interval, fn)
end

--- Restore EVERY setting to its default.
---
--- The sub-tables are wiped and refilled in place rather than replaced: each
--- module keeps its own local reference to its slice (`db = HK.db.range`), so
--- handing HK.db fresh tables would leave every module writing to orphans that
--- are never saved. Identity must survive; only the contents change.
local function ResetInto(dst, src)
  for k in pairs(dst) do dst[k] = nil end
  for k, v in pairs(src) do
    if type(v) == "table" then
      dst[k] = {}
      ResetInto(dst[k], v)
    else
      dst[k] = v
    end
  end
end

function HK.ResetAll()
  for k, v in pairs(HK.defaults) do
    if type(v) == "table" then
      if type(HK.db[k]) ~= "table" then HK.db[k] = {} end
      ResetInto(HK.db[k], v)
    else
      HK.db[k] = v
    end
  end
  -- Drop keys this version no longer knows about (older saves).
  for k in pairs(HK.db) do
    if HK.defaults[k] == nil and k ~= "dbVersion" then HK.db[k] = nil end
  end
  HK.db.dbVersion = HK.dbVersion

  -- Re-apply everywhere. RescanSettings re-reads the db slice and rebuilds what
  -- the setting controls; the mend marker also puts any leftover forced
  -- nameplate CVar back.
  for _, name in ipairs({ "FeedPet", "Range", "Sounds", "PassivePulse", "MendMark" }) do
    local m = HK[name]
    if m and m.RescanSettings then pcall(m.RescanSettings) end
  end
  if HK.MendMark and HK.MendMark.Update then pcall(HK.MendMark.Update) end
  print("|cff39ff14HunterKit|r all settings restored to their defaults.")
end

-- ---------------------------------------------------------------------------
-- Drag / position helpers (shared by feed button, sniper mark, passive alert)
-- ---------------------------------------------------------------------------
HK.draggables = {}
-- Register a frame that can be shown/moved in unlock mode. `apply` restores the
-- frame's real anchor from db offsets; `save(x, y)` persists a new offset.
-- opts.clickable: frame is clickable even when locked (e.g. the feed button).
-- opts.blankSecure: in unlock mode, blank secure attributes so dragging never
-- triggers the action (feed button); must be out of combat.
function HK.RegisterDraggable(name, frame, apply, save, opts)
  HK.draggables[name] = { frame = frame, apply = apply, save = save, opts = opts or {} }
end

-- ---------------------------------------------------------------------------
-- Drag-position save/apply — the one fix that actually stops the "jump".
-- Every draggable frame is a DIRECT child of UIParent, so its `GetCenter()` is
-- already measured in UIParent's coordinate space. We store the frame on-screen
-- centre as an offset from UIParent's CENTRE, and re-apply it with the SAME
-- CENTRE/CENTRE anchor. Both the measurement and the re-apply happen entirely in
-- UIParent space, so the offset round-trips exactly — no unit-frame coordinate
-- conversion, no scale mismatch. THIS is the bug: the old code measured the frame
-- against a unit-frame anchor (a different coordinate/scale space) and then
-- re-applied that as a `SetPoint` offset, which put it back somewhere else on lock.
-- ---------------------------------------------------------------------------
function HK.SaveDragged(frame, db)
  -- The frame is a direct child of UIParent, so GetCenter() is already in
  -- UIParent's coordinate space (UI units, Y-up, origin at UIParent's bottom-left).
  -- UIParent's own CENTRE in that SAME space is (width/2, height/2). Subtracting
  -- gives an offset that re-applies exactly via SetPoint("CENTER", UIParent,
  -- "CENTER", offX, offY) — and, critically, keeps everything in one coordinate
  -- system regardless of the UI scale. (We must NOT use UIParent:GetCenter(),
  -- which returns in UIParent's PARENT space / raw pixels.)
  local fx, fy = frame:GetCenter()
  local uw = UIParent:GetWidth() or 0
  local uh = UIParent:GetHeight() or 0
  db.offsetX = (fx or 0) - (uw / 2)
  db.offsetY = (fy or 0) - (uh / 2)
  db.moved = true
end

-- Whether a registered draggable should take part in lock/unlock at all. A
-- frame that is currently anchored to something it must follow (e.g. the mend
-- marker sitting on the pet's name plate) is not the player's to move, and
-- touching its drag state can throw on restricted regions.
function HK.DraggableActive(d)
  if d and d.opts and d.opts.draggableIf then
    return d.opts.draggableIf() and true or false
  end
  return true
end

-- SetClampedToScreen() throws "Can't clamp restricted regions" (and taints) when
-- the frame is anchored to a protected frame such as a name plate. Every call
-- goes through here so a restricted frame can never break lock/unlock.
function HK.SafeClamp(f, on)
  if not f or not f.SetClampedToScreen then return false end
  local ok, err = pcall(f.SetClampedToScreen, f, on)
  if not ok then HK.Dbg("SetClampedToScreen refused:", tostring(err)) end
  return ok
end

-- Decide whether a draggable should be pinned to UIParent CENTRE (absolute) rather
-- than its unit-frame anchor. True once the user has dragged it (moved) or when it
-- anchors to UIParent anyway (CENTER mode). While it anchors to the unit frame, its
-- stored offset is used as a gap from the frame's right edge.
function HK.IsPinned(db)
  return (db.moved == true) or (db.parent == "UIParent")
end

-- ---------------------------------------------------------------------------
-- Saved variables: validation + migration
-- ---------------------------------------------------------------------------
local function LoadDB()
  local db = HunterKitDB
  if type(db) ~= "table" then db = {} end  -- corrupt/partial wipe -> clean slate
  HK.MergeDefaults(db, HK.defaults)

  -- Migrations: bump dbVersion and apply per-version field fixes here.
  if type(db.dbVersion) ~= "number" then db.dbVersion = 1 end

  -- v1/v2 -> v3: the gunshot is meant to be SILENCED by default. Earlier builds
  -- (and the "never mute by default" rule) left `muteOriginal` false for many
  -- users, so they kept hearing the stock gun shot. Since silencing the original
  -- gun sound is the headline feature, set it on for anyone upgrading. A user who
  -- genuinely wants the stock sound can uncheck it in options.
  if db.dbVersion < 3 then
    if db.sound then
      db.sound.muteOriginal = true
    end
    db.dbVersion = 3
  end

  -- v3 -> v4: `mutedFileIDs` wasn't being populated for existing users. Because
  -- MergeDefaults only fills keys that are nil, a user who already had a
  -- `mutedFileIDs` key (e.g. an empty table left over from an early build, or a
  -- short list from a trial) kept that value and never received the full default
  -- gun-mute set — so the stock gunshot kept playing even with muteOriginal on.
  -- Union the configured list with the full default set, and force the mute on
  -- (silencing the stock gunshot is a headline requirement).
  if db.dbVersion < 4 then
    if db.sound then
      db.sound.muteOriginal = true
      local seen = {}
      local merged = {}
      local function add(fid)
        if type(fid) == "number" and not seen[fid] then seen[fid] = true; merged[#merged + 1] = fid end
      end
      for _, fid in ipairs(HK.defaults.sound.mutedFileIDs or {}) do add(fid) end
      for _, fid in ipairs(db.sound.mutedFileIDs or {}) do add(fid) end
      db.sound.mutedFileIDs = merged
    end
    db.dbVersion = 4
  end

  -- v4 -> v5: the previous builds also muted the hunter spell-cast weapon-fire
  -- sound (`spell_hu_blunderbuss_weaponfire_01..06`, 921248-921258), which is
  -- SHARED by Multi-Shot / Arcane Shot — so those abilities went silent too. We
  -- now keep ONLY the weapon fire/load IDs (the gun auto-shot bang). Strip the
  -- spell-cast IDs out of the persisted list so upgrading users get their ability
  -- sounds back while the gun shot stays silenced.
  if db.dbVersion < 5 then
    if db.sound and type(db.sound.mutedFileIDs) == "table" then
      local keep = {}
      local seen = {}
      for _, fid in ipairs(db.sound.mutedFileIDs) do
        if type(fid) == "number" and not seen[fid] and fid ~= 921248 and fid ~= 921250
           and fid ~= 921252 and fid ~= 921254 and fid ~= 921256 and fid ~= 921258 then
          seen[fid] = true; keep[#keep + 1] = fid
        end
      end
      -- make sure the weapon fire/load set is present
      for _, fid in ipairs(HK.defaults.sound.mutedFileIDs or {}) do
        if not seen[fid] then seen[fid] = true; keep[#keep + 1] = fid end
      end
      db.sound.mutedFileIDs = keep
      db.sound.muteOriginal = true
    end
    db.dbVersion = 5
  end

  -- v5 -> v6: the feed button's saved position could end up stuck somewhere odd
  -- (reported as "way below" — a leftover offset from dragging during testing).
  -- Reset the feed button's anchor to the good default (right of the pet frame).
  -- Food pin/exclude prefs and other settings are preserved.
  if db.dbVersion < 6 then
    if db.feed then
      db.feed.offsetX = HK.defaults.feed.offsetX
      db.feed.offsetY = HK.defaults.feed.offsetY
      db.feed.parent  = HK.defaults.feed.parent
    end
    db.dbVersion = 6
  end

  -- v6 -> v7: the feed button now anchors to the happiness icon's right edge (so
  -- it sits beside it on the same height instead of overlapping it). Re-apply the
  -- default feed position once so the new anchor takes effect for existing users.
  if db.dbVersion < 7 then
    if db.feed then
      db.feed.offsetX = HK.defaults.feed.offsetX
      db.feed.offsetY = HK.defaults.feed.offsetY
      db.feed.parent  = HK.defaults.feed.parent
    end
    db.dbVersion = 7
  end

  -- v7 -> v8: the sniper mark default is now 50% bigger (60) and the feed button
  -- default/minimum size is larger (28). Apply the new default sizes once to
  -- existing users so they actually see the change. (Users who set a custom size
  -- keep it — we only bump users still on the old default.)
  if db.dbVersion < 8 then
    if db.range and db.range.size == 40 then db.range.size = HK.defaults.range.size end
    if db.feed and db.feed.size == 22 then db.feed.size = HK.defaults.feed.size end
    db.dbVersion = 8
  end

  -- v8 -> v9: several earlier builds had BROKEN drag saving — the dropped offset
  -- was never written (the code read `dd.saveFromScreen`, which is nil, so the
  -- fallback wrote (0,0)) and one build even flipped the offset's Y axis. The
  -- result is a stale/bad saved position that makes the feed/range/pulse frames
  -- appear to "jump" on lock or on load. Reset those three position fields to the
  -- defaults once so every user starts from a clean, correct position. (Food
  -- prefs, sound settings, etc. are untouched.) Run after the merge so the key
  -- exists; run once via the version bump.
  if db.dbVersion < 9 then
    if db.feed then
      db.feed.offsetX = HK.defaults.feed.offsetX
      db.feed.offsetY = HK.defaults.feed.offsetY
      db.feed.parent  = HK.defaults.feed.parent
    end
    if db.range then
      db.range.offsetX = HK.defaults.range.offsetX
      db.range.offsetY = HK.defaults.range.offsetY
      db.range.parent  = HK.defaults.range.parent
    end
    if db.pulse then
      db.pulse.offsetX = HK.defaults.pulse.offsetX
      db.pulse.offsetY = HK.defaults.pulse.offsetY
    end
    db.dbVersion = 9
  end

  -- v9 -> v10: the drag-save now stores an ABSOLUTE UIParent-CENTRE offset (see
  -- HK.SaveDragged) instead of an offset measured against a unit-frame anchor.
  -- The old relative offsets are in a different coordinate/scale space and will
  -- make a frame "jump" on lock. Reset all three position fields (and the `moved`
  -- flag) to the defaults so every position starts clean and correct; a user who
  -- re-drags a frame gets a correct absolute offset.
  if db.dbVersion < 10 then
    for _, sec in ipairs({ "feed", "range", "pulse" }) do
      local s = db[sec]
      if s then
        s.offsetX = HK.defaults[sec] and HK.defaults[sec].offsetX or s.offsetX
        s.offsetY = HK.defaults[sec] and HK.defaults[sec].offsetY or s.offsetY
        if HK.defaults[sec] and HK.defaults[sec].parent then
          s.parent = HK.defaults[sec].parent
        end
        s.moved = false
      end
    end
    db.dbVersion = 10
  end

  -- v10 -> v11: the sniper mark default offset moved right (6 -> 14) to clear the
  -- elite target-frame artwork, and the two per-state mark-style keys were added.
  -- For anyone who has NOT hand-dragged the mark, move it to the new default so
  -- it stops overlapping the elite frame. Users who dragged it themselves (moved)
  -- keep their spot. Also drop the removed option keys (blinkOnDead, shapeCode).
  if db.dbVersion < 11 then
    if db.range then
      if db.range.moved ~= true then
        db.range.offsetX = HK.defaults.range.offsetX
        db.range.offsetY = HK.defaults.range.offsetY
        db.range.parent  = HK.defaults.range.parent
      end
      db.range.blinkOnDead = nil
      db.range.shapeCode   = nil
    end
    db.dbVersion = 11
  end

  -- v11 -> v12: the Pet Mend Marker section (`mend`) was added. No field rewrite
  -- is needed — HK.MergeDefaults fills a whole missing section from
  -- HK.defaults, so existing users simply receive the new keys with their default
  -- values (marker ON, 30% threshold, world/plate anchor with a pet-frame
  -- fallback). The bump exists so the schema change is recorded and so a later
  -- migration has a version to hang off.
  if db.dbVersion < 12 then
    db.dbVersion = 12
  end

  -- v12 -> v13: the bold outlined cross family (plus / cross / broken) is the new
  -- default look, matching the TOO CLOSE cross the user liked. Users still on the
  -- OLD *default* trio (crosshair / x / rings) are moved onto the matching bold
  -- marks; anyone who deliberately picked a different style keeps it.
  if db.dbVersion < 13 then
    if db.range then
      if db.range.markOK   == "crosshair" then db.range.markOK   = "plus"   end
      if db.range.markDead == "x"         then db.range.markDead = "cross" end
      if db.range.markFar  == "rings"     then db.range.markFar  = "broken" end
    end
    db.dbVersion = 13
  end

  -- v13 -> v14: "Force pet name plate" was removed (0.9.1) — on clients that
  -- publish no pet plate even with every nameplate CVar on it could never work,
  -- and it held the player's nameplate settings hostage. Leftover CVars an older
  -- build changed are still restored by MendMark on load/logout. The OUT OF
  -- RANGE default also moves from the broken-cross to the clearer ban sign.
  if db.dbVersion < 14 then
    if db.range and db.range.markFar == "broken" then db.range.markFar = "ban" end
    if db.mend then db.mend.forcePlate = nil end
    db.dbVersion = 14
  end

  -- v14 -> v15: the feed button's default moved from right-of-happiness to
  -- centred under the pet avatar (the old spot could sit off-screen and read as
  -- detached). Anyone who never dragged it gets the new spot; dragged/pinned
  -- positions are untouched.
  if db.dbVersion < 15 then
    db.dbVersion = 15
  end

  -- v15 -> v16: the 0.9.2 feed-button experiment (under-avatar default + "follow
  -- pet name") was meant for the MEND marker, not the feed button. Restore the
  -- old feed defaults (right of the happiness icon) for anyone who never dragged
  -- it, and drop the short-lived followName key.
  if db.dbVersion < 16 then
    if db.feed then
      db.feed.followName = nil
      if not db.feed.moved then
        db.feed.offsetX = 12
        db.feed.offsetY = 0
      end
    end
    db.dbVersion = 16
  end

  db.dbVersion = HK.defaults.dbVersion
  HunterKitDB = db
  HK.db = db
end

-- ---------------------------------------------------------------------------
-- Load (on ADDON_LOADED)
-- ---------------------------------------------------------------------------
function HK:Load()
  HK.isHunter = (select(2, UnitClass("player")) == "HUNTER")
  LoadDB()

  for name, mod in pairs(HK.modules) do
    if type(mod.Init) == "function" then
      local ok, err = pcall(mod.Init, HK)
      if not ok then
        print("|cffff0000HunterKit|r module " .. name .. " load error: " .. tostring(err))
      end
    end
  end

  -- one-time welcome
  if HK.db.firstRun then
    if HK.isHunter then
      print("|cff39ff14HunterKit|r loaded — /htk for settings, /htk help for commands.")
    else
      print("|cff39ff14HunterKit|r loaded — hunter features disabled (not a hunter). /htk for options.")
    end
    HK.db.firstRun = false
  end
end

-- Built-in: register ADDON_LOADED before any module could register other events.
bus:RegisterEvent("ADDON_LOADED")
bus.handlers["ADDON_LOADED"] = function(name)
  if name == ADDON_NAME then
    HK:Load()
  end
end

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------
local function AddUnlockMsg()
  if HK.db and HK.db.sound then print("HunterKit: /htk help for commands.") end
end

local function FeatureStatus()
  local d = HK.db or {}
  return string.format("feed=%s range=%s sound=%s pulse=%s mend=%s",
    tostring(d.feed and d.feed.enabled), tostring(d.range and d.range.enabled),
    tostring(d.sound and d.sound.enabled), tostring(d.pulse and d.pulse.enabled),
    tostring(d.mend and d.mend.enabled))
end

local function PrintHelp()
  print("|cff39ff14HunterKit|r v" .. HK.version .. (HK.isHunter and "" or "  [not a hunter]"))
  print("  /htk ui            — open options")
  print("  /htk help          — this help")
  print("  /htk lock|unlock   — toggle drag handles")
  print("  /htk reset         — reset positions")
  print("  /htk sound         — preview pews")
  print("  /htk feed          — show the current feed macro + food")
  print("  /htk mend          — pet mend marker diagnostics")
  print("  /htk selfcheck     — API diagnostics")
  print("  /htk gunlist       — list muted gun-sound FileDataIDs")
  print("  /htk debug         — toggle verbose logging")
  print("  features: " .. FeatureStatus())
end

SLASH_HUNTERKIT1 = "/htk"
SlashCmdList["HUNTERKIT"] = function(msg)
  msg = ((msg or ""):gsub("^%s+", ""):gsub("%s+$", "")):lower()
  if msg == "" or msg == "ui" then
    if HK.Options then HK.Options.Toggle() end
  elseif msg == "help" then
    PrintHelp()
  elseif msg == "lock" then
    if HK.Positions then HK.Positions.SetLock(true) end
    print("|cff39ff14HunterKit|r locked.")
  elseif msg == "unlock" then
    if HK.Positions then HK.Positions.SetLock(false) end
    print("|cff39ff14HunterKit|r unlocked — drag the highlighted frames to reposition.")
  elseif msg == "reset" then
    if HK.Positions then HK.Positions.Reset() end
    print("|cff39ff14HunterKit|r positions reset.")
  elseif msg == "sound" then
    if HK.Sounds then HK.Sounds.Preview() end
  elseif msg == "feed" then
    if HK.FeedPet then HK.FeedPet:PrintFeed() else print("HunterKit: FeedPet not initialised.") end
  elseif msg == "mend" then
    if HK.MendMark then HK.MendMark.PrintDiag() else print("HunterKit: MendMark not initialised.") end
  elseif msg == "gunlist" then
    if HK.Sounds then HK.Sounds.PrintGunList() end
  elseif msg == "selfcheck" then
    HK:SelfCheck()
  elseif msg == "debug" then
    HK.debug = not HK.debug
    print("|cff39ff14HunterKit|r debug " .. (HK.debug and "on" or "off"))
  else
    PrintHelp()
  end
end

-- Silence a stray linter warning (AddUnlockMsg is a placeholder for future use).
AddUnlockMsg()

-- ---------------------------------------------------------------------------
-- Selfcheck — pcall-guarded diagnostics; must never throw.
-- ---------------------------------------------------------------------------
function HK:SelfCheck()
  print("|cff39ff14HunterKit selfcheck|r")
  local function probe(label, fn)
    local ok, v = pcall(fn)
    print(string.format("  %-28s %s", label, ok and (tostring(v) or "ok") or "FAIL: " .. tostring(v)))
  end
  probe("class", function()
    local _, cls = UnitClass("player")
    return (cls == "HUNTER") and "HUNTER" or cls
  end)
  probe("pet", function()
    if UnitExists("pet") then
      return string.format("exists happy=%s", tostring(GetPetHappiness()))
    end
    return "none"
  end)
  probe("diets", function()
    return HK.FeedPet and (HK.FeedPet:GetDietsString() or "-") or "-"
  end)
  probe("passive slot", function()
    return HK.PassivePulse and (HK.PassivePulse.GetSlot() or "none") or "-"
  end)
  probe("passive alert shown", function()
    return HK.PassivePulse and (HK.PassivePulse.IsShown() and "SHOWN" or "hidden") or "-"
  end)
  probe("feed button", function()
    return HK.FeedPet and (HK.FeedPet.IsButtonValid() and "VALID" or "missing") or "-"
  end)
  probe("feed diag", function()
    return HK.FeedPet and HK.FeedPet.Diagnostic() or "-"
  end)
  probe("petframehappy global", function()
    return tostring(_G["PetFrameHappy"])
  end)
  probe("sniper mark", function()
    return HK.Range and (HK.Range.IsFrameValid() and "VALID" or "missing") or "-"
  end)
  probe("mend marker", function()
    return HK.MendMark and (HK.MendMark.IsShown() and "SHOWN" or "hidden") or "-"
  end)
  probe("mend diag", function()
    return HK.MendMark and HK.MendMark.Diagnostic() or "-"
  end)
  probe("range diag", function()
    return HK.Range and HK.Range.Diagnostic() or "-"
  end)
  probe("media filecount", function()
    return HK.Sounds and HK.Sounds.MediaCount() or "-"
  end)
  probe("mutes applied", function()
    return HK.Sounds and HK.Sounds.MutedCount() or "-"
  end)
  probe("sound diag", function()
    return HK.Sounds and HK.Sounds.Diagnostic() or "-"
  end)
  probe("db version", function()
    return HK.db and ("v" .. tostring(HK.db.dbVersion)) or "-"
  end)
end
