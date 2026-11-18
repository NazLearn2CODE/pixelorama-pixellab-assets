# PixelLab Assets — an extension for Pixelorama

Use your pixellab.ai library from inside Pixelorama.

Pull your PixelLab characters and objects into Pixelorama, edit them like any
other project, then save your edits back to the same cloud asset. Free to
use. No subscription needed from Pixelorama — this is a community extension.

Built for Pixelorama **v1.2.4-stable** (other 1.x versions may work, but only
v1.2.4 is tested).

## What you need

1. [Pixelorama](https://github.com/Orama-Interactive/Pixelorama) v1.2.4 or newer.
2. A [pixellab.ai](https://pixellab.ai) account (free tier is fine).
3. Your pixellab.ai secret key: on pixellab.ai, open **account** and copy it.

## Install (about a minute)

1. Download `PixelLabAssets.pck` from
   [Releases](../../releases) — no need to unzip it.
2. Open Pixelorama. Go to **Edit → Preferences → Extensions** and click
   **Add Extension**. Pick the `PixelLabAssets.pck` file you downloaded.
3. Turn on the **PixelLab Assets** checkbox in the same list.

You now have a new item at the bottom of the **Project** menu:
**PixelLab Assets**.

## How to use

- **Pull an asset:** open **Project → PixelLab Assets**, paste your secret
  key, click **Save key**, then **Refresh**. Pick an asset and click
  **Pull as Aseprite (tagged)** — it opens as its own project with all
  frames and animation tags.
- **Save your edits:** after editing, open the dialog again and click
  **Save all back**. Every animation — and every rotation direction — goes
  back to the exact cloud asset you pulled it from. PixelLab's own servers
  report how many pixels changed.
- **Made a mistake?** Click **Undo last save**. The extension keeps the
  pixels your save replaced and puts them back exactly.
- **Keep a copy in the cloud without overwriting:** click **Publish tag as
  GIF (gallery)** — the animation lands in your pixellab.ai gallery.
- **Upload one frame:** **Upload frame (max 256px)** adds the current frame
  to your PixelLab library as a new object.

Your secret key is stored on your device only. It is sent to
`api.pixellab.ai` and nowhere else.

## About AI (transparency)

This extension was **built with AI coding agents**, working under Naz's
direction and testing. Every feature was verified by actually running it
against the real pixellab.ai service — including tests where the extension
pushes a 1-pixel change to a real cloud asset, confirms the change, then
undoes it and checks the cloud asset is back to being **byte-for-byte
identical**. The source code is included in this repository, so anyone can
read exactly what it does: it talks to the pixellab.ai API, renders your
frames, and uploads pixels. Nothing else.

## Source and license

- Source: the `PixelLabAssets/` folder in this repository (MIT license).
- Questions or problems: open an issue here, or see the original proposal at
  [Orama-Interactive/Pixelorama#1674](https://github.com/Orama-Interactive/Pixelorama/issues/1674).

## Not included

- Generation features (creating NEW art with AI) are not part of this
  extension. It only moves YOUR pixels between Pixelorama and your own
  pixellab.ai library.
