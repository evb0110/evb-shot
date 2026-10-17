# CleanShot X 5.0.1: architecture investigation

Investigation date: 2026-10-17. Target: `/Applications/CleanShot X.app`.

CleanShot is a native capture application with several distinct systems: selection overlays, screenshot capture, a streaming recorder, an editable screenshot canvas, an editable video project, recent-media management, and optional cloud delivery. The useful pattern for evb-shot is the separation between acquiring media, retaining an editable result, and deciding what to do with that result.

This report distinguishes **observed artifact facts**, **implementation inferences**, and **proposed evb-shot design**. Static metadata and decompiled code do not establish that a workflow was executed successfully.

## Target and evidence

- Bundle identifier: `pl.maketheweb.cleanshotx`; version/build: `5.0.1`.
- Menu-bar application: `LSUIElement=true`; minimum macOS version: 13.0.
- Universal executable: x86_64 and arm64. Investigation selected arm64.
- Executable SHA-256: `4876cf9206b9b051afd6a6d4e6adbae2347fac891ceaaae2821b0c30c8daf167`.
- arm64 slice SHA-256: `f6c3586d7fd46f29c48bed2046b40ef1a8acb8336579b891d5925039294fbb09`.
- The slice is byte-identical to the original range starting at file offset 12,337,152, length 11,347,216. See `slice-receipt.json`.
- REA 6.5.0 was connected over MCP; the live server advertised 207 tools. Its registration was also saved in `~/.codex/config.toml`, with backups.
- Raw evidence and supporting inventories are retained in [the evidence directory](../../.devkit/cleanshot-rea/). That directory has a `.keep` marker.

REA evidence records are identified in the ledger below. Supplementary `nm`, `strings`, `otool`, plist parsing, and slice extraction are shell observations, not REA evidence.

## Application shell and entry points

**Observed.** The binary contains Swift application classes backed by AppKit objects, with SwiftUI and Combine also linked. `AppDelegate` owns a `StatusMenuController`. The compiled `MainMenu.nib` connects capture, recording, OCR, history, annotation, pinning, and preferences actions to its controller. This is a native application, rather than an Electron package.

Some recovered arm64 implementation entry points:

| Entry | Address |
|---|---|
| `StatusMenuController.areaClicked:` | `0x1000f0980` |
| `StatusMenuController.windowClicked:` | `0x1000f09e0` |
| `StatusMenuController.scrollingCaptureClicked:` | `0x1000f09ec` |
| `StatusMenuController.recordVideoClicked:` | `0x1000f0a30` |
| `StatusMenuController.captureTextClicked:` | `0x1000f0d00` |
| `AppDelegate.application:openURLs:` | `0x1001ea5fc` |
| `Motion.stream:didOutputSampleBuffer:ofType:` | `0x100033c28` |
| `ScrollingGrabber.captureAndCompare` | `0x1000e2d70` |

These addresses come from decoded implementation metadata, not protocol method declarations. See `dispatch-data.json`, `app-classes.json`, and `mainmenu-nodes.json`.

## Screenshot selection and capture

**Observed.** `ScreenCapture` retains `task`, `lastCaptureRect`, modifier-key state, and the last screenshot action. `OneOverlay` retains a frozen image, display ID, screen scale, selection controls, and a self-timer overlay. Dedicated settings cover Retina downscaling, conversion to sRGB, cursor visibility, freezing, crosshairs, magnification, window shadow, padding, and background presets.

The executable imports `CGWindowListCopyWindowInfo` and `CGWindowListCreateImage`, contains a `ScreenCaptureKit` abstraction, and contains `/usr/sbin/screencapture`. These establish several available capture mechanisms. Their presence alone does not tell us which mechanism every screenshot mode uses.

**Inference.** Selection is a separate interaction layer: resolve the display/window/rectangle, obtain pixels, then route the result to configured actions. Remembering a rectangle is application state rather than a property of the final PNG. Display coordinates and backing-pixel scale have to remain explicit throughout this flow.

## Screen recording and audio

**Observed.** `ScreenRecorder` is the application-level coordinator. It retains the recording overlay, recorder, status, destination, GIF/Studio flags, cursor and keyboard overlays, writer-completion state, and periodic Studio-saving state.

Its lower-level `Motion` class conforms to `SCStreamOutput`, `SCStreamDelegate`, `AVCaptureAudioDataOutputSampleBufferDelegate`, and `AVAssetWriterDelegate`. Its retained state includes:

- `stream`, `assetWriter`, `videoInputWriter`, `systemAudioInputWriter`, and `microphoneAudioInputWriter`.
- Separate video, audio, and microphone buffer queues.
- Start times, last presentation timestamps for each stream, a time offset, pause state, and an invalid-timestamp count.
- Microphone device/session state, disconnect warnings, audio power meters, and completion/error/pause/resume callbacks.
- Screen, excluded window IDs, crop rectangle, output size, FPS, and cursor configuration.

