# Decision log — Solana implementation

One entry per choice the spec (`01`–`06`) plus the Solana overlay did not determine.
Tags: `[ABI]` on-chain interface/layout, `[BEHAVIOUR]` observable behaviour, `[INTERNAL-NAME]`
naming/organisation with no on-chain effect, `[TEST-TECHNIQUE]` how a condition is exercised.

1. `[ABI]` **Program ids.** Two fresh keypairs were generated (`keys/cache.json`,
   `keys/proxy.json`) and their pubkeys declared with `declare_id!`
   (`25HhsgLfQfdQEZqiGgpUt2JPALrSp6VFc2HqkC5NWFHS`, `9oCC2Y4ELvKKhtnXGY6oNE7P12BhykMBswCdb2rZNjDT`).
   The overlay names no ids; the processors use the runtime-supplied `program_id` for all
   derivations, so the same code runs unchanged under any id (used by the tests for a second
   Cache instance).

2. `[ABI]` **Config account payload encoding.** The overlay lists the config contents
   ("owner, pending owner + live_until"; Proxy adds `cache`) but not their Borsh shape. Chosen:
   `Ownable { owner: Option<Pubkey>, pending: Option<PendingTransfer { new_owner: Pubkey,
   live_until_ledger: u32 }> }`, followed for the Proxy by `cache: Pubkey`; maximum sizes 71
   (Cache) and 103 (Proxy) bytes including the discriminator, zero-padded. Deserialisation reads
   the Borsh prefix and ignores the padding without checking that it is zero.

3. `[ABI]` **Round account payload.** The overlay says round accounts "additionally store the
   payer pubkey (outside the RoundData ABI)". Chosen order: `RoundData` then `payer: Pubkey`
   (`RoundRecord`).

4. `[ABI]` **`has_permission` keeps its `sender` argument.** A.2 drops only the
   *host-authorised* `sender`/`admin` principals; `has_permission`'s `sender` is a lookup key
   with no authorisation, so it stays as instruction data (`data_id, sender, workflow_owner,
   workflow_name`).

5. `[ABI]` **Proxy CPI reader account layout.** The overlay says "then the Cache accounts in the
   Cache's own convention for `is_frozen` and the delegated reader" after the shared
   `cache_config`. Read literally: one group per CPI, so `latest_round` takes `feed_state`
   twice (`is_frozen`, then `latest_round`), `get_round` takes `feed_state, feed_state, round`,
   `decimals`/`description` take `feed_state, feed_config`. Documented in the README table.

