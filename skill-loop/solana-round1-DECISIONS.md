# Decision log — Solana implementation

One entry per choice that `spec/01`–`06` plus `chains/solana.md` did not determine. Format:
**context → choice → why**. Everything not listed here follows the spec/overlay literally.

1. **Admin membership account.** The overlay's fixed accounts for admin batch instructions
   (`[admin (s), payer (s,w), config, system_program]`) do not include the `FeedAdmin(admin)`
   record, yet `admin ∈ admin set` must be checked on-chain → the fixed list is
   `[admin (s), payer (s,w), config, admin_record, system_program]` (README) → an account-model
   chain cannot test membership without the record being declared (spec/06 D.2).
2. **Ownership instruction accounts.** Not given by the overlay → `transfer_ownership` /
   `renounce_ownership`: `[owner (s), config (w)]`; `accept_ownership`: `[pending_owner (s), config (w)]`
   → the minimum the spec's host-authorisation requires.
3. **`recover_tokens` on Solana.** `token`/`to` are Soroban-flavoured → `token` = mint,
   `to` = destination token account; accounts `[owner (s), config, source (w), destination (w), token_program]`;
   the source must be an SPL token account of that mint owned by the config PDA (which signs the
   transfer) → the overlay only says "SPL Token transfer by CPI signed by the config PDA".
4. **`reclaim_round` accounts and edge cases.** Overlay defines the behaviour but not the accounts
   → `[feed_state, round (w), payer (w)]`; `payer` must equal the payer recorded in the round
   (`InvalidArgument` otherwise); a missing round or state is `ProgramError::UninitializedAccount`
   (native, no spec code) → only `RoundStillReadable = 111` is specified.
5. **Config PDAs are fixed-size and zero-padded** (Cache 71 bytes, Proxy 103 bytes) and read with
   trailing bytes tolerated → Borsh `Option<Pubkey>` changes length when a transfer is pending and
   ownership instructions carry no payer for a resize → a stable layout is part of the upgrade
   contract (spec/06 B.4).
6. **Record discriminators.** Overlay requires a 1-byte record-type discriminator but no values →
   Cache: config 1, FeedAdmin 2, FeedConfig 3, Permission 4, FeedState 5, Round 6; Proxy: config 1,
   MinDecimals 2. Unit records (`FeedAdmin`, `Permission`) hold only the discriminator.
7. **Instruction tags** are the Borsh enum variant indices in `instruction.rs`, in the order
   constructor, writer, admin, readers, lifecycle, reclaim (README tables) → the overlay leaves the
   encoding of instruction data open beyond "Borsh".
8. **`initialize` twice** → `OwnerAlreadySet` (2102). Any other entry point whose config PDA does not
   exist → `ProgramError::UninitializedAccount` → gives the ownership table's `OwnerAlreadySet` a
   use; an uninitialised program has no owner to be "not set".
9. **Ownership details not fixed by spec/06 J.** `transfer_ownership` with a non-zero
   `live_until_ledger` below the current slot → `InvalidLiveUntilLedger` (2201); `accept_ownership`
   by a signer other than the pending owner → `InvalidPendingAccount` (2202) (the signature itself
   is the host check); no pending offer → `NoPendingTransfer` (2200); slot > `live_until_ledger` →
   `TransferExpired` (2203) → the remaining table entries needed a trigger each; validity is
   inclusive per J.1.
10. **Reader fixed accounts.** Every Cache reader takes `[config]` first (also `version` and
    `type_and_version`, which do not read it) → uniform with the overlay's "Readers: `[config]`
    then per id". Proxy readers without a CPI are reduced: `get_min_decimals` → `[config, min_decimals]`;
    `get_cache`, `version`, `type_and_version`, `get_owner` → `[config]` (the overlay's four fixed
    accounts include `min_decimals`, which is undefined without a `data_id`).
11. **History-read account indexing** (spec/06 D.5). `round_range`: accounts cover `from..=to`,
    index = `id − from`; only ids in `[max(from,1), min(to, tip)]` are read, so accounts above the
    tip may be omitted. `find_round`: accounts cover `lo..=hi`, index = `id − lo`, search range
    `[max(lo,1), min(hi, tip)]`. The tip is answered from `FeedState`; its account (if in range) is
    validated for derivation but not read → the overlay names the ranges but not the indexing.
