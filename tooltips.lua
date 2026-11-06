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
  local verdict, why = Tips.About(id)
  if not (verdict and WORDS[verdict]) then return 0 end
  local a = Core.UI.Accent("dimension")
  tt:AddLine("Dimension: " .. WORDS[verdict], a[1], a[2], a[3])
  tt:AddLine(why, .8, .8, .8)
  return 2
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
