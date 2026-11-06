-- Making room: first what costs nothing (merging partial stacks, putting things in the bag made for
-- them), then the list of the cheapest things to clear. Destroying sits last: DeleteCursorItem is
-- restricted on this client, so it needs a real click, one per stack, and only ever comes from a
-- button the player pressed.

local Core = NorgannonCore
local D = Dimension
if D.disabled then return end

local Room = {}
D.Room = Room
local Rules, Mover = D.Rules, D.Mover

local AUTO_COOLDOWN = 5   -- seconds between looks at merging by itself
local TOSS_ROWS = 8
local MAX_QUALITY_TO_TOSS = 1

---Stack size, or nil if the client doesn't know yet. Without it nothing can be planned safely.
local function maxStack(id)
  local size = D.In("C_Item", "GetItemMaxStackSizeByID", id)
  if size then return size end
  return Rules.Facts(id).stack
end
Room.MaxStack = maxStack

local function pinned(bag, slot)
  return D:Me().pins[bag .. ":" .. slot] ~= nil
end

---A plan of merges, and how many slots it frees. Two copies only count as the same item when their
---links agree, so an enchant or a suffix is never merged away. Pinned stacks can receive, not leave.
function Room:MergePlan()
  local groups = {}
  D.Each(D.Carried(), function(bag, slot, info)
    local size = maxStack(info.itemID)
    if size and size > 1 and (info.stackCount or 1) < size and not info.isLocked then
      local key = tostring(info.hyperlink or info.itemID)
      groups[key] = groups[key] or { id = info.itemID, size = size, stacks = {} }
      table.insert(groups[key].stacks, { bag = bag, slot = slot, count = info.stackCount or 1, pinned = pinned(bag, slot) })
    end
  end)
  local moves, freed, names = {}, 0, {}
  for _, group in pairs(groups) do
    if #group.stacks > 1 then
      table.sort(group.stacks, function(a, b)
        if a.pinned ~= b.pinned then return a.pinned end   -- fill pinned stacks first
        if a.count ~= b.count then return a.count > b.count end
        if a.bag ~= b.bag then return a.bag < b.bag end
        return a.slot < b.slot
      end)
      local into, from = 1, #group.stacks
      while into < from do
        local target, source = group.stacks[into], group.stacks[from]
        if source.pinned then break end
        local room = group.size - target.count
        if room <= 0 then
          into = into + 1
        else
          moves[#moves + 1] = { from = { source.bag, source.slot }, to = { target.bag, target.slot }, id = group.id }
          local moved = math.min(room, source.count)
          target.count = target.count + moved
          source.count = source.count - moved
          if source.count == 0 then
            freed = freed + 1
            from = from - 1
          else
            -- the rest of the stack stays where it was; the target is full now
            into = into + 1
          end
        end
      end
      names[#names + 1] = group.id
    end
  end
  return moves, freed, names
end

---True if a container can hold the item. Reagent bags take only reagents and a special bag only its
---own family; asking the client saves a refused move later.
function Room.Accepts(entry, id, family, isReagent)
  local _, bagFamily = D.In("C_Container", "GetContainerNumFreeSlots", entry.id)
  if entry.reagent then return isReagent and true or false end
  if bagFamily and bagFamily ~= 0 then
    return family ~= nil and bit.band(bagFamily, family) ~= 0
  end
  return true
end

---Things in ordinary bags that have a place in a special one: soul shards, herbs, ammunition and
---reagents, into free slots of the bag made for them.
function Room:PutAwayPlan()
  local free, ordinary = {}, {}
  for _, entry in ipairs(D.Carried()) do
    local _, bagFamily = D.In("C_Container", "GetContainerNumFreeSlots", entry.id)
    if entry.reagent or (bagFamily and bagFamily ~= 0) then
      local slots = {}
      for slot = 1, D.Size(entry.id) do
        if not D.Read(entry.id, slot) then slots[#slots + 1] = slot end
      end
      if #slots > 0 then free[#free + 1] = { entry = entry, slots = slots } end
    else
      ordinary[#ordinary + 1] = entry
    end
  end
  local moves = {}
  if #free == 0 then return moves end
  D.Each(ordinary, function(bag, slot, info)
    if not info.isLocked and not pinned(bag, slot) then
      local family = D.In("C_Item", "GetItemFamily", info.itemID)
      local isReagent = Rules.Facts(info.itemID).reagent
      for _, target in ipairs(free) do
        if #target.slots > 0 and Room.Accepts(target.entry, info.itemID, family, isReagent) then
          moves[#moves + 1] = { from = { bag, slot }, to = { target.entry.id, table.remove(target.slots, 1) }, id = info.itemID }
          break
        end
      end
    end
  end)
  return moves
end

---Merges and puts away. onDone(reason, moved) as for the mover. False if there's nothing to do or
---something else is moving.
function Room:FreeWithoutCost(onDone)
  local moves = self:MergePlan()
  local away = self:PutAwayPlan()
  for _, move in ipairs(away) do moves[#moves + 1] = move end
  if #moves == 0 then return false end
  return Mover:Run(moves, { label = "Merging stacks", onDone = function(reason, moved)
    if moved > 0 then D:Log("Merged and put away", moved .. " moves. Nothing left your bags") end
    if onDone then onDone(reason, moved) end
  end })
end

---What Make room shows, cheapest way first:
---{ free = {moves, slots}, sell = Rules:SellList(), toss = { bag, slot, id, count, value } }.
function Room:List()
  local moves, freed = self:MergePlan()
  local away = self:PutAwayPlan()
  local toss = {}
  D.Each(D.Carried(), function(bag, slot, info)
    local verdict = Rules:Verdict(info.itemID, info, bag, slot)
    local facts = Rules.Facts(info.itemID)
    local price = facts.price or 0
    -- only ever things with a price the game told us, no better than white, that no rule wants
    if verdict == "stay" and price > 0 and not info.hasNoValue and (info.quality or facts.quality or 9) <= MAX_QUALITY_TO_TOSS then
      toss[#toss + 1] = { bag = bag, slot = slot, id = info.itemID, count = info.stackCount or 1, value = price * (info.stackCount or 1), name = info.itemName, link = info.hyperlink }
    end
  end)
  table.sort(toss, function(a, b)
    if a.value ~= b.value then return a.value < b.value end
    if a.bag ~= b.bag then return a.bag < b.bag end
    return a.slot < b.slot
  end)
  for i = #toss, TOSS_ROWS + 1, -1 do toss[i] = nil end
  return { moves = #moves + #away, slots = freed + #away, sell = Rules:SellList(), toss = toss }
end

---Destroys one stack. Only called from a button the player pressed, because the client refuses
---anything else, and only with the opt-in on. It checks the slot still holds what the row showed.
function Room:Destroy(bag, slot, id)
  if not D.db.rules.destroy then return false, "switched off" end
  if D.PauseReason() then return false, D.PauseReason() end
  if D.CursorBusy() then return false, "you're holding an item" end
  local info = D.Read(bag, slot)
  if not info or info.itemID ~= id or info.isLocked then return false, "it has moved" end
  if Rules:Verdict(id, info, bag, slot) == "keep" then return false, "a rule keeps it" end
  D.In("C_Container", "PickupContainerItem", bag, slot)
  if not D.CursorBusy() then return false, "the game didn't pick it up" end
  D.Global("DeleteCursorItem")
  if D.CursorBusy() then
    D.Global("ClearCursor")
    return false, "the game refused"
  end
  D:Log("Destroyed " .. tostring(info.itemName or id), "You pressed Destroy", id, info.stackCount or 1)
  return true
end

-------------------------------------------------------------------------------------------
-- Merging by itself, when the rule is on and bags are getting full
-------------------------------------------------------------------------------------------

local lastAuto = 0

local function look()
  if not (D.db and D.db.rules.merge) then return end
  if Mover:Active() or D.PauseReason() or D.CursorBusy() then return end
  if D.Vendor and D.Vendor:Selling() then return end
  local free = D.FreeSlots()
  if free > (D.db.mergeAt or 0) then return end
  local now = GetTime()
  if now - lastAuto < AUTO_COOLDOWN then return end
  lastAuto = now
  local moves, freed = Room:MergePlan()
  if freed <= 0 then return end
  Mover:Run(moves, { label = "Merging stacks", onDone = function(reason)
    if not reason then
      D:Log("Merged stacks", string.format("%d %s freed. Nothing left your bags", freed, freed == 1 and "slot" or "slots"))
      D:Print(string.format("Bags were filling up, so I merged partial stacks: %d %s freed.", freed, freed == 1 and "slot" or "slots"))
    end
  end })
end
Room.Look = look

Core:On("BAG_UPDATE_DELAYED", "dimension.room", function()
  Core:NextFrame(look, "dimension.room")
end)
Core:On("PLAYER_REGEN_ENABLED", "dimension.room", function()
  Core:NextFrame(look, "dimension.room")
end)
