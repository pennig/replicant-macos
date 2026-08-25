---
name: swift-test-event-stream
description: Query the results of `swift test` programmatically using Swift Testing's JSON event stream (`--event-stream-output-path`) combined with `--filter` and `jq`. Use this skill whenever the task involves extracting, counting, summarizing, or gating on Swift test results — parsing failures out of a test run, building a CI check, finding slow tests, detecting crashed tests, producing a report from a Swift package's test suite, or comparing runs. Reach for it especially if you are about to scrape or regex `swift test` console output, since that output is not a stable interface and the event stream is. Also applies when the user mentions swift-testing's JSON ABI, event stream, `--event-stream-version`, `--experimental-event-stream-output`, or asks why `swift test` results are hard to parse — and when a multi-target package's stream appears truncated, to be missing test targets, or to contain many `runStarted`/`runEnded` pairs, which are the traps this skill explains.
---

# Querying `swift test` results via the Swift Testing event stream

`swift test` console output is human-readable text with no stability guarantees. Swift Testing also emits a machine-readable JSON Lines stream covering the same run. Parse that instead — it is a documented, versioned ABI, and it carries structured source locations, issue severities, tags, and timing that the console text either omits or buries in prose.

This skill covers only Swift Testing. XCTest emits nothing into this stream.

## Core invocation

```bash
swift test \
  --disable-xctest \
  --filter 'CartTests' \
  --event-stream-version 6.4 \
  --event-stream-output-path .build/events.jsonl
```

Both event-stream options are declared on `swift test` but marked `help: .hidden`, so they do not appear in `swift test --help`. They are real and supported — do not conclude they are unavailable because help does not list them.

Mechanically, SwiftPM declares these options so ArgumentParser will not reject them, then forwards the entire command line through to swift-testing's entry point. That pass-through is also why `--filter` reaches both testing libraries: SwiftPM consumes it for XCTest, and swift-testing re-parses it independently.

Legacy aliases `--experimental-event-stream-output` and `--experimental-event-stream-version` still work but are marked private. Prefer the non-experimental names; recognize the old ones in existing scripts and CI configs.

**Always pass `--disable-xctest`** unless the package genuinely has XCTest targets that need to run. Otherwise SwiftPM emits "no matching tests" noise that has nothing to do with the stream.

**Always pin `--event-stream-version`.** Omitting it selects "the current supported non-experimental version," which floats across toolchains and will silently change field availability under a script. Pick a version deliberately using the table below. The pin is validated — an unrecognized value fails the run with exit 1 and `Event stream version <v> is experimental. Use --experimental-event-stream-version to enable it.` — so a typo cannot silently fall back to a different schema.

## Filtering

`--filter` takes a regular expression matched against test IDs. A test ID has the form:

```
Module.SuiteName/functionName()/File.swift:line:column
```

For example: `AppTests.CartTests/addsItem()/CartTests.swift:11:3`

**`SuiteName` is the suite's Swift TYPE name, never its `@Suite("display name")`.** A suite declared `@Suite("System scan state") struct SystemScanStateTests` is filtered as `SystemScanStateTests`; passing `'System scan state'` matches nothing, exits 0, and prints only `warning: No matching test cases were run` — which is easy to read as "ran and passed" in a script that greps for failures. Gate on the `testEnded` count, not on the absence of failures.

This is the same string that appears as `payload.id` on test records and `payload.testID` on events, so a filter expression and the JSON you get back share one namespace. That makes it practical to filter a run down, then key jq queries off the same identifiers.

`--skip` is the inverse and composes with `--filter`. Both accept multiple occurrences.

Filtering a parameterized test selects the whole function, not individual cases. There is no supported way to filter to a single argument set.

## One output path, many test processes

Under the `swiftbuild` backend each test target becomes its own test product and its own binary, and SwiftPM forwards the entire command line — `--event-stream-output-path` included — to every one of those processes. So a package with N test targets has N processes writing to one file. That single fact produced one historical trap and produces one live one.

### Historical: the file was truncated (fixed in Swift 6.4)

