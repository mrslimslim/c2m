# iOS Manual Test Checklist

This checklist is the repeatable acceptance guide for the current native iOS client. It is written for real-device testing first, because camera permissions, local-network prompts, and QR pairing are not meaningfully covered by the simulator alone.

## Current Runtime Assumptions

- Rust Cargo workspace is the default build and test runtime for the repository.
- End-to-end iOS device QA still uses the legacy bridge launch path as a temporary fallback until the final runtime cutover removes it.
- The app may save multiple connection configs, but it only keeps one live bridge connection at a time.
- LAN is the primary baseline path.
- Relay is supported and should be verified, but it is not the default self-use path.
- Saved projects persist across launches, and bridge-side pairing material now stays stable by default for the same working directory.
- Re-scanning may still be required if the bridge advertises a different reachable host, uses a different working directory, or the pairing state is intentionally reset.
- The slash command menu is protocol-driven. The bridge chooses the slash catalog by adapter type and detected adapter version.

## Recommended Test Environment

- One physical iPhone running the latest local build or TestFlight build.
- One Mac running the CodePilot bridge on the same LAN as the phone.
- Optional: a reachable Relay deployment for cross-network verification.
- A test repo with at least one readable file such as `README.md`.

## Preflight

1. Build the workspace:

```bash
pnpm run build
```

2. Build the temporary legacy bridge fallback used for device QA:

```bash
pnpm run legacy:build
```

3. For LAN verification, start the legacy bridge binary:

```bash
pnpm --filter @codepilot/bridge exec node ./dist/bin/codepilot.js --dir /absolute/path/to/test-repo
```

4. For Relay verification, start the legacy bridge in relay mode:

```bash
pnpm --filter @codepilot/bridge exec node ./dist/bin/codepilot.js --relay --dir /absolute/path/to/test-repo
```

5. Confirm the bridge terminal prints a QR code or pairing payload containing `host`/`port` or `relay`/`channel`, plus `bridge_pubkey` and `otp`.
6. If you are validating Codex slash commands, also confirm `codex --version` matches the catalog you expect. The current baseline is `codex-cli 0.116.0`.
7. Install the iOS app on a physical device.
8. If you want a clean run, delete any previously saved projects in the app before starting.

## Pass Criteria

- Pairing succeeds from QR scan and from pasted or manually entered payloads.
- The app can connect, show sessions, start a new session, continue a session, cancel a busy turn, and request a file.
- Code change events open a dedicated diff viewer without inlining full patches into the session timeline.
- Large diffs stay incrementally loaded: the first view shows only the initial hunk per file, and later hunks load on demand.
- The slash menu reflects the bridge-provided catalog, including nested workflows, current/default config badges, and disabled reasons.
- `/model` updates both `model` and `modelReasoningEffort`, and `/permissions` updates `approvalPolicy` and `sandboxMode`.
- Diagnostics are useful and redact sensitive values such as `token`, `otp`, and ciphertext.
- Relay and LAN both work as intended for the currently supported single-active-connection runtime model.

## Scenario 1: Fresh LAN Pairing Via QR

**Setup**

- Bridge is running in LAN mode on the same Wi-Fi or local network as the phone.
- The bridge terminal is showing a fresh QR code.

**Steps**

1. Launch the iOS app.
2. Tap the QR button from the home screen.
3. Allow camera access if prompted.
4. Scan the bridge QR code.
5. If iOS shows the local network permission prompt, allow it.
6. Wait for the project card to appear and transition from connecting to live.
7. Open the project detail screen.

**Expected**

- A saved project is created automatically.
- The project reaches a connected state.
- The project detail screen either shows existing sessions or the empty connected state with a `New Session` action.
- Diagnostics show a connect attempt followed by a connected state.

**Failure clues**

- If the QR scan succeeds but connection stalls, check the Diagnostics screen first.
- If the app never reaches connected, compare the app state with bridge terminal output.
- If the wrong LAN address was advertised, note it as a pairing-host issue rather than an iOS-only bug.

## Scenario 2: Pairing Via Pasted Payload

**Setup**

- Bridge is running and you have a full pairing payload from terminal output or another trusted source.

**Steps**

1. Open the add-project sheet.
2. Paste the full payload into the payload field.
3. Tap `Connect`.

**Expected**

- The payload parses without error.
- A saved project is created or the existing matching project is reused.
- The app connects and the project opens normally.

**Failure clues**

- `Could not parse pairing payload.` means the payload format is incomplete or malformed.
- If parsing works but the connection fails, capture the diagnostics log and the bridge-side terminal output together.

## Scenario 3: Manual LAN Entry

**Setup**

- Bridge is running in LAN mode.
- You know the host, port, `bridge_pubkey`, and `otp`.

**Steps**

