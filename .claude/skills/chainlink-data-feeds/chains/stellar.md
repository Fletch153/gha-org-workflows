# Chain overlay — Stellar (Soroban)


## Platform facts (per `spec/06` axis)

- **capabilities:** `[per_arg_auth, expiry, network_max_variable, in_contract_upgrade, events_indexed]`
- **A** case A.1 (`require_auth`); **B** key-value entries with tiers; **C** case C.2; **D** per-transaction
  resource limits only, no declaration convention; **E** `#[contracterror]` enums; **F** XDR;
  **G** native `Option`, readers return `Result` as in `02`; **H** topics; **I** case I.1;
  **J** `stellar-access` `ownable`; **K** spec spelling, `i128` token amounts, `BytesN<20>` owner;
  **L** generated client. Details follow.

## Toolchain and dependencies

- Rust `1.96.0`, pinned by a `rust-toolchain.toml` at the workspace root with
  `channel = "1.96.0"`, `targets = ["wasm32v1-none"]`, `components = ["rustfmt"]`.
- `soroban-sdk` exactly `26.1.0`. Tests need its `testutils` feature (dev-dependency only).
- `stellar-access` exactly `0.7.2` — provides the `ownable` module: the `Ownable`
  contract-trait (`get_owner`, `transfer_ownership`, `accept_ownership`, `renounce_ownership`,
  with the events and error codes named in `spec/01`), plus the free functions `set_owner`
  (for constructors) and `enforce_owner_auth` (owner-only gating). Use it; do not re-implement.
- All contract crates are `#![no_std]`.

## Layout and commands

A Cargo workspace (resolver 2) at `out_dir` with three members:

| Crate | Kind | Contents |
|---|---|---|
| `data-feeds-common` | `rlib` | the shared lifecycle traits `Versioned` (`version`, `type_and_version` — both implemented by each contract, no default bodies), `Upgradeable` (`upgrade`) and `TokenRecoverable` (`recover_tokens`) (these two as `#[contracttrait]`s with default bodies), their events `Upgraded` and `TokenRecovered`; a `test_utils` module gated on `cfg(any(test, feature = "testutils"))` so dependants can reuse it via the feature with a tiny mock contract that implements the traits, plus helpers reused by the other crates' tests |
| `data-feeds-cache` | `cdylib` + `rlib` | `DataFeedsCache`. Public interface split into three contract traits with generated clients: `DataFeedsCacheReader`, `DataFeedsCacheWriter`, `DataFeedsCacheAdmin`; public types `RoundData`, `Bound`, `WorkflowPermission`, `FeedConfig`, `FeedConfigEntry`, `ReportEntry`, `Metadata`, `CacheError`, the `DataId` alias (`BytesN<32>`) and the `DECIMALS` constant. Gate the contract implementation, storage, events and domain logic behind a default-on `contract` feature so the crate can be depended on for its interface alone; expose a `testutils` feature (implies `contract` + `soroban-sdk/testutils`) exporting test helpers |
| `data-feeds-proxy` | `cdylib` + `rlib` | `DataFeedsProxy`. Contract traits `DataFeedsProxyReader` and `DataFeedsProxyAdmin`; types `Round`, `ProxyReadError`. Depends on `data-feeds-cache` with `default-features = false` (interface + reader client only) so the Cache's exported functions are **not** linked into the Proxy artifact — declare `default-features = false` on the **workspace** `[workspace.dependencies]` line (Cargo ignores it on a member's `workspace = true` line); dev-depends on it with `contract` + `testutils` for integration tests |

A fourth crate is allowed **outside** the workspace members (e.g. `test-fixtures/peek-contract`,
listed under `[workspace] exclude`) for the distinct upgrade-target fixture; a `cdylib` fixture
cannot live inside the `rlib` common crate.

Dependency pin: `soroban-env-host 26.1.x` allows `ed25519-dalek 3.x`, which does not compile
with its testutils. After the first resolve run `cargo update -p ed25519-dalek --precise 2.2.0`
(if the first resolve pulled both 2.x and 3.x, address the 3.x one:
`cargo update -p ed25519-dalek@3.0.0 --precise 2.2.0`). Check in `Cargo.lock`.

Workspace lints: `unsafe_code = "deny"`. Release profile: `opt-level = "z"`,
`overflow-checks = true`, `debug = 0`, `strip = "symbols"`, `debug-assertions = false`,
`panic = "abort"`, `codegen-units = 1`, `lto = true`.

Recommended module split per contract crate: `interface/` (traits, types, errors),
`contract.rs` (entry points only), `storage.rs` (keys, tiers, TTL helpers), `events.rs`,
and for the Cache a `domain/` module (feed state machine, retention window, decoding, binary
search) that the entry points call. Keep entry points thin.

## Build and test commands

