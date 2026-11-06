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
-- the vendor being open in the same frame (db.sellMethod; /prov probe says which is in use).

local Core = NorgannonCore
local P = Providence
if P.disabled then return end

local Vendor = {}
P.Vendor = Vendor
local Rules = P.Rules

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
  if type(sets) == "table" and sets.sell ~= false and P.In("C_AddOns", "IsAddOnLoaded", "Scrap") then return "Scrap" end
end

---How many more stacks this visit may sell without asking.
function Vendor:Room()
  if P.db.rules.overCap then return math.huge end
  return math.max(0, BUYBACK_SLOTS - (visit and #visit.sold or 0))
end

---One sale, checked and done within this frame. True if it went out; false and "refused" if the
---game left the item on the cursor, which went straight back.
local function sellOne(entry)
  if not merchantShown() then return false end
  if P.PauseReason() or P.CursorBusy() then return false end
  local info = P.Read(entry.bag, entry.slot)
  if not info or info.itemID ~= entry.id or info.isLocked then return false end
  if Rules:Verdict(entry.id, info, entry.bag, entry.slot) ~= "sell" then return false end
  if P.db.sellMethod == "use" then
    P.In("C_Container", "UseContainerItem", entry.bag, entry.slot)
  else
    P.In("C_Container", "PickupContainerItem", entry.bag, entry.slot)
    if not P.CursorBusy() then return false end
    P.Global("SellCursorItem")
    if P.CursorBusy() then
      P.Global("ClearCursor")
      return false, "refused"
    end
  end
  return true
end

---After enough sales ignored in a row, the other way of selling.
local function ignoredSale()
  Vendor.ignored = (Vendor.ignored or 0) + 1
  if Vendor.ignored >= GIVE_UP and P.db.sellMethod == "cursor" then
    P.db.sellMethod = "use"
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
  P:Log("Sold " .. tostring(entry.name or entry.id), entry.why, entry.id, entry.count, entry.value)
end

---Sales still sitting in their slot long after: the game ignored them. Undoes the record, and after
---a couple changes to the other way of selling.
local function checkPending()
  for i = #pending, 1, -1 do
    local p = pending[i]
    if GetTime() - p.at >= CHECK_AFTER then
      table.remove(pending, i)
      local info = P.Read(p.bag, p.slot)
      if info and info.itemID == p.id and not info.isLocked then
        for k, rec in ipairs(visit and visit.sold or {}) do
          if rec == p.rec then
            table.remove(visit.sold, k)
            visit.value = visit.value - rec.value
            break
          end
        end
        local history = P:Me().history
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
  if P.PauseReason() then return end
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
  P:Changed()
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

---What's waiting because of the buyback limit.
function Vendor:Held()
  if not visit or self:Room() > 0 then return 0 end
  return #Rules:SellList()
end

---Buys a sale back, from this vendor's buyback list. It's marked Keep so the next visit doesn't undo
---the undo. False if the game no longer holds it.
function Vendor:Undo(rec)
  if not merchantShown() then return false end
  local n = P.Global("GetNumBuybackItems") or 0
  for i = n, 1, -1 do
    local id = P.In("C_MerchantFrame", "GetBuybackItemID", i)
    if id == rec.id then
      P.Global("BuybackItem", i)
      P.db.itemMarks[rec.id] = "keep"
      if visit then
        for k, r in ipairs(visit.sold) do
          if r == rec then
            table.remove(visit.sold, k)
            visit.value = visit.value - rec.value
            break
          end
        end
      end
      P:Log("Bought back " .. tostring(rec.name or rec.id), "Marked Keep so it won't sell again", rec.id, rec.count)
      return true
    end
  end
  return false
end

---Repairs from the player's own gold, if the rule is on and it can be afforded.
local function repair()
  if not P.db.rules.repair or not P.Global("CanMerchantRepair") then return end
  local cost, can = P.Global("GetRepairAllCost")
  if not cost or cost <= 0 or can == false then return end
  if (P.Global("GetMoney") or 0) < cost then return end
  P.Global("RepairAllItems", false)
  visit.repaired = cost
  P:Log("Repaired", P.Money(cost), nil, nil, -cost)
end

---What this vendor could supply from the carry list: { { index, id, count, cost } }, within the cap.
function Vendor:BuyPlan()
  local plan = {}
  local budget = (P.db.buyCap or 0) - (visit and visit.spent or 0)
  local count = {}
  P.Each(P.Carried(), function(_, _, info)
    count[info.itemID] = (count[info.itemID] or 0) + (info.stackCount or 1)
  end)
  for _, want in ipairs(P:Me().carry) do
    local short = (want.want or 0) - (count[want.id] or 0)
    if short > 0 then
      for index = 1, P.Global("GetMerchantNumItems") or 0 do
        local id = P.Global("GetMerchantItemID", index)
        if id == want.id then
          local info = P.In("C_MerchantFrame", "GetItemInfo", index)
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
  if not P.db.rules.buy then return end
  for _, item in ipairs(Vendor:BuyPlan()) do
    if (P.Global("GetMoney") or 0) < item.cost then return end
    local maxStack = P.Global("GetMerchantItemMaxStack", item.index) or item.count
    local left = item.count
    while left > 0 do
      local n = math.min(left, math.max(1, maxStack))
      P.Global("BuyMerchantItem", item.index, n)
      left = left - n
    end
    visit.spent = visit.spent + item.cost
    visit.bought = visit.bought + 1
    P:Log("Bought " .. tostring(item.name or item.id), "On your carry list, up to your cap", item.id, item.count, -item.cost)
  end
end

Core:On("MERCHANT_SHOW", "providence.vendor", function()
  open = true
  visit = { sold = {}, value = 0, spent = 0, bought = 0 }
  if not P.db or P.PauseReason() then
    P:Changed()
    return
  end
  local other = Vendor.OtherSeller()
  if other and not Vendor.noted then
    Vendor.noted = true
    P:Print(other .. " is already selling here, so I'll leave selling to it. Turn its auto-sell off to use mine.")
  end
  repair()
  buy()
  if P.db.rules.autoSell and not other then Vendor:Sell() end
  P:Changed()
end)
Core:On("MERCHANT_CLOSED", "providence.vendor", function()
  open = false
  run = nil
  wipe(pending)   -- with the vendor gone, an item back in that slot says nothing about the sale
  if visit and visit.value > 0 then
    P:Print(string.format("Sold %d %s for %s. /prov shows what and why.", #visit.sold, #visit.sold == 1 and "stack" or "stacks", P.Money(visit.value)))
  end
  P:Changed()
end)
Vendor.BUYBACK_SLOTS = BUYBACK_SLOTS
