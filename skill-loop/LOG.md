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

## Round 2 — skill v2 (commit 702de83) — ALL GREEN

Same generator setup as round 1 (fresh agent, default model), `out_dir=/home/user/df-gen/round-2`.
Isolation audit clean. 44 tool calls, ~30 min.

| Gate | Result |
|---|---|
| G1 wasm build | PASS (cache 53,834 B; proxy 36,772 B, no Cache exports) |
| G2 own tests | PASS — 150 passed, 0 failed (cache 96 / common 4 / proxy 50) |
| G3 reference conformance | PASS — cache 117/117, proxy 62/62 |

### Generator's report (candidates for v3)
- 04-retention: prose says "previous plan aged out" but formula uses the new ttl — formula is right, prose loose; tighten.
- Overlay: `cargo update -p ed25519-dalek@3.0.0 --precise 2.2.0` is the working form.
- Overlay: `#[contracttrait]` already generates `<Trait>Client`; don't also ask for `#[contractclient]`.
- Overlay: default-bodied contracttraits re-emit signatures in the implementing crate → import `Env`, `Address`, `BytesN` there.
- Overlay: `Event` trait must be in scope for `to_xdr`; `env.events().all()` only holds the last invocation's events.
- 01-domain: ownership library also raises 2200–2299 (`RoleTransferError`); `renounce` only fails on an *unexpired* pending transfer; `transfer_ownership(.., 0)` cancels. Document as library behaviour.
- 05-tests: add the all-zero owner → 104 case.
- Overlay: `test_utils` gated on `cfg(any(test, feature = "testutils"))`.
- Overlay: SDK writes `test_snapshots/`; gitignore them.

## Round 3 — skill v2, generator = Sonnet (stress test) — ALL GREEN

Same prompt as round 2, `model: sonnet`, `out_dir=/home/user/df-gen/round-3`. Isolation audit
clean. 247 tool calls, ~46 min (weaker model needed more iterations but converged).

| Gate | Result |
|---|---|
| G1 wasm build | PASS |
| G2 own tests | PASS — 132 passed, 0 failed (cache 87 / common 3 / proxy 42) |
| G3 reference conformance | PASS — cache 117/117, proxy 62/62 |

Report highlights: `test_utils` gating wording; ownership library's 2200+ codes vs. the stated
range; `Bound` needs explicit discriminants on both variants; 104 case missing from tests list.

## Skill v3
Applied rounds 2+3 feedback (see the two lists above). Not re-validated by a fresh round yet —
every change is a clarification of behaviour that all three green rounds already exhibited.

## Status
3/3 rounds green across two model tiers on v1/v2. Stellar target is done; next milestone is a
second chain overlay, which will test whether `spec/` is truly chain-agnostic.
