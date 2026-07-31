---
name: ftl-authority-rule
description: "Command authority = a replicant physically present, OR the target in an FTL-mesh subgraph containing one STATIONARY replicant. A relay must be IN a system for it to be meshed (7.5 ly is the relay-to-relay edge, not a coverage radius), and within a subgraph there are no hops. Corrects the geometry-first reading; `in_control_range` is the server's own answer."
metadata:
  type: reference
---

Operator-supplied and probe-confirmed 2026-07-30. This corrects a natural but wrong reading of the
docs that cost most of a design session.

**Authority to issue a command at a location comes from either:**

1. a replicant physically present in that system, or
2. the target sitting in an FTL-mesh subgraph that **also contains one stationary replicant** —
   stationary meaning *not currently in interstellar travel*.

**A relay must physically be in a system for that system to be on the mesh.** The 7.5 ly figure is
the relay-to-relay **edge** range, not a coverage radius that pulls relay-less neighbours in. A
system 3 ly from a relay is still dark until it has its own relay.

**Within a connected subgraph there are no hops.** Any two systems in the same subgraph are
effectively directly connected, however many ≤7.5 ly edges the subgraph contains. `ftlLinks` stores
that **closure**, which is why it reads as a 7-clique containing pairs up to 12.53 ly apart — do not
mistake those rows for physical links, and do not compute hop counts from them.

Consequences that bite:

- **The anchor replicant must not travel.** `pennig-1` sitting still at MENKENTAN-3 is what makes the
  whole mesh commandable. While it is in interstellar travel the mesh goes dark for commands. A
  *roaming* replicant (the survey roam) is therefore never an acceptable anchor — it is in transit
  most of the time.
- **Planting a relay is what frees a vessel.** A mining vessel at an off-mesh system is the only
  authority there, so a hauler sent to meet it can only be commanded while it stays parked. Put a
  relay in that system and the hauler becomes commandable from the anchor, so the vessel can leave.
- **`in_control_range` (Bool) is on every device** in `DeviceListItemSchema` and `DeviceStatusSchema`
  — already in `openapi.json`, already decoded by the generated client, and **read by nothing in the
  app**. It is the server's own answer to all of the above. Prefer it to any geometry the app
  computes. See [[device-tags-and-control-range]].
- Relays must sit at an **L4/L5 Lagrange point**, which is a first-class addressable location
  (`location_type: "lagrange"`, with `lagrange.parent_planet` / `l_point`). Emplacement is travel to
  `<STAR>-<n>-L4`, then `deploy`, then `activate`; an active relay reports status `relaying`.
- An **FTL beacon needs the mesh to function** — beacons report status but cannot carry commands
  without a relay. So "deliver a beacon" tasks imply "deliver a relay" first.

See [[salvage-run-design]] for the design this rule shaped, and the directives spec's
"reachability is a precondition on every dispatch" line, which this makes concrete.
