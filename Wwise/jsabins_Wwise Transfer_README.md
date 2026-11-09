# Wwise Transfer

Send audio from REAPER straight into Wwise, without exporting files by hand or dragging them into the Audio File Importer. Select some items, check the preview, click **Transfer to Wwise**, and the Sounds show up in your Wwise project with the container structure, property templates and Initial Delays you set up.

Wwise Transfer is a free REAPER script by Jay Sabins, written in Lua with a ReaImGui window. It works in the spirit of Audiokinetic's ReaWwise, but it's a separate, independent tool. It isn't made or endorsed by Audiokinetic.

## Features

- **Fast transfers.** Untouched WAV items import straight from disk with no render. Edited items render together in one pass. Everything goes to Wwise in a single import call.
- **Send items or renders.** Send the selected items, or everything your REAPER render settings produce (regions, stems, region matrix).
- **Folder items.** An empty item on a folder track renders the folder's mix over that time range.
- **Automatic mono or stereo.** Rendered Sounds whose left and right channels are the same are imported as mono, folder items included. You can force Mono or Stereo for any Sound or container from the preview.
- **Build the Wwise structure for you.** Add levels of Actor-Mixers, Random, Sequence, Switch and Blend Containers, Virtual Folders or Work Units above each Sound, named with REAPER wildcards like `$region` and `$track`.
- **Property templates.** Point any level at a template object in Wwise and its settings (volume, bus, attenuation, randomizers...) are pasted onto the new objects.
- **Initial Delay from layer timing.** For layered sounds like gunshots, the gap between each layer and the first one is written into Wwise's Initial Delay.
- **Live preview.** See every object that will be created, marked New, Exists or Duplicate, before anything is sent.
- **Conflict handling.** Choose to reuse, replace or rename objects that already exist.
- **SFX and Voice.** Import as Sound SFX or as Sound Voice in a chosen language.
- **Originals subfolders** with wildcards, and a folder picker that opens in your Wwise project's Originals folder.
- **Presets** for structure setups you use often.
- **One undo step.** Each transfer is a single undo in Wwise.
- **Quick send.** A second action transfers with your last settings, without opening the window. Put it on a shortcut for one-key transfers.
- **No extra downloads.** It talks to Wwise through `curl.exe`, which comes with Windows. The only extension it needs is ReaImGui.

## Requirements

- REAPER 6.x or 7.x on Windows 10 or 11.
- The **ReaImGui** extension (free, from ReaPack).
- Wwise with the Wwise Authoring API (WAAPI) turned on. Tested with Wwise 2025.1. Property templates need Wwise 2022.1 or newer.

## Install

1. If you don't have ReaPack yet, install it from [reapack.com](https://reapack.com/).
2. In REAPER, go to **Extensions > ReaPack > Import repositories...**, paste this URL and click OK:
   ```
   https://github.com/jaysabins/reascripts/raw/main/index.xml
   ```
3. Go to **Extensions > ReaPack > Browse packages**, search for **Wwise Transfer**, right-click it, choose **Install**, then click **Apply**.
4. In the same window, search for **ReaImGui** and install it too. Restart REAPER.

You now have two actions in REAPER's **Actions** list:

- **Wwise Transfer** opens the window.
- **Wwise Transfer - Quick send** transfers right away with the window's last settings.

## One-time Wwise setup

In Wwise, open **Project > User Preferences** and find the **Wwise Authoring API** section:

1. Tick **Enable Wwise Authoring API**.
2. Set **Allow connections from** to `127.0.0.1,::1`. If this is left empty, Wwise refuses every connection with "404 Not Found".
3. Leave the WAMP port at **8080** and the HTTP port at **8090**. The two must be different.
4. Click OK and restart Wwise.

If you change the HTTP port in Wwise, set the same number in Wwise Transfer's **Settings**.

## Quick start: your first transfer

1. Open your Wwise project, then run **Wwise Transfer** in REAPER. The dot at the top left turns green and shows the Wwise project name.
2. In Wwise, select the object the new Sounds should go into, for example a Work Unit or an Actor-Mixer.
3. In REAPER, select the items you want to send.
4. Check the preview on the right. Each new object is green and marked New.
5. Click **Transfer to Wwise**. A summary shows how many files were imported and objects were created.

