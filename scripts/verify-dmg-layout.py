#!/usr/bin/env python3
"""Check Finder's shipped layout and the real multi-resolution background."""
import re
import subprocess
import sys
from pathlib import Path

from ds_store import DSStore
from mac_alias import Alias

mount = Path(sys.argv[1]).resolve()
with DSStore.open(str(mount / '.DS_Store'), 'r') as store:
    assert store['EVB Shot.app']['Iloc'] == (160, 185), 'App must be on the left'
    assert store['Applications']['Iloc'] == (440, 185), 'Applications must be on the right'
    assert store['.']['icvl'] == (b'type', b'icnv'), 'Finder must open in icon view'
    window, icons = store['.']['bwsp'], store['.']['icvp']
    assert re.findall(r'\d+', window['WindowBounds'])[-2:] == ['600', '450']
    assert not any(window[key] for key in ['ShowStatusBar', 'ShowTabView', 'ShowToolbar', 'ShowPathbar', 'ShowSidebar'])
    assert icons['iconSize'] == 128 and icons['textSize'] == 16 and icons['arrangeBy'] == 'none'
    assert icons['backgroundType'] == 2, 'Finder background must be an image'
    alias = Alias.from_bytes(icons['backgroundImageAlias'])
    assert alias.target.filename == '.background.tiff', 'Background alias must point inside this volume'
background = mount / '.background.tiff'
assert background.is_file()
# AppKit reads both TIFF representations, including their point sizes. A 2x
# raster alone would make Finder open a huge window instead of rendering Retina.
subprocess.run(['swift', '-e', r'''import AppKit
let image = NSImage(contentsOfFile:CommandLine.arguments[1])!
let sizes = Set(image.representations.map { "\($0.pixelsWide)x\($0.pixelsHigh):\(Int($0.size.width))x\(Int($0.size.height))" })
precondition(sizes == ["600x450:600x450", "1200x900:600x450"], "Missing 1x/2x TIFF representations: \(sizes)")
print("PASS Retina DMG background: \(sizes.sorted())")
''', str(background)], check=True)
print('PASS compact Finder installer, hidden chrome, 128-point app and Applications icons, left-to-right arrow layout')
