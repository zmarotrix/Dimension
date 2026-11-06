-- At the bank: one carry list and one stash list, run in both directions. Pinned slots never move.
-- The plan is worked out once against what's in the slots; the mover checks each slot again before
-- it touches it, so anything that changed in between is skipped, not misplaced.

local Core = NorgannonCore
local D = Dimension
if D.disabled then return end

local Bank = {}
D.Bank = Bank
local Rules, Mover = D.Rules, D.Mover

local open = false
Bank.lastResult = nil

function Bank:IsOpen() return open end

---Free slots and stacks with room for an item in a set of containers, as a chooser. It reserves
---what it hands out, so two moves in one plan can't aim at the same slot.
local function chooser(containers)
  local free, taken = {}, {}
  for _, entry in ipairs(containers) do
    local list = {}
    for slot = 1, D.Size(entry.id) do
      if not D.Read(entry.id, slot) then list[#list + 1] = slot end
    end
    free[#free + 1] = { entry = entry, slots = list }
  end
  return function(id, count)
    local family = D.In("C_Item", "GetItemFamily", id)
    local isReagent = Rules.Facts(id).reagent
    local size = D.Room.MaxStack(id) or 1
    -- first a stack of the same thing with room for all of it
    for _, entry in ipairs(containers) do
      for slot = 1, D.Size(entry.id) do
        local info = D.Read(entry.id, slot)
        local key = entry.id .. ":" .. slot
        if info and info.itemID == id and not taken[key] and (info.stackCount or 1) + count <= size then
          taken[key] = true
          return entry.id, slot
        end
      end
    end
    for _, place in ipairs(free) do
      if #place.slots > 0 and D.Room.Accepts(place.entry, id, family, isReagent) then
        return place.entry.id, table.remove(place.slots, 1)
      end
    end
  end
end

---{ take = { {from, to, id, count} }, put = { ... }, noRoom = n } for this character's lists.
function Bank:Plan()
  local me = D:Me()
  local carried, bank = D.Carried(), Core.Bags:BankList("Character")
  local take, put, noRoom = {}, {}, 0
  local intoBags, intoBank = chooser(carried), chooser(bank)

  local have = {}
  D.Each(carried, function(_, _, info)
    have[info.itemID] = (have[info.itemID] or 0) + (info.stackCount or 1)
  end)
  local onCarry = {}
  for _, want in ipairs(me.carry) do
    onCarry[want.id] = true
    local need = (want.want or 0) - (have[want.id] or 0)
    if need > 0 then
      D.Each(bank, function(bag, slot, info)
        if info.itemID == want.id and need > 0 and not info.isLocked then
          local count = math.min(need, info.stackCount or 1)
          local toBag, toSlot = intoBags(want.id, count)
          if toBag then
            take[#take + 1] = { from = { bag, slot }, to = { toBag, toSlot }, id = want.id, count = count }
            need = need - count
          else
            noRoom = noRoom + 1
          end
        end
        return need <= 0
      end)
    end
  end

  D.Each(carried, function(bag, slot, info)
    local id = info.itemID
    if not onCarry[id] and not info.isLocked and not me.pins[bag .. ":" .. slot] then
      -- naming an item always counts; a whole kind never takes what a quest in the log wants
      local wanted = me.stash[id] or (me.stashKinds[Core.Bags.Kind(id, info.quality)] and not Rules.QuestWants(id))
      if wanted then
        local toBag, toSlot = intoBank(id, info.stackCount or 1)
        if toBag then
          put[#put + 1] = { from = { bag, slot }, to = { toBag, toSlot }, id = id, count = info.stackCount or 1 }
        else
          noRoom = noRoom + 1
        end
      end
    end
  end)
  return { take = take, put = put, noRoom = noRoom }
end

---Runs the plan, puts first, so anything taken has the room they just made. False if nothing to do.
function Bank:Run()
  if not open or Mover:Active() then return false end
  local plan = self:Plan()
  local moves = {}
  for _, move in ipairs(plan.put) do moves[#moves + 1] = move end
  for _, move in ipairs(plan.take) do moves[#moves + 1] = move end
  if #moves == 0 then return false end
  self.lastResult = nil
  return Mover:Run(moves, { label = "Bank trip", bank = true, onDone = function(reason, moved, skipped)
    Bank.lastResult = { reason = reason, moved = moved, skipped = skipped }
    if moved > 0 then
      D:Log("Bank trip", string.format("%d moves%s%s", moved, skipped > 0 and (", " .. skipped .. " skipped") or "", reason and (": " .. reason) or ""))
    end
    if not reason and D.db.rules.tidyAfter and D.Tidy then D.Tidy:Run() end
  end })
end

Core:On("BANKFRAME_OPENED", "dimension.bank", function()
  open = true
  Bank.lastResult = nil
  if D.db and D.db.rules.autoBank and not D.PauseReason() then
    -- the bank's contents arrive a frame later than the event
    Core:NextFrame(function() Bank:Run() end, "dimension.bank")
  end
  D:Changed()
end)
Core:On("BANKFRAME_CLOSED", "dimension.bank", function()
  open = false
  D:Changed()
end)
for _, event in ipairs({ "PLAYERBANKSLOTS_CHANGED", "BANK_TABS_CHANGED" }) do
  Core:On(event, "dimension.bank", function() if open then D:Changed() end end)
end
