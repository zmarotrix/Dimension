# Changelog

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
