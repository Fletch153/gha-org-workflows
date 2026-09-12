# Chainlink Data Feeds on Aptos — `DataFeedsCache` + `DataFeedsProxy`

Move 2 implementation of the Data Feeds contract pair from the chain-agnostic behavioural
spec (`spec/01`–`07` of the `chainlink-data-feeds` skill) instantiated for Aptos by
`chains/aptos.md`. Two deployables: the **Cache** package (source of truth: feed
configuration, round history, feed state) and the **Proxy** package (consumer-facing reader
with precision scaling, per-feed minimum precision and the frozen-feed guard).

## Layout

```
aptos-4/
├── README.md                       this file
├── DECISIONS.md                    decision log (SKILL.md step 6)
├── cache/                          package DataFeedsCache, named address `data_feeds`
│   ├── Move.toml
│   ├── sources/
│   │   ├── host_error.move         host-failure abort codes (0x50001 / 0x60001 / 0x10001)
│   │   ├── ledger.move             sequence unit: chain timestamp in seconds, u32
│   │   ├── ownable.move            two-step ownership with expiring offer (spec/06 J)
│   │   ├── window.move             retention window arithmetic (spec/04)
│   │   ├── cache.move              DataFeedsCache (spec/02, spec/04)
│   │   ├── test_utils.move         #[test_only] shared harness (also used by proxy tests)
│   │   └── scripts/
│   │       └── set_feed_configs_script.move   example transaction script (spec/06 M.1)
│   └── tests/                      one test per applicable scenario + spec/05 extras
│       ├── config_tests.move       set_feed_configs, remove_feed_configs, admins, permission reads
│       ├── frozen_tests.move       set_feed_frozen
│       ├── lifecycle_tests.move    constructor, invariants, lifecycle, ownership table
│       ├── reader_tests.move       latest_round, get_round, round_range, find_round, decimals,
│       │                           description, is_configured, is_frozen, retention
│       ├── on_report_tests.move    on_report, decoder strictness
│       └── window_tests.move       window helper, permission hash, host-level width checks
└── proxy/                          package DataFeedsProxy, named address `data_feeds_proxy`
    ├── Move.toml                   depends on ../cache
    ├── sources/proxy.move          DataFeedsProxy (spec/03)
    └── tests/proxy_tests.move      one test per applicable proxy scenario + extras
```

The shared library modules (`host_error`, `ledger`, `ownable`, `window`) live in the Cache
package so there are exactly two deployables.

## Toolchain

- Aptos CLI `7.6.0` (`~/.aptos/bin`), Move 2 compiler. Framework pinned to aptos-core git
  tag `aptos-cli-v7.6.0`, subdir `aptos-move/framework/aptos-framework`; sources are cached
  under `~/.move/`, so pass `--skip-fetch-latest-git-deps` to build offline.
- Dev addresses: `data_feeds = 0x1000`, `data_feeds_proxy = 0x2000`.

## Build

```sh
export PATH=$HOME/.aptos/bin:$PATH
cd cache && aptos move compile --dev --save-metadata --skip-fetch-latest-git-deps
cd ../proxy && aptos move compile --dev --save-metadata --skip-fetch-latest-git-deps
```

Artifacts:

- `cache/build/DataFeedsCache/bytecode_modules/{cache,ownable,window,ledger,host_error}.mv`
  + `cache/build/DataFeedsCache/package-metadata.bcs`
  (+ `bytecode_scripts/set_one_feed_config.mv`, the example script)
- `proxy/build/DataFeedsProxy/bytecode_modules/proxy.mv`
  + `proxy/build/DataFeedsProxy/package-metadata.bcs`

For a real deployment replace `--dev` with
`--named-addresses data_feeds=<addr>` (Cache) and
`--named-addresses data_feeds=<addr>,data_feeds_proxy=<addr>` (Proxy), and publish with
`aptos move publish --upgrade-policy compatible` from the publisher account (package
upgrades are the publisher's — i.e. the owner's — responsibility; there is no in-contract
`upgrade`, spec/06 I.2).

## Test

```sh
cd cache && aptos move test --dev --skip-fetch-latest-git-deps   # 149 tests
cd ../proxy && aptos move test --dev --skip-fetch-latest-git-deps # 60 tests
```

Tests are named by the full scenario id of `spec/scenarios.json` with dots replaced by
underscores (e.g. `cache_on_report_equal_or_older_timestamp_is_stale_and_emits_event`);
scenarios with several failing calls have `__alt2…` companions. All 147 applicable
scenarios are implemented; the 34 inapplicable ones (`expiry`, `network_max_variable`,
`in_contract_upgrade`, `per_arg_auth`) are listed in `DECISIONS.md`.

## Instance model

