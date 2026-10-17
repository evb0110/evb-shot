# EVB Shot landing

Static HTML/CSS, with local fonts and a real native editor rendering over a generated sample. No build dependencies or server. The design follows EVB Player's paper palette, Inter typography, and download card.

The stable GitHub `releases/latest` links always resolve to the current public release without a redeploy. The release workflow keeps the archive name `EVB-Shot-macOS-arm64.zip` stable.

## Regenerate the editor image

Build the app, then run its offscreen renderer with an empty output directory:

```sh
"dist/EVB Shot.app/Contents/MacOS/EVBShot" --landing-preview "$PWD/.devkit/landing-preview"
cp .devkit/landing-preview/editor-content.png landing/editor.png
python3 scripts/verify-landing.py
```

## Manual deployment

Project: `evb-shot`, team: `eugenes-projects-23020cc6`, production: <https://evb-shot.vercel.app>.

```sh
vercel link --cwd landing --project evb-shot --scope eugenes-projects-23020cc6
vercel project inspect evb-shot --scope eugenes-projects-23020cc6
bash scripts/deploy-landing.sh
```

The deployment script uploads only this directory through a temporary source copy without Git metadata or private local files. No Git integration or automatic Vercel deployment is configured.
