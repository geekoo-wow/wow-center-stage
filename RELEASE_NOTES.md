# Release Notes

## v0.1.0

Initial release.

- Confines Blizzard's system windows (character pane, map, LFG, merchant, ...) to a centered band of the screen — by default the middle 16:9 of a 32:9 monitor — while Blizzard's own layout code keeps doing all placement and fit decisions (push/slide/replace, auto-close, auto-minimize).
- Single "Center area width" slider (percent of screen width; 100% = Blizzard default), with a green preview rectangle while adjusting.
- Per-resolution profiles: enabled by default on aspect ratios 18:9 and wider, defaulting to the centered 16:9 slice of the screen (50% on 32:9, ~74% on 21:9).
- Boundary attributes are written from a secure handler snippet, so Blizzard's layout code never reads a tainted value; writes are queued during combat.
- `/centerstage` opens the settings panel.
