# JunkMark

JunkMark is an addon for World of Warcraft: Forever that marks bag items the way Diablo 4 does: hover an item and press Space to mark it as junk, press again to make it a favorite. Junk is sold or disenchanted in bulk, and favorites cannot be sold.

> **Status: untested in the game.** JunkMark has only been run against a hand-written fake of the WoW API (see [Development](#development)). Expect rough edges on first load.

## Features

- Mark any bag item with one key while hovering it: junk, favorite, or none
- Marks belong to the individual item, so marking one of two identical swords leaves the other alone
- Sell all junk at a vendor with one click, or automatically when a vendor opens
- Junk your character can disenchant can be queued for disenchanting instead, one item per click or key press
- Favorites are blocked from being sold while a vendor is open
- Overlay icons in your bags show what each marked item is and where it is headed
- Refundable items are never sold, and a sale only counts once the item has left your bags
- Marks follow items when bags are sorted, and are saved per character
- Keeps favorites out of the junk selling of Scrap, BetterBags, SellJunk, EllesmereUI and RestedXP, and warns about sellers it cannot stop

## Getting Started

Copy or clone this folder into the Forever client's AddOns directory. The folder must be named `JunkMark`:

```
World of Warcraft/_forever_/Interface/AddOns/JunkMark/
```

Restart the game, or `/reload` if you are already logged in, and check that JunkMark appears in the AddOns list on the character screen. JunkMark targets Interface `16001` (Forever 1.60.1).

Then open your bags, hover an item, and press **Space**. Nothing is sold or disenchanted until you click for it.

## Marking Items

Hover an item in your bags and press **Space**:

| Press | Mark | Shown as |
| --- | --- | --- |
| 1st | Junk | Dimmed, with a coin (or a profession icon, see below) |
| 2nd | Favorite | Star |
| 3rd | None | |

- Space is only taken over while the cursor is on a bag item. Everywhere else it still jumps.
- It does not work during combat, because the game does not let addons change key bindings in combat.
- An item that can be neither sold nor used by a profession skips junk and goes straight to favorite.
- An item your character can disenchant **and** a vendor will buy has two junk steps: the first press makes it vendor junk (coin), the second queues it for disenchanting instead (purple, with the ability's icon), and the third makes it a favorite.

### Other bag addons

Marking also works in bag addons that draw their own bag window, such as Bagnon, Baganator and EllesmereUIBags. JunkMark has no code specific to any of them: it recognises item buttons built from the game's own bag-button template, which these addons use.

- JunkMark notices such a window the first time your cursor rests on one of its items, and remembers it. That first hover is needed once per character; after that the window's marks show as soon as it opens, including after a login or `/reload`.
- ElvUI, EllesmereUI Bags, BetterBags and Bagnon need no first hover: their bag window, or their item buttons, have fixed names that JunkMark looks for. (Added in 0.7.0 by reading their code; not yet seen in the game.)
- A bag addon reuses its buttons for different slots when it sorts or filters. JunkMark redraws a mark in the same frame the addon gives the button its new item's icon, so a mark does not sit on the wrong item while the bags rearrange. (Also 0.7.0, and also not yet seen in the game. Before that it was checked a few times a second.)
- While Bagnon shows another character's bags, no marks are drawn in its window.
- Only bag slots can be marked, not bank slots.
- Bag addons put things of their own in the corners of an item (Baganator and EllesmereUIBags write the item level top-left). The mark icon sits bottom-right by default, under the stack count; if that corner is taken in your layout, move it with `/jm corner`.

## Junk

Junk goes to a vendor unless you send it to a profession. Which of the two an item can go to depends on your character and the item.

### Selling

A **Sell Junk (N)** button hangs under the bottom-right corner of the vendor window, in the same row as its tabs. It narrows to fit beside a tab another addon adds, and only drops to a row of its own when there is no room at all. It sells every junk item bound for the vendor and reports the total.

- An item only counts as sold once it has left your bags. Anything the vendor did not take keeps its mark and is reported.
- Items you can still return for a refund are never sold.
- There is no confirmation. Mistakes can be bought back from the vendor's buyback tab.

### Disenchanting

If your character knows an ability that uses an item up, junk it applies to can be queued for that ability instead of being sold: press Space a second time on the item. Currently that is Disenchant, for uncommon-to-epic weapons and armor, except items whose tooltip says they cannot be disenchanted. Queued junk is tinted purple with the ability's icon. Gear a vendor will not buy is queued on the first press, since nothing else can be done with it.

- A small movable panel shows the next item and how many are queued. Click the icon, with either mouse button, to process that item.
- The game requires a real click or key press for every spell cast, so the queue cannot run by itself.
- Items are processed in the order you marked them.
- Shift-right-click the icon to send that item back to the vendor pile instead.
- Shift-click **Sell Junk** to sell the queued items too.
- The queue pauses during combat.
- Some gear cannot be disenchanted and the game does not say so until you try. When the game refuses a queued item outright, JunkMark removes its mark, tells you, and stops offering to disenchant that kind of item.

A character with no such ability sells all junk. Junk marked for the vendor stays vendor junk if the ability is learned later.

## Favorites

While a vendor window is open, a favorite cannot be right-clicked or dragged; trying shows a red error. **Sell Junk** never touches favorites.

The protection covers selling only:

- A favorite can still be disenchanted by hand, deleted, or traded.
- If the client's built-in "sell all gray items" vendor button is enabled, it could still sell a gray-quality favorite. JunkMark leaves that button alone.
- Another addon that sells junk may not know about favorites. See below.
- `/jm clear` removes favorites along with junk marks.

### Other addons that sell junk

Other junk addons decide what is junk by item type, so they cannot tell a favorite from another copy of the same item. Run `/jm check` to see which of them JunkMark found on your character and what it did about each.

> Added in 0.7.0 by reading each addon's code at the version named. None of it has been run in the game.

| Addon | Version read | What JunkMark does |
| --- | --- | --- |
| Scrap | 12.1.10 | Guarded: it never sells or destroys a favorite |
| BetterBags (its own selling) | development, 2026-11-18 | Guarded: it never sells a favorite |
| SellJunk | Beast-Masters copy, 2026-11-08 | Guarded: by slot where that version allows, otherwise for every copy of a favorited item |
| RestedXP inventory manager (auto-sell, delete when bags are full) | 4.11.36 | Guarded: it never treats a favorite as junk |
| EllesmereUI junk marker (Sell Junk, and Auto Sell Junk while the Junk Icon is on) | 9.8.9 | Guarded: no copy of an item is junk to it while one copy in your bags is a favorite |
| Dejunk | 3.5.1 | Cannot be stopped; asked about each new favorite, and warns if it counts it as junk |
| Vendor | 6.14.0 | Cannot be stopped; asked about each new favorite, and warns if it would sell it |
| Peddler | Cartas's copy, 2026-11-09 | Cannot be stopped; warns about gray favorites |
| EllesmereUI Auto Sell Junk with the Bags Junk Icon off | 9.8.9 | Cannot be stopped; warns about gray favorites |
| Leatrix Plus "Sell junk automatically" | 1.60.32 | Cannot be stopped; warns about gray favorites |

- A guard changes only what the other addon is told about favorites. Nothing is written to its settings, and JunkMark's junk marks are not passed to it.
- Dejunk and Vendor keep their selling private, so JunkMark cannot stop them. It can ask them, so it tells you when a favorite needs adding to their own keep lists, and `/jm check` counts such favorites.
- The gray sellers only take gray items, so only a gray favorite is at risk. JunkMark warns once per session, per seller, when you make a gray item a favorite while one is active.
- EllesmereUI's Junk Items window can still list a gray favorite. It deletes only on your Ctrl-click.
- A junk seller not in this table is not known to JunkMark at all.

### Baganator's junk source

JunkMark offers itself to Baganator as its source of what is junk: marked junk, plus unmarked gray items with a vendor price, and never a favorite. Baganator's junk coin, its `junk` search word and its junk category then follow JunkMark. You can pick another source under Baganator's Plugins settings.

## Keybindings

Two bindings are listed under Options > Keybindings > AddOns:

- **Cycle mark on hovered item** sets a key of your own for marking. Space keeps working alongside it.
- **Process next queued item** disenchants the next item in the queue, so you can work through it with one key.

## Chat Commands

`/junkmark` works in place of `/jm`.

```bash
# Display a list of commands.
/jm

# List the marked items in your bags.
/jm list

# Sell junk. Requires an open vendor.
/jm sell

# Sell junk, including items queued for a profession.
/jm sell all

# Toggle selling automatically when a vendor opens. Off by default.
/jm auto

# Show your professions, their abilities, and how junk is routed.
/jm professions

# Show which corner of an item the mark icon sits in, or set it:
# topleft, topright, bottomleft, bottomright. Bottom right by default.
/jm corner
/jm corner topright

# Forget which items the game refused to disenchant, so they can be queued again.
/jm forget

# Show which bag windows JunkMark is following, which other junk sellers it found,
# and what it did about each.
/jm check

# Write what the game reports about each junk-marked item into the saved data,
# to attach to a bug report. It is on disk after a /reload.
/jm debug

# Remove every mark, favorites included.
/jm clear
```

## Known Limitations

- **Stacks.** Looting more into a marked stack keeps the mark. Splitting a marked stack leaves the new stack unmarked. Dragging a marked stack onto an unmarked one loses the mark; the other way round keeps it.
- **Bank.** A junk mark is dropped if the item is not in your bags when you open a vendor. Favorites are kept, wherever the item is. A favorite mark is only removed for an item you no longer have at all, and that is checked when you open your bank, the one time everything you hold can be seen.
- **Disenchant's spell ID** is assumed to be `13262`. If an enchanter never sees the queue, run `/jm professions`: it lists the real IDs and warns about a mismatch.
- **English only.** There are no translations yet.

## Development

`JunkMark.lua` holds the addon itself. `OtherAddons.lua` holds the guards and warnings for other junk sellers and the Baganator junk source. `Bindings.xml` declares the two key bindings, and `JunkMark.toc` is the manifest.

Run the logic tests from the addon folder:

```bash
lua tests/mock_test.lua
```

The tests load the files `JunkMark.toc` lists. They run outside the game against a fake of the WoW API, and of the few calls JunkMark makes into other addons. A pass shows the addon's logic is self-consistent, not that it works in the client: the fake accepts any method name, and it encodes assumptions about how the real API and the other addons behave. The game runs Lua 5.1.

To guard another junk seller, add a function to `OtherAddons.lua` that wraps the one function that addon asks before selling an item.

### For other addons

JunkMark exposes a small global table, `JunkMarkAPI` (`version = 1`). Bags and slots are the game's own numbers.

| Call | Returns |
| --- | --- |
| `JunkMarkAPI.GetMark(bag, slot)` | `"junk"`, `"favorite"`, or `nil` |
| `JunkMarkAPI.IsJunk(bag, slot)` | boolean |
| `JunkMarkAPI.IsFavorite(bag, slot)` | boolean |
| `JunkMarkAPI.IsItemFavorite(itemID)` | whether any copy in the bags is a favorite |
| `JunkMarkAPI.OnChanged(func)` | nothing; `func` is called whenever a mark changes |

To add another ability that is cast on a bag item and uses it up, add an entry to the `ACTIONS` table near the top of `JunkMark.lua`: a spell ID and a rule for which items qualify.

Blizzard's own interface code for this client is mirrored in the `forever` branch of [Gethe/wow-ui-source](https://github.com/Gethe/wow-ui-source/tree/forever), and is the best reference for what the API actually does.

## Feedback & Issues

To report a bug or suggest a change, please open an issue on GitHub:
<https://github.com/CannonBowl/JunkMark/issues>

## Legal

JunkMark is released under the MIT License. Please see the [LICENSE](LICENSE) file.
