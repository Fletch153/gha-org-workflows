# Decision log — Solana (Phase 1; Phase 0 did not run: `chains/solana.md` existed)

One entry per choice the spec plus the overlay did not determine. Tags: `[ABI]` on-chain
interface, `[BEHAVIOUR]` observable behaviour, `[INTERNAL-NAME]` naming/structure only,
`[TEST-TECHNIQUE]` how something is tested. Every `[ABI]`/`[BEHAVIOUR]` entry has been written
back into `chains/solana.md` (SKILL.md step 7).

## [ABI]

1. **Type vocabulary** (the overlay has no type table): `data_id`/`workflow_cid`/hashes →
   `[u8; 32]`; `workflow_owner` → `[u8; 20]`; `workflow_name` → `[u8; 10]`; `report_id` →
   `[u8; 2]` (raw metadata only); `String` → Borsh `String`; `List<T>` → Borsh `Vec<T>`;
   `Bytes` (`metadata`, `report` arguments) → Borsh `Vec<u8>`; `Address` → `Pubkey`;
   `Option<T>` → Borsh `Option<T>`; `u32`/`u64` keep their widths; records are Borsh structs
   with the spec field order (order is the wire ABI, names are not); `Bound` is a Borsh enum
   whose single tag byte is the spec discriminant (`AtOrBefore = 0`, `AtOrAfter = 1`).
2. **Instruction argument layout**: the Borsh enum tag is one byte (variant index); variant
   payloads carry the spec arguments in spec order; `find_round`'s `lo`/`hi` come **last**
   (`data_id, timestamp, bound, lo, hi`).
3. **Reader return types**: `latest_round` → `Vec<Option<RoundData>>`, `get_round`/`find_round`
   → `Option<RoundData>`, `round_range` → `Vec<RoundData>`, `decimals` → `Vec<Option<u32>>`,
   `description` → `Vec<Option<String>>`, `is_configured`/`is_frozen` → `Vec<bool>`,
   `get_feed_permissions` → `Vec<WorkflowPermission>`, `has_permission`/`is_feed_admin` → `bool`,
   `version` → `u32`, `type_and_version` → `String`, `get_owner` → `Option<Pubkey>`; Proxy
   `latest_round`/`get_round` → `Round { round_id, answer: [u8;32], timestamp }`, `decimals`/
   `get_min_decimals` → `u32`, `description` → `String`, `get_cache` → `Pubkey`. No `Result`
   wrapper (spec/06 G.2: the instruction result is the native channel).
4. **`RoundStillReadable = 111`** is a variant of the `CacheError` enum (the overlay places it
   in the Cache range but names no enum); the ownership codes are two enums, `OwnableError`
   (2100–2102) and `OwnableTransferError` (2200–2203), mirroring the two ranges of spec/01.

## [BEHAVIOUR]

5. **Presence rule at a derived address**: owned by the program → the first byte must be the
   record's discriminator (anything else, including empty data, → `InvalidAccountData`); not
   owned by the program → absent when it holds no data (lamports or not), `InvalidAccountData`
   when it holds data.
6. **`on_report` round account already initialised**: if the account for `(data_id, tip + 1)`
   already carries a Round record (unreachable in a consistent state) the call fails with
   `ProgramError::AccountAlreadyInitialized`.
7. **Check interleaving inside batches** (spec/06 D.2 gives the principle, not the exact
   order): `set_feed_configs` runs the whole spec validation of the entry data (codes 103–108)
   before consuming any per-entry account, then per entry: derivation/discriminator checks of
   its records, then the writes. `remove_feed_configs` per id: take + validate `feed_config`
   (derivation) → duplicate-id check (108) → presence (102) → take + validate its old
   permissions; all ids are validated before anything is closed. `set_feed_frozen`: the
   duplicate check over the whole list (108) precedes consuming any `feed_state`; then per id
   derivation → presence (110) → write + event. `on_report` per entry: derivation of
   `permission`, `feed_config`, `feed_state` and discriminator check of `feed_config` precede
   the permission lookup; the `round` account is derivation-checked only on append.
8. **`find_round` validates every supplied round account in `[max(lo,1), min(hi,tip)]`
   (derivation) before the binary search starts**; the tip's account is validated, never read.
9. **Ownership**: `live_until_ledger == now` is accepted (`< now` → 2201); there is no maximum
   offer horizon on Solana; `renounce_ownership` discards an expired offer; the events carry
   the arguments as passed (a cancel emits `ownership_transfer { old_owner, new_owner, 0 }`).
