# 42 — Relax the index, and stop the supersede eating siblings

Type: task
Status: open
Blocked by: 41
Labels: directives-architecture, stage-3

**The one ticket in Stage 3 that changes schema.** The partial unique index narrows from `status IN ('enqueued','active')` to `status = 'active'`, and `CommandClient`'s supersede stops applying to prints — in the same commit, because either alone is worse than neither.

**Plan:** `.scratch/directives-architecture/plan-stage-3.md` — Task 10.

**Relaxing the index alone accomplishes nothing.** `CommandClient.swift:247-262` proactively marks every *other* live op on a device `.superseded` when a command confirms, and its comment at `:248-249` names the index as the reason. With the index relaxed and this untouched, print #2 still kills print #1 and N-deep queues remain impossible. Conversely, scoping the supersede without relaxing the index makes the second insert fail the constraint, which rolls back the whole fleet walk (`Reconciler.swift:66-79`).

**No second partial unique index is needed.** Ticket 18 asked for the audit and the answer is clean: `completion(for:)` (`CommandClient.swift:351-359`) returns `.enqueued` for `.print` and nothing else — `.enqueued` is unreachable through the `default:` arm, which yields only `.deadline` or `.immediate`. `Reconciler` inserts only `.active` rows. `.print` is provably the only kind that produces an enqueued operation.

**A new index NAME, not the old one reused.** `DROP` plus `CREATE` under the same name leaves two databases with the same index name and different predicates depending on migration path, and nothing tells them apart. The new one is `operation_one_active_per_device`.

**Append only.** The old index is migration #20 of 46 (`GameDatabase.swift:68`); this one is #47, after `TheatreRecord.createTheatres`. Never edit or reorder a shipped entry.

**Leave `CommandClientTests.swift:212-217` alone.** It asserts `openCount == 1` for travel, which does not change. Add beside it, do not edit it.

---

- [ ] **Step 1:** Write the failing test: a second print on a bench queues behind the first — two live ops, at most one of them `.active`.
- [ ] **Step 2:** Confirm it fails, and **record which failure it is** — a unique-constraint violation at insert, or `live.count == 1` after the supersede. That tells you which of the two mechanisms fires first.
- [ ] **Step 3:** Append `Operation.relaxOpenIndex` and register it in the manifest.
- [ ] **Step 4:** Scope the supersede so it skips `.print`. Check `kind` is in scope at that point and thread it if not — `openOps` may not contain the op being confirmed. Replace the comment at `:248-249`; its reason no longer holds.
- [ ] **Step 5:** Regenerate the golden fixture with `RC_REGENERATE_SCHEMA_FIXTURE=1`, then **read the diff by eye** and confirm the only change is the index at `schema.sql:18-20`. Update `SchemaManifestTests`'s frozen identifier list. Update `DatabaseEraseResetTests.swift:50-51` rather than deleting it.
- [ ] **Step 6:** Eight targets green — the usual six plus `GameDatabaseTests` and `DevicesFeatureTests`.
- [ ] **Step 7:** Prove the relax is real: two `enqueued` prints on one device both persist; two `active` ops on one device are rejected. The second assertion proves the index still does its remaining job.
- [ ] **Step 8:** `check-comments.sh`; commit, naming the regenerated fixture and why in the body.

**Done when:** two enqueued prints coexist on one bench and two active ops on one device still cannot.
