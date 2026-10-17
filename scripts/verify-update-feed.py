#!/usr/bin/env python3
"""Verify that published update metadata describes exactly the packaged bundle."""
import base64
import plistlib
import sys
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path

def verify(folder):
    archive = folder / 'EVB-Shot-macOS-arm64.zip'
    with zipfile.ZipFile(archive) as bundle:
        info = plistlib.loads(bundle.read('EVB Shot.app/Contents/Info.plist'))
        names = bundle.namelist()
        assert 'EVB Shot.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle' in names
    version = info['CFBundleShortVersionString']
    assert len(base64.b64decode(info['SUPublicEDKey'], validate=True)) == 32
    assert info['SUVerifyUpdateBeforeExtraction'] and info['SURequireSignedFeed']
    assert info['SUFeedURL'] == 'https://github.com/evb0110/evb-shot/releases/latest/download/appcast.xml'
    data = (folder / 'appcast.xml').read_text()
    assert 'edSignature=' in data, 'Feed must be signed'
    root = ET.fromstring(data)
    items = root.findall('channel/item')
    assert len(items) == 1, 'Publish exactly one complete release, never stale scratch archives'
    item = items[0]
    ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
    assert item.findtext(ns + 'version') == info['CFBundleVersion']
    assert item.findtext(ns + 'shortVersionString') == version
    enclosure = item.find('enclosure')
    assert enclosure is not None
    assert enclosure.attrib['url'] == f'https://github.com/evb0110/evb-shot/releases/download/v{version}/{archive.name}'
    assert int(enclosure.attrib['length']) == archive.stat().st_size
    assert len(base64.b64decode(enclosure.attrib[ns + 'edSignature'], validate=True)) == 64
    print(f'PASS signed feed metadata, immutable v{version} download, bundled Sparkle, build {info["CFBundleVersion"]}')

if __name__ == '__main__':
    verify(Path(sys.argv[1]))
