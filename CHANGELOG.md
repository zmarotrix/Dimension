# Changelog

## 0.13.0, 2026-11-06

- **A bar under the title shows how full your bags are** at a glance: green, through yellow at 60%, to red by 95%.
- **Empty always shows its slot and count.** Clicking its title could close it, leaving "+ Empty (0)". It no longer closes, and if it was closed
  it opens again. With full bags it stays and says 0.
- **Drag group titles in Edit layout** to move groups: onto another group to sit beside it, or onto the strip at the bottom for a new row. A line
  shows where it will land. This replaces the arrow buttons, so editing now draws groups at their real size.
- Dragging an item lights up the group it would land in. Dropping in a gap counts as the nearest group on that line, and dropping an item back
  on its own group changes nothing.
- A drag ends properly if the game misses the mouse being let go, and nothing rearranges under it.

## 0.12.0, 2026-11-06

- **Rename groups:** in Edit layout, click a group's title, type and press Enter. Escape cancels, and a blank name goes back to the usual one.
- **Drag items between groups** in Edit layout. It only moves a picture, so nothing can be dropped or sold by accident. Clicking an item still
  opens the menu of groups, and item tooltips now show while editing.
- Each group's area is tinted while editing, and empty groups have room to drop on.
- Reset now puts names back too.

## 0.11.7, 2026-11-06

- Fixed: Edit layout could refuse with a message about restrictions when you weren't fighting. Only combat stops it now.

## 0.11.6, 2026-11-06

- Fixed: selling, bank trips, Tidy and merging could all stop with "the game has add-ons restricted" while you weren't in a fight. Only
  combat, encounters, keystones and PvP matches stop them now. A map or chat restriction doesn't.
- The vendor panel's button now reads "Confirm and sell 3 for 24s 15c", so you can check the list and the total first.

## 0.11.5, 2026-11-06

- What sells at the next vendor now shows the game's gold coin rather than a yellow dot, and its icon is greyed, in the bag window and on the game's
  own bags. The small marks setting turns off both.

## 0.11.4, 2026-11-06

- The bag window shows your money with the game's coin icons, as its own bags do.

## 0.11.3, 2026-11-06

- Fixed: the bag window's footer buttons were too narrow for their text. They now size themselves to it.
- Your money is larger, bolder and brighter in the bag window, and brighter wherever else Dimension shows it.

## 0.11.2, 2026-11-06

- **A more compact bag window:** 14 slots across at 32 pixels each, tighter gaps, a smaller head and foot, and the search moved into the
  head. Slots keep all their art because they're scaled, not resized.
- **Shorter group names,** which were setting how wide small groups were: To sell, Quests, Everyday, Professions, Trade goods, Other.
- Empty now sits on the same row as Gear and Other by default, if there's room.

## 0.11.1, 2026-11-06

- **Other add-ons' marks:** the bag window now tells them when it fills a slot, so Clairvoyance's quest
  item mark shows there as it does on the game's bags.

## 0.11.0, 2026-11-06

- **The bag window is now rows of small groups** rather than one long column: Sells next vendor, For your quests, Always with you,
  Keepsakes, Food & drink, Potions, Consumables, Your professions use, Recipes, Other trade goods, Gear, Everything else and Empty.
- **Edit layout:** arrows move a group, and clicking an item chooses its group. Reset puts everything back.

## 0.10.2, 2026-11-06

- If the game blocks anything of Dimension's in combat, or locks its bag buttons, fights use the game's own bags from then on,
  and the window comes back when combat ends. A setting turns this on or off by hand.
- The window now keeps updating in combat, so new loot shows straight away. It only holds still under the mouse.

## 0.10.1, 2026-11-06

- Fixed: the bag window was empty if the first time you opened it was in combat. It's now laid out at login and ahead of each
  fight, and opening always shows your items. If the game does lock its bag buttons in combat, its own bags open instead of an empty window.
- Section titles and the search now work in combat.

## 0.10.0, 2026-11-06

- **A bag window grouped by what things are for,** instead of the game's bags: Sells at the next vendor, For your quests, Your
  professions use, Always with you, Consumables, Gear, Recipes, Other trade goods and Everything else. Nothing physically moves.
  Sections collapse, a search dims what doesn't match, and `/dim bags` or a setting goes back to the game's bags.

## 0.9.0, 2026-11-06

First build. It passes its harness but hasn't been played in the game yet.

- **Keep rules:** one verdict and one reason for every item, on its tooltip. Protections come first, so a
  selling rule can't reach a quest item, a quest reward, a rare or a recipe. Junk and Keep marks by key.
- **At a vendor:** sells what the rules allow, repairs, and buys from the carry list if that's on and within a
  cap. A visit stays inside the 12 stacks of buyback, cheapest first, with an undo for each sale.
- **Make room:** merges stacks and puts things in the bag made for them, then the cheapest things to clear.
  Destroying is off until opted in, and it's one click per stack, which is all the client allows.
- **At the bank:** a carry list and a stash list, run both ways. Pinned slots never move.
- **Places:** pin items to slots, set what each bag is for with the game's own filters, and tidy with the
  game's own sort.
- **History:** everything it did, kept for 30 days.
- **First run:** Just show me, Standard or Hands free. Nothing is automatic until you choose.
- `/dim probe` tests what the client really allows.
