# Screenshot track FX chain to Docs folder

**Written by:** Jay Sabins

## What it does

Takes a picture of every plugin on the selected track, in chain order, and saves them as PNG files in a **Docs** folder inside your project folder:

```
MyProject\
  MyProject.rpp
  Docs\
    01_ReaEQ.png
    02_Pro-Q 3.png
    03_ReaComp.png
```

The Docs folder is created if it doesn't exist.

## Requirements

- **js_ReaScriptAPI** (does the actual screen capture). Install it from **Extensions > ReaPack > Browse packages**, search "js_ReaScriptAPI", install, then restart REAPER. The script tells you if it's missing.
- The project must be **saved**, so the script knows where the project folder is.

## How to use

1. Save your project.
2. Select the track you want to document.
3. Run the script.
4. Hands off the mouse while it works. Each plugin window pops up, gets captured, and closes again. It takes about a second per plugin.
5. When it's done, the Docs folder opens and a summary tells you what was saved.

If Docs already has numbered screenshots from an earlier run, it asks whether to delete them first (so an old, longer chain doesn't leave extra images behind).

## Good to know

- Plugin windows you already had open stay open. Windows the script opened are closed again.
- Offline plugins have no window, so they're skipped and listed in the summary.
- The capture grabs what's on screen, so another window on top of a plugin would show up in its picture. The script brings each plugin window to the front and moves it fully onto the screen if it was hanging off an edge.
- Your project isn't changed.

## Settings

Open the script in a text editor (or **Actions > Edit action**) and change the values at the top:

| Setting | Default | What it does |
|---|---|---|
| `DOCS_FOLDER_NAME` | `"Docs"` | Name of the folder inside the project folder |
| `WAIT_SECONDS` | `1.0` | How long each plugin gets to draw before the picture. Raise it if a slow plugin comes out blank |
| `TRACK_SUBFOLDER` | `false` | `true` saves into `Docs\<Track name>\`, so several tracks don't overwrite each other |
| `KEEP_VENDOR_IN_NAME` | `false` | `true` keeps the maker in the file name, like `01_ReaEQ (Cockos).png` |
| `OPEN_FOLDER_WHEN_DONE` | `true` | Opens the folder when finished |
| `INCLUDE_OFFLINE` | `false` | Try offline plugins too (they usually have nothing to capture) |
