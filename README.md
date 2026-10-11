# CenterStage

Repositions World of Warcraft's system windows (character pane, map, LFG, merchant, quest, professions, ...) on ultrawide monitors — **without losing Blizzard's dynamic window placement**.

## The problem

Blizzard's UIPanel manager anchors the whole window dock to a fixed origin 16px from the left edge of the screen (the `LEFT_OFFSET` attribute on UIParent). On a 21:9 or 32:9 monitor that leaves every system window glued to the far left, out of your natural line of sight.

Window movers (BlizzMove, MoveAny) can drag frames anywhere, but you lose the built-in dynamic layout: windows pushing each other aside instead of overlapping, sliding into free slots, the spellbook auto-minimizing next to other panels, and so on. Addons like NoAutoClose or DeModal remove the panel system entirely — same tradeoff.

## What CenterStage does

CenterStage moves both boundaries the layout lives between. Every layout pass in Blizzard's secure code re-reads `LEFT_OFFSET` (the origin windows anchor from) and `RIGHT_OFFSET_BUFFER` (the right-edge reserve behind every "does another window fit" capacity check), so raising those two values confines the whole dock to a centered band of configurable width — by default the middle 16:9 slice of the screen — while Blizzard keeps doing **100% of the layout itself**. Spacing between windows, pushing, sliding, replacing, auto-closing, auto-minimizing, and the capacity decisions all behave exactly as in the default UI, just measured inside the band.

The bag windows are not part of that dock: Blizzard lays them out separately, stacked up from the bottom-right corner of the screen. CenterStage slides that stack left so it opens against the right edge of the band instead (optional, on by default). Blizzard still stacks, scales and wraps the bags into columns exactly as before.

If you use [EllesmereUI](https://www.curseforge.com/wow/addons/ellesmereui), its bag and bank windows are covered by the same option: the bag window opens against the right edge of the band and the bank window against the left edge, instead of the corners of the screen. A window you have dragged somewhere yourself stays where you put it.

The Trading Post and the Barber Shop are a third case. They cover the whole screen, Blizzard hides the rest of the UI behind them, and their panels hang off the screen's edges, so on an ultrawide the Trading Post's product list and its details column sit at opposite ends of the screen with the model in between. CenterStage pulls both interfaces into the band (optional, on by default); the 3D model stays centered and Blizzard keeps laying out everything inside.

Native center popups (game menu, death recap) and cinematics are unaffected; they were already centered.

## How it works

The addon never writes UIParent attributes from insecure code. A `SecureHandlerAttributeTemplate` frame performs the `LEFT_OFFSET` and `RIGHT_OFFSET_BUFFER` writes inside the restricted environment, so the values Blizzard's secure layout code reads are never tainted. Writes are deferred to after combat when needed.

Bag windows never read those boundaries, so they are handled with a post-hook on Blizzard's `UpdateContainerFrameAnchors`: after each of Blizzard's own layouts, the bags anchored to the screen's right edge are moved left by the distance between the screen's right edge and the band's, and the bags chained to them follow. Bag frames are not protected, so no secure handler is involved and the move also works in combat. The combined bag and the individual bags are both covered, and the shift is capped so an open bank window keeps the clearance Blizzard's own layout gives it.

EllesmereUI's bag and bank windows are plain frames that EllesmereUI anchors to the screen's corners itself (the bag window once at login, the bank window on every bank open); a dragged window is restored from its profile with a differently shaped anchor. CenterStage hooks each window's `OnShow` and, whenever the band changes, re-anchors any window still carrying EllesmereUI's default anchor (or the one CenterStage gave it) against the band's edge, and leaves dragged windows alone. EllesmereUI is an optional dependency so that its frames exist when CenterStage loads; without it, this part does nothing.

The Trading Post and the Barber Shop are UIPanels of area `full`, which the panel manager never positions: showing one hides UIParent and shows the frame, a single parentless frame anchored to the screen's corners with everything inside anchored to its edges. CenterStage re-anchors that root frame to the band from a post-hook on its `OnShow` and again whenever the band changes, and restores Blizzard's anchors when the option is off. The Barber Shop's customization frame, which Blizzard reparents into it, is anchored to it as well. Neither frame is protected and the secure layout code never touches their position, so no secure handler is involved. The hook only engages while the panel registry lists the frame as fullscreen, which leaves Classic Era's small Barber Shop window alone.

## Settings

Open with `/centerstage` or via Options → AddOns → CenterStage. Settings are saved **per resolution**, so a 32:9 monitor and a 16:9 monitor on the same machine each keep their own configuration.

- **Enable on this resolution** — defaults to on for aspect ratios 18:9 and wider, off otherwise. Disabling restores Blizzard's original boundaries exactly.
- **Center area width** — width of the centered band windows are confined to, as a percentage of screen width. 100% spans the full width, which is Blizzard's default behavior.
- **Include bag windows** — on by default. Opens the bag windows (combined or individual) against the right edge of the band instead of the right edge of the screen. Bags are only ever slid left, never further right than Blizzard's own position next to the right action bars. With EllesmereUI, its bag window opens against the right edge of the band and its bank window against the left edge, unless you have dragged them elsewhere.
- **Include fullscreen interfaces** — on by default. Opens the Trading Post and the Barber Shop inside the band instead of across the whole screen. The dock's left margin and minimap reserve do not apply to them (the rest of the UI is hidden while they are open), so at 100% they sit exactly where Blizzard puts them.

The default width for each resolution is its centered 16:9 slice — windows land where they would on a regular 16:9 monitor: 50% on 32:9, ~74% on 21:9 (3440×1440), approaching 100% (Blizzard default) as the screen narrows toward 16:9.

Adjusting a setting flashes a green rectangle for a few seconds previewing the band. The band is never allowed to shrink below one default panel width, and the right border never reserves less than Blizzard's original minimap buffer.

## Compatibility

- Game versions: Retail (12.0 and 12.1), WoW Forever, Classic Era and TBC Anniversary.
- Window movers such as BlizzMove or MoveAny take over individual frames as you drag them; CenterStage only affects where Blizzard places windows it manages and the default bag windows.
- Bag replacements (Bagnon, AdiBags, BetterBags, ElvUI's bags, ...) hide Blizzard's bag windows and draw their own; the bag option only moves Blizzard's and leaves those alone. EllesmereUI's bags are the exception: its bag and bank windows are placed against the band by the same option, as described above.
- NoAutoClose / DeModal detach frames from the panel system; frames they manage are no longer positioned by Blizzard, so the origin shift won't apply to them.
- UI suites and window managers that re-anchor or dock Blizzard windows themselves override Blizzard's placement for those frames; a frame another addon anchors can end up outside the configured band even though Blizzard's own layout respects it.
- The Trading Post does not exist on WoW Forever, Classic Era or TBC Anniversary, and the Barber Shop on Classic Era and TBC Anniversary is a small window that needs no help, so the fullscreen option has nothing to do there. The 12.0 House Editor also fills the screen but is deliberately left alone: it is an in-world editor whose panels sit at the screen edges by design.
