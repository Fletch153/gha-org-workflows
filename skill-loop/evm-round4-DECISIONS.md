# Decision log — EVM implementation

One entry per choice that `spec/01`–`06` plus `chains/evm.md` did not determine. Tags:
`[ABI]` public-surface shape, `[BEHAVIOUR]` observable behaviour, `[INTERNAL-NAME]` naming/organisation
of internals, `[TEST-TECHNIQUE]` how a required test condition is exercised.

1. `[INTERNAL-NAME]` Module split and file names. The overlay only requires `src/DataFeedsCache.sol`,
   `src/DataFeedsProxy.sol` and "shared pieces under `src/`". Chosen: `src/DataFeedsTypes.sol` (file-level
   structs/enum + `DECIMALS`), `src/Errors.sol` (custom errors + `CacheErrors`/`ProxyReadErrors`/
   `OwnableErrors` constant libraries), `src/lifecycle/Ownable.sol`, `src/lifecycle/TokenRecoverable.sol`,
   `src/libraries/RetentionWindow.sol`, `src/libraries/ReportCodec.sol`, `src/libraries/PermissionHash.sol`,
   `src/interfaces/IDataFeedsCacheReader.sol`, `IDataFeedsCache.sol`, `IDataFeedsProxy.sol`. Private helper
   names (`_record`, `_probe`, `_enforceFeedAdmin`, `_enforceOwner`, `_scale`, …) are mine.

2. `[ABI]` Declaration placement: structs, the `Bound` enum and the custom errors are file-level
   declarations; events are declared in the interfaces (`IDataFeedsCache`, `IDataFeedsProxy`, `Ownable`,
   `TokenRecoverable`). The emitted ABI (names, types, field order, `indexed` flags) is identical whatever
   the placement; only the source organisation was open.

3. `[ABI]` State mutability: every reader is `view` (spec 06 C.3 makes lifetime refreshes no-ops, so readers
   are pure reads); `version()`/`typeAndVersion()` are `pure`; nothing is `payable`.

4. `[ABI]` The Proxy's `latestRound(dataId, decimals)` / `getRound(dataId, roundId, decimals)` parameter
   `decimals` shadows the `decimals(bytes32)` function. The argument name is normative, so the parameter
   is kept and the compiler's shadowing warning (8760) is accepted. `min` (in `setMinDecimals`) is not a
   reserved word and is kept as-is.

5. `[ABI]` The Proxy's frozen failure is `revert CacheError(109)` — the Cache's error *family* carrying
   `FeedFrozen`, not a `ProxyReadError`. Spec 03 says the Proxy fails "with the Cache's `FeedFrozen`
   (109)" and spec 06 E.1 keeps one typed error per family, so the Cache family is the carrier.

6. `[BEHAVIOUR]` `now` is `uint32(block.number)` (truncating cast, spec 06 C.5) for **both** the retention
   window / `ledgerSeq` and the ownership offer comparisons (`live_until_ledger` is u32 in blocks). No upper
   "offer horizon" bound is applied to `live_until_ledger` (spec 06 J: "where one exists" — the EVM has
   none), so any value `>= now` up to `type(uint32).max` is accepted.

7. `[BEHAVIOUR]` Presence of a pending ownership offer is `_pendingLiveUntilLedger != 0` (spec 06 B.2
   "a field that is never zero for a written record": `0` selects the cancel branch, so a stored offer always
   has a non-zero ledger). `new_owner` is not validated (spec silent): an offer to `address(0)` is recorded
   like any other.

8. `[BEHAVIOUR]` Constructor `owner` is stored without validation (spec silent). `_setOwner` raises
   `OwnerAlreadySet` (2102) only when an owner is already recorded, which is unreachable through the
   public interface (spec 06 J). Constructing with `owner = address(0)` yields "no owner recorded", so
   owner-only calls then fail with 2100.

9. `[BEHAVIOUR]` `recoverTokens` return-data interpretation. The overlay names three failure forms (revert,
   `false`, no code at `token`). Realised as: `token.code.length == 0` → `TokenTransferFailed`; the transfer
   is made with a low-level `call` so a token revert maps to `TokenTransferFailed` instead of bubbling;
   empty return data → success (a token that returns nothing signals no failure); return data ≥ 32 bytes
   → success iff the first word is non-zero; return data of 1–31 bytes → `TokenTransferFailed`. No other
   validation (amount, balance, `to`) is added.

