# Jay Sabins Scripts

REAPER scripts for game audio and voice-over workflows by Jay Sabins.

## Install with ReaPack

1. Install [ReaPack](https://reapack.com/) if you don't have it.
2. In REAPER, go to **Extensions → ReaPack → Import repositories...**
3. Paste this URL and click OK:

```
https://github.com/jaysabins/reascripts/raw/main/index.xml
```

4. Go to **Extensions → ReaPack → Browse packages**, search for "Jay Sabins", right-click the scripts you want and choose **Install**, then click **Apply**.
5. The scripts appear in the **Actions** list (search for their name). Assign shortcuts or toolbar buttons from there.

### Updates and new scripts

- **Updates** to scripts you already have arrive whenever ReaPack synchronizes (**Extensions → ReaPack → Synchronize packages**).
- **New scripts** are not installed automatically. Synchronizing only updates packages you already installed, so each new script has to be installed once through **Browse packages** (step 4). After that it updates like the rest.
- Some scripts need other extensions (SWS, ReaImGui, js_ReaScriptAPI). All of them can be installed from ReaPack's **Browse packages** too; restart REAPER after installing an extension.

## Scripts

**Batch Tools**
- **Folder Batch Processor**: batch-renders multi-language VO from a structured project folder (`_Raw` to `_Processed`), with per-language overrides and CSV logging. Requires SWS and ReaImGui. Written with Daniel Petras.

**FX**
- **Screenshot track FX chain to Docs folder**: saves a PNG of every plugin on the selected track, numbered in chain order, into `Docs\<Track name>` in the project folder. Requires js_ReaScriptAPI.

**Items**
- **Build layer variations**: builds aligned layer variations (gunshots, impacts, etc.) from one track per layer. A ReaImGui window shows the selected layers live; choose side-by-side variations or every combination, align by item start or first transient, and optionally add a region per variation for rendering. Requires ReaImGui.
- **Measure timing between selected layers**: lists every selected layer sorted by position with its offset from the first layer and from the previous one, in ms and seconds, ready to type into Wwise's Initial Delay. Copies the result to the clipboard when SWS is installed. Based on a script by bfieser.

**Loudness**
- **Loudness Analyzer (language folders)**: measures LUFS and RMS across the project's `_Raw` language folders and writes a CSV. Requires SWS. Based on a script by Daniel Petras.
- **Loudness Analyzer (selected items)**: measures LUFS, true peak and RMS of selected items without touching the project. Requires SWS. Based on a script by Daniel Petras.

**Rename**
- **Name items by track and number them per region**: renames items to their track name plus a counter (`Footsteps_01`, `Footsteps_02`...), restarting at 01 in each region and counting each track separately. Works on folder/empty items too.
- **Rename and number items with region name**: renames selected items to their region name plus a counter (`Region_01`, `Region_02`...). Made with acendan.

**Utility**
- **List installed plugins**: writes a text list of every plugin REAPER knows about, grouped by format.
- **Remove missing scripts from action list**: finds every script in the Action List (all sections) whose file no longer exists on disk, lets you tick which ones to remove, backs up `reaper-kb.ini`, then unregisters them. Uses ReaImGui for the pick list; without it, asks once and removes them all.

**Wwise**
- **Wwise Tool** (formerly Wwise Transfer): sends audio from REAPER straight into Wwise over WAAPI, in the spirit of ReaWwise but built with Lua and ReaImGui. Source is the selected items, just the selected folder items (a Folder items mode that ignores their child items, so NVK Folder Items' auto-select can stay on), or your render settings. It builds the Wwise hierarchy above each Sound from wildcards like `$region` and `$track`, with property templates, conflict handling, and one Wwise undo per transfer. Tabs along the top each hold a whole setup (structure and settings), so you can flick between setups with one click; add, rename, color, duplicate, reorder and close them, and they're saved with the project. Presets come in two kinds: structure presets (just the Wwise structure) and settings presets (everything else), so loading one leaves the other alone. Settings > Configuration exports the complete setup (all tabs, all presets and the window's look) to a file and imports it again, for backups or moving to another computer. Can set Initial Delay from the timing between selected layers. Works out mono or stereo on its own (a Sound whose left and right match, folder items included, is imported as mono), and you can force Mono or Stereo per Sound or per container from the preview's Channels column, one row at a time or many at once (drag, Shift+click or Ctrl+click to pick rows). Streaming works the same way from the preview's Streaming column, with optional Auto streaming for every Sound longer than a length you pick (plus Zero latency / Non-cachable if you want them). A Loop column sets Sounds to loop forever the same way. Structure levels are added and removed with + and - buttons on each row and reordered by dragging, each level's property template sits behind a clipboard icon, and rows are color-coded by type to match the preview's tags (the preview's top row shows what the destination is in Wwise, like `[WU]` for a Work Unit or `[RND]` for a Random Container), with your own colors settable in Settings. Settings is organized into tabs (Connection, Rendering, Channels, Transfer, Streaming, Interface, Configuration, Diagnostics). The preview shows each object's status, where its audio comes from (the original WAV as is, or a render), Originals file name and Initial Delay (in seconds or milliseconds, your choice), and you right-click a column header to choose columns or drag one to reorder them. The Originals subfolder picker reaches both `Originals\SFX` and `Originals\Voices\<language>`, and picking a Voices folder imports the Sounds as voice in that language. You can keep item renders in a folder of your choice (wildcards allowed), and Settings also has the window's opacity. Buttons, dropdowns and highlights use a dark grey look with softly rounded corners instead of ImGui's default blue, and **Transfer to Wwise** sits at the bottom left. Installs a second action, **Wwise Tool - Quick send**, that transfers with the last settings without opening the window. If the REAPER project has never been saved, it says so up front instead of failing the render. Requires ReaImGui and Wwise with WAAPI enabled. Full guide (also one click away from the **?** button in the window): [Wwise Tool README](Wwise/jsabins_Wwise%20Tool_README.md).

Scripts with more to explain have their own README in their folder.

## Feedback

Found a bug or have an idea? Open an [issue](https://github.com/jaysabins/reascripts/issues).

## License

[MIT](LICENSE). Free to use, change and share.

## Trademarks

Wwise, ReaWwise and Audiokinetic are trademarks of Audiokinetic Inc. REAPER is a trademark of Cockos Incorporated. These scripts are independent and aren't affiliated with or endorsed by either company. Wwise Tool contains no code from ReaWwise or the Wwise SDK.
