# Changelog

## 0.4.0 (2026-10-11)

- Move windows from the keyboard: `⌃⌥←` / `⌃⌥→` one slot, `⌃⌥↑` / `⌃⌥↓` a row,
  `⌃⌥⇧←` / `⌃⌥⇧→` to the first or the last slot. Also in the menu under
  "Move front window".
- `⌃⌥P` puts the sessions that need you first. Settings > "Keep sessions that
  need you first" does it on its own when a session starts asking or finishes.
- Dragging a window onto another slot now moves it there and shifts the
  windows in between, instead of swapping the two. In the focus layout a drop
  onto or from the main pane still swaps.
- Fixed: one incomplete answer from Terminal could make Corral forget which
  sessions you had already looked at, so every idle session turned orange. A
  window now has to be missing from three answers in a row before Corral
  forgets it, and an empty answer while windows are on screen is ignored.
- Tests cover every window count from 1 to 20 on ten display sizes.

## 0.3.0 (2026-10-11)

- Finds every Claude Code config dir from `CLAUDE_CONFIG_DIR` in each running
  `claude`'s environment, so several accounts work with any folder layout.
- `make universal` builds one binary for Apple silicon and Intel; plain
  `make build` targets this Mac's architecture.
- `make uninstall`.
- Bundle id is now `com.urbanodx.corral`.
- MIT license.

## 0.2.0 (2026-10-11)

- Reads the status file Claude Code writes for each session: working,
  asking (permission prompt, question, agent request, dialog, stuck at a
  startup prompt) or idle. Window titles are the fallback.
- Asking sessions get a red frame and a red count in the menu bar; finished
  sessions you have not looked at stay orange. `⌃⌥N` takes the red ones first.
- A session whose Claude exited no longer counts as idle.
- Seen state, floating windows and the focus layout survive a restart.
- Drag a tiled window onto another slot to swap; drop it on an untiled
  display to float it.
- Windows no longer overlap when Terminal rounds their size up to whole
  character cells.
- Tiles leave windows that are already in place alone.

## 0.1.0 (2026-10-10)

- First version: grid tiling of Terminal windows, auto-tile, focus layout,
  float, undo, slots, session menu, orange frames on finished sessions.
