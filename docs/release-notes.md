Separate save and clipboard actions for **EVB Shot 0.1.8**.

- **Save** immediately writes to the configured folder and leaves the clipboard alone.
- **Save & Copy** saves and copies the full-resolution edited image, or the saved video/audio file for pasting as media.
- **Save & Copy Path** saves and copies the full path wrapped in shell-safe single quotes.
- All three actions close the editor after success. Failed saves keep the editor and clipboard intact.
- Media copy uses the saved output, including annotations, trimming, frame crop and the Include audio choice. Recording files are copied through native macOS file clipboard formats without loading large recordings into memory.
- The Trim action follows AVKit readiness so it becomes available as soon as the recording supports trimming.
