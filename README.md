# DungeonWinner

A World of Warcraft: Forever addon that pops up when a Need / Greed / Pass roll starts and shows everyone's choice and roll number in one clean list.

## Features

- Pops up automatically when group loot rolls start
- Lists every group member as pending, then fills in Need / Greed / Pass as they choose
- Shows each roll number and marks the winner
- Class-colored names, sorted with the highest Need first
- Hover an item to see its tooltip
- Keeps your last 50 rolled items between sessions
- Works in any game language (reads Blizzard's own loot text)

## Install

**WowUp:** choose *Install from URL* and paste this repository's GitHub URL.

**Manual:** download `DungeonWinner-<version>-forever.zip` from [Releases](../../releases) and extract it into:

```
World of Warcraft\_forever_\Interface\AddOns\
```

You should end up with `AddOns\DungeonWinner\DungeonWinner.toc`. Keep the folder name `DungeonWinner` so WoW can find it and keep your saved history.

## Commands

| Command | What it does |
|---|---|
| `/dungeonwinner` or `/dwin` | Open or close the window |
| `/dungeonwinner test` | Fill the window with fake rolls to check it works |
| `/dungeonwinner clear` | Clear the roll history |
| `/dungeonwinner auto` | Turn the automatic pop-up on or off |
| `/dungeonwinner debug` | Print every loot event to chat (for bug reports) |

## Reporting bugs

Open an [issue](../../issues) with what happened. If rolls aren't showing up, turn on `/dungeonwinner debug`, do a roll, and paste what it printed to chat.
