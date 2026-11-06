-- Places: pins and bag roles, and Tidy, which uses the game's own sort and then puts pinned items
-- back. The sort is one call done by the server, so it's far quicker and safer than moving every slot
-- ourselves. Bag roles are the game's own filters, so looted items go there by themselves.

local Core = NorgannonCore
local P = Providence
if P.disabled then return end

local Tidy = {}
P.Tidy = Tidy
local Mover = P.Mover

local SETTLE = 1            -- quiet seconds after the last bag change before pins go back
local SORT_TIMEOUT = 8      -- seconds to wait for a sort the game never finishes
local DONE_LINE = "Tidied, using the game's own sort."

Tidy.ROLES = {
  { key = "none", label = "Anything" },
  { key = "ClassEquipment", label = "Equipment" }, { key = "ClassConsumables", label = "Consumables" },
  { key = "ClassProfessionGoods", label = "Trade goods" }, { key = "ClassJunk", label = "Junk" }, { key = "ClassQuestItems", label = "Quest items" },
}

local waiting             -- { started, lastChange } while the server sorts
local frame = CreateFrame("Frame")
frame:Hide()

function Tidy:Sorting() return waiting ~= nil end

---Moves that put each pinned item back in its slot. An item already in another pinned slot stays,
---and a pin whose item isn't in the bags just waits.
function Tidy:PinPlan()
  local pins = P:Me().pins
  local moves = {}
  local claimed = {}
  for key, id in pairs(pins) do
    local bag, slot = key:match("^(-?%d+):(%d+)$")
    bag, slot = tonumber(bag), tonumber(slot)
    if bag then
      local here = P.Read(bag, slot)
      if here and here.itemID == id then claimed[key] = true end
    end
  end
  for key, id in pairs(pins) do
    if not claimed[key] then
      local bag, slot = key:match("^(-?%d+):(%d+)$")
      bag, slot = tonumber(bag), tonumber(slot)
      if bag and slot <= P.Size(bag) then
        local fromBag, fromSlot
        P.Each(P.Carried(), function(b, s, info)
          local k = b .. ":" .. s
          if info.itemID == id and not claimed[k] and pins[k] ~= id then
            fromBag, fromSlot = b, s
            return true
          end
        end)
        if fromBag then
          claimed[fromBag .. ":" .. fromSlot] = true
          claimed[key] = true
          moves[#moves + 1] = { from = { fromBag, fromSlot }, to = { bag, slot }, id = id }
        end
      end
    end
  end
  return moves
end

local function restorePins(reportDone)
  local moves = Tidy:PinPlan()
  if #moves == 0 or Mover:Active() then
    if reportDone then reportDone() end
    return
  end
  Mover:Run(moves, { label = "Putting pinned items back", onDone = function() if reportDone then reportDone() end end })
end

local function done()
  P:Log("Tidied your bags", "The game's sort, then pinned items put back")
  P:Print(DONE_LINE)
end

---Tidies. False with a reason if it can't run now.
function Tidy:Run()
  local reason = P.PauseReason()
  if reason then
    P:Print("Not now: " .. reason .. ".")
    return false, reason
  end
  if P.CursorBusy() then return false, "you're holding an item" end
  if Mover:Active() or waiting then return false, "something else is moving" end
  local sort = rawget(_G, "C_Container") and C_Container.SortBags
  if not sort then
    P:Print("This client has no bag sort, so only pinned items were put back.")
    restorePins()
    return true
  end
  P.In("C_Container", "SortBags")
  waiting = { started = GetTime(), lastChange = GetTime() }
  frame:Show()
  P:Changed()
  return true
end

frame:SetScript("OnUpdate", function(self)
  if not waiting then
    self:Hide()
    return
  end
  local now = GetTime()
  if now - waiting.lastChange >= SETTLE or now - waiting.started >= SORT_TIMEOUT then
    waiting = nil
    self:Hide()
    if P.PauseReason() then
      Core:AfterCombat(function() restorePins(done) end, "providence.pins")
    else
      restorePins(done)
    end
  end
end)

Core:On("BAG_UPDATE_DELAYED", "providence.tidy", function()
  if waiting then waiting.lastChange = GetTime() end
end)

-------------------------------------------------------------------------------------------
-- Pins
-------------------------------------------------------------------------------------------

---Pins what's in a slot, or unpins the slot. Returns whether it's pinned now.
function Tidy:TogglePin(bag, slot)
  local pins = P:Me().pins
  local key = bag .. ":" .. slot
  if pins[key] then
    pins[key] = nil
    P:Changed()
    return false
  end
  local info = P.Read(bag, slot)
  if not info then return false end
  pins[key] = info.itemID
  P:Changed()
  return true
end

-------------------------------------------------------------------------------------------
-- What each bag is for: the game's own filters. The backpack can't take one
-------------------------------------------------------------------------------------------

local function flag(key)
  local flags = rawget(_G, "Enum") and Enum.BagSlotFlags
  return flags and flags[key]
end

---True if this client has bag filters at all.
function Tidy.HasRoles()
  return flag("ClassEquipment") ~= nil and P.In("C_Container", "GetBagSlotFlag", 1, flag("ClassEquipment")) ~= nil
end

function Tidy.Role(bag)
  for _, role in ipairs(Tidy.ROLES) do
    if role.key ~= "none" and flag(role.key) and P.In("C_Container", "GetBagSlotFlag", bag, flag(role.key)) then return role.key end
  end
  return "none"
end

function Tidy.SetRole(bag, key)
  for _, role in ipairs(Tidy.ROLES) do
    if role.key ~= "none" and flag(role.key) then
      P.In("C_Container", "SetBagSlotFlag", bag, flag(role.key), role.key == key)
    end
  end
  P:Changed()
end

---"Leave this bag alone": the sort skips it, and it's the game itself that does the skipping.
function Tidy.LeftAlone(bag)
  if bag == 0 then return P.In("C_Container", "GetBackpackAutosortDisabled") and true or false end
  return flag("DisableAutoSort") and P.In("C_Container", "GetBagSlotFlag", bag, flag("DisableAutoSort")) and true or false
end

function Tidy.SetLeftAlone(bag, on)
  if bag == 0 then
    P.In("C_Container", "SetBackpackAutosortDisabled", on)
  elseif flag("DisableAutoSort") then
    P.In("C_Container", "SetBagSlotFlag", bag, flag("DisableAutoSort"), on)
  end
  P:Changed()
end
