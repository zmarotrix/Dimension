-- Swapping in a bigger bag. The game only takes a bag off its slot when that bag is empty, so swapping one
-- that holds anything means emptying it by hand first, and counting whether the rest of your bags have room.
-- This does both:
--
--   * Drop a bag on a bag slot whose bag still holds things, and the game refuses. Dimension notices, moves the
--     old bag's items into your other bags, then puts the new bag in. If they won't fit, it says how many slots
--     to free first and touches nothing.
--   * A bag you carry that's bigger than one you wear says so on its tooltip, gets a row in Make room, and is
--     named once in chat when it first turns up. /dim swap puts the best one in.
--
-- Nothing leaves your bags: items only move between them, through the mover, which pauses for fights and for
-- a player holding something. The old bag ends up where the new one was. Bagshui (absir/Bagshui) only keeps
-- its "new item" marks across a bag move, so there was nothing to take from it beyond PutItemInBag.

local Core = NorgannonCore
local D = Dimension
if D.disabled then return end

local Swap = {}
D.Swap = Swap
local Room, Mover = D.Room, D.Mover

local CONTAINER, QUIVER = 1, 11      -- Enum.ItemClass: the items that go in a bag slot
local CHECK_AFTER = 1                -- seconds before checking the game really took the new bag
local REFUSAL_WINDOW = 2             -- seconds a dropped bag's refusal is watched for
local BIND_POPUPS = { "EQUIP_BIND", "AUTOEQUIP_BIND", "EQUIP_BIND_TRADEABLE", "EQUIP_BIND_REFUNDABLE" }

local function plural(n, one, many) return n .. " " .. (n == 1 and one or (many or one .. "s")) end

---True for an item that goes in a bag slot.
function Swap.IsBag(id)
  local classId = select(6, D.In("C_Item", "GetItemInfoInstant", id))
  return classId == CONTAINER or classId == QUIVER
end

---The family of things a bag holds: 0 for an ordinary bag.
local function familyOf(id)
  return D.In("C_Item", "GetItemFamily", id) or 0
end