1. Open the add-project sheet.
2. Expand `Manual Configuration`.
3. Choose `LAN`.
4. Enter host, port, optional token, bridge public key, and OTP.
5. Tap `Connect`.

**Expected**

- The app saves the project and connects successfully.
- Returning to the home screen shows the new project in the saved list.

## Scenario 4: Relay Pairing

**Setup**

- Bridge is running with `--relay` or `--relay-url ...`.
- The phone can reach the relay endpoint.

**Steps**

1. Pair using the relay QR code or a pasted relay payload.
2. Open the project after it appears in the saved list.
3. Wait for the connection to settle.

**Expected**

- The project connects without needing local-network discovery.
- Diagnostics should show relay-related connection activity rather than a LAN host/port attempt.
- The project behaves the same as LAN once connected.

**Failure clues**

- If the relay path pairs but never reaches connected, capture both app diagnostics and relay or bridge logs.
- If LAN works but relay does not, treat it as a relay transport problem first, not a session UI problem.

## Scenario 5: Saved Connection Restore On Relaunch

**Setup**

- At least one project has already been paired and saved successfully.

**Steps**

1. Force-quit the app.
2. Relaunch the app.
3. Confirm the saved project list is still present.
4. Open one saved project.

**Expected**

- Saved project metadata persists across cold launch.
- Opening a saved project triggers an automatic reconnect attempt.
- The app reconnects if the bridge is still reachable with compatible pairing material.

**Current limitation**

- If the bridge restarts with a different advertised endpoint, a different working directory, or a deliberately reset pairing state, the saved project may fail to reconnect and require re-pairing.

## Scenario 6: Single-Active-Connection Behavior

This is intentional behavior in the current self-use runtime model.

**Setup**

- Save at least two projects, for example one LAN project and one Relay project.

**Steps**

1. Connect project A and confirm it is live.
2. Return to the home screen.
3. Connect project B.
4. Return to project A.

**Expected**

- Project B becomes the active live connection.
- Project A is no longer actively connected.
- Sessions and file state shown in the app follow the active project only.
- No mixed session list or wrong-file routing appears when switching projects.

## Scenario 7: Create A New Session

**Setup**

- A project is connected.

**Steps**

1. Open the connected project.
2. Tap `New Session`.
3. Enter a prompt such as `Summarize this repository layout`.
4. Tap `Start Session`.

**Expected**

- A new session appears in the project.
- The app navigates into the new session once it is created.
- Timeline items begin to stream into the session.

## Scenario 8: Continue A Session

**Setup**

- At least one session already exists for the active project.

**Steps**

1. Open an existing session.
2. Send a follow-up command in the composer.

**Expected**

- The user command is appended to the timeline.
- The bridge response streams into the same session.
- The session state changes through busy and back to idle when work completes.

## Scenario 9: Cancel A Busy Turn

**Setup**

- Start a command that keeps the agent busy long enough to press cancel.

**Steps**

1. Open a running session.
2. While the session state is busy, tap the stop button in the composer row.
3. Wait for the session to settle.

**Expected**

- The cancel action does not crash the app.
- The session eventually leaves the busy state.
- Diagnostics do not show an unrecoverable transport failure caused by the cancel request.

## Scenario 10: Request And Open A File

**Setup**

- A connected session exists.
- The bridge working directory contains a readable file such as `README.md`.

**Steps**

1. Open the session detail screen.
2. Tap the file request button in the navigation bar.
3. Request a known path such as `README.md`.
4. Wait for the file chip to finish loading.
5. Open the file viewer from the chip.

**Expected**

- A loading chip appears first, then resolves into a file item.
- The file viewer opens and shows the requested contents.
- The file content belongs to the active project and active session, not a previously connected project.

## Scenario 10A: View A Diff From A Code Change Event

**Setup**

- A connected project has a session containing at least one `code_change` event.
- The changed turn should ideally include either:
  - one file with multiple hunks
  - or multiple changed files

**Steps**

1. Open the target session.
2. Expand the code change card.
3. Tap `View Diff`.
4. Wait for the dedicated diff screen to load.
5. Confirm the first hunk for each visible file renders.
6. Tap `Load next hunk` for a file that has additional hunks.
7. Tap `Open File` for one diff entry.

**Expected**

- The session timeline stays compact and does not inline the full patch.
- The diff screen opens as a separate view.
- The initial diff load renders only the first hunk for each file.
- Additional hunks load incrementally when requested.
- `Open File` still works as a fallback into the existing file viewer.

**Failure clues**

- If the diff screen opens but remains empty, check whether the corresponding `code_change` item has a replay event ID.
- If scrolling the session detail screen becomes noticeably worse after this feature lands, treat it as a timeline regression and inspect whether diff text leaked into the timeline path.
- If a file changed but shows no hunks, compare the current workspace state on the bridge with the original turn timing before treating it as an iOS rendering bug.

