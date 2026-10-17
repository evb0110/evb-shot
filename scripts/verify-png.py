#!/usr/bin/env python3
"""Independently decode our PNG chunks using Python's standard library.

Verify CRCs, native dimensions and every original RGBA byte, streaming in rows.
"""
import hashlib
import pathlib
import struct
import sys
import zlib


def verify(png, raw, dimensions):
    digest = hashlib.sha256()
    expected = hashlib.sha256()
    row_size = dimensions[0] * 4 + 1
    pending = bytearray()
    rows = 0
    decoder = zlib.decompressobj()
    with png.open('rb') as image, raw.open('rb') as source:
        assert image.read(8) == b'\x89PNG\r\n\x1a\n'
        while True:
            size = struct.unpack('>I', image.read(4))[0]
            kind = image.read(4)
            data = image.read(size)
            crc = struct.unpack('>I', image.read(4))[0]
            assert zlib.crc32(kind + data) & 0xffffffff == crc, f'{kind} CRC'
            if kind == b'IHDR':
                w, h, depth, color, compression, filtering, interlace = struct.unpack('>IIBBBBB', data)
                assert (w, h) == dimensions and (depth, color, compression, filtering, interlace) == (8, 6, 0, 0, 0)
            if kind == b'IDAT':
                pending.extend(decoder.decompress(data))
                offset = 0
                while len(pending) - offset >= row_size:
                    assert pending[offset] == 0, 'PNG filter'
                    actual = pending[offset + 1:offset + row_size]
                    reference = source.read(row_size - 1)
                    assert actual == reference, f'Pixel mismatch at row {rows}'
                    digest.update(actual)
                    expected.update(reference)
                    rows += 1
                    offset += row_size
                del pending[:offset]
            if kind == b'IEND':
                break
        assert decoder.eof and not pending and rows == dimensions[1]
        assert not source.read(1) and not image.read(1)
    assert digest.digest() == expected.digest()
    print(f'PASS {png.name}: {dimensions[0]} × {dimensions[1]}, every RGBA byte matches, SHA256 {digest.hexdigest()}')


folder = pathlib.Path(sys.argv[1])
verify(folder / 'stitch/scrolling-capture.png', folder / 'stitch-reference.rgba', (401, 906))
verify(folder / 'native-1537x70001.png', folder / 'tall.rgba', (1537, 70001))
