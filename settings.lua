-- Providence's settings page, under NorgannonDB in the game's Settings window (/prov settings). The
-- rules live in the window; this holds how it looks and its numbers.

local Core = NorgannonCore
local P = Providence
if P.disabled then return end
local UI = Core.UI

local COPPER_PER_GOLD = 10000

StaticPopupDialogs["PROVIDENCE_FORGET_MARKS"] = {
  text = "Forget every Junk and Keep mark? The rules decide again for those items.",
  button1 = YES, button2 = NO, timeout = 0, whileDead = true, hideOnEscape = true,
  OnAccept = function()
    wipe(P.db.itemMarks)
    P:Changed()
  end,
}

Core:OnLogin(function()
  if not P.db then return end
  local page = CreateFrame("Frame")
  page:Hide()
  local list = UI.SettingsList(page)

  list:Header("The game's bags")
  list:Toggle("The strip beside the bags", "Free slots, what can go, and the Tidy and Make room buttons.",
    function() return P.db.strip end, function(on) P.db.strip = on P:Changed() end)
  list:Toggle("Small marks on bag slots", "A coin for what sells at the next vendor, a tick for your Keep marks, an arrow for pinned slots.",
    function() return P.db.marks end, function(on) P.db.marks = on P:Changed() end)
  list:Toggle("The verdict and reason in tooltips", nil,
    function() return P.db.tooltips end, function(on) P.db.tooltips = on end)

  list:Header("Numbers")
  list:Slider("Merge stacks at this many free slots", "With the merging rule on, this is how full bags get first.", 0, 20, 1,
    function() return P.db.mergeAt end, function(v) P.db.mergeAt = v end, "%.0f", 1)
  list:Slider("Spending cap per vendor visit", "For buying what's on the carry list, in gold.", 0, 50, 1,
    function() return (P.db.buyCap or 0) / COPPER_PER_GOLD end, function(v) P.db.buyCap = v * COPPER_PER_GOLD end, "%.0fg", 1)

  list:Header("How it starts")
  list:Buttons("First-run choices", "Choose how much it does by itself again.", { { "Show them", function() P.Window:ShowWelcome() end } })
  list:Toggle("Show the minimap button", "Providence is also in the game's addon menu and opens with /prov.",
    function() return Core.MinimapButton:IsShown("providence") end,
    function(on) Core.MinimapButton:SetShown("providence", on) end)

  list:Header("Marks")
  list:Buttons("Junk and Keep marks", "They apply across the account.", { { "Forget them all", function() StaticPopup_Show("PROVIDENCE_FORGET_MARKS") end } })

  list:Header("Checking the client")
  list:Buttons("What this client allows", "The same as /prov probe. Each test undoes itself, and nothing is deleted.", {
    { "Summary", function() P.Probe:Run() end }, { "Sell test", function() P.Probe:Run("sell") end },
    { "Move test", function() P.Probe:Run("move") end }, { "Sort test", function() P.Probe:Run("sort") end },
  })

  list:Header("Key bindings")
  list:Buttons("Open or close, mark, pin, tidy", "Set the keys in the game's Key Bindings, under AddOns.", {})

  page:SetScript("OnShow", function() list:Refresh() end)
  P.settingsPage, P.settingsList = page, list
  P.settingsCategory = Core:AddSettingsPage(page, "Providence")

  -- Providence's hot paths for /norg perf (wrapped only while measuring)
  local function perf(label, tbl, method) Core:RegisterPerf("Providence: " .. label, tbl, method, "providence") end
  perf("bag marks", P.Overlay, "Refresh")
  perf("sell list", P.Rules, "SellList")
  perf("make room", P.Room, "List")
  perf("window refresh", P.Window, "Refresh")
  perf("panels", P.Panels, "Refresh")
end)

function P:OpenSettings()
  if self.settingsCategory and Settings and Settings.OpenToCategory then
    Settings.OpenToCategory(self.settingsCategory:GetID())
  else
    Core:OpenSettings()
  end
end
