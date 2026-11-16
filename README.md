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

## Junk

Junk goes to a vendor unless you send it to a profession. Which of the two an item can go to depends on your character and the item.

### Selling

A **Sell Junk (N)** button appears below the bottom-right corner of the vendor window, one row under its tabs. It sells every junk item bound for the vendor and reports the total.

- An item only counts as sold once it has left your bags. Anything the vendor did not take keeps its mark and is reported.
- Items you can still return for a refund are never sold.
- There is no confirmation. Mistakes can be bought back from the vendor's buyback tab.

### Disenchanting

If your character knows an ability that uses an item up, junk it applies to can be queued for that ability instead of being sold: press Space a second time on the item. Currently that is Disenchant, for uncommon-to-epic weapons and armor. Queued junk is tinted purple with the ability's icon. Gear a vendor will not buy is queued on the first press, since nothing else can be done with it.

- A small movable panel shows the next item and how many are queued. Click the icon to process that item.
- The game requires a real click or key press for every spell cast, so the queue cannot run by itself.
- Items are processed in the order you marked them.
- Right-click the icon to send that item back to the vendor pile.
- Shift-click **Sell Junk** to sell the queued items too.
- The queue pauses during combat.

A character with no such ability sells all junk. Junk marked for the vendor stays vendor junk if the ability is learned later.

## Favorites

While a vendor window is open, a favorite cannot be right-clicked or dragged; trying shows a red error. **Sell Junk** never touches favorites.

The protection covers selling only:

- A favorite can still be disenchanted by hand, deleted, or traded.
- If the client's built-in "sell all gray items" vendor button is enabled, it could still sell a gray-quality favorite.
- `/jm clear` removes favorites along with junk marks.

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

# Remove every mark, favorites included.
/jm clear
```

## Known Limitations

- **Stacks.** Looting more into a marked stack keeps the mark. Splitting a marked stack leaves the new stack unmarked. Dragging a marked stack onto an unmarked one loses the mark; the other way round keeps it.
- **Bank.** A junk mark is dropped if the item is not in your bags when you open a vendor. Favorites are kept.
- **Disenchant's spell ID** is assumed to be `13262`. If an enchanter never sees the queue, run `/jm professions`: it lists the real IDs and warns about a mismatch.
- **English only.** There are no translations yet.

## Development

Everything is in `JunkMark.lua`. `Bindings.xml` declares the two key bindings, and `JunkMark.toc` is the manifest.

Run the logic tests from the addon folder:

```bash
lua tests/mock_test.lua JunkMark.lua
```

These run outside the game against a fake of the WoW API. A pass shows the addon's logic is self-consistent, not that it works in the client: the fake accepts any method name, and it encodes assumptions about how the real API behaves. The game runs Lua 5.1.

To add another ability that is cast on a bag item and uses it up, add an entry to the `ACTIONS` table near the top of `JunkMark.lua`: a spell ID and a rule for which items qualify.

Blizzard's own interface code for this client is mirrored in the `forever` branch of [Gethe/wow-ui-source](https://github.com/Gethe/wow-ui-source/tree/forever), and is the best reference for what the API actually does.

## Feedback & Issues

To report a bug or suggest a change, please open an issue on GitHub:
<https://github.com/CannonBowl/JunkMark/issues>

## Legal

JunkMark is released under the MIT License. Please see the [LICENSE](LICENSE) file.