Swift Testing used to open the output path in truncating mode (`"wb"`), so the last process to run destroyed everything written before it. The stream held only one target's events, nothing warned you, and the exit code was 0.

**This is fixed as of Swift 6.4 — verified on Xcode 27.0 beta 6 (`27A5252f`): the writes accumulate, and one invocation produces one complete stream.** Measured on this repo's 28-test-target package: a whole-package run yielded all 28 modules with `testStarted` == `testEnded` == 4057, where the old behavior left a single module.

On an older toolchain the truncation is still real. Detect it by counting distinct modules against the package's test targets:

```bash
jq -r 'select(.kind=="test").payload.id | split(".")[0]' .build/events.jsonl | sort -u
```

One module where several were expected confirms it. The workarounds, in descending preference: `--test-product <ProductName>` collapses a filtered run to a single process (a hidden option taking a *product* name, not a target name — an umbrella product reintroduces the problem); or run each product into its own file and `cat` them, since JSON Lines concatenates cleanly. `--build-system native` also sidesteps it by producing a single umbrella bundle, but it is deprecated and on Swift 6.4 it aborts with a bare `error: fatalError`, so do not reach for it.

**None of that is needed on Swift 6.4.** Use plain `--filter` and let SwiftPM run every product.

### Live: one `runStarted`/`runEnded` pair per test product

The consequence of the fix is that a single ordinary invocation now contains N run-lifecycle pairs, not one. A 28-target package emits 28 `runStarted` and 28 `runEnded` records into one file **even when `--filter` selects tests from a single target** — the other 27 products each run zero tests and still open and close a run.

That breaks any gate written as "is there a `runEnded`?", because one surviving product satisfies it while the process that mattered died mid-suite. Assert the count instead — see "Run-completed gate" below.

It also means `--filter` is broadcast to every product, so a typo'd or renamed suite produces N runs of zero tests, zero test records, **exit code 0**, and only a console `warning: No matching test cases were run`. Gate on a non-zero test-record count.

## Stream anatomy

The output file is JSON Lines: one complete JSON object per line, no enclosing array. Every line has the same envelope:

```json
{"version": "6.4.0", "kind": "test" | "event", "payload": { ... }}
```

`.version` reports the resolved patch version (`"6.4.0"`), not the string passed on the command line (`6.4`). Match on a prefix, not on equality.

There are exactly two record kinds. Ignore any line whose `kind` you do not recognize — the format reserves the right to add more.

**`test` records** describe the static test plan: suites and functions, their names, display names, source locations, and (on newer schema versions) tags, bugs, and time limits. They are all emitted *before* most events.

**`event` records** describe what happened: `runStarted`, `testStarted`, `testCaseStarted`, `issueRecorded`, `testCaseEnded`, `testEnded`, `testSkipped`, `runEnded`, `valueAttached`, `testCancelled`, `testCaseCancelled`.

The critical structural fact: **events carry only a `testID`, never a name.** Display names, tags, and bug references live on the `test` records. Any human-readable output requires joining the two.

**The lifecycle name lives at `.payload.kind`, not at the top level.** The top-level `.kind` is only ever `"test"` or `"event"`, so `select(.kind=="runEnded")` matches nothing — and an empty result reads as a clean run. Every recipe below keys off `.payload.kind` for this reason.

Fields prefixed with an underscore (`_testCase`, `_comments`, `_backtrace`, `_error`, `_knownIssueComment`) appear in the JSON but are explicitly outside the schema. Read them opportunistically for diagnostics; never build a CI gate on them.

## Recipes

All of these are verified working. Use `jq -s` (slurp) where a query needs the whole stream at once — joins and aggregations do; line-at-a-time filters do not.

**Counting pitfall:** `jq 'select(...)' file | wc -l` counts pretty-printed *output lines*, not records, and inflates every count several-fold. Project to a scalar (`jq -r 'select(...).payload.kind'`) or pass `-c` before piping to `wc -l`.

### Failures only

On schema `"6.3"` and later, warnings are also `issueRecorded` events. Filtering on `kind == "issueRecorded"` alone counts warnings as failures. Discriminate on `issue.isFailure`:

```bash
jq -r 'select(.kind=="event").payload
       | select(.kind=="issueRecorded" and .issue.isFailure != false)
       | "\(.issue.sourceLocation.filePath):\(.issue.sourceLocation.line): \(.testID)\n    \(.messages[0].text)"' \
  .build/events.jsonl
```

Use `!= false` rather than `== true`. On version `0` streams the field is absent, and `!= false` degrades correctly to "treat every issue as a failure," which is the right behavior for a schema that had no warning concept.

### Join test records onto events

This is the recipe that makes output readable. Build an index from the test records, then look up each event's `testID`:

```bash
jq -s -r '
  (map(select(.kind=="test").payload) | INDEX(.id)) as $tests
  | map(select(.kind=="event").payload)
  | map(select(.kind=="issueRecorded" and .issue.isFailure != false))[]
  | $tests[.testID] as $t
  | "\($t.displayName // $t.name)  [\($t.tags // [] | join(","))]\n  \(.issue.sourceLocation.fileID):\(.issue.sourceLocation.line)  \(.messages[0].text)"
' .build/events.jsonl
```

`displayName // $t.name` falls back correctly when no custom display name was supplied. `.tags // []` does the same for schema versions that predate tags.

### Summary counts

```bash
jq -s '
  map(select(.kind=="event").payload) as $e
  | ($e | map(select(.kind=="issueRecorded" and .issue.isFailure != false).testID) | unique) as $failed
  | { total:    ($e | map(select(.kind=="testStarted")) | length),
      failed:   ($failed | length),
      passed:   (($e | map(select(.kind=="testEnded")) | length) - ($failed | length)),
      warnings: ($e | map(select(.kind=="issueRecorded" and .issue.isFailure == false)) | length),
      skipped:  ($e | map(select(.kind=="testSkipped")) | length) }
' .build/events.jsonl
```

`unique` on the failing test IDs matters: one test can record several failing issues, and counting raw issue events inflates the failure count.

`total` counts `testStarted`, which fires for `@Suite` records as well as `@Test` functions, so it runs above the console's tail line — on this repo, 4057 `testStarted` = 3557 functions + 500 suites. Both numbers are right; compare like with like, and split them on `select(.kind=="test").payload.kind` when the distinction matters.

### Slowest tests

There is no duration field. Pair `testStarted` with `testEnded` on `instant.absolute`:

```bash
jq -s -r '
  map(select(.kind=="event").payload)
  | map(select(.kind=="testStarted" or .kind=="testEnded"))
  | group_by(.testID)
  | map({ id: .[0].testID,
          seconds: ((map(select(.kind=="testEnded"))   | first | .instant.absolute)
                  - (map(select(.kind=="testStarted")) | first | .instant.absolute)) })
  | sort_by(-.seconds)[]
  | "\(.seconds * 1000 | round)ms  \(.id)"
' .build/events.jsonl
```

Use `instant.absolute` (monotonic seconds from a system epoch) for durations, not `instant.since1970` (wall clock, subject to adjustment mid-run).

### Crashed tests

A test that traps produces `testStarted` with no terminal event, and that product's stream simply stops — no `testEnded`, no `issueRecorded`, no `runEnded`. This is the failure mode most likely to be missed, because a naive "any failing issues?" query reports a clean run on a process that died. With every product sharing one file, the surviving siblings' records now surround the gap, which makes it easier to overlook rather than harder.

Diff the started set against the terminated set:

```bash
jq -s -r '
  map(select(.kind=="event").payload) as $e
  | (($e | map(select(.kind=="testStarted").testID))
   - ($e | map(select(.kind=="testEnded" or .kind=="testSkipped").testID)))[]
' .build/events.jsonl
```

### Run-completed gate

Pair the crash check with an explicit completion check. These are different conditions and deserve different exit codes.

**Count the `runEnded` records and compare against the number of test products.** One product dying still leaves its 27 siblings' `runEnded` records in the file, so an `any(...)` check passes on a broken run:

