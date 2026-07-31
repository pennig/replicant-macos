# Resource-hub model

Type: grilling
Status: open
Blocked by: 01
Labels: wayfinder:ticket

## Question

How does the brain model resource hubs, inventory, and supply?

The operator expects hubs to be an **emergent** need as fleet numbers and distances grow —
places where inventory accumulates and from which printing/supply draws. This ticket builds
the domain model the brain reasons over for material.

Resolve:
- **What is a hub?** A designated location, an emergent property of where stock/autofactories
  sit, or an operator-tagged role? Inventory is location-bound and only `transport` devices
  carry cargo (see [[directives-feature]] "print-if-missing is permanently out") — so a hub
  is a *place*, and material at the wrong place is unusable. How is that represented?
- **Inventory accounting.** How does the brain know what material sits where, how fresh that
  is, and what a print will consume? (Ties to ticket 01's freshness question and research 07.)
- **Supply.** Autofactory feeding and restock (`awaitingRelayRestock` is the current human
  hole) — a hub is drained/filled by `shuttle` (ticket 05). What triggers a resupply goal
  (ticket 03), and what's the reserve policy?
- **Placement.** Do hubs get *placed* deliberately (a goal), or only recognised where they
  form? Interaction with mesh growth (a hub off-mesh can't be commanded).

Consult `/domain-modeling` + `/grilling` and research 07/09. Feeds the `shuttle` primitive
(05), the auto-print+deliver build, and mesh growth. Must cite 02.
