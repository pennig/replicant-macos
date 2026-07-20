---
name: device-refresher-dependency
description: All device confirm-reads funnel through @Dependency(\.deviceRefresher) over one shared PollCoordinator.
metadata: 
  node_type: memory
  type: project
  originSessionId: a152c5b7-926a-4e21-ab2a-d531fc3ba240
---

`PollCoordinator` (coalescing + TTL + read-budget) lives in **GameServices** (the module renamed from `DependencyClients` on 2026-07-03; `DeviceRefreshClient.swift` is there too) and backs `@Dependency(\.deviceRefresher)`, whose `liveValue` owns one process-shared coordinator. `RefreshPriority` (`.low`/`.high`) is the public top-level enum it vends.

Every device re-read now goes through it: GameSync's `deviceRoute` (`.high` when the event closed an op, else `.low`), `DeadlineScheduler.processDue` (`.high`), and `DevicesFeature`'s while-viewing loop (`.high` — deliberate poller, bypasses TTL but still coalesces). `Reconciler` is a stateless struct, so the coordinator owning its own instance is equivalent to sharing GameSync's. Tests inject `$0.deviceRefresher` backed by a real `PollCoordinator`. Related: [[device-inspector-refresh-loop]].
