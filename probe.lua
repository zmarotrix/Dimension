-- /prov probe: what this client really allows. The files show which calls exist and which are flagged
-- as restricted; only the game can say how the rest behave. Each test is small and undoes itself:
--
--   /prov probe        which calls exist, what's been learned so far
--   /prov probe sell   at a vendor: sells the cheapest thing the rules allow, then buys it back
--   /prov probe move   moves one item to an empty slot and back, timed
--   /prov probe sort   runs the game's sort and says whether anything moved
--
-- Nothing here deletes anything. Results stay in ProvidenceDB.probe, so they can be read from the file.

local Core = NorgannonCore
local P = Providence
if P.disabled then return end

local Probe = {}
P.Probe = Probe

local SELL_WAIT = 1.5    -- seconds for a test sale to land before buying it back
local SORT_WAIT = 3

local CALLS = {
  "C_Container.GetContainerItemInfo", "C_Container.PickupContainerItem", "C_Container.SplitContainerItem", "C_Container.SortBags",
  "C_Container.SetBagSlotFlag", "C_Container.GetBagSlotFlag", "C_Container.GetContainerItemQuestInfo", "C_Container.GetContainerItemPurchaseInfo",
  "C_Container.GetContainerItemEquipmentSetInfo", "C_MerchantFrame.GetBuybackItemID", "C_MerchantFrame.GetItemInfo", "C_RestrictedActions.IsAddOnRestrictionActive",
  "C_Bank.FetchPurchasedBankTabData", "C_Item.GetItemFamily", "C_Item.GetItemMaxStackSizeByID", "SellCursorItem", "BuybackItem", "GetNumBuybackItems",
  "CursorHasItem", "ClearCursor", "GetCursorInfo", "RepairAllItems", "GetRepairAllCost", "CanMerchantRepair", "BuyMerchantItem", "GetMerchantItemID", "GetMerchantItemMaxStack", "GetMouseFoci",
}

local function exists(path)
  local ns, name = path:match("^(.-)%.(.+)$")
  if not ns then return rawget(_G, path) ~= nil end
  local t = rawget(_G, ns)
  return type(t) == "table" and t[name] ~= nil
end

local timer = CreateFrame("Frame")
timer:Hide()
local waitLeft, waitThen
timer:SetScript("OnUpdate", function(self, dt)
  waitLeft = waitLeft - dt
  if waitLeft <= 0 then
    self:Hide()
    local fn = waitThen
    waitThen = nil
    if fn then fn() end
  end
end)

local function after(seconds, fn)
  waitLeft, waitThen = seconds, fn
  timer:Show()
end

local function note(key, ok, detail)
  P.db.probe[key] = { ok = ok, detail = detail, at = P.Now() }
  P:Print(string.format("%s%s|r %s: %s", ok and "|cff8fe08f" or "|cffff9478", ok and "works" or "problem", key, detail))
end

