-- The keep rules: one verdict and one reason for every item, shared by everything else. Selling, Make
-- room and tooltips all ask here, so they can't disagree.
--
-- The order is the safety. What must never be sold is tested first and returns before any rule that
-- could sell is reached, so turning a selling rule on can't reach a quest item, whatever else is on.
-- Unknown never counts as safe: an item the client hasn't cached has no price yet, so it stays.

local Core = NorgannonCore
local D = Dimension
if D.disabled then return end

local Rules = {}
D.Rules = Rules

local RARE = 3      -- Enum.ItemQuality.Rare
local POOR = 0
local CLASS_WEAPON, CLASS_TRADE, CLASS_ARMOR, CLASS_RECIPE, CLASS_QUEST = 2, 7, 4, 9, 12
Rules.CLASS_QUEST = CLASS_QUEST

local HEARTHSTONE = 6948
-- gathering and crafting tools: cheap, soulbound-looking, and a nuisance to lose
local TOOLS = {
  [7005] = "Skinning Knife", [12709] = "Finkle's Skinner", [2901] = "Mining Pick", [5956] = "Blacksmith Hammer",
  [6219] = "Arclight Spanner", [6218] = "Runed Copper Rod", [6339] = "Runed Silver Rod", [11130] = "Runed Golden Rod",
  [11145] = "Runed Truesilver Rod", [16207] = "Runed Arcanite Rod", [6256] = "Fishing Pole", [6365] = "Strong Fishing Pole",
  [6367] = "Big Iron Fishing Pole", [12225] = "Blump Family Fishing Pole", [19022] = "Nat Pagle's Extreme Angler FC-5000", [19970] = "Arcanite Fishing Pole",
}

-- what each class can ever equip, by Enum.ItemArmorSubclass and Enum.ItemWeaponSubclass. A subclass
-- not named anywhere (miscellaneous, generic, cosmetic) is never called unusable, nor is any class
-- this table doesn't know: being wrong here must only mean keeping something
local ARMOR = { CLOTH = 1, LEATHER = 2, MAIL = 3, PLATE = 4, SHIELD = 6, LIBRAM = 7, IDOL = 8, TOTEM = 9 }
local WEAPON = { AXE1 = 0, AXE2 = 1, BOW = 2, GUN = 3, MACE1 = 4, MACE2 = 5, POLEARM = 6, SWORD1 = 7, SWORD2 = 8, STAFF = 10, FIST = 13, DAGGER = 15, THROWN = 16, CROSSBOW = 18, WAND = 19 }
local function set(...)
  local out = {}
  for _, v in ipairs({ ... }) do out[v] = true end
  return out
