# Decision log — Aptos (`df-gen/aptos-2`)

Choices that `spec/01`–`06` plus `chains/aptos.md` did not determine. Phase 0 did not run
(`chains/aptos.md` existed). Toolchain: Aptos CLI 7.6.0, framework `aptos-cli-v7.6.0`.

## [ABI]

- none — every public name, argument, type, field, event and error code is fixed by the spec
  and the overlay (spec spelling; `sender`/`admin` signers; instance address as first non-signer
  argument; `Bound` as `u8`; `answer` as two's-complement `u256`; ownership events UpperCamelCase).

## [BEHAVIOUR]

- **Instance check first.** Every entry point and every view asserts that the `Cache` / `Proxy`
  resource exists at the instance address (`host_error::no_instance()`, aborting in the called
  module) before any signer/owner check, byte-width check or spec check. A call on a missing
  instance therefore never surfaces a spec error code. (Written back to overlay axis A.)
- **`find_round` bound validation precedes the state lookup.** An unknown `bound` discriminant
  aborts with `host_error::invalid_argument()` even for a feed without state (host argument
  checks precede spec logic, the D.2 analogue), instead of answering `None`. (Written back to
  overlay axis K.)
- **`recover_tokens` ordering and framework failures.** `TokenRecovered` is emitted after
  `primary_fungible_store::transfer` returns; the destination's primary store is created by the
  framework when absent; an amount above the instance's balance aborts with
  `fungible_asset::EINSUFFICIENT_BALANCE` (`0x10004`, location `aptos_framework::fungible_asset`);
  a `token` address holding no `Metadata` object aborts in `aptos_framework::object`. The
  contract adds no check of its own (`spec/06` K.2). (Written back to overlay axis K.)

## [INTERNAL-NAME]

- `data_feeds::window` API: `initial(ttl)`, `next(prev, prev_tip_seq, ttl, seq)`,
  `width_at(w, now)`, `is_readable(w, round_seq, now)`, field accessors `shortest_ttl`,
  `grow_to_ttl`, `grow_at_ledger` (public so `tests/` modules can drive the TTL-varying
  conditions, `spec/06` C.3). `Window` is never returned by a public entry point, so the
  `<struct_snake>_<field>` accessor convention of M.2 is not applied to it.
- `data_feeds::ownable` API on `&mut OwnershipState`: `new(owner)`, `get_owner`,
  `enforce_owner(state, caller)`, `transfer_ownership(state, caller, new_owner,
  live_until_ledger, now)`, `accept_ownership(state, caller, now)`,
  `renounce_ownership(state, caller, now)`; private `set_owner` carries `OwnerAlreadySet` (2102).
- `data_feeds::cache` private helpers: `probe` (tip-or-readable-round lookup shared by
  `get_round`, `round_range`, `find_round`), `record`, `decode_metadata`, `decode_report`,
  `read_uleb128`, `slice` (no `vector::slice` in this stdlib), `permission_hash`,
  `require_admin`, `delete_permissions`, `is_all_zero`, `borrow_instance[_mut]` (inline).
  The decoded metadata record is the private `struct Metadata has copy, drop` in
  `data_feeds::cache`; the fungible-asset type is referenced as `fungible_asset::Metadata`.
- `data_feeds_proxy::proxy` private helpers: `effective_min`, `validate_decimals`,
  `frozen_check`, `project`, `scale` (sign = bit 255; magnitude by two's-complement negation
  `(x ^ MAX_U256) + 1`; integer division; re-negation), `pow10`, `borrow_instance[_mut]`.
- Round and state writes use `table::upsert` (the spec's "write"); round keys are monotonic so
  this is indistinguishable from `add`.
- Proxy `Move.toml` re-declares the dependency's named address `data_feeds = "_"` under
  `[addresses]` so `[dev-addresses]` can pin it to `0x1000` next to `data_feeds_proxy = 0x2000`.

## [TEST-TECHNIQUE]

- Conditions not applicable on Aptos, with the `spec/06` rule: "sender without host
  authorisation (host) fails" — A.2 / overlay axis A (a missing signer is rejected by the
  transaction layer before Move runs; the tested guarantee is that a non-permitted signer is
  soft-skipped); "`upgrade` swaps code in place" and "self-upgrade keeps ..." — I.2 / I.4
  (tested as persistence without an upgrade step; `no_upgrade_entry_point_exists` is a named
  test with a comment); "network maximum below the network's minimum entry lifetime" — C.3;
  TTL-varying window conditions (shrink/grow/second change/lock-in/switch exactly at
  `grow_at_ledger`) — C.3, tested against `data_feeds::window` directly; lifetime-refresh
  conditions — C.3, asserted as persistence after advancing the clock by 20M seconds.
- Extra `#[test_only]` helpers beyond the overlay's list: Cache `test_has_round`,
  `test_new_round_data`; Proxy `test_new_round`; `ownable::test_error_codes`.
  `test_inject_round(cache, data_id, round_id, answer, timestamp, ledger_seq)` writes the
  round, makes it the tip (window `initial(DATA_RETENTION_TTL)` for a new state, `frozen`
  preserved) — no business logic. `test_set_frozen` requires existing state.
- `test_utils` helpers: `setup(fw, secs)`, `set_time`, `bytes(len, last)`, `zero(len)`,
  `id/owner20/name10/cid32/report_id2(n)` (zero-filled, last byte `n`), `metadata(...)`,
  `md(owner, name)`, `report(entries)` = `bcs::to_bytes(&vector<ReportEntry>)`, `report1`,
  `create_cache(creator, seed, owner)`, `perm`, `entry`, `str`, `configure`, `setup_feed`,
  `create_token` (`init_test_metadata_with_primary_store_enabled` on a named object; max
  supply 100), `mint`, `balance`.
- Expiry of a temporary round entry is emulated with `test_expire_round`; window masking is
  exercised by advancing the clock past `ledger_seq + 15_552_000`.
- Report-decoder failure cases: garbage bytes, truncated body, trailing byte, empty bytes,
  non-minimal ULEB128 count (`[0x81, 0x00]`) — all `100` in `data_feeds::cache`.
- "Only"/count conditions use `vector::length(&event::emitted_events<T>())`, which
  accumulates over the whole test; each such test starts from a fresh instance.
- A Cache abort propagating through the Proxy is asserted with `location = data_feeds::cache`
  (`0x60001` from a Proxy whose `cache` address holds no instance); Proxy `FeedFrozen` (109)
  and 50/51/52 with `location = data_feeds_proxy::proxy`; host failures of owner / pending
  owner checks with `location = data_feeds::ownable`.
- Negative answers in tests are built as `(x ^ MAX_U256) + 1`; a 256-bit-fidelity test stores
  `2^200 + 2^129 + 99`, `-5` and the minimum `I256` bit pattern.
- Check-order tests added beyond `spec/05`: width check after 101 and before an entry's spec
  checks; duplicate-id check before configured / state checks in `remove_feed_configs` and
  `set_feed_frozen`; metadata before report body; precision before frozen check and before the
  Cache is consulted; owner auth before width check before 51 in `set_min_decimals`.
