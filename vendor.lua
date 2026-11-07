-- At a vendor: sells what the rules allow, repairs, buys what the carry list is short of, and keeps a
-- record with an undo.
--
-- The buyback list holds 12 stacks and the 13th sale pushes the first off it for good. So a visit
-- sells 12 stacks and stops, cheapest first so the dearest stays buyable longest, and anything more
-- waits for a click unless the player has opted in. Older sales from earlier visits do roll off, as
-- they do by hand (Maro, 2026-11-06), and History keeps the record.
--
-- A sale is pick-up-then-sell, not UseContainerItem: "use" drinks the potion or equips the sword if
-- the vendor has just closed, while selling with no vendor does nothing and the item goes back. If
-- the game ignores SellCursorItem on this client, it falls back to UseContainerItem, checked against
-- the vendor being open in the same frame (db.sellMethod; /dim probe says which is in use).

local Core = NorgannonCore
local D = Dimension
if D.disabled then return end

local Vendor = {}
D.Vendor = Vendor
local Rules = D.Rules

local BUYBACK_SLOTS = 12     -- BUYBACK_ITEMS_PER_PAGE in the client's own MerchantFrame code
local PER_TICK = 3           -- sales per step: enough to feel instant, few enough to watch locks
local TICK = .2
local CHECK_AFTER = 2        -- seconds after which an unsold item means the sale didn't happen
local GIVE_UP = 2            -- ignored sales before changing method

local open = false
local visit                  -- { sold = {records}, value, repaired, spent, bought, ignoring }
local run                    -- { pass = sell past the cap } while selling
local pending = {}           -- sales not confirmed yet
local frame = CreateFrame("Frame")
frame:Hide()
local elapsed = 0

function Vendor:IsOpen() return open end
function Vendor:Visit() return visit end
function Vendor:Selling() return run ~= nil end

local function merchantShown()
  if not open then return false end
  local f = rawget(_G, "MerchantFrame")
  return f == nil or f:IsShown()
end

---Another add-on selling at the same vendor would fight us over the same slots.
function Vendor.OtherSeller()
  -- Scrap sells by default, and a saved file only says so when it has been turned off
  local sets = rawget(_G, "Scrap_Sets")
  if type(sets) == "table" and sets.sell ~= false and D.In("C_AddOns", "IsAddOnLoaded", "Scrap") then return "Scrap" end
end

