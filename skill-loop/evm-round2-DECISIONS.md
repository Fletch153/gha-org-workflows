# Decision log — Chainlink Data Feeds (Cache + Proxy) on the EVM

One entry per choice that `spec/01`–`06` plus `chains/evm.md` did not determine. Format: **what was
open → what was chosen → why**. Everything not listed here is taken verbatim from the spec/overlay.

## Naming of things the spec leaves unnamed

1. **Optional struct names.** The overlay prescribes the shape `{bool present; T value;}` but not the
   struct names → `OptionalRoundData`, `OptionalU32`, `OptionalString` (`src/Types.sol`). The field
   names `present`/`value` are the overlay's.
2. **Error-constant containers.** "Names as constants" → three internal-constant libraries
   `CacheErrors`, `ProxyReadErrors`, `OwnableErrors` in `src/Errors.sol`; constant names are the spec's
   error names unchanged (K.1 says error/enum/constant names are not case-converted, so they are
   PascalCase and trigger forge-lint style notes, which are ignored).
3. **Shared-lifecycle module names.** Abstract contracts `Ownable` (ownership table) and
   `TokenRecoverable` (`recoverTokens`), and interface `IVersioned` (`version`/`typeAndVersion`).
   Interfaces `IDataFeedsCacheReader/Writer/Admin` (+ `IDataFeedsCache`) and
   `IDataFeedsProxyReader/Admin` (+ `IDataFeedsProxy`) mirror the spec's function groups. None of these
   names are ABI.
4. **Public argument `decimals` shadows the `decimals` function on the Proxy.** Argument names are
   normative, so the two solc shadowing warnings (`DataFeedsProxy.latestRound`/`getRound`) are accepted
   rather than renaming; internal helpers use `requested` to avoid further noise.

## Storage representation

5. **`MinDecimals` presence.** B.2 wants a never-zero field for presence, but `0` is a valid minimum
   (`set_min_decimals(id, 0)` is legal) → stored as `OptionalU32 {present, value}` in the mapping.
6. **`FeedConfig` overwrite.** Solidity cannot copy a calldata struct with a nested dynamic struct array
   into storage in one assignment → the config is rewritten field-wise (`delete` old permission list,
   set description, `push` each new permission). Observationally identical to a single overwrite.
7. **"now" for the retention window** and for ownership expiry is `uint32(block.number)` — the same
   truncating cast C.5 prescribes for `ledger_seq`, so both sides of the comparison share one unit.

## Ownership table (overlay: no library, "implement the table")

8. **Owner gating order.** `OwnerNotSet` (2100) is checked before the caller comparison, so an
   owner-gated call with no owner fails with the code (J.1) and any other caller fails
   `Unauthorized(caller)`.
9. **Ownership event topics.** `spec/01` gives topic fields for Cache/Proxy events but not for the
   ownership events → `OwnershipTransfer`, `OwnershipTransferCompleted`, `OwnershipRenounced` carry all
   fields as data (no `indexed`), like `Upgraded`/`TokenRecovered` which are stated to have none.
10. **`InvalidLiveUntilLedger` (2201)** is raised by `transferOwnership` when `liveUntilLedger != 0` and
    `liveUntilLedger < uint32(block.number)` (an offer that would already be expired).
11. **`InvalidPendingAccount` (2202)** is raised by `transferOwnership(address(0), liveUntil != 0)`:
    `address(0)` is the "absent" optional address (overlay, axis G), so it cannot be a pending owner.
12. **Cancel semantics.** `transferOwnership(x, 0)` always clears the pending slot (also when none is
    pending) and emits `OwnershipTransfer{owner, x, 0}` with `x` as passed.
13. **`acceptOwnership` check order.** `NoPendingTransfer` (2200) → caller ≠ pending →
    `Unauthorized(caller)` (host) → `TransferExpired` (2203) when `block.number > liveUntil` (valid
    through `liveUntil` inclusive, J.1).
14. **`OwnerAlreadySet` (2102)** is guarded in the internal `_setOwner` helper (mirrors a library
    `set_owner`); it is unreachable from the constructors and defined for table completeness.
15. **`renounceOwnership`** fails `TransferInProgress` only while an *unexpired* offer exists; an expired
    offer is left in place (nothing extra is cleared).

## `recover_tokens`

16. **Transfer failure handling.** "Transfers `amount`" is realised as a low-level `transfer(to, amount)`
    call that must succeed, must target an address with code, and must not return `false`; otherwise
    the call reverts with a dedicated `TokenTransferFailed(address token)` error (a host-style error
    outside all numeric ranges, since the spec assigns no code). Return-data-less tokens are accepted.

## Report decoding

17. **Strict decoder implementation.** Solidity's `abi.decode` reverts with empty data on malformed
    input, which cannot be mapped to `MalformedReport` (100) without an external self-call. A manual
    strict decoder (`src/libraries/ReportDecoder.sol`) accepts exactly `abi.encode(ReportEntry[])`:
    head offset `0x20`, total length `64 + n·96`, `timestamp` words `< 2^64`; anything else (undecodable,
    truncated, non-canonical, trailing bytes) is `MalformedReport`. A fuzz test asserts agreement with
    `abi.decode` and byte-for-byte round-tripping on canonical input.
18. **Permission hash.** `abi.encode(sender) ‖ abi.encode(owner) ‖ abi.encode(name)` is byte-identical
    to `abi.encode(sender, owner, name)` (three static words), so the latter is used.

## Toolchain

19. **`lint_on_build`.** forge 1.5.1 reads this key from the `[lint]` section, not `[profile.default]`;
    it is set there. `optimizer = true`, `optimizer_runs = 200`, `evm_version = "cancun"` are chosen
    (the overlay is silent); the Cache is 13.3 KB and the Proxy 5.7 KB of runtime code.

## Test conditions that cannot be exercised on the EVM (and what stands in)

20. **Upgrade conditions** (self-upgrade keeps data, upgrade to a distinct artifact, proxy self-upgrade)
    do not apply (I.3: no `upgrade`). A test asserts the `upgrade(bytes32)` selector does not exist; the
    resurrection and cache-swap conditions are covered without the upgrade step.
21. **Lifetime-refresh conditions** ("refreshes the instance/config/permission/state/MinDecimals
    lifetime") are vacuous (C.3). Tests named for them assert the only observable EVM property: the
    records remain present and readers are `view` (callable via `staticcall`).
22. **TTL-varying window conditions** (shrinks when the network maximum drops, grows at
    `grow_at_ledger`, second change replaces the plan, lock-in after the grow date, raised TTL reaches
    only new rounds) cannot be reached through the public interface because `round_ttl` is the constant
    `DATA_RETENTION_TTL`. The window arithmetic is implemented in full and tested directly in
    `test/RetentionWindow.t.sol` (allowed by `spec/05`); the public-interface tests cover expiry via
    `vm.roll` past `ledger_seq + round_ttl`, same-ledger writes sharing the window, and the saturating
    early-chain case.
23. **"`on_report` sender without host authorisation (host) fails"** is vacuous under A.2 (the caller is
    always its own authorised sender); the stand-in test shows an unpermitted caller is soft-skipped
    with `InvalidUpdatePermission{sender = caller}`.
