-- Dimension: your bags, looked after. Sells what's safe, frees space, runs bank trips and keeps
-- things in their places, and can always say why. Built on NorgannonDB and NorgannonDB_Core.
-- Plan and client findings: docs/dimension-v1.md; the look: design/suite/dimension.html.

local ADDON = ...
local Core = NorgannonCore
local DB = NorgannonDB

Dimension = { addonName = ADDON or "Dimension" }
local D = Dimension

if not (Core and Core:Require(1, 16)) or not (DB and DB:RequireSchema(1, 4)) then
  D.disabled = true
  C_Timer.After(5, function()
    print("|cfff08a9dDimension|r needs NorgannonDB 1.4 and NorgannonDB Core 1.16 or newer; it is turned off.")
  end)
  return
end

D.PREFIX = "|cfff08a9dDimension|r"
function D:Print(msg) Core:Print(msg, self.PREFIX) end

-------------------------------------------------------------------------------------------
-- Calling the client. Docs list calls for every game flavour, so any may be missing or refuse on
-- Forever: nothing assumes one works, and a secret value counts as no answer.
-------------------------------------------------------------------------------------------

local function clean(ok, ...)
  if not ok then return nil end
  local n = select("#", ...)
  if n == 0 then return nil end
  local out = { ... }
  for i = 1, n do
    if Core.IsSecret(out[i]) then out[i] = nil end
  end
  return unpack(out, 1, n)
end

---The global function name(...), with errors and secret values turned into nil.
function D.Global(name, ...)
  local fn = rawget(_G, name)
  if not fn then return nil end
  return clean(pcall(fn, ...))
end

---The namespaced client function ns.name(...): D.In("C_Bank", "CanViewBank").
function D.In(ns, name, ...)
  local t = rawget(_G, ns)
  local fn = t and t[name]
  if not fn then return nil end
  return clean(pcall(fn, ...))
end

function D.Now()
  return D.Global("GetServerTime") or time()
end

---What's in a slot, as the client's table, or nil. A table holding secrets counts as nothing there.
function D.Read(bag, slot)
  local info = D.In("C_Container", "GetContainerItemInfo", bag, slot)
  if type(info) ~= "table" or Core.IsSecret(info.itemID) or not info.itemID then return nil end
  return info
end

function D.Size(bag)
  return D.In("C_Container", "GetContainerNumSlots", bag) or 0
end

---Calls fn(bag, slot, info, entry) for every item in a list of containers from Core.Bags. fn
---returning true stops the walk.
function D.Each(list, fn)
  for _, entry in ipairs(list) do
    for slot = 1, D.Size(entry.id) do
      local info = D.Read(entry.id, slot)
      if info and fn(entry.id, slot, info, entry) then return end
    end
  end
end

