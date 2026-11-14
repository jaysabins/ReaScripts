# Folder Batch Processor v2.1

**Written by:** Daniel Petras and Jay Sabins  
**GUI:** ReaImGui (ported from Lokasenna GUI v2), styled to match Wwise Tool

---

## Overview

Folder Batch Processor automates rendering multi-language voice-over assets in REAPER. Point it at a structured project folder, configure your render settings, and it will import raw audio files language by language, render them out to `_Processed`, and log everything to a CSV — all in one click.

---

## Dependencies

- **REAPER** (any recent version)
- **[SWS/S&M Extension](https://www.sws-extension.org/)** — required for track notes and track selection commands
- **[ReaImGui](https://forum.cockos.com/showthread.php?t=250419)** — install via ReaPack

---

## Folder Structure

Your REAPER project folder must be set up like this before running the script:

```
MyProject/
├── MyProject.rpp          ← REAPER project file
├── _Raw/                  ← Raw (unprocessed) source audio
│   ├── English/           ← One subfolder per language
│   ├── French/
│   └── Spanish/
├── _Processed/            ← Rendered output lands here (created automatically per language)
├── Data/                  ← CSV processing logs are saved here
├── Chains/                ← FX Chain files (used with the FX Chain script)
└── Docs/                  ← Any documentation or reference files
```

> **Important:** Each language folder name inside `_Raw` must exactly match the name of a track in the REAPER session. The script matches folders to tracks by name.

---

## Track Setup

1. Create one track per language in your REAPER session (e.g., `English`, `French`, `Spanish`)
2. *(Optional)* Use `Script: mpl_Add FXChain to selected track (modified by JS 2).lua` to apply FX Chains to tracks — the chain name will be included in the CSV log output
3. Populate each language folder inside `_Raw` with the corresponding audio files

---

## Running the Script

1. Open your REAPER project (`.rpp` file). It has to be saved, since the script works from the project's folder.
2. Run `jsabins_Folder_Batch.lua` from the REAPER Actions list (it shows up as **Folder Batch Processor**)
3. The window has the same look as Wwise Tool: a dark window with rounded corners, a bold **Folder Batch** title, and flat **?** (opens this guide) and **X** buttons in the top-right corner. Next to them it shows the project's name and how many languages were found.

Everything is on one screen: project and render settings on the left, the languages on the right, and the **Batch** button at the bottom left.

### Project

Shows the project's `_Raw` folder. Click **Scan _Raw folder** to find the language folders; it shows how many it found.

### Render settings

These apply to every language unless the language has its own settings (see Languages below).

| Setting | Description |
|---|---|
| **Sample rate** | 22050 / 44100 / 48000 / 96000 Hz |
| **Channels** | Mono or Stereo |
| **Format** | WAV, MP3, FLAC, or AIFF |
| **Fade-in** | Fade-in length in ms, and its shape (the dropdown next to it) |
| **Fade-out** | Fade-out length in ms, and its shape |
| **End marker** | Places a take marker named `end` this many ms before each item's end point. Set to `0` to disable. |
| **Tail** | Extra time rendered after each item, in ms |
| **Delete items after render** | If checked, removes the imported items from the timeline after rendering |

### Languages

After scanning, every language folder is listed with:

- **Files**: how many files are in its `_Raw` folder
- **Track**: **Found** if there's a track with exactly the same name, **Missing** if not (a missing language is skipped)
- **Settings**: **Global** (uses the render settings on the left) or **Own**

Click a language to open its settings underneath the list. Tick **Use its own render settings** to give it its own sample rate, format, fades and so on, for example a language that needs a different format. Click it again to close it.

### Batch

Click **Batch** to import each language's files onto its track, render them and write the CSV log. It's greyed out until the project is saved and the `_Raw` folder has been scanned; hover it to see why. While rendering, the button reads **Rendering...**, and when it's done the result appears under **Last batch** on the right (and in the button's tooltip).

### Matching look

Folder Batch uses Wwise Tool's look. If you've changed Wwise Tool's **Settings > Appearance** (font, sizes, colors, corner rounding), Folder Batch picks up the same look the next time it opens.

---

## Output

**Rendered files:** `_Processed/<LanguageName>/`  
Each language gets its own subfolder. Files are named using REAPER's `$item` pattern.

**CSV log:** `Data/<timestamp> <projectname> Proc Data.csv`  
One row per file processed, with the following columns:

| Column | Description |
|---|---|
| Project | Full path to the `.rpp` file |
| Language | Language folder name |
| Filename | Source file name |
| FX Chain | SWS track notes (chain name if set, otherwise "None") |
| Date | Processing date |
| Time | Processing time |
| CH | Channel count |
| FI Length | Fade-in length in ms |
| FI Shape | Fade-in shape index |
| FO Length | Fade-out length in ms |
| FO Shape | Fade-out shape index |
| Tail Length | Tail length in ms |
| End Marker Offset | End marker offset in ms |

---

## Troubleshooting

**"No languages found" after scanning**  
- Confirm the `_Raw` folder exists directly inside your project folder (same level as the `.rpp`)
- Make sure there are subfolders inside `_Raw`, not just loose files

**Files aren't rendering to the right tracks**  
- Double-check that your track names match the language folder names exactly (case-sensitive)

**Script won't open / errors on load**  
- Verify ReaImGui is installed and up to date via ReaPack
- Verify SWS/S&M Extension is installed

**CSV not being written**  
- Make sure the `Data` folder exists inside your project folder before running
