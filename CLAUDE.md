# BracketCam — 5-Frame HDR Bracket Camera for Real Estate

Native iOS app (SwiftUI + AVFoundation, iOS 17+, iPhone, physical device only).
One tap captures a 5-shot exposure bracket on a tripod, optimized for lowest
noise, for AI-based HDR merge/editing downstream. Output is JPEG, saved to
Photos in one album per set.

## File map

| File | Responsibility |
|---|---|
| `Sources/BracketCamApp.swift` | App entry point |
| `Sources/ContentView.swift` | UI: preview, plan strip, histogram, warnings, shutter |
| `Sources/CameraManager.swift` | Session setup, format selection, metering, capture sequence |
| `Sources/BracketPlanner.swift` | Exposure math: ladder, ISO selection, highlight logic, `Tuning` constants |
| `Sources/HistogramAnalyzer.swift` | Luma histogram from the video data output |
| `Sources/HistogramView.swift` | Live histogram rendering |
| `Sources/CameraPreviewView.swift` | Preview layer, tap-to-focus, volume-button shutter |
| `Sources/PhotoLibrarySaver.swift` | Photos album/folder creation and saving |

## Device limits (queried at runtime, never hardcoded)

At startup the back wide camera is selected and, among its formats, the one
with the **largest `maxExposureDuration`** is chosen (ties broken by largest
photo resolution). From the active format we read `minISO`, `maxISO`,
`minExposureDuration`, `maxExposureDuration`.

**Exposure cap** = `min(1.0 s, format.maxExposureDuration)` — the longest
shutter any frame may use (`Tuning.exposureCapSeconds`).

## Metering

While idle the device runs continuous auto-exposure (tap the preview to set
the AF/AE point of interest; a single-scan AF then holds the lens position).
At capture time we read the AE solution and form the **meter product**

```
E = exposureDuration × ISO      (seconds × ISO, the "0 EV" scene exposure)
```

All frames are defined as multiples of E. Because a frame's brightness depends
only on the product `T × ISO`, targets are expressed as products and each frame
independently picks the lowest-noise T/ISO split (below).

## The exposure ladder (fixed, 5 frames)

Four meter-anchored frames at fixed 2-stop spacing, plus one floating
highlight-protected frame. Capture order is darkest → brightest:

| Frame | Target product | Notes |
|---|---|---|
| HL ★ | measured (see below) | never brighter than the −2 frame |
| −2 EV | E / 4 | |
|  0 EV | E | the meter anchor |
| +2 EV | E × 4 | |
| +4 EV | E × 16 | shadow/noise frame |

## ISO selection (per frame, lowest possible)

For a target product `P`:

1. `T = clamp(P / minISO, minExposureDuration, cap)` — stretch the shutter as
   long as the cap allows at base ISO first (tripod: no stabilization needed).
2. `ISO = clamp(P / T, minISO, maxISO)` — raise ISO only for the exposure the
   shutter alone cannot deliver.

So in bright scenes the whole bracket runs at base ISO (UI shows a green
**BASE ISO** badge). In dark scenes only the brighter frames climb the ISO
range. If even `maxISO` at the cap can't reach a frame's target, the frame is
flagged underexposed; when that happens to the +4 frame the UI shows the
**VERY DARK** warning (deep shadows may stay underexposed).

## Highlight-protection logic (the HL frame)

Goal: put the **diffuse** highlights (bright windows) just under clipping,
letting a small fraction of extreme speculars clip — we do not chase zero
clipping.

At capture time, after locking focus and white balance:

1. Set exposure to the −2 EV frame's settings and wait `settleSeconds` (0.35 s)
   for the pipeline to settle.
2. Read the luma histogram of a preview frame and find the value `v` at the
   **99.5th percentile** (`Tuning.highlightPercentile`).
3. If `v` is pinned at the clip point (≥ `clipValue − 1`), the histogram can't
   tell us how far over we are: halve the metering exposure (−1 stop) and
   re-measure, up to `maxHighlightSearchStops` (4) times.
4. Otherwise compute the shift that puts `v` at the clip point minus the
   safety margin:

   ```
   shiftStops = displayGamma × log2(clipValue / v) − highlightMarginStops
   HL product = (measured product) × 2^shiftStops
   ```

   The preview histogram is gamma-encoded, so the value ratio is converted to
   linear stops with `displayGamma` (2.2 approximation).
5. **CLAMP:** `HL product = min(HL product, E / 4)` — the HL frame is never
   brighter than the −2 EV frame. In scenes with no real highlights it simply
   matches −2 EV.

Tunable constants (all in `Tuning`, `BracketPlanner.swift`):

| Constant | Default | Meaning |
|---|---|---|
| `highlightPercentile` | 0.995 | histogram percentile treated as diffuse highlight |
| `highlightMarginStops` | 1/3 | safety margin below clip |
| `clipValue` | 250 | 8-bit value treated as clipping (tone-curve shoulder) |
| `displayGamma` | 2.2 | gamma-to-linear conversion for stop math |
| `exposureCapSeconds` | 1.0 | shutter ceiling (min'd with device max) |
| `settleSeconds` | 0.35 | wait after each exposure change |
| `maxHighlightSearchStops` | 4 | iterative search depth when clipped |

The plan strip in the UI shows a live HL estimate computed from the current
histogram; the definitive measurement happens at capture time at −2 EV.

## Capture sequence

1. Optional 2 s self-timer countdown (toggle in UI); volume buttons also fire
   the shutter on iOS 17.2+ (`AVCaptureEventInteraction`) — both avoid tripod shake.
2. Read the meter product E from continuous AE.
3. Lock focus (`.locked`) and white balance (`.locked`) — only exposure
   changes across the bracket.
4. Measure the HL frame (above).
5. For each of the 5 frames: `setExposureModeCustom(duration:iso:)`, wait for
   the commit callback + `settleSeconds`, capture one JPEG
   (`AVCapturePhotoSettings` with JPEG codec, flash off, max photo dimensions).
6. Restore continuous auto exposure / auto white balance.
7. Save all 5 JPEGs in one Photos change request: a new album named
   `Bracket yyyy-MM-dd HH.mm.ss` inside the top-level **RE Brackets** folder —
   each 5-shot set is its own album, in capture order (darkest first).

## Build pipeline (no Mac)

The user has a Windows PC only. `project.yml` (XcodeGen) defines the Xcode
project; `.github/workflows/build-ipa.yml` generates the project and compiles
an **unsigned** `BracketCam.ipa` on GitHub's macOS runners. The ipa is then
signed and installed onto the iPhone from Windows with Sideloadly (or
AltStore) using a free Apple ID — see `SETUP.md`. Privacy strings and all
Info.plist content live in `project.yml`, not in a checked-in plist.

## Known limitations / notes

- iPhones cap custom (manual) exposure around 1 s; the app reads the real
  limit at runtime and never exceeds it.
- Requires **Full** Photos access (album creation isn't possible with
  add-only or limited access).
- The UI is portrait-locked, but `RotationCoordinator`'s horizon-level capture
  angle is applied to each photo, so shooting landscape on the tripod still
  produces correctly-oriented files.
- `photoQualityPrioritization` is `.balanced`; with custom exposure the system
  does not apply multi-frame merges (Deep Fusion etc.), so each JPEG reflects
  the requested exposure.
- Volume-button shutter needs iOS 17.2+; on 17.0/17.1 use the on-screen
  shutter with the 2 s timer.
