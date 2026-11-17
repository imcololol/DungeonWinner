# DungeonWinner

A World of Warcraft: Forever addon that pops up when a Need / Greed / Pass roll starts and shows everyone's choice and roll number in one clean list.

## Features

- Pops up automatically when group loot rolls start
- Lists every group member as pending, then fills in Need / Greed / Pass as they choose
- Shows each roll number and marks the winner
- Class-colored names, sorted with the highest Need first
- Hover an item to see its tooltip
- Keeps your last 300 rolled items between sessions
- Works in any game language (reads Blizzard's own loot text)
- When anyone rolls a 67, everyone with DungeonWinner announces it to the group
- Minimap button: left-click for the leaderboard, right-click for settings, shift-left-click for test rolls
- Settings: active everywhere or only in dungeons/raids (default), show first names only, use Auctionator prices instead of vendor prices, 5 window themes
- **Leaderboard:** ranks your group by the total value of loot won on **Greed** rolls during the current dungeon run (Need wins don't count). Uses vendor prices, or Auctionator prices if you turn that on.

## Install

**WowUp:** choose *Install from URL* and paste this repository's GitHub URL.

**Manual:** download `DungeonWinner-<version>-forever.zip` from [Releases](../../releases) and extract it into:

```
World of Warcraft\_forever_\Interface\AddOns\
```

You should end up with `AddOns\DungeonWinner\DungeonWinner.toc`. Keep the folder name `DungeonWinner` so WoW can find it and keep your saved history.

## How the leaderboard works

- Tracking starts when you enter a dungeon. Each dungeon run gets its own leaderboard.
- Only items won with a **Greed** roll count. Need wins, raids and loot outside dungeons don't.
- Leaving and coming back to the same dungeon within 15 minutes continues the same run. A different dungeon, or a longer break, starts a new one.
- Want to track somewhere else (open-world farming, a raid)? Click **Start run** at the top of the leaderboard, or type `/dw start` (optionally with a name, like `/dw start ZG farm`). It tracks Greed wins anywhere until you click **End run** or type `/dw stop`.
- Click **Reset** at the top of the leaderboard (then again to confirm) to start over.

## Commands

| Command | What it does |
|---|---|
| `/dw` (or `/dungeonwinner`) | Open or close the window |
| `/dw board` | Open the leaderboard |
| `/dw start [name]` | Start a leaderboard run manually |
| `/dw stop` | End a manual run |
| `/dw settings` | Open the settings (also in Esc > Options > AddOns > DungeonWinner) |
| `/dw minimap` | Show or hide the minimap button |
| `/dw test` | Show sample rolls, handy for sizing and placing the window |
| `/dw clear` | Clear the roll list (same as the Clear button; leaderboard scores are kept) |
| `/dw auto` | Turn the automatic pop-up on or off |

## Reporting bugs

Open an [issue](../../issues) with what happened, and include a screenshot of the window and your chat if you can.
