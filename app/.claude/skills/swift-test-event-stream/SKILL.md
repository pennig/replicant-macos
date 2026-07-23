---
name: swift-test-event-stream
description: Query the results of `swift test` programmatically using Swift Testing's JSON event stream (`--event-stream-output-path`) combined with `--filter` and `jq`. Use this skill whenever the task involves extracting, counting, summarizing, or gating on Swift test results — parsing failures out of a test run, building a CI check, finding slow tests, detecting crashed tests, producing a report from a Swift package's test suite, or comparing runs. Reach for it especially if you are about to scrape or regex `swift test` console output, since that output is not a stable interface and the event stream is. Also applies when the user mentions swift-testing's JSON ABI, event stream, `--event-stream-version`, `--experimental-event-stream-output`, or asks why `swift test` results are hard to parse — and when event stream output appears truncated, overwritten, or to be missing test targets, which is a known trap this skill explains.
---

# Querying `swift test` results via the Swift Testing event stream

`swift test` console output is human-readable text with no stability guarantees. Swift Testing also emits a machine-readable JSON Lines stream covering the same run. Parse that instead — it is a documented, versioned ABI, and it carries structured source locations, issue severities, tags, and timing that the console text either omits or buries in prose.

This skill covers only Swift Testing. XCTest emits nothing into this stream.

## Core invocation

```bash
swift test \
  --disable-xctest \
  --filter 'CartTests' \
  --event-stream-version 0 \
  --event-stream-output-path .build/events.jsonl
```

Both event-stream options are declared on `swift test` but marked `help: .hidden`, so they do not appear in `swift test --help`. They are real and supported — do not conclude they are unavailable because help does not list them.

Mechanically, SwiftPM declares these options so ArgumentParser will not reject them, then forwards the entire command line through to swift-testing's entry point. That pass-through is also why `--filter` reaches both testing libraries: SwiftPM consumes it for XCTest, and swift-testing re-parses it independently.

Legacy aliases `--experimental-event-stream-output` and `--experimental-event-stream-version` still work but are marked private. Prefer the non-experimental names; recognize the old ones in existing scripts and CI configs.

**Always pass `--disable-xctest`** unless the package genuinely has XCTest targets that need to run. Otherwise SwiftPM emits "no matching tests" noise that has nothing to do with the stream.

**Always pin `--event-stream-version`.** Omitting it selects "the current supported non-experimental version," which floats across toolchains and will silently change field availability under a script. Pick a version deliberately using the table below.

## Filtering

`--filter` takes a regular expression matched against test IDs. A test ID has the form:

```
Module.SuiteName/functionName()/File.swift:line:column
```

For example: `AppTests.CartTests/addsItem()/CartTests.swift:11:3`

This is the same string that appears as `payload.id` on test records and `payload.testID` on events, so a filter expression and the JSON you get back share one namespace. That makes it practical to filter a run down, then key jq queries off the same identifiers.

`--skip` is the inverse and composes with `--filter`. Both accept multiple occurrences.

Filtering a parameterized test selects the whole function, not individual cases. There is no supported way to filter to a single argument set.

## One output path, many test processes

**This silently produces wrong results. Check for it before trusting any output from a multi-target package.**

Symptom: the event stream file contains only the last test target's events. Everything earlier in the run is missing, and nothing warns you.

The cause is four behaviors composing badly:

1. SwiftPM's default build system is now `swiftbuild` (`--build-system native` is deprecated).
2. Under `swiftbuild`, each test target becomes its own test product and its own binary. The older `native` backend produced a single umbrella `<Package>PackageTests` bundle instead.
3. SwiftPM runs one process per test product, forwarding the entire command line — including `--event-stream-output-path` — to every one of them.
4. Swift Testing opens that path in truncating mode (`"wb"`). There is no append mode.

So N test targets means N processes truncating the same file. The last writer wins.

Detect it by counting distinct modules in the output and comparing against the package's test targets:

```bash
jq -r 'select(.kind=="test").payload.id | split(".")[0]' .build/events.jsonl | sort -u
```

One module where several were expected confirms it.

### Choosing a fix

**When the task is already scoped with `--filter`, prefer `--test-product`.** A filtered run is usually aimed at tests that live in one target anyway, so naming that product collapses the run to a single process — which fixes the truncation and skips building and running the other products. The two options compose naturally: `--test-product` narrows to a binary, `--filter` narrows within it.

```bash
swift test --test-product ModuleATests --filter 'CartTests' \
  --disable-xctest --event-stream-version 0 \
  --event-stream-output-path .build/events.jsonl
```

`--test-product` is a hidden option and takes a product name, not a target name. Passing an umbrella product name selects all of its members and reintroduces the problem.

**`--build-system native`** also works and needs no knowledge of product names, which makes it the better choice for a whole-package run. It is deprecated, so treat it as a stopgap rather than something to bake into CI.

**For a full run that must stay on `swiftbuild`,** run each product into its own file and concatenate. JSON Lines concatenates cleanly, and every aggregate recipe below keys off `testID`, which stays unique across modules:

```bash
for p in ModuleATests ModuleBTests; do
  swift test --test-product "$p" --disable-xctest --event-stream-version 0 \
    --event-stream-output-path ".build/events-$p.jsonl"
done
cat .build/events-*.jsonl > .build/events.jsonl
```

