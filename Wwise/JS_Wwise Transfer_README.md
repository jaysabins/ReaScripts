# Wwise Transfer

Sends audio from REAPER straight into Wwise, in a window built with ReaImGui. It works like ReaWwise.

The package installs two actions:

- **Wwise Transfer** opens the window.
- **Wwise Transfer - Quick send** sends right away using the window's last settings, with no window. Give it a shortcut.

## One-time setup

1. Install **ReaImGui** from Extensions > ReaPack > Browse packages (search "ReaImGui").
2. Install **Mavriq Lua Sockets**. It lets the script hold one fast WebSocket connection to Wwise, the same way Wwise's own tools connect. Wwise 2025.1 needs it.
   1. Go to Extensions > ReaPack > **Import repositories...**.
   2. Paste `https://github.com/mavriq-dev/public-reascripts/raw/master/index.xml` and click OK.
   3. Go to Extensions > ReaPack > **Browse packages**, search **Mavriq Lua Sockets**, right-click it, choose **Install**, then click **Apply**.
3. Restart REAPER.
4. In Wwise, go to **Project > User Preferences** and tick **Enable Wwise Authoring API**. Leave the WAMP port at **8080** and the HTTP port at **8090**. They must be different from each other.

Without Mavriq Lua Sockets, the script falls back to Wwise's HTTP connection through `curl.exe`. That only works on older Wwise versions. Wwise 2025.1 answers that route with "404 Not Found".

## The window, top to bottom

**Connection.** Shows the Wwise version and project you're connected to. Click Connect or Refresh if you opened Wwise after REAPER.

**Source.** Choose what gets sent:

- **Selected items** is the fast way.
  - An item that plays a whole, untouched WAV is imported straight from disk, with no render.
  - Edited items render together in one pass, with their trims, fades, take FX, pitch and rate.
  - An empty item on a folder track renders the folder's mix over that item's time range. It's named after the item's name or notes.
- **REAPER render settings** sends whatever your render dialog is set to produce: regions, stems, the region render matrix, and so on. The files render where your settings say, and then get imported.

**Wwise destination.** By default the sounds go into whatever is selected in Wwise. You can untick that and type a fixed path instead, or click **From Wwise** to fill it in.

The **Originals subfolder** sets where Wwise stores the WAVs. It accepts wildcards, for example `Weapons\$region`.

**Wwise structure.** This sets the containers created above each Sound:

- Add levels such as Actor-Mixer, Random, Sequence, Switch or Blend Container, Virtual Folder, or Work Unit.
- Name each level with REAPER wildcards like `$region`, `$track`, `$parenttrack`, `$item` or `$project`. The **$** button inserts one.
- The last row is the Sound itself. Choose Sound SFX or Sound Voice, and for Voice pick a language. Leave its name empty to use the item's name, or the rendered file's name in render settings mode.
- Each level can have a **property template**. Select an object in Wwise and click **W**. Its properties are pasted onto the new objects at that level.
- **Presets** saves and loads hierarchy setups.

**If objects already exist.** Choose what happens when a Sound or container already exists:

- **Use existing** keeps the object and replaces its audio.
- **Replace** deletes the object and creates it again.
- **Create new** makes a renamed copy.

You can also choose whether templates apply every time or only to new objects.

**Preview.** Lists every Wwise object that will be made, and marks each one New, Exists or Duplicate. Hover over a row to see its full path and its Originals subfolder.

**Transfer to Wwise.** Does the whole transfer as one Wwise undo step, then shows a summary.

Settings are saved with the REAPER project. The last-used settings carry over to new projects.
