# 40 — The Print Queue names the run that ordered each bench's print

Type: task
Status: resolved
Blocked by: 39
Labels: directives-architecture, stage-3

`PrintQueueFeature` learns about directives for the first time. Both surfaces — the list row's active job and the detail pane's Queue section — gain the owning run's title.

**Plan:** `.scratch/directives-architecture/plan-stage-3.md` — Task 8.

**No new package dependency.** `Directive` and `DirectiveKind.title` live in `GameModels` (`Directive.swift:36-49`), already a `PrintQueueFeature` dependency (`Package.swift:637`). `DirectiveOwner`'s "driven by X" phrasing is in `DirectivesFeature` and is **not** reachable — write the string here.

**By bench, not by queue position, and the copy must not imply otherwise.** A `print_queue` entry carries no id (`Printing.swift:147-152`), so a queued job cannot be matched to an operation row. What the ops table can answer is which runs have a print open on this bench. The Queue section gets a line naming the owning run; it does not get a per-row owner. Ticket 46 revisits this once `queuedOperations` exists, and even then the mapping to a queue *position* stays unavailable.

**There are no GRDB associations anywhere in this app.** The template is a `FetchKeyRequest` that reads both tables and merges in a pure static — `BobnetQueries.swift:46-105`. The covering index `operation_by_directive (directiveID, startedAt)` already exists from Stage 0.

**A run title is prose, not a designation.** It does not go in a mono token. `.rcCaption` / `.rcTextTertiary`, in the existing second-line slot at `PrintQueueDetailView.swift:263`. The device code beside it stays `.rcMonoSmall`.

**`PrintQueueDetailView.activeJob` (`:135-178`) is correct and stays.** A bench prints one thing at a time; showing one active job is right. What is missing is the owner, not a second job.

---

- [x] **Step 1:** Write `Tests/PrintQueueOwnersTests.swift` — five cases: one owner; a job with no `directiveID`; an op whose directive has been deleted; two runs on one bench in a stable oldest-first order; a completed print naming nobody.
- [x] **Step 2:** Confirm it fails to compile.
- [x] **Step 3:** Write `Sources/PrintQueueOwners.swift` — the `FetchKeyRequest` and its pure `merge(operations:directives:)`. `merge` re-checks status and kind even though `fetch` filtered: `merge` is the tested surface and must be correct on its own inputs.
- [x] **Step 4:** Wire `@Fetch(PrintQueueOwners())` into `PrintQueueFeature.State` beside the existing `@FetchAll` at `:32-33`.
- [x] **Step 5:** Render the line in `PrintQueueDetailView`'s `queue(_:)` section and in `PrintQueueListView`'s active-job block.
- [x] **Step 6:** All six targets green. `PrintQueueFeatureTests` had 6 cases and gains 5.
- [x] **Step 7:** Build and run; open the Print Queue with a run printing; screenshot into `## Comments`. Do not encode meaning in hue.
- [x] **Step 8:** `check-comments.sh`; commit.

**Done when:** an op stamped with a deleted directive renders nothing rather than an invented title, with a test.

**Phase A ends here.** Every ticket from 41 changes the substrate.

## Comments

**Built and reviewed 2026-08-19**, subagent-driven, on worktree branch
`worktree-directives-stage-3` off local `main` at `b7228f1`. **Not merged** — merging is Matt's
call. Every claim below was checked against the source or the event stream, not taken from a
subagent's summary.

| Commit | What |
|---|---|
| `0639659` | `feat(printqueue): name the run that ordered each bench's print` |
| `2c76264` | `fix(printqueue): move the owner line beside the active job, not the queue` |

`PrintQueueOwners` lands — a `FetchKeyRequest` joining `operations.directiveID` to `directives`,
plus a pure `merge` static — and the owning run is named in both the list and detail views. No
new package dependency.

**The copy was accurate and its placement made it lie.** "Ordered by X" names the run behind the
bench's open operation and claims nothing about queue positions. But the brief put it under the
"Queue" header, directly above the numbered `ForEach` of `print_queue` entries — the rows that
carry no id and cannot be attributed to anyone — while "Active Job", which shows the operation
the line actually describes, had no owner line at all. A reader goes Queue → "Ordered by Mine
Fleet Print" → a numbered list and concludes the queue belongs to that run. Moved in `2c76264`
into `activeJob(_:)`, beside the "Printing" row. The list view had it right from the start.

**Two of the brief's five supplied tests did not isolate the branch they named**, masked by
shared `directives: []` and default-kind fixtures. The implementer found both unprompted and
added `nonPrintOpNamesNobody` and `unownedJobIgnoresEmptyIDDirective` — the latter covering the
coalesce-nil-to-empty-string trap that an empty array cannot reach.

**The sort tie-break is pinned even though it is unreachable today.** `$0.id < $1.id` on equal
`startedAt` could be deleted with the suite green, and the reviewer rated that cosmetic because
Phase A's `operation_one_open_per_device` index makes two open prints on one bench impossible.
That reasoning expires at ticket 42, which removes the index, and ticket 46, which makes `owners`
hold N elements. Pinned now by `sameStartedAtBreaksTieByID`.

**Step 7 is NOT done and needs Matt.** The ticket asks for a live screenshot of the Print Queue
showing the owner line. The app is not running — verified by `pgrep`, which finds only Xcode
macro plugin processes — and a background job cannot pass the Keychain login wall to launch it.
An `xcodebuild` compile-check of the app target was substituted and succeeded, so the views
build; seeing them render is the outstanding item.
