# Decision log — Chainlink Data Feeds on Aptos (`chain = aptos`)

Phase 0 ran (no `chains/aptos.md` existed): the overlay was authored from `chains/_template.md`
after verifying the toolchain (Aptos CLI 7.6.0, framework pinned to git tag `aptos-cli-v7.6.0`)
with a hello-world build/test. Every `[ABI]` and `[BEHAVIOUR]` entry below has been written
back into `chains/aptos.md` (SKILL.md step 7); the section that holds it is named.

## [ABI]

1. **Instance model.** Move has no dynamic dispatch by address and a module cannot be deployed
   twice in a test, so a "contract" is *module code + an object instance*: one `Cache` /
   `Proxy` resource per instance object. Every entry point takes the instance address
   (`cache: address` / `proxy: address`) as its first non-signer argument. This is what makes
   `set_cache` and multi-instance tests meaningful. → overlay axis B, "Interface encoding".
2. **Constructors.** `cache::create(creator: &signer, seed: vector<u8>, owner: address)` and
   `proxy::create(creator, seed, owner, cache)` are `public entry`; the instance is a named
   object at `object::create_object_address(&creator, seed)` (entry functions cannot return
   the address, so a caller-chosen seed makes it derivable). → "Interface encoding", axis B.
3. **`set_feed_configs` is `public fun`, not `entry`** — entry functions cannot take struct
   arguments (compiler-verified). It is reached from a transaction through a Move script
   using the public constructors `new_workflow_permission`, `new_feed_config`,
   `new_feed_config_entry`. No flattened entry variant was added (no extra surface).
   `new_report_entry` exists for encoders. → "Interface encoding".
4. **Record field access.** Struct fields are private outside their module, so public
   accessors `<struct_snake>_<field>` (e.g. `round_data_answer`, `round_round_id`) expose
   record fields; field names/order remain the ABI (BCS / view JSON). → "Type vocabulary".
5. **`Bound` is a `u8` discriminant** (`0` = `AtOrBefore`, `1` = `AtOrAfter`) on `find_round`
   because entry/view functions cannot take enums. → axes G/K, "Type vocabulary".
6. **`answer: I256` is `u256`** holding the two's-complement bit pattern (BCS: 32 bytes LE);
   Move has no signed integers. → axis K, "Type vocabulary".
7. **Ownership event names are UpperCamelCase** (`OwnershipTransfer`,
   `OwnershipTransferCompleted`, `OwnershipRenounced`): Move struct names must start with an
   uppercase letter; declared as the overlay's one mechanical case transformation (K.1).
   → axes H/K.
8. **Host failure codes** (`data_feeds::host_error`): `unauthorized() = 0x50001`,
   `no_instance() = 0x60001`, `invalid_argument() = 0x10001` — `std::error` categories,
   outside every spec range; abort location is the module that aborts (owner / pending-owner
   checks abort in `data_feeds::ownable`). → axes A/E.
9. **Token recovery** uses the Fungible Asset standard: `token` is the `Metadata` object
   address, `amount: u64`, transfer via the instance's `ExtendRef` signer and
   `primary_fungible_store::transfer`; failures are the framework's own aborts. → axis K.
10. **`version()` / `type_and_version()` take no instance argument** (module-level constants).
    → "Interface encoding".
11. **Signer parameter naming**: the `&signer` takes the dropped argument's role name
    (`sender`, `admin`, `owner`, `new_owner`). → axis A.
12. **Module split / two deployables**: `data_feeds::{host_error, ledger, ownable, window,
    cache}` in the Cache package, `data_feeds_proxy::proxy` in the Proxy package, which
    depends on the Cache package (shared library modules live in the Cache package so there
    are exactly two deployables). → "Layout and commands".

## [BEHAVIOUR]

13. **Sequence unit = chain timestamp in seconds** (`timestamp::now_seconds()` truncated to
    u32), not block height: `block::get_current_block_height()` cannot be advanced in
    `aptos move test` (only `emit_writeset_block_event`, +1 per VM-signed call), which would
    make every retention condition untestable through the public interface, and the
    framework's own Move code uses the timestamp as its clock. `ledger_seq` and
    `live_until_ledger` are in this unit. → axis C.