```bash
expected=$(grep -cE '^\s+\.testTarget' Package.swift)
actual=$(jq -r 'select(.kind=="event" and .payload.kind=="runEnded").payload.kind' \
         .build/events.jsonl | wc -l)
[ "$actual" -eq "$expected" ] \
  || echo "run incomplete: $actual/$expected products finished"
```

If the run was narrowed with `--test-product`, compare against the number of products named instead. The same count is the right gate for a concatenated multi-file stream from an older toolchain, so the check is portable across both layouts.

### Live consumption

The stream is written incrementally, and SwiftPM's own tooling passes a FIFO as the output path. For progress reporting rather than post-hoc analysis:

```bash
tail -f .build/events.jsonl | jq --unbuffered -r 'select(.kind=="event").payload | select(.kind=="testEnded") | .testID'
```

A FIFO also works as the output path — opening one in truncating mode destroys nothing — but the reader must know how many writers to expect, since each process closing sends EOF. Reach for it only when live streaming is the actual goal.

## Schema versions

Pin deliberately. The schema itself only adds fields, but **non-schema underscore fields can and do disappear**: `_filePath` is present on `0` and `"6.3"` and gone on `"6.4"`. That is exactly why nothing should gate on an underscore-prefixed field.

| Version | `.version` reports | Adds | Swift |
|---|---|---|---|
| `0` | `0` (number) | Baseline: test records, events, issues, messages; `_filePath` only | 6.0 |
| `0` | `0` (number) | Attachments (`valueAttached`) | 6.2 |
| `"6.3"` | `"6.3.0"` | Issue `severity` and `isFailure`; public `filePath` on source locations; test cancellation events | 6.3 |
| `"6.4"` | `"6.4.0"` | `tags`, `bugs`, `timeLimit` on test records; `iteration` on `testStarted`/`testEnded`; drops `_filePath` | 6.4 |

Note the type change: version `0` is a JSON number, later versions are semver strings. Compare with care.

**Default to `6.4` on this repo's toolchain.** It is the only version carrying `tags` — which the join recipe above prints — and the only one where `filePath` has no unstable underscore twin. Drop to `"6.3"` only to support a Swift 6.3 toolchain, and to `0` only for maximum portability, accepting that warnings become indistinguishable from failures and absolute paths are unavailable outside the out-of-schema `_filePath`.

## Attachments

`valueAttached` events carry only `{"path": ...}`. Attachments are written to disk only if `--attachments-path` points at an existing, writable directory; otherwise they are created and discarded. If a task involves reading attached values, add:

```bash
--attachments-path .build/test-attachments
```

and create the directory first.

## Failure modes to check for

Before reporting results from this stream, verify:

1. **Are all the expected test targets present?** Count distinct modules against the package's test targets. On Swift 6.4 a shortfall means a product crashed or was filtered away; on an older toolchain it means the file was truncated. See "One output path, many test processes" above.
2. **Did every product's run complete?** Compare the `runEnded` count against the test-product count. A single `runEnded` is not evidence of a complete run on a multi-target package.
3. **Are there started-but-never-ended tests?** These are crashes and will not appear as issues.
4. **Are warnings being counted as failures?** Only on `"6.3"`+ can these be told apart; check `issue.isFailure`.
5. **Is the failure count deduplicated by test ID?** One test can emit many issues.
6. **Did the filter match anything at all?** A typo'd `--filter` regex produces a valid, empty run across every product that looks like success: exit 0, no test records, one console warning. Confirm the test-record count is non-zero and consistent with expectation.
7. **Are the counts real?** `jq 'select(...)' | wc -l` counts pretty-printed lines, not records. Project to a scalar first.
8. **Was `--disable-xctest` appropriate?** If the package has XCTest targets, disabling them silently narrows the run.

## Reporting

When summarizing a run for a user, lead with the counts and the failing tests with their source locations. Report crashed and skipped tests separately from failures — conflating them hides the most serious category. Prefer display names over raw test IDs in prose, but include the ID when the user may want to re-run with `--filter`, since the ID is directly usable as a filter pattern.
