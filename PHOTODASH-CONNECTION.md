# PhotoDash camera connection — 2.1

The Library sends selected complete JPEG stacks to the same PhotoDash account and home used on the website. Capture, exposure ladders, and Photos originals are unchanged.

1. Capture stacks, then open Library and select their thumbnails.
2. Tap Send to PhotoDash. Sign in with the same Google account as the website and confirm Connect PhotoDash Camera.
3. Choose an existing home, or enter an address to save a new draft.
4. Tap Upload & process selected stacks. Keep the app open while uploading.
5. Open View processing & finished photos. On the website, sign in with the same account if needed. The home’s bracket page shows Esoft processing and delivered results; add a finished photo to its gallery for marketing products.

The current build targets the existing Hostinger temporary origin in PhotoDashConfig. Change that one public origin when the domain launches. No service secrets belong in the app.

## Pilot limits

- Processing uses Esoft and the server’s existing superuser allowlist. This is currently the Esoft development account; checkout is not enabled.
- StagerAI remains an alternative on the website for the superuser.
- Full Photos access is required to read the captured albums. Each selected album must contain 2–7 JPEG exposures, at most 25 MB each and 100 MB per stack.
- Uploads run in the foreground. If interrupted, select the same stacks and home to continue. The journal reuses each request ID and checks the saved server job before submission. A failed partial server upload needs attention on the website; it is never silently submitted as a complete stack.
- Saved submission labels are the last state observed by the phone. The website shows the latest delivery state.
- Original resources are read using PHAssetResourceManager without JPEG re-encoding. Multipart uploads are streamed from a temporary disk file, one stack at a time.
- Upload journal records are separate from legacy orders.json, which is preserved. Old placeholder orders do not represent actual server submissions and are not automatically submitted.

## Authentication

ASWebAuthenticationSession uses the existing web Google flow. A user-confirmed, five-minute authorization code is bound to a random S256 PKCE verifier and consumed atomically. The returned 30-day mobile token is stored in the device Keychain; only its hash is stored server-side. Mobile tokens work only on mobile endpoints, with home ownership and pilot checks. Sign out revokes the token. No Google, AWS, Esoft, or website API key is embedded in the binary.

## Validation

The Build IPA workflow compiles device Release builds on main and codex branches. The manual TestFlight workflow can release this branch to the existing internal beta. Before considering this ready for customers, test a physical-phone Google sign-in, interrupted upload/retry, and complete Esoft delivery with actual captured brackets. Production Esoft access and payment gating are separate launch work.
