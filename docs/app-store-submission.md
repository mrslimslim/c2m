# CTunnel App Store Submission Guide

This document is the release-facing checklist for preparing the public iOS app submission.

## App Identity

| Field | Value |
| --- | --- |
| App name | `CTunnel` |
| Display name | `CTunnel` |
| Default bundle id | `com.ctunnel.app` |
| UI test bundle id | `com.ctunnel.app.uitests` |
| Primary category | `Developer Tools` |
| Secondary category | `Utilities` or `Productivity` |
| Deployment target | iOS 17.0 |
| Device families | iPhone and iPad |

## Public URLs To Publish Before Submission

Publish stable HTTPS URLs for:

- privacy policy
- support page
- project homepage or marketing site

The repository versions live here and are ready to adapt for hosted URLs:

- [`PRIVACY.md`](../PRIVACY.md)
- [`SUPPORT.md`](../SUPPORT.md)

## App Store Connect Metadata

Complete these items in App Store Connect before submitting:

- app name, subtitle, keywords, and description
- support URL and privacy policy URL
- iPhone screenshots
- iPad screenshots
- review contact information
- age rating answers based on the shipped binary
- pricing and territory availability

## Archive And Upload

The repo does not track a personal signing team. Pass your own Apple team id at archive time:

```bash
xcodebuild \
  -project packages/ios/CodePilotApp/CodePilot.xcodeproj \
  -scheme CTunnel \
  -configuration Release \
  -archivePath build/CTunnel.xcarchive \
  DEVELOPMENT_TEAM=<YOUR_TEAM_ID> \
  archive
```

Then upload the archive with Xcode Organizer or your normal App Store Connect pipeline.

## Export Compliance

The iOS app contains end-to-end encryption primitives used for bridge pairing and encrypted transport:

- Curve25519 key agreement
- HKDF-SHA256 key derivation
- AES-256-GCM message encryption

Before submission:

1. Complete the App Store Connect export compliance questionnaire.
2. Answer based on the shipped binary and current encryption use.
3. If Apple requests follow-up documentation, stop the submission until the export review is complete.

## Review Notes Template

Use a reviewer note close to the following:

> CTunnel pairs an iPhone with a companion bridge running on the user's Mac.
> To review the primary flow:
> 1. Install `codex` and `cloudflared` on a Mac.
> 2. Clone `https://github.com/mrslimslim/c2m.git`.
> 3. Run `codex login`.
> 4. Run `./bin/ctunnel preflight`.
> 5. Run `ctunnel` from the repo root.
> 6. Open the iPhone app and scan the QR code shown by the bridge.
> 7. Open the paired project, tap `New Session`, and send `Summarize this repository layout`.
> 8. Verify that the session streams output and that file / diff views open successfully.
>
> If reviewer setup is inconvenient, attach a short demo video showing the full pairing and session flow.

## Release Verification

Before pressing submit:

- rerun `./bin/ctunnel preflight`
- do a real-device smoke pass on camera, local network, LAN pairing, tunnel pairing, new session, continue session, cancel turn, file view, diff view, relaunch restore, and diagnostics redaction
- confirm the final archive still matches the current App Privacy answers