**Inference.** ScreenCaptureKit supplies screen/system-audio samples, an AVFoundation capture session supplies microphone samples, and AVAssetWriter writes the media. The timestamp and offset fields support synchronization and pause/resume handling. Their existence does not establish the exact offset arithmetic or all stop/failure ordering.

`FLCameraRecorder` is separate and retains its own capture session, video output, asset writer/input, queue, first-frame lock, timestamps, and pause offset. `AudioMixer` is a separate component with microphone/system-audio volumes and export sessions. The architecture accommodates independent audio tracks and a separate camera recording.

The bundle ships `gifsicle` and `cwebp`; `ScreenRecorder` retains a `gifsicle` reference. GIF optimization is therefore an additional encoding stage, not a fundamental screen-capture API.

## Studio mode: retain events as editable data

**Observed.** `FLDocument` retains `project`, `meta`, `videoURL`, `cameraURL`, `capturedWallpaper`, and `projectURL`. `FLProject` retains:

- Clips and zooms.
- Window, text, mouse, and keyboard events.
- Cursor appearance, smoothing/movement style, hiding rules, and click/press effects.
- Camera placement, shape, scale, mirroring, and timing offset.
- Background, padding, shadow, corner radius, aspect ratio, motion blur, and audio configuration.

`FLMouseTracker` has separate cursor/window polling, event collections, recording time offsets, pixel scales, window identities, and text-field/caret tracking. `FLKeyboardTracker` has event collection and recording-time state. `FLVideoEncoder` has reader/writer inputs, a project, render properties, cancellation state, and a passthrough-export path.

**Inference.** Studio keeps source media plus an event/edit model, then renders a presentation from them. That enables later changes to cursor effects, camera placement, backgrounds, and zooms. This is a considerably larger subsystem than a recorder that directly produces an MP4.

The exact event schemas, interpolation, automatic zoom heuristics, frame compositor, and export-performance characteristics were not reconstructed.

## Scrolling capture

**Observed.** `ScrollingGrabber` retains `shotA`, `shotB`, `lastComparedShot`, `lastMatch`, `mergedImage`, `headerHeight`, `heightDiff`, failure counts, orientation, capture rectangle, window ID, and preview state. Subclasses include `AutomaticScrollingGrabber`, `VisionScrollingGrabber`, and `ClassicScrollingGrabber`. The automatic variant adds a match collection, final match, and pause state. The binary imports `VNTranslationalImageRegistrationRequest`.

**Inference.** The feature captures successive overlapping viewport images, estimates their relative displacement, and merges newly revealed content. Vision supplies a plausible registration path; a separate classic path also exists. This is raster stitching, rather than a browser-only full-page screenshot implementation.

Packaged onboarding warns about animations, mixed scroll directions, scrolling too fast, reverse scrolling, and including fixed elements/scrollbars in the selection. Those warnings describe intended operating constraints, not failures reproduced in this investigation.

Exact matching thresholds, seam selection, fallback dispatch, duplicate-frame rejection, and termination rules remain unknown.

## Screenshot annotation and editable documents

**Observed.** `AnnotateDocument` separates metadata, a serializable document, preview bitmap, thumbnail bitmap, and project URL. `AnnotateHistory` retains a session, history points, and a current index. Annotation types include text, arrows, image objects, drawing, counters, spotlighting, and pixelation.

For example, `ANText` retains text, style, font size, color, position, width, anchors, and rendering layers. `ANArrow` retains control points, color, thickness, style, and direction. This is an object model with persistent editing attributes, not only a flattened bitmap.

The bundle declares `.cleanshot` as an editable document and `.cleanshotvideo` as a package conforming to `com.apple.package`. It contains serialization/archive dependencies and an `NSKeyedArchiver` compatibility marker. No saved document was decoded, so the exact serialization/container layout is not established.

## Quick Access, pinning, history, and output

**Observed.** `Media` retains permanent and temporary URLs, project URL, a URL bookmark, creation date, application metadata, cloud metadata, and cached thumbnail/duration. `Popup` owns thumbnail and drag/hover/animation state; Quick Access settings govern placement, display switching, dismissal, drag completion, upload completion, and saving behavior.

History has its own controller, collection items, filtering, restoration, and deletion actions. `FloatingOverlayController` is separate from the Quick Access popup. `IconOverlayController` retains overlays and a saved state for desktop-icon presentation.

