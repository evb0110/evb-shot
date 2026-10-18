#!/usr/bin/env python3
"""Write Finder's installer layout without opening or automating Finder."""
import subprocess
import sys
import tempfile
from pathlib import Path

import dmgbuild

root = Path(__file__).resolve().parents[1]
app, destination = (Path(arg).resolve() for arg in sys.argv[1:])
with tempfile.TemporaryDirectory(prefix='dmg-art-', dir=root / '.devkit') as directory:
    art = Path(directory)
    subprocess.run(['swift', str(root / 'scripts/generate-dmg-background.swift'), str(art)], check=True)
    destination.unlink(missing_ok=True)
    dmgbuild.build_dmg(str(destination), 'EVB Shot', settings={
        'format': 'ULFO', 'filesystem': 'APFS',
        'files': [str(app)], 'symlinks': {'Applications': '/Applications'},
        'hide_extensions': ['EVB Shot.app'],
        'hide': ['.background.tiff'],
        'background': str(art / 'background.png'),
        'window_rect': ((200, 160), (600, 450)),
        'default_view': 'icon-view', 'icon_size': 128, 'text_size': 16,
        'icon_locations': {'EVB Shot.app': (160, 185), 'Applications': (440, 185)},
        'show_status_bar': False, 'show_tab_view': False,
        'show_toolbar': False, 'show_pathbar': False, 'show_sidebar': False,
        'include_icon_view_settings': True,
    })
