# **IRC - Instance Reset Counter**
A lightweight addon that tracks your instance resets against the server's limit of **5 resets per hour**.

## What it does
- Shows up to **5 reset timers**, each counting down from **60:00** (MM:SS).
- **Reset 1 is always the oldest** reset (the shortest time remaining). When it
  reaches 0 it clears, the other timers shift up one slot, and slot 5 goes blank.
- Timers are stored as **absolute clock timestamps**, so they stay accurate
  across logout and disconnect. If a timer should have expired while you were
  offline, it shows **cleared** when you log back in.
- A **Reset Dungeon** button asks the game to reset your instances. A timer is
  recorded **only when the reset actually succeeds** (confirmed by the game's
  system message), so it will **not** start a timer if a player is still inside
  the instance and the reset fails.
- A **Reset All Timers** button clears everything.
- Reset feedback (recorded / failed / cap reached) prints to your chat frame
  with an `IRC:` prefix.

## Interface
Everything runs from a **minimap button** — there are no slash commands.
- **Left-click** the minimap button: open / close the menu.
- **Click elsewhere** (or the **Close** row): dismiss the menu.
- **Drag** the minimap button: reposition it around the minimap.
The menu is a compact dropdown-style panel that auto-sizes to its content.

## Notes
- Saved data is stored **account-wide** (`IRCDB`), so the timers are shared
  across all characters on the account. If TurtleWoW enforces its reset cap
  per-character instead, this can be switched to per-character storage by
  changing the `.toc` line `## SavedVariables: IRCDB` to
  `## SavedVariablesPerCharacter: IRCDB`.
- Reset confirmation is detected from the English system message
  (`"... has been reset."`). On a localized client, that string would need to
  be adjusted.

## Author
Fayz - Author
Zumwali - Contrubutor