10. **`set_cache` stores the new address and then emits `CacheSet`** (spec/06 H.2 "after the
    effect" wins over the literal "emit; store" order of spec/03; unobservable within one
    instruction).
11. **Fixed-size record overwrite** (`FeedState`, `MinDecimals`, config): written in place,
    remainder zero-padded; only `FeedConfig` is resized.
12. **`recover_tokens` order**: owner gating (2100 / `MissingRequiredSignature`) →
    `token_program` is SPL Token (`IncorrectProgramId`) → `destination == to`
    (`InvalidArgument`) → `source` owned by SPL Token, unpacks as a token account, `mint ==
    token`, `owner == config PDA` (`InvalidArgument`) → CPI; `TokenRecovered` after the CPI.

## [INTERNAL-NAME]

13. Crates: `data-feeds-common` (modules `types`, `answer`, `errors`, `events`, `hash`,
    `ownership`, `accounts`, `window`, `token`), `data-feeds-cache` (`instruction`, `state`,
    `processor/{mod,admin,writer,readers,lifecycle}`), `data-feeds-proxy` (`instruction`,
    `state`, `processor`), `data-feeds-testkit` (harness; not a deployable).
14. Rust names: `CacheInstruction`/`ProxyInstruction` variants are the PascalCase of the spec
    names (the wire carries only the index); `CacheConfig { ownership }` /
    `ProxyConfig { ownership, cache }` wrap `OwnershipState { owner, pending }` (flat Borsh
    layout as the overlay states); `RoundRecord { round, payer }`; `Unit` for unit records;
    `PendingTransfer`; discriminator constants `DISC_*`; seed constants `*_SEED`.
15. `DATA_RETENTION_TTL`, `round_ttl()`, `Window::{initial, next, width_at, is_readable}` in
    `data_feeds_common::window`; `DECIMALS` in `types`; `VERSION`/`TYPE_AND_VERSION` constants
    per program.

## [TEST-TECHNIQUE]

16. **Inapplicable scenarios (34)** — not implemented, per spec/07 applicability:
    - `expiry` (spec/06 C.3: no TTLs on Solana; lifetime rules are no-ops):
      `cache.set_feed_configs.extends_contract_config_and_permission_ttls`,
      `cache.remove_feed_configs.extends_contract_instance_ttl`,
      `cache.add_feed_admin.extends_contract_and_admin_entry_ttls`,
      `cache.remove_feed_admin.extends_contract_instance_ttl`,
      `cache.on_report.extends_all_in_scope_ttls`, `cache.on_report.refreshes_all_permissions`,
      `proxy.constructor.extends_instance_ttl`, `proxy.latest_round.extends_instance_ttl`,
      `proxy.latest_round.extends_min_decimals_ttl`, `proxy.get_round.extends_instance_ttl`,
      `proxy.get_round.extends_min_decimals_ttl`, `proxy.decimals.extends_instance_ttl`,
      `proxy.decimals.extends_min_decimals_ttl`, `proxy.description.extends_instance_ttl`,
      `proxy.description.extends_min_decimals_ttl`, `proxy.set_cache.extends_instance_ttl`,
      `proxy.get_min_decimals.extends_instance_ttl`, `proxy.get_min_decimals.extends_min_decimals_ttl`,
      `proxy.get_cache.extends_instance_ttl`, `proxy.set_min_decimals.sets_entry_ttl_on_init`,
      `proxy.set_min_decimals.update_repins_entry_ttl`, `proxy.set_min_decimals.extends_instance_ttl`
      (22). The lifetime-refresh conditions are covered as persistence by the scenarios that
      read back state after warps and by `tests/extra.rs`.
    - `in_contract_upgrade` (spec/06 I.2: the upgrade is the loader's, outside the program):
      `cache.set_feed_configs.stale_feed_state_resurrects_across_remove_upgrade_and_re_add`,
      `cache.lifecycle.upgrade_is_wired`,
      `cache.lifecycle.all_persistent_and_temporary_feed_state_survives_upgrade`,
      `proxy.lifecycle.upgrade_is_wired`, `proxy.lifecycle.proxy_is_upgradable`,
      `proxy.lifecycle.cache_is_upgradable` (6). The resurrection and cache-swap conditions
      are covered without the upgrade step by the applicable scenarios
      (`re_add_by_a_different_workflow…`, `re_add_first_report…`, `cache_is_swappable`,
      `get_round_history_does_not_span_caches_after_swap`); the state-survives-upgrade and
      routing-survives-upgrade conditions are covered by the two loader tests in
      `tests/extra.rs`, which deploy the built `.so` artifacts behind the BPF upgradeable
      loader with the owner as authority and upgrade them via a buffer (spec/06 I.4).
    - `network_max_variable` (spec/06 C.3: the network maximum is unbounded and cannot be
      varied): `cache.get_round.explicit_id_reads_share_the_lookback_window`,
      `cache.round_range.window_shrinks_immediately_when_the_ttl_drops`,
      `cache.round_range.window_grows_at_grow_at_ledger`,
      `cache.find_round.window_shrinks_immediately_when_the_ttl_drops`,
      `cache.find_round.window_grows_at_grow_at_ledger` (5). The window arithmetic is tested
      against the helper (`data-feeds-common/src/window.rs` unit tests) and the window mask is
      exercised through the public interface with a 38.9M-slot warp
      (`cache_retention_rounds_outside_the_window_are_unreadable_and_reclaimable`).
    - `per_arg_auth` (spec/06 A.2): `cache.on_report.sender_without_auth_host_fails` (1). The
      A.2 guarantee is `cache_on_report_non_permitted_caller_is_soft_skipped_with_its_own_identity`.
17. Tests live in a fourth workspace member, `crates/data-feeds-testkit` (harness lib + `tests/`),
    so that the Cache and Proxy crates need no cyclic dev-dependencies and both processors are
    loaded into one `ProgramTest`. Scenario tests are **generated** from `spec/scenarios.json`
    by `tools/gen_tests.py` (checked in) as explicit step calls carrying the corpus values as
    `json!` literals; the harness translates the corpus vocabulary (shorthand ids, actors,
    reports, value matching) mechanically.
18. `expect_error_codes`: `ownership_range: [2100, 2199]` is asserted against `OwnableError`
    (2100–2102), and the transfer-helper codes (2200–2203) are additionally asserted to lie in
    2200–2299 and to be disjoint from the contract's range (the corpus, extracted from a
    reference with a three-variant `OwnableError`, does not mention the second range).
