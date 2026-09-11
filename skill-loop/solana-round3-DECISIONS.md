# Decision log — Solana implementation

One entry per choice that `spec/01`–`06` plus `chains/solana.md` left open. Tags:
`[ABI]` on-chain interface, `[BEHAVIOUR]` observable behaviour, `[INTERNAL-NAME]` naming
of non-ABI items, `[TEST-TECHNIQUE]` how a required condition is exercised.

1. `[BEHAVIOUR]` Proxy readers: a `cache_program` account that is not the stored cache fails
   with `ProgramError::IncorrectProgramId`. The overlay requires the check but names no error;
   `IncorrectProgramId` is the native variant for "wrong program".
2. `[BEHAVIOUR]` Proxy CPI result handling: missing return data, return data published by a
   program other than the cache, or undecodable return data fail with
   `ProgramError::InvalidAccountData` (a native error outside all spec ranges). Unreachable
   with the real Cache; only a foreign program at the cache address could trigger it.
3. `[BEHAVIOUR]` Return-data cap: `set_return` panics when the Borsh result exceeds 1024 bytes,
   so native (program-test) builds fail with `ProgramFailedToComplete` exactly like the SBF
   syscall's `ReturnDataTooLarge` abort; a long `round_range` never returns a partial result.
4. `[BEHAVIOUR]` Order of native account checks vs. contract-level validation in
   fixed-account instructions: account derivation is checked immediately after authorisation
   and config loading, before contract validations. Concretely `set_min_decimals` checks the
   `min_decimals` derivation before `min > 18 → 51`, and the Proxy readers derive every Cache
   record before validating `decimals` (51 still precedes any CPI). Batch instructions
   validate per item at the point the item is consumed, as the overlay prescribes for
   `on_report`; for `remove_feed_configs` the per-id accounts are consumed during the
   validate-everything-first pass (no writes happen before all ids pass).
5. `[BEHAVIOUR]` `get_round`: the `round` account is always required and derivation-checked
   for `(data_id, round_id)` (also when the feed has no state or `round_id` is the tip); it
   is read only for a non-tip id. The tip is answered from `feed_state`.
6. `[BEHAVIOUR]` `round_range` / `find_round`: supplied round accounts are validated for
   every id of the requested range in order; accounts for ids above the tip are validated
   when present and the walk stops at the first missing one; ids at or below the tip must
   be present (`NotEnoughAccountKeys`). Accounts beyond the requested range are surplus and
   ignored.
7. `[BEHAVIOUR]` `recover_tokens`: "source is a token account of mint `token` owned by the
   config PDA" is realised as: `source.owner == SPL Token program`, `spl_token::state::Account`
   unpacks, `mint == token`, `owner == config PDA` — each failing with `InvalidArgument`
   (after the `IncorrectProgramId` and `destination == to` checks). Everything else is left
   to SPL Token.
8. `[BEHAVIOUR]` `reclaim_round` emits no event (the spec/overlay list none) and takes no
   config account (the overlay's account list has none), so it is the one instruction
   besides `initialize` that does not fail with `UninitializedAccount` for a missing config.
9. `[BEHAVIOUR]` `transfer_ownership`: Solana has no "maximum offer horizon", so only
   `live_until_ledger < now` is rejected with 2201; any larger u32 is accepted.
10. `[BEHAVIOUR]` `on_report`: if the round account for `tip + 1` already exists as a
    program-owned account (unreachable through the interface), the system-program
    `create_account` CPI fails natively; no spec code is assigned.
11. `[INTERNAL-NAME]` Record and helper names not on the ABI: `CacheConfig` / `ProxyConfig`
    (config PDA payloads), `Ownership` + `PendingTransfer` (ownership sub-record),
    `RoundRecord` (`RoundData` + `payer`), `WindowExt` (window arithmetic), record
    discriminator module `disc`, module split `instruction / state / domain / events /
    processor / client` per program; Borsh instruction enums `CacheInstruction` /
    `ProxyInstruction` with PascalCase variant names (only the variant index is on the wire).
12. `[TEST-TECHNIQUE]` Every write transaction appends a unique self-transfer nonce
    instruction *after* the instruction under test, so identical instructions are never
    deduplicated and errors are always reported for instruction index 0.
13. `[TEST-TECHNIQUE]` "Refreshes the instance / entry lifetime" conditions are asserted as
    persistence (`spec/06` C.3): the account exists, is owned by the program, is rent-exempt
    and survives slot warps; "reads never create `MinDecimals`" is asserted by account absence.
14. `[TEST-TECHNIQUE]` Mock Cache for the Proxy unit tests: a native processor registered
    under a fixed program id that decodes `CacheInstruction` and answers `is_frozen`,
    `latest_round`, `get_round`, `decimals`, `description` from a `MockState` record injected
    with `set_account` into its `["config"]` PDA (injectable rounds, latest, frozen flag,
    forced error on the delegated call or on the frozen check). Per-id records are passed as
    their non-existent derived addresses. A second real Cache deployment for cache-swap tests
    is the same processor registered under a second program id.
15. `[TEST-TECHNIQUE]` Loader upgrade test: program, programdata (authority = owner) and
    buffer (authority = owner, containing the artifact) accounts are added at genesis;
    data is seeded through the SBF build, `bpf_loader_upgradeable::upgrade` is sent signed
    by the owner, and a two-slot warp makes the new code visible. It is a self-upgrade of
    the Cache artifact and additionally exercises resize/close paths under the SBF runtime.
16. `[TEST-TECHNIQUE]` Conditions that vary the round TTL (window shrink/grow, second change,
    same-ledger writes, lock-in after the grow date) are unit tests on the `Window` helper
    in `domain.rs`; expiry through the public interface is exercised with slot warps past
    `DATA_RETENTION_TTL`; "tip round entry expired" is emulated by deleting the round account
    with `set_account`; "network maximum below the minimum entry lifetime" does not apply.