---One-line results of what has run so far, for the summary.
function Probe:Lines()
  local lines = {}
  for _, key in ipairs({ "Selling", "Moving", "Sorting" }) do
    local got = P.db.probe[key]
    if got then
      lines[#lines + 1] = string.format("%s%s|r %s: %s", got.ok and "|cff8fe08f" or "|cffff9478", got.ok and "works" or "problem", key, tostring(got.detail))
    else
      lines[#lines + 1] = string.format("|cffd9a066not run|r %s: /prov probe %s", key, key == "Selling" and "sell" or key == "Moving" and "move" or "sort")
    end
  end
  local missing = {}
  for _, path in ipairs(CALLS) do
    if not exists(path) then missing[#missing + 1] = path end
  end
  P.db.probe.missing = missing
  P.db.probe.client = { build = (select(2, GetBuildInfo())), interface = (select(4, GetBuildInfo())) }
  lines[#lines + 1] = #missing == 0 and "Every call Providence leans on exists." or ("Missing calls: " .. table.concat(missing, ", "))
  lines[#lines + 1] = "Selling goes through: " .. tostring(P.db.sellMethod)
  local mover = P.db.probe.mover
  if mover then
    lines[#lines + 1] = string.format("Last move: %d moves in %.1f s, batch %d", mover.moves, mover.seconds, mover.batch)
  end
  local bank = #Core.Bags:BankList("Character")
  lines[#lines + 1] = string.format("Bank containers the client names: %d", bank)
  return lines
end

function Probe:Sell()
  if not P.Vendor:IsOpen() then
    P:Print("Open a vendor first.")
    return false
  end
  local entry = P.Rules:SellList()[1]
  if not entry then
    P:Print("The rules wouldn't sell anything right now, so there's nothing safe to test with.")
    return false
  end
  local before = P.Global("GetNumBuybackItems") or 0
  P.In("C_Container", "PickupContainerItem", entry.bag, entry.slot)
  P.Global("SellCursorItem")
  local refused = P.CursorBusy()
  if refused then P.Global("ClearCursor") end
  after(SELL_WAIT, function()
    local info = P.Read(entry.bag, entry.slot)
    local sold = not (info and info.itemID == entry.id)
    if not sold then
      note("Selling", false, "SellCursorItem did nothing here, so sales will use UseContainerItem")
      P.db.sellMethod = "use"
      return
    end
    local now = P.Global("GetNumBuybackItems") or 0
    local bought = false
    for i = now, 1, -1 do
      if P.In("C_MerchantFrame", "GetBuybackItemID", i) == entry.id then
        P.Global("BuybackItem", i)
        bought = true
        break
      end
    end
    note("Selling", bought, string.format("sold without a click (buyback %d to %d)%s", before, now, bought and ", and bought it back" or ", but couldn't find it to buy back"))
  end)
  return true
end

function Probe:Move()
  if P.Mover:Active() then return false end
  local fromBag, fromSlot, id, toBag, toSlot
  P.Each(P.Carried(), function(bag, slot, info)
    if not info.isLocked and not P:Me().pins[bag .. ":" .. slot] then
      fromBag, fromSlot, id = bag, slot, info.itemID
      return true
    end
  end)
  for _, entry in ipairs(P.Carried()) do
    if not entry.reagent then
      for slot = 1, P.Size(entry.id) do
        if not P.Read(entry.id, slot) and not P:Me().pins[entry.id .. ":" .. slot] then
          toBag, toSlot = entry.id, slot
          break
        end
      end
    end
    if toBag then break end
  end
  if not (fromBag and toBag) then
    P:Print("I need one item and one empty slot to test with.")
    return false
  end
  local started = GetTime()
  local moves = { { from = { fromBag, fromSlot }, to = { toBag, toSlot }, id = id }, { from = { toBag, toSlot }, to = { fromBag, fromSlot }, id = id } }
  -- one at a time: the second move is the first one back
  return P.Mover:Run({ moves[1] }, { label = "Probe", onDone = function(reason, moved)
    if reason or moved == 0 then
      note("Moving", false, reason or "the item didn't move")
      return
    end
    P.Mover:Run({ moves[2] }, { label = "Probe", onDone = function(backReason, backMoved)
      note("Moving", not backReason and backMoved > 0, string.format("out and back in %.2f s without a click", GetTime() - started))
    end })
  end })
end

local function layout()
  local out = {}
  P.Each(P.Carried(), function(bag, slot, info)
    out[#out + 1] = bag .. ":" .. slot .. "=" .. info.itemID
  end)
  return table.concat(out, ";")
end

function Probe:Sort()
  local before = layout()
  local ok, why = P.Tidy:Run()
  if not ok then
    P:Print("Can't sort now: " .. tostring(why))
    return false
  end
  after(SORT_WAIT, function()
    note("Sorting", true, before ~= layout() and "the game's sort moved things" or "nothing moved: already tidy, or the sort doesn't work here")
  end)
  return true
end

---Runs one test, or prints the summary.
function Probe:Run(what)
  if what == "sell" then return self:Sell() end
  if what == "move" then return self:Move() end
  if what == "sort" then return self:Sort() end
  P:Print("what this client allows (saved in ProvidenceDB.probe):")
  for _, line in ipairs(self:Lines()) do Core:Print(line, P.PREFIX) end
end
