# Chain overlay — Aptos (Move 2 / Aptos CLI)

Instantiation of `spec/06` for Aptos. Mechanics only; behaviour is in `spec/`.

## Platform facts (per `spec/06` axis)

- **capabilities:** `[external_upgrade]`

- **A. Account model** — case A.2: the caller identity is the `&signer` parameter of the
  entry point (`signer::address_of`). `sender` (on `on_report`) and `admin` (on
  `set_feed_configs`, `remove_feed_configs`, `set_feed_frozen`) are dropped from the
  argument list; the `&signer` takes their position and role name (`sender: &signer`,
  `admin: &signer`, `owner: &signer`, `new_owner: &signer` on `accept_ownership`). Lookup
  keys (`has_permission`'s `sender`, `is_feed_admin`'s `admin`, `remove_feed_admin`'s
  `admin`) stay as `address`. A missing signer is rejected by the transaction layer before
  Move code runs (so the `05` condition "sender without host authorisation fails" has no
  Move-level test). Host failures inside Move code (the signer is not the recorded owner /
  pending owner, no instance at the address, a mis-sized byte argument, an unknown `Bound`
  discriminant) abort with the dedicated codes of module `data_feeds::host_error`, all
  outside every spec range: `unauthorized() = error::permission_denied(1) = 0x50001`,
  `no_instance() = error::not_found(1) = 0x60001`, `invalid_argument() =
  error::invalid_argument(1) = 0x10001`. The abort location is the module that aborts
  (owner / pending-owner checks abort in `data_feeds::ownable`). A token failure in
  `recover_tokens` is the framework's own abort (`aptos_framework::fungible_asset` /
  `object` codes).
  Every entry point and every view first asserts that the `Cache` / `Proxy` resource exists
  at the instance address (`host_error::no_instance()`, aborting in the called module) before
  any signer/owner check, byte-width check or spec check; a call on a missing instance never
  surfaces a spec error code.
- **B. Storage** — a contract **instance** is an Aptos object (`aptos_framework::object`)
  holding one resource: `data_feeds::cache::Cache` for the Cache, `data_feeds_proxy::proxy::Proxy`
  for the Proxy. Instance singletons (owner, pending offer, `ExtendRef`, the Proxy's `cache`
  address) are fields of that resource. Every keyed record is an entry of an
  `aptos_std::table::Table` inside the resource (one storage slot per entry), keyed by the
  spec key: `feed_admins: Table<address, bool>` (`FeedAdmin`), `feed_configs: Table<vector<u8>, FeedConfig>`
  (`FeedConfig(data_id)`), `permissions: Table<PermissionKey{data_id, phash}, bool>`
  (`Permission(data_id, permission_hash)`), `feed_states: Table<vector<u8>, FeedState>`,
  `rounds: Table<RoundKey{data_id, round_id}, RoundData>`; Proxy `min_decimals:
  Table<vector<u8>, u32>` (`MinDecimals(data_id)`). Presence = `table::contains`; unit
  records store `true`. Storage is paid by the transaction's gas payer (storage fee); no
  explicit payer argument. Records are variable-size Move values; no resize rules. Layout
  (resource/table shapes): `Cache { extend_ref, ownership: OwnershipState, feed_admins,
  feed_configs, permissions, feed_states, rounds }`, `Proxy { extend_ref, ownership, cache,
  min_decimals }`, `FeedState { latest_round: RoundData, window: Window, frozen: bool }`,
  `Window { shortest_ttl: u32, grow_to_ttl: u32, grow_at_ledger: u32 }`,
  `OwnershipState { owner: Option<address>, pending: Option<PendingTransfer{new_owner,
  live_until_ledger: u32}> }`.
  Instance address: `object::create_object_address(&creator, seed)` (named object; the
  constructor takes `creator: &signer, seed: vector<u8>`). The object's `ObjectCore.owner`
  is the creator (named-object semantics) and is **not** tracked afterwards; the spec's
  ownership lives in the resource. Creating a second instance with the same `(creator,
  seed)` fails with the framework's `object::EOBJECT_EXISTS` abort.
- **C. Expiry** — case C.3 (none): every pin/refresh is a no-op, `round_ttl =
  DATA_RETENTION_TTL = 15_552_000`, rounds are never deleted, no reclaim; Cache readers and
  Proxy readers are pure. Sequence unit: the chain timestamp in **seconds**,
  `aptos_framework::timestamp::now_seconds()` truncated to `u32` (`(x & 0xFFFF_FFFF) as u32`)
  — read through `data_feeds::ledger::sequence()`. Block height
  (`block::get_current_block_height`) is not used: Move unit tests cannot advance it (only
  `emit_writeset_block_event`, +1 per VM-signed call), and the framework's own Move code uses
  the timestamp as its clock. `ledger_seq` and `live_until_ledger` are therefore in truncated
  seconds.
