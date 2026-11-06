-- Dimension's window (design/suite/dimension.html): Make room, Rules, Carry & stash, Places and
-- History, plus the first-run presets. Panels at a vendor and the bank are in panels.lua and share
-- the row list made here.

local Core = NorgannonCore
local D = Dimension
if D.disabled then return end
local UI = Core.UI
local C = UI.C

local Window = {}
D.Window = Window
local Rules, Room, Tidy, Vendor = D.Rules, D.Room, D.Tidy, D.Vendor

local W, H = 780, 580
local ROW_H = 38
local GRID_TILE, GRID_GAP = 30, 2
local COLS = 20
local CARRY_STEP = 5
local TABS = {
  { key = "room", label = "Make room" }, { key = "rules", label = "Rules" }, { key = "carry", label = "Carry & stash" },
  { key = "places", label = "Places" }, { key = "history", label = "History" },
}
local FOOTERS = {
  room = "Nothing here happens unless you click, apart from merging if that rule is on",
  rules = "Hover any item and press your Mark key to cycle Junk, Keep, none. Set it in Key Bindings",
  carry = "Lists belong to this character",
  places = "Left-click a slot to pin what's in it · right-click to cycle Junk, Keep, none",
  history = "Everything Dimension did for this character, kept for 30 days",
}

local win
local panes = {}

-------------------------------------------------------------------------------------------
-- A list of item rows, for the window and the panels: { group } or
-- { id, title, sub, right, actions = { { text, run, off, tip } } }
-------------------------------------------------------------------------------------------

local function actionButton(row, i)
  local b = UI.Button(row, "", "quiet", function(self)
    local action = self.action
    if action and not action.off then action.run() end
  end)
  b:SetHeight(22)
  b:SetScript("OnEnter", function(self)
    if self.action and self.action.tip then
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine(self.action.tip, 1, 1, 1, true)
      GameTooltip:Show()
    end
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  row.buttons[i] = b
  return b
end

local function createRow(row, content)
  row.buttons = {}
  row.icon = content:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(26, 26)
  row.icon:SetPoint("LEFT", 8, 0)
  row.icon:SetTexCoord(.07, .93, .07, .93)
  row.title = UI.Text(content, "body", 14)
  row.title:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, 1)
  row.title:SetWordWrap(false)
  row.sub = UI.Text(content, "body", 12, C.muted)
  row.sub:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -1)
  row.sub:SetWordWrap(false)
  row.right = UI.Text(content, "body", 13)
  row.host = content
end

