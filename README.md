# EVB Shot

A small native macOS screenshot and recording prototype. Swift, AppKit, ScreenCaptureKit, AVFoundation, Core Image, libpng, and the system zlib. No Electron, web runtime, cloud upload, or global capture shortcuts.

## Use

Download the [latest DMG](https://github.com/evb0110/evb-shot/releases/latest/download/EVB-Shot-macOS-arm64.dmg), open it, and drag **EVB Shot.app** to Applications. Requires macOS 15+ and Apple Silicon. Click its viewfinder circle in the menu bar.

[Website](https://evb-shot.vercel.app) · [Source](https://github.com/evb0110/evb-shot) · [MIT License](LICENSE)

Public releases are signed with Developer ID and notarized by Apple. Both the app and disk image carry stapled notarization tickets.

- **Capture Area**, **Capture Full Screen**, **Capture Window**. PNG at native pixel dimensions. Window capture has no added background or drop shadow.
- **Annotate and crop** in a compact image editor. The top toolbar provides Select, Rectangle, Arrow, Text, and Crop, plus color, line thickness or text size, Undo, Redo, and Delete. **⌘Z** undoes; **⇧⌘Z** redoes. While typing a label, those shortcuts operate on the text. Click to place text; double-click existing text with Select to edit it. Select and drag objects to move them, or drag rectangle corners and arrow endpoints to resize. Arrows and rectangles show no selection decorations while drawing. Select a shape to reveal small gray resize handles, without an outline. Crop has explicit **Cancel / Crop** actions. Zoom and image dimensions stay in the bottom bar.
- **Scrolling Capture**. Select the scrolling content, leaving fixed headers, footers, and scrollbars outside the rectangle. A continuous native stream follows downward scrolling. Its floating controls stay visible while you use another app. Pause/Resume is available. Finish opens the editor. Intermediate animation or missing overlap is not committed; capture continues from the last good viewport when a valid overlap appears. If you scrolled too far, scroll back until that content is visible, then continue slowly.
- **Record Screen / Audio**. Enters area selection immediately, then shows a compact floating control bar near the selection. Screen, Area, and Window show the actual selected mode. Start hides setup while a click-through overlay frames the capture and dims everything outside it across displays. A small floating timer/Stop bar and the menu-bar Stop remain available; the overlays are excluded from the recording. Stop opens a larger resizable video editor, without reopening setup. Video previews show a decoded first frame and native playback controls; audio uses a small playback card. **Trim** removes unwanted time from the start and end using macOS controls. **Crop Frame** selects part of the picture with draggable corner handles and previews the result. **Reset** restores the original recording. Saving exports the selected time range, pixel crop and optional audio; the original draft remains unchanged. Full screen, selected area, or window. Resolution (native, 50%, or fit within 1920 × 1080) and **15/24/30/60 FPS** are directly visible in a compact settings card. Microphone, computer audio, and selfie camera start off. Enable the sources you want. The camera is mirrored into the selected corner and continues updating over a static desktop. Audio-only recording is also available.
- **Save**, **Save & Copy**, and **Save & Copy Path** immediately write to `~/Pictures/EVB Shot`, without a save dialog, then close the editor on success. The toolbar stays visually stable while saving; errors leave the editor open for retry. Change the folder in **Settings → Save location**. A previously chosen save folder is retained. **Save & Copy Path** also copies the absolute path wrapped in shell-safe single quotes, including escaped apostrophes; **Save & Copy** puts the full-resolution edited PNG on the clipboard, or copies the saved video/audio file as a native file attachment. **Save** leaves the clipboard alone. Repeated saves create separate files. Recorded video has an **Include audio** option so a silent copy can be saved without changing the compressed video frames.

macOS may ask for screen capture access. Microphone/camera permission is requested only when starting a recording with that source enabled. Drafts stay in `~/Library/Application Support/EVBShot/Drafts`; **Open Drafts Folder** reveals them, while **Open Captures Folder** opens the configured save location. Original captures remain unchanged while editing. Editable annotations and crop coordinates are kept separately in `~/Library/Application Support/EVBShot/Edits`, and restored when the same capture is reopened. Saving creates a flattened PNG with the chosen crop. Drafts are retained until you remove them.

The app appears in the Dock and ⌘Tab while an editor, recording setup, window picker, Settings, or About window is open. Closing those windows returns it to the menu bar. Reopened editable drafts can undo/redo each restored annotation and their crop. The menu has capture/recording icons, and About uses the native macOS panel with version, author, source, and library credits. The app icon source is `Resources/AppIcon.svg`; the bundled ICNS contains all macOS sizes with transparent corners.

During recording, the live selfie preview can be dragged within the capture and resized from its lower-right handle. Its position and size are applied to the saved video. The microphone follows the current macOS input device, including changes during capture; the recording bar shows its name and incoming level. A microphone that delivers no samples produces a visible warning instead of an unexplained silent result.

If camera or microphone access is denied, setup and the selected-area frame stay visible. Use **Open Camera Settings…** or **Open Microphone Settings…** to grant access, or explicitly record without the blocked input. Audio-only recording must retain at least one audio source. The controls hide only after the selected inputs pass permission checks.

## Full-resolution scrolling

The stitcher matches overlapping native viewports and appends original RGBA rows to a disk spool. Export streams PNG rows through zlib. The editor decodes original rows through libpng into a disk spool, displays bounded viewport tiles, and renders edited exports in strips. Viewports follow the display's physical pixel density, without a 2048-pixel cap, and refresh when moving between displays. **100%** maps one original image pixel to one display pixel. Fit uses native source pixels where possible, with bounded oversampling for very large captures. It never builds a whole long image in a GPU texture or giant bitmap, and never reduces output dimensions. Tall images open at Fit width; scroll to reach the entire capture, or choose Fit or a fixed zoom.

Memory depends on viewport size, not final image height. Disk space and the PNG format's dimension limit still apply; failure produces an error instead of resizing. This prototype supports vertical, downward scrolling. Repetitive/blank regions, animation, sticky content, or scrolling too far between samples can prevent reliable overlap detection. Keep meaningful overlap visible. It does not automate scrolling or remove sticky headers.

## Build

Requires macOS 15 or later and Xcode with Swift 6. The build script downloads the pinned libpng 1.6.59 source, verifies its SHA-256, and builds it statically for macOS 15. The resulting app needs no separately installed libraries. Sparkle 2.10.0 is pinned through SwiftPM and embedded, including its updater helpers. Both libraries retain their licenses in the app bundle. An existing compatible static build can be supplied through `LIBPNG_PREFIX`.

```sh
export TMPDIR="$(agent-tmpdir evb-shot-build)"
agent-env run --mem 2G -- bash scripts/build-app.sh
open "dist/EVB Shot.app"
```

Outside this workspace's agent environment, `bash scripts/build-app.sh` is sufficient for development. Its default signature is ad hoc. Set `EVBSHOT_SIGN_IDENTITY` to a local Developer ID identity for a stable signed build. The script includes the camera/audio entitlements for hardened runtime signing. Release packaging requires Developer ID signing and notarization credentials; it never falls back to an unsigned public release.

## Verify

Use a new empty output directory for each run:

```sh
"dist/EVB Shot.app/Contents/MacOS/EVBShot" --self-test "$PWD/.devkit/checks/run-1"
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

## Releases and hosting

GitHub Actions **CI** builds and exercises the native app on Apple Silicon macOS, including independent PNG verification. The **Release** workflow runs those checks before packaging and publishing a `v*` tag. `workflow_dispatch` builds the same archive as an Actions artifact without publishing.

To cut the next patch from a clean, verified `main`, update `docs/release-notes.md` with the change, land it, then run `bash scripts/cut-release.sh` (or pass `minor` / `major`). This increments both `CFBundleShortVersionString` and the monotonic `CFBundleVersion`, commits and publishes the version change, waits for exact-commit CI, and pushes its matching tag. For a version already bumped as part of a reviewed change, push its matching tag directly. A mismatched tag is rejected.

The tag pipeline signs with Developer ID, notarizes and staples the app, then creates the DMG and Sparkle ZIP from that same app. The DMG opens a compact 600 × 450 installer with a Retina background, the app on the left, and an arrow toward Applications on the right, matching EVB Viewer. Hash-pinned, build-only Python tools write Finder metadata without launching Finder. It also signs, notarizes, and staples the DMG. Before publication it downloads the uploaded artifacts, checks signatures and SHA-256 checksums, validates both tickets with Gatekeeper, mounts the DMG, verifies the installer geometry and both background resolutions, and confirms that its app matches the ZIP byte for byte. Only then does it publish the release and update feed. The landing page uses the stable DMG download name; Sparkle uses the ZIP.

Sparkle checks for updates automatically; **Check for Updates…** also checks on demand. **Settings** can disable automatic checks. Update archives and the feed are Ed25519-signed, verified before extraction, and served through GitHub Releases. Installing an update requires your action and waits until captures and editors have finished. Version 0.1.2 and earlier need one manual installation to gain the updater.

CI requires 20 consecutive native editor runs, independent PNG pixel checks, media export checks, and landing asset checks. Test output is unbuffered, and failed jobs report available native crash diagnostics. A failed run stops validation; there are no pass-on-retry checks.

For local packaging, set `EVBSHOT_SIGN_IDENTITY` and either `EVBSHOT_NOTARY_PROFILE` or the existing `APPLE_API_KEY` file path, `APPLE_API_KEY_ID`, and `APPLE_API_ISSUER`, then run `bash scripts/package-release.sh`. CI uses the same encrypted `CSC_LINK`, `CSC_KEY_PASSWORD`, `APPLE_API_KEY`, `APPLE_API_KEY_ID`, and `APPLE_API_ISSUER` secrets as the sibling EVB projects. `scripts/ci-package-release.sh` imports the certificate into an isolated temporary keychain and removes the keychain and private transfer files on exit. `scripts/verify-release.py dist/release` verifies the finished artifacts on macOS.

The separate Sparkle update-signing key uses the `com.evb.shot.updates` Keychain account locally and the repository Actions secret `SPARKLE_PRIVATE_KEY`. `bash scripts/build-sparkle-tools.sh` supplies the pinned signing tools. Do not commit private keys.

The [landing page](landing/README.md) is a separate static site. It is deployed manually to **evb-shot.vercel.app** using `scripts/deploy-landing.sh`; Git pushes do not deploy the website.

The visible name is **EVB Shot**. The executable/module `EVBShot`, bundle ID `com.evb.shot`, and internal draft/edit paths remain stable for compatibility. Existing configured save folders are preserved, including the previous default when it already exists.