A "contract" is module code plus an **instance object** (spec/06 L.2). `create` makes a named
object at `object::create_object_address(&creator, seed)` holding the `Cache` / `Proxy`
resource; every other function takes the instance address as its first non-signer argument.
Spec ownership lives in the resource (`ownable::OwnershipState`), not in `ObjectCore`.

## ABI

Named address `data_feeds`, module `cache` (Cache) and named address `data_feeds_proxy`,
module `proxy` (Proxy). `E` = `public entry fun`, `P` = `public fun` (non-entry), `V` =
`#[view] public fun`. Caller identity is the `&signer` (spec/06 A.2), so the spec's
`sender`/`admin` principal arguments are the signer. Byte types: `data_id` 32 bytes,
`workflow_owner` 20, `workflow_name` 10, all `vector<u8>`; `answer` is `u256` holding the
two's-complement I256 bit pattern; `Bound` is `u8` (`0` AtOrBefore, `1` AtOrAfter).

### `data_feeds::cache`

| Kind | Function | Notes |
|---|---|---|
| E | `create(creator: &signer, seed: vector<u8>, owner: address)` | constructor; instance at `create_object_address(creator, seed)` |
| V | `version(): u32` | `1` |
| V | `type_and_version(): String` | `"DataFeedsCache 1.0.0"` |
| V | `get_owner(cache: address): Option<address>` | |
| E | `transfer_ownership(owner: &signer, cache: address, new_owner: address, live_until_ledger: u32)` | `live_until_ledger = 0` cancels |
| E | `accept_ownership(new_owner: &signer, cache: address)` | |
| E | `renounce_ownership(owner: &signer, cache: address)` | |
| E | `recover_tokens(owner: &signer, cache: address, token: address, to: address, amount: u64)` | `token` = fungible-asset `Metadata` object address |
| V | `latest_round(cache, data_ids: vector<vector<u8>>): vector<Option<RoundData>>` | |
| V | `decimals(cache, data_ids): vector<Option<u32>>` | `18` iff configured |
| V | `description(cache, data_ids): vector<Option<String>>` | |
| V | `is_configured(cache, data_ids): vector<bool>` | |
| V | `is_frozen(cache, data_ids): vector<bool>` | |
| V | `get_round(cache, data_id: vector<u8>, round_id: u64): Option<RoundData>` | |
| V | `round_range(cache, data_id, from: u64, to: u64): vector<RoundData>` | |
| V | `find_round(cache, data_id, timestamp: u64, bound: u8): Option<RoundData>` | unknown `bound` → `0x10001` |
| E | `on_report(sender: &signer, cache: address, metadata: vector<u8>, report: vector<u8>)` | `metadata` 64 raw bytes; `report` = BCS `vector<ReportEntry>` |
| P | `set_feed_configs(admin: &signer, cache: address, entries: vector<FeedConfigEntry>)` | reached from a transaction script (see `sources/scripts/`) |
| E | `remove_feed_configs(admin: &signer, cache: address, data_ids: vector<vector<u8>>)` | |
| E | `set_feed_frozen(admin: &signer, cache: address, data_ids: vector<vector<u8>>, frozen: bool)` | |
| E | `add_feed_admin(owner: &signer, cache: address, new_admin: address)` | |
| E | `remove_feed_admin(owner: &signer, cache: address, admin: address)` | |
| V | `get_feed_permissions(cache, data_id): vector<WorkflowPermission>` | |
| V | `has_permission(cache, data_id, sender: address, workflow_owner: vector<u8>, workflow_name: vector<u8>): bool` | |
| V | `is_feed_admin(cache, admin: address): bool` | |
| P | `new_workflow_permission(allowed_sender, allowed_workflow_owner, allowed_workflow_name)`, `new_feed_config(description, workflow_permissions)`, `new_feed_config_entry(data_id, config)`, `new_report_entry(data_id, answer, timestamp)` | record constructors |
| P | `round_data_{round_id,answer,timestamp,ledger_seq,primary}`, `workflow_permission_{allowed_sender,allowed_workflow_owner,allowed_workflow_name}`, `feed_config_{description,workflow_permissions}`, `feed_config_entry_{data_id,config}`, `report_entry_{data_id,answer,timestamp}` | record accessors |

Records (field order is the BCS/view ABI): `RoundData { round_id: u64, answer: u256,
timestamp: u64, ledger_seq: u32, primary: bool }`, `WorkflowPermission { allowed_sender:
address, allowed_workflow_owner: vector<u8>, allowed_workflow_name: vector<u8> }`,
`FeedConfig { description: String, workflow_permissions: vector<WorkflowPermission> }`,
`FeedConfigEntry { data_id: vector<u8>, config: FeedConfig }`, `ReportEntry { data_id:
vector<u8>, answer: u256, timestamp: u64 }`.

