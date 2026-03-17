# Deep Testing And Optimization Design

**Topic:** CodePilot bridge/relay correctness hardening and testability improvements

**Goal:** Close the highest-risk correctness and security gaps while turning this review into repeatable regression coverage.

## Scope

- Add focused regression tests for:
  - `file_req` symlink escape
  - E2E handshake followed by plaintext downgrade
  - Codex session ID remap behavior at the bridge layer
  - Relay transport shutdown / reconnect behavior
- Fix the corresponding implementation defects with minimal surface-area changes.
- Add root-level test entrypoints so the new checks are easy to run again.

## Non-Goals

- Full relay protocol redesign in this pass
- Large architecture refactors across bridge / transport / adapter boundaries
- Full CI pipeline setup while the project is outside a Git worktree

## Recommended Approach

1. Keep the existing `node:test` stack.
2. Add regression tests close to the current `packages/bridge/src/__tests__` suite.
3. Fix only the code needed to make the new tests pass.
4. Expose repeatable root scripts: `test`, `test:unit`, and `check`.

## Design Notes

- `file_req` should validate the real filesystem target, not only the lexical path.
- Once E2E is established, plaintext messages on that socket should be rejected.
- Bridge session lookup should tolerate the Codex temp ID -> real thread ID transition.
- Relay shutdown must suppress reconnect scheduling after an intentional stop.

## Verification

- `pnpm -r build`
- `pnpm test`
- `pnpm run check`
