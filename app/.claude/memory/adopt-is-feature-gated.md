---
name: adopt-is-feature-gated
description: "An AMI controller adopts any device carrying its feature (`mine`/`survey`/`transport`), not one named worker device type — and several device types carry one feature."
metadata:
  type: reference
---

The backend gates `adopt` on the candidate's **device feature**, not its `device_type`.
A controller shepherds every device carrying its feature:

| controller | feature | live types carrying it |
|---|---|---|
| `ami_mining_controller` | `mine` | `mining_drone`, `heaven_vessel`, `racing_vessel` |
| `ami_survey_controller` | `survey` | `survey_drone` |
| `ami_transport_controller` | `transport` | `cargo_freighter`, `transport_hauler` |

The mapping lives in `DeviceCommand.controllableFeature(for:)`; `CommandAvailability.adoptCandidates`
filters `Device.features` with it. Blueprints carry the same `features` array per device
type, so a type the account holds no instance of is still resolvable through `blueprints`.

**There is no `transport_drone`.** The one-type-per-controller rule this replaced named
one, so `adoptCandidates` came back empty for every transport controller, and because
`CommandAvailability.commands` withholds `adopt` on an empty candidate list, the button
was hidden permanently on all seven of them while `available_commands` carried `adopt`
and unadopted `cargo_freighter`s sat idle. A type-named gate cannot express a feature
several types carry — that is the shape of the bug, and why the fix is the feature.

Adjacent: the offered command set is **not** `available_commands` alone. `CommandAvailability.commands`
maps the server's list and then applies its own filter, dropping any verb whose candidate
list or precondition is empty (`adopt`, `release`, `attach`, `detach`, `change_owner`,
`message`, `repair`, `replicate`, `set_directive`, plus `retarget`/cargo state gates). A
verb the server offers can be absent from the grid entirely.

Docs (`/docs/ami/`) say only "Controllers can adopt most other non-AMI devices" and name
no per-controller feature; the feature vocabulary above is from the live fleet's `features`
arrays. Consequence worth knowing before trusting the mining picker: `mine` is also
carried by the vessels that host replicants, so a mining controller's candidate list
includes them. See [[replication-source-matrix-feature]] for the same feature-not-type
gating on `replicate`, and [[carrier-hull-capability-gate]] for the cost of a type gate
where a capability gate belonged.
