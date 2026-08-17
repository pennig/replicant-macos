# Theatres are recognised, never placed

`TheatreRegistry.recognise(devices:pins:meshSystems:components:stockByLocation:)`
(`DirectiveEngine/Sources/TheatreRegistry.swift`), called once per tick from
`WorldView.read(from:now:)`, derives every `Theatre` fresh from world state —
there is no "place a theatre" command and no table row a theatre owns. Three
tiers, first match wins, depot designation breaking ties for a total order:

1. **`.pinned`** — every `TheatrePin` row becomes a theatre at the pin's
   location; its system is marked claimed.
2. **`.systemHub(code)`** — every `system_hub` device whose system holds no
   pin. Depot = the richest stocked print-capable location in that system,
   falling back to the hub device's own location so the theatre always has an
   identity even when `.claimed`.
3. **`.derived`** — for each mesh component holding no `.operational` theatre
   after the first two passes, the old `WorldView.hubLocation` rule (richest
   stocked print-capable location, designation tie-break) applies within that
   component.

**Why `.operational` gates the derivation pass, not "any theatre exists":** a
pin or a hub claim with no usable depot yet must not suppress derivation, or
pinning an empty system would blind the brain to a working depot elsewhere in
the same component. A `.claimed` theatre and a `.derived` operational one can
coexist in one component.

**Identity is now PERSISTED** in the `theatres` table (`TheatreRecord`, one row per system), making tiers 2 and 3 sticky while the row's depot still prints — written by `Brain.persistTheatres` and, for a pin, by `EstablishTheatreSheet`.

**Print-capability is the whole proviso; stock is deliberately NOT a condition.**
A depot going quiet is exactly the flip stickiness exists to outrank, so a
persisted depot that has run dry keeps the identity and reports
`.claimed(missing: [.noStock])` rather than hopping to a stocked sibling in the
same system. That is spec S1.7's rule read literally, and the trade is parked
for Matt, not settled: `readiness` is honest, but **the run is silent** — with a
second theatre operational, `theatreWentClaimed` sends seven mission guards to
`.wait` with no stall, no `attentionReason` and no operator surface, and nothing
can restock it, because the brain allocates only to operational theatres and the
haul run that would refill it is itself one of the waiters. Recovery needs the
operator. Pinned by `StickyTheatreRecognitionTests.aDryPersistedDepotKeepsTheIdentity`.

**Identity is the depot location** (`Theatre.id { depot }`): a theatre that
moves is a different theatre, and a stateless brain must name the same one
every tick from world state alone — the same reason `WorldView.hubLocation`
returned a bare designation before it was retired.
