-- Dimension: your bags, looked after. Sells what's safe, frees space, runs bank trips and keeps
-- things in their places, and can always say why. Built on NorgannonDB and NorgannonDB_Core.
-- Plan and client findings: docs/dimension-v1.md; the look: design/suite/dimension.html.

local ADDON = ...
local Core = NorgannonCore

if not (Core and Core.NewAddon) then
  Dimension = { disabled = true }
  print("Dimension needs Norgannon Core 1.20 or newer; it is turned off.")
  return
end

Dimension = {}
local D = Dimension

-------------------------------------------------------------------------------------------
-- Saved data: rules and marks are account-wide, lists and pins belong to a character
-------------------------------------------------------------------------------------------

-- Automation is off until the first-run choice (suite plan, decision 5); the first two only say
-- what can go, and `overCap` and `destroy` are the two things that take a clear opt-in
local RULES = {
  grey = true, marked = true, cantUse = false, noRecipe = false, altKeep = true,
  autoSell = false, repair = false, merge = false, autoBank = false, tidyAfter = false, buy = false,
  overCap = false, destroy = false,
}

D.DEFAULTS = {
  first = true,        -- the first-run presets haven't been answered
  tooltips = true,     -- the verdict and reason, in item tooltips
  pocket = true,       -- the sectioned bag window, instead of the game's bags
  strip = true,        -- the strip beside the game's bags, when they're showing
  marks = true,        -- the small marks on bag slots
  fillBar = true,      -- the bar under the items showing how full the bags are
  bagSwap = true,      -- empty a bag for you when you swap in a bigger one
  bagSizes = {},       -- [itemId] = slots, learnt from bags worn and tooltips
  buyCap = 10000,      -- copper a vendor visit may spend from the carry list (1g)
  mergeAt = 6,         -- merge stacks by itself at this many free slots or fewer
  sellMethod = "cursor",
  itemMarks = {},      -- [itemId] = "junk" | "keep"
  collapsed = {},      -- [group key] = true
  assign = {},         -- [itemId] = group key, chosen in Edit layout
  names = {},          -- [group key] = the player's name for it
  chars = {},          -- ["Realm-Name"] = a character's lists, pins and history
  probe = {},
}
D.DEFAULTS.rules = RULES

-- The suite's plumbing (Core:NewAddon): version checks, DimensionDB with its defaults, the slash command, the minimap
-- row and the add-on menu. Left-click and /dim open the window; right-click opens settings.
Core:NewAddon("dimension", {
  folder = ADDON, api = { 1, 20 }, data = { 1, 4 },
  db = "DimensionDB", defaults = D.DEFAULTS,
  slash = { "/dim", "/dimension" },
  commands = {
    bags = { function()
      D.Pocket:SetEnabled(not D.db.pocket)
      D:Print(D.db.pocket and "Using Dimension's bag window." or "Using the game's own bags.")
    end, "switch between Dimension's bag window and the game's own bags" },
    tidy = { function() D.Tidy:Run() end, "tidy your bags" },
    room = { function() D.Window:Open("room") end, "what would free space" },
    swap = { function() D.Swap:Best() end, "put in the biggest bag you carry, emptying the one it replaces" },
    probe = { function(rest) D.Probe:Run(rest ~= "" and string.lower(rest) or nil) end, "[sell | move | sort]: check what the client allows" },
  },
})
if D.disabled then return end

-------------------------------------------------------------------------------------------
-- Calling the client: Core's helpers. Docs list calls for every game flavour, so any may be missing or refuse on
-- Forever: nothing assumes one works, and a secret value counts as no answer.
-------------------------------------------------------------------------------------------

D.Global, D.In, D.Now = Core.Global, Core.In, Core.Now

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

---Why nothing may move right now, or nil: Core:Restricted("fight"), which is combat, an encounter, M+ or a PvP match.
---Chat and Map restrictions don't stop items moving: checking every kind stopped selling at a vendor out of a fight
---(Maro, 2026-11-06). No bag call is flagged as blocked in combat, but a slot shifting under someone mid-fight is never
---what they want, so everything stops regardless.
function D.PauseReason()
  local why = Core:Restricted("fight")
  if why == "combat" then return "in combat" end
  if why then return "a fight or match is under way" end
  return nil
end

---The names of every restriction active now, whatever they mean, for the probe.
function D.ActiveRestrictions()
  local out = {}
  local kinds = rawget(_G, "Enum") and Enum.AddOnRestrictionType
  for name, kind in pairs(kinds or {}) do
    if D.In("C_RestrictedActions", "IsAddOnRestrictionActive", kind) then out[#out + 1] = name end
  end
  table.sort(out)
  return out
end

---True when the cursor is holding something: that's the player mid-drag, not ours to disturb.
function D.CursorBusy()
  return D.Global("CursorHasItem") and true or false
end

-------------------------------------------------------------------------------------------
-- Saved data: rules and marks are account-wide, lists and pins belong to a character
-------------------------------------------------------------------------------------------

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

local HISTORY_DAYS = 30
local HISTORY_MAX = 300

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
  if g > 0 then out[#out + 1] = "|cffffd100" .. g .. "g|r" end
  if s > 0 then out[#out + 1] = "|cffe6e6e6" .. s .. "s|r" end
  if c > 0 or #out == 0 then out[#out + 1] = "|cffeda55f" .. c .. "c|r" end
  return table.concat(out, " ")
end

---Money as the game's own bags show it: white numbers and coin icons, with every coin below the largest.
function D.Coins(copper)
  copper = math.floor(copper or 0)
  local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
  local function coin(amount, metal) return amount .. "|TInterface\\MoneyFrame\\UI-" .. metal .. "Icon:0:0:2:0|t" end
  local out = {}
  if g > 0 then out[#out + 1] = coin(g, "Gold") end
  if g > 0 or s > 0 then out[#out + 1] = coin(s, "Silver") end
  out[#out + 1] = coin(c, "Copper")
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

BINDING_HEADER_DIMENSION = "Dimension"
BINDING_NAME_DIMENSION_TOGGLE = "Open or close Dimension"
BINDING_NAME_DIMENSION_MARK = "Mark the hovered item: Junk, Keep, none"
BINDING_NAME_DIMENSION_PIN = "Pin the hovered bag slot"
BINDING_NAME_DIMENSION_TIDY = "Tidy my bags"
