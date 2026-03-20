# iOS Worktree To Packages Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Move the existing iOS SwiftUI app from the `ios-client-swiftui` worktree into the main repository under `packages/ios/...` and fix the repository paths so the app and Swift package build from the main checkout.

**Architecture:** Reuse the current `CodePilotApp` and `CodePilotKit` structure from the worktree, copy it into `packages/ios`, and keep the app/package sibling layout intact so the Xcode package dependency stays relative. Treat the migration as a repository-layout refactor: verify the old paths fail the migration checks first, then copy the code, rewrite path references, update docs and ignore rules, and finally run Swift and Xcode verification from the new location.

**Tech Stack:** Git worktrees, Swift Package Manager, Xcode project files, SwiftUI, ripgrep, apply_patch

---

### Task 1: Establish migration checks and ignore rules

**Files:**
- Modify: `.gitignore`

**Step 1: Write the failing checks**

- Confirm `packages/ios/CodePilotKit/Package.swift` does not exist yet.
- Confirm `packages/ios/CodePilotApp/CodePilot.xcodeproj/project.pbxproj` does not exist yet.
- Confirm the root ignore file does not yet ignore `packages/ios/**/.swiftpm`, `packages/ios/**/.build`, and `packages/ios/**/xcuserdata`.

**Step 2: Run the checks to verify they fail for the target state**

Run: `test -f packages/ios/CodePilotKit/Package.swift && test -f packages/ios/CodePilotApp/CodePilot.xcodeproj/project.pbxproj`
Expected: FAIL because the migrated iOS tree is not present yet.

Run: `rg -n "packages/ios/.+(\\.swiftpm|\\.build|xcuserdata)" .gitignore`
Expected: FAIL because the new ignore rules do not exist yet.

**Step 3: Write minimal implementation**

- Add ignore rules for generated SwiftPM and Xcode user data under `packages/ios`.

**Step 4: Run the check to verify it passes**

Run: `rg -n "packages/ios/.+(\\.swiftpm|\\.build|xcuserdata)" .gitignore`
Expected: PASS and show the new ignore rules.

**Step 5: Commit**

```bash
git add .gitignore
git commit -m "chore: ignore iOS build artifacts under packages"
```

### Task 2: Copy the iOS app and Swift package into `packages/ios`

**Files:**
- Create: `packages/ios/CodePilotApp/**`
- Create: `packages/ios/CodePilotKit/**`

**Step 1: Write the failing checks**

- Confirm the target app and Swift package trees are absent in the main checkout.

**Step 2: Run the checks to verify they fail for the target state**

Run: `find packages/ios -maxdepth 3 -type f`
Expected: FAIL or no results because the target tree does not exist yet.

**Step 3: Write minimal implementation**

- Copy `CodePilotApp` and `CodePilotKit` from `.worktrees/ios-client-swiftui/apps/ios`.
- Exclude generated directories and user-specific artifacts:
  - `.build`
  - `.swiftpm`
  - `xcuserdata`

**Step 4: Run the checks to verify they pass**

Run: `test -f packages/ios/CodePilotKit/Package.swift && test -f packages/ios/CodePilotApp/CodePilot.xcodeproj/project.pbxproj`
Expected: PASS.

Run: `find packages/ios -type d \\( -name .build -o -name .swiftpm -o -name xcuserdata \\)`
Expected: no output from copied generated directories.

**Step 5: Commit**

```bash
git add packages/ios
git commit -m "feat: move iOS app into packages"
```

### Task 3: Rewrite hard-coded repository paths to the new location

**Files:**
- Modify: `packages/ios/CodePilotApp/CodePilot/App/RootView.swift`

**Step 1: Write the failing check**

- Confirm the copied app still contains `apps/ios/...` fixture paths and preview working-directory values.

**Step 2: Run the check to verify it fails for the target state**

Run: `rg -n "apps/ios" packages/ios/CodePilotApp/CodePilot/App/RootView.swift`
Expected: PASS with matches, proving the stale paths are still present.

**Step 3: Write minimal implementation**

- Change preview file paths from `apps/ios/...` to `packages/ios/...`.
- Change the preview working directory example from `.../apps/ios` to `.../packages/ios`.

**Step 4: Run the check to verify it passes**

Run: `rg -n "apps/ios" packages/ios/CodePilotApp/CodePilot/App/RootView.swift`
Expected: no matches.

Run: `rg -n "packages/ios" packages/ios/CodePilotApp/CodePilot/App/RootView.swift`
Expected: PASS with the updated paths.

**Step 5: Commit**

```bash
git add packages/ios/CodePilotApp/CodePilot/App/RootView.swift
git commit -m "refactor: update iOS preview paths for packages layout"
```

### Task 4: Update repo documentation to the new iOS layout

**Files:**
- Modify: `docs/plans/2026-03-17-ios-client-swiftui-design.md`
- Modify: `docs/plans/2026-03-17-ios-client-swiftui-implementation.md`
- Modify: `docs/plans/2026-03-18-ios-swiftui-previews-implementation.md`
- Optionally modify: `docs/ios-testing.md`

**Step 1: Write the failing check**

- Confirm repository docs still refer to `apps/ios/...` for the iOS client.

**Step 2: Run the check to verify it fails for the target state**

Run: `rg -n "apps/ios/(CodePilotApp|CodePilotKit)" docs`
Expected: PASS with matches in the existing docs.

**Step 3: Write minimal implementation**

- Rewrite iOS-specific doc paths and commands to `packages/ios/...`.
- Keep historical document names unchanged; only update their referenced repository paths.

**Step 4: Run the check to verify it passes**

Run: `rg -n "apps/ios/(CodePilotApp|CodePilotKit)" docs`
Expected: no matches for active repository paths.

**Step 5: Commit**

```bash
git add docs
git commit -m "docs: update iOS paths for packages layout"
```

### Task 5: Verify the migrated iOS code builds from the main checkout

**Files:**
- Verify only

**Step 1: Run the Swift package tests**

Run: `swift test --package-path packages/ios/CodePilotKit`
Expected: PASS.

**Step 2: Run the Xcode build**

Run: `xcodebuild -project packages/ios/CodePilotApp/CodePilot.xcodeproj -scheme CodePilot -destination 'generic/platform=iOS Simulator' build`
Expected: BUILD SUCCEEDED.

**Step 3: Run the final path audit**

Run: `rg -n "apps/ios" packages/ios docs`
Expected: no remaining active-path references in the migrated tree or updated docs.

**Step 4: Commit**

```bash
git add packages/ios docs .gitignore
git commit -m "feat: migrate iOS app from worktree into packages"
```
