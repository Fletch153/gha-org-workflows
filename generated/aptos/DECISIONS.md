# Decision log — Chainlink Data Feeds on Aptos (Move 2 / Aptos CLI 7.6.0)

One entry per choice that `spec/` plus `chains/aptos.md` did not determine. Tags:
`[ABI]`, `[BEHAVIOUR]`, `[INTERNAL-NAME]`, `[TEST-TECHNIQUE]`. Phase 0 did **not** run
(the overlay existed). `[ABI]`/`[BEHAVIOUR]` entries were written back into
`chains/aptos.md` (SKILL.md step 7).

## [BEHAVIOUR]

- **B6-native-error.** spec/06 B.6 requires a `Round` that must be created at `tip + 1` but
  already exists to fail with the platform's native "already initialised" error. The overlay
  did not name it. Realised as `aptos_std::table::add` on the existing key, which aborts
  with the table native's `ALREADY_EXISTS` code `0x6407` (25607), location
  `aptos_std::table`. Unreachable through the public interface (rounds are only written at
  `tip + 1` and never deleted); covered by
  `cache_on_report_pre_existing_round_at_next_id_is_native_already_exists`, which forges the
  state with the test-only injector. Written back to the overlay (axis B).
- **Proxy-cache-not-validated.** `proxy::create` and `proxy::set_cache` store the `cache`
  address without checking that a `Cache` instance exists there (spec: "store cache", nothing
  extra). A later reader then aborts with `host_error::no_instance()` (`0x60001`) raised in
  `data_feeds::cache` — this is what the `fail_with` substitution of spec/07 relies on.
  Written back to the overlay (axis L).

## [ABI]

- none beyond the overlay. (The example transaction script
  `cache/sources/scripts/set_feed_configs_script.move`, `set_one_feed_config`, is not part
  of the module ABI; it is the spec/06 M.1 script path for `set_feed_configs`, kept in the
  package so it is compiled with it. Its name is logged under `[INTERNAL-NAME]`.)

## [INTERNAL-NAME]

- Cache helpers: `assert_instance`, `assert_feed_admin`, `delete_permissions`,
  `is_all_zero`, `permission_hash`, `readable_round`, `record`, `round_ttl`; strict BCS
  decoder `Reader { bytes, pos }`, `decode_report`, `read_u8`, `read_uleb128`,
  `read_bytes`, `read_u64_le`, `read_u256_le`. Table key structs `PermissionKey { data_id,
  phash }` and `RoundKey { data_id, round_id }` (as named in the overlay).
- Proxy helpers: `effective_min`, `validate_decimals`, `assert_not_frozen`, `project`,
  `scale`, `pow10`, `is_negative`, `negate`, `assert_instance`. The Proxy carries its own
  `DECIMALS = 18` constant (spec: the constant, not a Cache call).
- `data_feeds::window`: `initial`, `width_at`, `next`, `is_readable`, `saturating_add`,
  accessors `shortest_ttl` / `grow_to_ttl` / `grow_at_ledger`.
- `data_feeds::ownable`: `new`, `set_owner` (private), `get_owner`, `assert_owner`,
  `transfer_ownership`, `accept_ownership`, `renounce_ownership`; `PendingTransfer`.
- `data_feeds::ledger::sequence`, `data_feeds::host_error::{unauthorized, no_instance,
  invalid_argument}` (as named in the overlay).
- Test-only: `cache::test_ensure_state` (private), `test_decimals`, the event constructors
  `<snake_event_name>_event(..)`, `test_event_counts` order `[FeedUpdated, StaleReport,
  InvalidUpdatePermission, FeedConfigSet, FeedConfigRemoved, FeedFrozenSet, FeedAdminAdded,
  FeedAdminRemoved, OwnershipTransfer, OwnershipTransferCompleted, OwnershipRenounced,
  TokenRecovered]`; Proxy `test_event_counts` order `[CacheSet, MinDecimalsSet,
  OwnershipTransfer, OwnershipTransferCompleted, OwnershipRenounced, TokenRecovered]`;
  `ownable::test_error_codes` (table order); `data_feeds::test_utils` (helpers `setup`,
  `advance_to`, `deploy_cache`, `id`, `wire`, `zero32/20/10`, `owner_bytes`, `name_bytes`,
  `repeat`, `neg`, `metadata_with`, `metadata`, `default_metadata`, `entry`,
  `encode_report`, `report`, `report_as`, `seed`, `perm`, `default_perm`, `config_entry`,
  `configure`, `assert_round`, `assert_round_full`, `latest`, `latest_is_none`,
  `full_range`, `assert_permission`, `snapshot`, `assert_only`, `assert_count`,
  `assert_no_events`, `emitted`, `deploy_token`, `mint`, `balance`).
- Example script: `set_one_feed_config(admin, cache, data_id, description, allowed_sender,
  allowed_workflow_owner, allowed_workflow_name)`.
