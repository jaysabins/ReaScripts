# GunKit RPM

Respaces a run of shots so they fire at a set **rounds per minute**, with a live preview on the timeline.

Requires [ReaImGui](https://forum.cockos.com/showthread.php?t=250419) (ReaPack > ReaTeam Extensions).

## How to use

1. Select the folder items that make up the shots (one folder item per shot). NVK Folder Items' auto-select can stay on: the child items it selects are ignored as shots and simply move with their folder item.
2. Run **GunKit RPM**. The rate the shots are at now is shown next to the shot count. Nothing moves until you change a setting or click a preset tab.
3. Drag the **Rounds/min** slider, or type a value in the box next to it and press Enter. The shots move on the timeline as you go. Click the **play** button to play from the first shot and keep changing settings while it plays.
4. Click **Apply** to keep it. That's one undo point, so Ctrl+Z puts everything back.

**Revert** puts the shots back where they were. Closing the window without Apply does the same.

## What moves

- Shot *n* starts at `first shot + (n - 1) × 60 / RPM` seconds. The first shot stays where it is.
- Each folder item moves with everything on its child tracks (nested folders included) that starts inside it.
- If the selection spans several folder tracks, each track's shots are spaced on their own, each from its own first shot.
- With no folder items selected, the selected items themselves are the shots (nothing else moves).
- While a preview is showing, the selection is locked. Apply or Revert to pick other items.

## Burst fire

Tick **Burst fire** to group the shots into bursts. **Shots per burst** sets how many (2 or more; Ctrl+click the slider to type a bigger number). The shots inside a burst are spaced by the rate, and **Gap** is the time from the last shot of one burst to the first shot of the next. With 600 RPM, 3 shots per burst and a 250 ms gap, the shots land at 0, 100, 200 ms, then 450, 550, 650 ms, and so on.

## Trim so shots don't overlap

When the spacing is shorter than a shot, each shot (folder item and child items) is cut where the next shot starts, so nothing overlaps. **Fade on cut** puts a short fade-out on each cut end (5 ms by default; 0 = none). The last shot is never trimmed.

Trimming only shortens items from the end. Lowering the rate again (even after an Apply, while the window is still open) lets the shots ring out to their full length again.

## Sculpt

Tick **Shape the volume across the burst** to set each shot's level across all the shots:

- **Start** and **End**: the first and last shot's level (dB). The shots in between go from one to the other.
- **Curve**: above 0 holds near Start and drops late; below 0 moves toward End right away.
- **Random**: each shot gets up to this many dB up or down, so the burst sounds less mechanical. Each shot keeps its random amount while the window is open.

Tick **Accent the first shot** to make the first shot louder (or quieter, with a negative value) by the **Accent** amount, on top of the shape. With burst fire on, the first shot of every burst gets the accent.

The bar graph shows each shot's level, grouped by burst when burst fire is on (hover a bar for its value). For folder items the gain goes on their child items (the audio); plain items get it themselves. Shaping again after an Apply starts from the levels the items had before, so it doesn't stack.

## Preset tabs

Each tab along the top is a preset with its own rate, burst, trim and sculpt settings, saved for every project. Click a tab to preview its settings on the selected shots. **+** adds a copy of the current tab. Right-click or double-click a tab to rename it, give it a color, duplicate it, move it left or right, or close it.

## Accent color

The gear button in the title bar sets the accent color used by the Apply button, the sliders, the checkmarks and the volume bars. **Reset** goes back to the default green.

## Look

Same look as Wwise Tool and Folder Batch. If you've changed Wwise Tool's Settings > Appearance (font, colors, corners), GunKit RPM uses it too.
