---
name: pbxproj-link-is-manual
description: Linking a new SPM module product to the app target must be done manually in Xcode; direct pbxproj edits are blocked.
metadata: 
  node_type: memory
  type: project
  originSessionId: fd8980c1-8074-49b1-99a8-64247ff6fbdf
---

When adding a new SPM module under `Modules/` and wiring it into the app, the final step — linking the library product to the `Replicould` app target in `Replicould.xcodeproj/project.pbxproj` — cannot be done by editing the file. A steering guard denies direct edits to `project.pbxproj` while Xcode has the project open, and the xcode-tools MCP exposes no tool to add a package-product dependency.

**Why:** Editing the pbxproj out from under an open Xcode would clobber its in-memory state.

**How to apply:** Do the Package.swift edits + source files yourself, then ask the user to link the product via Xcode: app target → General → Frameworks, Libraries, and Embedded Content → + → select the module. Validate module code with `swift build --target <Name>` from `Modules/` before the link exists; validate full-app wiring with BuildProject after. See [[api-module-name]].

**Same constraint applies to NEW source files in the app target** (`macOS/*.swift`): a file you create there isn't a member of the app target's Compile Sources (pbxproj membership is blocked too), so it builds as "Cannot find 'X' in scope". Workaround that avoids any manual file-add: put new views/types in an **already-linked SPM module** (e.g. `DevicesFeature`) and make them `public`, rather than in `macOS/`. Editing existing app-target files (ReplicantApp.swift, MainFeature.swift) is fine — they're already members.

**Re-confirmed 2026-07-15:** ran the full experiment — scaffolded a disposable `LinkProof` module, edited Package.swift, `swift package resolve` OK, then attempted all four pbxproj link stanzas (PBXBuildFile, PBXFrameworksBuildPhase files, target packageProductDependencies, XCSwiftPackageProductDependency) via the Edit tool. All four were "Denied by steering extension"; the hook message explicitly states editing pbxproj while Xcode is open risks crashing Xcode and to ask the user instead. So the block is unconditional for any edit method (editor or shell). Reverted cleanly.

**Confirmed 2026-06-26:** the whole Real-Time State plan (`IMPLEMENTATION_PLAN.md`, Phases 0–5) shipped this way. New modules `GameSync` and `DevicesFeature` each needed one manual link; `ActivityView`/`BobnetView` were moved out of `macOS/` into `DevicesFeature` to dodge the source-membership block.