10. `[BEHAVIOUR]` Strict report decoding (spec 06 F.2; overlay: "strict decode; trailing bytes →
    `MalformedReport`") is a hand-written canonical decoder, `ReportCodec.decodeReport`: the head offset
    word must be exactly `0x20`, the byte length must be exactly `64 + 96·n`, and every `timestamp` word
    must fit in `uint64`. Any deviation (undecodable, truncated, trailing, non-canonical) returns
    `MalformedReport` (100). `abi.decode` was not used because it neither rejects trailing bytes nor
    returns an error (it reverts without data), and wrapping it in `try/catch` would have required an extra
    external function on the ABI.

11. `[BEHAVIOUR]` `setFeedConfigs` write path: Solidity cannot copy a `WorkflowPermission[] calldata` into
    storage in one statement, so the stored permission array is cleared and re-pushed element by element.
    A permission present in both the old and the new list is deleted and re-set within the same call. No
    externally observable difference.

12. `[BEHAVIOUR]` Proxy `setCache(cache)` stores any address without validation (spec silent). If the
    address has no code, subsequent reads fail with the EVM's native call failure (no spec code).

13. `[INTERNAL-NAME]` Where the storage layout is documented (spec 06 I.4 requires it; the overlay does not
    say where): NatSpec on each contract plus the "Storage layout" section of `README.md`. The pending
    offer fields are packed into slot 1 of `Ownable`.

14. `[TEST-TECHNIQUE]` spec 05 "`on_report`: sender without host authorisation (host) fails" cannot occur on
    the EVM — the caller is always authenticated as itself. Covered instead by
    `test_onReport_senderIsCaller_otherCallerIsNotPermitted`: the sender identity is `msg.sender`, so a
    different caller is soft-skipped with its own address in `InvalidUpdatePermission`.

15. `[TEST-TECHNIQUE]` Lifetime-refresh conditions ("the call refreshes the instance / entry lifetime") are
    tested as persistence (spec 06 C.3): after the call, `vm.roll` far ahead and assert the records (owner,
    config, permissions, state, admin, `MinDecimals`, cache address) are still present.

16. `[TEST-TECHNIQUE]` "Expiry" conditions (tip survives the expiry of its round entry; a non-tip round does
    not; `find_round` returns the tip after history expires) are emulated by `vm.roll` past
    `ledgerSeq + 3_110_400`, i.e. exclusion from the retention window, since nothing is ever deleted on the
    EVM (overlay: "cover the window with `vm.roll` past `ledger_seq + round_ttl`").

17. `[TEST-TECHNIQUE]` The retention-window conditions that vary the TTL / network maximum are tested
    directly against the `RetentionWindow` library (`test/RetentionWindow.t.sol`, internal functions linked
    into the test contract) with a small `ttl` (1000) standing in for `round_ttl`. The "network maximum
    below the network's minimum entry lifetime" condition does not apply (spec 06 C.3).

18. `[TEST-TECHNIQUE]` Self-upgrade conditions (spec 06 I.4): no upgrade step exists.
    `test_upgrade_noUpgradeEntryPointExists` (Cache) and
    `test_upgrade_noUpgradeEntryPointExists_routingIsImmutableCode` (Proxy) assert that calling the
    `upgrade(bytes32)` selector — and any unknown selector — reverts (no such function, no fallback). The
    "survives a self-upgrade" / resurrection / cache-swap conditions run without the upgrade step.

19. `[TEST-TECHNIQUE]` "Reads never create a `MinDecimals` entry" and "reads never write" are asserted with
    `vm.record()` / `vm.accesses()` showing zero storage writes during reads — the public interface alone
    cannot distinguish "absent" from "present with value 18".

20. `[TEST-TECHNIQUE]` "Only"/"exactly" event conditions are asserted with `vm.recordLogs()` filtered by
    emitter address and counted, in addition to `vm.expectEmit` for the exact fields. Atomicity on revert is
    asserted via state (recorded logs are not rolled back in Foundry).

21. `[TEST-TECHNIQUE]` Test doubles: `test/mocks/MockDataFeedsCache.sol` implements `IDataFeedsCacheReader`
    with injectable latest/rounds/frozen/decimals/description and a forced `CacheError(code)`
    (`roundRange`/`findRound` unimplemented — the Proxy never calls them); `test/mocks/MockERC20.sol`
    provides a standard token plus returns-`false`, reverting and no-return-data variants for
    `recoverTokens`.
