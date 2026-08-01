#!/usr/bin/env bash
# Verifies the grading and retouch chains against a real ffmpeg binary.
#
# Unit tests can prove the compiler emits a given filter string. They cannot
# prove that string parses, that `colorbalance`'s zones sit where the preview
# shader thinks they do, or that a skin mask actually finds skin. Each of those
# has already been wrong once:
#
#   * a tone curve quoted twice produced `all='\'0/0 …\''`, which does not
#     parse — and takes the whole graph down, not just the one filter;
#   * `colorbalance`'s three zones meet at a lightness of 0.25, not 0.5, so a
#     preview built on the obvious assumption puts a mid-tone push in the
#     wrong place.
#
# Requires ffmpeg and python3 on PATH. Run from the repository root:
#     ./tool/verify_grade.sh

set -euo pipefail

command -v ffmpeg >/dev/null || { echo "ffmpeg not found on PATH"; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found on PATH"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "ffmpeg: $(ffmpeg -version | head -1)"
echo

# ── 1. Every filter the two compilers emit must exist ───────────────────
echo "== filters used by GradeCompiler and RetouchCompiler exist =="
MISSING=0
for f in colortemperature colorchannelmixer curves colorbalance vibrance hue \
         bilateral maskedmerge geq gblur unsharp split; do
    flags="$(ffmpeg -hide_banner -filters 2>/dev/null | awk -v n="$f" '$2==n {print $1}')"
    if [ -n "$flags" ]; then
        printf "  %-18s %-6s ok\n" "$f" "$flags"
    else
        printf "  %-18s %-6s MISSING\n" "$f" "-"
        MISSING=1
    fi
done
[ "$MISSING" -eq 0 ] || { echo "FAIL: a filter the compiler emits does not exist"; exit 1; }
echo

# ── 2. Every filter the grade animates must take runtime commands ───────
echo "== filters bound to grade commands support runtime commands =="
MISSING=0
for f in colortemperature colorchannelmixer curves colorbalance vibrance hue; do
    flags="$(ffmpeg -hide_banner -filters 2>/dev/null | awk -v n="$f" '$2==n {print $1}')"
    if [[ "$flags" == *C* ]]; then
        printf "  %-18s %-6s ok\n" "$f" "$flags"
    else
        printf "  %-18s %-6s NO COMMAND SUPPORT\n" "$f" "${flags:-missing}"
        MISSING=1
    fi
done
[ "$MISSING" -eq 0 ] || { echo "FAIL: a bound filter cannot take commands"; exit 1; }
echo

# ── 3. The zone weights the preview uses must match the filter ──────────
#
# This is the measurement the shader's three lines — and the numbers pinned in
# retouch_and_grade_test.dart — are fitted to. Re-run it when FFmpeg changes.
echo "== colorbalance zone weights match GradeCompiler.zoneWeights =="
python3 - "$WORK" <<'PY'
import subprocess, sys
work = sys.argv[1]

def ramp(vf):
    chain = "format=gbrp,geq=r='X':g='X':b='X'" + ("," + vf if vf else "")
    p = subprocess.run(
        ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi',
         '-i', 'color=c=black:s=256x8:r=1:d=1', '-vf', chain,
         '-frames:v', '1', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'],
        capture_output=True)
    if p.returncode != 0:
        print('FAIL: ' + p.stderr.decode()[:300]); sys.exit(1)
    return [p.stdout[i * 3] for i in range(256)]

def model(l):
    shadows = min(max((0.25 - l) / 0.15, 0.0), 1.0)
    highlights = min(max((l - 0.25) / 0.15, 0.0), 1.0)
    return shadows, max(0.0, 1 - shadows - highlights), highlights

base = ramp('')
amount, scale = 0.2, 0.7
peak = amount * scale * 255

worst = 0.0
for zone, param in ((0, 'rs'), (1, 'rm'), (2, 'rh')):
    out = ramp('colorbalance=%s=%s:pl=0' % (param, amount))
    for x in range(0, 256, 8):
        # Skip anywhere the offset would run past white — the falloff there is
        # clipping, not weighting, and it would be measured as model error.
        if base[x] + peak > 254:
            continue
        measured = (out[x] - base[x]) / peak
        predicted = model(x / 255.0)[zone]
        worst = max(worst, abs(measured - predicted))

print('  worst deviation across all three zones: %.3f' % worst)
if worst > 0.2:
    print('FAIL: the preview model no longer matches colorbalance')
    sys.exit(1)
print('  within tolerance')
PY
echo

# ── 4. Warmth must move the picture the direction its label claims ──────
echo "== warmth right is warmer, left is cooler =="
python3 - <<'PY'
import subprocess, sys

def sample(temperature):
    vf = 'colortemperature=temperature=%s:mix=1:pl=1' % temperature if temperature else None
    args = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi',
            '-i', 'color=c=gray:s=32x32:r=1:d=1']
    if vf:
        args += ['-vf', vf]
    args += ['-frames:v', '1', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-']
    p = subprocess.run(args, capture_output=True)
    if p.returncode != 0:
        print('FAIL: ' + p.stderr.decode()[:300]); sys.exit(1)
    return p.stdout[0], p.stdout[2]

# GradeCompiler.kelvinFor(+1) and (-1): a mired shift either side of 6500 K,
# clamped. Warm is the *lower* number, which is the inversion the control is
# labelled "warmth" to avoid having to explain.
warm_r, warm_b = sample('4100.9')
cool_r, cool_b = sample('12000')
neutral_r, neutral_b = sample(None)

print('  neutral  R=%3d B=%3d' % (neutral_r, neutral_b))
print('  warmth+1 R=%3d B=%3d' % (warm_r, warm_b))
print('  warmth-1 R=%3d B=%3d' % (cool_r, cool_b))

ok = warm_r > neutral_r and warm_b < neutral_b and cool_b > cool_r
print('  ok' if ok else 'FAIL: warmth moves the wrong way')
sys.exit(0 if ok else 1)
PY
echo

# ── 5. The tone curve must pivot where it says it does ──────────────────
echo "== contrast darkens below the pivot and brightens above it =="
python3 - <<'PY'
import math, subprocess, sys

def tone(x, contrast, pivot):
    e = math.log(0.5) / math.log(pivot)
    u = min(max(x, 0.0), 1.0) ** e
    s = u * u * (3 - 2 * u)
    return min(max(x + contrast * (s ** (1 / e) - x), 0.0), 1.0)

pivot, contrast = 0.5, 0.8
points = ' '.join('%g/%g' % (i / 4, round(tone(i / 4, contrast, pivot), 6))
                  for i in range(5))
print('  curve: %s' % points)

p = subprocess.run(
    ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi',
     '-i', 'color=c=black:s=256x8:r=1:d=1', '-vf',
     "format=gbrp,geq=r='X':g='X':b='X',curves=all='%s'" % points,
     '-frames:v', '1', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'],
    capture_output=True)
if p.returncode != 0:
    print('FAIL: ' + p.stderr.decode()[:300]); sys.exit(1)

out = [p.stdout[i * 3] for i in range(256)]
print('  64 -> %3d, 128 -> %3d, 192 -> %3d' % (out[64], out[128], out[192]))
ok = out[64] < 60 and abs(out[128] - 128) <= 3 and out[192] > 196
print('  ok' if ok else 'FAIL: the curve does not pivot at the mid-point')
sys.exit(0 if ok else 1)
PY
echo

# ── 6. The whole grade chain must parse and do something ────────────────
#
# The filter string below is the shape GradeCompiler.build emits for the
# "teal & orange" look, in the order it emits it.
echo "== the full grade chain renders =="
GRADE="colortemperature=temperature=5741:mix=1:pl=1,\
colorchannelmixer=rr=1:gg=1:bb=1,\
curves=all='0/0 0.25/0.2 0.5/0.5 0.75/0.8 1/1',\
colorbalance=rs=-0.052:gs=-0.213:bs=0.265:rm=0:gm=0:bm=0:rh=0.209:gh=-0.253:bh=0.044,\
vibrance=intensity=0.16,hue=s=1.05"
ffmpeg -hide_banner -loglevel error \
    -f lavfi -i "testsrc=d=1:s=320x240:r=10" \
    -vf "$GRADE" -frames:v 5 -f null -
echo "  accepted"

ffmpeg -hide_banner -loglevel error -f lavfi -i "testsrc=d=1:s=320x240:r=10" \
    -frames:v 1 -f framehash -hash md5 - 2>/dev/null | grep -v '^#' > "$WORK/plain.txt"
ffmpeg -hide_banner -loglevel error -f lavfi -i "testsrc=d=1:s=320x240:r=10" \
    -vf "$GRADE" -frames:v 1 -f framehash -hash md5 - 2>/dev/null | grep -v '^#' > "$WORK/graded.txt"
if cmp -s "$WORK/plain.txt" "$WORK/graded.txt"; then
    echo "FAIL: the grade left the picture untouched"; exit 1
fi
echo "  the picture changed"
echo

# ── 7. An animated tone curve must actually animate ─────────────────────
#
# This is the one command in the app whose value is text rather than a number.
# `sendcmd` has to accept it as a single quoted token, and `curves` has to
# honour it at runtime — neither is obvious from the documentation.
echo "== a keyframed tone curve animates through sendcmd =="
cat > "$WORK/grade.cmd" <<'EOF'
0.000 curves@fxg1 all '0/0 0.5/0.5 1/1';
0.500 curves@fxg1 all '0/0 0.5/0.7 1/1';
0.900 curves@fxg1 all '0/0 0.5/0.9 1/1';
EOF
ffmpeg -hide_banner -loglevel error \
    -f lavfi -i "color=c=gray:s=64x64:r=10:d=1" \
    -vf "sendcmd=f=$WORK/grade.cmd,curves@fxg1=all='0/0 0.5/0.5 1/1'" \
    -f rawvideo -pix_fmt rgb24 - 2>/dev/null > "$WORK/curve.raw"
python3 - "$WORK/curve.raw" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()
frame = 64 * 64 * 3
first, mid, last = data[0], data[6 * frame], data[9 * frame]
print('  frame 0 R=%d, frame 6 R=%d, frame 9 R=%d' % (first, mid, last))
ok = first < mid < last
print('  ok' if ok else 'FAIL: the curve did not move')
sys.exit(0 if ok else 1)
PY
echo

# ── 8. The retouch mask must find skin and leave everything else ────────
echo "== retouch smooths skin only =="
SKIN="255*clip(min((cb(X,Y)-77)/12,(130-cb(X,Y))/12),0,1)*clip(min((cr(X,Y)-135)/12,(175-cr(X,Y))/12),0,1)"
ffmpeg -hide_banner -loglevel error \
    -f lavfi -i "color=c=0xC08060:s=128x128:r=1:d=1" \
    -f lavfi -i "color=c=0x6080C0:s=128x128:r=1:d=1" \
    -filter_complex "[0:v][1:v]hstack,noise=alls=28:allf=t+u,format=yuv444p,\
split=3[o][b][m];\
[b]bilateral=sigmaS=12.4:sigmaR=0.22[s];\
[m]geq=lum='$SKIN':cb=128:cr=128,gblur=sigma=8[k];\
[o][s][k]maskedmerge[out]" \
    -map "[out]" -frames:v 1 -f rawvideo -pix_fmt gray - 2>/dev/null > "$WORK/retouched.raw"

ffmpeg -hide_banner -loglevel error \
    -f lavfi -i "color=c=0xC08060:s=128x128:r=1:d=1" \
    -f lavfi -i "color=c=0x6080C0:s=128x128:r=1:d=1" \
    -filter_complex "[0:v][1:v]hstack,noise=alls=28:allf=t+u[out]" \
    -map "[out]" -frames:v 1 -f rawvideo -pix_fmt gray - 2>/dev/null > "$WORK/noisy.raw"

python3 - "$WORK/noisy.raw" "$WORK/retouched.raw" <<'PY'
import statistics, sys

W, H = 256, 128

def halves(path):
    data = open(path, 'rb').read()
    skin, other = [], []
    for y in range(H):
        row = data[y * W:(y + 1) * W]
        skin.extend(row[:W // 2])
        other.extend(row[W // 2:])
    return statistics.pstdev(skin), statistics.pstdev(other)

before_skin, before_other = halves(sys.argv[1])
after_skin, after_other = halves(sys.argv[2])
print('  skin      noise %.2f -> %.2f' % (before_skin, after_skin))
print('  not skin  noise %.2f -> %.2f' % (before_other, after_other))

ok = after_skin < before_skin * 0.7 and after_other > before_other * 0.85
print('  ok' if ok else 'FAIL: the mask is not selective')
sys.exit(0 if ok else 1)
PY
echo

echo "PASS: grading and retouch behave as the compilers describe"
