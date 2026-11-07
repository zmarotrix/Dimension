-- The bag window: rows of small groups, by what things are for. Nothing physically moves, so it's instant,
-- can't fight the server's locks and doesn't depend on any sort working. Several groups come from the
-- rules and NorgannonDB, which is what a generic bag add-on can't know. Which group claims an item is one
-- fixed order; where groups sit is the player's (Edit layout), and so is a choice of group for any item.
--
-- Every slot is the client's own ContainerFrameItemButtonTemplate, so clicking, dragging, selling, using
-- and tooltips stay the game's own code. Two things keep item use free of taint. Each button gets its
-- bag from its parent's frame ID, not from a field or attribute we set (the client's GetBagID falls
-- back to that, and its own comment warns about tainting it). And nothing is ever written onto a button:
-- what we track about one lives in our own tables.
--
-- In combat it keeps updating, except under the mouse, so a slot never jumps as it's clicked. It also holds
-- still while something is being dragged and while the mover works. If it can't work in combat, the
-- game's own bags are used during fights instead (Maro, 2026-11-06): either the game locks the buttons,
-- or it blocks something of ours, which turns that on for good. A setting turns it on or off by hand.

local Core = NorgannonCore
local D = Dimension
if D.disabled then return end
local UI = Core.UI
local C = UI.C

local Pocket = {}
D.Pocket = Pocket
local Rules, Overlay = D.Rules, D.Overlay

local TEMPLATE = "ContainerFrameItemButtonTemplate"
local COLS, TILE, GAP = 14, 32, 2
local NATIVE_TILE = 37      -- the template's own size. Its textures have fixed sizes, so slots are scaled, never resized
local TILE_SCALE = TILE / NATIVE_TILE
local GROUP_GAP = 8         -- pixels between groups in a row
local ROW_GAP = 3
local WRAP_AT = 8           -- a group up to this many items stays on one line
local ARROW = 14
local MAX_ROW = 7
local PAD = 6
local HEADER_H = 16
local WINDOW_HEAD, FOOT = 32, 24
local BODY_MARGIN = 4
local BUTTON_H, BUTTON_PAD = 18, 12
local SCREEN_SHARE = .8     -- the most of the screen it takes before it scrolls
local KEYRING = -1          -- Enum.BagIndex.Keyring: the game's own frame keeps showing it

-- an item is in the first of these that claims it, wherever the groups have been moved to
local function kind(item) return Core.Bags.Kind(item.id, 1) end
local GROUPS = {
  { key = "sell", label = "To sell", ours = true, row = 0, claims = function(item) return item.verdict == "sell" end },
  { key = "quest", label = "Quests", ours = true, row = 0, claims = function(item) return item.facts.class == Rules.CLASS_QUEST or item.questItem or Rules.QuestWants(item.id) end },
  { key = "every", label = "Everyday", row = 0, claims = function(item) return Rules.IsEveryday(item.id) end },
  { key = "keeps", label = "Keepsakes", ours = true, row = 0, claims = function(item) return Rules.IsKeepsake(item.id, item.bound) end },
  { key = "food", label = "Food & drink", row = 1, claims = function(item) return kind(item) == "consumable" and Rules.ConsumableKind(item.id, item.facts, item.name) == "food" end },
  { key = "pots", label = "Potions", row = 1, claims = function(item) return kind(item) == "consumable" and Rules.ConsumableKind(item.id, item.facts, item.name) == "potion" end },
  { key = "cons", label = "Consumables", row = 1, claims = function(item) return kind(item) == "consumable" end },
  { key = "prof", label = "Professions", ours = true, row = 2, claims = function(item) return Rules.ProfessionUses(item.id) end },
  { key = "recipe", label = "Recipes", row = 2, claims = function(item) return kind(item) == "recipe" end },
  { key = "trade", label = "Trade goods", row = 2, claims = function(item) return kind(item) == "trade" end },
  { key = "gear", label = "Gear", row = 3, claims = function(item) return kind(item) == "gear" end },
  { key = "other", label = "Other", row = 3, claims = function() return true end },
  { key = "empty", label = "Empty", row = 3, empty = true, claims = function() return false end },
}
local GROUP_BY_KEY = {}
for _, g in ipairs(GROUPS) do GROUP_BY_KEY[g.key] = g end

