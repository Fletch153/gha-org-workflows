# Loop log

## Round 1 — skill v1 (commit c6bed82) — ALL GREEN, loop stopped

Generator: fresh general-purpose agent, prompt named only the skill dir, `chain=stellar`,
`out_dir=/home/user/df-gen/round-1`. Transcript audit: 0 reads outside skill/out dirs, 0 web
tool uses. 42 tool calls, ~30 min.

| Gate | Result |
|---|---|
| G1 wasm build | PASS (cache 52,151 B; proxy 35,402 B, no Cache exports linked) |
| G2 own tests | PASS — 164 passed, 0 failed (cache 109 / common 7 / proxy 48) |
| G3 reference conformance | PASS — cache 117/117, proxy 62/62 |

Negative control: grading a wrong wasm → 116/117 cache tests fail, so G3 is discriminating.

### Generator's ambiguity report (candidates for skill v2; not yet applied)
1. `type_and_version` can't have a default body in a `#[contracttrait]` — say it is required per contract.
2. Whether `upgrade` / `recover_tokens` refresh the instance lifetime — spec/04's general phrase vs. its list disagree. Reference: they do not. State it.
3. Topic fields of `Upgraded` / `TokenRecovered` unspecified — state "no topic fields".
4. `set_min_decimals`: say owner auth precedes the `min > DECIMALS` check.
5. "Overwriting never re-pins" is not observable via the public interface — move that row out of the "through the public interface" test section.
6. Test-env note: window tests need `set_max_entry_ttl` lowered and `min_persistent_entry_ttl` lowered (default 4096) or first-write pinning can't be observed.
7. "network maximum below the fresh minimum" — define "fresh minimum" (network minimum entry TTL).
8. Overlay: `default-features = false` for the cache dep must be on the *workspace* dependency line.
9. Overlay: pin `ed25519-dalek` to 2.2.0 (`soroban-env-host 26.1.3` allows 3.0.0, which breaks testutils).
10. Distinct upgrade fixture forced a 4th, non-member crate — allow it explicitly.