- Tests: `cargo test --workspace` (host target).
- Artifacts: build **one package per invocation** (building both in one command unifies
  features and links the Cache into the Proxy):
  `cargo build --release --target wasm32v1-none -p data-feeds-cache` and again for
  `-p data-feeds-proxy`. Output: `target/wasm32v1-none/release/<crate_name_with_underscores>.wasm`.
- `stellar-access` enables the SDK's `experimental_spec_shaking_v2` feature, whose build
  script refuses to run without the Stellar CLI. Without the CLI, export
  `SOROBAN_SDK_BUILD_SYSTEM_SUPPORTS_SPEC_SHAKING_V2=1` for the wasm build.
- Upgrade tests need wasm fixtures: (1) a distinct small contract exposing something the real
  contract lacks (a `peek` function that reads an instance-storage slot both real contracts
  write in their constructor, e.g. the ownership library's owner slot) to prove the swap; (2) a self-build of each contract. Build them with the command above and
  check them in under each crate's `test_fixtures/`, loaded via `include_bytes!`. The
  self-upgrade fixture must be rebuilt whenever the contract changes.

## Type vocabulary

| Spec | Soroban |
|---|---|
| `data_id`, `workflow_cid`, permission hash, wasm hash | `BytesN<32>` |
| `workflow_owner` | `BytesN<20>` |
| `workflow_name` | `BytesN<10>` |
| `report_id` | `BytesN<2>` |
| `answer` | `I256` |
| `String` | `soroban_sdk::String` |
| `List<T>` | `soroban_sdk::Vec<T>` |
| `Bytes` (metadata, report) | `soroban_sdk::Bytes` |
| `Address` | `soroban_sdk::Address` |
| records | `#[contracttype]` structs — serialised as a map keyed by field name, so field **names** are ABI; field order is not |
| enums (`Bound`, storage keys) | `#[contracttype]` enums — variant names and payload types are ABI |
| errors | `#[contracterror]` enums with the explicit `= code` discriminants, `#[repr(u32)]` |
| events | `#[contractevent(topics = ["<EventName>"])]` structs; spec "topic fields" carry `#[topic]`, the rest are data (default map format). Event name, topic order and field names are ABI |
| `encode(x)` for the permission hash | `x.to_xdr(env)` (`soroban_sdk::xdr::ToXdr`); concatenate the three `Bytes` and hash with `env.crypto().keccak256(..)`, converting to `BytesN<32>` |
| report decoding | `Vec<ReportEntry>::from_xdr(env, &bytes)` (`soroban_sdk::xdr::FromXdr`). Map its `Err` to `MalformedReport`. Note the host **traps** on undecodable or trailing bytes with `Error(Value, InvalidInput)` before your mapping runs — that trap is the expected observable behaviour and what tests must assert |
| metadata decoding | check `len() == 64`, then `BytesN::try_from(bytes.slice(a..b))` per field |
| current ledger | `env.ledger().sequence()` |

Constructors are named `__constructor` and take `env` first; every entry point takes `env: Env`
first. Fallible functions return `Result<_, CacheError>` / `Result<_, ProxyReadError>`; a
returned `Err` surfaces to callers as `Error(Contract, #<code>)` and rolls back the call's
storage writes and events. The Proxy's frozen check uses `panic_with_error!(env, CacheError::FeedFrozen)`.

## Authorisation

- "Host-authorise `x`" for an address argument → `x.require_auth()`.
- Owner-only → `stellar_access::ownable::enforce_owner_auth(&env)`.
- Both fail with the host error `Error(Auth, InvalidAction)`.

## Storage and lifetimes

Tiers: `env.storage().instance()`, `.persistent()`, `.temporary()`. Network maximum:
`env.storage().max_ttl()`. Refresh instance: `instance().extend_ttl(max - 1, max)` (saturating).
Pin on first write: `has()` before `set()`; if absent, `extend_ttl(&key, ttl, ttl)`. Explicit
refresh: if `has()`, `extend_ttl(&key, ttl - 1, ttl)`. Round TTL: `min(3_110_400, max_ttl())`.

Storage key enums are part of the upgrade contract — use these exact shapes:

- Cache, enum `DataKey`: `FeedAdmin(Address)`, `FeedConfig(BytesN<32>)`,
  `Permission(BytesN<32>, BytesN<32>)`, `FeedState(BytesN<32>)`, `Round(BytesN<32>, u64)`.
  `FeedState` value struct fields: `latest_round: RoundData`, `window: Window`, `frozen: bool`;
  `Window` fields: `shortest_ttl: u32`, `grow_to_ttl: u32`, `grow_at_ledger: u32`.
- Proxy, enum `DataKey`: `Cache` (instance tier), `MinDecimals(BytesN<32>)` (persistent).

## Cross-contract calls

The Proxy calls the Cache through the client the SDK generates for the `DataFeedsCacheReader`
trait (`DataFeedsCacheReaderClient` — `#[contracttrait]` generates it; do not add a second
`#[contractclient]`), invoking `is_frozen`,
`latest_round`, `get_round`, `decimals`, `description` by name with single-element `vec!`s for
the batch functions. Client calls that fail propagate the callee's error as a trap of the
Proxy call (use the plain client methods, not `try_`).

A `#[contracttrait]` with default bodies re-emits those signatures inside the implementing
contract's module, so that module must import the types they mention (`Env`, `Address`,
`BytesN`) even if its own code does not use them.