local win
local holders, buttons = {}, {}     -- [bag] = holder frame; [bag][slot] = button
local headers, freeLabels, catchers = {}, {}, {}
local editing = false
local dirty = false
local openedAt
local broken

function Pocket:Enabled() return D.db and D.db.pocket and not broken end
function Pocket:IsShown() return win ~= nil and win:IsShown() end
function Pocket:Window() return win end

-------------------------------------------------------------------------------------------
-- Groups: only reads, so it can be checked without any frames
-------------------------------------------------------------------------------------------

local function byQuality(a, b)
  local qa, qb = a.quality or 1, b.quality or 1
  if qa ~= qb then return qa > qb end
  if a.name ~= b.name then return a.name < b.name end
  if a.count ~= b.count then return a.count > b.count end
  if a.bag ~= b.bag then return a.bag < b.bag end
  return a.slot < b.slot
end

---Where the groups sit: { { key, row } }, top to bottom and left to right. A saved layout keeps its order;
---a group added in a later version turns up where it would by default.
function Pocket.Arrangement()
  local out, seen = {}, {}
  for _, entry in ipairs(D.db.layout or {}) do
    if GROUP_BY_KEY[entry.key] and not seen[entry.key] then
      seen[entry.key] = true
      out[#out + 1] = { key = entry.key, row = entry.row }
    end
  end
  for _, g in ipairs(GROUPS) do
    if not seen[g.key] then out[#out + 1] = { key = g.key, row = g.row } end
  end
  for i, entry in ipairs(out) do entry.order = i end
  table.sort(out, function(a, b)
    if a.row ~= b.row then return a.row < b.row end
    return a.order < b.order
  end)
  return out
end

---Moves a group "left", "right", "up" or "down" and saves where everything now sits.
function Pocket:MoveGroup(key, direction)
  local list = self.Arrangement()
  local at
  for i, entry in ipairs(list) do
    if entry.key == key then at = i end
  end
  if not at then return end
  local entry = list[at]
  if direction == "up" then
    entry.row = math.max(0, entry.row - 1)
  elseif direction == "down" then
    entry.row = math.min(MAX_ROW, entry.row + 1)
  else
    local other = list[direction == "left" and at - 1 or at + 1]
    if other and other.row == entry.row then entry.order, other.order = other.order, entry.order end
  end
  table.sort(list, function(a, b)
    if a.row ~= b.row then return a.row < b.row end
    return a.order < b.order
  end)
  local saved = {}
  for i, e in ipairs(list) do saved[i] = { key = e.key, row = e.row } end
  D.db.layout = saved
  self:Layout(true)
end

---Puts every group back and forgets each item's chosen group.
function Pocket:ResetLayout()
  D.db.layout = nil
  wipe(D.db.assign)
  self:Layout(true)
end

---The groups with something in them, in the player's arrangement, and the free slots by kind of bag:
---{ { key, label, ours, row, items = { { bag, slot, id, name, quality, count } } } }, { { bag, slot, count } }.
---While editing, empty groups are included so they can be moved.
function Pocket:Sections()
  local filled, free = {}, {}
  for _, g in ipairs(GROUPS) do filled[g.key] = {} end
  local freeByKind, order = {}, {}
  for _, entry in ipairs(D.Carried()) do
    local _, family = D.In("C_Container", "GetContainerNumFreeSlots", entry.id)
    local bagKind = entry.reagent and "reagent" or (family and family ~= 0 and ("family" .. family)) or "any"
    for slot = 1, D.Size(entry.id) do
      local info = D.Read(entry.id, slot)
      if info then
        local facts = Rules.Facts(info.itemID)
        local quest = D.In("C_Container", "GetContainerItemQuestInfo", entry.id, slot)
        local item = { bag = entry.id, slot = slot, id = info.itemID, name = info.itemName or facts.name or "", quality = info.quality or facts.quality,
          count = info.stackCount or 1, facts = facts, bound = info.isBound, questItem = type(quest) == "table" and quest.isQuestItem,
          verdict = Rules:Verdict(info.itemID, info, entry.id, slot) }
        local chosen = D.db.assign[info.itemID]
        if chosen and GROUP_BY_KEY[chosen] and not GROUP_BY_KEY[chosen].empty then
          table.insert(filled[chosen], item)
        else
          for _, g in ipairs(GROUPS) do
            if g.claims(item) then
              table.insert(filled[g.key], item)
              break
            end
          end
        end
      else
        local group = freeByKind[bagKind]
        if not group then
          group = { bag = entry.id, slot = slot, count = 0 }
          freeByKind[bagKind] = group
          order[#order + 1] = group
        end
        group.count = group.count + 1
      end
    end
  end
  for i, group in ipairs(order) do free[i] = group end
  local out = {}
  for _, place in ipairs(self.Arrangement()) do
    local g = GROUP_BY_KEY[place.key]
    local items = filled[g.key]
    table.sort(items, byQuality)
    if #items > 0 or (g.empty and #free > 0) or editing then
      out[#out + 1] = { key = g.key, label = g.label, ours = g.ours, row = place.row, empty = g.empty, items = items }
    end
  end
  return out, free
end

---{ { text, func } } for choosing an item's group, for the menu Edit layout shows.
function Pocket.GroupChoices(id)
  local items = {}
  for _, g in ipairs(GROUPS) do
    if not g.empty then
      local here = D.db.assign[id] == g.key
      items[#items + 1] = { text = g.label .. (here and " (chosen)" or ""), func = function()
        D.db.assign[id] = g.key
        Pocket:Layout(true)
      end }
    end
  end
  items[#items + 1] = { text = "Back to the rules", func = function()
    D.db.assign[id] = nil
    Pocket:Layout(true)
  end }
  return items
end

-------------------------------------------------------------------------------------------
-- The slots
-------------------------------------------------------------------------------------------

local function holderFor(bag)
  if holders[bag] then return holders[bag] end
  local holder = CreateFrame("Frame", nil, win.scroll.content)
  holder:SetID(bag)
  holder:SetSize(1, 1)
  holder:SetPoint("TOPLEFT")
  holder:SetScale(TILE_SCALE)
  -- what the client's button code asks of its parent
  function holder:MatchesBagID(id) return id == bag end
  function holder:GetBagID() return bag end
  function holder:IsCombinedBagContainer() return false end
  holders[bag] = holder
  buttons[bag] = {}
  return holder
end

---The button for a slot, made once. False if the client refuses, and then the game's bags stay.
local function buttonFor(bag, slot)
  local holder = holderFor(bag)
  local b = buttons[bag][slot]
  if b then return b end
  local name = "DimensionSlot" .. (bag < 0 and "N" or "") .. math.abs(bag) .. "_" .. slot
  local ok, made = pcall(CreateFrame, "ItemButton", name, holder, TEMPLATE)
  if not ok or not made then
    broken = tostring(made)
    D.db.probe.pocket = { ok = false, detail = broken, at = D.Now() }
    D:Print("The game wouldn't make bag buttons here, so its own bags stay: " .. broken)
    return false
  end
  made:SetID(slot)
  made:SetSize(NATIVE_TILE, NATIVE_TILE)
  made:Hide()
  buttons[bag][slot] = made
  return made
end

---What the client's own bags do for a slot, leaving out only its tutorials.
local function drawSlot(b, bag, slot, owner)
  local info = D.In("C_Container", "GetContainerItemInfo", bag, slot)
  if type(info) ~= "table" then info = nil end
  local texture = info and info.iconFileID
  local quality = info and info.quality
  local quest = D.In("C_Container", "GetContainerItemQuestInfo", bag, slot)
  if type(quest) ~= "table" then quest = {} end
  ClearItemButtonOverlay(b)
  b:SetHasItem(texture)
  b:SetItemButtonTexture(texture)
  b:SyncAppearanceWithHasItem()
  SetItemButtonQuality(b, quality, info and info.hyperlink, false, info and info.isBound)
  SetItemButtonCount(b, info and info.stackCount)
  SetItemButtonDesaturated(b, info and info.isLocked)
  b:UpdateExtended()
  b:UpdateQuestItem(quest.isQuestItem, quest.questID, quest.isActive)
  b:UpdateNewItem(quality)
  b:UpdateJunkItem(quality, info and info.hasNoValue)
  b:UpdateItemContextMatching()
  b:UpdateCooldown(texture)
  b:SetReadable(info and info.isReadable)
  b:CheckUpdateTooltip(owner)
  b:SetMatchesSearch(true)
  Overlay.RefreshButton(b)
  Core:Send("NORGANNON_BAG_BUTTON_UPDATED", b)   -- for other add-ons' marks, as on the game's bags
end

local function drawAll()
  local owner = GameTooltip:GetOwner()
  for bag, slots in pairs(buttons) do
    for slot, b in pairs(slots) do
      if b:IsShown() then drawSlot(b, bag, slot, owner) end
    end
  end
end

-------------------------------------------------------------------------------------------
-- The layout
-------------------------------------------------------------------------------------------

local function headerFor(i)
  local h = headers[i]
  if h then return h end
  h = CreateFrame("Button", nil, win.scroll.content)
  h:SetHeight(HEADER_H)
  h:RegisterForClicks("LeftButtonUp")
  h.label = UI.Text(h, "title", 11, C.goldSoft)
  h.label:SetPoint("LEFT", 0, 0)
  h:SetScript("OnClick", function(self)
    D.db.collapsed[self.key] = not D.db.collapsed[self.key] or nil
    Pocket:Layout(true)
  end)
  h.arrows = {}
  local previous
  for _, spec in ipairs({ { "down", "v" }, { "up", "^" }, { "right", ">" }, { "left", "<" } }) do
    local a = UI.Button(h, spec[2], "quiet", function() Pocket:MoveGroup(h.key, spec[1]) end)
    a:SetSize(ARROW, ARROW)
    if previous then a:SetPoint("RIGHT", previous, "LEFT", -1, 0) else a:SetPoint("RIGHT", 0, 0) end
    previous = a
    h.arrows[spec[1]] = a
  end
  headers[i] = h
  return h
end

---In Edit layout, a click on an item chooses its group instead of using it, so a plain button sits over the
---game's: its own click must never run from here.
local function catcherFor(i)
  local c = catchers[i]
  if c then return c end
  c = CreateFrame("Button", nil, win.scroll.content)
  c:SetSize(TILE, TILE)
  c:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  c:SetScript("OnClick", function(self) Pocket:ChooseGroup(self.itemId, self) end)
  catchers[i] = c
  return c
end

function Pocket:ChooseGroup(id, owner)
  local name = Rules.Facts(id).name or tostring(id)
  Core:ShowActionMenu(owner or win, "item", id, { title = name .. " goes in", items = self.GroupChoices(id) })
end

---Edit layout on or off. Not in combat: it's no time to rearrange, and the game may refuse.
function Pocket:SetEditing(on)
  if on and D.PauseReason() then
    D:Print("Not now: " .. D.PauseReason() .. ".")
    return false
  end
  editing = on and true or false
  win.edit:SetLabel(editing and "Done" or "Edit layout")
  win.reset:SetShown(editing)
  self:Layout(true)
  return true
end
function Pocket:Editing() return editing end

local function freeLabel(i)
  local l = freeLabels[i]
  if l then return l end
  l = CreateFrame("Frame", nil, win.scroll.content)
  l:SetSize(TILE, TILE)
  l:EnableMouse(false)
  l.text = UI.Text(l, "bold", 13, C.muted, "OVERLAY")
  l.text:SetPoint("CENTER")
  freeLabels[i] = l
  return l
end

local function canLayout()
  if D.CursorBusy() or D.Mover:Active() then return false end
  if D.PauseReason() and win:IsMouseOver() then return false end
  -- hiding a slot closes the game's stack-split box, so a reflow waits while that's open
  local split = rawget(_G, "StackSplitFrame")
  return not (split and split:IsShown())
end

---True if the game has locked the bag buttons, which it can only do in combat.
local function buttonsLocked()
  if not D.Global("InCombatLockdown") then return false end
  for _, slots in pairs(buttons) do
    for _, b in pairs(slots) do return b:IsProtected() and true or false end
  end
  return false
end

---True if fights use the game's bags right now: the player chose that, it was blocked, or it's locked.
function Pocket.UseGameBagsNow()
  if not D.Global("InCombatLockdown") then return false end
  return D.db.combatBags == "game" or buttonsLocked()
end

---Places everything, or notes that it has to wait. `now` is for what has to happen regardless of the
---freeze, such as opening or a click on a section's title; only buttons the game has locked stop it.
function Pocket:Layout(now)
  if not win then return end
  local allowed = canLayout() or (now and not buttonsLocked())
  if not allowed then
    dirty = true
    drawAll()
    return
  end
  dirty = false
  local sections, free = self:Sections()
  local search = string.lower(win.search:GetText() or "")
  local step = TILE + GAP
  local width = COLS * step - GAP
  -- only what's left over gets hidden at the end: hiding a slot it's about to show again would close the
  -- stack-split box and make the tooltip under the mouse flicker
  local wanted = {}
  local owner = GameTooltip:GetOwner()
  local function place(b, x, y)
    wanted[b] = true
    b:ClearAllPoints()
    -- a frame's offsets are in its own scale, and slots inherit theirs from the holder
    b:SetPoint("TOPLEFT", win.scroll.content, "TOPLEFT", x / TILE_SCALE, y / TILE_SCALE)
    b:Show()
  end

  for _, l in ipairs(freeLabels) do l:Hide() end
  for _, c in ipairs(catchers) do c:Hide() end
  local usedCatchers = 0
  local x, y, lineHeight, row = 0, -2, 0, nil
  local usedHeaders = 0
  for _, s in ipairs(sections) do
    usedHeaders = usedHeaders + 1
    local h = headerFor(usedHeaders)
    local shut = D.db.collapsed[s.key] and not editing
    local count = s.empty and #free or #s.items
    h.key = s.key
    h.label:SetText(shut and string.format("+ %s (%d)", s.label, s.empty and 0 or #s.items) or s.label)
    h.label:SetTextColor(unpack(s.ours and UI.Accent("dimension") or C.goldSoft))
    for _, a in pairs(h.arrows) do a:SetShown(editing) end

    -- wide enough for its title, then its items: long groups fold to two lines
    local titleWidth = (h.label:GetStringWidth() or 0) + 6 + (editing and 4 * (ARROW + 1) or 0)
    local shown = shut and 0 or count
    local columns = shown <= WRAP_AT and shown or math.ceil(shown / 2)
    columns = math.min(COLS, math.max(columns, math.ceil(titleWidth / step)))
    local pixels = math.min(width, columns * step - GAP)

    if row ~= nil and (s.row ~= row or x + pixels > width) then
      y = y - lineHeight - ROW_GAP
      x, lineHeight = 0, 0
    end
    row = s.row
    h:ClearAllPoints()
    h:SetPoint("TOPLEFT", win.scroll.content, "TOPLEFT", x, y)
    h:SetWidth(pixels)
    h:Show()

    local top = y - HEADER_H
    if not shut then
      if s.empty then
        -- one real slot per kind of bag, so an item can be dropped on it
        for i, group in ipairs(free) do
          local b = buttonFor(group.bag, group.slot)
          if b == false then return end
          place(b, x + (i - 1) * step, top)
          drawSlot(b, group.bag, group.slot, owner)
          b:SetAlpha(1)
          local l = freeLabel(i)
          l:ClearAllPoints()
          l:SetPoint("TOPLEFT", b, "TOPLEFT")
          l:SetFrameLevel((b:GetFrameLevel() or 1) + 4)
          l.text:SetText(tostring(group.count))
          l:Show()
        end
      else
        for i, item in ipairs(s.items) do
          local b = buttonFor(item.bag, item.slot)
          if b == false then return end
          local bx, by = x + (i - 1) % columns * step, top - math.floor((i - 1) / columns) * step
          place(b, bx, by)
          drawSlot(b, item.bag, item.slot, owner)
          local matches = search == "" or string.find(string.lower(item.name), search, 1, true) ~= nil
          b:SetAlpha(matches and 1 or .2)
          if editing then
            usedCatchers = usedCatchers + 1
            local c = catcherFor(usedCatchers)
            c.itemId = item.id
            c:ClearAllPoints()
            c:SetPoint("TOPLEFT", b, "TOPLEFT")
            c:SetFrameLevel((b:GetFrameLevel() or 1) + 5)
            c:Show()
          end
        end
      end
    end
    local lines = columns > 0 and math.ceil(shown / columns) or 0
    lineHeight = math.max(lineHeight, HEADER_H + lines * step)
    x = x + pixels + GROUP_GAP
  end
  for i = usedHeaders + 1, #headers do headers[i]:Hide() end
  for _, slots in pairs(buttons) do
    for _, b in pairs(slots) do
      if not wanted[b] then b:Hide() end
    end
  end
  Pocket.lastSections, Pocket.lastFree = sections, free

  -- it fits its contents until it would take too much of the screen
  local height = -(y - lineHeight)
  win.scroll.content:SetSize(width, height)
  local chrome = WINDOW_HEAD + FOOT + 2 * BODY_MARGIN
  win:SetSize(width + 2 * PAD, math.min(height + chrome, GetScreenHeight() * SCREEN_SHARE))
  self:DrawFooter()
end

---Each footer button as wide as its text, measured whenever it's drawn: a label's width depends on the player's
---font and scale, and is only reliable once the client has sized the text.
local function fitFooterButtons()
  for _, b in ipairs({ win.more, win.room, win.edit, win.reset }) do
    b:SetWidth(math.ceil(b.label:GetStringWidth() or 0) + BUTTON_PAD)
  end
end

function Pocket:DrawFooter()
  fitFooterButtons()
  local totalFree, total = D.FreeSlots()
  win:SetSub(string.format("%d of %d free", totalFree, total))
  win.money:SetText(editing and "" or D.Money(D.Global("GetMoney") or 0))   -- the hint needs the room
  local status = D.Mover:Status()
  local text = editing and "Click an item to regroup it." or ""
  if status then
    text = status.paused and ("Paused: " .. status.paused) or string.format("%s: %d of %d", status.label or "Moving", status.done, status.total)
  end
  win.footerText:SetText(text)
end

---Icons and marks always; the layout when it's allowed.
function Pocket:Refresh()
  if not self:IsShown() then return end
  self:Layout()
  self:DrawFooter()
end

-------------------------------------------------------------------------------------------
-- The window
-------------------------------------------------------------------------------------------

local function build()
  win = UI.Window({ name = "DimensionPocket", addon = "dimension", title = "Dimension", width = COLS * (TILE + GAP) - GAP + 2 * PAD, height = 400, footer = true })
  win:SetAccent("dimension")
  win:Hide()
  if win.powered then win.powered:Hide() end
  if not (Core.db and Core.db.windows and Core.db.windows.DimensionPocket) then
    win:ClearAllPoints()
    win:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -40, 100)
  end
  -- a smaller head and foot than a full suite window, with the search in the head instead of a row of its own
  win.header:SetHeight(WINDOW_HEAD)
  win.footer:SetHeight(FOOT)
  win.mark:SetSize(22, 22)
  win.title:SetFontObject(UI.Font("title", 15))
  win.sub:SetFontObject(UI.Font("body", 12))
  win.search = UI.Search(win.header, "Search", function() Pocket:Layout(true) end)
  win.search:SetSize(150, 22)
  win.search:SetPoint("RIGHT", win.close, "LEFT", -8, 0)
  win.scroll = UI.ScrollArea(win.body)
  win.scroll:SetPoint("TOPLEFT", PAD, -BODY_MARGIN)
  win.scroll:SetPoint("BOTTOMRIGHT", -PAD, BODY_MARGIN)
  win.money = UI.Text(win.footer, "bold", 14)
  win.money:SetPoint("LEFT", 12, 0)
  win.footerText:ClearAllPoints()
  win.footerText:SetPoint("LEFT", win.money, "RIGHT", 10, 0)
  win.more = UI.Button(win.footer, "Rules", "quiet", function() D.Window:Open("rules") end)
  win.more:SetHeight(BUTTON_H)
  win.more:SetPoint("RIGHT", -8, 0)
  win.room = UI.Button(win.footer, "Make room", "quiet", function() D.Window:Open("room") end)
  win.room:SetHeight(BUTTON_H)
  win.room:SetPoint("RIGHT", win.more, "LEFT", -4, 0)
  win.edit = UI.Button(win.footer, "Edit layout", "quiet", function() Pocket:SetEditing(not editing) end)
  win.edit:SetHeight(BUTTON_H)
  win.edit:SetPoint("RIGHT", win.room, "LEFT", -4, 0)
  win.reset = UI.Button(win.footer, "Reset", "quiet", function() Pocket:ResetLayout() end)
  win.reset:SetHeight(BUTTON_H)
  win.reset:SetPoint("RIGHT", win.edit, "LEFT", -4, 0)
  for _, b in ipairs({ win.more, win.room, win.edit, win.reset }) do
    b.label:SetFontObject(UI.Font("title", 12))
  end
  win.reset:Hide()
  win.footerText:SetPoint("RIGHT", win.reset, "LEFT", -6, 0)
  win.footerText:SetWordWrap(false)
  Pocket.frame = win
end

---Makes the buttons for every slot now, out of combat, so opening in a fight needs nothing new.
local function makeAll()
  if not win then build() end
  for _, entry in ipairs(D.Carried()) do
    for slot = 1, D.Size(entry.id) do
      if buttonFor(entry.id, slot) == false then return end
    end
  end
end

local function hideGameBags()
  for _, frame in ipairs(Overlay.ContainerFrames()) do
    if frame:IsShown() and not Pocket.KeepGameFrame(frame) then frame:Hide() end
  end
end

---The keyring stays the game's, and so does anything it won't let us hide in combat.
function Pocket.KeepGameFrame(frame)
  if frame.GetBagID then
    local ok, bag = pcall(frame.GetBagID, frame)
    if ok and bag == KEYRING then return true end
  end
  if Pocket.UseGameBagsNow() then return true end
  return D.Global("InCombatLockdown") and frame.IsProtected and frame:IsProtected()
end

function Pocket:Open()
  if not self:Enabled() then return end
  makeAll()
  if broken or win:IsShown() or Pocket.UseGameBagsNow() then return end
  openedAt = GetTime()
  win:Show()
  self:Layout(true)
  hideGameBags()
end

function Pocket:Close()
  if not win then return end
  if editing then self:SetEditing(false) end
  win:Hide()
end

function Pocket:Toggle()
  if self:IsShown() then self:Close() else self:Open() end
end

---Turns the window on or off; off hands everything back to the game's bags.
function Pocket:SetEnabled(on)
  D.db.pocket = on and true or false
  if not on then self:Close() end
  D:Changed()
end

-------------------------------------------------------------------------------------------
-- Opening instead of the game's bags: its functions are never replaced. They run, what they show is
-- hidden straight away, and this follows. The game's toggles always see closed bags and so always
-- open them, which runs OpenBackpack first: the time check stops that open being closed again.
-------------------------------------------------------------------------------------------

local function allowed()
  local fn = rawget(_G, "ContainerFrame_AllowedToOpenBags")
  return not fn or fn()
end

local function onToggle()
  if not Pocket:Enabled() or not allowed() or Pocket.UseGameBagsNow() then return end
  if openedAt == GetTime() then return end
  Pocket:Toggle()
end

local function onOpen()
  if Pocket:Enabled() and allowed() then Pocket:Open() end
end

local function onClose()
  if Pocket:Enabled() then Pocket:Close() end
end

---Hooks once, at login: bag buttons get made while it's safe.
function Pocket:Hook()
  if self.hooked then return end
  self.hooked = true
  for _, name in ipairs({ "ToggleAllBags", "ToggleBackpack" }) do
    if rawget(_G, name) then hooksecurefunc(name, onToggle) end
  end
  if rawget(_G, "ToggleBag") then
    hooksecurefunc("ToggleBag", function(id)
      if id ~= KEYRING then onToggle() end
    end)
  end
  for _, name in ipairs({ "OpenAllBags", "OpenBackpack" }) do
    if rawget(_G, name) then hooksecurefunc(name, onOpen) end
  end
  if rawget(_G, "CloseAllBags") then hooksecurefunc("CloseAllBags", onClose) end
  for _, frame in ipairs(Overlay.ContainerFrames()) do
    frame:HookScript("OnShow", function(self)
      if Pocket:Enabled() and not Pocket.KeepGameFrame(self) then self:Hide() end
    end)
  end
end

Core:OnLogin(function()
  if not D.db then return end
  Pocket:Hook()
  Core:AfterCombat(function()
    if Pocket:Enabled() then
      makeAll()
      if not broken then Pocket:Layout(true) end
    end
  end, "dimension.pocket")
end)

-- ready ahead of a fight; or, if fights use the game's bags, out of the way before lockdown starts
Core:On("PLAYER_REGEN_DISABLED", "dimension.pocket", function()
  if not (Pocket:Enabled() and win) then return end
  if D.db.combatBags == "game" then
    Pocket:Close()
  elseif not win:IsShown() then
    Pocket:Layout(true)
  end
end)

-- the fight's over: anything the game's bags showed in the meantime comes back to the window
Core:On("PLAYER_REGEN_ENABLED", "dimension.pocket.return", function()
  if not Pocket:Enabled() then return end
  local showing = false
  for _, frame in ipairs(Overlay.ContainerFrames()) do
    if frame:IsShown() and not Pocket.KeepGameFrame(frame) then showing = true end
  end
  if showing then Pocket:Open() end
end)

-- the game refusing something of ours in combat is the real answer to whether this works there
local function blocked(_, addon, what)
  if addon ~= D.addonName or Core.IsSecret(addon) then return end
  D.db.probe.blocked = { what = tostring(what), at = D.Now(), inCombat = D.Global("InCombatLockdown") and true or false }
  if D.Global("InCombatLockdown") and D.db.combatBags ~= "game" then
    D.db.combatBags = "game"
    Pocket:Close()
    D:Print("The game blocked " .. tostring(what) .. " in combat, so fights now use its own bags. Settings can change that back.")
  end
end
Core:On("ADDON_ACTION_BLOCKED", "dimension.pocket", blocked)
Core:On("ADDON_ACTION_FORBIDDEN", "dimension.pocket", blocked)

-- a new bag means new slots; catching up once a frozen layout is allowed to move
Core:On("BAG_CONTAINER_UPDATE", "dimension.pocket", function()
  Core:AfterCombat(function()
    if Pocket:Enabled() and win then makeAll() end
  end, "dimension.pocket")
end)
for _, event in ipairs({ "PLAYER_REGEN_ENABLED", "CURSOR_CHANGED" }) do
  Core:On(event, "dimension.pocket", function()
    if dirty then D:Changed() end
  end)
end
for _, event in ipairs({ "ITEM_LOCK_CHANGED", "BAG_UPDATE_COOLDOWN", "BAG_NEW_ITEMS_UPDATED", "MERCHANT_SHOW", "MERCHANT_CLOSED", "PLAYER_MONEY" }) do
  Core:On(event, "dimension.pocket", function() D:Changed() end)
end