- **D. Limits** — no per-module code limit that matters (package publish limit ~64 KiB per
  transaction, `code::publish_package_txn` chunking available); transaction gas bounds batch
  size and history reads (`round_range`, `find_round`) — a batch that exceeds gas aborts as
  a whole with the VM's out-of-gas failure. No record declaration convention (`find_round`
  has no `lo`/`hi`). Entry functions accept only primitive / `vector` / `String` / `Option` /
  `address` / `&signer` arguments and return nothing; view functions return any value.
- **E. Errors** — `abort <code>` with the exact spec number as the u64 abort code; names are
  module constants with the spec spelling (`const MalformedReport: u64 = 100;`; constants are
  module-private, hence not ABI). Cache codes abort in `data_feeds::cache`, Proxy codes
  (50–52 and the Proxy-raised `FeedFrozen = 109`) in `data_feeds_proxy::proxy`, ownership
  codes 2100–2299 in `data_feeds::ownable`. Host failures use `data_feeds::host_error` codes
  (axis A). A callee's abort propagates unchanged (code and location) through the caller.
- **F. Serialisation** — BCS (`std::bcs::to_bytes`). `encode(x)` for the permission hash:
  `bcs(address)` (32 bytes) ‖ `bcs(vector<u8> owner)` (ULEB128 length 20 + 20 bytes) ‖
  `bcs(vector<u8> name)` (ULEB128 length 10 + 10 bytes), hashed with
  `aptos_std::aptos_hash::keccak256`. Report body: BCS of `vector<ReportEntry>` where
  `ReportEntry { data_id: vector<u8>, answer: u256, timestamp: u64 }` (ULEB128 count; per
  entry ULEB128 length + id bytes, 32-byte little-endian answer, 8-byte little-endian
  timestamp). The contract decodes it with its own strict decoder (Move has no generic BCS
  deserialiser for structs — `from_bcs::from_bytes` is friend-only): non-minimal ULEB128,
  a length above u32, truncation, or trailing bytes → `MalformedReport` (100). The decoder
  does not check id widths (a mis-sized id decodes and is soft-skipped as an unknown feed).
  Metadata is the raw 64-byte layout.
- **G. Optionals** — `std::option::Option<T>`. `get_owner` returns `Option<address>`.
  Readers that never fail return the bare value (no `Result`).
- **H. Events** — `#[event] struct <Name> has copy, drop, store` + `aptos_framework::event::emit`.
  No indexing: fields in spec order, topic fields first. Event names are struct names, so the
  snake_case ownership events become `OwnershipTransfer`, `OwnershipTransferCompleted`,
  `OwnershipRenounced` (axis K). Each contract defines its own `TokenRecovered { token:
  address, to: address, amount: u64 }`. Ownership events are defined in `data_feeds::ownable`.
- **I. Upgrade** — case I.2: Move package upgrade (`aptos move publish --upgrade-policy
  compatible` / `object_code_deployment::upgrade`) is driven by the package publisher's
  account, outside the contract. No `upgrade`/`Upgraded`. The publisher key is the owner's
  responsibility. Storage layout is the resource/table shape under axis B.
