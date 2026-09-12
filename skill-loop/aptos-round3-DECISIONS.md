# Decision log — Chainlink Data Feeds on Aptos (`/home/user/df-gen/aptos-3`)

Phase 0 did not run (`chains/aptos.md` existed). Every entry below is a choice the spec plus
the overlay left open, tagged per `SKILL.md` step 6. `[ABI]` and `[BEHAVIOUR]` entries have been
written back into `chains/aptos.md` (step 7).

## [ABI]

- **[ABI] Accessors for `FeedConfigEntry` and `ReportEntry`.** `spec/06` M.2 requires
  `<struct_snake>_<field>` accessors for every record on the public surface; the overlay's
  accessor list omitted the two batch-element records that `new_feed_config_entry` /
  `new_report_entry` produce. Added `feed_config_entry_data_id`, `feed_config_entry_config`,
  `report_entry_data_id`, `report_entry_answer`, `report_entry_timestamp` (all `public fun` in
  `data_feeds::cache`).

## [BEHAVIOUR]

- **[BEHAVIOUR] Grouping of byte-width checks inside `set_feed_configs`.** The overlay says
  widths are checked "at the point the entry is validated ... before that entry's spec checks".
  Realised as: for entry `i`, *all* width checks of that entry (its `data_id`, then every
  permission's owner and name in order) run first, then all of that entry's spec checks
  (`InvalidDataId`, `DuplicateFeedConfig`, `EmptyConfig`, per-permission `InvalidAddress` /
  `InvalidWorkflowName` / `DuplicatePermission`). So a mis-sized owner in permission 2 aborts
  with `host_error::invalid_argument()` even if permission 1 has an all-zero owner; entries are
  still processed in order, so a spec error in entry 1 precedes a width error in entry 2.

## [INTERNAL-NAME]

- `Metadata` (spec/01 record) is a private `struct Metadata has copy, drop` in `data_feeds::cache`
  (it never crosses the public surface, so no constructor/accessors per M.2).
- Private helpers: `assert_instance`, `require_admin`, `read_round`, `record`, `decode_metadata`,
  `decode_report`, `read_uleb128`, `permission_hash`, `remove_permissions`, `is_all_zero`
  (Cache); `effective_min`, `validate_decimals`, `frozen_check`, `project`, `scale`, `pow10`
  (Proxy); `window::next`, `window::initial`, `window::width_at`, `window::is_inside`;
  `ownable::enforce_owner`, `ownable::set_owner`, `ownable::new`.
- Test-only surface beyond the overlay's list: `cache::test_new_round_data` (a `RoundData`
  constructor for injection), `cache::test_set_latest` (sets `FeedState.latest_round` without
  touching the round table, i.e. the mock's `latest`), `cache::test_decimals`,
  `cache::test_event_counts` / `proxy::test_event_counts` (per-type emitted-event counts for
  "only"/"count" assertions), `proxy::test_feed_frozen_code`, and the harness module
  `data_feeds::test_utils` (actors, id/byte constructors, report encoding, `seed`, deployment,
  mock Cache, token, event deltas).
- Test signers are minted with `account::create_signer_for_test` at fixed actor addresses
  (`owner` 0xA1, `admin` 0xA2, `admin2` 0xA3, `sender` 0xB1, `sender2` 0xB2, `stranger` 0xC1,
  `new_owner` 0xD1, `payer` 0xE1); instances use seeds `b"cache"`, `b"cache2"`, `b"proxy"` with
  `owner` as creator.

## [TEST-TECHNIQUE]

### Inapplicable scenarios (34), with the `spec/06` rule

Overlay `capabilities: [external_upgrade]`; no scenario requires `external_upgrade`.

- `expiry` (22) — `spec/06` C.3: Aptos has no entry expiry; every pin/refresh is a no-op and
  TTLs cannot be read. Lifetime-refresh conditions are instead asserted as persistence
  (`cache_lifecycle_all_feed_state_persists_field_for_field`,
  `proxy_lifecycle_routing_and_history_persist_and_keep_operating`):
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
  `proxy.set_min_decimals.update_repins_entry_ttl`, `proxy.set_min_decimals.extends_instance_ttl`.
- `network_max_variable` (5) — `spec/06` C.3: the network maximum is unbounded and
  `round_ttl` is the constant, so the public interface cannot vary the TTL; the same ledgers
  and TTLs are replayed against `data_feeds::window` in
  `cache_retention_window_shrinks_immediately_when_the_ttl_drops` and
  `cache_retention_window_grows_exactly_at_grow_at_ledger` (plus the other
  `cache_retention_*` helper tests), and masking through the public interface is covered by
  `cache_retention_non_tip_round_outside_the_window_is_masked_on_every_read`:
  `cache.get_round.explicit_id_reads_share_the_lookback_window`,
  `cache.round_range.window_shrinks_immediately_when_the_ttl_drops`,
  `cache.round_range.window_grows_at_grow_at_ledger`,
  `cache.find_round.window_shrinks_immediately_when_the_ttl_drops`,
  `cache.find_round.window_grows_at_grow_at_ledger`.
- `in_contract_upgrade` (6) — `spec/06` I.2/I.4: Aptos package upgrade is external; no
  `upgrade` entry point. The resurrection / persistence / cache-swap conditions run without
  the upgrade step (`cache_set_feed_configs_stale_feed_state_resurrects_across_remove_and_re_add`,
  `cache_lifecycle_all_feed_state_persists_field_for_field`,
  `proxy_lifecycle_routing_and_history_persist_and_keep_operating`, and the applicable
  `proxy.lifecycle.cache_is_swappable`), and the absence of `upgrade` is a named test with a
  comment (`cache_lifecycle_no_upgrade_entry_point_exists`,
  `proxy_lifecycle_no_upgrade_entry_point_exists`) per M.4:
  `cache.set_feed_configs.stale_feed_state_resurrects_across_remove_upgrade_and_re_add`,
  `cache.lifecycle.upgrade_is_wired`,
  `cache.lifecycle.all_persistent_and_temporary_feed_state_survives_upgrade`,
  `proxy.lifecycle.upgrade_is_wired`, `proxy.lifecycle.proxy_is_upgradable`,
  `proxy.lifecycle.cache_is_upgradable`.
- `per_arg_auth` (1) — `spec/06` A.2: the sender is the transaction signer; a missing signer
  is rejected before Move runs. The A.2 guarantee (a non-permitted caller is soft-skipped with
  its own identity) is covered by `cache.on_report.wrong_owner_or_name_or_sender_does_not_record`
  and `cache.on_report.unconfigured_feed_soft_skips_with_event_and_writes_nothing`:
  `cache.on_report.sender_without_auth_host_fails`.

### Translation techniques for the 145 applicable scenarios

- Tests are generated mechanically from `spec/scenarios.json` (one `#[test]` per scenario,
  named `<id>` with dots → underscores) into `cache/tests/cache_scenario_tests.move` (103) and
  `proxy/tests/proxy_scenario_tests.move` (50).
- **Failing calls.** Move has no try/catch, so a scenario's failing `call` is the test's
  terminal statement under `#[expected_failure(abort_code, location)]`; every non-failing step
  of the scenario (including the read assertions the corpus places *after* the failing call)
  runs before it. This is sound because no scenario has a state-changing step after a failing
  call (verified over the corpus) and the VM rolls an aborting call back atomically (M.4).
  The six scenarios with more than one failing call keep the first as the named test and get
  one companion test per further failing call, named `<id>__alt2`, `__alt3`, …:
  `cache.set_feed_frozen.a_feed_without_state_aborts_the_whole_batch` (1),
  `proxy.precision.unset_min_locks_reads_to_full_precision` (1),
  `proxy.precision.below_the_configured_min_is_rejected` (1),
  `proxy.precision.above_cache_precision_is_rejected` (1),
  `proxy.precision.configured_min_without_data_is_no_data_present` (1),
  `proxy.cache_reader_client.every_read_on_an_unconfigured_feed_is_no_data_present` (3).
- **Expectation mapping.** `{error: n}` → `abort_code = n` in `data_feeds::cache` /
  `data_feeds_proxy::proxy`; `{host_fail}` → `0x50001` in `data_feeds::ownable`;
  `{decode_fail}` → `100` in `data_feeds::cache` (the overlay's strict decoder returns
  `MalformedReport`); `{cache_error: 109}` → `109` in `data_feeds_proxy::proxy`.
- **`fail_with` / `{cache_error: 100}`** (`proxy.latest_round.cache_error_traps_the_read`):
  the production Cache has no forced-error hook and no reader raises 100, so — as the overlay
  prescribes — the Proxy is pointed (`set_cache`) at an address holding no Cache instance and
  the test asserts the Cache's own abort propagating unchanged through the Proxy
  (`0x60001`, location `data_feeds::cache`). The exact code 100 of the scenario is not
  expressible on Aptos; the asserted property is "a Cache abort surfaces with the Cache's code
  and location".
- **Events.** `event::emitted_events<T>()` accumulates over a test, so every `expect_events`
  snapshots per-type counts (`test_event_counts`) before the call and asserts the delta:
  `only` → the delta vector equals exactly the listed per-type counts; `count: n` → the delta
  sum is `n`; each listed event with fields is asserted to be among the events of its type
  emitted by that call. `ordered: true` (used once, `FeedConfigRemoved` then `FeedConfigSet`)
  cannot be asserted across types — Move's test API exposes no cross-type event stream — so
  both events are asserted for the call and the code emits them in spec order.
- **`advance {to: n}`** is a no-op when the sequence already equals `n` (the `seed` macro
  revisits 101 when two feeds are seeded with `n: 1`); a lower `n` is an error.
- **Mock Cache** = a real Cache instance (`test_utils::deploy_mock_cache`) whose `owner` is
  admin and whose `id:1` is configured with description `"MOCK"` (so `decimals` → 18 and
  `description` → "MOCK"; every mock scenario uses `id:1`). `rounds` → `test_inject_round`
  (creates the state with that round as tip if absent), `latest` → `test_set_latest`,
  `frozen` → `test_set_frozen` (creates a state with a zero tip if absent — test-only),
  mock rounds carry `ledger_seq 1000`, `primary true`.
- **`expect_error_codes`** is a runtime assertion over `cache::test_error_codes()` /
  `proxy::test_error_codes()` (spec order), `ownable::test_owner_error_codes()` (2100–2102,
  checked against the scenario's `ownership_range` [2100, 2199]) and
  `ownable::test_pending_error_codes()` (2200–2203, checked against [2100, 2299]); disjointness
  is asserted against both.
- **Token** for `recover_tokens`: `primary_fungible_store::create_primary_store_enabled_fungible_asset`
  with unlimited supply on a named object of `@0xF1` (the framework's
  `init_test_metadata_with_primary_store_enabled` caps supply at 100, below the 1000 the
  scenarios mint); `mint` = `primary_fungible_store::mint`, balances via
  `primary_fungible_store::balance`.
- **`expect_state` `MinDecimals`** uses `proxy::test_has_min_decimals`.
- `version` / `type_and_version` scenarios deploy an instance the calls never use (they take
  no instance address); the binding is `_c` / `_p`.

### Additional tests from `spec/05` not in the corpus (48 Cache + 24 Proxy)

`cache/tests/cache_extra_tests.move`, `proxy/tests/proxy_extra_tests.move`: ownership codes
2100/2101/2200/2201/2202/2203 and the ownership events; `live_until_ledger == now` accepted;
offer replacement; host failures (`0x50001` wrong signer for transfer/accept/renounce/
recover_tokens, `0x60001` missing instance before auth, `0x10001` unknown bound / mis-sized
ids with their check order, `0x80001` duplicate `(creator, seed)`, token failures `0x10004`
in `aptos_framework::fungible_asset` and `0x60002` in `aptos_framework::object`); strict
decoder cases (truncation, non-minimal ULEB128, length above u32, metadata checked before the
body, mis-sized id soft-skipped, cid/report_id ignored); permission-hash construction; the
retention constant; the window helper conditions of `spec/05` (switch exactly at
`grow_at_ledger`, shrink immediately, grow at the expected ledger, second change replaces the
plan, same-ledger writes share the window, raised TTL reaches only new rounds, lowered TTL
reaches new rounds immediately, write after the grow date locks in the grown width,
saturation); masking through the public interface for `get_round`/`round_range`/`find_round`
and through the Proxy; Proxy frozen-before-data ordering, `get_min_decimals` ignoring the
frozen flag, `set_min_decimals(18)` writing the entry, scaling extremes (I256 max/min, −1).
The "network maximum below the minimum entry lifetime" condition does not apply (C.3).
