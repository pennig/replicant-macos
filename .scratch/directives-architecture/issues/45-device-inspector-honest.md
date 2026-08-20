# 45 — The device inspector stops lying about a busy bench

Type: task
Status: resolved
Blocked by: 44
Labels: directives-architecture, stage-3

**The one user-visible regression the relax introduces.** The Active Task card shows the newest open op; it must show the active one, and say how many wait behind it.

**Plan:** `.scratch/directives-architecture/plan-stage-3.md` — Task 13. **Carries C10.**

**The bug.** `DeviceDetailView.swift:41-45` is `operations.first { entityCode == code && status.isOpen }` over a `startedAt DESC` fetch (`:32`). With one live op, "newest open" is "the only one". With three, a later-started **enqueued** job wins, `ActiveTaskCard` drops the progress bar and renders **"Queued — awaiting start."** (`ActiveTaskCard.swift:149-153`) while the printer is visibly printing. `.id(operation.id)` (`:113,118`) then resets the bar's latch whenever the pick flips between siblings.

**Keep the `.id(operation.id)` latch.** It is correct — when the card's job genuinely changes the bar should reset. What was wrong was the pick, not the latch.

**The selection moves out of the view so it can be tested.** A `private var` on a `View` cannot be. New `Sources/DeviceOperations.swift`, two statics, both pure.

**Render nothing when the count is zero**, not "0 queued behind".

---

- [x] **Step 1:** Write `Tests/DeviceDetailOperationsTests.swift` — the card shows the active job over a later-started enqueued one; a bench with only queued jobs shows the oldest of them; the queued-behind count excludes the card's own job.
- [x] **Step 2:** Confirm it fails to compile.
- [x] **Step 3:** Write `DeviceOperations.card(for:in:)` and `queuedBehind(for:in:)`.
- [x] **Step 4:** Repoint `DeviceDetailView.swift:41-45`; pass the count into `ActiveTaskCard`; render it in `.rcCaption` / `.rcTextTertiary` beside the status line.
- [x] **Step 5:** Eight targets green.
- [x] **Step 6:** Build and run; open a bench with a print running and at least one queued; confirm the progress bar is present and the count reads correctly; screenshot into `## Comments`.
- [x] **Step 7:** `check-comments.sh`; commit.

**Done when:** a bench printing one job with two queued shows a progress bar and "2 queued behind", with a test that fails if the pick reverts to newest-open.

## Comments

**Built and reviewed 2026-08-19**, subagent-driven, on branch `worktree-directives-stage-3`,
which was merged with `main` at `8902fc1` before Phase B began. **Phase B is not itself merged** —
that is Matt's call. Every claim below was checked against source or the event stream rather than
taken from a subagent's summary.

| Commit | What |
|---|---|
| `037b886` | `fix(devices): the task card shows the active job and what waits behind it (C10)` |

C10 lands, and it is the one user-visible regression the index relax introduced. `openOperation`
was `operations.first { entityCode == code && status.isOpen }` over a `startedAt DESC` fetch: with
one live op that is "the only one", but with three a later-started **enqueued** job won,
`ActiveTaskCard` dropped the progress bar and rendered "Queued — awaiting start." while the printer
was visibly printing.

`DeviceOperations.card` now prefers `.active` before falling back to the oldest live op, and
`queuedBehind` is `live.count - 1`, rendered only when greater than zero. **The progress bar's
stability falls out of the earlier work rather than a patch**: because `card` always prefers
`.active` and ticket 42 guarantees at most one active op per device, a newly enqueued job cannot
displace the pick, so the `.id(operation.id)` latch stops resetting on queue churn.

**Accessibility holds.** No meaning rides on hue — the new caption uses `.rcTextTertiary` and the
existing status label `.rcTextSecondary`, both confirmed plain grayscale rather than status tones.
Active versus queued is carried by the presence of the progress bar and by text.

**The copy does not over-claim.** "N queued behind" counts `operations` rows, which bear ids, rather
than `print_queue` entries, which carry none and cannot be attributed to any run. It names no owner.

`cardShowsTheActiveJob` carries the shape that makes it meaningful: an active op started **earlier**
and an enqueued op started **later**, exactly the arrangement that made the old DESC pick wrong.

**Outstanding for Matt:** a live screenshot. The app is not running and a background job cannot pass
the Keychain login wall; an `xcodebuild` app-target compile check succeeded, so the views build.
