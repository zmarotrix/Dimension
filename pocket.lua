-- The bag window: one window, grouped by what things are for. Nothing physically moves, so it's instant,
-- can't fight the server's locks and doesn't depend on any sort working. The first sections come from
-- the rules and NorgannonDB, which is what a generic bag add-on can't know.
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
local COLS, TILE, GAP = 10, 37, 2
local PAD = 10
local HEADER_H = 20
local WINDOW_HEAD, SEARCH_H, FOOT = 44, 30, 30
local SCREEN_SHARE = .8     -- the most of the screen it takes before it scrolls
local KEYRING = -1          -- Enum.BagIndex.Keyring: the game's own frame keeps showing it

-- in order: an item is in the first section that claims it
local SECTIONS = {
  { key = "sell", label = "Sells at the next vendor", ours = true, claims = function(item) return item.verdict == "sell" end },
  { key = "quest", label = "For your quests", ours = true, claims = function(item) return item.facts.class == Rules.CLASS_QUEST or item.questItem or Rules.QuestWants(item.id) end },
  { key = "prof", label = "Your professions use", ours = true, claims = function(item) return Rules.ProfessionUses(item.id) end },
  { key = "every", label = "Always with you", claims = function(item) return Rules.IsEveryday(item.id) end },
  { key = "cons", label = "Consumables", claims = function(item) return Core.Bags.Kind(item.id, 1) == "consumable" end },
  { key = "gear", label = "Gear", claims = function(item) return Core.Bags.Kind(item.id, 1) == "gear" end },
  { key = "recipe", label = "Recipes", claims = function(item) return Core.Bags.Kind(item.id, 1) == "recipe" end },
  { key = "trade", label = "Other trade goods", claims = function(item) return Core.Bags.Kind(item.id, 1) == "trade" end },
  { key = "other", label = "Everything else", claims = function() return true end },
}

local win
local holders, buttons = {}, {}     -- [bag] = holder frame; [bag][slot] = button
local headers, freeLabels = {}, {}
local dirty = false
local openedAt
local broken

function Pocket:Enabled() return D.db and D.db.pocket and not broken end
function Pocket:IsShown() return win ~= nil and win:IsShown() end
function Pocket:Window() return win end

-------------------------------------------------------------------------------------------
-- Sections: only reads, so it can be checked without any frames
-------------------------------------------------------------------------------------------

local function byQuality(a, b)
  local qa, qb = a.quality or 1, b.quality or 1
  if qa ~= qb then return qa > qb end
  if a.name ~= b.name then return a.name < b.name end
  if a.count ~= b.count then return a.count > b.count end
  if a.bag ~= b.bag then return a.bag < b.bag end
  return a.slot < b.slot
end

