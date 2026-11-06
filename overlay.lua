-- What Providence adds to the game's own bags: a strip beside them and small marks on the slots. It
-- never replaces them. Marks are separate frames that take no mouse, kept in a table of our own, so
-- nothing is written onto Blizzard's buttons and clicks reach them as before.

local Core = NorgannonCore
local P = Providence
if P.disabled then return end
local UI = Core.UI
local C = UI.C

local Overlay = {}
P.Overlay = Overlay
local Rules = P.Rules

local MARK_SIZE = 13
local STRIP_W, STRIP_H = 318, 38
local LOW_FREE = 4           -- the strip's count turns to a warning at this many free slots
local GOLD, GREEN = { .91, .78, .42 }, { .56, .88, .56 }
local WARN = { 1, .58, .47 }

local marks = setmetatable({}, { __mode = "k" })   -- item button -> its marks
Overlay.marks = marks
local hooked = {}
local strip

local function containerFrames()
  local out = {}
  local combined = rawget(_G, "ContainerFrameCombinedBags")
  if combined then out[#out + 1] = combined end
  for i = 1, rawget(_G, "NUM_CONTAINER_FRAMES") or 13 do
    local f = rawget(_G, "ContainerFrame" .. i)
    if f then out[#out + 1] = f end
  end
  return out
end

local function marksFor(button)
  local m = marks[button]
  if m then return m end
  m = CreateFrame("Frame", nil, button)
  m:SetAllPoints()
  m:EnableMouse(false)
  m:SetFrameLevel((button:GetFrameLevel() or 1) + 3)
  m.sell = UI.Icon(m, "circle", MARK_SIZE, GOLD, "OVERLAY")
  m.sell:SetPoint("TOPLEFT", 1, -1)
  m.keep = UI.Icon(m, "check", MARK_SIZE, GREEN, "OVERLAY")
  m.keep:SetPoint("TOPLEFT", 1, -1)
  m.pin = UI.Icon(m, "chevron", MARK_SIZE, UI.Accent("providence"), "OVERLAY")
  m.pin:SetPoint("TOPRIGHT", -1, -1)
  marks[button] = m
  return m
end

---Which mark a slot shows: "sell", "keep" (only your own Keep marks: everything kept would be noise)
---or nil, and whether it's pinned. Also used by the Places grid.
function Overlay.MarkOf(bag, slot, info)
  local pinned = P:Me().pins[bag .. ":" .. slot] ~= nil
  if not info then return nil, pinned end
  if P.db.itemMarks[info.itemID] == "keep" then return "keep", pinned end
  if Rules:Verdict(info.itemID, info, bag, slot) == "sell" then return "sell", pinned end
  return nil, pinned
end

local function refreshButton(button)
  local okBag, bag = pcall(button.GetBagID, button)
  local okSlot, slot = pcall(button.GetID, button)
  if not (okBag and okSlot and bag and slot) or Core.IsSecret(bag) then return end
  local m = marksFor(button)
  local show, pinned
  if P.db.marks then
    show, pinned = Overlay.MarkOf(bag, slot, P.Read(bag, slot))
  end
  m.sell:SetShown(show == "sell")
  m.keep:SetShown(show == "keep")
  m.pin:SetShown(pinned and true or false)
end

local function refreshFrame(frame)
  if not (frame.EnumerateValidItems and frame:IsShown()) then return end
  for _, button in frame:EnumerateValidItems() do refreshButton(button) end
end

-------------------------------------------------------------------------------------------
-- The strip
-------------------------------------------------------------------------------------------

local function buildStrip()
  strip = CreateFrame("Frame", "ProvidenceStrip", UIParent)
  strip:SetSize(STRIP_W, STRIP_H)
  strip:SetFrameStrata("HIGH")
  strip:Hide()
  local edge = UI.Tex(strip, "BACKGROUND", 0, UI.Accent("providence"))
  edge:SetAllPoints()
  local back = UI.Tex(strip, "BACKGROUND", 1, C.stone)
  back:SetPoint("TOPLEFT", 1, -1)
  back:SetPoint("BOTTOMRIGHT", -1, 1)
  local mark = UI.Mark(strip, "providence", 24)
  mark:SetPoint("LEFT", 6, 0)
  strip.count = UI.Text(strip, "bold", 13)
  strip.count:SetPoint("TOPLEFT", mark, "TOPRIGHT", 6, 1)
  strip.note = UI.Text(strip, "body", 11, C.muted)
  strip.note:SetPoint("TOPLEFT", strip.count, "BOTTOMLEFT", 0, -1)
  strip.settings = UI.Button(strip, "...", "quiet", function() P.Window:Open("rules") end)
  strip.settings:SetSize(24, 22)
  strip.settings:SetPoint("RIGHT", -6, 0)
  strip.room = UI.Button(strip, "Make room", "quiet", function() P.Window:Open("room") end)
  strip.room:SetSize(78, 22)
  strip.room:SetPoint("RIGHT", strip.settings, "LEFT", -4, 0)
  strip.tidy = UI.Button(strip, "Tidy", "quiet", function() P.Tidy:Run() end)
  strip.tidy:SetSize(44, 22)
  strip.tidy:SetPoint("RIGHT", strip.room, "LEFT", -4, 0)
  Overlay.strip = strip
end

local function backpackFrame()
  local combined = rawget(_G, "ContainerFrameCombinedBags")
  if combined and combined:IsShown() then return combined end
  local first = rawget(_G, "ContainerFrame1")
  if first and first:IsShown() then return first end
  for _, f in ipairs(containerFrames()) do
    if f:IsShown() then return f end
  end
end

local function refreshStrip()
  local anchor = P.db.strip and backpackFrame()
  if not anchor then
    if strip then strip:Hide() end
    return
  end
  if not strip then buildStrip() end
  strip:ClearAllPoints()
  -- to the left of the backpack: other bags stack above it, and this stays clear of them
  strip:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMLEFT", -4, 0)
  local free, total = P.FreeSlots()
  local tone = free <= LOW_FREE and UI.Code(WARN) or ""
  strip.count:SetText(string.format("%s%d of %d free%s", tone, free, total, tone ~= "" and "|r" or ""))
  local status = P.Mover:Status()
  local paused = P.PauseReason()
  if paused then
    strip.note:SetText("Waiting: " .. paused)
  elseif status then
    strip.note:SetText(status.paused and ("Paused: " .. status.paused) or string.format("%s: %d of %d", status.label or "Moving", status.done, status.total))
  else
    local sell = #Rules:SellList()
    strip.note:SetText(sell > 0 and string.format("%d can go at the next vendor", sell) or "Nothing to sell")
  end
  strip:Show()
end

---Marks and strip again, for whichever bags are showing.
function Overlay:Refresh()
  if not P.db then return end
  self:HookFrames()
  for _, frame in ipairs(containerFrames()) do refreshFrame(frame) end
  refreshStrip()
end

---Follows the game's bag frames as they open and fill. Runs again until they exist: some load late.
function Overlay:HookFrames()
  for _, frame in ipairs(containerFrames()) do
    if not hooked[frame] then
      hooked[frame] = true
      local again = function() P:Changed() end
      frame:HookScript("OnShow", again)
      frame:HookScript("OnHide", again)
      if frame.UpdateItems then hooksecurefunc(frame, "UpdateItems", again) end
    end
  end
end

Core:OnLogin(function() if P.db then Overlay:HookFrames() end end)
for _, event in ipairs({ "BAG_UPDATE_DELAYED", "ITEM_UNLOCKED", "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED", "ADDON_RESTRICTION_STATE_CHANGED" }) do
  Core:On(event, "providence.overlay", function() P:Changed() end)
end
for _, message in ipairs({ "NORGANNON_QUESTLOG_UPDATED", "NORGANNON_SKILLS_CHANGED" }) do
  Core:Listen(message, "providence.overlay", function() P:Changed() end)
end

-------------------------------------------------------------------------------------------
-- Marking by key: works on any hovered item, with the mouse or the gamepad's cursor
-------------------------------------------------------------------------------------------

---bag, slot, id under the mouse, as far as they're known: a bag button gives all three, any other
---item tooltip only the id.
function Overlay.Hovered()
  local foci = P.Global("GetMouseFoci")
  local focus = type(foci) == "table" and foci[1]
  if focus and not Core.IsSecret(focus) and focus.GetBagID and focus.GetID then
    local ok, bag = pcall(focus.GetBagID, focus)
    local slot = focus:GetID()
    if ok and bag and slot then
      local info = P.Read(bag, slot)
      return bag, slot, info and info.itemID
    end
  end
  if GameTooltip:IsShown() and GameTooltip.GetItem then
    local _, link = GameTooltip:GetItem()
    if type(link) == "string" and not Core.IsSecret(link) then
      return nil, nil, tonumber(link:match("item:(%d+)"))
    end
  end
end

local MARK_WORD = { junk = "Junk: it sells at the next vendor", keep = "Keep: it won't be sold" }

function Overlay:MarkHovered()
  local _, _, id = Overlay.Hovered()
  if not id then return end
  local mark = Rules:CycleMark(id)
  P:Print(mark and MARK_WORD[mark] or "Mark removed: the rules decide again.")
end

function Overlay:PinHovered()
  local bag, slot = Overlay.Hovered()
  if not bag then return end
  P:Print(P.Tidy:TogglePin(bag, slot) and "Pinned: Tidy puts it back here, and bank trips leave it alone." or "Unpinned.")
end
