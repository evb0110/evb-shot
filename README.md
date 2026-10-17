# EVBShot

A small native macOS screenshot and recording prototype. Swift, AppKit, ScreenCaptureKit, AVFoundation, Core Image, libpng, and the system zlib. No Electron, web runtime, cloud upload, or global capture shortcuts.

## Use

Open `~/Applications/EVBShot.app`, then click the viewfinder circle in the menu bar.

- **Capture Area**, **Capture Full Screen**, **Capture Window**. PNG at native pixel dimensions. Window capture has no added background or drop shadow.
- **Annotate and crop** in a compact image editor. The top toolbar provides Select, Rectangle, Arrow, Text, and Crop, plus color, line thickness or text size, Undo, Redo, and Delete. **⌘Z** undoes; **⇧⌘Z** redoes. While typing a label, those shortcuts operate on the text. Click to place text; double-click existing text with Select to edit it. Select and drag objects to move them, or drag rectangle corners and arrow endpoints to resize. Selected arrows show only their endpoint handles. Crop has explicit **Cancel / Crop** actions. Zoom and image dimensions stay in the bottom bar.
- **Scrolling Capture**. Select the scrolling content, leaving fixed headers, footers, and scrollbars outside the rectangle. A continuous native stream follows downward scrolling. Its floating controls stay visible while you use another app. Pause/Resume is available. Finish opens the editor. Intermediate animation or missing overlap is not committed; capture continues from the last good viewport when a valid overlap appears. If you scrolled too far, scroll back until that content is visible, then continue slowly.
- **Record Screen / Audio**. Full screen, selected area, or window. Resolution (native, 50%, or fit within 1920 × 1080) and **15/24/30/60 FPS** are directly visible in a compact settings card. Microphone, computer audio, and selfie camera start off. Enable the sources you want. The camera is mirrored into the selected corner and continues updating over a static desktop. Audio-only recording is also available.
- **Save** and **Save & Copy Path** immediately write to `~/Pictures/EVBShot`, without a save dialog, then close the editor on success. The toolbar stays visually stable while saving; errors leave the editor open for retry. Change the folder in **Settings → Save location**. A previously chosen save folder is retained. **Save & Copy Path** also copies the absolute path as plain text; **Save** leaves the clipboard alone. Repeated saves create separate files. Recorded video has an **Include audio** option so a silent copy can be saved without changing the compressed video frames.

macOS may ask for screen capture access. Microphone/camera permission is requested only when starting a recording with that source enabled. Drafts stay in `~/Library/Application Support/EVBShot/Drafts`; **Open Drafts Folder** reveals them, while **Open Captures Folder** opens the configured save location. Original captures remain unchanged while editing. Editable annotations and crop coordinates are kept separately in `~/Library/Application Support/EVBShot/Edits`, and restored when the same capture is reopened. Saving creates a flattened PNG with the chosen crop. Drafts are retained until you remove them.

The app appears in the Dock and ⌘Tab while an editor, recording setup, window picker, Settings, or About window is open. Closing those windows returns it to the menu bar. Reopened editable drafts can undo/redo each restored annotation and their crop. The menu has capture/recording icons, and About uses the native macOS panel with version, author, source, and library credits. The app icon source is `Resources/AppIcon.svg`; the bundled ICNS contains all macOS sizes with transparent corners.

## Full-resolution scrolling

The stitcher matches overlapping native viewports and appends original RGBA rows to a disk spool. Export streams PNG rows through zlib. The editor decodes original rows through libpng into a disk spool, displays bounded viewport tiles, and renders edited exports in strips. It never builds a whole long image in a GPU texture or giant bitmap, and never reduces output dimensions. Tall images open at Fit width; scroll to reach the entire capture, or choose Fit or a fixed zoom.

Memory depends on viewport size, not final image height. Disk space and the PNG format's dimension limit still apply; failure produces an error instead of resizing. This prototype supports vertical, downward scrolling. Repetitive/blank regions, animation, sticky content, or scrolling too far between samples can prevent reliable overlap detection. Keep meaningful overlap visible. It does not automate scrolling or remove sticky headers.

## Build

Requires macOS 15 or later and Xcode with Swift 6. The build script downloads the pinned libpng 1.6.59 source, verifies its SHA-256, and builds it statically for macOS 15. The resulting app needs no separately installed libraries. The libpng license is included in the app resources. An existing compatible static build can be supplied through `LIBPNG_PREFIX`.

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

`--result-layout-test OUTPUT_DIRECTORY` runs only the result-window regression checks. Native-size 2294 × 1741, 4K, ultra-wide, and portrait previews must keep both the window and its Auto Layout fitting size compact, stay within one screen, and save byte-identical original PNGs.

`--editor-test OUTPUT_DIRECTORY` exercises the canvas gesture routes for text, arrows, rectangles, moving, resizing, deletion, crop Apply/Cancel, and native undo/redo. It dispatches actual window key-equivalent events for ⌘Z/⇧⌘Z, including native text-field undo; checks selected-arrow pixels, the actual 24 FPS control, and transient-frame rejection followed by pixel-exact scrolling recovery through the live frame receiver. It also checks editable draft reopening, both save buttons without dialogs, configurable persistent save folders, repeated saves, failure/clipboard preservation with a private pasteboard, source-version changes, transparent pixels, and **257 × 70001** annotated / **220 × 69950** cropped PNGs. Run `python3 scripts/verify-editor.py OUTPUT_DIRECTORY` to independently decode those exports, compare every unmarked native pixel, and check annotation positions, crop offsets, and alpha compositing.

`--show-capture PNG_PATH` reopens an existing capture in the native result window without changing its file. This also restores a capture after installing an update.

The app tests native scrolling pixels, real rendered text, rejected overlaps, CGImage orientation, a **1537 × 70001** PNG, recording/compositing, mixed audio, muting, audio-only recording, a static-screen frame clock, atomic saves, Unicode paths, and failed-save clipboard preservation. UI windows render offscreen. Tests use a private pasteboard and synthetic camera/audio, so they do not activate those devices or modify your clipboard. Independent PNG checks use Python's standard library. The optional independent media checks require FFmpeg/ffprobe for development only.

`--capture-smoke OUTPUT_DIRECTORY` runs a short silent live screen test when screen capture access is already available. It checks full-screen, area, window capture, the native scrolling SCStream, and a 1080p/15 FPS recording. Desktop pixels are discarded after checking. It does not activate the camera or microphone.

## Source layout

`CaptureEngine` and `Selection` handle native capture and selection. `LongCapture` owns the disk spool; `PixelCore` performs overlap matching and streaming PNG encoding/decoding. `ImageEditDocument` owns original-coordinate objects, crop state, persistence, and native undo history. `ImagePixelStore` owns disk pixels, viewport tiles, and strip exports; `ImageCanvas` handles gestures and drawing. `ResultController` provides the native editor toolbar and save actions. `RecordingSession` owns the serial media writer and frame clock. `CameraCapture` owns the camera queue and locked latest frame. `MediaExport` mixes audio while passing compressed video through.

The CleanShot research in `docs/research` informed the feature boundaries and editor workflow. This implementation uses public Apple APIs, libpng, and original source code.
