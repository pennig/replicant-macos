# Goal & decision policy

Type: grilling
Status: open
Blocked by: 01
Labels: wayfinder:ticket

## Question

What is the brain's vocabulary of goals, and how does it choose and prioritise among them?

The brain turns global world state (ticket 01) into concrete work. This ticket defines
*what it wants* and *how it arbitrates* — the heart of the orchestrator.

Resolve:
- **Goal vocabulary.** What is a goal? ("survey outward from X", "mine this salvage",
  "bridge this gap", "print+deliver a relay to Y", "fulfil this event"). Are goals derived
  fresh each tick from world state (stateless policy) or are they persisted intents?
- **Prioritisation.** When multiple goals are live, what ranks them? (value, distance,
  unblocking-other-goals, operator-pinned priority?) The salvage planner's
  "already-meshed → one-hop → units → distance" ranking is a precedent to generalise.
- **Contention.** Two goals want the same vessel; many goals share the 60/min actions
  budget. How is a device assigned to at most one goal? How is budget apportioned so no
  capability starves? (Absorbs the deferred **multi-vessel coordination** gap — two roam
  runs currently pick the same target because neither sees the other.)
- **Spend ceiling.** The operator authorised "unattended within a ceiling." What is the
  ceiling's shape — a reserve floor (keep ≤ N idle printed relays), a rate, a per-tick
  cap? Where does it live?
- **Idle & backoff.** When nothing is worth doing, what does the brain do? (Ties to 02.)

Consult `/grilling` + `/domain-modeling`. Must cite the robustness bar (02). Feeds 04, 06,
and the mesh-growth policy.
