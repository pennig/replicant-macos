# 09 — Re-profile and record the real number

Status: ready-for-human
Blocked by: 08

The estimate is ~18% of a core against today's 53%. It is arithmetic from
measured shares, not a measured result, and stays unclaimed until a fresh
trace says otherwise.

Needs Matt: capturing a Time Profiler trace requires a Keychain login a
background job cannot complete. At least 90s of idle app time.

**Trap for whoever attributes it:** the parser must resolve
`<tagged-backtrace ref="N"/>`. In the original trace 147,218 of 280,546 rows
reused a deduplicated backtrace by ref, and dropping them silently attributes
47% of samples to "empty stack" — which reads like a profiler limitation
rather than the parser bug it is.

Full steps: `../plan.md` → **Task 9**.

**Done when:** `../spec.md`'s "Expected result" section carries the measured
split instead of the estimate, and says plainly whether the arithmetic held.
If it did not, the gap is the next investigation.
