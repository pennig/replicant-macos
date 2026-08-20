# 12 — The transaction-counting tests count transactions, not rows

Status: ready-for-agent
Blocked by: —

`WorldTickReads.opensExactlyOneReadTransaction` and
`aTicksTransactionCountDoesNotGrowWithTheRoster` are the branch's strongest
tests, and they have one blind spot the whole-branch review identified as the
highest-value gap left open:

**Move `Device.all.fetchAll(db)` inside `readAll`'s per-directive loop and every
test on the branch stays green** — while reintroducing exactly the 22×-decode
regression the branch exists to kill. The transaction count is unchanged; the row
count explodes.

`opensExactlyOneReadTransaction`'s doc claims it makes that regression
"impossible to reintroduce without a red test". It does not.

That matters because decoding, not transaction count, was the measured cost:
`JSONDecoder` was 35.4% of app CPU and `sqlite3_step` only 19.2%.

**Fix, either shape:**
- have the counting `DatabaseReader`/`DatabaseWriter` pair also count `fetchAll`
  invocations, and assert that count is O(1) in roster size, or
- assert a row-count ceiling per tick.

The counting harness already exists (`WorldTickTests.swift`, the
`CountingReader`/`CountingWriter` pair) and is real protocol conformance, so this
is an extension rather than new machinery.

**Prove it by mutation:** hoist a whole-table read into the per-directive loop and
confirm the new assertion goes red. A counting test that cannot catch that
mutation has not earned its doc comment.

**Done when:** a per-directive whole-table read fails a test, and
`opensExactlyOneReadTransaction`'s doc claim is true or narrowed to what it
actually proves.
