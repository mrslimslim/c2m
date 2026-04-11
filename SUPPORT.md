# CTunnel Support

This page is the public support guide for CTunnel.

## Self-Serve Checklist

Before opening an issue, please check:

- [README](./README.md) for setup and quick start
- [Debugging guide](./docs/debugging.md) for common failures
- [Release preflight checklist](./docs/release-preflight-checklist.md) for environment verification
- [iOS manual test checklist](./docs/ios-testing.md) for pairing and session smoke tests

## Opening a Bug Report

Use the bug report template and include:

- your macOS version, Xcode version, and iOS version
- `codex --version` and `cloudflared --version`
- whether the failure happened on LAN, Cloudflare Tunnel, or relay
- the exact command you ran
- Diagnostics output with secrets redacted

## Feature Requests

Use the feature request template for product ideas, workflow requests, and App Store feedback.

## Security

For vulnerabilities or sensitive disclosures, use the private reporting flow in [SECURITY.md](./SECURITY.md) instead of a public issue.
