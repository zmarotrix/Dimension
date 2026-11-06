-- Dimension's settings page, under NorgannonDB in the game's Settings window (/dim settings). The
-- rules live in the window; this holds how it looks and its numbers.

local Core = NorgannonCore
local D = Dimension
if D.disabled then return end
local UI = Core.UI

local COPPER_PER_GOLD = 10000

StaticPopupDialogs["DIMENSION_FORGET_MARKS"] = {
  text = "Forget every Junk and Keep mark? The rules decide again for those items.",
  button1 = YES, button2 = NO, timeout = 0, whileDead = true, hideOnEscape = true,
  OnAccept = function()
    wipe(D.db.itemMarks)
    D:Changed()
  end,
}

Core:OnLogin(function()
  if not D.db then return end
  local page = CreateFrame("Frame")
  page:Hide()
  local list = UI.SettingsList(page)

  list:Header("Bags")
  list:Toggle("Use Dimension's bag window", "Everything grouped by what it's for, instead of the game's bags. Nothing moves. /dim bags switches too.",
    function() return D.db.pocket end, function(on) D.Pocket:SetEnabled(on) end)
  list:Toggle("Use the game's bags during fights", "Turns on by itself if the game ever blocks something of Dimension's in combat.",
    function() return D.db.combatBags == "game" end, function(on) D.db.combatBags = on and "game" or nil end)
  list:Toggle("The strip beside the game's bags", "When they're showing: free slots, what can go, and the Tidy and Make room buttons.",
    function() return D.db.strip end, function(on) D.db.strip = on D:Changed() end)
  list:Toggle("Small marks on bag slots", "A coin for what sells at the next vendor, a tick for your Keep marks, an arrow for pinned slots.",
    function() return D.db.marks end, function(on) D.db.marks = on D:Changed() end)
  list:Toggle("The verdict and reason in tooltips", nil,
    function() return D.db.tooltips end, function(on) D.db.tooltips = on end)

  list:Header("Numbers")
  list:Slider("Merge stacks at this many free slots", "With the merging rule on, this is how full bags get first.", 0, 20, 1,
    function() return D.db.mergeAt end, function(v) D.db.mergeAt = v end, "%.0f", 1)
  list:Slider("Spending cap per vendor visit", "For buying what's on the carry list, in gold.", 0, 50, 1,
    function() return (D.db.buyCap or 0) / COPPER_PER_GOLD end, function(v) D.db.buyCap = v * COPPER_PER_GOLD end, "%.0fg", 1)

  list:Header("How it starts")
  list:Buttons("First-run choices", "Choose how much it does by itself again.", { { "Show them", function() D.Window:ShowWelcome() end } })
  list:Toggle("Show the minimap button", "Dimension is also in the game's addon menu and opens with /dim.",
    function() return Core.MinimapButton:IsShown("dimension") end,
    function(on) Core.MinimapButton:SetShown("dimension", on) end)

  list:Header("Marks")
  list:Buttons("Junk and Keep marks", "They apply across the account.", { { "Forget them all", function() StaticPopup_Show("DIMENSION_FORGET_MARKS") end } })

  list:Header("Checking the client")
  list:Buttons("What this client allows", "The same as /dim probe. Each test undoes itself, and nothing is deleted.", {
    { "Summary", function() D.Probe:Run() end }, { "Sell test", function() D.Probe:Run("sell") end },
    { "Move test", function() D.Probe:Run("move") end }, { "Sort test", function() D.Probe:Run("sort") end },
  })

  list:Header("Key bindings")
  list:Buttons("Open or close, mark, pin, tidy", "Set the keys in the game's Key Bindings, under AddOns.", {})

  page:SetScript("OnShow", function() list:Refresh() end)
  D.settingsPage, D.settingsList = page, list
  D.settingsCategory = Core:AddSettingsPage(page, "Dimension")

  -- Dimension's hot paths for /norg perf (wrapped only while measuring)
  local function perf(label, tbl, method) Core:RegisterPerf("Dimension: " .. label, tbl, method, "dimension") end
  perf("bag marks", D.Overlay, "Refresh")
  perf("bag window", D.Pocket, "Refresh")
  perf("sell list", D.Rules, "SellList")
  perf("make room", D.Room, "List")
  perf("window refresh", D.Window, "Refresh")
  perf("panels", D.Panels, "Refresh")
end)

function D:OpenSettings()
  if self.settingsCategory and Settings and Settings.OpenToCategory then
    Settings.OpenToCategory(self.settingsCategory:GetID())
  else
    Core:OpenSettings()
  end
end
