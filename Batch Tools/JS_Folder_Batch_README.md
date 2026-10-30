# JS Folder Batch Processor v2.0

**Written by:** Daniel Petras and Jay Sabins  
**GUI:** ReaImGui (ported from Lokasenna GUI v2)

---

## Overview

JS Folder Batch Processor automates rendering multi-language voice-over assets in REAPER. Point it at a structured project folder, configure your render settings, and it will import raw audio files language by language, render them out to `_Processed`, and log everything to a CSV — all in one click.

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

1. Open your REAPER project (`.rpp` file)
2. Run `JS_Folder_Batch_ImGui.lua` from the REAPER Actions list or Scripts menu
3. The script window opens with three tabs:

### Tab 1 — Global Settings

Configure your render settings here. These apply to all languages unless overridden.

| Setting | Description |
|---|---|
| **Sample Rate** | 22050 / 44100 / 48000 / 96000 Hz |
| **Channels** | Mono or Stereo |
| **Format** | WAV, MP3, FLAC, or AIFF |
| **Fade-In Length (ms)** | Fade-in duration applied to each rendered item |
| **Fade-In Shape** | Curve type for the fade-in |
| **Fade-Out Length (ms)** | Fade-out duration applied to each rendered item |
| **Fade-Out Shape** | Curve type for the fade-out |
| **End Marker Offset (ms)** | Places a take marker named `end` this many ms before each item's end point. Set to `0` to disable. |
| **Tail Length (ms)** | Extra silence rendered after each item |
| **Delete items after render** | If checked, removes source items from the timeline after rendering |

4. Click **Scan _Raw Folder for Languages** — the script will detect all language subfolders and display the count
5. Click **BATCH!** to start processing

> The Batch button is disabled until you scan the folder at least once.

---

### Tab 2 — Language Overrides

After scanning, each detected language appears here as a collapsible section.

- **Enable override** for a language to give it completely independent render settings
- Disabled languages fall back to the Global Settings
- Useful for languages that need a different sample rate, format, or fade behavior

---

### Tab 3 — Progress

Shows the current batch status:
- Progress bar and current language being processed
- Completion message with total languages processed and elapsed time

> Because REAPER's Lua environment is single-threaded, the progress bar updates after the batch completes rather than live during rendering. The tab will always reflect the correct final state.

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
