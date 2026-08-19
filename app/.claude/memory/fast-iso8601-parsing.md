# Date columns decode through a hand parser, not ISO8601FormatStyle

`Date.FastISO8601Representation` (`GameModels/Sources/FastISO8601.swift`) is the
`@Column(as:)` representation on the hot `Date` columns. It overrides only the
**decode**; binding still goes through the library's own `.date` case, so the
bytes written are identical by construction and no migration is involved —
`freshSchemaMatchesTheGoldenFixture` passes unregenerated.

Applied to `Star`, `LocationFootprint`, `Device`, `Operation`, `Directive`,
`DirectiveLogEntry` and `LocationEvent`. A query predicate comparing one of those
columns against a `Date` must wrap the operand:
`$0.updatedAt < Date.FastISO8601Representation(queryOutput: cutoff)`.

## Three things that cost a round each

**Debug is the configuration that bites.** The first cut was 14x faster than
Foundation in release and 4x *slower* in debug: at `-Onone` a nested helper and
`Range.contains` per digit cost more than Foundation's precompiled parser. Flat
`UInt8` reads with explicit comparisons win in both. Benchmark any hand-rolled
hot loop in **both** configurations or the debug regression ships invisibly.

**`Date` stores time against the 2001 reference date.** Adding the fractional
seconds to a since-1970 interval disagreed with Foundation in the last bits on
296 of 1000 millisecond values. Add the fraction *after* the epoch shift.

**Foundation's Gregorian calendar is a Julian hybrid before the 1582 cutover.**
Proleptic arithmetic runs two days out there, so `0001-01-01` decoded as
`0001-01-03`. `.distantPast` is a live sentinel in `Directive`, so it reaches the
column — the fast path declines anything before 1583 and lets Foundation take it.

Guarded by differential tests asserting bit-exact agreement with Foundation
across a wide span and every millisecond value. Extend those before touching the
parser; the span test originally started at 1906 and that is exactly why the
calendar bug reached `DirectiveSchemaTests` instead of its own suite.