- Test actor addresses: `owner = @0xA1`, `admin = @0xA2`, `admin2 = @0xA3`, `sender = @0xB1`,
  `sender2 = @0xB2`, `stranger = @0xC1`, `new_owner = @0xD1`, `payer = @0xE1`; instance seeds
  `b"cache"`, `b"cache2"`, `b"proxy"`, token seed `b"TOKEN"`; "no instance" address `@0xDEAD`.

## [TEST-TECHNIQUE]

### Inapplicable scenarios (34) — not implemented, per spec/07 applicability

`capabilities: [external_upgrade]`; a scenario applies only if every `requires` tag is
declared.

- `requires: ["expiry"]` (22) — spec/06 C.3: Aptos has no entry expiry; every pin/refresh is
  a no-op and `expect_ttl`/`age_ttl` have no meaning. The lifetime-refresh conditions are
  covered as persistence (`cache_on_report_refreshed_records_persist`,
  `proxy_set_min_decimals_update_persists`, and every scenario that reads back state).
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
  `proxy.get_min_decimals.extends_instance_ttl`,
  `proxy.get_min_decimals.extends_min_decimals_ttl`, `proxy.get_cache.extends_instance_ttl`,
  `proxy.set_min_decimals.sets_entry_ttl_on_init`,
  `proxy.set_min_decimals.update_repins_entry_ttl`,
  `proxy.set_min_decimals.extends_instance_ttl`.
- `requires: ["network_max_variable"]` (5) — spec/06 C.3: the network maximum is unbounded
  and `round_ttl` is the constant; the harness cannot vary it. The conditions are tested
  directly against `data_feeds::window` (`window_tests.move`: shrink, grow at
  `grow_at_ledger`, replaced plan, same-ledger writes, raised/lowered reach, lock-in) and the
  window mask through the public interface by the two universal `cache.retention.*`
  scenarios. `cache.get_round.explicit_id_reads_share_the_lookback_window`,
  `cache.round_range.window_shrinks_immediately_when_the_ttl_drops`,
  `cache.round_range.window_grows_at_grow_at_ledger`,
  `cache.find_round.window_shrinks_immediately_when_the_ttl_drops`,
  `cache.find_round.window_grows_at_grow_at_ledger`.
- `requires: ["in_contract_upgrade"]` (6) — spec/06 I.2 / I.4: Aptos package upgrade is
  driven by the publisher outside the contract; no `upgrade`/`Upgraded`. Resurrection and
  cache-swap conditions run without the upgrade step (`re_add_*`, `cache_is_swappable`,
  `get_round_history_does_not_span_caches_after_swap`); the "no upgrade entry point"
  condition is the named tests `cache_lifecycle_no_upgrade_entry_point` /
  `proxy_lifecycle_no_upgrade_entry_point` (compile-time fact, spec/06 M.4).
  `cache.set_feed_configs.stale_feed_state_resurrects_across_remove_upgrade_and_re_add`,
  `cache.lifecycle.upgrade_is_wired`,
  `cache.lifecycle.all_persistent_and_temporary_feed_state_survives_upgrade`,
  `proxy.lifecycle.upgrade_is_wired`, `proxy.lifecycle.proxy_is_upgradable`,
  `proxy.lifecycle.cache_is_upgradable`.