14. **Byte-width validation (D.2 analogue)**: `set_feed_configs` checks `data_id` = 32,
    permission owner = 20, name = 10 at the point each entry is validated (before that
    entry's spec checks, after the `UnauthorizedCaller` / empty-batch checks);
    `set_min_decimals` checks `data_id` = 32 after owner auth and before `InvalidDecimals`.
    Lookup-only arguments and decoded report ids are not width-checked (a mis-sized id is an
    unknown feed). → "Interface encoding".
15. **Unknown `Bound` value** (`bound > 1`) → `host_error::invalid_argument()` (bad
    instruction data, never a spec code). → axis K.
16. **`ObjectCore.owner`** of the instance object is the creator (named-object semantics) and
    is not tracked; the spec's ownership lives in the resource. → axis B.
17. **Re-creating an instance** with the same `(creator, seed)` fails with the framework's
    `object::EOBJECT_EXISTS` abort (native failure). → axis B.
18. **No maximum offer horizon** for `transfer_ownership` on Aptos (J's "where one exists"
    clause is empty). → axis J.
19. **Lifetime rules are no-ops** (C.3); `round_ttl()` returns `DATA_RETENTION_TTL`; rounds
    are never deleted; Cache readers and Proxy readers are pure. → axis C.
20. **Ownership library cannot be invoked on an instance from outside**: `OwnershipState` is a
    `store`-only value embedded in the instance resource and the `ownable` functions take
    `&mut OwnershipState`, so only the owning contract module can drive it. → axis J.

## [INTERNAL-NAME]

21. Resources `Cache` / `Proxy` and their fields (`extend_ref`, `ownership`, `feed_admins`,
    `feed_configs`, `permissions`, `feed_states`, `rounds`, `cache`, `min_decimals`); key
    structs `PermissionKey { data_id, phash }`, `RoundKey { data_id, round_id }`; internal
    `FeedState`, `Metadata`, `Window`.
22. Cache helpers: `record`, `readable_round`, `permission_hash`, `authorize_admin`,
    `round_ttl`, `remove_permissions_of`, `is_all_zero`, `decode_metadata`, `decode_report`,
    `read_uleb128`, `read_u64_le`, `read_u256_le`, `borrow_cache(_mut)`; constants
    `BOUND_AT_OR_BEFORE`, `BOUND_AT_OR_AFTER`, `VERSION`, `METADATA_LEN`, `MAX_U32`.
23. Proxy helpers: `effective_min`, `validate_decimals`, `assert_not_frozen`, `project`,
    `scale`, `negate`, `pow10`, `borrow_proxy(_mut)`; constants `SIGN_BIT`, `MAX_U256`.
24. Library modules: `data_feeds::window` (`initial`, `width_at`, `is_readable`, `next`,
    accessors), `data_feeds::ledger::sequence`, `data_feeds::ownable` (`new`, `set_owner`,
    `get_owner`, `enforce_owner`, `transfer_ownership`, `accept_ownership`,
    `renounce_ownership`, `PendingTransfer`), `data_feeds::host_error`.
25. Error constants keep the spec spelling (`const MalformedReport: u64 = 100;`); they are
    module-private in Move and therefore not ABI.

## [TEST-TECHNIQUE]

26. **Atomicity after an abort cannot be observed** in Move unit tests (an abort ends the
    test); conditions such as "an invalid entry aborts the whole batch (earlier valid
    entries are not written)", "duplicate id aborts and removes nothing", "110 aborts
    everything" assert the abort code with `#[expected_failure]` and rely on the VM's
    transaction atomicity (spec/06 H.2 spirit).
27. **Not applicable — "sender without host authorisation (host) fails"** (`on_report`):
    under A.2/A.3 the signer is proven by the transaction layer before Move code runs; there
    is no Move-level failure to assert. An unpermitted sender is soft-skipped (tested).
28. **Not applicable — upgrade conditions** (`upgrade` swaps code; self-upgrade keeps feed
    data; Proxy self-upgrade keeps routing; SKILL.md step 5 upgrade tests): spec/06 I.2/I.4.
    Resurrection and cache-swap are tested without an upgrade step; the "no `upgrade` entry
    point" assertion is a compile-time fact recorded by the named tests
    `upgrade_entry_point_absent` (trivially passing, with a comment).
29. **Lifetime-refresh conditions are tested as persistence** (C.3): state, config,
    permissions, admin entries and instance singletons are re-read after advancing the clock.
30. **TTL-varying window conditions** run against `data_feeds::window` directly
    (`retention_tests`); "a new round's lifetime is min(3_110_400, max) and never refreshed"
    is asserted through `#[test_only] cache::test_window` (the window plan) and through the
    round still being readable after later reports; "network maximum below the minimum entry
    lifetime" does not apply (C.3).
31. **Expiry emulation**: `#[test_only] cache::test_expire_round` removes a `Round` table
    entry; window masking is exercised by advancing `timestamp` past `ledger_seq + TTL`.
32. **Mock Cache** for Proxy unit tests = `#[test_only]` injectors on the real Cache module
    (`test_inject_round`, `test_set_frozen`; plus `test_expire_round`, `test_window`,
    `test_permission_hash`, `test_error_codes`, and `proxy::test_has_min_decimals`), usable
    from the Proxy package because dependency `#[test_only]` code is compiled under
    `aptos move test`. "A Cache error traps the read with the Cache's code" is exercised by
    routing the Proxy to an address without a Cache instance (the Cache's
    `host_error::no_instance()` propagates); the real Cache readers never raise a spec code
    and production readers carry no forced-error hook.
33. **Events** are asserted with `#[test_only]` event constructors (struct literals are
    module-private) via `event::was_event_emitted` and counts of `event::emitted_events<T>()`
    (cumulative per test) for "only" conditions.
34. **Error-code range tests** use `#[test_only] test_error_codes()` lists on `cache`,
    `proxy` and `ownable`.
35. `#[test_only] module data_feeds::test_utils` lives in `cache/sources/` (not `tests/`) so
    the Proxy package's tests can reuse it.

## Counts

`[ABI]` 12 · `[BEHAVIOUR]` 8 · `[INTERNAL-NAME]` 5 · `[TEST-TECHNIQUE]` 10.
Tests: Cache 124, Proxy 56 (180 total), all passing.