---How many more stacks this visit may sell without asking.
function Vendor:Room()
  if D.db.rules.overCap then return math.huge end
  return math.max(0, BUYBACK_SLOTS - (visit and #visit.sold or 0))
end

---One sale, checked and done within this frame. True if it went out; false and "refused" if the
---game left the item on the cursor, which went straight back.
local function sellOne(entry)
  if not merchantShown() then return false end
  if D.PauseReason() or D.CursorBusy() then return false end
  local info = D.Read(entry.bag, entry.slot)
  if not info or info.itemID ~= entry.id or info.isLocked then return false end
  if Rules:Verdict(entry.id, info, entry.bag, entry.slot) ~= "sell" then return false end
  if D.db.sellMethod == "use" then
    D.In("C_Container", "UseContainerItem", entry.bag, entry.slot)
  else
    D.In("C_Container", "PickupContainerItem", entry.bag, entry.slot)
    if not D.CursorBusy() then return false end
    D.Global("SellCursorItem")
    if D.CursorBusy() then
      D.Global("ClearCursor")
      return false, "refused"
    end
  end
  return true
end

---After enough sales ignored in a row, the other way of selling.
local function ignoredSale()
  Vendor.ignored = (Vendor.ignored or 0) + 1
  if Vendor.ignored >= GIVE_UP and D.db.sellMethod == "cursor" then
    D.db.sellMethod = "use"
    Vendor.ignored = 0
    return true
  end
  return false
end

local function record(entry)
  local rec = { id = entry.id, count = entry.count, value = entry.value, why = entry.why, name = entry.name, link = entry.link }
  table.insert(visit.sold, rec)
  visit.value = visit.value + entry.value
  table.insert(pending, { bag = entry.bag, slot = entry.slot, id = entry.id, at = GetTime(), rec = rec })
  D:Log("Sold " .. tostring(entry.name or entry.id), entry.why, entry.id, entry.count, entry.value)
end

---Sales still sitting in their slot long after: the game ignored them. Undoes the record, and after
---a couple changes to the other way of selling.
local function checkPending()
  for i = #pending, 1, -1 do
    local p = pending[i]
    if GetTime() - p.at >= CHECK_AFTER then
      table.remove(pending, i)
      local info = D.Read(p.bag, p.slot)
      if info and info.itemID == p.id and not info.isLocked then
        for k, rec in ipairs(visit and visit.sold or {}) do
          if rec == p.rec then
            table.remove(visit.sold, k)
            visit.value = visit.value - rec.value
            break
          end
        end
        local history = D:Me().history
        if history[1] and history[1].id == p.id then table.remove(history, 1) end
        if ignoredSale() and visit and open then Vendor:Sell() end
      else
        Vendor.ignored = 0
      end
    end
  end
  if #pending == 0 and not run then frame:Hide() end
end

local function step()
  if not visit or not merchantShown() then
    run = nil
    return
  end
  if D.PauseReason() then return end
  local left = run.pass and math.huge or Vendor:Room()
  local list = Rules:SellList()
  local waiting = {}
  for _, p in ipairs(pending) do waiting[p.bag .. ":" .. p.slot] = true end
  local sent, changed = 0, false
  for _, entry in ipairs(list) do
    if sent >= PER_TICK or sent >= left then break end
    -- a sale not confirmed yet stays out of the list, or a slow server would see it sold twice
    if not waiting[entry.bag .. ":" .. entry.slot] then
      local ok, refused = sellOne(entry)
      if ok then
        record(entry)
        sent = sent + 1
      elseif refused and ignoredSale() then
        changed = true
        break
      end
    end
  end
  if sent == 0 and not changed then
    run = nil
  end
  D:Changed()
end

frame:SetScript("OnUpdate", function(_, dt)
  elapsed = elapsed + dt
  if elapsed < TICK then return end
  elapsed = 0
  if run then step() end
  checkPending()
end)

---Starts selling. `pass` sells past the buyback limit: only from the button that says so.
function Vendor:Sell(pass)
  if not visit or not open then return false end
  run = { pass = pass and true or false }
  elapsed = TICK
  frame:Show()
  return true
end

---What a Sell button sells now: how many stacks and what they fetch, within the buyback limit.
function Vendor:Offer()
  local list = Rules:SellList()
  local count = math.min(#list, self:Room())
  local value = 0
  for i = 1, count do value = value + (list[i].value or 0) end
  return count, value
end

---What's waiting because of the buyback limit.
function Vendor:Held()
  if not visit or self:Room() > 0 then return 0 end
  return #Rules:SellList()
end

---Buys a sale back, from this vendor's buyback list. It's marked Keep so the next visit doesn't undo
---the undo. False if the game no longer holds it.
function Vendor:Undo(rec)
  if not merchantShown() then return false end
  local n = D.Global("GetNumBuybackItems") or 0
  for i = n, 1, -1 do
    local id = D.In("C_MerchantFrame", "GetBuybackItemID", i)
    if id == rec.id then
      D.Global("BuybackItem", i)
      D.db.itemMarks[rec.id] = "keep"
      if visit then
        for k, r in ipairs(visit.sold) do
          if r == rec then
            table.remove(visit.sold, k)
            visit.value = visit.value - rec.value
            break
          end
        end
      end
      D:Log("Bought back " .. tostring(rec.name or rec.id), "Marked Keep so it won't sell again", rec.id, rec.count)
      return true
    end
  end
  return false
end

---Repairs from the player's own gold, if the rule is on and it can be afforded.
local function repair()
  if not D.db.rules.repair or not D.Global("CanMerchantRepair") then return end
  local cost, can = D.Global("GetRepairAllCost")
  if not cost or cost <= 0 or can == false then return end
  if (D.Global("GetMoney") or 0) < cost then return end
  D.Global("RepairAllItems", false)
  visit.repaired = cost
  D:Log("Repaired", D.Money(cost), nil, nil, -cost)
end

---What this vendor could supply from the carry list: { { index, id, count, cost } }, within the cap.
function Vendor:BuyPlan()
  local plan = {}
  local budget = (D.db.buyCap or 0) - (visit and visit.spent or 0)
  local count = {}
  D.Each(D.Carried(), function(_, _, info)
    count[info.itemID] = (count[info.itemID] or 0) + (info.stackCount or 1)
  end)
  for _, want in ipairs(D:Me().carry) do
    local short = (want.want or 0) - (count[want.id] or 0)
    if short > 0 then
      for index = 1, D.Global("GetMerchantNumItems") or 0 do
        local id = D.Global("GetMerchantItemID", index)
        if id == want.id then
          local info = D.In("C_MerchantFrame", "GetItemInfo", index)
          if type(info) == "table" and info.isPurchasable ~= false and not info.hasExtendedCost and (info.price or 0) > 0 then
            local per = math.max(1, info.stackCount or 1)
            local available = (info.numAvailable or -1) >= 0 and info.numAvailable * per or math.huge
            local afford = math.floor(budget / info.price) * per
            local buy = math.min(short, available, afford)
            if buy > 0 then
              local cost = math.ceil(buy / per) * info.price
              plan[#plan + 1] = { index = index, id = want.id, count = buy, cost = cost, name = info.name }
              budget = budget - cost
            end
          end
          break
        end
      end
    end
  end
  return plan
end

---Buys what the plan says, in batches the merchant's stack size allows.
local function buy()
  if not D.db.rules.buy then return end
  for _, item in ipairs(Vendor:BuyPlan()) do
    if (D.Global("GetMoney") or 0) < item.cost then return end
    local maxStack = D.Global("GetMerchantItemMaxStack", item.index) or item.count
    local left = item.count
    while left > 0 do
      local n = math.min(left, math.max(1, maxStack))
      D.Global("BuyMerchantItem", item.index, n)
      left = left - n
    end
    visit.spent = visit.spent + item.cost
    visit.bought = visit.bought + 1
    D:Log("Bought " .. tostring(item.name or item.id), "On your carry list, up to your cap", item.id, item.count, -item.cost)
  end
end

Core:On("MERCHANT_SHOW", "dimension.vendor", function()
  open = true
  visit = { sold = {}, value = 0, spent = 0, bought = 0 }
  -- what's restricted here, and whether a click's sales then go through, is only known from the real game
  if D.db then D.db.probe.restrictionsAtVendor = D.ActiveRestrictions() end
  if not D.db or D.PauseReason() then
    D:Changed()
    return
  end
  local other = Vendor.OtherSeller()
  if other and not Vendor.noted then
    Vendor.noted = true
    D:Print(other .. " is already selling here, so I'll leave selling to it. Turn its auto-sell off to use mine.")
  end
  repair()
  buy()
  if D.db.rules.autoSell and not other then Vendor:Sell() end
  D:Changed()
end)
Core:On("MERCHANT_CLOSED", "dimension.vendor", function()
  open = false
  run = nil
  wipe(pending)   -- with the vendor gone, an item back in that slot says nothing about the sale
  if visit and visit.value > 0 then
    D:Print(string.format("Sold %d %s for %s. /dim shows what and why.", #visit.sold, #visit.sold == 1 and "stack" or "stacks", D.Money(visit.value)))
  end
  D:Changed()
end)
Vendor.BUYBACK_SLOTS = BUYBACK_SLOTS
