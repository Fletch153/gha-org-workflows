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

## EVM round 1 — skill v3 + mechanics-only EVM overlay — builds, 206 tests, 22 decisions

`out_dir=/home/user/df-gen/evm-1`. Purpose: surface every platform-dependent question. Full
log in `evm-round1-DECISIONS.md`. Headline answers the agent had to invent (and Chainlink's
real EVM cache for comparison):

| Axis | Agent chose | Chainlink EVM |
|---|---|---|
| Account model | keep `sender` arg, require `msg.sender == sender` | drop arg, use `msg.sender` |
| History/expiry | window mask emulated, nothing reclaimed | unbounded mappings |
| Upgrade | delegatecall self-forwarding emulation | immutable, migrate via proxy swap |
| Errors | `CacheError(uint32 code)` typed errors | named custom errors |
| Optionals | `{present, value}` structs | n/a |
| Naming | snake_case verbatim | camelCase |
| Ownership | implemented spec table + 2200 code | ConfirmedOwner (no expiry) |

Outcome → skill v4: `spec/06-platform-model.md` gives a rule per axis (A account/auth,
B storage, C expiry/history, D tx/compute/size limits, E errors, F serialisation,
G optionals, H events, I upgradeability, J ownership/time, K naming/widths, L cross-contract);
the EVM overlay becomes an instantiation of those rules. Notable rulings: caller-identity
chains drop the `sender` argument; the retention window is behaviour on every chain; no
upgrade emulation on chains without native code replacement.

## EVM round 2 — skill v4 — builds, 193 tests, 23 decisions (all minor)

`out_dir=/home/user/df-gen/evm-2`. Isolation clean. Verified independently: `forge test`
193/193; no `upgrade` on the ABI (I.3); `sender` argument dropped (A.2); camelCase (K.1).
Decision log (`evm-round2-DECISIONS.md`) no longer contains architectural choices; what is
left: unnamed struct/library names, ownership-table trigger order and cancel/expiry details,
`MinDecimals` presence (0 is a valid minimum), token-transfer failure handling, forge
`[lint]` key location, and which spec/05 conditions are vacuous on the EVM (upgrade,
lifetime refresh, TTL-varying window, sender-without-auth).
→ v5: full ownership semantics table in spec/06 J (taken from the Stellar library's exact
behaviour), presence exception for `MinDecimals`, token failure rule, overlay fixes.

## Solana round 1 — skill v4 — builds, 159 tests, 24 decisions

`out_dir=/home/user/df-gen/solana-1`. Isolation clean. Verified: `cargo test --workspace`
159/159; both `.so` built; no `upgrade` instruction (I.2). Decisions (`solana-round1-DECISIONS.md`)
were overwhelmingly gaps in the overlay's account conventions (admin record, ownership /
recover / reclaim accounts, discriminators, instruction tags, config sizing, rent flows,
history-read indexing) plus the ownership-trigger questions also raised on EVM.
→ v5: spec/06 J now the full ownership semantics (from the Stellar library); C.3 says how
TTL-varying window conditions are tested on constant-TTL chains; Solana overlay carries the
complete instruction/account table.

## Skill v5 — stop criterion for the multi-chain loop
A chain is "done" when: artifact builds; own tests pass; the decision log contains no entry
that changes ABI or behaviour (only internal names / test technique are acceptable).

## EVM round 3 — skill v5 — builds, 222 tests, 12 decisions (0 architectural) — EVM CONVERGED

`out_dir=/home/user/df-gen/evm-3`. Isolation clean. Verified `forge test` 222/222. Log
(`evm-round3-DECISIONS.md`): 1 `[ABI]` = the name of the host-style token-failure error;
4 `[BEHAVIOUR]` entries restate spec-implied behaviour (u32 `now`, accept check order,
constants not exposed as getters, hand-written strict decoder); the rest are internal names
and test technique. → v6: overlay names `TokenTransferFailed(address token)`; spec/06 K states
constants are not public functions.

## Solana round 2 — skill v5 — builds, 109 tests, 21 decisions (5 ABI, 8 behaviour)

`out_dir=/home/user/df-gen/solana-2`. Verified `cargo test --workspace` 109/109, both `.so`.
Log (`solana-round2-DECISIONS.md`): remaining ABI gaps were overlay omissions — program ids,
config account layout, round payload order, `has_permission`'s `sender` (a lookup key, not a
principal), Proxy CPI account grouping; behaviour gaps were D.2 validation details (range
edge cases, `recover_tokens` account checks vs "no extra validation", reclaim check order,
foreign discriminators, pre-funded addresses, return-data cap, bad instruction data).
→ v6: spec/06 A.2 distinguishes principals from lookup keys; K.3/K.4 (constants not public;
D.2 validation is never "extra validation"); EVM overlay names `TokenTransferFailed`; Solana
overlay carries all of the above.

## EVM round 4 — skill v6 — builds, 194 tests, 21 decisions (0 real choices) — CONVERGED

`out_dir=/home/user/df-gen/evm-4`. Verified `forge test` 194/194. Every `[ABI]`/`[BEHAVIOUR]`
entry restates a spec ruling (view readers, `CacheError(109)`, u32 `now`, no validation where
the spec is silent) or a Solidity mechanic (calldata→storage copy). Caught one spec
inconsistency: spec/05 says ownership codes lie in 2100–2199; spec/01/06 say 2100–2299 → v7.
