# EVBShot

A small native macOS screenshot and recording prototype. Swift, AppKit, ScreenCaptureKit, AVFoundation, Core Image, and the system zlib. No Electron, web runtime, cloud upload, or keyboard shortcuts.

## Use

Open `~/Applications/EVBShot.app`, then click the viewfinder circle in the menu bar.

- **Capture Area**, **Capture Full Screen**, **Capture Window**. PNG at native pixel dimensions. Window capture has no added background or drop shadow.
- **Scrolling Capture**. Select the scrolling content, leaving fixed headers, footers, and scrollbars outside the rectangle. Scroll **downward slowly** with overlap. Pause/Resume is available. Finish opens the save window. A missing or ambiguous overlap pauses capture and preserves the last good pixels; scroll back to that content before resuming.
- **Record Screen / Audio**. Full screen, selected area, or window. Resolution (native, 50%, or fit within 1920 × 1080) and 15/30/60 FPS are directly visible. Microphone, computer audio, and selfie camera start off. Enable the sources you want. The camera is mirrored into the selected corner and continues updating over a static desktop. Audio-only recording is also available.
- **Save & Copy File Path** writes the file, then copies its absolute path as plain text. **Save** leaves the clipboard alone. Recorded video has an **Include recorded audio** option so a silent copy can be saved without changing the compressed video frames.

macOS may ask for screen capture access. Microphone/camera permission is requested only when starting a recording with that source enabled. Drafts stay in `~/Library/Application Support/EVBShot/Drafts`; the menu can reveal that folder. Drafts are retained until you remove them.

## Full-resolution scrolling

The stitcher matches overlapping native viewports and appends original RGBA rows to a disk spool. Export streams PNG rows through zlib. It never builds the full image in an image view, GPU texture, or giant bitmap, and never reduces the output dimensions. The preview shows only the first viewport.

Memory depends on viewport size, not final image height. Disk space and the PNG format's dimension limit still apply; failure produces an error instead of resizing. This prototype supports vertical, downward scrolling. Repetitive/blank regions, animation, sticky content, or scrolling too far between samples can prevent reliable overlap detection. Keep meaningful overlap visible. It does not automate scrolling or remove sticky headers.

## Build

Requires macOS 15 or later and Xcode with Swift 6. There are no third-party app dependencies.

```sh
export TMPDIR="$(agent-tmpdir evb-shot-build)"
agent-env run --mem 2G -- bash scripts/build-app.sh
open dist/EVBShot.app
```

Outside this workspace's agent environment, `bash scripts/build-app.sh` is sufficient. The default signature is ad hoc. Set `EVBSHOT_SIGN_IDENTITY` to a local Developer ID identity for a stable signed build. The script includes the camera/audio entitlements for hardened runtime signing. This local prototype is not notarized.

## Verify

Use a new empty output directory for each run:

```sh
dist/EVBShot.app/Contents/MacOS/EVBShot --self-test "$PWD/.devkit/checks/run-1"
python3 scripts/verify-png.py .devkit/checks/run-1
python3 scripts/verify-media.py .devkit/checks/run-1
```

The app tests native scrolling pixels, real rendered text, rejected overlaps, CGImage orientation, a **1537 × 70001** PNG, recording/compositing, mixed audio, muting, audio-only recording, a static-screen frame clock, atomic saves, Unicode paths, and failed-save clipboard preservation. UI windows render offscreen. Tests use a private pasteboard and synthetic camera/audio, so they do not activate those devices or modify your clipboard. Independent PNG checks use Python's standard library. The optional independent media checks require FFmpeg/ffprobe for development only.

`--capture-smoke OUTPUT_DIRECTORY` runs a short silent live screen test when screen capture access is already available. It checks full-screen, area, window capture, and a 1080p/15 FPS recording. Desktop pixels are discarded after checking. It does not activate the camera or microphone.

## Source layout

`CaptureEngine` and `Selection` handle native capture and selection. `LongCapture` owns the disk spool; `PixelCore` performs overlap matching and streaming PNG encoding. `RecordingSession` owns the serial media writer and frame clock. `CameraCapture` owns the camera queue and locked latest frame. `MediaExport` mixes audio while passing compressed video through. AppKit controllers provide menu, recording, scrolling, and save controls.

The CleanShot research in `docs/research` informed the feature boundaries. This implementation uses public Apple APIs and original source code.
