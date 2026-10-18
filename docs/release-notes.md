Installer and annotation color improvements for **EVB Shot 0.1.5**.

- The DMG opens a compact installer matching EVB Viewer, with a Retina background and an arrow from EVB Shot to Applications.
- The annotation color button opens a palette directly beneath the toolbar. Twelve useful colors replace the empty saved-color grid; **More Colors…** opens the optional system picker beside the editor on the same display.
- The app and DMG remain Developer ID signed, Apple notarized, and stapled.
- Sparkle updates use a ZIP containing the identical signed, notarized app. Update archives and the feed retain their separate Ed25519 signatures.
- Release publication requires passing Gatekeeper checks on the final downloaded DMG and ZIP, valid notarization tickets, matching app contents, and SHA-256 checksums.
- Recording frames and dimming, full-resolution scrolling, annotations, crop, undo/redo, audio/camera controls, and immediate save actions are unchanged.

**Install:** macOS 15+ on Apple Silicon. Open **EVB-Shot-macOS-arm64.dmg** and drag **EVB Shot** to Applications. Existing 0.1.3 and newer installations can use **Check for Updates…**; 0.1.2 and earlier need one manual installation.

Apple screen/camera/microphone permissions still apply. Existing drafts and preferences are preserved.

`SHA256SUMS` covers the DMG, update ZIP, source receipt, and update feed.
