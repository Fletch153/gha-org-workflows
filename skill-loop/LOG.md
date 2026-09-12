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

## Solana round 3 — skill v6 — builds, 146 tests, 16 decisions (0 ABI) — CONVERGED

`out_dir=/home/user/df-gen/solana-3`. Verified `cargo test --workspace` 146/146, both `.so`.
Log (`solana-round3-DECISIONS.md`): no ABI entries; behaviour entries are the choice of
native `ProgramError` variant for wrong cache program / bad CPI return data, the ordering of
account-derivation checks vs contract validation, and "reclaim emits no event" → v7 states
all three.

## Skill v7 — final state of this loop
Stellar: reference conformance 179/179 (rounds 1–3). EVM: converged at round 3, confirmed at
round 4. Solana: converged at round 3. Stop criterion met on all three chains.

Rounds run: Stellar 3, EVM 4, Solana 3. Every round: fresh agent, skill-only context,
isolation audited (no reference reads, no web).

## Aptos round 1 — skill v8, NO overlay existed — Phase 0 + implement — 180 tests

`out_dir=/home/user/df-gen/aptos-1`. The agent authored `chains/aptos.md` from the template,
verified the toolchain, implemented two Move packages (Cache 124 tests, Proxy 56), and wrote
all 12 `[ABI]` + 8 `[BEHAVIOUR]` decisions back into the overlay. Isolation clean.
It reported 8 questions `spec/06` did not answer (entry-argument limits, static linking /
instance model, sequence-unit choice, field privacy, constructor naming, post-abort
observability, compile-time-absent entry points, private constants) → v9 adds L.2, M.1–4
and the C.5 selection rule.
**Bug found via this run:** `DATA_RETENTION_TTL = 3_110_400` was a Stellar ledger count
(180 d @ 5 s) baked into the chain-agnostic spec; on EVM/Solana/Aptos it silently meant
432 d / 14 d / 36 d. v9 specifies retention as 180 days and derives the number per unit in
each overlay (EVM 1_296_000, Solana 38_880_000, Aptos 15_552_000; Stellar unchanged).

## EVM round 5 — skill v9 — builds, 189 tests, `DATA_RETENTION_TTL = 1_296_000` ✅

`out_dir=/home/user/df-gen/evm-5`. Isolation clean. Verified `forge test` 189/189 and the
retention constant. The agent logged 10 ABI / 11 behaviour entries — all restatements of
spec/overlay rulings — and wrote them back into `chains/evm.md` (+60 lines, committed here).
Real spec gaps it named (→ v10): the spec/05 "sender without host authorisation" condition
is A.1-only; G.1 applies to return values; presence rule for the pending offer; B.4 layout
always documented; E.2 constants non-public; K.2 token return-data rule; invalid enum
discriminant = host failure.

## Aptos round 2 — skill v9 (overlay existed) — builds, 187 tests, 0 ABI / 3 behaviour — CONVERGED

`out_dir=/home/user/df-gen/aptos-2`. Verified: cache 128 + proxy 59; `DATA_RETENTION_TTL =
15_552_000`. Isolation clean. Three behaviour entries (host instance check first; bound
discriminant validated before state lookup; `recover_tokens` event ordering) written back into
`chains/aptos.md` (committed here). Gaps → v10: host-check ordering generalised to all
platforms (D.2), M.2 accessors only for public-surface records, events after effects (H.2).

## Skill v10 — final state
| Chain | Path | Rounds | Final |
|---|---|---|---|
| Stellar | human overlay | 3 | 179/179 reference conformance |
| EVM | human overlay | 5 | 189 tests, retention 180 d, 0 real decisions |
| Solana | human overlay | 3 | 146 tests, 0 ABI decisions |
| Aptos | **self-authored overlay** | 2 | 187 tests, 0 ABI / 3 behaviour (written back) |
"Implement for a new chain" is now a single invocation: Phase 0 authors the overlay, Phase 1
implements + tests, step 7 hardens the overlay. Expect 1–2 runs per new chain to reach 0 ABI
decisions. Solana has not been re-run on the 180-day retention fix (v9); its overlay carries
the new number.

## Stellar round 4 — skill v11 (scenario corpus), generator = Sonnet — ALL GREEN

`out_dir=/home/user/df-gen/round-4`. Isolation clean. 294 tool calls, ~51 min.

