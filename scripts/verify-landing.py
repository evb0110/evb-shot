#!/usr/bin/env python3
"""Check the static deploy tree and stable release target without dependencies."""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlsplit
import plistlib

root = Path(__file__).resolve().parents[1]
class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []
        self.h1 = 0
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == 'h1': self.h1 += 1
        for key in ('src', 'href'):
            if key in attrs: self.links.append(attrs[key])

page = Page()
html = (root/'landing/index.html').read_text()
page.feed(html)
assert page.h1 == 1
assert 'EVBShot' not in html
assert 'https://github.com/evb0110/evb-shot/releases/latest/download/EVB-Shot-macOS-arm64.zip' in page.links
assert 'https://github.com/evb0110/evb-shot/releases/latest' in page.links
for link in page.links:
    if link.startswith('/'):
        target = root/'landing'/urlsplit(link).path.lstrip('/')
        assert target.exists(), f'Missing landing asset: {target}'
with (root/'Resources/Info.plist').open('rb') as stream:
    info = plistlib.load(stream)
assert info['CFBundleName'] == info['CFBundleDisplayName'] == 'EVB Shot'
assert info['CFBundleIdentifier'] == 'com.evb.shot'
print('PASS branding, local assets, and stable latest-release download links')
