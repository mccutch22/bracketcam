# BracketCam — Build & Install from a Windows PC (no Mac needed)

You can't compile iOS apps on Windows, but GitHub will do it for you on their
free cloud Macs, and a free Windows tool installs the result on your iPhone.

The pipeline:

1. **GitHub Actions** (cloud) compiles the code into `BracketCam.ipa` —
   the workflow in `.github/workflows/build-ipa.yml` does this automatically.
2. **Sideloadly** (free Windows app) installs the `.ipa` onto your iPhone over
   USB, signing it with your everyday Apple ID. No paid developer account.

What you need: a free GitHub account, your Apple ID, a USB cable, and iTunes
installed on the PC (for the iPhone drivers).

Known trade-offs of free-Apple-ID signing: the app expires after **7 days**
(reinstalling takes 2 minutes and keeps all settings — see step 6), and you
can have at most 3 sideloaded apps at once.

---

## 1. Put the code on GitHub

1. Create a free account at github.com if you don't have one.
2. Create a new repository: github.com/new → name it `bracketcam` →
   **Public** (public repos get unlimited free build minutes; private ones
   have a monthly cap) → Create repository. Don't add a README.
3. In PowerShell, from the `BracketCam` folder, run (replace `YOURUSERNAME`):

   ```powershell
   cd "C:\Users\jeffm\OneDrive\claude football chess\BracketCam"
   git init -b main
   git add .
   git commit -m "BracketCam initial"
   git remote add origin https://github.com/YOURUSERNAME/bracketcam.git
   git push -u origin main
   ```

   The first push opens a browser window to sign in to GitHub — approve it
   (Git Credential Manager handles the rest, no token setup needed).

## 2. Let GitHub build the .ipa

1. On your repo page, open the **Actions** tab. A "Build IPA" run starts
   automatically after the push (takes ~10 minutes).
2. When it shows a green check, click the run → scroll to **Artifacts** →
   download **BracketCam-ipa**.
3. Unzip it — inside is `BracketCam.ipa`. Keep this file; you'll reuse it
   every week.

Every future code change is the same loop: edit → `git add . ; git commit -m "..." ; git push`
→ download the new artifact. You can also trigger a build manually from the
Actions tab ("Run workflow").

## 3. Prepare the PC

1. Install **iTunes** — get it from Apple's website (apple.com/itunes) rather
   than the Microsoft Store if you have a choice; Sideloadly needs its device
   drivers. Launch it once.
2. Install **Sideloadly** from https://sideloadly.io (Windows 64-bit).

## 4. Apple ID password note

Sideloadly needs your **real Apple ID password** — app-specific passwords are
NOT supported (it has to reach Apple's signing service, which rejects them).
With two-factor auth on, after the password Sideloadly shows a separate box for
the 6-digit code sent to your trusted device. If you'd rather not use your main
Apple ID, create a second free Apple ID just for sideloading (optional).

## 5. Install onto the iPhone

1. Connect the iPhone by USB, unlock it, tap **Trust This Computer**.
2. Open Sideloadly: your iPhone should appear in the device dropdown.
3. Drag `BracketCam.ipa` into Sideloadly, enter your Apple ID and real password,
   click **Start**, and enter the 6-digit 2FA code in the box that appears.
4. First time only, on the iPhone:
   - **Settings → General → VPN & Device Management** → tap your Apple ID
     under "Developer App" → **Trust**.
   - **Settings → Privacy & Security → Developer Mode** → On → restart the
     phone and confirm. (This toggle only appears after a sideloaded app is
     installed.)
5. Launch BracketCam. Grant **Camera** access; after your first capture, grant
   Photos access and choose **Full Access** (album creation doesn't work with
   "Add Photos Only").

## 6. Weekly refresh

Free-Apple-ID apps stop launching after 7 days. Fix: plug in the iPhone and
re-run step 5 with the same `.ipa` — no rebuild needed, data and permissions
survive. If that gets old, **AltStore** (altstore.io) can auto-refresh over
Wi-Fi while its companion AltServer runs on the PC; the ipa installs the same way.

---

## Using the app

1. Phone on the tripod, frame the shot (0.5× ultra wide is the default lens).
2. **Tap the preview** on your subject to set the focus/metering point (AF
   locks after a single scan).
3. Optional: toggle the **timer** icon for a 2-second delay, or use the
   **volume buttons** as the shutter (iOS 17.2+) so you never touch the screen.
4. Tap the shutter. The app meters, then fires 6 JPEGs from −6 to +4 EV
   (darkest → brightest) and saves to Photos → Albums →
   **RE Brackets → Bracket <date time>** — one album per set.
5. During capture the preview freezes and a "keep the phone still" overlay
   shows — long exposures slow the camera stream to a crawl; this is normal.
   A dark room can take 20–30 seconds for the full set.

Warnings:
- **VERY DARK** (orange): even at max ISO and the shutter cap, the +4 frame
  can't reach its target — deep shadows may stay underexposed.
- **BASE ISO** (green): the whole bracket is at the sensor's lowest ISO
  (best case for noise).

## Troubleshooting

- **Actions run fails**: open the run, click the failed step, and copy the
  first error lines back to Claude — usually a one-line code fix, then push again.
- **Sideloadly can't see the iPhone**: iTunes not installed / phone locked /
  cable is charge-only. Launch iTunes once and confirm it sees the phone.
- **"Guru Meditation" or provisioning errors in Sideloadly**: usually the
  Apple ID hit its 10-App-ID-per-week limit or 2FA wasn't approved; wait or
  re-try with the app-specific password.
- **App installed but won't open ("Untrusted Developer" / Developer Mode)**:
  step 5.4.
- **Black preview**: camera permission denied — Settings → BracketCam → Camera.
- **"Save failed … Photos access denied"**: Settings → BracketCam → Photos →
  **Full Access**.
- **App stopped launching after a week**: signing expired — step 6.