local function updateRow(row, item)
  if item.id then
    row.icon:SetTexture(D.In("C_Item", "GetItemIconByID", item.id) or 134400)
    row.icon:Show()
  else
    row.icon:Hide()
  end
  row.title:SetText(item.title or "")
  row.sub:SetText(item.sub or "")
  local previous
  for i = 1, math.max(#row.buttons, #(item.actions or {})) do
    local action = item.actions and item.actions[i]
    local b = row.buttons[i] or (action and actionButton(row, i))
    if b then
      b.action = action
      b:SetShown(action ~= nil)
      if action then
        b:SetLabel(action.text)
        b:SetWidth(action.width or 70)
        b:SetAlpha(action.off and .4 or 1)
        b:ClearAllPoints()
        if previous then
          b:SetPoint("RIGHT", previous, "LEFT", -4, 0)
        else
          b:SetPoint("RIGHT", row, "RIGHT", -14, 0)
        end
        previous = b
      end
    end
  end
  row.right:ClearAllPoints()
  if previous then
    row.right:SetPoint("RIGHT", previous, "LEFT", -8, 0)
  else
    row.right:SetPoint("RIGHT", row, "RIGHT", -14, 0)
  end
  row.right:SetText(item.right or "")
end

---A virtual list of item rows; hovering one with an id shows the game's item tooltip.
function Window.RowList(parent)
  return UI.List(parent, {
    rowHeight = ROW_H,
    createRow = createRow,
    updateRow = updateRow,
    onEnter = function(row, item)
      if item.id then
        GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
        if item.link then GameTooltip:SetHyperlink(item.link) else GameTooltip:SetItemByID(item.id) end
        GameTooltip:Show()
      end
    end,
    onLeave = function() GameTooltip:Hide() end,
  })
end

---A bag item's name: what the slot said, else the client, else NorgannonDB, else its number.
function Window.ItemName(id, name)
  if name then return name end
  return Rules.Facts(id).name or Core.DB:Name("items", id) or ("Item " .. tostring(id))
end
local itemName = Window.ItemName

-------------------------------------------------------------------------------------------
-- Make room
-------------------------------------------------------------------------------------------

local function destroyAction(entry)
  local on = D.db.rules.destroy
  return { text = "Destroy", width = 62, off = not on, tip = on and "Destroys this stack, for good. One click per stack: the game allows no less." or "Off until you switch it on in Rules.",
    run = function()
      local ok, why = Room:Destroy(entry.bag, entry.slot, entry.id)
      if not ok then D:Print("Not destroyed: " .. tostring(why) .. ".") end
      Window:Refresh()
    end }
end

local function buildRoom(f)
  f.lead = UI.Text(f, "body", 13, C.muted)
  f.lead:SetPoint("TOPLEFT")
  f.lead:SetPoint("TOPRIGHT")
  f.lead:SetJustifyH("LEFT")
  f.lead:SetText("The cheapest ways to free a slot, in order.")
  f.list = Window.RowList(f)
  f.list:SetPoint("TOPLEFT", f.lead, "BOTTOMLEFT", 0, -6)
  f.list:SetPoint("BOTTOMRIGHT")
end

local function fillRoom(f)
  local list = Room:List()
  local items = {}
  if list.moves > 0 then
    items[#items + 1] = { group = "Costs nothing" }
    items[#items + 1] = { title = "Merge partial stacks and put things in their bags", sub = "Nothing leaves your bags",
      right = list.slots > 0 and string.format("+%d %s", list.slots, list.slots == 1 and "slot" or "slots") or "",
      actions = { { text = "Do it", off = D.PauseReason() ~= nil or D.Mover:Active(), tip = D.PauseReason(), run = function() Room:FreeWithoutCost() end } } }
  end
  if #list.sell > 0 then
    items[#items + 1] = { group = "Goes at the next vendor" }
    for _, e in ipairs(list.sell) do
      items[#items + 1] = { id = e.id, link = e.link, title = itemName(e.id, e.name) .. (e.count > 1 and (" × " .. e.count) or ""), sub = e.why, right = D.Money(e.value),
        actions = { { text = "Keep it", run = function() D.db.itemMarks[e.id] = "keep" D:Changed() end } } }
    end
  end
  if #list.toss > 0 then
    items[#items + 1] = { group = "Cheapest things no rule wants" }
    for _, e in ipairs(list.toss) do
      items[#items + 1] = { id = e.id, link = e.link, title = itemName(e.id, e.name) .. (e.count > 1 and (" × " .. e.count) or ""), sub = "Worth little. That's only an opinion", right = D.Money(e.value),
        actions = { destroyAction(e), { text = "Mark Junk", width = 72, run = function() D.db.itemMarks[e.id] = "junk" D:Changed() end } } }
    end
  end
  if #items == 0 then items[1] = { title = "Nothing cheap to clear", sub = "Everything left is something a rule wants kept" } end
  f.list:SetData(items, true)
end

-------------------------------------------------------------------------------------------
-- Rules: the shared settings list, because that's what they are
-------------------------------------------------------------------------------------------

local function rule(list, key, label, desc)
  list:Toggle(label, desc, function() return D.db.rules[key] end, function(on)
    D.db.rules[key] = on
    D:Changed()
  end)
end

local function buildRules(f)
  local list = UI.SettingsList(f)
  list:Header("Never sold")
  list:Buttons("Quest items", "And anything a quest in your log wants, or that starts a quest, from NorgannonDB.", {})
  list:Buttons("Rewards you earned", "Soulbound or grey items that came from a quest: greys like this aren't always junk.", {})
  list:Buttons("Rare or better, and recipes", "Blue, purple and above, and any recipe.", {})
  list:Buttons("Your hearthstone and profession tools", nil, {})
  list:Buttons("Equipment sets, refundable items, Keep marks and pinned slots", "Plus anything on your carry or stash lists, and anything with no vendor value.", {})
  list:Buttons("Reagents your professions use", "Unless you mark them Junk yourself.", {})
  rule(list, "altKeep", "Reagents another character's profession uses", "From Retrospect, if it's installed.")
  list:Header("Sold")
  rule(list, "grey", "Greys", "Unless something above says keep.")
  rule(list, "marked", "Items you marked Junk", "Hover an item and press your Mark key.")
  rule(list, "cantUse", "Soulbound gear you can't use", "Armor or weapons your class can't ever equip.")
  rule(list, "noRecipe", "Trade goods no profession of yours uses", "Off by default, because a new profession changes the answer.")
  list:Header("On its own")
  rule(list, "autoSell", "Sell when I open a vendor", "Stays inside the 12 stacks of buyback, cheapest first. When off, a Sell button instead.")
  rule(list, "repair", "Repair at repair vendors", "From your own gold.")
  rule(list, "merge", "Merge partial stacks when bags are getting full", "Out of combat, and never while you're holding an item.")
  rule(list, "autoBank", "Run my lists when the bank opens", "Carry and stash, both ways.")
  rule(list, "tidyAfter", "Tidy after a bank trip", "The game's own sort, then pinned items go back.")
  rule(list, "buy", "Buy what's on my carry list from vendors", "Up to the spending cap in Settings. The only thing here that spends gold without a click.")
  list:Header("Only if you say so")
  rule(list, "overCap", "Sell past the buyback limit without asking", "What gets pushed off the list can't be bought back. When off, more than 12 stacks wait for a click.")
  rule(list, "destroy", "Offer a Destroy button in Make room", "Still one click per stack: the game doesn't let an add-on delete by itself.")
  f.settings = list
end

local function fillRules(f) f.settings:Refresh() end

-------------------------------------------------------------------------------------------
-- Carry & stash
-------------------------------------------------------------------------------------------

---A slot to drop an item on, with what happens to it.
local function dropSlot(parent, onItem)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(36, 36)
  local edge = UI.Tex(b, "BACKGROUND", 0, C.lineStrong)
  edge:SetAllPoints()
  local back = UI.Tex(b, "BACKGROUND", 1, C.inset)
  back:SetPoint("TOPLEFT", 1, -1)
  back:SetPoint("BOTTOMRIGHT", -1, 1)
  local add = function()
    local kind, id = D.Global("GetCursorInfo")
    if kind == "item" and id then
      onItem(id)
      D.Global("ClearCursor")
    end
  end
  b:SetScript("OnReceiveDrag", add)
  b:SetScript("OnClick", add)
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Drop an item here", 1, 1, 1)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return b
end

function Window.AddCarry(id)
  local carry = D:Me().carry
  for _, c in ipairs(carry) do
    if c.id == id then return end
  end
  carry[#carry + 1] = { id = id, want = math.max(CARRY_STEP, Room.MaxStack(id) or 1) }
  D:Changed()
end

function Window.AddStash(id)
  D:Me().stash[id] = true
  D:Changed()
end

local function column(f, title, note, anchorRight, onItem)
  local col = CreateFrame("Frame", nil, f)
  if anchorRight then
    col:SetPoint("TOPLEFT", f, "TOP", 7, 0)
    col:SetPoint("BOTTOMRIGHT")
  else
    col:SetPoint("TOPLEFT")
    col:SetPoint("BOTTOMRIGHT", f, "BOTTOM", -7, 0)
  end
  col.title = UI.Text(col, "title", 15, C.goldSoft)
  col.title:SetPoint("TOPLEFT")
  col.title:SetText(title)
  col.note = UI.Text(col, "body", 12, C.muted)
  col.note:SetPoint("TOPLEFT", col.title, "BOTTOMLEFT", 0, -2)
  col.note:SetPoint("TOPRIGHT", col.title, "BOTTOMRIGHT", 0, -2)
  col.title:SetPoint("TOPRIGHT", -44, 0)
  col.note:SetJustifyH("LEFT")
  col.note:SetText(note)
  col.drop = dropSlot(col, onItem)
  col.drop:SetPoint("TOPRIGHT")
  col.list = Window.RowList(col)
  col.list:SetPoint("TOPLEFT", 0, -46)
  col.list:SetPoint("BOTTOMRIGHT")
  return col
end

local function buildCarry(f)
  f.carry = column(f, "Carry list", "What this character should have on them. The bank first, then a vendor if buying is on.", false, Window.AddCarry)
  f.stash = column(f, "Stash list", "What belongs in the bank, not on you.", true, Window.AddStash)
  f.kinds = {}
  local anchor
  for _, spec in ipairs({ { "trade", "All trade goods" }, { "recipe", "All recipes" } }) do
    local chip = UI.Chip(f.stash, spec[2], nil, function(on)
      D:Me().stashKinds[spec[1]] = on or nil
      D:Changed()
    end)
    chip:SetPoint("BOTTOMLEFT", anchor or f.stash, anchor and "BOTTOMRIGHT" or "BOTTOMLEFT", anchor and 6 or 0, 0)
    anchor = chip
    f.kinds[spec[1]] = chip
  end
  f.stash.list:ClearAllPoints()
  f.stash.list:SetPoint("TOPLEFT", 0, -46)
  f.stash.list:SetPoint("BOTTOMRIGHT", 0, 30)
end

local function fillCarry(f)
  local me = D:Me()
  local have = {}
  D.Each(D.Carried(), function(_, _, info) have[info.itemID] = (have[info.itemID] or 0) + (info.stackCount or 1) end)
  local carry = {}
  for i, c in ipairs(me.carry) do
    local got = have[c.id] or 0
    carry[#carry + 1] = { id = c.id, title = itemName(c.id), sub = string.format("Want %d, have %d", c.want, got),
      actions = {
        { text = "x", width = 22, tip = "Take it off the list", run = function() table.remove(me.carry, i) D:Changed() end },
        { text = "+", width = 22, run = function() c.want = c.want + CARRY_STEP D:Changed() end },
        { text = "-", width = 22, run = function() c.want = math.max(1, c.want - CARRY_STEP) D:Changed() end },
      } }
  end
  if #carry == 0 then carry[1] = { title = "Nothing yet", sub = "Drop an item on the slot above" } end
  f.carry.list:SetData(carry, true)
  local stash = {}
  for id in pairs(me.stash) do
    stash[#stash + 1] = { id = id, title = itemName(id), sub = string.format("%d on you", have[id] or 0),
      actions = { { text = "x", width = 22, tip = "Take it off the list", run = function() me.stash[id] = nil D:Changed() end } } }
  end
  table.sort(stash, function(a, b) return a.title < b.title end)
  if #stash == 0 then stash[1] = { title = "Nothing yet", sub = "Drop an item on the slot above" } end
  f.stash.list:SetData(stash, true)
  for kind, chip in pairs(f.kinds) do chip:SetOn(me.stashKinds[kind] and true or false, true) end
end

-------------------------------------------------------------------------------------------
-- Places: a grid of your bags to pin from, and what each bag is for
-------------------------------------------------------------------------------------------

local function gridTile(f)
  local b = CreateFrame("Button", nil, f.grid)
  b:SetSize(GRID_TILE, GRID_TILE)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b.edge = UI.Tex(b, "BACKGROUND", 0, C.line)
  b.edge:SetAllPoints()
  b.back = UI.Tex(b, "BACKGROUND", 1, C.inset)
  b.back:SetPoint("TOPLEFT", 1, -1)
  b.back:SetPoint("BOTTOMRIGHT", -1, 1)
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetPoint("TOPLEFT", 1, -1)
  b.icon:SetPoint("BOTTOMRIGHT", -1, 1)
  b.icon:SetTexCoord(.07, .93, .07, .93)
  b.sell = UI.Icon(b, "circle", 11, { .91, .78, .42 }, "OVERLAY")
  b.sell:SetPoint("TOPLEFT", 1, -1)
  b.keep = UI.Icon(b, "check", 11, { .56, .88, .56 }, "OVERLAY")
  b.keep:SetPoint("TOPLEFT", 1, -1)
  b.pin = UI.Icon(b, "chevron", 11, UI.Accent("dimension"), "OVERLAY")
  b.pin:SetPoint("TOPRIGHT", -1, -1)
  b:SetScript("OnClick", function(self, button)
    if button == "RightButton" then
      if self.id then Rules:CycleMark(self.id) end
    else
      Tidy:TogglePin(self.bag, self.slot)
    end
  end)
  b:SetScript("OnEnter", function(self)
    if self.id then
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetBagItem(self.bag, self.slot)
      GameTooltip:Show()
    end
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return b
end

local function buildPlaces(f)
  f.title = UI.Text(f, "title", 15, C.goldSoft)
  f.title:SetPoint("TOPLEFT")
  f.title:SetText("Your bags")
  f.grid = CreateFrame("Frame", nil, f)
  f.grid:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -4)
  f.grid:SetPoint("TOPRIGHT", f.title, "BOTTOMRIGHT", 0, -4)
  f.title:SetPoint("TOPRIGHT")
  f.tiles = {}
  f.settingsArea = CreateFrame("Frame", nil, f)
  f.settingsArea:SetPoint("TOPLEFT", f.grid, "BOTTOMLEFT", 0, -6)
  f.settingsArea:SetPoint("BOTTOMRIGHT")
  local list = UI.SettingsList(f.settingsArea)
  list:Header("What each bag is for")
  if not Tidy.HasRoles() then
    list:Buttons("Bag filters", "This client doesn't answer for them, so only pins are available.", {})
  end
  local options = {}
  for _, role in ipairs(Tidy.ROLES) do options[#options + 1] = { role.key, role.label } end
  for _, entry in ipairs(D.Carried()) do
    local bag = entry.id
    if bag ~= 0 and not entry.reagent and Tidy.HasRoles() then
      list:Dropdown(entry.name, nil, options, function() return Tidy.Role(bag) end, function(v) Tidy.SetRole(bag, v) end)
    end
    list:Toggle("Tidy leaves " .. entry.name .. " alone", nil, function() return Tidy.LeftAlone(bag) end, function(on) Tidy.SetLeftAlone(bag, on) end)
  end
  f.settings = list
end

local function fillPlaces(f)
  local n, step = 0, GRID_TILE + GRID_GAP
  for _, entry in ipairs(D.Carried()) do
    for slot = 1, D.Size(entry.id) do
      n = n + 1
      local tile = f.tiles[n] or gridTile(f)
      f.tiles[n] = tile
      tile.bag, tile.slot = entry.id, slot
      local info = D.Read(entry.id, slot)
      tile.id = info and info.itemID
      tile.icon:SetTexture(info and info.iconFileID or nil)
      tile.icon:SetShown(info ~= nil)
      local mark, pinned = D.Overlay.MarkOf(entry.id, slot, info)
      tile.sell:SetShown(mark == "sell")
      tile.keep:SetShown(mark == "keep")
      tile.pin:SetShown(pinned and true or false)
      tile:ClearAllPoints()
      tile:SetPoint("TOPLEFT", ((n - 1) % COLS) * step, -math.floor((n - 1) / COLS) * step)
      tile:Show()
    end
  end
  for i = n + 1, #f.tiles do f.tiles[i]:Hide() end
  f.grid:SetHeight(math.ceil(n / COLS) * step)
  f.settings:Refresh()
end

-------------------------------------------------------------------------------------------
-- History
-------------------------------------------------------------------------------------------

local function ago(at)
  local seconds = math.max(0, D.Now() - (at or 0))
  if seconds < 60 then return "just now" end
  if seconds < 3600 then return math.floor(seconds / 60) .. "m ago" end
  if seconds < 86400 then return math.floor(seconds / 3600) .. "h ago" end
  return math.floor(seconds / 86400) .. "d ago"
end

local function buildHistory(f)
  f.list = Window.RowList(f)
  f.list:SetAllPoints()
end

local function fillHistory(f)
  local items = {}
  local visit = Vendor:Visit()
  if Vendor:IsOpen() and visit and #visit.sold > 0 then
    items[#items + 1] = { group = "Can still be bought back" }
    for _, rec in ipairs(visit.sold) do
      items[#items + 1] = { id = rec.id, link = rec.link, title = itemName(rec.id, rec.name) .. (rec.count > 1 and (" × " .. rec.count) or ""), sub = rec.why, right = D.Money(rec.value),
        actions = { { text = "Buy back", width = 72, run = function() Vendor:Undo(rec) end } } }
    end
    items[#items + 1] = { group = "All of it" }
  end
  for _, h in ipairs(D:Me().history) do
    local value = h.value and (h.value < 0 and ("-" .. D.Money(-h.value)) or D.Money(h.value)) or ""
    items[#items + 1] = { id = h.id, title = h.what .. ((h.count or 0) > 1 and (" × " .. h.count) or ""), sub = (h.detail or "") .. "  ·  " .. ago(h.at), right = value }
  end
  if #items == 0 then items[1] = { title = "Nothing yet", sub = "What Dimension does shows up here" } end
  f.list:SetData(items, true)
end

panes.room = { build = buildRoom, fill = fillRoom }
panes.rules = { build = buildRules, fill = fillRules }
panes.carry = { build = buildCarry, fill = fillCarry }
panes.places = { build = buildPlaces, fill = fillPlaces }
panes.history = { build = buildHistory, fill = fillHistory }

-------------------------------------------------------------------------------------------
-- The window
-------------------------------------------------------------------------------------------

local function fillPane()
  local key = D.db.tab or "rules"
  for k, p in pairs(panes) do
    if p.frame then p.frame:SetShown(k == key) end
  end
  local p = panes[key]
  if not p.frame then
    p.frame = CreateFrame("Frame", nil, win.paneArea)
    p.frame:SetAllPoints()
    p.build(p.frame)
  end
  p.frame:Show()
  p.fill(p.frame)
  win.footerText:SetText(FOOTERS[key] or "")
  local free, total = D.FreeSlots()
  win:SetSub(string.format("%d of %d slots free", free, total))
end

local function build()
  win = UI.Window({ name = "DimensionWindow", addon = "dimension", title = "Dimension", width = W, height = H, footer = true })
  win:SetAccent("dimension")
  win:Hide()
  win.tabs = UI.Tabs(win.body, TABS, function(key)
    D.db.tab = key
    fillPane()
  end)
  win.tabs:SetPoint("TOPLEFT")
  win.tabs:SetPoint("TOPRIGHT")
  win.tabs:ApplyAccent(UI.Accent("dimension"))
  win.paneArea = CreateFrame("Frame", nil, win.body)
  win.paneArea:SetPoint("TOPLEFT", win.tabs, "BOTTOMLEFT", 14, -10)
  win.paneArea:SetPoint("BOTTOMRIGHT", -14, 10)
  win.gear = UI.Button(win.footer, "Settings", "quiet", function() D:OpenSettings() end)
  win.gear:SetHeight(20)
  win.gear:SetPoint("RIGHT", -12, 0)
end

function Window:Get()
  if not win and D.db then build() end
  return win
end

---Opens on a tab, or where it was.
function Window:Open(tab)
  if not self:Get() then return end
  if tab then D.db.tab = tab end
  D.db.tab = D.db.tab or "rules"
  win.tabs:Select(D.db.tab, true)
  win:Show()
  fillPane()
end

function Window:Refresh()
  if win and win:IsShown() then fillPane() end
end

-------------------------------------------------------------------------------------------
-- First run: how much it should do by itself (suite plan, decision 5)
-------------------------------------------------------------------------------------------

local PRESET_CARDS = {
  { key = "show", title = "Just show me", lines = "Marks and reasons on tooltips.\nSell, Tidy and Make room buttons.\nNothing happens by itself." },
  { key = "standard", title = "Standard", lines = "Sells greys at vendors, within buyback.\nRepairs.\nMerges stacks when bags fill up." },
  { key = "free", title = "Hands free", lines = "Everything in Standard.\nRuns carry and stash at the bank.\nTidies after a bank trip." },
}

local welcome

function Window:ShowWelcome()
  if not welcome then
    welcome = UI.Window({ name = "DimensionWelcome", addon = "dimension", title = "Dimension", sub = "Your bags, looked after", width = 660, height = 280 })
    welcome:SetAccent("dimension")
    welcome:Hide()
    local lead = UI.Text(welcome.body, "body", 14, C.muted)
    lead:SetPoint("TOPLEFT", 14, -12)
    lead:SetPoint("TOPRIGHT", -14, -12)
    lead:SetJustifyH("LEFT")
    lead:SetText("How much should it do by itself? It never destroys anything, and never sells what can't be bought back unless you turn that on. Any of this can change later.")
    welcome.cards = {}
    for i, spec in ipairs(PRESET_CARDS) do
      local card = UI.Button(welcome.body, spec.title, i == 2 and "accent" or "quiet", function()
        D:ApplyPreset(spec.key)
        welcome:Hide()
      end)
      card:SetSize(200, 26)
      card:SetPoint("BOTTOMLEFT", 14 + (i - 1) * 212, 14)
      local text = UI.Text(welcome.body, "body", 13, C.text)
      text:SetPoint("BOTTOMLEFT", card, "TOPLEFT", 0, 8)
      text:SetWidth(200)
      text:SetJustifyH("LEFT")
      text:SetText(spec.lines)
      welcome.cards[spec.key] = card
    end
    -- closing it is an answer too: nothing automatic
    welcome:HookScript("OnHide", function() D.db.first = false end)
    Window.welcome = welcome
  end
  welcome:Show()
end

Core:OnLogin(function()
  if D.db and D.db.first then Core:NextFrame(function() Window:ShowWelcome() end, "dimension.welcome") end
end)
