---
name: ignore-sandbox-folder
description: Ignore the Replicant/sandbox folder in all work on this project
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 7c39548a-6a4e-4a71-a1d0-7267fab2cd59
---

Ignore the `Replicant/sandbox/` folder in all dealings within this project. Do not read, edit, search, or reference its contents (e.g. FirstLaunchView.swift, ReplicantDesignSystem.swift, ReplicantSplitView.swift, Swatches.swift, DESIGN_SPEC.md) unless the user explicitly asks about it.

**Why:** The user designated it as out of scope for ongoing work.

**How to apply:** Exclude `Replicant/sandbox/` from explorations, edits, and suggestions by default. Scope searches and changes to the rest of the project.
