-- One line on the tooltip of anything you're carrying that Dimension has an opinion on: what will
-- happen to it and why. "Left alone" isn't worth a line.

local Core = NorgannonCore
local D = Dimension
if D.disabled then return end

local Tips = {}
D.Tips = Tips
local Rules = D.Rules

local WORDS = { sell = "Sells at the next vendor", keep = "Kept" }

---verdict, why for an item on the player, judged on the copy they hold; nil if they hold none.
function Tips.About(id)
  if not D.db then return nil end
  local verdict, why
  D.Each(D.Carried(), function(bag, slot, info)
    if info.itemID == id then
      verdict, why = Rules:Verdict(id, info, bag, slot)
      return true
    end
  end)
  return verdict, why
end

function Tips:AddItem(tt, id)
  if not D.db.tooltips then return 0 end
  local a = Core.UI.Accent("dimension")
  local added = 0
  local verdict, why = Tips.About(id)
  if verdict and WORDS[verdict] then
    tt:AddLine("Dimension: " .. WORDS[verdict], a[1], a[2], a[3])
    tt:AddLine(why, .8, .8, .8)
    added = 2
  end
  -- a bag that would give you more room
  local u = D.Swap and D.db.bagSwap and D.Swap.IsBag(id) and D.Swap.UpgradeFor(id)
  if u then
    tt:AddLine(u.target.itemId and string.format("Dimension: %d more slots than your %s", u.gain, u.target.name) or "Dimension: fits your empty bag slot", a[1], a[2], a[3])
    tt:AddLine(u.plan.short > 0 and D.Swap.ShortText(u.plan) or "/dim swap or Make room puts it in, and moves what's in the old bag.", .8, .8, .8, true)
    added = added + 2
  end
  return added
end

local function onItem(tt, data)
  if type(data) ~= "table" or Core.IsSecret(data) then return end
  local id = data.id
  if type(id) == "number" and not Core.IsSecret(id) and Tips:AddItem(tt, id) > 0 then tt:Show() end
end
Tips.OnItem = onItem

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item then
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, onItem)
end
