# GunKit RPM

Respaces a run of shots so they fire at a set **rounds per minute**, with a live preview on the timeline.

Requires [ReaImGui](https://forum.cockos.com/showthread.php?t=250419) (ReaPack > ReaTeam Extensions).

## How to use

1. Select the folder items that make up the shots (one folder item per shot). NVK Folder Items' auto-select can stay on: the child items it selects are ignored as shots and simply move with their folder item.
2. Run **GunKit RPM**. The slider starts at the rate the shots are at now.
3. Drag the **Rounds/min** slider, or type a value in the box next to it and press Enter. The shots move on the timeline as you go. Click **Play** to play from the first shot and keep changing the rate while it plays.
4. Click **Apply** to keep it. That's one undo point, so Ctrl+Z puts everything back.

**Revert** puts the shots back where they were. Closing the window without Apply does the same.

## What moves

- Shot *n* starts at `first shot + (n - 1) × 60 / RPM` seconds. The first shot stays where it is.
- Each folder item moves with everything on its child tracks (nested folders included) that starts inside it.
- If the selection spans several folder tracks, each track's shots are spaced on their own, each from its own first shot.
- With no folder items selected, the selected items themselves are the shots (nothing else moves).
- While a preview is showing, the selection is locked. Apply or Revert to pick other items.

## Trim so shots don't overlap

When the spacing is shorter than a shot, each shot (folder item and child items) is cut where the next shot starts, so nothing overlaps. **Fade on cut** puts a short fade-out on each cut end (5 ms by default; 0 = none). The last shot is never trimmed.

Trimming only shortens items from the end. Lowering the rate again (even after an Apply, while the window is still open) lets the shots ring out to their full length again.

## Look

Same look as Wwise Tool and Folder Batch. If you've changed Wwise Tool's Settings > Appearance (font, colors, corners), GunKit RPM uses it too.
