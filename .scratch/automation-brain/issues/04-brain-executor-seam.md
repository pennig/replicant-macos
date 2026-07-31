# Brain ↔ executor seam

Type: grilling
Status: open
Blocked by: 01, 03
Labels: wayfinder:ticket

## Question

How does the brain start, stop, and own executors without double-committing a device?

The brain is additive: it launches/retires the existing bespoke runs (Survey roam,
Salvage Run) as opaque executors and, later, the new primitive-based behaviours. This
ticket defines the seam between the *policy* (tickets 01/03) and the *machinery* (the
existing `DirectiveEngine` + `MissionStepMachine`s).

Resolve:
- **Launch/retire contract.** How does the brain create a directive (today the launcher
  sheets do this) and how does it retire one? A directive is created with
  `controllerCode: nil` and claims its controller at preflight — does the brain reserve
  devices earlier, and if so how does that interact with `assignController`?
- **Ownership.** A device must serve at most one executor at a time. Who records the claim
  — the brain, the `CommandGovernor` (per-device in-flight claim, but that's per-command
  not per-mission), or a new mission-level lease? How is a lease released on
  completion/stall/cancel without wedging the device (the governor's release-on-every-path
  precedent)?
- **Feedback.** How does the brain learn an executor finished, stalled, or needs the one
  HITL decision (a location-event approach choice)? Does it read `Directive.status` +
  `DirectiveAttentionReason`, or a richer channel?
- **Existing stalls.** Today a stall halts and waits for the operator. Under the brain,
  which stalls become the brain's problem to route around vs still the operator's? (The
  stall matrix was deliberately kept as "everything halts" — does B change that, and does
  that reopen the auto-skip decision that was rejected twice?)

Consult `/grilling`. Must cite 02. Feeds 05 and every capability build.
