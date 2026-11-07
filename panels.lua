-- The small panels beside the game's vendor and bank windows: what just happened, what's waiting and
-- why. They show only when there's something to say.

local Core = NorgannonCore
local D = Dimension
if D.disabled then return end
local UI = Core.UI
local C = UI.C

local Panels = {}
D.Panels = Panels
local Rules, Vendor, Bank, Mover = D.Rules, D.Vendor, D.Bank, D.Mover
local itemName = D.Window.ItemName

local W, H = 340, 420

---A panel with a status line, a button and a list, anchored to the game's window for that NPC.
local function makePanel(title, frameName)
  local f = UI.Window({ addon = "dimension", title = "Dimension", sub = title, width = W, height = H })
  f:SetAccent("dimension")
  f:Hide()
  if f.powered then f.powered:Hide() end
  f.status = UI.Text(f.body, "body", 13)
  f.status:SetPoint("TOPLEFT", 12, -10)
  f.status:SetPoint("TOPRIGHT", -12, -10)
  f.status:SetJustifyH("LEFT")
  f.note = UI.Text(f.body, "body", 12, C.muted)
  f.note:SetPoint("TOPLEFT", f.status, "BOTTOMLEFT", 0, -3)
  f.note:SetPoint("TOPRIGHT", f.status, "BOTTOMRIGHT", 0, -3)
  f.note:SetJustifyH("LEFT")
  f.action = UI.Button(f.body, "", "accent", function(self) if self.run then self.run() end end)
  f.action:SetHeight(24)
  f.action:SetPoint("TOPLEFT", 12, -56)
  f.action:SetPoint("TOPRIGHT", -12, -56)
  f.list = D.Window.RowList(f.body)
  f.list:SetPoint("TOPLEFT", 0, -88)
  f.list:SetPoint("BOTTOMRIGHT", 0, 8)
  function f:Attach()
    local game = rawget(_G, frameName)
    self:ClearAllPoints()
    if game and game:IsShown() then
      self:SetPoint("TOPLEFT", game, "TOPRIGHT", 12, 0)
    else
      self:SetPoint("CENTER")
    end
  end
  function f:SetAction(text, run)
    self.action:SetShown(text ~= nil)
    self.action.run = run
    if text then self.action:SetLabel(text) end
  end
  return f
end

-------------------------------------------------------------------------------------------
-- At a vendor
-------------------------------------------------------------------------------------------

local vendorPanel

local function fillVendor()
  local visit = Vendor:Visit()
  local waiting = #Rules:SellList()
  local anything = visit and (#visit.sold > 0 or waiting > 0 or visit.repaired or visit.bought > 0)
  if not (Vendor:IsOpen() and visit and anything) then
    if vendorPanel then vendorPanel:Hide() end
    return
  end
  if not vendorPanel then
    vendorPanel = makePanel("At a vendor", "MerchantFrame")
    Panels.vendor = vendorPanel
  end
  local f = vendorPanel
  f:Attach()
  local parts = {}
  if #visit.sold > 0 then parts[#parts + 1] = string.format("Sold %d %s for %s", #visit.sold, #visit.sold == 1 and "stack" or "stacks", D.Money(visit.value)) end
  if visit.repaired then parts[#parts + 1] = "repaired for " .. D.Money(visit.repaired) end
  if visit.bought > 0 then parts[#parts + 1] = "bought for " .. D.Money(visit.spent) end
  f.status:SetText(#parts > 0 and table.concat(parts, ", ") or "Nothing sold yet")
  f.note:SetText(string.format("%d of %d of this visit's buyback used", math.min(#visit.sold, Vendor.BUYBACK_SLOTS), Vendor.BUYBACK_SLOTS))

  local paused = D.PauseReason()
  local held = Vendor:Held()
  if paused then
    f:SetAction(nil)
    f.note:SetText("Stopped: " .. paused)
  elseif held > 0 then
    f:SetAction(string.format("Sell %d more (can't all be bought back)", held), function() Vendor:Sell(true) end)
  elseif waiting > 0 and not Vendor:Selling() then
    local count, value = Vendor:Offer()
    f:SetAction(string.format("Confirm and sell %d for %s", count, D.Money(value)), function() Vendor:Sell() end)
  else
    f:SetAction(nil)
  end

  local items = {}
  if #visit.sold > 0 then items[#items + 1] = { group = "Sold just now" } end
  for _, rec in ipairs(visit.sold) do
    items[#items + 1] = { id = rec.id, link = rec.link, title = itemName(rec.id, rec.name) .. (rec.count > 1 and (" × " .. rec.count) or ""), sub = rec.why, right = D.Money(rec.value),
      actions = { { text = "Undo", width = 44, tip = "Buy it back and mark it Keep", run = function() Vendor:Undo(rec) D:Changed() end } } }
  end
  local list = Rules:SellList()
  if #list > 0 then items[#items + 1] = { group = "Waiting" } end
  for _, e in ipairs(list) do
    items[#items + 1] = { id = e.id, link = e.link, title = itemName(e.id, e.name) .. (e.count > 1 and (" × " .. e.count) or ""), sub = e.why, right = D.Money(e.value),
      actions = { { text = "Keep", width = 44, tip = "Mark it Keep", run = function() D.db.itemMarks[e.id] = "keep" D:Changed() end } } }
  end
  f.list:SetData(items, true)
  f:Show()
end

-------------------------------------------------------------------------------------------
-- At the bank
-------------------------------------------------------------------------------------------

local bankPanel

local function fillBank()
  if not Bank:IsOpen() then
    if bankPanel then bankPanel:Hide() end
    return
  end
  local plan = Bank:Plan()
  local status = Mover:Status()
  local result = Bank.lastResult
  local count = #plan.take + #plan.put
  if count == 0 and not status and not result then
    if bankPanel then bankPanel:Hide() end
    return
  end
  if not bankPanel then
    bankPanel = makePanel("At the bank", "BankFrame")
    Panels.bank = bankPanel
  end
  local f = bankPanel
  f:Attach()
  if status then
    f.status:SetText(status.paused and ("Paused: " .. status.paused .. ". It carries on by itself") or string.format("Moving %d of %d", status.done, status.total))
    f.note:SetText("A few items at a time, waiting for the server to finish each")
    f:SetAction(nil)
  elseif count > 0 then
    f.status:SetText(string.format("%d %s ready", count, count == 1 and "move" or "moves"))
    f.note:SetText(plan.noRoom > 0 and string.format("%d won't fit", plan.noRoom) or (D.db.rules.autoBank and "These run when the bank opens" or "Runs on a click. A rule makes it run when the bank opens"))
    f:SetAction(not D.PauseReason() and "Do it" or nil, function() Bank:Run() end)
  else
    f.status:SetText("Done")
    f.note:SetText(result and result.reason and ("Stopped: " .. result.reason) or "Everything is where your lists say")
    f:SetAction(nil)
  end
  local items = {}
  if #plan.take > 0 then items[#items + 1] = { group = "Take from the bank" } end
  for _, m in ipairs(plan.take) do
    items[#items + 1] = { id = m.id, title = itemName(m.id) .. (m.count > 1 and (" × " .. m.count) or ""), sub = "On your carry list" }
  end
  if #plan.put > 0 then items[#items + 1] = { group = "Put in the bank" } end
  for _, m in ipairs(plan.put) do
    items[#items + 1] = { id = m.id, title = itemName(m.id) .. (m.count > 1 and (" × " .. m.count) or ""), sub = "On your stash list" }
  end
  f.list:SetData(items, true)
  f:Show()
end

function Panels:Refresh()
  fillVendor()
  fillBank()
end