## Scenario 10B: Diff Viewer Performance And Large Patch Behavior

**Setup**

- Use a session with a `code_change` event that includes a relatively large patch.
- Prefer one example with:
  - at least 3 changed files
  - at least one file with 3 or more hunks
  - enough changed lines to make scrolling meaningful

**Steps**

1. Open the session detail screen and scroll through the surrounding timeline before opening the diff.
2. Confirm the code change card still looks like a compact summary rather than a giant inline patch.
3. Tap `View Diff`.
4. Measure the perceived time to first useful paint on the diff screen.
5. Scroll from the summary card through the initially loaded files.
6. Tap `Load next hunk` for one file, then keep scrolling.
7. Tap `Load next hunk` again on the same file if available.
8. Navigate back to the session detail screen.
9. Scroll the session detail screen again.
10. Re-open the same diff once more.

**Expected**

- Opening the diff does not cause a long blank screen before content appears.
- The first render shows file summaries and first hunks without waiting for every hunk in the patch.
- Loading the next hunk affects only that file section and does not visibly re-layout the whole page.
- Returning to the session detail screen does not leave the timeline in a heavier or jankier state.
- Re-opening the same diff should feel stable and should not duplicate file sections or hunks.

**Failure clues**

- If the session detail screen stutters before the diff is opened, check whether the timeline row started carrying full diff bodies.
- If pressing `Load next hunk` causes the entire page to jump or freeze, inspect whether state updates are too coarse-grained for per-file pagination.
- If re-opening the diff duplicates content, inspect whether the client appends initial hunks twice after a cached state restore.
- If the first paint is slow only for very large patches, capture the changed file count and total hunk count alongside the repro.

## Scenario 11: Slash Workflow Acceptance

**Setup**

- A project is connected over LAN or Relay.
- The bridge advertises `slash_catalog_v1`.
- For Codex, the version probe currently reports `codex-cli 0.116.0`.

**Steps**

1. Open a session composer or the new-session composer.
2. Type `/` and verify the menu lists protocol-driven commands such as `/model`, `/permissions`, and `/new`.
3. Confirm commands that are not implemented yet, such as `/review`, appear disabled with a reason instead of acting enabled.
4. Type `/model` or tap `/model`.
5. Choose a model such as `gpt-5.4`.
6. In the next layer, choose a reasoning level such as `Extra high`.
7. Verify config chips now reflect both the model and the reasoning effort.
8. Re-open the slash menu and choose `/permissions`.
9. Pick an approval policy, then pick a sandbox mode.
10. Verify those config chips update as well.
11. From an existing session, invoke `/new`, type a follow-up prompt, and send it.

**Expected**

- The slash menu is populated from bridge metadata rather than a client-side hard-coded list.
- `/model` renders as a nested workflow, not a flat chip picker.
- Choosing a reasoning level updates both `model` and `modelReasoningEffort`.
- Choosing `/permissions` updates both `approvalPolicy` and `sandboxMode`.
- Disabled commands remain visible but cannot be executed.
- `/new` is handled as a client action. In session detail, the next send starts a new session instead of continuing the current one.

## Scenario 12: Reconnect Behavior

**Setup**

- A project is already connected.

**Steps**

1. Interrupt connectivity:
   - for LAN, briefly disable Wi-Fi on the phone or stop the bridge, then restore it
   - for Relay, temporarily stop the relay path or disconnect the network
2. Watch the project state and diagnostics.
3. Restore connectivity.

**Expected**

- The app transitions through reconnecting or failed states without crashing.
- After connectivity returns, the app can reconnect or be manually reconnected.
- The diagnostics timeline captures the transition clearly enough to debug the failure.

## Scenario 13: Diagnostics Redaction

**Setup**

- Complete at least one connect flow and one command flow so diagnostics are populated.

**Steps**

1. Open the Diagnostics screen.
2. Review the transport timeline and log output.
3. Use the copy button if needed.

**Expected**

- Sensitive values are redacted in diagnostics output.
- Raw `token`, raw `otp`, and raw ciphertext should not be visible.
- The log remains readable enough to understand whether the failure was parse, handshake, transport, or reconnect related.

## Simulator Smoke Check

Use the simulator only for quick UI smoke tests:

- launch the app
- paste a payload manually
- confirm saved project persistence
- browse sessions already exposed by a reachable bridge

Do not treat simulator-only results as sufficient for QR scanning, camera permissions, or local-network permission validation.

## What To Capture For A Bug Report

- Whether the path was LAN or Relay.
- Whether pairing came from QR, pasted payload, or manual entry.
- Device model and iOS version.
- Whether the issue reproduces after app relaunch.
- A screenshot or copy of the Diagnostics screen.
- The matching bridge terminal log around the same timestamp.