That's it. The rest of this guide covers the options.

## The window

### Toolbar

The thin bar along the top shows a green dot when you're connected, then the Wwise project name and version. On the right, **?** opens this guide in your web browser, and next to it is **Settings**.

If Wwise can't be reached, the dot turns red and a yellow banner explains why. If you opened Wwise after REAPER, or Wwise restarted, open **Settings** and click **Reconnect**.

### Source

Choose what gets sent:

- **Selected items** is the fast way.
  - An item that plays a whole, untouched WAV (no trims, fades, FX, pitch, rate or volume changes) is imported straight from disk.
  - Edited items render together in one pass, with their trims, fades, take FX, pitch and rate.
  - An empty item on a folder track renders the folder's mix (the folder track and its children) over that item's time range. It's named after the item's name or its notes.
- **REAPER render settings** sends whatever your render dialog is set to produce, such as regions, stems or the region render matrix. The files render to wherever your render settings say, and are imported from there. The **Render settings...** and **Region matrix...** buttons open those REAPER windows.

The Sound's name comes from the item's take name (or the rendered file's name in render settings mode), unless you give the Sound level a name pattern (see below).

### Wwise destination

- **Always use the object selected in Wwise** (on by default) sends the Sounds into whatever is selected in Wwise when you click Transfer. If a Sound is selected, its parent is used.
- Untick it to use a fixed path instead. Type the path, or select the object in Wwise and click **From Wwise**.
- **Originals subfolder** sets where Wwise stores the WAV files inside its Originals folder. It accepts wildcards, for example `Weapons\$region`. **Browse** opens a folder picker inside the Wwise project's Originals folder (`Originals\SFX`, or `Originals\Voices\<language>` for Sound Voice), so you can pick or create a folder instead of typing.
- **If a Sound or container already exists**:
  - **Use existing** keeps the object and replaces its audio. Good for iterating on a sound.
  - **Replace** deletes the object and creates it again.
  - **Create new** makes a renamed copy next to it.

### Wwise structure

This sets the containers that are created above each Sound, from the top down:

- Click **+ Add level** and choose its type: Actor-Mixer, Random Container, Sequence Container, Switch Container, Blend Container, Virtual Folder, Work Unit or Physical Folder.
- Name each level. Names can use REAPER wildcards, and the **$** button inserts one. Every item gets its own name from the wildcard, so `$region` puts each item in a container named after its region.
- The last row is the **Sound** itself. Choose **Sound SFX** or **Sound Voice** (pick a language for Voice). In Wwise 2025.1 and later both are simply called Sound. Leave its name empty to use the item's name.
- Each row's type dropdown is colored by its type, the same color its tag uses in the preview (orange for Random Containers, green for Sounds, and so on), so you can see the structure at a glance.
- Each level's **...** button holds its property template plus **Move up**, **Move down** and **Remove level**. The button shows **T** when a template is set.
- **Presets...** saves the current structure (levels, templates, Sound settings, Originals subfolder and conflict choice) under a name, and loads or deletes saved ones.

If a level can't hold the level below it (for example a Random Container can't hold an Actor-Mixer), the problem is shown and Transfer stays greyed out until you fix it.

#### Wildcards

| Wildcard | Becomes |
|---|---|
| `$region` | Region name |
| `$regionnumber` | Region number |
| `$marker` | Marker before the item or region |
| `$track` | Track name |
| `$parenttrack` | Parent (folder) track name |
| `$folders` | All parent folder names |
| `$item` | Item (take) name |
| `$itemnumber` | Item number on its track |
| `$project` | Project name |
| `$tempo` | Tempo |
| `$timesig` | Time signature |
| `$date` | Date |
| `$author` | Project author |

These are REAPER's own render wildcards, worked out by REAPER itself, so any other wildcard REAPER's render dialog understands works too.

### Property templates

A template is an ordinary object in your Wwise project that's set up the way you like, often kept in a `\Templates\` folder: volume, output bus, attenuation, randomizers, and so on.