end
local CAN_USE = {
  WARRIOR = { armor = set(ARMOR.CLOTH, ARMOR.LEATHER, ARMOR.MAIL, ARMOR.PLATE, ARMOR.SHIELD), weapon = set(WEAPON.AXE1, WEAPON.AXE2, WEAPON.BOW, WEAPON.GUN, WEAPON.MACE1, WEAPON.MACE2, WEAPON.POLEARM, WEAPON.SWORD1, WEAPON.SWORD2, WEAPON.STAFF, WEAPON.FIST, WEAPON.DAGGER, WEAPON.THROWN, WEAPON.CROSSBOW) },
  PALADIN = { armor = set(ARMOR.CLOTH, ARMOR.LEATHER, ARMOR.MAIL, ARMOR.PLATE, ARMOR.SHIELD, ARMOR.LIBRAM), weapon = set(WEAPON.AXE1, WEAPON.AXE2, WEAPON.MACE1, WEAPON.MACE2, WEAPON.POLEARM, WEAPON.SWORD1, WEAPON.SWORD2) },
  HUNTER = { armor = set(ARMOR.CLOTH, ARMOR.LEATHER, ARMOR.MAIL), weapon = set(WEAPON.AXE1, WEAPON.AXE2, WEAPON.BOW, WEAPON.GUN, WEAPON.POLEARM, WEAPON.SWORD1, WEAPON.SWORD2, WEAPON.STAFF, WEAPON.FIST, WEAPON.DAGGER, WEAPON.THROWN, WEAPON.CROSSBOW) },
  ROGUE = { armor = set(ARMOR.CLOTH, ARMOR.LEATHER), weapon = set(WEAPON.AXE1, WEAPON.BOW, WEAPON.GUN, WEAPON.MACE1, WEAPON.SWORD1, WEAPON.FIST, WEAPON.DAGGER, WEAPON.THROWN, WEAPON.CROSSBOW) },
  PRIEST = { armor = set(ARMOR.CLOTH), weapon = set(WEAPON.MACE1, WEAPON.STAFF, WEAPON.DAGGER, WEAPON.WAND) },
  SHAMAN = { armor = set(ARMOR.CLOTH, ARMOR.LEATHER, ARMOR.MAIL, ARMOR.SHIELD, ARMOR.TOTEM), weapon = set(WEAPON.AXE1, WEAPON.AXE2, WEAPON.MACE1, WEAPON.MACE2, WEAPON.STAFF, WEAPON.FIST, WEAPON.DAGGER) },
  MAGE = { armor = set(ARMOR.CLOTH), weapon = set(WEAPON.SWORD1, WEAPON.STAFF, WEAPON.DAGGER, WEAPON.WAND) },
  WARLOCK = { armor = set(ARMOR.CLOTH), weapon = set(WEAPON.SWORD1, WEAPON.STAFF, WEAPON.DAGGER, WEAPON.WAND) },
  DRUID = { armor = set(ARMOR.CLOTH, ARMOR.LEATHER, ARMOR.IDOL), weapon = set(WEAPON.MACE1, WEAPON.MACE2, WEAPON.POLEARM, WEAPON.STAFF, WEAPON.FIST, WEAPON.DAGGER) },
}
local MAPPED_ARMOR, MAPPED_WEAPON = {}, {}
for _, v in pairs(ARMOR) do MAPPED_ARMOR[v] = true end
for _, v in pairs(WEAPON) do MAPPED_WEAPON[v] = true end

---What the client says about an item: { quality, price, stack, class, subclass, name, reagent }, with
---`price` nil until the client has cached it.
function Rules.Facts(id)
  local name, _, quality, _, _, _, _, stack, _, icon, price, class, subclass, _, _, _, reagent = D.In("C_Item", "GetItemInfo", id)
  if class == nil then
    local _, _, _, _, instantIcon, instantClass, instantSub = D.In("C_Item", "GetItemInfoInstant", id)
    class, subclass, icon = instantClass, instantSub, icon or instantIcon
  end
  return { name = name, quality = quality, stack = stack, icon = icon, price = price, class = class, subclass = subclass, reagent = reagent }
end

---True if this class can never equip the gear. False when unsure.
function Rules.CantEverUse(facts)
  local _, token = D.Global("UnitClass", "player")
  local can = CAN_USE[token]
  if not can or facts.subclass == nil then return false end
  if facts.class == CLASS_ARMOR then return MAPPED_ARMOR[facts.subclass] and not can.armor[facts.subclass] end
  if facts.class == CLASS_WEAPON then return MAPPED_WEAPON[facts.subclass] and not can.weapon[facts.subclass] end
  return false
end

---The first quest in the log that wants this item, or nil.
local function wantedByQuest(dbInfo)
  if not (dbInfo and Core.Player and dbInfo.objective) then return nil end
  for _, questId in ipairs(dbInfo.objective) do
    if Core.Player:HasQuest(questId) then return questId end
  end
end

function Rules.QuestWants(id)
  return wantedByQuest(Core.DB:ItemInfo(id)) ~= nil
end

local function questName(questId)
  return Core.DB:Name("quests", questId) or ("quest " .. tostring(questId))
end

