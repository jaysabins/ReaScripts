# JS Loudness Analyzer (Selected Items) v1.0

**Written by:** Jay Sabins (based on DP_Utility_LoudnessAnalyzer by Daniel Petras)

---

## Overview

JS Loudness Analyzer (Selected Items) measures the loudness of whatever audio items you have selected in REAPER. It shows the results in the console and can also save them to a CSV or copy them to the clipboard.

It doesn't need any special folder setup, and it doesn't change your project. Nothing is imported, moved or deleted.

For each item it reports:

- **LUFS-I** (integrated loudness)
- **LUFS-S Max** (maximum short-term loudness)
- **LUFS-M Max** (maximum momentary loudness)
- **LRA** (loudness range)
- **True Peak** (dBTP)
- **RMS** (average RMS, in dB)

---

## Dependencies

- **REAPER** (any recent version)
- **[SWS/S&M Extension](https://www.sws-extension.org/)**, which provides the loudness, true peak and RMS measurements

---

## Running the Script

1. Select one or more audio items on the timeline.
2. Run `JS_Utility_LoudnessAnalyzer_SelectedItems.lua` from the Actions list or Scripts menu.
3. The ReaScript console opens with a results table, the CSV location (if enabled) and how long the analysis took.

If no items are selected, a message box asks you to select some first.

> **Tip:** Assign the script to a keyboard shortcut or toolbar button in the Actions list. Then you can select items and check their loudness with a single key press.

---

## User Settings

Open the script in a text editor (or REAPER's built-in editor) and change these values near the top:

| Setting | Default | Description |
|---|---|---|
| `ANALYZE_LOUDNESS` | `true` | Measure LUFS-I, LUFS-S Max, LUFS-M Max and LRA |
| `ANALYZE_TRUE_PEAK` | `true` | Measure true peak. Slightly slower, so turn it off for very large selections if you don't need it |
| `ANALYZE_RMS` | `true` | Measure average RMS |
| `PRINT_TO_CONSOLE` | `true` | Show the results table in the ReaScript console |
| `WRITE_CSV` | `true` | Save the results to a CSV file |
| `COPY_TO_CLIPBOARD` | `false` | Copy the results to the clipboard as tab-separated text, ready to paste into Excel or Google Sheets |

---

## Output

### Console

A table with one row per item. Long track, take or file names are shortened to keep the columns lined up (a `~` marks a shortened name). The CSV always has the full names.

### CSV file

**File name:** `<timestamp> <ProjectName> Selected Loudness.csv`

**Location:**
- **Saved project:** a `Data` folder next to your `.rpp` file
- **Unsaved project:** `Data\Loudness` inside REAPER's resource folder (open it with **Options > Show REAPER resource path in explorer/finder**)

The folder is created automatically if it doesn't exist. A new file is made on every run, so earlier results are never overwritten.

| Column | Description |
|---|---|
| Track | Name of the item's track (or "Track N" if it has no name) |
| Take | Name of the active take |
| Source File | File name of the take's audio source |
| Position (s) | Item start time in seconds |
| Length (s) | Item length in seconds |
| LUFS-I | Integrated loudness |
| LUFS-S Max | Maximum short-term loudness |
| LUFS-M Max | Maximum momentary loudness |
| LRA | Loudness range |
| True Peak | True peak in dBTP |
| RMS | Average RMS in dB |
| Date | Date of analysis |
| Time | Time of analysis |

### Clipboard

When `COPY_TO_CLIPBOARD` is on, the same columns (without Date and Time) are copied as tab-separated text. Paste them straight into a spreadsheet.

**Special values:**
- `NO CALC`: the measurement couldn't be calculated (for example, the item is silent or too short)
- `NOT CALC`: that measurement was turned off in User Settings

---

## Notes

- **Only the active take is measured.** If an item has several takes, switch to the one you want before running the script.
- **MIDI items and empty items are skipped.** The console lists any items it skipped.

---

## Troubleshooting

**"This script needs the SWS extension"**
Install the SWS/S&M Extension and restart REAPER.

**"Select one or more audio items first"**
No items were selected when the script ran. Select the items you want on the timeline and run it again.

**A value shows `NO CALC`**
The item is probably silent, or too short to measure. Integrated loudness and LRA need at least a few seconds of audio.

**"Clipboard copy needs a newer SWS version"**
Update SWS to the latest version to use `COPY_TO_CLIPBOARD`.

**Can't find the CSV**
The console prints the full path after every run. If the project isn't saved, look in REAPER's resource folder under `Data\Loudness`.