Upgrade: `env.deployer().update_current_contract_wasm(new_wasm_hash)`. Token recovery:
`soroban_sdk::token::TokenClient::new(env, &token).transfer(&env.current_contract_address(), &to, &amount)`.

## Testing notes

- `Env::default()`; `env.mock_all_auths()` for the happy path; for **(host)** conditions use
  `env.mock_auths(..)` for the *wrong* address (or no auth) and `#[should_panic(expected =
  "Error(Auth, InvalidAction)")]`. Contract errors: `#[should_panic(expected = "Error(Contract, #101)")]`
  or the client's `try_` variant matched against `Err(Ok(CacheError::..))`.
- Deploy with `env.register(Contract, (ctor_args,))`; deploy a wasm fixture with
  `env.register(WASM_BYTES, (args,))`; upload for upgrade with `env.deployer().upload_contract_wasm(bytes)`.
- Move ledgers with `env.ledger().with_mut(|li| li.sequence_number = n)`; change the network
  maximum with `env.ledger().set_max_entry_ttl(n)` (testutils `Ledger` trait). Retention-window
  tests must keep the ledger inside the instance/persistent lifetimes (the test host
  auto-restores expired persistent/instance entries and treats expired temporary entries as
  absent) — lower `max_entry_ttl` to a few hundred ledgers rather than rolling thousands ahead
  (except the two `cache.retention.*` scenarios, which run under the default maximum and roll
  `DATA_RETENTION_TTL` ahead),
  and lower `min_persistent_entry_ttl` (default 4096) below it, otherwise first-write pinning
  cannot be observed; read an entry's
  TTL inside `env.as_contract(&id, || env.storage().persistent().get_ttl(&key))` (testutils
  `storage::Persistent` / `Temporary` / `Instance` traits); expire a round by removing its
  temporary entry inside `as_contract`.
- Assert events by comparing `event.to_xdr(&env, &contract_id)` (needs `soroban_sdk::Event`
  in scope) against `env.events().all().filter_by_contract(&id)`. `env.events().all()` holds
  only the **last** invocation's events — assert before making any further call, including
  read-only ones like a token `balance`.
- The SDK writes `test_snapshots/` on every test run; add it to `.gitignore`.
- A mock Cache for Proxy unit tests: a small contract implementing `DataFeedsCacheReader`
  with injectable rounds, latest, frozen flags and a forced error; leave the reads the Proxy
  never uses unimplemented.
- A token for `recover_tokens`: `env.register_stellar_asset_contract_v2(admin)` and its
  `StellarAssetClient::mint`.
- `#[contracttype]` on a struct cannot have a field typed `Option<S>` where `S` is itself a
  `#[contracttype]` struct (or an `Option<u32>` field either) — the derive needs
  `ScVal: TryFrom<&Option<S>>` for spec generation and that bound isn't met, so the crate fails
  to compile with a confusing `From<S> for ScVal` error pointing at the *outer* struct's
  `#[contracttype]` line. This only affects nested struct *fields*; `Option<S>` as a function
  argument or return type (e.g. the Cache reader's `Vec<Option<RoundData>>`) is unaffected. Model
  a test-only "0 or 1 present" field as `Vec<S>` (or a `bool` + a dummy `S`) instead of `Option<S>`
  — this bites test-only doubles with optional record fields.
- `std::panic::set_hook` is a process-global resource; `cargo test`'s default thread pool runs
  `#[test]` functions concurrently, so a helper that swaps the hook to capture a panic message
  (for host-auth-failure / library-error assertions where the payload isn't a plain
  `&str`/`String`) must serialise the whole hook-swap-and-`catch_unwind` critical section behind
  a `static Mutex<()>` — otherwise two tests racing through it intermittently see each other's
  hook or an empty captured message.
- A temporary-tier entry written without an explicit `extend_ttl` call keeps only the network's
  default/minimum TTL, so a fixture written before an `age_ttl`/ledger-jump step in the *same*
  test can appear to have expired (reads see it as absent) by the time the assertion runs. A
  test-only double that doesn't otherwise need TTL semantics (e.g. the Proxy's mock-Cache) should
  either store its state in the persistent tier (which the test host auto-restores when "expired")
  or explicitly re-pin its temporary entries to the network maximum on every write.

## Decision log

Same format as `SKILL.md` step 6. With this overlay and `spec/06` applied there should be
no `[ABI]` or `[BEHAVIOUR]` entries; any that remain are written back into this overlay by
the run that produced them (SKILL.md step 7).

## Retention constant

Sequence unit nominal duration: 5-second ledgers → `DATA_RETENTION_TTL = 3_110_400` (180 days, `spec/04`).