Events (`#[event]` structs, fields in spec order): `FeedUpdated { data_id, round_id,
timestamp, answer, ledger_seq, primary }`, `StaleReport { data_id, report_ts, stored_ts }`,
`InvalidUpdatePermission { data_id, sender, workflow_owner, workflow_name }`,
`FeedConfigSet { data_id, decimals, description, workflow_permissions }`,
`FeedConfigRemoved { data_id }`, `FeedFrozenSet { data_id, frozen }`, `FeedAdminAdded
{ admin }`, `FeedAdminRemoved { admin }`, `TokenRecovered { token, to, amount }`; ownership
events in `data_feeds::ownable`: `OwnershipTransfer { old_owner, new_owner,
live_until_ledger }`, `OwnershipTransferCompleted { new_owner }`, `OwnershipRenounced
{ old_owner }`.

Errors (abort codes, location `data_feeds::cache`): `MalformedReport 100`,
`UnauthorizedCaller 101`, `FeedNotConfigured 102`, `EmptyConfig 103`, `InvalidAddress 104`,
`InvalidWorkflowName 105`, `DuplicatePermission 106`, `InvalidDataId 107`,
`DuplicateFeedConfig 108`, `FeedFrozen 109` (raised by the Proxy), `NoFeedState 110`.
Ownership (location `data_feeds::ownable`): `OwnerNotSet 2100`, `TransferInProgress 2101`,
`OwnerAlreadySet 2102`, `NoPendingTransfer 2200`, `InvalidLiveUntilLedger 2201`,
`InvalidPendingAccount 2202`, `TransferExpired 2203`. Host failures
(`data_feeds::host_error`): `unauthorized 0x50001` (in `ownable`), `no_instance 0x60001`,
`invalid_argument 0x10001` (in the called module).

### `data_feeds_proxy::proxy`

| Kind | Function | Notes |
|---|---|---|
| E | `create(creator: &signer, seed: vector<u8>, owner: address, cache: address)` | constructor |
| V | `version(): u32` / `type_and_version(): String` | `1` / `"DataFeedsProxy 1.0.0"` |
| V | `get_owner(proxy: address): Option<address>` | |
| E | `transfer_ownership(owner: &signer, proxy, new_owner, live_until_ledger: u32)` / `accept_ownership(new_owner: &signer, proxy)` / `renounce_ownership(owner: &signer, proxy)` | |
| E | `recover_tokens(owner: &signer, proxy, token, to, amount: u64)` | |
| V | `latest_round(proxy, data_id, decimals: u32): Round` | 50 / 51 / 52 / 109 |
| V | `get_round(proxy, data_id, round_id: u64, decimals: u32): Round` | |
| V | `decimals(proxy, data_id): u32` | |
| V | `description(proxy, data_id): String` | |
| V | `get_min_decimals(proxy, data_id): u32` | `18` when unset |
| V | `get_cache(proxy): address` | |
| E | `set_cache(owner: &signer, proxy, cache: address)` | emits `CacheSet { old_cache, new_cache }` |
| E | `set_min_decimals(owner: &signer, proxy, data_id, min: u32)` | emits `MinDecimalsSet { data_id, min }` |
| P | `round_{round_id,answer,timestamp}` | accessors of `Round { round_id: u64, answer: u256, timestamp: u64 }` |

Errors (location `data_feeds_proxy::proxy`): `NoDataPresent 50`, `InvalidDecimals 51`,
`RoundsToZero 52`, `FeedFrozen 109`. Cache aborts propagate unchanged (code and location).

## Storage layout (upgrade / migration reference)

`Cache { extend_ref: ExtendRef, ownership: OwnershipState, feed_admins: Table<address,
bool>, feed_configs: Table<vector<u8>, FeedConfig>, permissions: Table<PermissionKey
{ data_id, phash }, bool>, feed_states: Table<vector<u8>, FeedState { latest_round, window,
frozen }>, rounds: Table<RoundKey { data_id, round_id }, RoundData> }`;
`Proxy { extend_ref, ownership, cache: address, min_decimals: Table<vector<u8>, u32> }`;
`OwnershipState { owner: Option<address>, pending: Option<PendingTransfer { new_owner,
live_until_ledger: u32 }> }`; `Window { shortest_ttl, grow_to_ttl, grow_at_ledger }`.

## Retention

Sequence unit = chain timestamp in seconds (u32); `DATA_RETENTION_TTL = 15_552_000`
(180 days). Aptos has no entry expiry, so rounds are never deleted; a non-tip round is
readable iff `ledger_seq >= now - window width` (spec/04), the tip always.