---The name of a profession of ours that has a recipe using this item, or nil.
local function ourProfessionUses(id)
  local recipes = Core.DB:ReagentOf(id)
  for _, spellId in ipairs(recipes or {}) do
    local recipe = Core.DB:Recipe(spellId)
    if recipe and Core.Player:GetSkill(recipe.skill) then
      return NorgannonDB:L("professions", recipe.skill, "name") or "One of your professions"
    end
  end
end

---A character of ours in Retrospect whose profession has a recipe using this item: name, or nil.
---Retrospect only ever reads here, and only if it's installed.
local function anotherCharacterUses(id)
  local R = rawget(_G, "Retrospect")
  if not (R and not R.disabled and R.Store and R.Store.List and R.db) then return nil end
  local recipes = Core.DB:ReagentOf(id)
  if not recipes or #recipes == 0 then return nil end
  local mine = R.Store.MyKey and R.Store:MyKey()
  for _, entry in ipairs(R.Store:List()) do
    if entry.key ~= mine then
      local skills = entry.c.professions and entry.c.professions.skills
      if skills then
        for _, spellId in ipairs(recipes) do
          local recipe = Core.DB:Recipe(spellId)
          if recipe and skills[recipe.skill] then return tostring(entry.c.name) end
        end
      end
    end
  end
end

---True if a profession here, or with the rule on another character's, uses this item.
function Rules.ProfessionUses(id)
  if ourProfessionUses(id) then return true end
  return D.db.rules.altKeep and anotherCharacterUses(id) ~= nil
end

---A soulbound or grey quest reward that isn't gear or a consumable: something kept for what it is.
function Rules.IsKeepsake(id, bound)
  local info = Core.DB:ItemInfo(id)
  if not (info and info.rewardOf and info.rewardOf[1]) then return false end
  local facts = Rules.Facts(id)
  if not (bound or facts.quality == POOR) then return false end
  return Core.Bags.Kind(id, 1) == "other"
end

---"food", "potion" or "other" for a consumable. The client's subclasses and older data number these differently,
---so it goes by what the item does and is called too. Being wrong only means landing in Consumables, and
---Edit layout can fix any one item.
function Rules.ConsumableKind(id, facts, name)
  local spell = D.In("C_Item", "GetItemSpell", id) or D.Global("GetItemSpell", id)
  if type(spell) == "string" and (spell:find("Food") or spell:find("Drink") or spell:find("Refreshment")) then return "food" end
  if facts.subclass == 1 or facts.subclass == 2 or facts.subclass == 3 then return "potion" end
  local text = name or facts.name or ""
  if text:find("Potion") or text:find("Elixir") or text:find("Flask") then return "potion" end
  return "other"
end

---The hearthstone and profession tools: what every trip needs.
function Rules.IsEveryday(id)
  return id == HEARTHSTONE or TOOLS[id] ~= nil
end

---Whether the character lists this item to carry or to stash.
function Rules.OnALists(id, me, kind)
  for _, c in ipairs(me.carry) do
    if c.id == id then return "On your carry list" end
  end
  if me.stash[id] then return "On your stash list" end
  if kind and me.stashKinds[kind] then return "Your stash list takes these" end
end

