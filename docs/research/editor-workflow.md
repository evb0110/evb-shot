# Screenshot editor reference

Date: 2026-10-17. The [CleanShot binary investigation](cleanshot-x-architecture.md) recovered `AnnotateDocument`, `AnnotateHistory`, `ANText`, and `ANArrow` metadata. These show separate source/preview data, editable objects, and history. They do not establish exact mouse interactions or provide reusable editor source.

The official [screenshots page](https://cleanshot.com/screenshots) supplies [markup](https://cleanshot.com/video/screenshots/markup.mp4) and [crop](https://cleanshot.com/video/screenshots/crop.mp4) demonstrations. Frames inspected locally show:

- An image-first window with annotation tools and style controls in a single top toolbar, saving on the right, and zoom along the bottom.
- A crop mode with an outside dimming mask, handles, a thirds grid, and explicit Cancel / Crop actions.
- Text, arrow, and shape annotations drawn over the image.

The installed application's editor could not be inspected reliably through the available native accessibility surface. The interactions above are grounded in the official demonstrations; the recovered metadata informed the original/vector/history separation. Reference clips and inspected frames are retained locally in `.devkit/editor/reference/`.

EVBShot follows that workflow using native AppKit controls and SF Symbols. Its smaller tool set is Select, Rectangle, Arrow, Text, and Crop. It keeps original pixel coordinates, native UndoManager history, and an editable sidecar; viewport tiles and strip exports allow the same editor to handle very tall scrolling captures. libpng supplies the row decoder. Proprietary executable code and artwork are not embedded.

## Follow-up controls and window behavior

The retained CleanShot class inventory also identifies `Annotate.performKeyEquivalent:` at `0x1000d74f8`, `SingleWindow.performKeyEquivalent:` at `0x10019a614`, `ANGenericLine.startAnchorPoint/endAnchorPoint`, and `ANColorPickerToggleButton.chevronImage`. `Flow` retains a `dockSessionID`; `FLDockProgressTracker` retains sessions. These observations support window-local commands, line endpoint controls, a dedicated color-picker button, and tracking active workspaces. They do not establish the exact Dock activation implementation. A new Ghidra procedure search timed out after 330 seconds; its session was closed. The earlier retained metadata and official demonstrations remain the reference.

EVBShot now dispatches the two undo/redo key equivalents in the editor window, preserving native text-field undo. Arrow selection draws endpoint handles only. Its color button draws a centered chevron and opens the system color panel. AppKit's regular activation policy applies while a workspace window exists, with accessory mode used when only the status menu remains.

EVB Viewer's local `electron/bootstrap/runInitSequence.ts` configures the standard macOS About panel with app name/version, Beta, author, copyright and icon. EVBShot uses the corresponding native `orderFrontStandardAboutPanel` path, with its own identity and library/source links. Its recording controls use a compact native settings card, and status-menu entries use matching SF Symbols.
