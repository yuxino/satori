#!/usr/bin/env python3
"""Rebuild the approved portrait's circular-alpha logo and platform icons.

Requires Pillow and the repository's installed Tauri CLI. This changes only the
alpha channel of the original 1254px portrait; no resizing or repainting occurs
until platform-specific icon exports. Intermediate exports remain in src-tauri/target/.
"""
from pathlib import Path
import hashlib
import shutil
import subprocess
from PIL import Image, ImageDraw

root = Path(__file__).resolve().parents[1]
original = root / 'docs/brand/portrait-original.png'
icons = root / 'src-tauri/icons'
expected_sha = '89094c287777b7c89b2635ad172ea4ba0feb9551dcd8676895de25195acac097'
if hashlib.sha256(original.read_bytes()).hexdigest() != expected_sha:
    raise ValueError('The approved portrait changed; review the source before rebuilding.')
with Image.open(original) as image:
    if image.size != (1254, 1254):
        raise ValueError('Expected the approved 1254px square portrait.')
    avatar = image.convert('RGBA')
    size = avatar.width
    scale = 4
    mask = Image.new('L', (size * scale, size * scale))
    ImageDraw.Draw(mask).ellipse((0, 0, size * scale - 1, size * scale - 1), fill=255)
    avatar.putalpha(mask.resize((size, size), Image.Resampling.LANCZOS))
    avatar.save(icons / 'source.png')

stage = root / 'src-tauri/target/brand-icons'
stage.mkdir(parents=True, exist_ok=True)
subprocess.run(['npm', 'run', 'tauri', '--', 'icon', str(icons / 'source.png'), '--output', str(stage)], cwd=root, check=True)
for name in ['32x32.png', '128x128.png', '128x128@2x.png', 'icon.icns']:
    shutil.copy2(stage / name, icons / name)
# Tauri's default ICO omits 128px; retain all nine established Windows sizes.
with Image.open(icons / 'source.png') as image:
    image.save(icons / 'icon.ico', format='ICO', sizes=[(n, n) for n in [16, 20, 24, 32, 40, 48, 64, 128, 256]])
print('Rebuilt the circular logo and five platform assets; original RGB artwork preserved.')
