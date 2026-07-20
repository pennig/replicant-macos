---
name: replicants-feature
description: ReplicantsFeature (galaxy directory) + KnownReplicant table + last-known-location via scan hook.
metadata: 
  node_type: memory
  type: project
  originSessionId: 04937c21-7918-469f-be3c-af86906f9dee
---

The Replicants view (sidebar `.replicants`, Catalog group) shows the account's own replicants plus all other players/NPCs known in the galaxy. New module `ReplicantsFeature` (list + detail, `ReplicantsClient` walks paged `GET replicants` directory + `GET replicants/{id}` details).

Key design:
- **`KnownReplicant`** @Table (in GameModels) is the galaxy directory + last-known-location intel — deliberately SEPARATE from the existing **`Replicant`** roster table (which stays the account's own roster from `accounts/me`, feeding the sidebar count). `ReplicantsClient.refresh` seeds `KnownReplicant` from the roster so own replicants always appear.
- **Last-known-location**: directory `last_location` is low-fidelity (mostly NPCs). Precise player positions come from the **`system_scan` response `replicants` block** (`{replicant_code, name, location, last_active}`), hooked in `CommandClient`'s immediate `.scan` path → `KnownReplicant.record(sightings:)`. Merge helpers are fetch-merge-upsert so scan/details intel isn't clobbered by a later directory page (`displayLocation` prefers precise over directory).
- In `MainFeature`, the feature state is named **`replicantDirectory`** (not `replicants`) to avoid colliding with the existing `@FetchAll var replicants` roster array.

See [[feature-module-import-dependencyclients]] (the reducer needed `import GameModels` for `KnownReplicant`) and [[pbxproj-link-is-manual]] (user linked the new module in Xcode).
