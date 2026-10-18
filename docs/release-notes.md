Recording permission recovery for **EVB Shot 0.1.6**.

- Recording controls and the selected-area frame stay visible while camera or microphone access is checked. A denied permission no longer makes setup disappear and reappear.
- **Open Camera Settings…** and **Open Microphone Settings…** go directly to the relevant macOS privacy category.
- **Record Without Camera** starts the selected screen recording with the camera off. Microphone denial offers the equivalent action when another valid recording source remains; audio-only recording cannot silently lose its only audio source.
- Denied retries do not repeatedly request permission. Camera and microphone remain off by default.
- The selected area is retained after an error, including its preview frame.
- The app and DMG remain Developer ID signed, Apple notarized, and stapled.
- Sparkle updates use a ZIP containing the identical signed, notarized app. Update archives and the feed retain their separate Ed25519 signatures.
- Release publication requires passing Gatekeeper checks on the final downloaded DMG and ZIP, valid notarization tickets, matching app contents, and SHA-256 checksums.
- Recording dimming and boundaries, full-resolution scrolling, annotations, crop, undo/redo, Retina rendering, installer artwork, and immediate save actions are retained.

**Install:** macOS 15+ on Apple Silicon. Open **EVB-Shot-macOS-arm64.dmg** and drag **EVB Shot** to Applications. Existing 0.1.3 and newer installations can use **Check for Updates…**; 0.1.2 and earlier need one manual installation.

Apple screen/camera/microphone permissions still apply. Existing drafts and preferences are preserved.

`SHA256SUMS` covers the DMG, update ZIP, source receipt, and update feed.
