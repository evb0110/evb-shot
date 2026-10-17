Recording boundaries and automatic updates for **EVB Shot 0.1.3**.

- Recording keeps a clear capture frame and dims the surrounding desktop on every display. The overlay passes clicks through and is excluded from the video.
- A small floating timer and Stop control stays available while setup remains hidden. Stop removes the overlay and opens the compact corner preview.
- Sparkle checks for updates automatically. Use **Check for Updates…** in the menu or Settings; automatic checks can be turned off. Update installation waits for captures and editors to finish.
- Update archives and the feed are Ed25519-signed and checked before extraction. Releases bump the patch and build numbers together.
- Existing capture, full-resolution scrolling, annotation, crop, undo/redo, recording audio/camera controls, and immediate save actions are retained.

**Install:** macOS 15+ on Apple Silicon. Unzip **EVB Shot.app** into Applications. Version 0.1.2 and earlier need this one manual update to gain automatic update checks.

The public prototype is ad-hoc signed and not notarized. First launch may require **System Settings → Privacy & Security → Open Anyway**. Apple screen/camera/microphone permissions still apply.

`SHA256SUMS` covers the archive, source receipt, and update feed. Existing drafts and preferences are preserved.
