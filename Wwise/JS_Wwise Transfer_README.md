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
