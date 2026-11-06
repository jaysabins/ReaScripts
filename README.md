# Jay Sabins Scripts

REAPER scripts for game audio and voice-over workflows by Jay Sabins.

## Install with ReaPack

1. Install [ReaPack](https://reapack.com/) if you don't have it.
2. In REAPER, go to **Extensions → ReaPack → Import repositories...**
3. Paste this URL and click OK:

```
https://github.com/jaysabins/reascripts/raw/main/index.xml
```

4. Go to **Extensions → ReaPack → Browse packages**, search for "Jay Sabins", and install what you want.

Updates arrive automatically whenever ReaPack synchronizes.

## Scripts

**Batch Tools**
- **Folder Batch Processor**: batch-renders multi-language VO from a structured project folder, with per-language overrides and CSV logging. Requires SWS and ReaImGui.

**FX**
- **Screenshot track FX chain to Docs folder**: saves a PNG of every plugin on the selected track, numbered in chain order, into `Docs\<Track name>` in the project folder. Requires js_ReaScriptAPI.

**Items**
- **Build layer variations**: builds aligned layer variations (gunshots, impacts, etc.) from one track per layer, with an optional region per variation. Requires ReaImGui.

**Loudness**
- **Loudness Analyzer (language folders)**: measures LUFS and RMS across the project's `_Raw` language folders and writes a CSV. Requires SWS.
- **Loudness Analyzer (selected items)**: measures LUFS, true peak and RMS of selected items without touching the project. Requires SWS.

**Rename**
- **Rename and number items with region name**: renames selected items to their region name plus a counter (`Region_01`, `Region_02`...).

**Utility**
- **List installed plugins**: writes a text list of every plugin REAPER knows about, grouped by format.

Each tool has its own README in its folder with full instructions.

## Feedback

Found a bug or have an idea? Open an [issue](https://github.com/jaysabins/reascripts/issues).

## License

[MIT](LICENSE)
