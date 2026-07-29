# Optimization guide

Everything here is a decision already made in the codebase, with the reasoning
and the way to verify it still holds. A 60fps timeline is not one trick; it is
a handful of choices that each remove a whole class of per-frame work.

## The frame budget

60fps means **16.67 ms** per frame for build + layout + paint + raster. On a
mid-range Android device, assume ~10 ms of headroom after the platform takes
its share.

---

## 1. Keep high-frequency state out of shared state

**The problem.** The playhead updates 60×/s. If it lives in `EditorState`,
every widget watching the editor rebuilds 60×/s — inspector, toolbar, track
headers, project title — for a value none of them read.

**What we do.** `PlayheadController` is a separate notifier. The timeline's
playhead layer subscribes to it directly through a `Listenable` bridged into
`CustomPainter.repaint`, so playback repaints one line and nothing else.

**Verify.** Turn on "Track widget rebuilds" in DevTools and play the timeline.
Only the playhead layer should tick.

## 2. Paint what is visible, not what exists

`TimelinePainter` calls `view.visibleRange()` and `track.clipsInRange()`. A
500-clip project paints exactly as fast as a 10-clip one when both show twelve
clips on screen.

`Track.clipAt` binary-searches the sorted clip list — the sort invariant is
maintained by every mutator in `Track`, which is what makes the search valid.

**Verify.** Build a 500-clip project and check the raster time in the
performance overlay against a 10-clip one. They should match.

## 3. Split cheap and expensive paint layers

`TimelinePainter` (clips, thumbnails, waveforms) is the background painter;
`PlayheadPainter` is the foreground. `shouldRepaint` on the first returns false
during playback, so the expensive layer is cached and only the playhead
re-rasterises.

Without this, every playback frame re-rasterises every visible thumbnail —
roughly 40× more work for the same visual result.

## 4. Cache thumbnails in two tiers, and quantise the key

Memory (LRU of decoded `ui.Image`) → disk (JPEG) → FFmpeg extraction.

The subtle part is `ThumbnailCache.keyFor`, which **quantises time to a 500 ms
grid**. Without it a scrolling timeline requests a different millisecond every
frame and the cache never hits. With it, neighbouring requests collapse onto
one key.

In-flight requests are de-duplicated: a second request for a key already being
generated joins the existing future instead of launching another FFmpeg
process.

Extraction uses `-ss` *before* `-i`, which seeks by keyframe — approximate but
~100× faster than decoding from zero. Nobody notices a scrubbing thumbnail
being one GOP off.

**Budget.** 240 entries at 96 px ≈ 4 MB. Tune with
`AppConstants.thumbnailCacheCapacity`.

## 5. Proxy heavy footage

Sources at ≥2560 px get a 540p proxy (`MediaAsset.needsProxy`), built in the
background after import. `previewPath` returns it automatically, so preview and
thumbnails use the proxy while **export always uses the original**.

The proxy is encoded `-preset ultrafast -crf 28 -g 15`. The dense keyframe
interval is the point — it makes seeking fast, which is the entire reason the
proxy exists.

## 6. Effects run on the GPU in preview, in FFmpeg on export

Preview effects are `ui.ImageFilter.shader` passes running the project's own
`.frag` files — real GPU work, not a CPU approximation.

Colour adjustment deliberately does **not** use a shader: it is a
`ColorFilter.matrix`, which Skia folds into the existing paint for free. Never
spend a render pass on something the compositor can do inline.

## 7. Collapse bursts before they reach expensive work

| Tool | Where | Why |
|---|---|---|
| `Debouncer` | Auto-save | A drag would otherwise write 60 revisions/second |
| `Throttler` | Thumbnail requests | The painter asks for every missing tile every frame |
| `LatestOnlyRunner` | Preview seeks | Scrubbing drops intermediate positions, keeps the newest |

`Throttler` fires the *leading* edge; a debounce here would make thumbnails
feel laggy. `Debouncer` fires the trailing edge; a throttle there would write
too often. The distinction matters.

## 8. Release decoders you are not showing

Android allows a small number of concurrent hardware video decoders (typically
4–8, device-dependent). `PreviewStage._syncControllers` disposes controllers for
layers scrolled out of view and caps concurrent decoders at 4. Holding them
open exhausts the device pool within a few edits and every subsequent
`initialize()` fails.

Controllers are keyed by **asset**, not clip — two clips from one file share a
decoder.

## 9. Do not seek every frame

`_syncPlayback` only corrects drift beyond 220 ms during playback (40 ms when
paused). Seeking every frame stutters far worse than the drift ever shows.

## 10. Serialise heavy FFmpeg work

`FFmpegService` runs a queue. A device has one hardware encoder; two concurrent
encodes make both slower and can hard-fail MediaCodec. Light calls
(thumbnails) pass `queued: false` and skip the queue.

## 11. Bound anything that grows

| Buffer | Bound | Why |
|---|---|---|
| Undo stack | 100 entries | Each holds a timeline alive |
| Log ring buffer | 500 records | Would grow unbounded over a session |
| FFmpeg log tail | 40 lines | FFmpeg emits tens of thousands |
| Thumbnail cache | 240 images | ~4 MB of decoded RGBA |

## 12. Integer time, always

Every position is a `Duration` (microsecond integers), never a double of
seconds. Accumulating float seconds across a hundred edits drifts enough to
visibly desync audio on a long project.

Frame snapping (`TimeUtils.snapToFrame`) runs on every edit so boundaries land
on real frame times — which also means a 29.97fps project stays sample-accurate
where milliseconds could not represent a frame boundary at all.

---

## Profiling recipes

**Timeline scroll jank**
```bash
flutter run --profile
```
DevTools → Performance → record while scrolling. Look for raster times over
16 ms. Usual culprit: thumbnail decode on the raster thread — check the cache
is hitting.

**Rebuild storms**
DevTools → Performance → "Track widget rebuilds". Anything rebuilding during
playback other than the playhead layer is a bug.

**Memory growth**
DevTools → Memory → watch `ui.Image` count. If it climbs while scrolling, the
LRU is not evicting; if it climbs while scrubbing the preview, a
`VideoPlayerController` is leaking.

**Export speed**
Settings → Diagnostics → Recent logs shows the chosen encoder and FFmpeg's
reported speed. Below ~1× realtime on a modern device, hardware encoding
probably fell back to software — the log says which.

## Anti-patterns to avoid here

- **A `BackdropFilter` in a scrolling list.** Every one is a full-screen GPU
  pass. `GlassPanel` is used only for the floating transport bar and sheets.
- **`setState` in the timeline widget on every pointer move.** Drag state lives
  in plain fields; only the snap guide triggers a rebuild.
- **Awaiting inside `CustomPainter.paint`.** Impossible by design — that is why
  `peek` is synchronous and misses are filled asynchronously.
- **Deep equality on `Timeline` in `shouldRepaint`.** Comparing 500 clips per
  frame costs more than the repaint. Identity is correct because edits always
  produce a new instance.
