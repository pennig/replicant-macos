---
name: convoy-legs-fly-abreast
description: A multi-hull step must step PAST a hull whose travel op is open, not return its `.wait` — returning it serialises the convoy into one crossing per hull.
---

# A convoy's legs fly abreast, not in a queue

`TravelTo.next` answers `.action(.wait)` while a hull's travel op is open. A
step flying SEVERAL hulls that returns that wait cannot order the next hull
until the one in front has landed, so an N-hull convoy costs N full crossings
per leg. `TravelTo.isUnderway` names the state; `EventRun.departing` and
`ReturnHome` skip past it and wait only once every hull is placed or airborne.

**Why it hid for so long:** every `departing` fixture teleported hulls between
`HUB-1` and `X-1` and never opened an operation, so the suite only ever walked
the arrival-gated path. `everyHullIsOrderedBeforeTheStepEnds` passes against
both the serial and the parallel code. A step whose real guard is an open op
needs a fixture that opens one — see [[same-step-dispatch-needs-tracked-op]].

Measured on the live ledger before the fix: event run `1C37ECB8` spent 48m52s
of its 51m29s in four sequential ~12-minute crossings.

The sibling rule about `confirmStep` in the same loop is
[[loop-legs-must-dispatch-in-step]] — both are needed, and neither implies
the other.
