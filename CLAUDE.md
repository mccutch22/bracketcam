# BracketCam — 6-Frame HDR Bracket Camera for Real Estate

Native iOS app (SwiftUI + AVFoundation, iOS 17+, iPhone, physical device only).
One tap captures a fixed 6-shot exposure bracket on a tripod, optimized for
lowest noise, for AI-based HDR merge/editing downstream. Output is JPEG, saved
to Photos in one album per set.

Built for/with a non-developer user on Windows: compiled by GitHub Actions,
installed via Sideloadly (see SETUP.md). Tested on an iPhone 12.

## File map

| File | Responsibility |
|---|---|
| `Sources/BracketCamApp.swift` | App entry point |
| `Sources/ContentView.swift` | UI: preview, lens buttons, badges, shutter, capture overlay |
| `Sources/CameraManager.swift` | Session setup, format selection, metering, capture sequence |
| `Sources/BracketPlanner.swift` | Exposure math: ladder, ISO selection, `Tuning` constants |
| `Sources/CameraPreviewView.swift` | Preview layer, tap-to-focus, pinch zoom, volume shutter |
| `Sources/PhotoLibrarySaver.swift` | Photos album/folder creation and saving |
| `project.yml` | XcodeGen spec — all Info.plist keys live here |
| `.github/workflows/build-ipa.yml` | CI build producing the unsigned .ipa |

## The exposure ladder (fixed, 6 frames)

`Tuning.ladderEVs = [-6, -4, -2, 0, +2, +4]`, all relative to the scene meter,
captured darkest → brightest. There is no metered highlight-protection frame
(v1 had one): field experience showed a fixed −6 EV floor protects window
highlights in any realistic interior, with zero moving parts. The histogram
pipeline was removed along with it — the app has no video data output at all.

## Metering

While idle the device runs continuous auto-exposure (tap the preview to set
the AF/AE point; a single-scan AF then holds the lens). At capture, after
waiting for AF/AE/AWB convergence (`isAdjusting*` polling, 2.5 s timeout), we
read the AE solution and form the meter product `E = exposureDuration × ISO`.
Each ladder frame's target exposure product is `E × 2^EV`. Focus and white
balance are locked for the bracket and restored after (v2 bug: focus stayed
locked forever).

## ISO selection (per frame, lowest possible)

For a target product `P`:

1. `T = clamp(P / minISO, minExposureDuration, cap)` — stretch the shutter to
   the cap at base ISO first (tripod assumed, no stabilization needed).
2. `ISO = clamp(P / T, minISO, maxISO)` — raise ISO only for what the shutter
   can't deliver.

Cap = `min(1.0 s, format effective max)`. Bright scenes run the whole bracket
at base ISO (green **BASE ISO** badge). If even maxISO at the cap can't reach
the +4 frame, the orange **VERY DARK** badge shows.

## Long exposures — the three traps (hard-won on a real iPhone 12)

1. **A photo's exposure can never exceed one video frame.** The format's real
   shutter ceiling is `min(maxExposureDuration, longest supported frame
   duration)` — compute limits from that.
2. **iOS will not stretch frames for you.** Merely raising
   `activeVideoMaxFrameDuration` (permission, v4) still left the stream at
   ~15 fps and every exposure clamped to 1/15 s. `setCustomExposure` must PIN
   the frame length: `activeVideoMinFrameDuration =
   activeVideoMaxFrameDuration = exposure / 0.95` (clamped to the format's
   range). The ~5% slack is not optional: pinning frame duration EXACTLY equal
   to the exposure (v5) left no sensor readout time and starved the pipeline —
   captures hung for minutes or failed with a generic AVFoundation error on
   the long frames. The exposure cap is correspondingly
   `min(maxExposureDuration, maxFrameDuration × 0.95)`. The preview crawls
   during the bracket (capture overlay explains this);
   `restoreContinuousModes` resets both to `.invalid` (= format defaults).
3. **Zero-shutter-lag fabricates photos from buffered preview frames.**
   `photoOutput.isZeroShutterLagEnabled = false` forces a real exposure with
   the committed shutter/ISO — this must STAY off.