19. Every transaction is `[memo(nonce), call]`, processed with
    `process_transaction_with_metadata`; the memo (bundled SPL Memo v3) makes identical calls
    unique. Reads are processed the same way (return data from the metadata) rather than
    simulated. The fee payer is the context payer; the `as` actor signs and is the `payer (s,w)`
    that funds rent (funded once by a transfer, never via `set_account`). Errors are read as
    `InstructionError(1, …)`; `host_fail` asserts `MissingRequiredSignature`; `decode_fail`
    asserts `Custom(100)` (overlay F: Borsh returns an error, so `MalformedReport`); an extra
    `{"host_error": name}` expectation asserts other native errors.
20. Events are parsed from the transaction log: `Program data:` lines (SBF) and the mirrored
    `Program log: Program data:` lines (native processor), attributed to the executing program
    by tracking the `invoke`/`success`/`failed` lines. Events of a failed call are treated as
    not emitted (the transaction is rolled back).
21. The Cache double (`testkit::mock`) is a native processor under two ids (`mock_cache` →
    `cache`, `mock_cache2` → `cache2`); its per-feed state (`MockFeed { latest, rounds, frozen,
    fail_with }`) is written with `set_account` to **both** the `feed_state` and `feed_config`
    PDAs of the double, so every Proxy reader group resolves it and `fail_with` reaches
    `decimals`/`description` too. `get_round` answers from `rounds` only, `latest_round` from
    `latest` only (literal reading of spec/07).
22. `expire_round` = `set_account(round PDA, default)`; `advance {to}` = `warp_to_slot`;
    `find_round` scenarios (no `lo`/`hi` in the corpus) are run with `lo = 1, hi = tip`;
    `round_range` accounts are supplied for `max(from,1)..=min(to,tip)`; `on_report` round
    accounts are derived by replaying the batch against chain state (permission presence and
    running timestamps).
23. Loader tests: after a loader deployment only single-slot warps are used (program-test's
    program cache panics with "Unexpected replacement of an entry" on a multi-slot warp right
    after a deployment), so the rounds of that test are written in one slot; the tests skip
    with a message when `target/deploy/*.so` is absent.
24. `recover_tokens` corpus values: `"to": "payer"` resolves to a token account of the `payer`
    actor created by the harness; `mint {to: "cache"}` credits a token account owned by the
    program's config PDA; `expect_balance` reads the actor's token account.