**Inference.** A capture becomes a media object that can feed several independent destinations: clipboard, file, editor, floating reference, history, or upload. Keeping temporary media ownership separate from popup lifetime makes restore and drag workflows possible. The exact cleanup/retention algorithm and persistent history schema were not inspected.

## OCR and automation

**Observed.** The app imports Vision text-recognition classes and retains supported-language and warm-up state in `OCR`. Settings include language selection/detection, line breaks, and link detection. This strongly supports an on-device Vision implementation; no OCR accuracy or language coverage was measured.

The `cleanshot` URL scheme is declared in the plist; `URLEventObserver` and the app delegate supply corresponding entry points. Packaged prompt text describes an opt-in decision before another app can control captures. The current [official URL API](https://cleanshot.com/docs-api) documents area/fullscreen/window capture, scrolling capture, OCR, opening annotation, overlays, history, settings, recording commands, and post-capture actions. Its coordinate examples use a lower-left origin. Public documentation is a contract reference, not a runtime receipt for this installation.

## Optional services and bundle integration

**Observed.** The app ships annotation and pinning share extensions, Quick Look preview and thumbnail extensions, and a login helper. Its framework/dependency inventory includes Sparkle, Sentry, LetsMove, Alamofire, CryptoSwift, SDWebImage, ZIPFoundation, SwiftyJSON, Lava hotkeys, and KeychainAccess.

`CloudAPI` has sessions, upload requests, uploaded-media state, tags, and user state; packaged text describes chunk uploads. These are separate delivery/account concerns. No cloud credentials, user captures, account traffic, or license behavior was inspected.

## Selected native-code verification

The focused Ghidra pass completed and produced twelve retained evidence records in `evidence-native.json`. It used a 512 MiB Java heap. The installed app was not executed by the disassembler.

- **Recording dispatch is code-backed.** The stream callback at `0x100033c28` checks sample validity and dispatches to `0x100032614`. That implementation checks pause/stopping/ended state, handles presentation timestamps and time offsets, selects the separate writer inputs, and updates per-stream timestamp state. Calls through recovered Objective-C stubs identify `isReadyForMoreMediaData`, `startSessionAtSourceTime:`, and `appendSampleBuffer:`. This confirms the sample-to-writer path beyond the earlier metadata inference. See `recording-callback.json`, `recording-dispatch.json`, and the three `writer-*-stub.json` receipts.
- **Scrolling frame acquisition is code-backed.** The `captureAndCompare` entry reaches `0x1000e2cc8`, which calls `CGWindowListCreateImage`, constructs an `NSBitmapImageRep`, stores it, and dispatches onward through a virtual method. This confirms raster acquisition in this path. It does not recover the matching/merge algorithm. See `scroll-capture-implementation.json`.
- **The general screenshot backend remains qualified.** The screenshot-menu callback was decompiled, and the `/usr/sbin/screencapture` literal was located at `0x1007cef40`. Its cross-reference query returned no defined references under the reduced profile. That does not establish that the command is unused, nor establish which screenshot modes invoke it. The scrolling path above should not be generalized to every screenshot mode.

Pseudocode has imperfect Swift calling-convention/type recovery and Objective-C trampoline warnings. The verified API names and control/state accesses support these bounded conclusions; they do not establish original source, exact synchronization arithmetic, or runtime reliability. Read each receipt's limitations. Human-readable projections are provided under `pseudocode/`.

## Implications for evb-shot

The following are proposed design choices, not claims about CleanShot source code.

1. Use a native capture core. Swift, AppKit overlays, ScreenCaptureKit, AVFoundation, and Vision fit the observed macOS integration. SwiftUI can serve settings and ordinary panels. A different frontend can still call a native core, but it adds an integration boundary that the current task does not require.
2. Make capture a service with explicit states: idle, selecting, preparing, capturing/recording, finalizing, ready, failed, or cancelled. A recorder should emit one terminal result after its writers finalize. Popup dismissal should not determine whether media survives.
3. Model a capture independently of its destinations. Give it an ID, source context, display/rectangle/pixel scale, timestamps, file references, preview, and optional editable project. Implement clipboard, save, editor, history, and sharing as consumers.
4. For a small first version, establish still capture, straightforward MP4 recording, dependable finalization, basic annotation, and local history before adding the Studio renderer or scrolling stitcher. The user's actual feature subset is still to be selected.
5. Retain an editable annotation model and the original image. Add raw recording/event projects only if later editing of cursor/zoom/camera effects is part of the intended subset.
6. Treat automation as a first-class interface. A local CLI or MCP API could expose explicit display/window/rectangle selection, cursor/audio choices, destination, capture IDs, asynchronous completion, and machine-readable errors. This would be a useful customization area beyond a URL that merely launches a command.
7. For development evidence workflows, candidate additions include an app/window allowlist, reproducible capture presets, a source-context sidecar, redaction before export, and a manifest linking related screenshots/recordings. These are product ideas, not assumed requirements.

Apple's [ScreenCaptureKit documentation](https://developer.apple.com/documentation/screencapturekit) describes content filtering and screen/audio sample delivery. Use the [official capture sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos) when implementing; do not infer current API availability solely from CleanShot's compatibility code.

Useful eventual acceptance scenarios include mixed-DPI displays, negative screen coordinates, permission denial, cancelled selection, repeated stop, audio-device removal, sleep/display changes, low disk space, and export failure while retaining source media. No evb-shot implementation or test suite was created in this research task.

## Scope and remaining uncertainty

| Question | Result |
|---|---|
| App identity, architecture, integrations | Answered from shipped metadata and resources |
| Major subsystems and retained state | Answered within decoded metadata coverage |
| Screenshot/recording implementation entry points | Located; selected recording/writer and scrolling acquisition calls verified in native code |
| Scrolling-capture approach | Strong inference; exact stitcher internals unresolved |
| Annotation and Studio data separation | Observed; serialized schemas unresolved |
| Automation surface | Artifact declarations plus public documentation |
| Real capture/recording correctness, latency, quality | Not measured in this investigation |

REA's metadata reader reached its 20,000-record budget. Objective-C metadata includes duplicate class/metaclass records and unresolved ivar offsets; class/field names remain useful, but no offsets were invented. Swift vtable/conformance recovery was unavailable in that bounded result. The NIB decoder also reports incomplete coverage for some private archive fields. See the original limitations in the evidence bundle.

Hopper was installed and its demo mode initialized, but its bridge was denied macOS Apple Events/Automation permission. Ghidra was installed and configured as the alternative engine. The default Ghidra import exceeded its 330-second startup deadline. A focused profile excludes whole-program constant propagation, decompiler switch analysis, Objective-C message analysis, and Swift demangling. The corresponding computed references, switches, message targets, and Swift names may be incomplete. These profile overrides are specific to this investigation; the persistent MCP configuration defaults to Ghidra without disabling analyzers. The installed CleanShot binary and its existing user data were not modified.

## Evidence ledger

| ID | Observation | Local receipt |
|---|---|---|
| `ev_b87ccbc560fa596a9531c522599008b9dd884bfef9b57720a4fae0a2b274464b` | Mach-O slices, dependencies, imports, build information | `evidence-inventory.json` |
| `ev_ae953fdba74a4786ef3f6ca4923c7852228efe41add8e0ec7b43c6b920161139` | Main application plist | `info-plist.json` |
| `ev_9e3df4926726ea38f694a76a7f74d77c73042d0d624df484e5387e7879d2e01b` | Bundle inventory, manifest `agm_e0704f8462c8ead08a6e1fa307d06a4c31a9da195e83ed370f1e1cc56132d9b1` | `evidence-inventory.json` |
| `ev_b05b005b787dfff96e0602f74c17cc75dc8e7478f1a0e192f6ca0e0d30bf7046` | Compiled NIB objects and connections | `evidence-inventory.json`, `mainmenu-nodes.json` |
| `ev_feb497786c87d585f9d3e971a16682922fc11146adc02858cf548af50b5e70d8` | Native dispatch, class, method, and ivar metadata | `evidence-inventory.json`, `dispatch-data.json` |
| `ev_2926a0604286042eb36ce29584b9418ba452fa51fbba139d7509f05c53c79f10` | Recording sample dispatcher | `evidence-native.json`, `recording-dispatch.json` |
| `ev_82a98dba3984903bc9fce4af94d3e1d3d1cb3bd814168ff12b950f0638e069f2` | Writer append selector stub | `writer-append-stub.json` |
| `ev_a85c9ac232fe5b76f33d38d165d2661b231a8a40f7aac02473ba249053bacb4b` | Writer readiness selector stub | `writer-readiness-stub.json` |
| `ev_a88e2462ac2e6d04be5f9482ed0617e334c13fd3feee3ad567f5487ac46972ce` | Writer source-time session selector stub | `writer-start-session-stub.json` |
| `ev_1d2b087349e274cf684d5cecce18f55c13bd157f428cd1c34499874206c5015c` | Scrolling capture calls CoreGraphics image capture | `scroll-capture-implementation.json` |

`app-classes.json` and `feature-classes.json` are convenient filtered projections of the dispatch evidence. They are not additional independent observations. Raw evidence has the original target digests, provider identities, locations, and limitations.

Public references: [CleanShot features](https://cleanshot.com/features), [CleanShot URL API](https://cleanshot.com/docs-api), [REA Ghidra provider semantics](https://github.com/morluto/rea/blob/main/docs/ghidra-provider.md).
