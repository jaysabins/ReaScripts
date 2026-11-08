# Wwise Transfer

Sends audio from REAPER straight into Wwise, in a window built with ReaImGui. It works like ReaWwise.

The package installs two actions:

- **Wwise Transfer** opens the window.
- **Wwise Transfer - Quick send** sends right away using the window's last settings, with no window. Give it a shortcut.

## One-time setup

1. Install **ReaImGui** from Extensions > ReaPack > Browse packages (search "ReaImGui"), then restart REAPER.
2. In Wwise, go to **Project > User Preferences > Wwise Authoring API** and set it up like this:
   - Tick **Enable Wwise Authoring API**.
   - Set **Allow connections from** to `127.0.0.1,::1`. If it's left empty, Wwise refuses every connection with "404 Not Found", and ReaWwise is refused too.
   - Leave the WAMP port at **8080** and the HTTP port at **8090**. They must be different from each other.
   - Click OK, then restart Wwise.

You need Windows 10 or 11, which come with `curl.exe`. The script uses it to talk to Wwise.

## The window

The connection to Wwise shows along the top, with a **Settings** button on the right. Below it, the setup is on the left and a preview of what will be created in Wwise is on the right. The **Transfer to Wwise** button sits under the preview.

### Setup (left)

**Source.** Choose what gets sent:

- **Selected items** is the fast way.
  - An item that plays a whole, untouched WAV is imported straight from disk, with no render.
  - Edited items render together in one pass, with their trims, fades, take FX, pitch and rate.
  - An empty item on a folder track renders the folder's mix over that item's time range. It's named after the item's name or notes.
- **REAPER render settings** sends whatever your render dialog is set to produce: regions, stems, the region render matrix, and so on. The files render where your settings say, and then get imported.

**Wwise destination.**

- By default the sounds go into whatever is selected in Wwise. You can untick **Always use the object selected in Wwise** and type a fixed path instead, or click **From Wwise** to fill it in.
- **Originals subfolder** sets where Wwise stores the WAVs. It accepts wildcards, for example `Weapons\$region`. **Browse** opens a folder picker inside the Wwise project's Originals folder (Originals\SFX, or Voices\<language> for Sound Voice), so you can pick or create the folder instead of typing it.
- **If a Sound or container already exists** has three choices:
  - **Use existing** keeps the object and replaces its audio.
  - **Replace** deletes the object and creates it again.
  - **Create new** makes a renamed copy.

**Set Initial Delay from layer timing.** Use this for layered sounds, such as a gunshot built from a muzzle, a mech and a tail:

- Select all the layers. Items that overlap in time count as one shot. Each layer's delay is how far it starts after the earliest layer in its shot.
- Choose where the delay goes: on the **layer containers** (the level above the Sounds), or on **each Sound**.
  - On containers, each container gets the smallest delay of its Sounds. If they differ, the preview shows a note.
- The delays show in the preview's **Initial delay** column and are written during the transfer.
- **Set delays on existing objects now** writes them straight away to objects already in Wwise, as one undo step.

**Wwise structure.** This sets the containers created above each Sound:

- Add levels such as Actor-Mixer, Random, Sequence, Switch or Blend Container, Virtual Folder, or Work Unit.
- Name each level with REAPER wildcards like `$region`, `$track`, `$parenttrack`, `$item` or `$project`. The **$** button inserts one.
- The last row is the Sound itself. Choose Sound SFX or Sound Voice, and for Voice pick a language. Leave its name empty to use the item's name, or the rendered file's name in render settings mode.
- Each level's **...** button holds its property template, plus Move up, Move down and Remove level. It shows **T** when a template is set.
- **Presets...** saves and loads structure setups.

**Property templates.** A template is an object in your Wwise project, often kept under `\Templates\`, that's set up the way you like: volume, bus, attenuation, randomizers and so on.

- Type its path into a level's **...** popup, or select the object in Wwise and click **From Wwise**.
- After the transfer, its settings are pasted onto the objects at that level with Wwise's Paste Properties.
- The Initial Delay from layer timing is written after templates, so a template won't overwrite it.

### Preview (right)

- Lists every Wwise object that will be made, and marks each one New, Exists or Duplicate. The tag in front of each name, such as [RND] or [SFX], shows its type. Hover over it to see the full type name.
- **Columns:**
  - **Audio** says whether a Sound is imported directly or rendered.
  - **Originals file** is the file name Wwise will keep in Originals, after your Originals subfolder. Hover over it to see the full path.
  - **Initial delay** shows the layer timing delays.
- **Right-click any column header** to tick which columns you see. Your choice is remembered.
- **Expand all** opens everything. **Collapse all** folds the containers that hold Sounds, so you see the container layout without the Sounds.
- Hover over a name to see its full path and its Originals subfolder.

**Transfer to Wwise** does the whole transfer as one Wwise undo step, then shows a summary. When the button is greyed out, the bar next to it says why.

## Settings

- **Connection:** the WAAPI HTTP port (8090 by default) and a **Reconnect** button.
- **Rendering selected items:**
  - Import untouched WAVs directly.
  - Render items through track FX and master.
  - Render folder items through master.
  - Render mono items as mono.
  - **Keep rendered files in:** by default, item renders go to a temporary folder that's deleted after the transfer. Type a folder here to keep them, for example `Renders` or `Renders\$project`.
    - Relative paths start in the project folder. Wildcards are allowed.
    - A file there with the same name as a new render is replaced.
- **Transfer:**
  - Whether property templates are pasted onto all objects or only new ones.
  - Whether the imported Sounds are selected in Wwise afterwards.
- **Window:** background opacity, for when the window is floating.
- **Diagnostics:** a log of moments where REAPER was slow. If something stutters, copy the log and send it over.

Settings are saved with the REAPER project. The last-used settings carry over to new projects. The visible columns and the window opacity apply in every project.