The one recipe this breaks is the run-completed gate: a concatenated stream has one `runStarted`/`runEnded` pair per product, so assert the `runEnded` count equals the product count rather than checking `any(...)`.

A FIFO also works — opening a FIFO in truncating mode destroys nothing — but the reader must know how many writers to expect, since each process closing sends EOF. Reach for it only when live streaming is the actual goal.

## Stream anatomy

The output file is JSON Lines: one complete JSON object per line, no enclosing array. Every line has the same envelope:

```json
{"version": "6.4", "kind": "test" | "event", "payload": { ... }}
```

There are exactly two record kinds. Ignore any line whose `kind` you do not recognize — the format reserves the right to add more.

**`test` records** describe the static test plan: suites and functions, their names, display names, source locations, and (on newer schema versions) tags, bugs, and time limits. They are all emitted *before* most events.

**`event` records** describe what happened: `runStarted`, `testStarted`, `testCaseStarted`, `issueRecorded`, `testCaseEnded`, `testEnded`, `testSkipped`, `runEnded`, `valueAttached`, `testCancelled`, `testCaseCancelled`.

The critical structural fact: **events carry only a `testID`, never a name.** Display names, tags, and bug references live on the `test` records. Any human-readable output requires joining the two.

Fields prefixed with an underscore (`_testCase`, `_comments`, `_backtrace`, `_error`, `_knownIssueComment`) appear in the JSON but are explicitly outside the schema. Read them opportunistically for diagnostics; never build a CI gate on them.

## Recipes

All of these are verified working. Use `jq -s` (slurp) where a query needs the whole stream at once — joins and aggregations do; line-at-a-time filters do not.

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

A test that traps produces `testStarted` with no terminal event, and the stream simply stops — no `testEnded`, no `issueRecorded`, no `runEnded`. This is the failure mode most likely to be missed, because a naive "any failing issues?" query reports a clean run on a process that died.

Diff the started set against the terminated set:

```bash
jq -s -r '
  map(select(.kind=="event").payload) as $e
  | (($e | map(select(.kind=="testStarted").testID))
   - ($e | map(select(.kind=="testEnded" or .kind=="testSkipped").testID)))[]
' .build/events.jsonl
```

### Run-completed gate

Pair the crash check with an explicit completion check. These are different conditions and deserve different exit codes:

```bash
jq -s -e 'any(.[]; .kind=="event" and .payload.kind=="runEnded")' .build/events.jsonl >/dev/null \
  || echo "run did not complete — process died mid-suite"
```

`jq -e` sets exit status from the output value, so this composes directly into shell conditionals.

### Live consumption

The stream is written incrementally, and SwiftPM's own tooling passes a FIFO as the output path. For progress reporting rather than post-hoc analysis:

```bash
tail -f .build/events.jsonl | jq --unbuffered -r 'select(.kind=="event").payload | select(.kind=="testEnded") | .testID'
```

## Schema versions

Pin deliberately. Newer versions add fields; they do not remove them.

| Version | Adds | Swift |
|---|---|---|
| `0` | Baseline: test records, events, issues, messages | 6.0 |
| `0` | Attachments (`valueAttached`) | 6.2 |
| `"6.3"` | Issue `severity` and `isFailure`; `filePath` on source locations; test cancellation events | 6.3 |
| `"6.4"` | `tags`, `bugs`, `timeLimit` on test function records | 6.4 |

Note the type change: version `0` is a JSON number, later versions are semver strings. Compare with care.

Choose `0` for maximum toolchain portability, accepting that warnings are indistinguishable from failures and `filePath` is unavailable (only `fileID`). Choose `"6.3"` or later when the analysis needs severity discrimination or absolute file paths — for instance when emitting CI annotations that must resolve to real files.

## Attachments

`valueAttached` events carry only `{"path": ...}`. Attachments are written to disk only if `--attachments-path` points at an existing, writable directory; otherwise they are created and discarded. If a task involves reading attached values, add:

```bash
--attachments-path .build/test-attachments
```

and create the directory first.

## Failure modes to check for

Before reporting results from this stream, verify:

1. **Are all the expected test targets present?** Under the `swiftbuild` backend a multi-target package truncates the file down to its last product. Count distinct modules before reporting anything. See "One output path, many test processes" above.
2. **Did the run complete?** Absence of `runEnded` means the process died. Never report "0 failures" on an incomplete stream.
3. **Are there started-but-never-ended tests?** These are crashes and will not appear as issues.
4. **Are warnings being counted as failures?** Only on `"6.3"`+ can these be told apart; check `issue.isFailure`.
5. **Is the failure count deduplicated by test ID?** One test can emit many issues.
6. **Did the filter match anything at all?** A typo'd `--filter` regex produces a valid, empty run that looks like success. Confirm `testStarted` count is non-zero and consistent with expectation.
7. **Was `--disable-xctest` appropriate?** If the package has XCTest targets, disabling them silently narrows the run.

## Reporting

When summarizing a run for a user, lead with the counts and the failing tests with their source locations. Report crashed and skipped tests separately from failures — conflating them hides the most serious category. Prefer display names over raw test IDs in prose, but include the ID when the user may want to re-run with `--filter`, since the ID is directly usable as a filter pattern.
