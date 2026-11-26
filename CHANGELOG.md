# Changelog

## v0.15.0

- Killing a dungeon's final boss ends the run, a few minutes later once the loot has been rolled, so the boss's loot still counts.
- Walking into a dungeon ends a manual run and starts a dungeon run.
- `/dw where` also shows the instance's final boss.
- The "Click to view another run" hint now shows above the box and disappears when you click.

## v0.14.0

- Runs follow your group: if you join a mostly different group, the old run ends (and a new one starts if you're in a dungeon) instead of adding the new players to it. A replacement joining keeps the same run. Battleground and arena groups don't count as a group change.
- Dungeon runs now end 15 minutes after you leave the dungeon (the leaderboard shows "left the dungeon, ends in Xm" until then). Coming back sooner continues the same run.
- Logging out inside a dungeon and coming back later ends that run instead of leaving it open.
- Starting a new run always closes the previous one.

## v0.13.0

- Blackrock Spire: UBRS (a 10-player instance) and LBRS now start a dungeon run like any other dungeon. Only 20/40-player raids are treated as raids.
- Smoother with lots of loot: the window redraws at most ~10 times a second, and the Rolls tab shows the newest 60 items.
- Fix: the run list on the Leaderboard tab showed on top of other windows (like quest dialogs). It now sits with the DungeonWinner window and closes when you click elsewhere.
- Clicking the DungeonWinner window brings it in front of other windows.

## v0.12.0

- Fix: after logging back in, players from earlier runs could show twice on the leaderboard ("Meddle" and "Meddle Floyd"). DungeonWinner now remembers full names and merges them, even when you're solo.

## v0.11.0

- Rolls saved with only a first name now show the group member's full name, and your own last name is picked up after login.

## v0.10.0

- Fix: last names were missing for group members. DungeonWinner now joins Forever's first and last names, and prefers the full name when chat shows it.

## v0.1.9

- Fix: names were cut to first names even with "Only show first names" off.
- New setting: Collapse rolls when finished (on by default). Folds an item's roll list as soon as someone wins it; the winner still shows on the item.

## v0.1.8

- New setting: Open when entering a dungeon (on by default). Shows the leaderboard when a new dungeon run starts.

## v0.1.7

- New versions now go to CurseForge automatically when they're released on GitHub.
- The addon now includes its CurseForge project ID, so addon managers can match it to the CurseForge page.

## v0.1.6

- Runs now stay in the run list until you log out, even through /reload.
- Reset closes the current run (it stays in the list) and starts a fresh board, instead of removing it.
- Fix: stacks (like 193 arrows) were valued as a single item. The leaderboard now counts the whole stack, and the item shows its stack size (x193).
- Share button at the bottom of the Leaderboard tab posts the top 5 for the run you're viewing to group chat.
- Leaderboard run picker: click the run name at the top of the Leaderboard tab to switch between every run from this play session. New runs open automatically.
- Fix: dungeon runs didn't start automatically in some dungeons (like Uldaman). Dungeon detection is more forgiving and re-checks a few seconds after you zone in.
- `/dw where` shows what the game reports about your current zone (handy for bug reports).

## v0.1.5

- The loot-roll dice icon now shows next to DungeonWinner in the game's AddOns list.

## v0.1.4

- Clear button at the top of the Rolls tab (click twice to confirm). It clears the roll list without changing any leaderboard scores; rolls still in progress stay. `/dw clear` works the same way.

## v0.1.3

- 67 announcements now trigger when anyone in the group rolls a 67, and everyone with DungeonWinner announces it.

## v0.1.2

- Start a leaderboard run manually with the Start run button (top of the Leaderboard tab) or `/dw start [name]`, and end it with End run or `/dw stop`. Manual runs track Greed wins anywhere until you end them.
- Reset is now a button at the top of the Leaderboard tab; click it twice to confirm.
- Roll a 67 and DungeonWinner announces it to your group (setting: Announce 67s, on by default).

## v0.1.1

- Settings now live in the game's own options: Esc > Options > AddOns > DungeonWinner.
- Theme option in settings: Classic Tooltip, Blizzard Dialog, Dark Minimal (default), Class Color, Parchment.
- Esc no longer closes the DungeonWinner windows.
- Leaderboard tab: ranks the group by total value of items won on Greed rolls during the current dungeon run. Need wins and loot outside dungeons don't count.
- `/dw test` rolls 6 random items from your bags with random choices, numbers and order (some that nobody can Need), checks every roll was read correctly, and fills a test leaderboard.
- Minimap button: left-click opens the leaderboard, right-click opens settings, shift-left-click runs test rolls, drag to move it.
- Settings: active everywhere (off by default, so it only tracks in dungeons and raids), only show first names, use Auctionator prices, open automatically, show minimap button.
- Hover a player on the leaderboard to see each item they won and its value.
- New look: compact dark window with one card per item (big icon, quality border, winner and roll), with everyone's rolls listed underneath.
- Click an item to fold or unfold its rolls; finished items fold away automatically when a new roll starts.
- The window can be resized from the bottom-right corner and remembers its size and position.
- While a roll is still open, a faint "-" shows next to each choice until the numbers come in.
- Fix: rolls weren't being read on the WoW Forever client (loot messages have an extra loot-history link at the start).
- Fix: `/dw test` no longer stacks up duplicate entries, and reports any line it can't parse.
- Dice, coin and pass icons next to each choice, like the default roll popup.
- Class-colored names are more reliable (yourself when solo, players from other realms); test players get sample classes.
- Handles WoW Forever first + last names, including players who hide their last name.
- `/dw debug` is developer-only.
- Slash command shortened to `/dw` (`/dungeonwinner` still works).
- Item names no longer wrap onto a second line; the rolling status sits on the right.

## v0.1.0

- First release: roll pop-up, everyone's choices and roll numbers, winner, saved history, `/dungeonwinner` commands.
