# 45 — The device inspector stops lying about a busy bench

Type: task
Status: open
Blocked by: 44
Labels: directives-architecture, stage-3

**The one user-visible regression the relax introduces.** The Active Task card shows the newest open op; it must show the active one, and say how many wait behind it.

**Plan:** `.scratch/directives-architecture/plan-stage-3.md` — Task 13. **Carries C10.**

**The bug.** `DeviceDetailView.swift:41-45` is `operations.first { entityCode == code && status.isOpen }` over a `startedAt DESC` fetch (`:32`). With one live op, "newest open" is "the only one". With three, a later-started **enqueued** job wins, `ActiveTaskCard` drops the progress bar and renders **"Queued — awaiting start."** (`ActiveTaskCard.swift:149-153`) while the printer is visibly printing. `.id(operation.id)` (`:113,118`) then resets the bar's latch whenever the pick flips between siblings.

**Keep the `.id(operation.id)` latch.** It is correct — when the card's job genuinely changes the bar should reset. What was wrong was the pick, not the latch.

**The selection moves out of the view so it can be tested.** A `private var` on a `View` cannot be. New `Sources/DeviceOperations.swift`, two statics, both pure.

**Render nothing when the count is zero**, not "0 queued behind".

---

- [ ] **Step 1:** Write `Tests/DeviceDetailOperationsTests.swift` — the card shows the active job over a later-started enqueued one; a bench with only queued jobs shows the oldest of them; the queued-behind count excludes the card's own job.
- [ ] **Step 2:** Confirm it fails to compile.
- [ ] **Step 3:** Write `DeviceOperations.card(for:in:)` and `queuedBehind(for:in:)`.
- [ ] **Step 4:** Repoint `DeviceDetailView.swift:41-45`; pass the count into `ActiveTaskCard`; render it in `.rcCaption` / `.rcTextTertiary` beside the status line.
- [ ] **Step 5:** Eight targets green.
- [ ] **Step 6:** Build and run; open a bench with a print running and at least one queued; confirm the progress bar is present and the count reads correctly; screenshot into `## Comments`.
- [ ] **Step 7:** `check-comments.sh`; commit.

**Done when:** a bench printing one job with two queued shows a progress bar and "2 queued behind", with a test that fails if the pick reverts to newest-open.
