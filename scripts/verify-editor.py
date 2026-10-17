#!/usr/bin/env python3
"""Independent row-streaming checks of edited native PNGs, including >65535 rows."""
import pathlib
import struct
import sys
import zlib

root = pathlib.Path(sys.argv[1])


def png_rows(path, expected):
    decoder = zlib.decompressobj()
    pending = bytearray()
    row_size = expected[0] * 4 + 1
    rows = 0
    with path.open('rb') as file:
        assert file.read(8) == b'\x89PNG\r\n\x1a\n'
        while True:
            size = struct.unpack('>I', file.read(4))[0]
            kind, data = file.read(4), file.read(size)
            assert zlib.crc32(kind + data) & 0xffffffff == struct.unpack('>I', file.read(4))[0]
            if kind == b'IHDR':
                assert struct.unpack('>IIBBBBB', data) == (*expected, 8, 6, 0, 0, 0)
            elif kind == b'IDAT':
                pending.extend(decoder.decompress(data))
                offset = 0
                while len(pending) - offset >= row_size:
                    assert pending[offset] == 0
                    yield rows, bytes(pending[offset + 1:offset + row_size])
                    rows += 1
                    offset += row_size
                del pending[:offset]
            elif kind == b'IEND':
                break
        assert decoder.eof and not pending and rows == expected[1]


def verify(name, reference, source_width, crop, boxes, probes):
    x, y, width, height = crop
    red_counts = [0] * len(boxes)
    with (root / reference).open('rb') as raw:
        raw.seek(y * source_width * 4)
        for row, actual in png_rows(root / name, (width, height)):
            original = raw.read(source_width * 4)[x * 4:(x + width) * 4]
            allowed = [(max(0, a - x), min(width, c - x), i) for i, (a, b, c, d) in enumerate(boxes) if b <= row + y <= d]
            allowed = [(a, c, i) for a, c, i in allowed if c > a]
            if not allowed:
                assert actual == original, (name, 'unmarked row changed', row)
            else:
                # Pixel comparisons outside annotation bounds remain exact.
                for col in range(width):
                    offset = col * 4
                    indexes = [i for a, c, i in allowed if a <= col <= c]
                    if not indexes:
                        assert actual[offset:offset+4] == original[offset:offset+4], (name, row, col)
                    elif actual[offset] > 200 and actual[offset+1] < 110:
                        for i in indexes:
                            red_counts[i] += 1
            for px, py in probes:
                if row + y == py:
                    offset = (px - x) * 4
                    assert actual[offset] > 200 and actual[offset+1] < 110, (name, 'annotation missing', px, py)
    assert all(count > 40 for count in red_counts), (name, red_counts)
    print(f'PASS {name}: {width} × {height}, exact unmarked pixels, crop offsets, visible annotations; red pixels per region {red_counts}')


verify('edited.png', 'reference.rgba', 640, (50, 60, 550, 370),
       [(90, 80, 300, 220), (288, 88, 532, 292), (75, 300, 640, 410)], [(300, 150), (270, 190)])
verify('long-annotated.png', 'long-reference.rgba', 257, (0, 0, 257, 70001),
       [(24, 69914, 186, 69986)], [(30, 69950)])
verify('long-cropped.png', 'long-reference.rgba', 257, (10, 30, 220, 69950),
       [(24, 69914, 186, 69986)], [(30, 69950)])

alpha_rows = dict(png_rows(root / 'alpha-edited.png', (64, 64)))
reference = (root / 'alpha-reference.rgba').read_bytes()
for y, row in alpha_rows.items():
    for x in range(64):
        if x < 7 or x > 53 or y < 7 or y > 53 or (13 < x < 47 and 13 < y < 47):
            assert row[x*4:x*4+4] == reference[(y*64+x)*4:(y*64+x+1)*4], ('alpha preservation', x, y)
for y, expected in [(20, (255, 0, 0, 128)), (40, (197, 30, 33, 192))]:
    pixel = alpha_rows[y][10*4:10*4+4]
    assert all(abs(a-b) <= 1 for a, b in zip(pixel, expected)), ('straight alpha compositing', y, pixel)
print('PASS transparent and translucent native samples remain exact outside annotations; overlay uses straight alpha correctly')
