The first public prototype of **EVB Shot**, a small native macOS screenshot and recording tool.

- Capture an area, window, full screen, or a manually scrolling region at original resolution.
- Add text, arrows, and rectangles, crop, and use native undo/redo.
- Recording enters area selection directly, uses compact floating controls, hides setup during capture, and returns to a small corner preview on Stop.
- Record with visible resolution and 15/24/30/60 FPS controls. Optional microphone, computer audio, selfie camera, and audio-only mode.
- Save instantly to a configured folder. Save & Copy Path copies a shell-quoted absolute path and closes the editor.

**Install:** requires macOS 15 or later and an Apple Silicon Mac. Unzip and move **EVB Shot.app** to Applications. Open it, then use its viewfinder icon in the menu bar.

This prototype is ad-hoc signed and **not notarized**. On first launch, macOS may require **System Settings → Privacy & Security → Open Anyway**. Screen Recording permission is required for capture; camera and microphone are off by default and request access only when enabled.

Scrolling capture is manual and needs overlapping views; fixed headers, blank areas, and repeated content can prevent alignment. Hardware camera/microphone compatibility is still evolving. There are no automatic app updates yet; download a new release to update. Existing drafts and preferences are preserved.

`SHA256SUMS` verifies the downloadable archive. `build-receipt.json` identifies its exact source commit.
