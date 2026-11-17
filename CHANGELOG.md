# Changelog

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
