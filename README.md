# ctunnel

Run Codex on your Mac. Control it from your iPhone over Cloudflare Tunnel.

`ctunnel` is a mobile-first bridge for AI coding agents. It lets you start a Codex-backed coding session on your machine, expose it through Cloudflare Tunnel, and connect to it from a native iPhone client.

> The public product and CLI are now `CTunnel` / `ctunnel`. Some internal crate and package names still use the older `codepilot-*` naming while the repo is being renamed.

## Why this exists

- Check on long Codex runs from your phone instead of sitting at your desk
- Start, continue, and cancel coding sessions remotely
- Inspect file changes and diffs from a mobile UI
- Pair over QR with end-to-end encrypted transport
- Use Cloudflare Tunnel instead of opening your laptop directly to the internet

## What makes it interesting

- Native iOS client instead of a thin web view
- Codex-first CLI workflow with a single default command: `ctunnel`
- QR pairing plus encrypted message transport
- Session replay, diff viewing, slash workflows, and project-scoped file access
- Rust workspace for protocol, bridge, runtime, and relay components

## 60-second mental model

1. You run `ctunnel` on your Mac inside a project directory.
2. It starts the Rust bridge, launches a Cloudflare Tunnel, and prints a QR code.
3. You scan the QR code from the iPhone app.
4. Your phone becomes a remote control for the Codex session running on your machine.

## Quick start

### Prerequisites

- macOS
- Rust stable
- `cloudflared`
- `codex`
- a working Codex CLI login
- Xcode if you want to build the iPhone app locally
- optional: `wrangler` if you want to deploy the relay worker

Install the missing pieces:

```bash
brew install cloudflared
rustup toolchain install stable
rustup target add wasm32-unknown-unknown
```

Authenticate Codex once:

```bash
codex login
codex login status
```

### Clone and verify

```bash
git clone https://github.com/mrslimslim/c2m.git
cd c2m
./bin/ctunnel preflight
```

### Expose `ctunnel` as a command

This repo already ships a real CLI entrypoint at `bin/ctunnel`.

```bash
ln -s "$(pwd)/bin/ctunnel" ~/.local/bin/ctunnel
```

Make sure the target directory is in your `PATH`.

### Start the bridge

Run `ctunnel` from the project directory you want the bridge to expose:

```bash
cd /absolute/path/to/project
ctunnel
```

By default this points the bridge at your current directory. For example, if you run it inside `/absolute/path/to/project`, the bridge starts with:

```bash
cargo run -p codepilot-bridge -- --agent codex --tunnel --dir /absolute/path/to/project
```

To point at a different working directory:

```bash
CTUNNEL_DIR=/absolute/path/to/project ctunnel
```

## Commands

```bash
ctunnel
ctunnel start
ctunnel preflight
ctunnel relay deploy
ctunnel --help
```

### Command guide

- `ctunnel`: start the default Codex + Tunnel bridge flow
- `ctunnel start`: explicit form of the default command
- `ctunnel preflight`: run automated environment, build, test, and iOS simulator checks
- `ctunnel relay deploy`: deploy the Cloudflare relay worker
  Requires a globally available `wrangler` CLI.

## Current workflow

### 1. Run automated checks

```bash
ctunnel preflight
```

### 2. Start the tunnel bridge

```bash
ctunnel
```

### 3. Build the iPhone app

```bash
xcodebuild -project packages/ios/CodePilotApp/CodePilot.xcodeproj -scheme CTunnel -destination 'generic/platform=iOS Simulator' build
```

### 4. Scan the QR code from the app

Once connected, you can:

- create a new session
- continue a session
- cancel a busy turn
- request a file
- inspect diffs
- reconnect to a saved project

## Repo layout

```text
crates/
├── codepilot-protocol
├── codepilot-core
├── codepilot-agents
├── codepilot-bridge
└── codepilot-relay-worker

packages/
└── ios/
```

### High-level components

- `codepilot-protocol`: wire models and message formats
- `codepilot-core`: pairing, crypto, storage, diff, and security
- `codepilot-agents`: Codex and Claude adapter layer
- `codepilot-bridge`: the Rust runtime and CLI bridge
- `codepilot-relay-worker`: optional Cloudflare Workers relay
- `packages/ios`: native iPhone client and shared Swift packages

## Status

This project is promising, but it is still early.

Today it is best for:

- builders who are comfortable cloning a repo
- developers who can build the iOS app locally
- people who want a Codex-first remote workflow

Current reality:

- the best-supported path is `Codex + Cloudflare Tunnel`
- the iPhone client is real, but still geared toward self-use and fast iteration
- some internal crates, modules, and storage identifiers still reflect the legacy `codepilot-*` naming

## Docs

- [Technical overview](./docs/technical.md)
- [Release preflight checklist](./docs/release-preflight-checklist.md)
- [Debugging guide](./docs/debugging.md)
- [iOS manual test checklist](./docs/ios-testing.md)
- [App Store submission guide](./docs/app-store-submission.md)
- [Privacy policy](./PRIVACY.md)
- [Support](./SUPPORT.md)
- [Contributing](./CONTRIBUTING.md)
- [Security policy](./SECURITY.md)

## License

CTunnel is dual-licensed under either:

- [MIT](./LICENSE-MIT)
- [Apache-2.0](./LICENSE-APACHE)

## If you want more GitHub stars

The README alone will help, but the biggest star multipliers are usually:

1. Put a short GIF or screenshot above the fold showing QR scan -> phone session -> diff view.
2. Keep the repo, app, and CLI surfaces consistently named `CTunnel`.
3. Keep the setup path to one minute or less: clone, `ctunnel preflight`, `ctunnel`.
4. Lead with a very specific hook:
   `Control Codex on your Mac from your iPhone over Cloudflare Tunnel.`
5. Post a tight demo clip on X, Hacker News, and Reddit with the exact same framing as the README title.
6. Show one opinionated use case instead of a broad platform story.

## Contributing

Issues and PRs are welcome. Please read [CONTRIBUTING.md](./CONTRIBUTING.md) before opening a PR, and use [SECURITY.md](./SECURITY.md) for private vulnerability reporting.

If this project saves you time or gives you a new workflow idea, star the repo. It helps more Codex-heavy builders discover it.
