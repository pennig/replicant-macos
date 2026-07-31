# Primitive contracts: print / deliver / shuttle

Type: prototype
Status: open
Blocked by: 04
Labels: wayfinder:ticket

## Question

What are the contracts of the three composable primitives, and how do they compose?

The new behaviours (mesh, auto-print+deliver, events) are built from a small set of
primitives rather than more bespoke machines. This ticket pins each primitive's contract
by making a rough concrete artifact (stub signatures + a worked composition) to react to.

Resolve, per primitive:
- **`print a device`** — inputs (device type, where, from which materials/hub), preconditions
  (feature gate, material availability), what it emits, failure modes. Note: a salvage vessel
  carries the `print` feature and mined output lands in the location stockpile, so
  print-in-situ is mechanically plausible (see [[salvage-run-design]]).
- **`deliver a device to a location`** — a printed/idle device → a target (relay to a gap,
  drone to a site, service bot / event device). How does it handle stow/launch, travel,
  arrival confirmation, and hand-off of command authority ([[ftl-authority-rule]])?
- **`shuttle cargo from source(s) → a location`** — the Haul Run's job generalised.
  **Key decision: does the unbuilt Haul Run collapse into `shuttle`, or ship as its own
  kind?** Multi-source (several stockpiles → one hub) is where resource hubs (ticket 06)
  meet this primitive.
- **Composition & seam.** Are primitives sub-machines a run/goal invokes, standalone
  directives the brain dispatches directly, or both? How do they report up to the brain
  (ticket 04)? Are they `MissionStepMachine`s themselves, or a lighter tier?

Build the stub artifact under `.scratch/automation-brain/research/` or a `/prototype`
branch and link it here. Consult `/prototype` + `/grilling`. Must cite 02. Depends on the
hub model (06) for `shuttle`'s multi-source shape — coordinate.