- Open a level's **...** popup and type the template's path, or select the template in Wwise and click **From Wwise**.
- After the audio is imported, the template's settings are pasted onto every object at that level with Wwise's Paste Properties.
- In **Settings** you choose whether templates go onto all objects, or only onto objects the transfer just created (so tweaks you made in Wwise aren't overwritten).

### Set Initial Delay from layer timing

Made for layered sounds, such as a gunshot built from a muzzle, a mechanical layer and a tail.

1. Lay out each shot's layers in REAPER as they should play, with a gap between one shot and the next.
2. Tick **Set Initial Delay from layer timing** and select all the layers.
3. Items that overlap in time count as one shot. Each layer's delay is how far it starts after the first item of its shot.
4. Choose where the delay goes:
   - **Layer containers** (the level above the Sounds). Each container gets the smallest delay of its Sounds. If its Sounds have different delays, the summary and preview tell you.
   - **Each Sound**.
5. The delays show in the preview's **Initial delay** column, and are written during the transfer, after templates, so a template can't overwrite them.

**Set delays on existing objects now** writes the delays straight away to objects that are already in Wwise, without transferring any audio. It's one undo step in Wwise.

### Preview

The right side shows what the transfer will create, laid out like Wwise's Project Explorer:

- Each object is marked **New** (green), **Exists** (orange) or **Duplicate** (two items would end up with the same name and path).
- The tag in front of each name, such as `[RND]` or `[SFX]`, shows its type. Hover over it for the full type name.
- Hover over a name to see its full Wwise path and Originals subfolder.
- **Columns:**
  - **Audio** says whether a Sound is imported directly or rendered.
  - **Channels** shows whether a Sound will be mono or stereo, and lets you change it. See [Mono and stereo](#mono-and-stereo).
  - **Originals file** is the file name Wwise will keep in Originals. Hover for the full path.
  - **Initial delay** shows the layer timing delays.
- **Right-click any column header** to choose which columns you see.
- **Expand all** opens everything. **Collapse all** folds the containers that hold Sounds, so you see the container layout on its own.

The preview updates as you change the selection in REAPER or the settings.

### Mono and stereo

By default, Wwise Transfer works out on its own whether each Sound should be mono or stereo:

- Edited items and folder items render in stereo. After rendering, each file is checked, and if its left and right channels are the same, it's imported as a mono file. Differences quieter than -90 dB (like dither noise) count as the same. A true stereo sound stays stereo, and the transfer summary lists those Sounds with how much left and right differ.
- Untouched WAV items that import straight from disk keep the channels the file has.

This is **Auto**, and you can turn it off in Settings (**Auto channels**). With it off, files keep whatever channel count they render with.

To decide yourself, click a row in the preview's **Channels** column and pick **Mono**, **Stereo** or **Auto**:

- On a **Sound**, the choice is for that Sound only.
- On a **container**, it's for every Sound inside it, so you can set a whole `Ambience` container to Stereo and a `Footsteps` container to Mono. A choice set on a Sound wins over its container's.
- Mono on a stereo file mixes left and right together. Stereo on a mono file copies it to both sides. An untouched WAV is copied first, so the file on disk is never changed.

Choices are remembered by the Sound's or container's name and place in the structure, and saved with the project. **Settings > Clear channel overrides** removes them all. This also works with **Source: Render settings**, where your own rendered files are copied before they're changed.

The check only reads WAV files. With other render formats (MP3, OGG...), Auto leaves the files as they are.

### Transfer

**Transfer to Wwise** runs the whole transfer as one Wwise undo step. When the button is greyed out, the text next to it (and its tooltip) says why, for example "Select one or more items in REAPER".

Afterwards a summary shows the destination, the number of files imported, objects created, templates applied and delays set, how long each step took, and any problems. **Copy details** copies the problems so you can paste them somewhere. If **Select imported Sounds in Wwise afterwards** is on, Wwise jumps to the new Sounds.

## Quick send

**Wwise Transfer - Quick send** does a transfer with the window's last-used settings, without opening the window. It shows a message only when something goes wrong. Assign it a keyboard shortcut in REAPER's Actions list, then iterating on a sound is: tweak it in REAPER, press the key, play it in Wwise.

## Settings

- **Connection:** the WAAPI HTTP port (8090 by default, must match Wwise) and **Reconnect**.
- **Rendering selected items:**
  - **Import untouched WAV files directly (no render).** Turn it off to always render.
  - **Render items through track FX and master.** Off renders just the items.
  - **Render folder items through master.**
  - **Auto channels: make a Sound mono when left and right are the same.** On by default. See [Mono and stereo](#mono-and-stereo). When you've set any Mono/Stereo choices in the preview, **Clear channel overrides** appears here.
  - **Keep rendered files in:** by default, item renders go to a temporary folder that's deleted after the transfer. Type a folder to keep them, such as `Renders` or `Renders\$project`. Relative paths start in the REAPER project folder, and wildcards are allowed. A file there with the same name as a new render is replaced.
- **Transfer:** paste templates onto all objects or new objects only, and whether imported Sounds are selected in Wwise afterwards.
- **Window:** background opacity, for when the window is floating (not docked).
- **Diagnostics:** a log of moments where REAPER was slow. If something stutters, click **Copy slow-moment log** and include it in a bug report.

Settings are saved with each REAPER project, and the last-used settings carry over to new projects. Presets, visible columns and window opacity apply to every project.

## Example setups

**Weapon with layers and variations.** Tracks `Muzzle`, `Mech` and `Tail`, each holding variations `Muzzle_01`, `Muzzle_02`... lined up under each other per shot.

- Destination: `\Actor-Mixer Hierarchy\Default Work Unit\Weapons` (or `\Containers\...` in Wwise 2025).
- Level 1: Blend Container named `Pistol`.
- Level 2: Random Container named `$track`.
- Sound: name left empty, so each Sound keeps its item name.
- Tick **Set Initial Delay from layer timing**, target **Layer containers**.

Result: `Pistol` holds three Random Containers (`Muzzle`, `Mech`, `Tail`), each with its variations and its Initial Delay already set.

**One container per region.** Regions named `Footstep_Concrete`, `Footstep_Grass`..., several items in each.

- Level 1: Random Container named `$region`.
- Originals subfolder: `Footsteps\$region`.

**Voice-over.** Choose **Sound Voice** and the language, and set the Sound's name to `$region` or leave it as the item name. The files go to `Originals\Voices\<language>`.

## Troubleshooting

- **Red dot, "Couldn't reach Wwise".** Wwise isn't open, WAAPI is off, or the HTTP port doesn't match. Check the Wwise setup above, then click **Reconnect** in Settings.
- **"Wwise refused the connection (HTTP 404)".** Set **Allow connections from** to `127.0.0.1,::1` in Wwise's User Preferences, make sure the WAMP and HTTP ports are different, and restart Wwise.
- **"Wwise is busy and didn't answer in time".** Wwise is still loading or working on something. Wait a moment; the preview updates on its own.
- **Transfer is greyed out.** Read the text next to the button. Usually nothing is selected in REAPER or in Wwise, or a structure level has no name.
- **"A wildcard in the hierarchy didn't resolve to a single name".** A wildcard came out empty for some items, for example `$region` on an item that's outside every region.
- **Two audio sources with the same name on one Sound.** Older versions could add a second source when you transferred onto an existing Sound. From 1.7.1 the existing source gets the new audio, and the next transfer of that Sound also removes the older duplicate.
- **A Sound came in stereo but should be mono (or the other way).** Left and right must match within -90 dB for Auto to pick mono, so a stereo effect, a stereo source file or a panned item keeps it stereo. The transfer summary says how much they differ. Click the Sound (or its container) in the preview's **Channels** column and pick Mono.
- **The window says it needs ReaImGui.** Install ReaImGui from ReaPack and restart REAPER.

Found a bug or have an idea? Open an [issue](https://github.com/jaysabins/reascripts/issues).

## License and trademarks

Wwise Transfer is free and open source under the [MIT License](../LICENSE).

Wwise, ReaWwise and Audiokinetic are trademarks of Audiokinetic Inc. REAPER is a trademark of Cockos Incorporated. This project isn't affiliated with or endorsed by either company.
