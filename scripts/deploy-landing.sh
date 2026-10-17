#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/verify-landing.py
project=evb-shot
scope=eugenes-projects-23020cc6
vercel project inspect "$project" --scope "$scope"
python3 - "$scope" <<'PY'
import os, shutil, subprocess, sys, tempfile
from pathlib import Path
with tempfile.TemporaryDirectory(prefix='evb-shot-landing-', dir=os.environ.get('TMPDIR', '.devkit')) as directory:
    stage = Path(directory)
    for name in ['index.html', 'style.css', 'icon.svg', 'editor.png', 'robots.txt', 'sitemap.xml', 'vercel.json']:
        shutil.copy2(Path('landing') / name, stage / name)
    shutil.copytree('landing/fonts', stage / 'fonts')
    (stage / '.vercel').mkdir()
    shutil.copy2('landing/.vercel/project.json', stage / '.vercel/project.json')
    environment = dict(os.environ, GIT_CEILING_DIRECTORIES=str(stage))
    subprocess.run(['vercel', 'deploy', '--cwd', str(stage), '--scope', sys.argv[1], '--prod', '--yes'], env=environment, check=True)
PY
