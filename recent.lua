-- New items: what came into your bags lately glows on its slot until you hover it, so a fresh drop is found
-- without hunting. Only a glow: it stays where it is in the bag window. It goes on time too (30 minutes by
-- default), so a glow you never looked at doesn't stay for ever.
--
-- It works from counts, not slots: what you carry of each item, compared after every bag change. Items moving
-- between bags, a sort or the mover change no count, so they never look new. A bigger stack does, which is
-- the point: five more Linen Cloth is something you just got. What comes out of the bank isn't new, and
-- neither is anything at login: the counts are saved, so a reload or a slow first bag load changes nothing.
--
-- /dim seen clears the lot.

local Core = NorgannonCore
local D = Dimension
if D.disabled then return end

local Recent = {}
D.Recent = Recent

local WARMUP = 10   -- seconds after login when counts only rise: the bags may still be filling in

local snapshot      -- [itemId] = how many you carry, as last seen
local hadSaved      -- counts were saved from before this login, so the warm-up can still tell what's new
local loginAt

local function list()
  local me = D:Me()
  me.recent = me.recent or {}    -- [itemId] = when it came in
  return me.recent
end

local function counts()
  local out = {}
  D.Each(D.Carried(), function(_, _, info)
    out[info.itemID] = (out[info.itemID] or 0) + (info.stackCount or 1)
  end)
  return out
end

---True while an item counts as new: on, got lately, and not yet hovered.
function Recent.Is(id)
  if not (D.db and D.db.recent) or not id then return false end
  local all = list()
  local at = all[id]
  if not at then return false end
  if D.Now() - at > (D.db.recentFor or 30) * 60 then
    all[id] = nil
    return false
  end
  return true
end

---How many items count as new.
function Recent.Count()
  local n = 0
  for id in pairs(list()) do
    if Recent.Is(id) then n = n + 1 end
  end
  return n
end

local function redrawGlows()
  local O = D.Overlay
  if not O then return end
  for button in pairs(O.marks) do O.RefreshButton(button) end
end

---Hovered: no longer new.
function Recent:Seen(id)
  local all = list()
  if not all[id] then return end
  all[id] = nil
  redrawGlows()
end

---Everything seen: /dim seen.
function Recent:SeenAll()
  wipe(list())
  D:Changed()
end

---After a bag change: anything you now carry more of is new.
function Recent:Update()
  if not D.db then return end
  local now = counts()
  local me = D:Me()
  local warm = loginAt and GetTime() - loginAt < WARMUP
  if not snapshot then
    hadSaved = me.counts ~= nil
    snapshot = me.counts or now
  end
  local bank = D.Bank and D.Bank.IsOpen and D.Bank:IsOpen()
  local added = false
  for id, n in pairs(now) do
    local before = snapshot[id] or 0
    if n > before and (hadSaved or not warm) and me.counts and not bank and D.db.recent then
      list()[id] = D.Now()
      added = true
    end
  end
  if warm then
    -- the first bag loads can come in pieces: only ever raise what's known, never take it as a loss
    for id, n in pairs(now) do
      if n > (snapshot[id] or 0) then snapshot[id] = n end
    end
  else
    snapshot = now
  end
  me.counts = snapshot
  if added then D:Changed() end
end

Core:OnLogin(function() loginAt = GetTime() end)
Core:On("BAG_UPDATE_DELAYED", "dimension.recent", function()
  Core:NextFrame(function() Recent:Update() end, "dimension.recent")
end)

-- hovering a slot in any bag window: the game's bags, ours, another add-on's
local function hovered(tt)
  if not (D.db and D.db.recent) or not tt or not tt.GetOwner then return end
  local owner = tt:GetOwner()
  if type(owner) ~= "table" or Core.IsSecret(owner) or not owner.GetBagID or not owner.GetID then return end
  local ok, bag = pcall(owner.GetBagID, owner)
  local okSlot, slot = pcall(owner.GetID, owner)
  if not (ok and okSlot and bag and slot) or Core.IsSecret(bag) then return end
  local info = D.Read(bag, slot)
  if info then Recent:Seen(info.itemID) end
end
Recent.Hovered = hovered

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item then
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt) hovered(tt) end)
end
