# CTunnel Privacy Policy

Last updated: 2026-04-11

CTunnel is a local-first remote control app for AI coding sessions that run on your own Mac.

## What CTunnel Does Not Collect

CTunnel does not operate a hosted user account system, does not include advertising SDKs, and does not include product analytics SDKs in the current open-source build.

The iOS app does not send usage analytics, marketing identifiers, or crash telemetry to the CTunnel maintainer.

## Data Stored On Your Devices

To make the app usable, CTunnel stores some data locally:

- saved bridge connection metadata, such as connection names, hosts, ports, and relay URLs
- bridge secrets such as pairing OTPs, bridge public keys, and optional tokens
- local conversation snapshots so the iPhone app can restore session history and file state after relaunch
- local diagnostics visible to you inside the app

Connection metadata and conversation snapshots are stored on-device. Sensitive saved connection secrets are stored in the iOS Keychain.

## Permissions

CTunnel requests these permissions only when needed:

- Camera: used to scan pairing QR codes
- Local Network: used to connect to bridge instances on your LAN

## Network Traffic

The app connects to infrastructure that you control or explicitly choose:

- your local CTunnel bridge running on your Mac
- Cloudflare Tunnel endpoints created by your bridge
- the optional CTunnel relay service you configure

CTunnel's bridge protocol uses end-to-end encryption between the phone and the bridge. If you use Cloudflare Tunnel or the relay path, encrypted traffic may transit through Cloudflare infrastructure, but the project is designed so intermediaries cannot read message contents.

## File and Session Data

The app can request session output, file contents, and diffs from the CTunnel bridge that you pair with. Those files and session logs stay on your devices unless you choose to share them yourself.

## Your Choices

You can:

- remove saved connections in the app
- clear local app state by deleting the app
- delete bridge-side logs and project state on the Mac where the bridge runs

## Changes

If this policy changes materially, the repository copy will be updated before the change ships in a public App Store build.
