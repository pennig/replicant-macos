# A modular device must be printed flatpacked to be carried

`enqueue_print` carries `flatpack` (openapi 2.5.0+, "print the device in a
compacted state (modular devices only)"). Nothing in the app sent it until
2026-08-23, so every modular device an event run printed came off the bench
unfurled — and the surge carrier's attach grid takes a modular device only
compacted, so the convoy could not load it.

**`modular` is a blueprint FEATURE, not a device one**, and the twelve types
carrying it are exactly the composite ones (a non-empty `components` bill):
`autofactory`, `galactic_observatory`, `system_hub`, `atmospheric_regulator`,
`biosphere_cultivator`, `climate_processor`, `colony_shuttle`, `fleet_tender`,
`orbital_foundry`, `stellar_forge`, `deep_space_relay_station`,
`orbital_defence_platform`. No modular type appears as another blueprint's
component, so "is it modular" and "does it fly as payload rather than get
consumed" are the same question — which is why the flag needs no second gate.

Everything else an event convoy attaches — `ftl_beacon`, `matrix_container`,
`sensor_array`, `defence_grid`, `shield_generator` — is non-modular, attaches
unfurled, and must NOT be sent `flatpack`: the flag is documented for modular
types only and the server's tolerance for it elsewhere is untested.

`WorldCore.read` folds the feature into `modularDeviceTypes`, `WorldSnapshot`
mirrors it, and `EventRun.printing` is the only site that sets the flag. An
empty set (unread catalogue) flatpacks nothing, which leaves a print unchanged.

**Two things this does NOT do.** A modular device already standing at a depot
unfurled is never compacted by the run — `loading` attaches it and the confirm
ladder ends in `commandRejected`; there is no `compact` dispatch anywhere in
`DirectiveEngine`. And whether an event's criteria count a compacted device
after `staging` detaches it on site is unverified — no run has delivered one.