- **J. Ownership** — no library: `data_feeds::ownable` implements the `spec/06` J table on
  an `OwnershipState` value (`store` only) embedded in each instance resource; its functions
  take `&mut OwnershipState`, the caller address and `now`, so the library cannot be invoked
  on an instance from outside the contract module. `live_until_ledger` is in the axis-C
  unit. Aptos has no maximum offer horizon (J's "where one exists" clause is empty).
- **K. Naming** — spec spelling for functions, arguments, struct/field names, error
  constants (snake_case / UpperCamelCase are native). One mechanical transformation: event
  struct names are UpperCamelCase (affects only the three ownership events). Token amount
  `u64` (fungible-asset amount); `token` is the `Metadata` object address and the transfer
  is `primary_fungible_store::transfer` signed via the instance's `ExtendRef`. `Address` =
  `address`; `workflow_owner` = `vector<u8>` of length 20. `u32` values stay `u32`.
  `answer: I256` = `u256` holding the two's-complement bit pattern (BCS: 32 bytes LE).
  `Bound` is a `u8` discriminant on the interface (`AtOrBefore = 0`, `AtOrAfter = 1`; any
  other value → `host_error::invalid_argument()`), because entry/view functions cannot take
  enums. `find_round` validates the discriminant right after the instance check and before
  the feed-state lookup, so an unknown bound aborts even for a feed without state (instead of
  answering `None`). `recover_tokens`: `TokenRecovered` is emitted after
  `primary_fungible_store::transfer` returns; the destination's primary store is created by
  the framework when absent; an amount above the instance's balance aborts with
  `fungible_asset::EINSUFFICIENT_BALANCE` (`0x10004`, location
  `aptos_framework::fungible_asset`); a `token` address holding no `Metadata` object aborts in
  `aptos_framework::object`; the contract adds no check of its own.
- **L. Cross-contract** — the Proxy calls `data_feeds::cache` functions directly
  (`cache::is_frozen(cache, vector[data_id])`, `cache::latest_round`, `cache::get_round`,
  `cache::decimals`, `cache::description`), passing the stored instance address. Aborts
  propagate unchanged. The Proxy package depends on the Cache package.

## Toolchain

- Aptos CLI `7.6.0` at `~/.aptos/bin` (add to `PATH`); Move 2 compiler (`aptos move
  compile` / `test`). Framework dependency pinned to the aptos-core git tag `aptos-cli-v7.6.0`
  with `subdir = "aptos-move/framework/aptos-framework"` (the `mainnet` rev of
  `aptos-framework` does not parse with this CLI). Sources are cached under `~/.move/`; pass
  `--skip-fetch-latest-git-deps` to build offline.
- Tests: `aptos move test --dev --skip-fetch-latest-git-deps` in each package. `--dev`
  applies `[dev-addresses]`. Dependency packages' `#[test_only]` functions are available to a
  dependent package's tests (the Proxy tests use the Cache's `#[test_only]` injectors).
  Pitfalls: a failing assertion aborts the whole test (no try/catch), so atomicity after an
  abort cannot be observed — assert the abort code with `#[expected_failure(abort_code = N,
  location = <module>)]`; `event::emitted_events<T>()` accumulates over the whole test;
  `timestamp::update_global_time_for_test_secs` only moves forward; a `///` doc comment
  placed before a `#[test_only]` attribute is a warning (put it after the attribute).

## Layout and commands

- Two packages at `out_dir`: `cache/` (package `DataFeedsCache`, named address `data_feeds`;
  modules `host_error`, `ledger`, `ownable`, `window`, `cache`, plus `#[test_only]`
  `test_utils` in `cache/sources/` so the Proxy tests can reuse it) and `proxy/` (package
  `DataFeedsProxy`, named address `data_feeds_proxy`; module `proxy`; depends on
  `DataFeedsCache` via `local = "../cache"`). The shared library modules live in the Cache
  package so there are exactly two deployables. Dev addresses: `data_feeds = 0x1000`,
  `data_feeds_proxy = 0x2000`. Tests live under each package's `tests/`.
- Build: `aptos move compile --dev --save-metadata --skip-fetch-latest-git-deps` in each
  package → `build/DataFeedsCache/bytecode_modules/{cache,ownable,window,ledger,host_error}.mv`
  and `build/DataFeedsProxy/bytecode_modules/proxy.mv` (+ `package-metadata.bcs`). For a
  real deployment replace `--dev` with `--named-addresses data_feeds=<addr>[,data_feeds_proxy=<addr>]`.
- Tests: `aptos move test --dev --skip-fetch-latest-git-deps` in each package.

## Type vocabulary

| Spec | Aptos |
|---|---|
| `data_id`, `workflow_cid`, hashes (32 bytes) | `vector<u8>` (length 32) |
| `workflow_owner` (20 bytes) | `vector<u8>` (length 20) |
| `workflow_name` (10 bytes) | `vector<u8>` (length 10) |
| `report_id` (2 bytes) | `vector<u8>` (length 2) |
| `answer` (I256) | `u256`, two's-complement bit pattern |
| `String` | `std::string::String` |
| `List<T>` | `vector<T>` |
| `Bytes` | `vector<u8>` |
| `Address` | `address` |
| records | `struct ... has copy, drop, store` with spec field names in spec order (BCS order and view-JSON names are ABI); fields are read from other modules through accessor functions `<struct_snake>_<field>` (`round_data_round_id/answer/timestamp/ledger_seq/primary`, `workflow_permission_allowed_sender/allowed_workflow_owner/allowed_workflow_name`, `feed_config_description/workflow_permissions`, Proxy `round_round_id/answer/timestamp`, and for the batch-element records `feed_config_entry_data_id/config`, `report_entry_data_id/answer/timestamp`) and built with `new_<struct_snake>(...)` constructors (`new_workflow_permission`, `new_feed_config`, `new_feed_config_entry`, `new_report_entry`) |
| `Bound` | `u8` (`0` / `1`) |
| events | `#[event]` structs |

## Interface encoding and account conventions (part of the ABI)

