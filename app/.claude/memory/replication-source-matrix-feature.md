---
name: replication-source-matrix-feature
description: "Only a matrix carrying the `matrix` feature can be a replication source; an empty matrix loses that feature once replicated into, so offspring replicants can't replicate."
metadata:
  type: reference
---

The backend gates the `replicate` command on the device **`matrix` feature**, not on
device type. Across the whole live fleet the two travel together — every device with
`matrix` in `features` lists `replicate` in `available_commands`, and no device without
it does.

The non-obvious part: **an `empty_replicant_matrix` is printed *with* the `matrix`
feature, but loses it once a replicant is replicated into it.** The device becomes a
`replicant_matrix` with `features: ["stow"]` and no `replicate`. Only a matrix that was
never itself a replication target keeps the feature.

Consequence: **a replicant born from replication can never itself replicate.** Only the
account's original matrix can. That reads like a backend bug for a von Neumann probe
game (it caps you at one replicating lineage), but it is the live behaviour as of
2026-07-31 and the docs (`/docs/cloning/`, `/docs/api/replicants/replicate/`,
`/docs/concepts/replicants/`) document no such rule — they list only the three target-side
preconditions. Worth re-probing before building anything that assumes exponential growth.

Evidence (live `GET devices/{code}`, 2026-07-31):

| device | type | created | features | `replicate`? |
|---|---|---|---|---|
| `1F6A12EB` | `replicant_matrix` | same instant as replicant `99380EDF` (`pennig-1`) — the **original** | `["stow","matrix"]` | yes |
| `60160672` | `replicant_matrix` | printed empty, replicated into → `1E79E724` (`pennig-scan`) | `["stow"]` | **no** |
| `30790F27` | `empty_replicant_matrix` | freshly printed | `["stow","matrix"]` | yes |

The `empty_replicant_matrix` blueprint declares `features: ["stow","matrix"]`; there is
**no `replicant_matrix` blueprint** (it isn't printable — it's what an empty one becomes).

`ReplicationEligibility` surfaces this via `Device.canBeSource` (`features.contains("matrix")`)
and names it in the "Active replicant matrix" hint, rather than the old hard-coded
"bring it into control range or wait for its current task to finish" — which asserted two
causes it never checked and misdirected the one real report of this. See
[[device-tags-and-control-range]] for `in_control_range`, which that hint now actually reads.
