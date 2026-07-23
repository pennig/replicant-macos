---
name: swift-test-event-stream-quirks
description: "swift test --event-stream-output-path quirks: --filter yields an EMPTY stream (vacuous 0), unfiltered captures only the LAST test bundle; use the swift-testing summary line for filtered evidence."
metadata:
  node_type: memory
  type: reference
---

Discovered 2026-07-23 (three independent trips during the Stage 3 DirectiveComposer work). The CLAUDE.md rule "read results from the event stream, not console text" needs these caveats in this toolchain:

- **`--filter <target/suite>` + `--event-stream-output-path` writes an EMPTY event stream** — `runStarted`/`runEnded` only, recording "0 tests in 0 suites" even while the console shows the filtered tests genuinely running and passing. Any `issueRecorded == 0` check against that file is a vacuous false-positive ("0 issues because 0 tests ran").
- **An unfiltered `swift test --event-stream-output-path` records only the LAST test bundle** that ran (e.g. `APITests`), not a package-wide aggregate — so a package-wide "0 issues" from one stream file is also not trustworthy.
- The per-test event kinds here are `testStarted` / `testEnded` (plus `issueRecorded`) — **not** `testCaseEnded`.

**How to verify a filtered run instead:** use swift-testing's own final summary line, which is authoritative and can't silently mask a failure:

```sh
swift test --filter DevicesFeatureTests 2>&1 | tail -8
# gate on: "Test run with N tests in M suites passed"
```

The event-stream file remains the right tool for a single-bundle unfiltered run; just know which bundle you're reading. See [[running-package-tests]].
