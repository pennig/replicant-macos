# 42 — Relax the index, and stop the supersede eating siblings

Type: task
Status: resolved
Blocked by: 41
Labels: directives-architecture, stage-3

**The one ticket in Stage 3 that changes schema.** The partial unique index narrows from `status IN ('enqueued','active')` to `status = 'active'`, and `CommandClient`'s supersede stops applying to prints — in the same commit, because either alone is worse than neither.

**Plan:** `.scratch/directives-architecture/plan-stage-3.md` — Task 10.

**Relaxing the index alone accomplishes nothing.** `CommandClient.swift:247-262` proactively marks every *other* live op on a device `.superseded` when a command confirms, and its comment at `:248-249` names the index as the reason. With the index relaxed and this untouched, print #2 still kills print #1 and N-deep queues remain impossible. Conversely, scoping the supersede without relaxing the index makes the second insert fail the constraint, which rolls back the whole fleet walk (`Reconciler.swift:66-79`).

**No second partial unique index is needed.** Ticket 18 asked for the audit and the answer is clean: `completion(for:)` (`CommandClient.swift:351-359`) returns `.enqueued` for `.print` and nothing else — `.enqueued` is unreachable through the `default:` arm, which yields only `.deadline` or `.immediate`. `Reconciler` inserts only `.active` rows. `.print` is provably the only kind that produces an enqueued operation.

**A new index NAME, not the old one reused.** `DROP` plus `CREATE` under the same name leaves two databases with the same index name and different predicates depending on migration path, and nothing tells them apart. The new one is `operation_one_active_per_device`.

**Append only.** The old index is migration #20 (`GameDatabase.swift:68`). The manifest was 46 entries when this ticket was written and is **47** as of `97585e1` — the stall triage appended `Directive.addFreighterCodes` — so this one is **#48, after `Directive.addFreighterCodes`**. Count the array before you append rather than trusting either number; more may have landed. Never edit or reorder a shipped entry.

**Leave `CommandClientTests.swift:212-217` alone.** It asserts `openCount == 1` for travel, which does not change. Add beside it, do not edit it.

---

- [x] **Step 1:** Write the failing test: a second print on a bench queues behind the first — two live ops, at most one of them `.active`.
- [x] **Step 2:** Confirm it fails, and **record which failure it is** — a unique-constraint violation at insert, or `live.count == 1` after the supersede. That tells you which of the two mechanisms fires first.
- [x] **Step 3:** Append `Operation.relaxOpenIndex` and register it in the manifest.
- [x] **Step 4:** Scope the supersede so it skips `.print`. Check `kind` is in scope at that point and thread it if not — `openOps` may not contain the op being confirmed. Replace the comment at `:248-249`; its reason no longer holds.
- [x] **Step 5:** Regenerate the golden fixture with `RC_REGENERATE_SCHEMA_FIXTURE=1`, then **read the diff by eye** and confirm the only change is the index at `schema.sql:18-20`. Update `SchemaManifestTests`'s frozen identifier list. Update `DatabaseEraseResetTests.swift:50-51` rather than deleting it.
- [x] **Step 6:** Eight targets green — the usual six plus `GameDatabaseTests` and `DevicesFeatureTests`.
- [x] **Step 7:** Prove the relax is real: two `enqueued` prints on one device both persist; two `active` ops on one device are rejected. The second assertion proves the index still does its remaining job.
- [x] **Step 8:** `check-comments.sh`; commit, naming the regenerated fixture and why in the body.

**Done when:** two enqueued prints coexist on one bench and two active ops on one device still cannot.

## Comments

**Built and reviewed 2026-08-19**, subagent-driven, on branch `worktree-directives-stage-3`,
which was merged with `main` at `8902fc1` before Phase B began. **Phase B is not itself merged** —
that is Matt's call. Every claim below was checked against source or the event stream rather than
taken from a subagent's summary.

| Commit | What |
|---|---|
| `5ab8af6` | `feat(operations): one ACTIVE op per device; prints queue` |
| `1de1b70` | `fix(operations): shrink supersede comment, drop a vacuous assertion` |

**The only schema change in the plan.** Migration `relaxOpenIndex`, appended **last as entry #50**
of 50 — both the plan (#48) and my own first count (#55) were wrong, and the implementer counted
directly and was right. `SchemaManifestTests` freezes the list, so the position is the part that
mattered and it is correct. No shipped migration's SQL, identifier or position was touched.

The index drops and is recreated under a **new name**, `operation_one_active_per_device`, with the
predicate narrowed from `status IN ('enqueued','active')` to `status = 'active'`. The invariant is
now **at most one active op per device, any number of enqueued**. The golden fixture diff shows the
rename and the predicate and nothing else; the commit message states the regeneration and why.

**The migration is safe against live data, established rather than assumed.** I queried a
read-only copy of the 326 MB production database: 13,055 operation rows — 12,217 completed, 443
superseded, 292 unknown, 44 active, 36 rejected, 23 failed. No device holds more than one `active`
op, nor more than one row under the old predicate, so `CREATE UNIQUE INDEX` cannot throw at
bootstrap and no cleanup is required.

**The supersede ships in the same commit by design**, because neither half means anything alone:
relaxing the index without scoping the supersede leaves print #2 killing print #1, and scoping
without relaxing makes the second insert fail the constraint. Prints now supersede nothing;
non-print kinds still supersede every other live op on the device, unchanged.
`secondPrintDoesNotSupersedeTheFirst` puts **two** live prints on one device and drives both
through a real confirm with stubbed HTTP rather than a stubbed DB write — the reviewer went
looking for the version of that test which cannot tell scoped from unscoped, and it is not there.

**A finding this ticket produced that shaped ticket 43.** There are **zero `enqueued` rows** in all
13,055, so the invariant's permissive half applies to a status production has never emitted. Tracing
it: `CommandClient`'s confirm write for a print is deterministically `.enqueued`, kind-based,
ignoring the server response — so a second print does get a queueable status and Phase B's premise
holds. But `Reconciler.apply`'s unordered, kind-only lookup could pick the enqueued sibling of a
two-print bench and promote it to `.active` while the real active job held that status. Before this
migration that was silent; after it, the narrower index turns it into a thrown, rolled-back write.
Ticket 43 closes it.
