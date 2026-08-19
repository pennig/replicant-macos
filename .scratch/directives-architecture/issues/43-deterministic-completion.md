# 43 — A completion closes the op it names, or the oldest

Type: task
Status: open
Blocked by: 42
Labels: directives-architecture, stage-3

Three unordered `fetchOne`s over `liveCases` become deterministic picks. They share one failure mode: an arbitrary row once N can exist.

**Plan:** `.scratch/directives-architecture/plan-stage-3.md` — Task 11.

**The three sites, and why each is dangerous now:**

- `Reconciler.swift:451-455` (`completeOpenOperation`) — a `print.completed` on a bench with one active and two enqueued prints can close enqueued job #3 and leave the running job open forever. Its two existing guards do not help: `allowedKinds` passes for any print op, and the skew tolerance passes for any op started before the event.
- `Reconciler.swift:284-286` — the same `fetchOne`, on the SSE path (`GameSync.swift:305-310`). A second copy of the same bug. Extract one private helper and have both call it, or the next fix will land on one and not the other.
- `Reconciler.swift:121-126` — feeds a four-arm switch. The adopt arm can insert a duplicate `.active` row and be rejected by the new index, rolling back the whole fleet walk. The complete-as-stale arm (`:182-195`) can complete a random enqueued sibling — and an enqueued print is not stale merely because the device is printing something else. That is precisely a queue. Scope that arm to `.active`.
- `DeadlineScheduler.swift:200,255` — holds `op.id`, asserts `op.status == .active` two lines earlier (`:188-192`), then throws the id away. The cheapest of the four fixes and the one with the least room for doubt.

**Ticket 18's device-type disambiguator is not implementable as specified, and this ticket does not pretend otherwise.** It asks to select by matching `detail.params.device_type` to the event's device type. That field is absent on ops adopted from a device snapshot (`Reconciler.swift:135,190`), and the event's device type is discarded before `completeOpenOperation` is reached (`:439-445`). **Nothing in this repository evidences whether the server's `device_type` on `print.completed` names the printer or the thing printed** — the only documented payload key for that event is `new_device_code` (`GameSync.swift:320`).

So the rule here is **oldest live print first**, which needs no field that may be absent and matches what a print queue is. Open Question 3 asks the operator for one live probe. If it says the event carries the printed device's type, add the type match as an additional predicate **above** the oldest rule; if it says the printer's type, the refinement is worthless and the question closes.

---

- [ ] **Step 1:** Write the three failing tests against the harnesses those two test files already use — a completion closes the oldest; a poll does not adopt twice; an expired deadline closes its own operation.
- [ ] **Step 2:** Confirm all three fail.
- [ ] **Step 3:** Give `completeOpenOperation` an optional `operationID:` and an ordered fetch. Break the `startedAt` tie by `id` — two ops in one transaction share the timestamp.
- [ ] **Step 4:** `DeadlineScheduler` passes `operationID: op.id` at both `:200` and `:255`.
- [ ] **Step 5:** Fix the four-arm switch at `:121-126`; scope the complete-as-stale arm to `.active`.
- [ ] **Step 6:** Extract the ordered fetch and repoint `:284-286` at it.
- [ ] **Step 7:** Eight targets green; `check-comments.sh`; commit.

**Done when:** a bench with one active and two enqueued prints closes the active one on a `print.completed`, with a test.

## Landed ahead of this ticket (merge 34e6a61)

`completeOpenOperation` grew a THIRD guard: a completion whose
`result.device_type` contradicts the open op's `params.device_type` is refused
and logged. It was the fix for a live Relay Run stall — a `defence_grid`
completion closed a relay run's `ftl_relay` print op and stamped the wrong
`new_device_code` in, so `printInFlight` went false and the run waited out
`PrintJob.deadline` for a relay that arrived 1h49m later. 23 of the ledger's
235 resolved print ops carry a contradicting result.

**Refusal is only correct while the index allows one open op per device.** Once
ticket 42 relaxes it, this guard must become a SELECTION rather than a refusal:
pick the op whose `params.device_type` matches the completion, falling back to
the oldest by `startedAt` then `id`. Fold it into Step 3's ordered fetch rather
than leaving both — a refusal against N open ops drops completions on the floor
and leans on the poll path to clear them.

Tests: `GameServices/Tests/ReconcilerSharedBenchTests.swift`. The poll path
(`result: nil`) is deliberately unguarded and is what currently clears a job
whose event this refused.