12. **`on_report` account validation.** `permission`, `feed_config`, `feed_state` are validated for
    every entry; `round` (PDA of running tip + 1) only when the entry appends. The overlay's optional
    `clock?` account is not required (Clock sysvar syscall); surplus accounts are ignored →
    "validate before use" (D.2) without forcing callers to derive a round for entries that cannot land.
13. **Deleting records.** Lamports of deleted permissions/configs/admin records are refunded to the
    instruction's `payer`. In `set_feed_configs` the closes are deferred to the end of the
    instruction, and a permission present in both the old and the new list is kept in place rather
    than deleted and recreated → the runtime requires the caller's lamport sum to be unchanged at
    every CPI boundary (creations are CPIs); the observable result (records present/absent, events)
    is the spec's.
14. **Overwriting a variable-size record** (`FeedConfig`) resizes the account to the new length and
    tops up rent from `payer` when it grows; no refund when it shrinks → simplest rent-safe rule.
15. **Events on host builds.** `sol_log_data` is not routed into the transaction log by
    `solana-program-test`'s native processor, so non-SBF builds mirror the exact runtime line
    (`Program data: <base64…>`) through `program_stubs::sol_log`; the on-chain build uses
    `sol_log_data` → keeps the overlay's test recipe ("events from `Program data:` lines") working.
16. **Proxy validation of Cache accounts.** The Proxy checks `cache_program == stored cache`
    (`IncorrectProgramId`), derives `cache_config` and the per-feed Cache records under the Cache
    program id and validates them before the CPI (spec/06 L) even though the Cache validates again.
17. **Proxy `set_cache` accounts** follow the overlay (`payer`, `system_program`) although the fixed
    size config never needs them → keep the documented convention.
18. **Retention on Solana.** `round_ttl` is the constant `DATA_RETENTION_TTL`; readability is the
    window mask only; the TTL-change behaviour of the window (shrink, grow at `grow_at_ledger`,
    replaced plan, lock-in) is unit-tested against the `Window` helper in `data-feeds-common`, since
    the public interface cannot vary the TTL; expiry-driven conditions are exercised by warping the
    slot beyond the window. The "network maximum below the minimum entry lifetime" condition has no
    Solana counterpart (no minimum lifetime) and is not tested.
19. **Lifetime refresh conditions** are tested as persistence (the records exist after the call and
    after a large slot warp) → every refresh is a no-op on Solana (spec/06 C.4).
20. **`Answer` newtype** wraps `ethnum::I256` with the overlay's 32-byte LE Borsh encoding; the
    Rust name is internal, the wire format is the overlay's.
21. **Upgrade tests.** Artifacts are deployed at genesis behind the upgradeable loader with the
    owner keypair as upgrade authority and upgraded with buffer accounts holding a fresh build; the
    "distinct artifact" proof upgrades one program to the other program's artifact and calls the
    other program's `type_and_version` at the same address → the loader is the upgrade mechanism
    (spec/06 I.2).
22. **Test layout.** One integration binary per program (`tests/cache/main.rs`, `tests/proxy/main.rs`)
    sharing one harness (`tests/cache/support`, included by path from the Proxy); the mock Cache is a
    test-only processor answering the Cache reader instructions from state written by a mock
    instruction; `RUST_TEST_THREADS=4` in `.cargo/config.toml` → many `solana-program-test` banks in
    parallel exhaust file handles.
23. **Toolchain pin.** `rust-toolchain.toml` pins `stable` (host tests); SBF builds use Agave 3.1.9's
    bundled platform tools (`cargo build-sbf`, arch `v0`, the runtime of `solana-program-test 2.3`
    accepts it).
24. **Compute.** All PDA checks use `find_program_address`; long history reads may need a raised
    compute budget (`ComputeBudgetInstruction`) — the tests set the bank's limit to 1.4M CU. Reader
    results above the 1024-byte return-data limit abort with the platform failure (spec/06 D.4).