---The sections with something in them, in order, and the free slots by kind of bag:
---{ { key, label, ours, items = { { bag, slot, id, name, quality, count } } } }, { { bag, slot, count } }.
function Pocket:Sections()
  local filled, free = {}, {}
  for _, s in ipairs(SECTIONS) do filled[s.key] = {} end
  local freeByKind, order = {}, {}
  for _, entry in ipairs(D.Carried()) do
    local _, family = D.In("C_Container", "GetContainerNumFreeSlots", entry.id)
    local kind = entry.reagent and "reagent" or (family and family ~= 0 and ("family" .. family)) or "any"
    for slot = 1, D.Size(entry.id) do
      local info = D.Read(entry.id, slot)
      if info then
        local facts = Rules.Facts(info.itemID)
        local quest = D.In("C_Container", "GetContainerItemQuestInfo", entry.id, slot)
        local item = { bag = entry.id, slot = slot, id = info.itemID, name = info.itemName or facts.name or "", quality = info.quality or facts.quality,
          count = info.stackCount or 1, facts = facts, questItem = type(quest) == "table" and quest.isQuestItem,
          verdict = Rules:Verdict(info.itemID, info, entry.id, slot) }
        for _, s in ipairs(SECTIONS) do
          if s.claims(item) then
            table.insert(filled[s.key], item)
            break
          end
        end
      else
        local group = freeByKind[kind]
        if not group then
          group = { bag = entry.id, slot = slot, count = 0 }
          freeByKind[kind] = group
          order[#order + 1] = group
        end
        group.count = group.count + 1
      end
    end
  end
  local out = {}
  for _, s in ipairs(SECTIONS) do
    local items = filled[s.key]
    if #items > 0 then
      table.sort(items, byQuality)
      out[#out + 1] = { key = s.key, label = s.label, ours = s.ours, items = items }
    end
  end
  for i, group in ipairs(order) do free[i] = group end
  return out, free
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
  made:SetSize(TILE, TILE)
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
  h.label = UI.Text(h, "title", 13, C.goldSoft)
  h.label:SetPoint("LEFT", 0, 0)
  h.count = UI.Text(h, "body", 11, C.faint)
  h.count:SetPoint("RIGHT", 0, 0)
  h:SetScript("OnClick", function(self)
    if self.key == "free" then return end
    D.db.collapsed[self.key] = not D.db.collapsed[self.key] or nil
    Pocket:Layout(true)
  end)
  headers[i] = h
  return h
end

local function freeLabel(i)
  local l = freeLabels[i]
  if l then return l end
  l = CreateFrame("Frame", nil, win.scroll.content)
  l:SetSize(TILE, TILE)
  l:EnableMouse(false)
  l.text = UI.Text(l, "bold", 14, C.muted, "OVERLAY")
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
  local y, usedHeaders = -2, 0
  local function place(b, column, top)
    wanted[b] = true
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", win.scroll.content, "TOPLEFT", column * step, top)
    b:Show()
  end
  local owner = GameTooltip:GetOwner()
  for _, s in ipairs(sections) do
    usedHeaders = usedHeaders + 1
    local h = headerFor(usedHeaders)
    local shut = D.db.collapsed[s.key]
    h.key = s.key
    h.label:SetText((shut and "+ " or "- ") .. s.label)
    h.label:SetTextColor(unpack(s.ours and UI.Accent("dimension") or C.goldSoft))
    h.count:SetText(tostring(#s.items))
    h:ClearAllPoints()
    h:SetPoint("TOPLEFT", win.scroll.content, "TOPLEFT", 0, y)
    h:SetWidth(width)
    h:Show()
    y = y - HEADER_H
    if not shut then
      for i, item in ipairs(s.items) do
        local b = buttonFor(item.bag, item.slot)
        if b == false then return end
        place(b, (i - 1) % COLS, y - math.floor((i - 1) / COLS) * step)
        drawSlot(b, item.bag, item.slot, owner)
        local matches = search == "" or string.find(string.lower(item.name), search, 1, true) ~= nil
        b:SetAlpha(matches and 1 or .2)
      end
      y = y - math.ceil(#s.items / COLS) * step - 4
    end
  end
  for i = usedHeaders + 1, #headers do headers[i]:Hide() end

  -- the free slots: one real slot per kind of bag, so an item can be dropped on it
  for _, l in ipairs(freeLabels) do l:Hide() end
  if #free > 0 then
    usedHeaders = usedHeaders + 1
    local h = headerFor(usedHeaders)
    h.key = "free"
    h.label:SetText("Free")
    h.label:SetTextColor(unpack(C.goldSoft))
    h.count:SetText("")
    h:ClearAllPoints()
    h:SetPoint("TOPLEFT", win.scroll.content, "TOPLEFT", 0, y)
    h:SetWidth(width)
    h:Show()
    y = y - HEADER_H
    for i, group in ipairs(free) do
      local b = buttonFor(group.bag, group.slot)
      if b == false then return end
      place(b, i - 1, y)
      drawSlot(b, group.bag, group.slot, owner)
      b:SetAlpha(1)
      local l = freeLabel(i)
      l:ClearAllPoints()
      l:SetPoint("TOPLEFT", b, "TOPLEFT")
      l:SetFrameLevel((b:GetFrameLevel() or 1) + 4)
      l.text:SetText(tostring(group.count))
      l:Show()
    end
    y = y - step
  end
  for _, slots in pairs(buttons) do
    for _, b in pairs(slots) do
      if not wanted[b] then b:Hide() end
    end
  end
  Pocket.lastSections, Pocket.lastFree = sections, free

  -- it fits its contents until it would take too much of the screen
  local height = -y
  win.scroll.content:SetSize(width, height)
  local chrome = WINDOW_HEAD + SEARCH_H + FOOT + PAD
  win:SetSize(width + 2 * PAD + 12, math.min(height + chrome, GetScreenHeight() * SCREEN_SHARE))
  self:DrawFooter()
end

function Pocket:DrawFooter()
  local totalFree, total = D.FreeSlots()
  win:SetSub(string.format("%d of %d free", totalFree, total))
  win.money:SetText(D.Money(D.Global("GetMoney") or 0))
  local status = D.Mover:Status()
  local text = ""
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
  win = UI.Window({ name = "DimensionPocket", addon = "dimension", title = "Dimension", width = COLS * (TILE + GAP) + 2 * PAD + 12, height = 400, footer = true })
  win:SetAccent("dimension")
  win:Hide()
  if win.powered then win.powered:Hide() end
  if not (Core.db and Core.db.windows and Core.db.windows.DimensionPocket) then
    win:ClearAllPoints()
    win:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -40, 100)
  end
  win.search = UI.Search(win.body, "Search your bags", function() Pocket:Layout(true) end)
  win.search:SetPoint("TOPLEFT", PAD, -6)
  win.search:SetPoint("TOPRIGHT", -PAD, -6)
  win.scroll = UI.ScrollArea(win.body)
  win.scroll:SetPoint("TOPLEFT", PAD, -SEARCH_H - 4)
  win.scroll:SetPoint("BOTTOMRIGHT", -PAD, 4)
  win.money = UI.Text(win.footer, "body", 12)
  win.money:SetPoint("LEFT", 12, 0)
  win.footerText:ClearAllPoints()
  win.footerText:SetPoint("LEFT", win.money, "RIGHT", 10, 0)
  win.more = UI.Button(win.footer, "Rules", "quiet", function() D.Window:Open("rules") end)
  win.more:SetSize(50, 20)
  win.more:SetPoint("RIGHT", -8, 0)
  win.room = UI.Button(win.footer, "Make room", "quiet", function() D.Window:Open("room") end)
  win.room:SetSize(78, 20)
  win.room:SetPoint("RIGHT", win.more, "LEFT", -4, 0)
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
  if win then win:Hide() end
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