- `requires: ["per_arg_auth"]` (1) — spec/06 A.2: the caller is the sender; a missing
  signer is rejected by the transaction layer before Move runs. The A.2 equivalent guarantee
  is `cache_on_report_caller_identity_is_the_sender` (a non-permitted caller is soft-skipped
  with its own identity and cannot claim another sender's).
  `cache.on_report.sender_without_auth_host_fails`.

### Harness realisations (spec/07 portability rules)

- **Failing calls terminal.** A Move test aborts at the first failure, so every non-failing
  step runs first and the failing call is the terminal statement under
  `#[expected_failure(abort_code = N, location = M)]`. Reads the scenario places *after* a
  failing call are executed *before* it (sound: no state-changing step follows a failing
  call; the platform is transaction-atomic). Scenarios with k failing calls became `<id>`
  plus `<id>__alt2 … __altk` (8 companions):
  `cache.set_feed_frozen.a_feed_without_state_aborts_the_whole_batch` (2),
  `proxy.precision.unset_min_locks_reads_to_full_precision` (2),
  `proxy.precision.below_the_configured_min_is_rejected` (2),
  `proxy.precision.above_cache_precision_is_rejected` (2),
  `proxy.precision.configured_min_without_data_is_no_data_present` (2),
  `proxy.cache_reader_client.every_read_on_an_unconfigured_feed_is_no_data_present` (4).
- **Expectation mapping.** `{"error": N}` → `abort_code = N` in `data_feeds::cache` /
  `data_feeds_proxy::proxy`; `{"cache_error": 109}` → `abort_code = 109` in
  `data_feeds_proxy::proxy` (the Proxy raises it); `{"host_fail": true}` →
  `host_error::unauthorized()` = `0x50001` in `data_feeds::ownable`; `{"decode_fail": true}`
  → `MalformedReport` (100) in `data_feeds::cache` (the contract's own strict decoder
  returns an error rather than trapping).
- **`fail_with` substitution** (`proxy.latest_round.cache_error_traps_the_read`): the mock is
  the real Cache module, so after injecting the tip the Proxy is re-routed with
  `set_cache(owner, proxy, @0xDEAD)` (an address holding no Cache instance) and the read is
  asserted to abort with the Cache's own host failure `0x60001`, location `data_feeds::cache`
  — a Cache failure surfaces through the Proxy untranslated.
- **Mock Cache** (`deploy mock_cache` / `mock_cache2`): a real Cache instance whose `id:1`
  (the only id the mock scenarios use) is configured by the owner with description `"MOCK"`,
  so `decimals`/`description` answer `18` / `"MOCK"`. `latest` → `cache::test_set_latest`
  (creates a zero-tip `FeedState` if absent, sets only `latest_round`); `rounds` →
  `cache::test_inject_round` per round (ledger_seq 1000, primary true, zero-tip state if
  absent); `frozen` → `cache::test_set_frozen`. The zero-tip state is a test-only artefact;
  production code never creates one.
- **Events.** `event::emitted_events<T>()` accumulates over a test, so `only`/`count` are
  asserted as per-type count deltas around the call (`test_event_counts` snapshot);
  exact fields via `event::was_event_emitted` on a test-only constructed event.
  `expect_events.ordered` (reconfigure: `FeedConfigRemoved` then `FeedConfigSet`): cross-type
  order is not observable; both events and their counts are asserted and the emission order
  is kept in the code.
- **Sequence.** `advance {to: n}` → `timestamp::update_global_time_for_test_secs(n)` guarded
  as a no-op when `n` equals the current second (the framework requires strictly increasing
  time). Environment starts at 0 (`set_time_has_started_for_testing`).
- **`advance {by_retention, plus}`** uses `ledger_seq` read back from the round plus the
  overlay's `DATA_RETENTION_TTL = 15_552_000`.
  `cache.retention.rounds_inside_the_window_stay_readable_just_before_it_closes` **cannot
  hold as written**: with the seed rounds at ledger 101/102/103, `plus: -1` sets `now =
  103 + TTL - 1 = 102 + TTL`, and spec/04 (readable iff `ledger_seq >= now - width`) already
  masks round 1 (101 < 102) there — on every chain, not only Aptos. The test therefore
  advances to the last sequence at which all three seeded rounds are inside the window
  (oldest `ledger_seq` 101 + TTL), asserts the scenario's full value (three rounds, every
  field), and additionally asserts that one sequence later round 1 drops out. The sibling
  scenario (`plus: 1`) is implemented literally (103 + TTL + 1) and holds. Reported as a
  corpus off-by-one.
- **`expire_round`** → `cache::test_expire_round` (removes the round-table entry; the tip in
  `FeedState` is untouched, as on an expiry chain).
- **`expect_state absent MinDecimals`** → `proxy::test_has_min_decimals == false`.
- **`expect_error_codes`** → `cache::test_error_codes()` / `proxy::test_error_codes()` /
  `ownable::test_error_codes()` vectors (names are private constants, spec/06 E.2), asserted
  for exact values, range membership and disjointness.
- **Token.** `deploy token` = a primary-store-enabled fungible asset with unlimited supply on
  a named object (`b"TOKEN"`) created by `owner`; `mint {to}` →
  `primary_fungible_store::mint`; `expect_balance` → `primary_fungible_store::balance`. The
  token's `Metadata` object address is the `token` argument.
- **Signers.** Actors are `#[test(...)]` signer parameters; `as` is the signer passed; the
  corpus' `sender`/`admin` args are ignored (A.2).
- **Instance addresses.** `owner` creates every instance (`object::create_object_address`
  with the seeds above); the corpus names `cache`/`cache2`/`proxy` resolve to those.
- **Atomicity** ("aborts and writes nothing") relies on VM transaction atomicity plus the
  reordering above (spec/06 M.4).
- **Additional tests** beyond the corpus (spec/05 conditions the applicable scenarios do not
  cover on Aptos, and the overlay's host-check statements): the ownership table conditions
  (2100, 2101, 2200, 2201, 2202, 2203, expiry, replacement, non-pending acceptor) on both
  contracts; decoder strictness (truncation, non-minimal ULEB128, length above u32,
  mis-sized id soft-skip, cid/report_id not validated); byte-width host checks and their
  ordering in `set_feed_configs` / `set_min_decimals`; `Bound` discriminant; missing
  instance; duplicate seed (`object::EOBJECT_EXISTS`); `recover_tokens` framework aborts and
  non-owner; the window helper conditions; the permission-hash encoding; the retention
  constant; the B.6 native error.
