# Changelog

## 1.0.0

First public release, for World of Warcraft: Forever (Interface 16001).

### Marking

- Hover a bag item and press Space to mark it: junk, then favorite, then none. Space only does this while the cursor is on a bag item, and never in combat; everywhere else it still jumps. A key of your own can be bound under Options > Keybindings > AddOns.
- Marks belong to the individual item, so marking one of two identical swords leaves the other alone. They follow items when bags are sorted and are saved per character.
- `/jm mode auto` makes gray items a vendor buys junk without marking them, with a per-item "not junk" step to keep one. Manual marking is the default.
- Marks are drawn in the default bags and in other bag addons' windows, including Baganator, Bagnon, BetterBags, ElvUI and EllesmereUI Bags. `/jm corner` moves the mark icon to another corner of the item.

### Junk

- The vendor window's Sell All Junk button sells what JunkMark marks as junk, and never a favorite or an item set to not junk. A client without that button gets a Sell Junk button of JunkMark's own. `/jm auto` sells when a vendor opens.
- Refundable items are never sold, and a sale only counts once the item has left your bags.
- Junk your character can disenchant can be queued instead: a small panel processes one item per click or key press. When the game refuses an item outright, JunkMark learns that and stops offering it.
- Baganator follows JunkMark as its junk source, so its junk category, `junk` search and sort order use JunkMark's marks, with one coin instead of two.

### Favorites

- A favorite cannot be sold by hand while a vendor is open.
- Favorites are kept out of the junk selling of Scrap, BetterBags, SellJunk, RestedXP and EllesmereUI, and out of EnhanceQoL's selling by rules and its deleting. JunkMark warns in chat about sellers it cannot stop, such as Leatrix Plus, Peddler, Dejunk, Vendor and EnhanceQoL's "Automatically sell all junk items".

### Commands

`/jm` lists them all, among them `/jm list`, `/jm check` (how JunkMark is working with your other addons) and `/jm debug` (details for a bug report).
