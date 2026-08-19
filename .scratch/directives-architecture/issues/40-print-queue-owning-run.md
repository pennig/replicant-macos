# 40 — The Print Queue names the run that ordered each bench's print

Type: task
Status: open
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

- [ ] **Step 1:** Write `Tests/PrintQueueOwnersTests.swift` — five cases: one owner; a job with no `directiveID`; an op whose directive has been deleted; two runs on one bench in a stable oldest-first order; a completed print naming nobody.
- [ ] **Step 2:** Confirm it fails to compile.
- [ ] **Step 3:** Write `Sources/PrintQueueOwners.swift` — the `FetchKeyRequest` and its pure `merge(operations:directives:)`. `merge` re-checks status and kind even though `fetch` filtered: `merge` is the tested surface and must be correct on its own inputs.
- [ ] **Step 4:** Wire `@Fetch(PrintQueueOwners())` into `PrintQueueFeature.State` beside the existing `@FetchAll` at `:32-33`.
- [ ] **Step 5:** Render the line in `PrintQueueDetailView`'s `queue(_:)` section and in `PrintQueueListView`'s active-job block.
- [ ] **Step 6:** All six targets green. `PrintQueueFeatureTests` had 6 cases and gains 5.
- [ ] **Step 7:** Build and run; open the Print Queue with a run printing; screenshot into `## Comments`. Do not encode meaning in hue.
- [ ] **Step 8:** `check-comments.sh`; commit.

**Done when:** an op stamped with a deleted directive renders nothing rather than an invented title, with a test.

**Phase A ends here.** Every ticket from 41 changes the substrate.