---The checks that return "keep" whatever else is on, given what the slot says (info may be nil).
local function hardKeep(id, facts, info, bag, slot, me)
  if id == HEARTHSTONE then return "Your hearthstone" end
  if bag and me.pins[bag .. ":" .. slot] == id then return "Pinned to this slot" end
  if D.db.itemMarks[id] == "keep" then return "You marked this Keep" end
  if TOOLS[id] then return "A profession tool" end
  local listed = Rules.OnALists(id, me, Core.Bags.Kind(id, facts.quality))
  if listed then return listed end
  if facts.class == CLASS_QUEST then return "Quest item" end
  if bag then
    local quest = D.In("C_Container", "GetContainerItemQuestInfo", bag, slot)
    if type(quest) == "table" and (quest.isQuestItem or quest.questID) then return "Quest item" end
  end
  local dbInfo = Core.DB:ItemInfo(id)
  local wanted = wantedByQuest(dbInfo)
  if wanted then return "Wanted by " .. questName(wanted) end
  if dbInfo and dbInfo.startQuest then return "Starts " .. questName(dbInfo.startQuest) end
  local bound = info and info.isBound
  if dbInfo and dbInfo.rewardOf and dbInfo.rewardOf[1] and (bound or facts.quality == POOR) then
    return "Reward from " .. questName(dbInfo.rewardOf[1])
  end
  if facts.class == CLASS_RECIPE then return "A recipe" end
  if facts.quality and facts.quality >= RARE then return "Rare or better" end
  if bag then
    local inSet = D.In("C_Container", "GetContainerItemEquipmentSetInfo", bag, slot)
    if inSet then return "In an equipment set" end
    local purchase = D.In("C_Container", "GetContainerItemPurchaseInfo", bag, slot, false)
    if type(purchase) == "table" and (purchase.refundSeconds or 0) > 0 then return "Still refundable" end
    if D.In("C_Container", "IsBattlePayItem", bag, slot) then return "Bought from the shop" end
  end
  return nil
end

---verdict, why: "sell" (at the next vendor), "keep" (protected) or "stay" (nothing applies).
---bag, slot and info are what's known about the copy in hand; without them only the item is judged.
function Rules:Verdict(id, info, bag, slot)
  local me = D:Me()
  local facts = Rules.Facts(id)
  local quality = (info and info.quality) or facts.quality
  facts.quality = quality

  local keep = hardKeep(id, facts, info, bag, slot, me)
  if keep then return "keep", keep end

  if info and info.hasNoValue then return "stay", "No vendor value, so it can't be sold" end
  if facts.price == nil then return "stay", "The game hasn't said what this sells for yet" end
  if facts.price <= 0 then return "stay", "No vendor value, so it can't be sold" end

  local rules = D.db.rules
  -- your own mark beats the recipe rules below it, but never the protections above
  if D.db.itemMarks[id] == "junk" then
    if rules.marked then return "sell", "You marked this Junk" end
    return "stay", "Marked Junk, but selling marks is switched off"
  end
  local used = ourProfessionUses(id)
  if used then return "keep", used .. " uses this" end
  if rules.altKeep then
    local alt = anotherCharacterUses(id)
    if alt then return "keep", alt .. "'s profession uses this" end
  end
  if quality == POOR and rules.grey then return "sell", "Grey" end
  if rules.cantUse and info and info.isBound and Rules.CantEverUse(facts) then return "sell", "Soulbound gear you can't use" end
  if rules.noRecipe and facts.class == CLASS_TRADE and quality and quality <= 1 then return "sell", "No recipe of yours uses this" end
  return "stay", "No rule applies, so it stays"
end

---Everything that would sell now, cheapest first, so the dearest stays in buyback longest:
---{ { bag, slot, id, count, value, why, link } }. Locked items wait for the next look.
function Rules:SellList()
  local out = {}
  D.Each(D.Carried(), function(bag, slot, info)
    local verdict, why = self:Verdict(info.itemID, info, bag, slot)
    if verdict == "sell" and not info.isLocked then
      local price = Rules.Facts(info.itemID).price or 0
      out[#out + 1] = { bag = bag, slot = slot, id = info.itemID, count = info.stackCount or 1, value = price * (info.stackCount or 1), why = why, link = info.hyperlink, name = info.itemName }
    end
  end)
  table.sort(out, function(a, b)
    if a.value ~= b.value then return a.value < b.value end
    if a.bag ~= b.bag then return a.bag < b.bag end
    return a.slot < b.slot
  end)
  return out
end

---Cycles an item's mark: none, Junk, Keep, none.
function Rules:CycleMark(id)
  local marks = D.db.itemMarks
  if marks[id] == "junk" then
    marks[id] = "keep"
  elseif marks[id] == "keep" then
    marks[id] = nil
  else
    marks[id] = "junk"
  end
  D:Changed()
  return marks[id]
end
