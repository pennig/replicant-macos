---
name: device-inspector-refresh-loop
description: How the device inspector keeps a mining/diverting device live while viewed
metadata: 
  node_type: memory
  type: project
  originSessionId: 2c2c1027-117a-48d5-901c-94cd9cdf9626
---

The device inspector (`DevicesFeature` / `DeviceDetailView`) refreshes a device **in place while it's being viewed** for activities that mutate without a completion event. Two such activities today: **mining** (continuous, no deadline) and **diverting** (slow deflection progress).

Mechanism: `DeviceDetailView` has a `.task(id: refreshKey)` where `refreshKey` is the device code only when `statusBase` is `mining`/`diverting` (else nil). It sends `.viewingChanged(deviceCode:)`; the reducer runs a `.cancellable(id: .refresh, cancelInFlight: true)` loop that re-reads the device (`devicesClient.read` → `Reconciler().ingest`, which the views observe) and, for a propulsor, re-fetches the diversion snapshot. Cadence lives in the pure static `DevicesFeature.refreshDelay(for:now:)`: mining → just past `started_at + cycle_time_seconds` (so the read reflects the finished cycle); diverting → 30s; settled/other → nil (stops the loop).

Key domain facts these surface:
- **Mining vs seeking:** `MiningSnapshot.isProducing = pending_cycles > 0 || pending_quantity > 0`. A scarce belt that yields nothing leaves both at 0 = "Seeking". The mining/diversion detail lives in the device `detail` blob (`[[device-command-shapes]]`); a diverting propulsor carries NO block of its own — its impact/progress come from `GET locations/{code}`'s `object` block (`[[location-sites-endpoint]]`).

The refresh loop is a long-running effect over the live clock, so it's not covered by an exhaustive `TestStore` walk — `refreshDelay` and the snapshot parsers are unit-tested instead.
