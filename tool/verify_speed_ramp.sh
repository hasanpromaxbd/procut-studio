#!/usr/bin/env bash
# Verifies that a speed ramp actually ramps, and that picture and sound agree.
#
# The compiler cuts a ramp into constant-rate pieces because `setpts` takes one
# multiplier for a whole stream. A unit test can prove it emits many rates; only
# ffmpeg can prove those rates add up to the clip's stated length, that the
# audio pieces match the video pieces, and that the motion genuinely
# accelerates. Before this existed, a ramp exported at one constant speed while
# a comment described the segmenting it was not doing.
#
# Requires ffmpeg on PATH. Run from the repository root:
#     ./tool/verify_speed_ramp.sh

set -euo pipefail

command -v ffmpeg >/dev/null || { echo "ffmpeg not found on PATH"; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found on PATH"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

echo "ffmpeg: $(ffmpeg -version | head -1)"
echo

ffmpeg -hide_banner -loglevel error -f lavfi \
    -i "testsrc2=size=320x180:duration=30:rate=30" \
    -f lavfi -i "sine=frequency=440:duration=30" \
    -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -shortest src.mp4

# A 1x→4x ramp over 8s of timeline, in the 16 pieces the compiler emits.
# Boundaries come from integrating the rate curve: piece i covers the source
# consumed between its timeline endpoints, and plays at that span's average
# rate. `rampSegments` in the compiler does the same arithmetic.
python3 - <<'PY' > graph.txt
SEGMENTS = 16
TOTAL = 8.0

def rate_at(t):
    return 1 + 3 * (t / TOTAL)

def consumed(a, b, steps=240):
    step = (b - a) / steps
    return sum(step * rate_at(a + step * (i + 0.5)) for i in range(steps))

vparts, aparts, vlabels, alabels = [], [], [], []
before = 0.0
for i in range(SEGMENTS):
    t0 = TOTAL * i / SEGMENTS
    t1 = TOTAL * (i + 1) / SEGMENTS
    span = t1 - t0
    used = consumed(t0, t1)
    rate = used / span
    s0, s1 = before, before + used
    before = s1
    vparts.append(
        f"[v{i}]trim=start={s0:.6f}:end={s1:.6f},setpts=PTS-STARTPTS,"
        f"setpts={1/rate:.6f}*PTS[vs{i}]")
    # atempo caps at 2x per instance, so a steep piece cascades.
    chain, remaining = [], rate
    while remaining > 2.0:
        chain.append("atempo=2.0"); remaining /= 2.0
    while remaining < 0.5:
        chain.append("atempo=0.5"); remaining /= 0.5
    chain.append(f"atempo={remaining:.6f}")
    aparts.append(
        f"[a{i}]atrim=start={s0:.6f}:end={s1:.6f},asetpts=PTS-STARTPTS,"
        + ",".join(chain) + f"[as{i}]")
    vlabels.append(f"[vs{i}]"); alabels.append(f"[as{i}]")

print(
    "[0:v]split=%d%s;%s;%sconcat=n=%d:v=1:a=0,setpts=PTS-STARTPTS[v];"
    "[0:a]asplit=%d%s;%s;%sconcat=n=%d:v=0:a=1,asetpts=PTS-STARTPTS[a]" % (
        SEGMENTS, "".join(f"[v{i}]" for i in range(SEGMENTS)),
        ";".join(vparts), "".join(vlabels), SEGMENTS,
        SEGMENTS, "".join(f"[a{i}]" for i in range(SEGMENTS)),
        ";".join(aparts), "".join(alabels), SEGMENTS))
PY

echo "== the segmented graph renders =="
ffmpeg -hide_banner -loglevel error -i src.mp4 \
    -filter_complex "$(cat graph.txt)" -map "[v]" -map "[a]" \
    -c:v libx264 -preset ultrafast -c:a aac out.mp4
echo "  accepted"
echo

echo "== picture and sound both land on the clip's stated length =="
V="$(ffprobe -v error -select_streams v -show_entries stream=duration -of csv=p=0 out.mp4)"
A="$(ffprobe -v error -select_streams a -show_entries stream=duration -of csv=p=0 out.mp4)"
printf "  video %.2fs, audio %.2fs, timeline says 8.00s\n" "$V" "$A"
awk -v v="$V" -v a="$A" 'BEGIN {
    if (v < 7.9 || v > 8.1) { print "FAIL: video length is wrong"; exit 1 }
    if (a < 7.9 || a > 8.1) { print "FAIL: audio length is wrong"; exit 1 }
    d = v - a; if (d < 0) d = -d
    if (d > 0.1) { printf "FAIL: picture and sound drifted %.2fs apart\n", d; exit 1 }
    print "  in step"
}'
echo

echo "== the motion genuinely accelerates =="
for n in 3 4 230 231; do
    ffmpeg -hide_banner -loglevel error -y -i out.mp4 \
        -vf "select='eq(n\,$n)'" -frames:v 1 "p$n.png"
done
python3 - <<'PY'
import subprocess, sys

def frame(path):
    return subprocess.run(
        ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-i', path,
         '-vf', 'scale=64:36', '-f', 'rawvideo', '-pix_fmt', 'gray', '-'],
        capture_output=True, check=True).stdout

def motion(a, b):
    x, y = frame(a), frame(b)
    return sum(abs(p - q) for p, q in zip(x, y)) / len(x)

early = motion('p3.png', 'p4.png')
late = motion('p230.png', 'p231.png')
print(f'  near the start: {early:.2f} per frame')
print(f'  near the end:   {late:.2f} per frame')
if late <= early * 1.8:
    print('FAIL: the clip is not speeding up — this is a constant-rate render')
    sys.exit(1)
print(f'  {late / early:.1f}x more motion by the end')
PY

echo
echo "PASS"
