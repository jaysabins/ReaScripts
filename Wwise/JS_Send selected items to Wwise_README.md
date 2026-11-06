# Send selected items to Wwise

Sends the selected REAPER items into Wwise as Sounds in one step.

## One-time setup (Wwise)

1. In Wwise, open **Project > User Preferences**.
2. Under **Wwise Authoring API**, tick **Enable Wwise Authoring API**.
3. Leave the HTTP port at **8090**, then click OK.

You need Windows 10 or 11, which come with `curl.exe`.

## Using it

1. In Wwise, select where the sounds should go: a Work Unit, Actor-Mixer, virtual folder or container. If you select a Sound, the new sounds go next to it.
2. In REAPER, select the items.
3. Run **Send selected items to Wwise**. Assign it a shortcut for one-key transfers.

Each item becomes a Sound named after its take name. If a Sound with that name is already there, its audio is replaced.

## What gets rendered

| Item | What happens |
|---|---|
| A whole, untouched WAV file (no trims, FX, fades, pitch or volume changes) | Imported straight from the source file. No render. |
| An edited item | Rendered with its take FX, trims, fades, pitch and rate. All of these items render in one pass. |
| An empty item on a folder track | Renders the folder's mix (the folder and its children) over that item's time range. |

The script restores your render settings afterwards.

## Options

The settings are in the **USER CONFIG** block at the top of the script:

- `ITEMS_VIA_MASTER`: render items through their track FX and the master.
- `FOLDERS_VIA_MASTER`: render folder items through the master.
- `SKIP_RENDER_UNTOUCHED`: set to `false` to always render.
- `WAAPI_URL`: change it if you changed the HTTP port in Wwise.
