---
name: probe-api
description: Probe the live replicant.space API to discover real endpoint request/response shapes using the `replicant raw` CLI. Use when you need to confirm what a backend endpoint actually returns (field names, types, nesting, error shapes), check whether openapi.json has drifted from the server, or understand an endpoint before wiring a feature/domain client. Read-only GET probes are safe; POST/PATCH/DELETE mutate live game state and must be announced before running.
---

# Probe the replicant.space API

The `replicant` CLI (`/Users/matt/.local/bin/replicant`, on `PATH`) sends authenticated raw HTTP requests to the live game backend. Use it to see what an endpoint *actually* returns, rather than trusting `openapi.json` (which is known to lag the server — see the spec-drift note in memory).

## Command

```
replicant raw <METHOD> <path> [<json-body>]
```

- `<path>` is **relative to the API base** — pass `messages`, `devices/ABCD1234`, `replicants/XYZ/stars`. Do **not** prefix `v1/` or a leading `/`; the tool adds the base. (`replicant raw GET v1/messages` → 404; `replicant raw GET messages` → the real payload.)
- `<json-body>` is required for POST and PATCH. Quote it as a single shell arg: `'{"command":"stow"}'`.
- Auth is handled by the tool (it reads the stored session token from `replicant login`). Do **not** pass tokens or build URLs yourself.
- Run `replicant raw --help` for the tool's own examples, and `replicant --help` for other subcommands (`status`, `scan`, `travel`, `events`) which can be quicker ways to read state.

## Output

- Success → pretty-printed JSON on stdout (this is what you inspect for field names/types/nesting).
- Failure → a line like `Error: Server error (404): Not found`. Note: the process may still exit 0, so judge success by the body, not just the exit code.

## Safety — non-idempotent methods

**GET is read-only and safe — use it freely to explore.**

**POST, PATCH, and DELETE mutate live game state and are not idempotent.** They can issue device commands, rename replicants, spend resources, or delete things — there is one real account behind this, with no sandbox.

Before running any POST/PATCH/DELETE:
1. State clearly and up front, in your reply, that you intend to make a mutating request, naming the exact method, path, and body.
2. Explain the expected effect on game state.
3. Run it only to satisfy the user's actual goal — never as casual exploration. Prefer a GET to understand an endpoint first.

Xcode drives the approval prompt for these commands; let it. If the user hasn't clearly authorized the mutation, ask before running it.

## Typical workflow

1. Find candidate paths in `Modules/API/Sources/openapi.json` (or from an existing domain client like `MessagesClient` / `StarsClient`).
2. `replicant raw GET <path>` to capture the real response shape.
3. Compare the live payload to the generated `Components.Schemas.*` types — fields the server sends that the spec omits (or vice-versa) are the drift you need to handle (coalesce optionals; relax `additionalProperties`).
4. Use what you learned to write/adjust the feature's value types and mapping.

## Examples

```
# Read-only probes (safe):
replicant raw GET messages
replicant raw GET devices/ABCD1234
replicant raw GET replicants/XYZ/stars

# Mutating (announce first, then run only with the user's goal in mind):
replicant raw POST devices/ABCD1234 '{"command":"stow"}'
replicant raw PATCH replicants/XYZ '{"name":"new-name"}'
replicant raw DELETE devices/ABCD1234
```