6. `[BEHAVIOUR]` **Supplied-range edge cases for `round_range` / `find_round`.** Accounts for
   ids at or below the tip that the iteration/probe needs must be supplied
   (`NotEnoughAccountKeys` otherwise — never a partial result); the tip's own account is
   optional (validated if supplied, never read; overlay: "accounts above the tip may be
   omitted", "a supplied tip account is validated but not read"). `find_round` validates only
   the accounts it probes (plus the tip account when supplied); `round_range` validates every
   account it iterates.

7. `[BEHAVIOUR]` **`recover_tokens` account checks.** The overlay states `source` "must be a
   token account of that mint owned by the config PDA" but names no failure, while `06` K.2 says
   the contract adds no validation of its own. Chosen: `token_program` must be the SPL Token
   program (`IncorrectProgramId`); `destination` must equal `to` and `source` must unpack as a
   token account of mint `token` owned by the config PDA (`InvalidArgument`); everything else
   (balance, frozen accounts, mint mismatch between source and destination) is left to the
   token program, whose error fails the call unchanged. All are host-style errors, no spec code.

8. `[BEHAVIOUR]` **`reclaim_round` check order.** Derivations → state present → round present
   (`UninitializedAccount`) → tip or readable (`RoundStillReadable` 111) → payer mismatch
   (`InvalidArgument`) → close. The overlay lists the conditions without an order.

9. `[BEHAVIOUR]` **Payer signature is checked up front.** `on_report` and the admin batches
   require `payer` to be a signer before any other work (even a batch that ends up creating
   nothing), since the overlay marks `payer (s,w)` in the convention. `set_cache` likewise
   requires its listed `payer` and `system_program` accounts to be present although it never
   allocates.

10. `[BEHAVIOUR]` **Record present with a foreign discriminator** (an account owned by the
    program at the derived address whose first byte is not the expected record type) fails with
    `ProgramError::InvalidAccountData`. Unreachable through the program's own writes.

11. `[BEHAVIOUR]` **Pre-funded derived addresses.** The overlay describes uninitialised records
    as "system-owned, zero data" without fixing their lamports. If a derived address already
    holds lamports, creation tops up to rent-exemption and uses `allocate` + `assign` instead
    of `create_account`, so a stray donation cannot block a record.

12. `[BEHAVIOUR]` **Return-data cap on host builds.** The SBF syscall aborts the program when
    return data exceeds 1024 bytes; `solana-program-test`'s native stub does not check. The
    non-SBF build mirrors the abort with a panic (→ `ProgramFailedToComplete`, the same
    transaction error the SBF build produces) so tests observe the platform failure.

13. `[BEHAVIOUR]` **Undecodable instruction data** (including the non-existent `upgrade` tag)
    fails with `ProgramError::InvalidInstructionData` — a native error, no spec code (`06` E.4).

14. `[INTERNAL-NAME]` **Module split.** Cache: `instruction`, `state` (seeds, discriminators,
    layouts), `domain/{window,search}`, `processor/{lifecycle,admin,report,reader}`; Proxy:
    `instruction`, `state`, `processor`; common: `types`, `errors`, `events`, `ownership`,
    `account`, `ret`, `tokens`. Entry-point helper names (`Record`, `derived`, `nth`,
    `CpiCtx`, …) are internal.

15. `[INTERNAL-NAME]` **Build settings.** Workspace lints allow the deprecated
    `solana_program::system_instruction`/`system_program` re-exports (the only ones available
    without crates beyond the overlay's list) and declare the `target_os = "solana"` cfg; the
    dev/test profiles build without debug info to keep the program-test dependency tree small.

16. `[TEST-TECHNIQUE]` **Upgrade conditions.** Case I.2 applies, so no `upgrade` entry point
    exists (asserted). The self-upgrade persistence conditions are nevertheless exercised
    end-to-end: the built `.so` files are placed behind the BPF upgradeable loader at genesis
    with the owner as upgrade authority, and upgraded to themselves through a buffer account
    (`write` chunks + `upgrade`); a non-authority upgrade is asserted to fail. These two tests
    print `SKIPPED` and pass when `target/deploy/*.so` has not been built.

17. `[TEST-TECHNIQUE]` **Tip "expiry".** Solana never expires the tip's round account and
    `reclaim_round` refuses the tip, so "latest_round still returns the tip after the tip's
    round entry has expired" deletes the account directly with `ProgramTestContext::set_account`.

18. `[TEST-TECHNIQUE]` **Distinct transactions.** Every write transaction is prefixed with a
    system transfer of a unique lamport amount to a pre-funded sink, so identical consecutive
    calls (re-add admin, repeated freeze) are not deduplicated; the failing `InstructionError`
    is extracted regardless of instruction index.

19. `[TEST-TECHNIQUE]` **Mock Cache.** A native program that decodes `CacheInstruction` and
    answers from a `MockFeed { latest, rounds, frozen, decimals, description, fail_with }`
    stored in the mock's `feed_state`/`feed_config` PDAs; `fail_with` makes every reader fail
    with that custom code (used for "a Cache error traps the read" and "invalid precision
    fails before the Cache is consulted").

20. `[TEST-TECHNIQUE]` **Cache swap.** The Cache processor is registered a second time under
    another program id so the Proxy can be pointed at an independent, real Cache.

21. `[TEST-TECHNIQUE]` **Warp distances.** Persistence ("lifetime refresh") checks warp at
    most 100 000 slots, or none at all where accounts were injected with `set_account`; only
    the retention conditions warp past `DATA_RETENTION_TTL`. Large warps in many tests, and a
    warp after `set_account`, exhaust file handles in program-test's accounts-hash background
    work (`Too many open files` in `accounts_hash.rs`), which is unrelated to the programs.