4. **Processing prioritization is per-frame (hybrid).** `.speed` everywhere
   (v6) banded bright gradients — visible in the user's Esoft AI merge.
   `.quality` everywhere (v7) starved at the pinned ~1 fps stream and timed
   out, aborting brackets. Hybrid (v8): frames with exposure ≤
   `Tuning.qualityProcessingMaxExposure` (0.1 s) get `.quality`, longer frames
   `.speed`. Any failed frame retries once with `.speed`. Status line shows
   "HQ"/"fast". NOTE: hybrid does NOT fix banding around ceiling lights —
   that gradient lives in the LONG frames (concentric-ring posterization seen
   in the user's Esoft output). RAW is the real fix (below).

## RAW mode (the actual banding fix)

`rawEnabled` (UI pill "RAW"/"JPG", persisted, default RAW) captures Bayer DNG
via `AVCapturePhotoSettings(rawPixelFormatType:)` — works on non-Pro iPhone 12.
RAW skips the ISP entirely, so processing banding cannot exist and gradients
are 12-bit. An embedded JPEG thumbnail is included for previews. Saved DNGs
get real filenames (`Bracket_..._1of6.dng`). The user converts DNG → JPG in
Lightroom (best) or via iCloud "Most Compatible" export — their AI editors
(Esoft, autohdr.com) only accept JPG. Caveats: `videoZoomFactor` does NOT
crop RAW output (pinch zoom is preview-only in RAW mode); ~25 MB per frame;
if a lens reports no RAW formats the capture silently falls back to JPEG
(status suffix shows which).

**Never trust the request — watch the hardware.** The capture status line
shows `device.exposureDuration`/`device.iso` as accepted by the sensor for
each frame; verify saved files with EXIF (Photos → swipe up). Watchdogs
guarantee forward progress: 6 s on exposure commit, 20 s per photo — a stuck
frame errors out and restores the camera instead of hanging the bracket.

## Format selection (per lens, queried at runtime)

The shutter cap is `min(1 s, device max)`, so every format reaching the cap is
exposure-equivalent. Among those (fallback: all formats), pick by **largest
photo resolution → widest `videoFieldOfView` → largest video resolution**.
Never pick purely by `maxExposureDuration`: low-res video formats also have
long exposures, and one of those gave a pixelated, cropped preview (v2 bug).
The preview layer uses `.resizeAspect` (letterboxed, like Apple's Camera) so
the full captured frame is always visible.

## Lenses & zoom

`Lens` enum: 0.5× ultra wide (default — real estate), 1× wide, Tele.
Discovered at runtime; capsule buttons switch. Switching swaps the session
input and re-runs all per-device setup (limits differ per lens; ultra wide is
fixed-focus on many iPhones — `isFocusModeSupported` guards handle it). The
gray "This lens: max shutter … • base ISO …" line shows the active lens's true
hardware limits. Pinch = digital zoom (crop, applies to saved photos), yellow
"crop" tag warns when active, resets on lens switch.

## Capture sequence

1. Optional 2 s self-timer; volume buttons fire the shutter on iOS 17.2+
   (`AVCaptureEventInteraction`) — both avoid tripod shake.
2. Wait for AF/AE/AWB convergence, read meter product E.
3. Lock focus + white balance.
4. For each of the 6 frames (darkest first): pin frame duration, commit custom
   exposure (completion + 0.35 s settle), capture one JPEG (flash off, max
   photo dimensions). A dim overlay covers the frozen preview.
5. Restore continuous AE/AWB/AF and normal frame rates.
6. Save all 6 JPEGs in one Photos transaction: album `Bracket yyyy-MM-dd
   HH.mm.ss` inside the top-level **RE Brackets** folder.

## Known limitations / notes

- Requires **Full** Photos access (album creation).
- Portrait-locked UI; `RotationCoordinator`'s horizon-level capture angle
  still orients landscape shots correctly.
- A dark-scene bracket takes a while: the +2/+4 frames can each run 1 s
  exposures plus pipeline settle — tens of seconds total is normal.
- Free-Apple-ID sideloading expires every 7 days (re-run Sideloadly).