Entry points are module functions addressed by name. Beyond the spec arguments each
function takes, in this order: the `&signer` (state-changing functions only; see axis A),
then the **instance address** (`cache: address` / `proxy: address`) as first non-signer
argument, then the spec arguments. `version()` and `type_and_version()` take nothing.
Constructors: `cache::create(creator: &signer, seed: vector<u8>, owner: address)` and
`proxy::create(creator: &signer, seed: vector<u8>, owner: address, cache: address)`, both
`public entry`; the instance address is `object::create_object_address(&signer::address_of(creator), seed)`.

Visibility: every reader is `#[view] public fun`; every state-changing function is
`public entry fun` except `set_feed_configs(admin: &signer, cache: address, entries:
vector<FeedConfigEntry>)`, which is `public fun` (struct arguments cannot be entry
arguments; entry functions cannot return values) and is reached from a transaction through
a Move script that builds the entries with `new_workflow_permission`, `new_feed_config`,
`new_feed_config_entry`. No flattened entry variant exists.

Byte-width checks (`spec/06` D.2 analogue, host errors): `set_feed_configs` checks each
entry's `data_id` (32) and each permission's owner (20) / name (10) at the point the entry
is validated — after the `UnauthorizedCaller` (101) and empty-batch (103) checks, before
that entry's spec checks; `set_min_decimals` checks `data_id` (32) after owner auth and
before `InvalidDecimals`. Within one entry, *all* of its width checks (the `data_id`, then every permission's
owner and name in order) run before *any* of that entry's spec checks, so a mis-sized owner in
a later permission aborts with `host_error::invalid_argument()` even when an earlier permission
would fail a spec check; entries are still validated in order, so a spec error in entry 1
precedes a width error in entry 2. Lookup-only arguments are not checked (a mis-sized id is simply an
unknown feed). The report decoder does not check id widths.

## Testing notes

- Signers: `#[test(fw = @aptos_framework, owner = @0xA1, ...)]` parameters; call
  `timestamp::set_time_has_started_for_testing(fw)` first, move the sequence with
  `timestamp::update_global_time_for_test_secs(n)` (strictly increasing).
- Failures: `#[expected_failure(abort_code = 101, location = data_feeds::cache)]`; host
  failures use the `host_error` codes (`0x50001`, `0x60001`, `0x10001`) with the aborting
  module as location (owner/pending-owner checks abort in `data_feeds::ownable`).
- Events: struct literals are module-private, so each module exposes `#[test_only]` event
  constructors (`feed_updated_event(..)`, `ownership_transfer_event(..)`, …); assert with
  `event::was_event_emitted(&e)` and count `event::emitted_events<T>()` for "only"
  conditions.
- Mock Cache for Proxy unit tests: the Cache module's `#[test_only]` injectors
  `test_inject_round`, `test_set_latest` (sets `FeedState.latest_round` without touching the
  round table), `test_new_round_data`, `test_set_frozen` (creates a zero-tip state if absent),
  `test_expire_round`, and per-type `test_event_counts` for event deltas (direct table writes, no
  business logic), plus `test_window`, `test_permission_hash`, `test_error_codes`,
  `test_data_retention_ttl`; Proxy `test_has_min_decimals`, `test_error_codes`. A Cache error
  propagating through the Proxy is exercised with a Proxy whose `cache` address holds no
  instance (`host_error::no_instance()` from `data_feeds::cache`); production readers carry
  no forced-error hook.
- Token for `recover_tokens`: `primary_fungible_store::create_primary_store_enabled_fungible_asset`
  with unlimited supply on a named object (the framework's `init_test_metadata_with_primary_store_enabled`
  caps supply at 100, below what the corpus mints), then `primary_fungible_store::mint`;
  balances via `primary_fungible_store::balance`.
- Upgrade: I.2 — resurrection / cache-swap conditions run without an upgrade step; the
  "no `upgrade` entry point" assertion is a compile-time fact (a call would not resolve) and
  is recorded by a named test with a comment.
- Retention: `round_ttl` is the constant, so window conditions that vary the TTL run against
  `data_feeds::window` directly; expiry through the public interface is emulated with
  `test_expire_round`; window masking is exercised by advancing the timestamp past
  `ledger_seq + 15_552_000`. Lifetime-refresh conditions are asserted as persistence.
- Atomicity conditions ("aborts the whole batch, nothing written") are `expected_failure`
  tests relying on VM transaction atomicity.

## Decision log

Same format as `SKILL.md` step 6. With this overlay and `spec/06` applied there should be
no `[ABI]` or `[BEHAVIOUR]` entries; any that remain are written back into this overlay by
the run that produced them (SKILL.md step 7).

## Retention constant

Sequence unit nominal duration: 1-second timestamp ticks → `DATA_RETENTION_TTL = 15_552_000` (180 days, `spec/04`).
