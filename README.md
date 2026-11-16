# VidRip

A standalone macOS app (macOS Sonoma 14 or later, Apple Silicon or Intel) that pulls a video
from YouTube into a simple editor, lets you pick the part you want with a movable, resizable
selection window, and exports that piece, with its audio, to your Desktop in a format any
video editor can import.

## What it does

1. **Get Video**: paste a YouTube link and choose a maximum quality (720p to 4K).
2. **Pick the part you want**: the yellow **selection window** on the filmstrip timeline:
   - drag the middle of the window to **move** it along the video,
   - drag its left or right handle to **expand or shrink** it,
   - click the ruler or filmstrip to move the playhead, and zoom in for precise cuts,
   - or type exact start and end times, or press **I** / **O** to set them at the playhead.
3. **Crop Frame** (optional): a second window over the video picture, also movable and
   resizable, with Free, 16:9, 9:16 (Reels, Shorts, TikTok), 1:1, 4:5 and 4:3 shapes.
4. **Export Clip**: saves to your Desktop (or a folder you choose):

| Format | Use it for |
| --- | --- |
| **MP4 · H.264 + AAC** (default) | Works everywhere: Final Cut Pro, iMovie, Premiere Pro, DaVinci Resolve, CapCut, Avid, Camtasia, social media |
| **MOV · Apple ProRes 422** | Professional editing (Final Cut, Premiere, Resolve). Best quality to edit, large files |
| **WAV** | Audio only |

Cuts are frame-accurate, the audio stays in sync, and exports use a constant frame rate,
which is what editing software expects.

### Keyboard shortcuts

| Key | Action |
| --- | --- |
| Space | Play / pause |
| P | Play the selection (loops if **Loop** is on) |
| I / O | Set selection start / end to the playhead |
| [ / ] | Jump to selection start / end |
| ← / → | Step one frame (hold Shift for one second) |
| ⌘E | Export clip |
| ⌘O | Open a video file from your Mac instead of YouTube |

You can also drag a YouTube link or a video file onto the window.

## Install

### Option A: download the built app (no developer tools needed)

1. On GitHub, open this repository's **Actions** tab, then the latest green **Build macOS app**
   run, and download **VidRip-macOS** under *Artifacts*. (If a release has been tagged,
   **VidRip.dmg** is also on the *Releases* page.)
2. Unzip it, open **VidRip.dmg** and drag **VidRip** into **Applications**.
3. The app is not notarized by Apple, so the first time you open it, **right-click (or
   Control-click) VidRip in Applications and choose Open**, then click **Open** again.
   If macOS still refuses, run this once in Terminal:

   ```bash
   xattr -dr com.apple.quarantine /Applications/VidRip.app
   ```

4. The first export asks for permission to use your Desktop folder. Click **Allow**.

### Option B: build it yourself on your Mac

Requires Xcode, or the Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/lorca7/vid-rip-2.git
```

```bash
cd vid-rip-2 && ./scripts/build_app.sh
```

The app is written to `dist/VidRip.app` and an installer to `dist/VidRip.dmg`.

## How it works

VidRip is a native SwiftUI app. It ships three command-line tools inside the app bundle, so
nothing else needs to be installed:

- [yt-dlp](https://github.com/yt-dlp/yt-dlp) downloads the video and audio from YouTube,
- [Deno](https://deno.com) is the JavaScript runtime yt-dlp needs to read YouTube's player,
- [FFmpeg](https://ffmpeg.org) merges, converts and cuts the media.

Downloads prefer H.264 + AAC, which macOS can preview directly. 1440p and 4K exist on YouTube
only as VP9 or AV1, so those are converted once (with the Mac's hardware encoder) before
editing. Downloaded videos are kept in `~/Library/Caches/VidRip/Downloads` so reopening the
same link is instant. **Tools ▸ Clear Downloads Cache** frees the space.

### When YouTube stops working

YouTube changes often. If downloads start failing, use **Tools ▸ Update YouTube Downloader**,
which updates yt-dlp in place. If YouTube says to *sign in to confirm you're not a bot*, choose
a browser where you're signed in to YouTube in the cookies menu next to the quality picker.
(Safari cookies need **Full Disk Access** for VidRip in System Settings ▸ Privacy & Security.)

## Project layout

```
Sources/VidRip/
  VidRipApp.swift          app entry point and menus
  Core/
    ToolBox.swift          finds and installs the bundled tools
    ProcessRunner.swift    runs tools and streams their output
    Downloader.swift       yt-dlp download and progress
    MediaPrep.swift        converts videos macOS can't preview
    Exporter.swift         ffmpeg export (MP4, ProRes, WAV)
    AppModel.swift         fetch and open state
    EditorModel.swift      playback, selection window, crop window, export
  Views/                   SwiftUI screens (timeline, crop overlay, editor, export bar)
scripts/
  build_app.sh             builds VidRip.app and VidRip.dmg
  fetch_tools.sh           downloads yt-dlp, ffmpeg and Deno (universal binaries)
  make_icon.swift          draws the app icon
```

## Please note

Only download videos you own or have permission to use. Downloading may be against
YouTube's Terms of Service, and copyright still applies to the clips you make.

Bundled tools: yt-dlp (Unlicense), Deno (MIT), FFmpeg (GPL; static build from
[ffmpeg-static](https://github.com/eugeneware/ffmpeg-static)).