| Gate | Result |
|---|---|
| G1 wasm build | PASS (cache 52,091 B / 25 exports; proxy 35,417 B / 16 exports — exactly the spec surface) |
| G2 own tests | PASS — 182 (179 scenario-derived, named by scenario id, + 3) |
| G3 reference conformance | PASS — cache 117/117, proxy 62/62 |

Scenario coverage 179/179 (Stellar declares every capability). Decision log: 1 `[ABI]` (no
case transform — correct), 2 `[BEHAVIOUR]` (single-pass `set_feed_frozen` relying on
invocation atomicity — identical to the reference; peek fixture reads the Owner slot), rest
test technique. Three SDK/test pitfalls appended to `chains/stellar.md` (committed here).

### Comparison across Stellar rounds
| Round | Skill | Model | Own tests | Reference | Open decisions |
|---|---|---|---|---|---|
| 1 | v1 | default | 164 | 179/179 | 10 ambiguities guessed right |
| 2 | v2 | default | 150 | 179/179 | 9 minor |
| 3 | v2 | Sonnet | 132 | 179/179 | 6 (3 flagged as unclear) |
| 4 | v11 | Sonnet | 182 | 179/179 | 3, all spec-consistent |
Functionally identical on every round (same 179 reference tests, same export surface). The
corpus raised the weaker model's own test count above the strong model's early rounds and
removed the guesswork; its remaining notes were corpus nits (one misnamed scenario, one
scenario relying on the mock's unconditional `decimals`).

## Grader v2 — closing the non-Stellar gap
Two independent checks now apply on every chain:
- `grade-scenarios.py <chain> <out_dir> <test log>`: applicable scenarios (by overlay
  capabilities) vs. passing tests named by scenario id. Stellar round 4: 178/179 (the one gap
  is an id renamed after that run).
- `mutants.md`: 16 behavioural mutants applied to the generated contract source by a grader
  agent; a faithful suite fails on each. **Calibration on Stellar round 4: 16/16 caught**,
  each by the predicted scenario family (baseline 182 pass, 0 fail).
A chain is graded PASS when: artifact builds; own tests pass; scenario coverage = all
applicable; mutation score = 16/16 (or n/a mutants explained).

## Aptos round 3 — skill v12 — builds, 225 tests, coverage 145/145, mutants 16/16 — PASS (grader v2)

`out_dir=/home/user/df-gen/aptos-3`. Isolation clean. `DATA_RETENTION_TTL = 15_552_000`.
Coverage grader: 145/145 applicable scenarios (34 inapplicable, each with its spec/06 rule).
Mutation grader: 16/16 caught, every one by the predicted scenario family. 1 ABI + 1
behaviour entry written back into `chains/aptos.md`. Reported holes → v13 (spec/07 harness
portability rules: multi-failure scenarios on abort-only harnesses, `fail_with` on
statically-linked mocks, cross-type event order, accumulating events; corpus
`ownership_range` 2100–2299; Aptos token fixture + injector notes).

## Solana round 4 — skill v12 — builds, 174 tests, coverage 145/145, retention 38_880_000 ✅

`out_dir=/home/user/df-gen/solana-4`. Isolation clean. Coverage grader 145/145 applicable
(34 inapplicable with rules). Scenario tests generated mechanically by a checked-in
`tools/gen_tests.py` from the corpus. 4 ABI + 8 behaviour entries written back into
`chains/solana.md` (type vocabulary + behaviour details; committed here). Mutation score:
pending. Reported holes → v14: spec/07 dropped-argument / `lo,hi` / token-account
conventions; spec/06 B.6 (pre-existing record at a create address) and C.4 (reclaim error
lives in the Cache enum).

## Solana round 4 — mutation grader: 16/16 caught (grader v2 PASS)
Caveats recorded by the grader: M7 partly an interface-shape catch on Solana (a program
cannot close an undeclared account); M11 caught only by the window helper's unit tests —
no corpus scenario observed the retention mask through the public interface on a
non-expiry chain. → v15: two universal `cache.retention.*` scenarios with a new
`advance {by_retention}` step (181 scenarios); M11 redefined so the universal scenario
catches it.

## Grader v2 results
| Chain | Coverage | Mutants | Reference |
|---|---|---|---|
| Stellar r4 | 178/179 (1 renamed id) | 16/16 | 179/179 |
| Aptos r3 | 145/145 | 16/16 | — |
| Solana r4 | 145/145 | 16/16 | — |
| EVM r5 | pre-corpus build; not graded | — | — |