-- "16 Slot Bag": the game's own format, turned into a pattern, with the English one as a fallback
local function slotPatterns()
  local out = {}
  local fmt = rawget(_G, "CONTAINER_SLOTS")
  if type(fmt) == "string" then
    local p = fmt:gsub("%%%d%$", "%%"):gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    p = p:gsub("%%d", "(%%d+)"):gsub("%%s", ".+")
    out[#out + 1] = p
  end
  out[#out + 1] = "(%d+) Slot"
  return out
end

---How many slots a bag item has: learnt from bags worn before, else read from its tooltip. nil if unknown.
function Swap.SlotsOf(id, bag, slot)
  D.db.bagSizes = D.db.bagSizes or {}
  if D.db.bagSizes[id] then return D.db.bagSizes[id] end
  local data = bag and D.In("C_TooltipInfo", "GetBagItem", bag, slot)
  if type(data) ~= "table" or type(data.lines) ~= "table" then return nil end
  for _, line in ipairs(data.lines) do
    local text = line.leftText
    if type(text) == "string" and not Core.IsSecret(text) then
      for _, pattern in ipairs(slotPatterns()) do
        local n = tonumber(text:match(pattern))
        if n and n > 0 then
          D.db.bagSizes[id] = n
          return n
        end
      end
    end
  end
  return nil
end

---The bag slots a bag can be swapped into, with what's in them: { { id, inv, size, family, itemId, name } }.
---The backpack can't be swapped; the reagent bag and keyring aren't bag slots for this.
function Swap.Slots()
  local out = {}
  D.db.bagSizes = D.db.bagSizes or {}
  for _, entry in ipairs(Core.Bags:BagList()) do
    if entry.id ~= 0 and not entry.reagent and not entry.keyring then
      local inv = D.In("C_Container", "ContainerIDToInventoryID", entry.id)
      if inv then
        local itemId = D.Global("GetInventoryItemID", "player", inv)
        local size = D.Size(entry.id)
        local _, family = D.In("C_Container", "GetContainerNumFreeSlots", entry.id)
        if itemId and size > 0 then D.db.bagSizes[itemId] = size end   -- learnt for when it's in a bag again
        local used = 0
        for slot = 1, size do if D.Read(entry.id, slot) then used = used + 1 end end
        out[#out + 1] = { id = entry.id, inv = inv, size = size, used = used, family = family or 0, itemId = itemId, name = entry.name }
      end
    end
  end
  return out
end

---A carried bag item, by where it is: { bag, slot, id, link, name, size, family }.
local function bagRef(bag, slot, info)
  return { bag = bag, slot = slot, id = info.itemID, link = info.hyperlink, name = info.itemName or D.Window and D.Window.ItemName(info.itemID) or ("Item " .. info.itemID),
    size = Swap.SlotsOf(info.itemID, bag, slot), family = familyOf(info.itemID) }
end

---What swapping a new bag into a bag slot takes: the moves that empty the old bag, and how many items have
---nowhere to go. { new, target, moves, held, free, short, newTo }. newTo is where the new bag moves to when it
---sits in the bag being emptied.
function Swap.Plan(new, target)
  local plan = { new = new, target = target, moves = {}, held = 0, free = 0, short = 0 }
  if target.size == 0 then return plan end
  -- free slots everywhere else: special bags first, so ordinary space is left for what only fits there
  local special, ordinary = {}, {}
  for _, entry in ipairs(D.Carried()) do
    if entry.id ~= target.id then
      local slots = {}
      for slot = 1, D.Size(entry.id) do
        if not D.Read(entry.id, slot) and not (entry.id == new.bag and slot == new.slot) then slots[#slots + 1] = slot end
      end
      if #slots > 0 then
        local _, family = D.In("C_Container", "GetContainerNumFreeSlots", entry.id)
        local list = (entry.reagent or (family and family ~= 0)) and special or ordinary
        list[#list + 1] = { entry = entry, slots = slots }
        plan.free = plan.free + #slots
      end
    end
  end
  local function place(id, isBag)
    local family = D.In("C_Item", "GetItemFamily", id)
    local isReagent = D.Rules.Facts(id).reagent
    if not isBag then
      for _, t in ipairs(special) do
        if #t.slots > 0 and Room.Accepts(t.entry, id, family, isReagent) then return t.entry.id, table.remove(t.slots, 1) end
      end
    end
    for _, t in ipairs(ordinary) do
      if #t.slots > 0 then return t.entry.id, table.remove(t.slots, 1) end
    end
  end
  for slot = 1, D.Size(target.id) do
    local info = D.Read(target.id, slot)
    if info then
      plan.held = plan.held + 1
      local bag, to = place(info.itemID, Swap.IsBag(info.itemID))
      if bag then
        plan.moves[#plan.moves + 1] = { from = { target.id, slot }, to = { bag, to }, id = info.itemID }
        if target.id == new.bag and slot == new.slot then plan.newTo = { bag, to } end
      else
        plan.short = plan.short + 1
      end
    end
  end
  return plan
end

---What to say when a plan can't go ahead for want of room.
function Swap.ShortText(plan)
  return string.format("Free %s first: your %s holds %s and your other bags have %s free.",
    plural(plan.short, "more slot"), plan.target.name, plural(plan.held, "item"), plural(plan.free, "slot"))
end

---Which bag slot a new bag would best go in, or nil: an empty slot first, else the smallest bag of the same
---kind that's smaller than it. A profession bag only replaces one of its own kind, and an ordinary bag never
---replaces a profession bag: that was somebody's choice.
function Swap.TargetFor(new, slots)
  local best
  slots = slots or Swap.Slots()
  for _, s in ipairs(slots) do
    if s.size == 0 then return s end
  end
  if not new.size then return nil end
  for _, s in ipairs(slots) do
    -- the smallest, and of two the same size the one with less to move
    if s.family == new.family and s.size < new.size
      and (not best or s.size < best.size or s.size == best.size and s.used < best.used) then best = s end
  end
  return best
end

---Every bag you carry that would give you more room: { { new, target, gain, plan } }, the biggest gain first.
function Swap.Upgrades()
  local out, slots = {}, Swap.Slots()
  D.Each(D.Carried(), function(bag, slot, info)
    if Swap.IsBag(info.itemID) and not info.isLocked then
      local new = bagRef(bag, slot, info)
      local target = Swap.TargetFor(new, slots)
      if target then
        out[#out + 1] = { new = new, target = target, gain = (new.size or 0) - target.size, plan = Swap.Plan(new, target) }
      end
    end
  end)
  table.sort(out, function(a, b)
    if a.gain ~= b.gain then return a.gain > b.gain end
    return a.new.bag * 100 + a.new.slot < b.new.bag * 100 + b.new.slot
  end)
  return out
end

---The upgrade a carried bag item would be, or nil: for its tooltip.
function Swap.UpgradeFor(id)
  for _, u in ipairs(Swap.Upgrades()) do
    if u.new.id == id then return u end
  end
end

-------------------------------------------------------------------------------------------
-- Doing it
-------------------------------------------------------------------------------------------

local equipping = false   -- our own PutItemInBag call, which the hook mustn't take for the player's

local function bindPopupShowing()
  for _, which in ipairs(BIND_POPUPS) do
    if D.Global("StaticPopup_Visible", which) then return true end
  end
  return false
end

---Where the new bag is now: it may have been moved out of the bag being emptied.
local function findNew(plan)
  if plan.newTo then return plan.newTo[1], plan.newTo[2] end
  local info = D.Read(plan.new.bag, plan.new.slot)
  if info and info.itemID == plan.new.id then return plan.new.bag, plan.new.slot end
  local bag, slot
  D.Each(D.Carried(), function(b, s, i)
    if b ~= plan.target.id and i.itemID == plan.new.id and (not plan.new.link or i.hyperlink == plan.new.link) then
      bag, slot = b, s
      return true
    end
  end)
  return bag, slot
end

local function report(ok, plan)
  local new, old = plan.new.name, plan.target.itemId and plan.target.name
  if ok then
    D:Log("Swapped in " .. new, old and ("Your " .. old .. " is where it was. Nothing left your bags") or "Into an empty bag slot", plan.new.id)
    D:Print(old and string.format("%s is in, and your %s is in your bags.", new, old) or (new .. " is in."))
  else
    D:Print(string.format("The game didn't take %s. Your %s is empty now, so drag %s onto it.", new, old or "bag slot", new))
  end
  D:Changed()
end

---Puts the new bag in its slot, once the old one is empty. The game answers a moment later, so it checks then.
local function equip(plan)
  local bag, slot = findNew(plan)
  if not bag then
    D:Print(plan.new.name .. " isn't in your bags any more, so nothing was swapped.")
    return false
  end
  if D.CursorBusy() then D.Global("ClearCursor") end
  D.In("C_Container", "PickupContainerItem", bag, slot)
  if not D.CursorBusy() then
    report(false, plan)
    return false
  end
  equipping = true
  D.Global("PutItemInBag", plan.target.inv)
  equipping = false
  if D.CursorBusy() then
    if bindPopupShowing() then
      D:Print("Say yes to the game's question to finish: " .. plan.new.name .. " binds to you when it goes in.")
      return true
    end
    D.Global("ClearCursor")
    report(false, plan)
    return false
  end
  D.In("C_Timer", "After", CHECK_AFTER, function()
    report(D.Global("GetInventoryItemID", "player", plan.target.inv) == plan.new.id, plan)
  end)
  return true
end

---Empties the old bag into the others, then puts the new one in. False and why if it can't start.
function Swap:Run(plan)
  local pause = D.PauseReason()
  if pause then return false, pause == "in combat" and "You're in combat: try again after." or "A fight or match is under way: try again after." end
  if Mover:Active() then return false, "Something else is moving items: try again in a moment." end
  if D.Vendor and D.Vendor.Selling and D.Vendor:Selling() then return false, "Selling is under way: try again in a moment." end
  if plan.short > 0 then return false, Swap.ShortText(plan) end
  if #plan.moves == 0 then return equip(plan), nil end
  D:Print(string.format("Moving %s out of your %s, then putting %s in.", plural(#plan.moves, "item"), plan.target.name, plan.new.name))
  Mover:Run(plan.moves, { label = "Emptying " .. plan.target.name, onDone = function(reason)
    if reason then
      D:Print("Stopped before swapping: " .. reason .. ". Everything is still in your bags.")
      return
    end
    for slot = 1, D.Size(plan.target.id) do
      if D.Read(plan.target.id, slot) then
        D:Print(string.format("Your %s isn't empty yet, so %s isn't in. Try again in a moment.", plan.target.name, plan.new.name))
        return
      end
    end
    equip(plan)
  end })
  return true
end

---/dim swap, and the Make room button: the biggest gain first, or the one asked for.
function Swap:Best(upgrade)
  upgrade = upgrade or Swap.Upgrades()[1]
  if not upgrade then
    D:Print("No bag you carry is bigger than one you're wearing.")
    return false
  end
  local ok, why = self:Run(upgrade.plan)
  if not ok and why then D:Print(upgrade.new.name .. " can't go in yet. " .. why) end
  return ok
end

-------------------------------------------------------------------------------------------
-- Catching a bag dropped on a full one
-------------------------------------------------------------------------------------------

local attempt   -- { inv, ref, at } while a dropped bag's answer is awaited

---Where the bag on the cursor came from: the locked slot holding it.
local function cursorBag()
  local kind, id = D.Global("GetCursorInfo")
  if kind ~= "item" or not id or not Swap.IsBag(id) then return nil end
  local found
  D.Each(D.Carried(), function(bag, slot, info)
    if info.itemID == id and info.isLocked then
      found = bagRef(bag, slot, info)
      return true
    end
  end)
  return found
end

local function slotByInv(inv)
  for _, s in ipairs(Swap.Slots()) do
    if s.inv == inv then return s end
  end
end

---After a dropped bag: if the game refused because the old bag holds things, empty it and swap.
function Swap:Settle()
  local a = attempt
  if not a or GetTime() - a.at > REFUSAL_WINDOW then return end
  local target = slotByInv(a.inv)
  if not target or target.itemId == a.ref.id then attempt = nil return end   -- it went in
  local holds = false
  for slot = 1, D.Size(target.id) do
    if D.Read(target.id, slot) then holds = true break end
  end
  if not holds then return end   -- not refused for being full; the game has its own reasons
  attempt = nil
  if D.CursorBusy() then D.Global("ClearCursor") end   -- it goes back where it was
  local plan = Swap.Plan(a.ref, target)
  local ok, why = self:Run(plan)
  if not ok and why then
    D:Print(string.format("%s can't go in yet. %s", a.ref.name, why))
    if plan.short > 0 then D:Print("Make room (/dim room) lists the cheapest ways to free them.") end
  end
end

local function dropped(inv)
  if equipping or not (D.db and D.db.bagSwap) or not inv then return end
  local ref = cursorBag()
  if not ref then return end
  attempt = { inv = inv, ref = ref, at = GetTime() }
  Core:NextFrame(function() Swap:Settle() end, "dimension.swap")
end
Swap.Dropped = dropped

if rawget(_G, "PutItemInBag") then hooksecurefunc("PutItemInBag", dropped) end
-- the game's refusal comes as an error; it may come after the cursor has already let go
Core:On("UI_ERROR_MESSAGE", "dimension.swap", function()
  if attempt then Core:NextFrame(function() Swap:Settle() end, "dimension.swap") end
end)

-------------------------------------------------------------------------------------------
-- Saying so, once per bag, when a bigger one turns up
-------------------------------------------------------------------------------------------

function Swap:Notice()
  if not (D.db and D.db.bagSwap) or D.PauseReason() then return end
  local told = D:Me()
  told.toldBags = told.toldBags or {}
  for _, u in ipairs(Swap.Upgrades()) do
    if not told.toldBags[u.new.id] then
      told.toldBags[u.new.id] = true
      local where = u.target.itemId and string.format("%d more slots than your %s", u.gain, u.target.name) or "a bag for your empty bag slot"
      D:Print(string.format("%s is %s. /dim swap puts it in%s.", u.new.name, where,
        u.plan.short > 0 and (", once you free " .. plural(u.plan.short, "more slot")) or ""))
    end
  end
end

Core:On("BAG_UPDATE_DELAYED", "dimension.swap", function()
  Core:NextFrame(function() Swap:Notice() end, "dimension.swap.notice")
end)
