# Recording overlay reference and implementation

Reference: CleanShot X 5.0.1, arm64 SHA-256 `f6c3586d7fd46f29c48bed2046b40ef1a8acb8336579b891d5925039294fbb09`.

REA 6.5.0 `inspect_native_dispatch_metadata` evidence `ev_511f80f500d14f35c18ea60063b9f510fb8771ff7c6824149c8dcbc7e10fb9b1` confirms `RecorderOverlay` at `0x100951560`, derived from `FSOverlay` at `0x10095ac30`; the recorder overlay owns separate settings/controls child windows. The base overlay retains `curtainView`, `area`, and `screenRect`. Relevant selectors include `rectangleChanged`, `rectangleFullStateChanged`, and `close`. These are shipped-artifact metadata facts, not recovered original source or runtime proof. Raw evidence is retained in `.devkit/recording-overlay/rea-evidence.json`.

A new focused Ghidra decompilation request for `0x100018228` timed out after 330 seconds during whole-program analysis, before producing pseudocode. No new control-flow claim relies on that attempt. The persistent frame and outside dimming are also the user-reported CleanShot behavior and the requested acceptance contract.

EVB Shot follows the separation: configuration hides at Start; independent nonactivating curtain windows stay on every display, with a transparent recording region and a neutral frame. The curtains ignore input. A separate compact timer/Stop panel remains usable. Window recording tracks the selected window bounds. Full-screen recording frames that display and dims other displays. Audio-only recording uses the menu-bar controls without a visual curtain. Stop, failure, and close remove recording chrome.

ScreenCaptureKit display filters exclude this process; window capture uses a desktop-independent window filter. Recording UI remains native and is not composited into encoded frames. Hidden native tests exercise actual Start and the overlay Stop button, verify display coverage and coordinate mapping, and assert overlay cleanup. A native drawing test checks transparent inside pixels and 38 percent black outside pixels.

Updater reference: EVB Viewer uses `electron-updater`, GitHub release metadata, code-signature checks, and a patch/minor/major release command. EVB Shot uses native Sparkle 2.10.0 with signed archives and signed feeds, pre-extraction signature verification, a settings checkbox, manual Check for Updates, and active-work relaunch deferral. Apple signing/notarization remains separate from Sparkle signing.
