The device `printing` block carries `tags` — the handles the finished device
inherits — alongside `device_type` / `started_at` / `completes_at` /
`progress_percent` / `eta_seconds`. Declared in every archived openapi back to
2.1.1 on `app_schemas_devices_PrintingInfoSchema`, and populated live: bench
`43C9B54A` read `{"tags":["auto:event:ainalram-belt-1"], …}` on 2026-08-20.

`PrintingSnapshot` parsed the other five keys and dropped this one until
2026-08-20, so a job's tags were readable while it sat in `print_queue` and
invisible once it reached the platen.

Two asymmetries worth knowing:

- The **replicant** variant, `app_schemas_replicants_PrintingInfoSchema`, has no
  `tags`. Only the device-level block declares them.
- `print_queue` is typed in the spec as a bare array of open objects, so the
  QUEUED tags the UI has always shown are the undocumented ones and the ACTIVE
  tags are the documented ones. Parsing stays lenient on both.

The server lowercases every tag — see [[tendmesh-relay-pool-and-carrier-tag]]
before matching on one.
