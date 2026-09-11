# Decision log — Stellar (Soroban) Data Feeds Cache + Proxy

One entry per choice the spec (`01`–`07`) plus the `chains/stellar.md` overlay did not already
pin down. Tags: `[ABI]`, `[BEHAVIOUR]`, `[INTERNAL-NAME]`, `[TEST-TECHNIQUE]`.

## Production contracts

1. `[ABI]` No mechanical case transformation (`06` K.1) was applied to any public identifier.
   Function names, argument names, event/field names and error variant names are the spec's
   own `snake_case`/`PascalCase` spellings verbatim, since Rust/Soroban's own idiom already
   matches the spec's casing and the axis only *permits* a transform, it doesn't require one.

2. `[BEHAVIOUR]` `set_feed_frozen`'s "an id without `FeedState` aborts the whole batch" (`02`)
   is implemented as a single forward pass that writes `FeedState.frozen` and emits
   `FeedFrozenSet` for each id in order, returning `Err(NoFeedState)` the moment a missing-state
   id is reached. This relies on Soroban's native per-invocation atomicity (a failed call's
   storage writes are never committed) to discard the earlier ids' writes, rather than a
   separate pre-validation pass that checks every id's `FeedState` exists before writing
   anything (which is what `set_feed_configs` and `remove_feed_configs` do, since their
   validations are cheap and id-only). `cache.set_feed_frozen.a_feed_without_state_aborts_the_whole_batch`
   exercises this and passes, confirming the reliance is sound on this host.

3. `[BEHAVIOUR]` The `upgrade_to_peek` fixture (`test-fixtures/peek-contract`) reads the
   `Ownable` `Owner` instance-storage slot (`stellar_access::ownable::get_owner`) rather than
   any Data-Feeds-specific key. Both `DataFeedsCache` and `DataFeedsProxy` write that same slot
   in their constructor, so one fixture crate serves `cache.lifecycle.upgrade_is_wired` and
   `proxy.lifecycle.upgrade_is_wired` alike, and a correct `peek()` result after the swap proves
   both that the new code is running (the real contracts have no `peek`) and that instance
   storage survived it.

4. `[INTERNAL-NAME]` Cache module split: `domain::{permission_hash, decode_metadata,
   decode_report, get_round, round_range, find_round}` hold the state-machine/decoding/binary-
   search logic; `storage::*` holds key construction and the TTL helpers (`refresh_instance`,
   `set_feed_config`, `write_round`, …); `contract::{require_admin, record}` are the two shared
   entry-point helpers (auth+membership prologue, and the per-report-entry stale/append logic).
   None of these names are observable on-chain.

5. `[INTERNAL-NAME]` Proxy module split mirrors the Cache's: `domain::{effective_min,
   validate_decimals, scale}` for precision; `storage::{get_cache, set_cache,
   refresh_min_decimals_if_present, set_min_decimals}`; `contract::{frozen_check,
   reader_client}` as the two shared reader helpers.

## Test harness (not part of either deployable)

6. `[TEST-TECHNIQUE]` Host-level and library-error assertions (`{"host_fail": true}`, a Cache/
   Proxy trap carrying a numeric code) are asserted by calling the plain (non-`try_`) client
   method inside `std::panic::catch_unwind`, with a temporary panic hook that captures the
   formatted message (`"HostError: Error(Contract, #<code>)"` / `"...Error(Auth,
   InvalidAction)"`) for the cases where the panic payload itself isn't a plain `&str`/`String`.
   Because `std::panic::set_hook` is process-global and `cargo test` runs tests concurrently,
   the whole hook-swap-and-catch region is serialised behind a `static Mutex<()>`
   (`support::PANIC_HOOK_LOCK`) in both crates' test supports — without it, two such assertions
   racing on different threads intermittently stomp on each other's hook.

7. `[TEST-TECHNIQUE]` `CacheError`/`ProxyReadError`-typed failures (e.g. `UnauthorizedCaller`,
   `EmptyConfig`, `InvalidDecimals`) are asserted via the generated `try_<fn>` client method
   matched against `Err(Ok(TheError::Variant))`, never via panic capture — they are ordinary
   `Result::Err` returns, not traps.

8. `[TEST-TECHNIQUE]` `"as": "unauthorised"` (`spec/07-scenarios.md`) is realised by calling
   `env.set_auths(&[])` immediately before the one failing call (clearing the environment's
   blanket `mock_all_auths()` grant so `require_auth()` has nothing to match), then restoring
   `env.mock_all_auths()` for any later steps in the same scenario that need it.

9. `[TEST-TECHNIQUE]` The Proxy's mock Cache (`data-feeds-proxy/src/tests/mock_cache.rs`)
   stores its per-feed `latest` round and `fail_with` code as 0-or-1-element `Vec<T>` rather
   than `Option<T>`, and keeps its state in *persistent* storage (explicitly re-pinned to the
   network maximum on every write) rather than temporary — see the two `chains/stellar.md`
   "Testing notes" facts appended by this run for why.

10. `[TEST-TECHNIQUE]` `I256` values from `scenarios.json`'s decimal-string answers (including
    negative values and values beyond `i128`) are built by a small `i256(env, &str)` helper that
    accumulates the digits via repeated `I256::mul`/`add` and negates at the end if the string
    was prefixed `-`, since the SDK has no direct decimal-string constructor for `I256`.

11. `[TEST-TECHNIQUE]` `new_env()` fixes `min_persistent_entry_ttl = min_temp_entry_ttl = 16`
    and `max_entry_ttl = 4_000` for every test (per the overlay's "a few hundred ledgers"
    guidance), rather than the network's real defaults, so `age_ttl` and TTL assertions are
    observable without rolling the ledger by millions. Scenarios that need a specific
    `DATA_RETENTION_TTL`-vs-network-maximum relationship (the `round_range`/`find_round`/
    `get_round` window-shrink/grow scenarios) call `set_network_max` explicitly instead of
    relying on this default.

No scenario was inapplicable: Stellar's declared capabilities (`per_arg_auth`, `expiry`,
`network_max_variable`, `in_contract_upgrade`, `events_indexed`) are a superset of every
`requires` list in `spec/scenarios.json`, so all 179 scenarios were implemented as tests.