---The character's own bags, without the keyring, whose slots hold nothing else.
function D.Carried()
  local out = {}
  for _, entry in ipairs(Core.Bags:BagList()) do
    if not entry.keyring then out[#out + 1] = entry end
  end
  return out
end

---free, total slots across the bags.
function D.FreeSlots()
  local free, total = 0, 0
  for _, entry in ipairs(D.Carried()) do
    local size = D.Size(entry.id)
    total = total + size
    for slot = 1, size do
      if not D.Read(entry.id, slot) then free = free + 1 end
    end
  end
  return free, total
end

-------------------------------------------------------------------------------------------
-- When not to touch anything
-------------------------------------------------------------------------------------------

---Why nothing may move right now, or nil. No bag call is flagged as blocked in combat, but a slot
---shifting under someone mid-fight is never what they want, so everything stops regardless.
function D.PauseReason()
  if D.Global("InCombatLockdown") then return "in combat" end
  local kinds = rawget(_G, "Enum") and Enum.AddOnRestrictionType
  if kinds then
    for _, kind in pairs(kinds) do
      if D.In("C_RestrictedActions", "IsAddOnRestrictionActive", kind) then return "the game has add-ons restricted" end
    end
  end
  return nil
end

---True when the cursor is holding something: that's the player mid-drag, not ours to disturb.
function D.CursorBusy()
  return D.Global("CursorHasItem") and true or false
end

-------------------------------------------------------------------------------------------
-- Saved data: rules and marks are account-wide, lists and pins belong to a character
-------------------------------------------------------------------------------------------

local DEFAULTS = {
  first = true,        -- the first-run presets haven't been answered
  tooltips = true,     -- the verdict and reason, in item tooltips
  pocket = true,       -- the sectioned bag window, instead of the game's bags
  strip = true,        -- the strip beside the game's bags, when they're showing
  marks = true,        -- the small marks on bag slots
  buyCap = 10000,      -- copper a vendor visit may spend from the carry list (1g)
  mergeAt = 6,         -- merge stacks by itself at this many free slots or fewer
  sellMethod = "cursor",
}
-- Automation is off until the first-run choice (suite plan, decision 5); the first two only say
-- what can go, and `overCap` and `destroy` are the two things that take a clear opt-in
local RULES = {
  grey = true, marked = true, cantUse = false, noRecipe = false, altKeep = true,
  autoSell = false, repair = false, merge = false, autoBank = false, tidyAfter = false, buy = false,
  overCap = false, destroy = false,
}
local HISTORY_DAYS = 30
local HISTORY_MAX = 300

local function fill(target, defaults)
  for k, v in pairs(defaults) do
    if target[k] == nil then target[k] = v end
  end
  return target
end

-- the first-run presets: which rules each one turns on
D.PRESETS = {
  show = { autoSell = false, repair = false, merge = false, autoBank = false, tidyAfter = false },
  standard = { autoSell = true, repair = true, merge = true, autoBank = false, tidyAfter = false },
  free = { autoSell = true, repair = true, merge = true, autoBank = true, tidyAfter = true },
}

function D:ApplyPreset(key)
  for rule, on in pairs(self.PRESETS[key] or {}) do self.db.rules[rule] = on end
  self.db.first = false
  self:Changed()
end

local function myKey()
  local name = D.Global("UnitName", "player") or "?"
  return tostring(D.Global("GetRealmName") or "?") .. "-" .. name
end

---This character's record: { carry, stash, stashKinds, pins, history }.
function D:Me()
  local key = myKey()
  local me = self.db.chars[key]
  if not me then
    me = {}
    self.db.chars[key] = me
  end
  me.carry = me.carry or {}             -- list of { id, want }
  me.stash = me.stash or {}             -- [itemId] = true
  me.stashKinds = me.stashKinds or {}   -- [Core.Bags kind] = true
  me.pins = me.pins or {}               -- ["bag:slot"] = itemId
  me.history = me.history or {}         -- newest first: { at, what, detail, id, count, value }
  return me
end

---Adds to History. Everything Dimension does goes through here, so nothing happens unexplained.
function D:Log(what, detail, id, count, value)
  local history = self:Me().history
  table.insert(history, 1, { at = self.Now(), what = what, detail = detail, id = id, count = count, value = value })
  local oldest = self.Now() - HISTORY_DAYS * 86400
  while #history > HISTORY_MAX or (history[#history] and history[#history].at < oldest) do
    history[#history] = nil
  end
  self:Changed()
end

Core:On("ADDON_LOADED", D, function(_, name)
  if name ~= D.addonName then return end
  Core:Off("ADDON_LOADED", D)
  local saved = rawget(_G, "DimensionDB")
  DimensionDB = fill(type(saved) == "table" and saved or {}, DEFAULTS)
  D.db = DimensionDB
  D.db.rules = fill(D.db.rules or {}, RULES)
  D.db.itemMarks = D.db.itemMarks or {}  -- [itemId] = "junk" | "keep"
  D.db.collapsed = D.db.collapsed or {}  -- [group key] = true
  D.db.assign = D.db.assign or {}        -- [itemId] = group key, chosen in Edit layout
  D.db.chars = D.db.chars or {}
  D.db.probe = D.db.probe or {}
end)

---Something changed that the marks, the strip or an open window shows.
function D:Changed()
  Core:NextFrame(function()
    if D.Overlay then D.Overlay:Refresh() end
    if D.Pocket then D.Pocket:Refresh() end
    if D.Window then D.Window:Refresh() end
    if D.Panels then D.Panels:Refresh() end
  end, "dimension.changed")
end

-------------------------------------------------------------------------------------------
-- Money, for lines of text
-------------------------------------------------------------------------------------------

function D.Money(copper)
  copper = math.floor(copper or 0)
  local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
  local out = {}
  if g > 0 then out[#out + 1] = "|cffe7c66c" .. g .. "g|r" end
  if s > 0 then out[#out + 1] = "|cffc8c8c8" .. s .. "s|r" end
  if c > 0 or #out == 0 then out[#out + 1] = "|cffc07a45" .. c .. "c|r" end
  return table.concat(out, " ")
end

-------------------------------------------------------------------------------------------
-- Opening
-------------------------------------------------------------------------------------------

function D:Toggle()
  local win = self.Window and self.Window:Get()
  if not win then return end
  if win:IsShown() then win:Hide() else self.Window:Open() end
end

Core:RegisterAddon("dimension", {
  version = C_AddOns and C_AddOns.GetAddOnMetadata(D.addonName, "Version") or "0.9.0",
  open = function() D:Toggle() end,
})

SLASH_DIMENSION1 = "/dim"
SLASH_DIMENSION2 = "/dimension"
SlashCmdList["DIMENSION"] = function(msg)
  local lower = string.lower(strtrim(msg or ""))
  if lower == "" then
    D:Toggle()
  elseif lower == "settings" or lower == "options" then
    D:OpenSettings()
  elseif lower == "bags" then
    D.Pocket:SetEnabled(not D.db.pocket)
    D:Print(D.db.pocket and "Using Dimension's bag window." or "Using the game's own bags.")
  elseif lower == "tidy" then
    D.Tidy:Run()
  elseif lower == "room" then
    D.Window:Open("room")
  elseif lower == "probe" or lower:match("^probe ") then
    D.Probe:Run(lower:match("^probe%s+(%S+)"))
  else
    D:Print("/dim opens the window. Also: /dim bags, /dim tidy, /dim room, /dim settings, /dim probe [sell | move | sort]")
  end
end

-- the minimap button and the client's addon menu: click opens or closes, right-click the settings
local function onClick(button)
  if button == "RightButton" then D:OpenSettings() else D:Toggle() end
end
local function tooltip(tt)
  tt:AddLine("Dimension", .941, .541, .616)
  tt:AddLine("Your bags, looked after", 1, 1, 1)
  tt:AddLine("Click: open or close  ·  Right-click: settings  ·  Drag: move", .43, .4, .32)
end
Core:OnLogin(function() Core.MinimapButton:Add("dimension", { onClick = onClick, tooltip = tooltip }) end)
function Dimension_OnAddonCompartmentClick(_, button) onClick(button) end
function Dimension_OnAddonCompartmentEnter(_, frame)
  GameTooltip:SetOwner(frame, "ANCHOR_LEFT")
  tooltip(GameTooltip)
  GameTooltip:Show()
end
function Dimension_OnAddonCompartmentLeave() GameTooltip:Hide() end

BINDING_HEADER_DIMENSION = "Dimension"
BINDING_NAME_DIMENSION_TOGGLE = "Open or close Dimension"
BINDING_NAME_DIMENSION_MARK = "Mark the hovered item: Junk, Keep, none"
BINDING_NAME_DIMENSION_PIN = "Pin the hovered bag slot"
BINDING_NAME_DIMENSION_TIDY = "Tidy my bags"
