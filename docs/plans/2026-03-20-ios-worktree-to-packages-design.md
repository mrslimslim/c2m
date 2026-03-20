# iOS Worktree To Packages Design

**Topic:** Move the iOS app and Swift package out of the dedicated git worktree and into the main monorepo under `packages/`.

**Goal:** Bring the existing SwiftUI iOS client from `.worktrees/ios-client-swiftui/apps/ios/...` into the main repository so it lives under `packages/ios/...`, builds from the main checkout, and no longer depends on the separate worktree path.

## Scope

- Copy the iOS sources from the `ios-client-swiftui` worktree into the main checkout.
- Change the target layout from `apps/ios/...` to `packages/ios/...`.
- Preserve the existing split between:
  - `CodePilotApp`
  - `CodePilotKit`
- Update Xcode local package references and in-app preview fixture paths so they match the new location.
- Update docs and ignore rules that still assume the old `apps/ios/...` layout.

## Non-Goals

- Re-architect the Swift package targets or the SwiftUI app structure.
- Convert the iOS code into a JavaScript workspace package.
- Reconcile or delete the source worktree in the same change.
- Fix unrelated dirty changes already present in the main checkout.

## Recommended Approach

Use `packages/ios/CodePilotApp` and `packages/ios/CodePilotKit` as the new home for the iOS code.

This keeps the current app-to-kit sibling relationship intact, which means the Xcode project can continue to reference the local Swift package via `../CodePilotKit` with no structural redesign. It also keeps the iOS code under the repository's established `packages/` umbrella without pretending the Swift targets are npm packages.

## Target Layout

```text
packages/
  ios/
    CodePilotApp/
      CodePilot.xcodeproj/
      CodePilot/
    CodePilotKit/
      Package.swift
      Sources/
      Tests/
```

## Path And Build Updates

- Replace repository-relative paths in preview fixtures from `apps/ios/...` to `packages/ios/...`.
- Replace preview sample working directories from `.../apps/ios` to `.../packages/ios`.
- Preserve the Xcode local package reference as `../CodePilotKit` after the move.
- Ignore generated Swift and Xcode artifacts in the new tree:
  - `.build`
  - `.swiftpm`
  - `xcuserdata`

## Verification

- `swift test --package-path packages/ios/CodePilotKit`
- `xcodebuild -project packages/ios/CodePilotApp/CodePilot.xcodeproj -scheme CodePilot -destination 'generic/platform=iOS Simulator' build`
- `rg -n "apps/ios" packages/ios docs`

