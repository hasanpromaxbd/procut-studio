#!/usr/bin/env bash
# Verifies that a layer lands where the preview puts it, and that stacking a
# layer on top does not erase what is beneath.
#
# Unit tests assert the compiler *emits* a scale/pad pair. Only ffmpeg can
# prove those numbers put red pixels in the right place — and only a real
# composite can prove the surround is genuinely transparent rather than
# opaque black, which is the bug that silently hid every lower track.
#
# Requires ffmpeg on PATH. Run from the repository root:
#     ./tool/verify_placement.sh

set -euo pipefail

command -v ffmpeg >/dev/null || { echo "ffmpeg not found on PATH"; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found on PATH"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

echo "ffmpeg: $(ffmpeg -version | head -1)"
echo

# A 16:9 source on a 1080x1920 canvas fits to 1080x608, centred at y=656.
# The PiP is that same fit scaled to 0.4 (432x244) and moved to x=+0.3,
# y=-0.3 → padded at x=324, y=262. These are the numbers the compiler
# computes in `_placement`; test/unit/layer_placement_test.dart pins them.
ffmpeg -hide_banner -loglevel error -f lavfi -i "color=c=blue:s=1920x1080:d=1:r=5" \
    -frames:v 1 base.png
ffmpeg -hide_banner -loglevel error -f lavfi -i "color=c=red:s=1920x1080:d=1:r=5" \
    -frames:v 1 pip.png

echo "== the emitted placement graph renders =="
ffmpeg -hide_banner -loglevel error -loop 1 -t 1 -i base.png -loop 1 -t 1 -i pip.png \
    -filter_complex \
"color=c=0x000000:s=1080x1920:d=1:r=5[base];\
[0:v]fps=5,scale=w=1080:h=608:flags=bicubic,pad=w=1080:h=1920:x=0:y=656:color=0x000000@0,format=pix_fmts=yuva420p[l0];\
[1:v]fps=5,scale=w=432:h=244:flags=bicubic,pad=w=1080:h=1920:x=324:y=262:color=0x000000@0,format=pix_fmts=yuva420p[l1];\
[base][l0]overlay=x=0:y=0:format=auto[c0];[c0][l1]overlay=x=0:y=0:format=auto[v]" \
    -map "[v]" -frames:v 1 out.png
echo "  accepted"
echo

echo "== the pixels are where the preview puts them =="
python3 - <<'PY'
import subprocess, sys

def pixel(x, y):
    raw = subprocess.run(
        ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-i', 'out.png',
         '-vf', f'crop=1:1:{x}:{y}', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'],
        capture_output=True, check=True).stdout
    return tuple(raw[:3])

def name(rgb):
    r, g, b = rgb
    if r > 200 and g < 60 and b < 60: return 'red'
    if b > 200 and r < 60 and g < 60: return 'blue'
    if max(rgb) < 40: return 'black'
    return f'rgb{rgb}'

checks = [
    ('PiP centre',                    540,  384, 'red'),
    ('base layer, left of the bars',   60,  960, 'blue'),
    ('above the PiP',                 540,  100, 'black'),
    ('just left of the PiP',          320,  384, 'black'),
    ('just right of the PiP',         760,  384, 'black'),
]

failed = False
for label, x, y, expected in checks:
    got = name(pixel(x, y))
    ok = got == expected
    failed |= not ok
    print(f"  {'ok  ' if ok else 'FAIL'} {label:<28} {got}")

if failed:
    print('\nFAIL: the composite does not match the preview')
    sys.exit(1)
PY

echo
echo "PASS"
