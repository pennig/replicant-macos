---
name: logistics-haul-yields
description: "LogisticsFeature (Logistics sidebar) SHIPPED 2026-08-10: the haulYields ledger + charts. Yields are RECONSTRUCTED from ami.transport.digest deltas, never reported (1,318 collections over 15 days vs 22 individual transport.collected events). Attribution is directives.deviceCode only. The categorical palette clears only ADJACENT pairs, so no all-pairs form may ever be added to this screen."
metadata:
  node_type: memory
  type: project
---

Spec: `docs/superpowers/specs/2026-08-10-logistics-design.md`. `HaulYield` (GameModels) +
`LogisticsIngestion` (GameServices) + `LogisticsFeature`/`LogisticsView` (charts + ledger).

**Yields are reconstructed, never reported.** An AMI-controlled transport is event-silent
([[ami-drones-are-event-silent]]): a pickup is inferred from a rise in the controller digest's
`cargo_carried`, and the composition comes from one triggered `.high` device read. Measured
2026-08-10: 1,318 collections over 15 days, only 22 individual `transport.collected` events. No
opt-out exists; `/v1/events` keeps no useful history, so a period with the app closed is a
permanent hole — `HaulYield.followsGap` marks exactly that.

**Attribution goes through `directives.deviceCode` only** — never `controllerCode` (stamped once
at launch, so older pinned rows carry nil) or `fleetTag` (worn by no device, it's belt-scoped).

**The `.high` device read is budget-gated**, a deliberate exception to the "no refresh on the
router's dispatch path" invariant at `ReplicantApp.swift:81-85` ([[haul-run-design]] established
the same controller). `LogisticsIngestion.recordPickup` checks `gameClient.budget(.reads)` before
issuing the read (mirroring `PollCoordinator`'s own floor) and writes `breakdownState = .unavailable`
— preserving the total, never blocking ingestion on `RateLimitGovernor.acquire`'s sleep.

**The categorical palette clears the colorblind gate on ADJACENT pairs only** and fails under
all-pairs in both modes — so no all-pairs categorical form (scatter, bubble, choropleth, six-colour
small multiples) may ever be added to this screen, and direct labels on the stacked column are
structural, not decoration. Slot order is `ResourceCost.displayOrder`; the naive remapping puts two
greens adjacent and drops the normal-vision floor to 15.6 against a hard-fail line of 15. **Guarded
only by a manual `dataviz` validator run — nothing in CI checks this** — re-run it by hand on any
future palette edit.

**The By Resource donut (2026-08-12) adds one adjacency the stacked column never had: the WRAP
pair.** A ring in `displayOrder` seats volatiles beside structural, which no linear form does, so
validating the six slots in order is not sufficient — validate `volatiles,structural` as its own
2-slot run. Measured: light ΔE 26.5 (protan), dark 27.3 (deutan), both well clear. The ring stays
gate-safe only while it keeps `displayOrder`; reordering it re-rolls the interior pairs and the
wrap together. The donut's direct labels (slices ≥10% share, `YieldChartMath.labelledResourceKeys`)
are the mandated relief for the light-mode slots under 3:1 contrast, and the legend is the second,
non-optional half of that relief, since a sub-10% slice gets no label at all.

**Validate against the app's REAL surfaces, never the validator's defaults** — `ContentBackground`
is `#F9F5EE` light and `#0D1018` dark, not `#fcfcfb`/`#1a1a19`. On the real light surface THREE
slots sit under 3:1 (conductive 2.94, silicates 2.59, rares 2.48), not the two an earlier pass
recorded against the generic surface.

**"Adjacent pairs is the right gate here" was half true, and the missing half is the LEGEND.** The
marks are adjacent forms, but every chart on this screen carries a legend, and a legend is an
all-pairs surface — six swatches side by side. Matt (colour-deficient) reported carbon as unreadable
against structural, and the measurement agreed: dark `#9085E9` vs `#3987E5` was **ΔE 1.9 protan**
and 9.8 normal, under the 15 floor. Carbon is now `#852D71`/`#9444A6`, found by an OKLCH sweep
maximising worst-pair separation under the band, chroma floor, real-surface contrast and the normal
floor (dark 1.9 → 10.5 CVD, 9.8 → 19.8 normal). **Two worse pairs remain and will surface in the
legend next**: dark silicates↔rares at ΔE 1.6, and conductive↔volatiles at 3.2 light / 2.7 dark.
**Dark mode cannot be fixed by hue alone** — five of six dark slots sit at L ≈ 0.62, so the palette
spends nothing on lightness, the one channel CVD preserves; any carbon hue caps near ΔE 12.
`docs/tools/resource-palette-playground.html` is the OKLCH bench for that work (live CVD simulation,
per-pair scoring, xcassets export) — it is the intended way to re-roll a slot, not a hand-picked hex.

Two latent traps: `haulYields.perType` has SQL `DEFAULT '{}'`, which `ResourceCost` cannot decode
(six non-optional Ints, no defaults) — unreachable today since every write supplies it, but the
migration is shipped and append-only. And a delivery arriving after a gap closes a stale open row
with a fabricated `deliveredAt`/`destinationDesignation`, which nothing renders yet.
