#!/usr/bin/env python3
"""Reproduce the original app icon using only Python's standard library."""
from pathlib import Path
import json
import struct
import zlib

size = 1024
background = (20, 67, 59)
foreground = (216, 246, 210)
rows = []
for y in range(size):
    row = bytearray([0])
    for x in range(size):
        # A quiet bulb silhouette with a short stem and two base bars.
        bulb = (x - 512)**2 + (y - 405)**2 < 205**2
        neck = 426 <= x <= 598 and 520 <= y <= 650
        base = 434 <= x <= 590 and (678 <= y <= 710 or 736 <= y <= 768)
        filament = (491 <= x <= 533 and 370 <= y <= 594)
        crossbar = (451 <= x <= 573 and 370 <= y <= 408)
        color = foreground if (bulb or neck or base) and not (filament or crossbar) else background
        row.extend(color)
    rows.append(row)
def chunk(tag, data):
    return struct.pack('!I', len(data)) + tag + data + struct.pack('!I', zlib.crc32(tag + data) & 0xffffffff)
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', size, size, 8, 2, 0, 0, 0))
png += chunk(b'IDAT', zlib.compress(b''.join(rows), 9)) + chunk(b'IEND', b'')
assets = Path(__file__).resolve().parent.parent / 'App/Assets.xcassets'
icon = assets / 'AppIcon.appiconset'
icon.mkdir(parents=True, exist_ok=True)
(icon / 'AppIcon.png').write_bytes(png)
(icon / 'Contents.json').write_text(json.dumps({'images': [{'filename': 'AppIcon.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'}], 'info': {'author': 'xcode', 'version': 1}}, indent=2) + '\n')
(assets / 'Contents.json').write_text('{"info":{"author":"xcode","version":1}}\n')
accent = assets / 'AccentColor.colorset'
accent.mkdir(exist_ok=True)
(accent / 'Contents.json').write_text(json.dumps({'colors': [
    {'idiom':'universal', 'color': {'color-space':'srgb', 'components': {'red':'0.106', 'green':'0.420', 'blue':'0.306', 'alpha':'1.000'}}},
    {'idiom':'universal', 'appearances':[{'appearance':'luminosity','value':'dark'}], 'color': {'color-space':'srgb', 'components': {'red':'0.620', 'green':'0.871', 'blue':'0.651', 'alpha':'1.000'}}}
], 'info': {'author':'xcode', 'version':1}}, indent=2) + '\n')
print('Generated original 1024px RGB icon and adaptive accent asset.')
