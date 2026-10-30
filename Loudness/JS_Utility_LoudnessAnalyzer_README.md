# JS Loudness Analyzer v1.1

**Written by:** Jay Sabins (based on a script written by Daniel Petras)

---

## Overview

JS Loudness Analyzer measures the loudness of every audio file in a set of language folders and writes the results to a CSV. Each file is imported onto its matching track in REAPER, measured, and (optionally) removed again. It's useful for checking multi-language VO deliveries against loudness specs before or after processing.

For each file it reports:

- **RMS** (average RMS of the item, in dB)
- **LUFS-I** (integrated loudness)
- **LUFS-S** (maximum short-term loudness)
- **LUFS-M** (maximum momentary loudness)

---

## Dependencies

- **REAPER** (any recent version)
- **[SWS/S&M Extension](https://www.sws-extension.org/)**, which provides the loudness and RMS measurement functions

---

## Folder Structure

Set up your project folder like this before running the script:

```
MyProject/
├── MyProject.rpp       ← REAPER project file (must be saved)
├── _Raw/               ← Audio files to analyze
│   ├── English/        ← One subfolder per language
│   ├── French/
│   └── Spanish/
└── Data/               ← CSV results are saved here (created automatically if missing)
```

> **Important:** Each language folder name inside `_Raw` must exactly match the name of a track in the REAPER session, including capitalization. The script matches folders to tracks by name.

Supported audio formats: WAV, BWF, AIF/AIFF, FLAC, MP3, OGG, Opus, M4A, WavPack. Other files in the folders (such as `.reapeaks` or `desktop.ini`) are ignored.

---

## Running the Script

1. Open and **save** your REAPER project. The script uses the `.rpp` location to find `_Raw` and `Data`.
2. Create one track per language, named to match the folders in `_Raw` (e.g. `English`, `French`, `Spanish`).
3. Open the ReaScript console (**View > ReaScript console**, or it opens automatically when the script prints) so you can see progress.
4. Run `JS_Utility_LoudnessAnalyzer.lua` from the Actions list or Scripts menu.
5. When it finishes, the console shows how many files were analyzed and where the CSV was saved.

The whole run is a single undo step, so **Ctrl+Z** reverses it.

---

## User Settings

Open the script in a text editor (or REAPER's built-in editor) and change these values near the top:

| Setting | Default | Description |
|---|---|---|
| `DISABLE_SCRIPT` | `false` | Set to `true` to stop the script from running (useful if it's set to launch with a project) |
| `DELETE_ITEMS_AFTER_ANALYSIS` | `true` | Removes the imported items from the timeline once they've been measured |
| `CLOSE_AFTER_PROCESS` | `false` | Quits REAPER when the analysis finishes. Useful for unattended or command-line runs |
| `ANALYZE_RMS` | `true` | Measure average RMS for each file |
| `ANALYZE_LOUDNESS` | `true` | Measure LUFS-I, LUFS-S and LUFS-M for each file |
| `VERBOSE` | `true` | Print folders, tracks and file counts to the console as the script runs |

---

## Output

**CSV file:** `Data/<timestamp> <ProjectName> Loudness Data.csv`

A new file is created on every run, so earlier results are never overwritten.

| Column | Description |
|---|---|
| Language | Language folder name |
| Filename | Source file name |
| RMS | Average RMS in dB |
| LUFS-I | Integrated loudness |
| LUFS-S | Maximum short-term loudness |
| LUFS-M | Maximum momentary loudness |
| Date | Date of analysis |
| Time | Time of analysis |

**Special values:**
- `NO CALC`: the measurement couldn't be calculated (for example, the file is silent or too short)
- `NOT CALC`: that measurement was turned off in User Settings

---

## Troubleshooting

The console messages are the first place to look. The script reports what it found and why anything was skipped.

**"Project must be saved before running this script"**
Save the project (**Ctrl+S**) so it has a location on disk, then run it again.

**"No language folders found"**
Make sure `_Raw` sits in the same folder as your `.rpp` file and contains subfolders, not just loose files.

**"SKIPPED 'French': no track with that exact name"**
The folder name and track name don't match. If the console says *did you mean 'french'?*, the only difference is capitalization or extra spaces. Rename the track or the folder so they match exactly.

**"FAILED to import"**
REAPER couldn't open that file. Check that it isn't corrupt or in an unsupported format.

**The CSV only has a header row**
No files were analyzed. Look above the "Done" line in the console for SKIPPED or FAILED messages.

**"SWS extension not found"**
Install the SWS/S&M Extension and restart REAPER.
