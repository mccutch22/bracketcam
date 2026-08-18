# TestFlight setup — one-time checklist

Once this is done: no more Sideloadly, no more 7-day expiry. Builds go
straight from GitHub to the TestFlight app on your phone (and to anyone you
invite by email). Everything below happens in a web browser.

## 1. Find your Team ID

- Go to https://developer.apple.com/account → scroll to **Membership
  details** → copy the **Team ID** (10 characters, like `A1B2C3D4E5`).

## 2. Register the app's identity

- Still on developer.apple.com: **Certificates, Identifiers & Profiles** →
  **Identifiers** → blue **+** → **App IDs** → **App** → Continue.
- Description: `Photo Dash`. Bundle ID: **Explicit**, exactly
  `com.photodash.app`. Don't tick any capabilities. **Register**.

## 3. Create the app in App Store Connect

- Go to https://appstoreconnect.apple.com → **My Apps** → blue **+** →
  **New App**.
- Platform: iOS. Name: `Photo Dash` (if Apple says the name is taken, try
  `Photo Dash HDR` — the name on this page doesn't change the app itself).
  Primary language: English (U.S.). Bundle ID: pick `com.photodash.app`.
  SKU: `photodash1`. Access: Full Access. **Create**.

## 4. Create an API key (lets GitHub sign & upload for you)

- App Store Connect → **Users and Access** → **Integrations** tab →
  **App Store Connect API** → **Team Keys** → blue **+**.
- Name: `GitHub CI`. Access: **App Manager**. **Generate**.
- Click **Download API Key** (.p8 file) — you get ONE chance; keep the file.
- Note the key's **Key ID** (in the table row) and the **Issuer ID**
  (shown at the top of the page).

## 5. Add four secrets to the GitHub repo

- Go to https://github.com/mccutch22/bracketcam → **Settings** →
  **Secrets and variables** → **Actions** → **New repository secret**,
  four times:

| Name | Value |
|---|---|
| `APPLE_TEAM_ID` | the Team ID from step 1 |
| `ASC_KEY_ID` | the Key ID from step 4 |
| `ASC_ISSUER_ID` | the Issuer ID from step 4 |
| `ASC_KEY_P8` | open the downloaded .p8 file in Notepad, copy EVERYTHING (including the BEGIN/END lines), paste |

## 6. Run the TestFlight workflow

- Repo → **Actions** tab → **TestFlight** (left sidebar) → **Run workflow**
  → green **Run workflow** button.
- Takes ~15 minutes. Green check = the build is uploading/processing.

## 7. Install on your phone

- App Store Connect → **Photo Dash** → **TestFlight** tab. The build
  appears after a few minutes of "Processing".
- Under **Internal Testing** → blue **+** to create a group (call it
  `Team`) → add yourself as a tester (your Apple ID email).
- On your iPhone: install the **TestFlight** app from the App Store, sign
  in, accept the invite (email or in-app), install Photo Dash.

## From then on

- New build: just run the TestFlight workflow again (or ask Claude to wire
  it to run on every push). TestFlight notifies your phone; updates install
  in one tap. Builds last 90 days.
- To invite other users: TestFlight tab → your group → add their email.
  Internal testers must be added as users in Users and Access; for
  arbitrary outside testers use External Testing (first build needs a quick
  Beta App Review by Apple, usually about a day).
