# CenterStage

Repositions World of Warcraft's system windows (character pane, map, LFG, merchant, quest, professions, ...) on ultrawide monitors — **without losing Blizzard's dynamic window placement**.

## The problem

Blizzard's UIPanel manager anchors the whole window dock to a fixed origin 16px from the left edge of the screen (the `LEFT_OFFSET` attribute on UIParent). On a 21:9 or 32:9 monitor that leaves every system window glued to the far left, out of your natural line of sight.

Window movers (BlizzMove, MoveAny) can drag frames anywhere, but you lose the built-in dynamic layout: windows pushing each other aside instead of overlapping, sliding into free slots, the spellbook auto-minimizing next to other panels, and so on. Addons like NoAutoClose or DeModal remove the panel system entirely — same tradeoff.

## What CenterStage does

CenterStage moves both boundaries the layout lives between. Every layout pass in Blizzard's secure code re-reads `LEFT_OFFSET` (the origin windows anchor from) and `RIGHT_OFFSET_BUFFER` (the right-edge reserve behind every "does another window fit" capacity check), so raising those two values confines the whole dock to a centered band of configurable width — by default the middle 16:9 slice of the screen — while Blizzard keeps doing **100% of the layout itself**. Spacing between windows, pushing, sliding, replacing, auto-closing, auto-minimizing, and the capacity decisions all behave exactly as in the default UI, just measured inside the band.

Native center popups (game menu, death recap) and fullscreen panels are unaffected; they were already centered.

## How it works

The addon never writes UIParent attributes from insecure code. A `SecureHandlerAttributeTemplate` frame performs the `LEFT_OFFSET` and `RIGHT_OFFSET_BUFFER` writes inside the restricted environment, so the values Blizzard's secure layout code reads are never tainted. Writes are deferred to after combat when needed.

## Settings

Open with `/centerstage` or via Options → AddOns → CenterStage. Settings are saved **per resolution**, so a 32:9 monitor and a 16:9 monitor on the same machine each keep their own configuration.

- **Enable on this resolution** — defaults to on for aspect ratios 18:9 and wider, off otherwise. Disabling restores Blizzard's original boundaries exactly.
- **Center area width** — width of the centered band windows are confined to, as a percentage of screen width. 100% spans the full width, which is Blizzard's default behavior.

The default width for each resolution is its centered 16:9 slice — windows land where they would on a regular 16:9 monitor: 50% on 32:9, ~74% on 21:9 (3440×1440), approaching 100% (Blizzard default) as the screen narrows toward 16:9.

Adjusting a setting flashes a green rectangle for a few seconds previewing the band. The band is never allowed to shrink below one default panel width, and the right border never reserves less than Blizzard's original minimap buffer.

## Compatibility

- Window movers such as BlizzMove or MoveAny take over individual frames as you drag them; CenterStage only affects where Blizzard places windows it manages.
- NoAutoClose / DeModal detach frames from the panel system; frames they manage are no longer positioned by Blizzard, so the origin shift won't apply to them.
- UI suites and window managers that re-anchor or dock Blizzard windows themselves override Blizzard's placement for those frames; a frame another addon anchors can end up outside the configured band even though Blizzard's own layout respects it.
