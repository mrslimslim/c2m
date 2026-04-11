# Contributing to CTunnel

Thanks for helping improve CTunnel.

## Before You Start

- Read the [README](./README.md) for the product overview and local setup.
- Check the existing docs in [`docs/`](./docs/) before opening a new issue or PR.
- Use the public name `CTunnel` in docs, screenshots, and release-facing copy.
- Keep the existing internal `codepilot-*` crate and module names unless a change is required for compatibility or a focused cleanup.

## Local Development

Recommended verification flow from the repo root:

```bash
./bin/ctunnel preflight
```

If you only need the Swift package tests:

```bash
swift test --package-path packages/ios/CodePilotKit
```

If you only need the Rust workspace:

```bash
cargo test --workspace
```

## Pull Requests

- Keep PRs focused and explain any user-visible behavior changes.
- Add or update tests when behavior changes.
- Update docs when setup, release, privacy, or support expectations change.
- Do not commit personal signing settings, local environment files, API keys, or certificates.

## iOS Release Builds

The repo intentionally does not track a personal `DEVELOPMENT_TEAM`. For local archive builds, pass your team id at build time or set it in Xcode locally:

```bash
xcodebuild \
  -project packages/ios/CodePilotApp/CodePilot.xcodeproj \
  -scheme CTunnel \
  -configuration Release \
  DEVELOPMENT_TEAM=<YOUR_TEAM_ID> \
  archive
```

## Reporting Problems

- Use the bug report template for reproducible defects.
- Use the feature request template for roadmap ideas.
- Use [SECURITY.md](./SECURITY.md) for vulnerabilities and sensitive reports.
