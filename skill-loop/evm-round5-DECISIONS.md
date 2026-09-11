# Decision log — DataFeedsCache / DataFeedsProxy on the EVM (`df-gen/evm-5`)

Format per `SKILL.md` step 6: one entry per choice that `spec/` + `chains/evm.md` did not
determine. Tags: `[ABI]`, `[BEHAVIOUR]`, `[INTERNAL-NAME]`, `[TEST-TECHNIQUE]`.
Phase 0 did not run (`chains/evm.md` existed). Every `[ABI]`/`[BEHAVIOUR]` entry has been
written back into `chains/evm.md` (step 7).

## [ABI]

- **[ABI] A1 — error-name constants are not public.** `spec/06` E.2 says names are "kept as
  constants" but not their visibility. They are `internal` constants of the libraries
  `CacheErrors`, `ProxyReadErrors`, `OwnableErrors` (spec spelling: `MalformedReport = 100`, …,
  `OwnerNotSet = 2100`, …). No public getter is generated ("do nothing extra"; K.3 already keeps
  `DECIMALS`/`DATA_RETENTION_TTL` out of the ABI — both are `internal constant`).
- **[ABI] A2 — one file-scope declaration per custom error.** `CacheError(uint32)` is declared at
  file scope in `src/interfaces/IDataFeedsCache.sol`, `ProxyReadError(uint32)` in
  `src/interfaces/IDataFeedsProxy.sol`, `OwnableError(uint32)` and `Unauthorized(address)` in
  `src/lifecycle/Ownable.sol`, `TokenTransferFailed(address)` in
  `src/lifecycle/TokenRecoverable.sol`. The Proxy imports `CacheError` and reverts with
  `CacheError(109)` for a frozen feed, so the selector is byte-identical to the Cache's family
  (E.3) and the Proxy's ABI lists `CacheError` as well.
- **[ABI] A3 — `getOwner()` returns `address`**, `address(0)` meaning `None` (the overlay's
  "optional address = `address(0)`" applied to a return value).
- **[ABI] A4 — ownership event spellings.** The snake_case library events become
  `OwnershipTransfer(address oldOwner, address newOwner, uint32 liveUntilLedger)`,
  `OwnershipTransferCompleted(address newOwner)`, `OwnershipRenounced(address oldOwner)` under
  the overlay's mechanical camelCase rule; none has `indexed` fields (spec/06 J). `TokenRecovered`
  and `CacheSet` likewise have no `indexed` fields.
- **[ABI] A5 — mutability.** Every reader on both contracts is `view` (spec/06 C.3 makes the
  lifetime-refresh prologue a no-op, so readers are pure reads); `version()` and
  `typeAndVersion()` are `pure`. Readers return bare values (G.2): `isFrozen` → `bool[]`,
  `latestRound` → `OptionalRoundData[]`, etc. — there is no `Result` wrapper on the EVM.
- **[ABI] A6 — the Proxy's precision argument is named `decimals`** (spec spelling) on
  `latestRound(bytes32 dataId, uint32 decimals)` and `getRound(bytes32 dataId, uint64 roundId,
  uint32 decimals)`, shadowing the `decimals(bytes32)` function inside those bodies (compiler
  warning only). Argument names are ABI, so the spec spelling wins over the shadowing lint.
- **[ABI] A7 — `Bound` is `enum Bound { AtOrBefore, AtOrAfter }`** (`uint8` `0`/`1` on the wire).
  A value above `1` fails ABI decoding with a Solidity panic — a host failure, no spec code.
- **[ABI] A8 — where the shared types live.** `RoundData`, `WorkflowPermission`, `FeedConfig`,
  `FeedConfigEntry`, `ReportEntry`, `OptionalRoundData`, `OptionalU32`, `OptionalString`, `Bound`
  are file-scope declarations in `src/interfaces/IDataFeedsCache.sol` (field names/order as in
  the spec, camelCased); `Round` in `src/interfaces/IDataFeedsProxy.sol`. `FeedState`, `Window`,
  `Metadata` and `PendingTransfer` are internal and not on the ABI (no spec function returns them).
- **[ABI] A9 — constructors.** `DataFeedsCache(address owner)` and
  `DataFeedsProxy(address owner, address cache)`; neither argument is validated (spec silent):
  an `address(0)` owner yields an ownerless contract (owner-only calls fail `OwnableError(2100)`),
  an `address(0)`/code-less cache makes every feed read fail as a host failure (empty revert).
- **[ABI] A10 — storage layout (documented per spec/06 B.4).** Cache: slot 0 `s_owner`
  (`address`), slot 1 `s_pending` (`address newOwner` + `uint32 liveUntilLedger`, packed), slot 2
  `s_feedAdmins` (`mapping(address => bool)`), slot 3 `s_feedConfigs` (`mapping(bytes32 =>
  FeedConfig)`), slot 4 `s_permissions` (`mapping(bytes32 => mapping(bytes32 => bool))`), slot 5
  `s_feedStates` (`mapping(bytes32 => FeedState{RoundData latestRound; Window window; bool
  frozen})`), slot 6 `s_rounds` (`mapping(bytes32 => mapping(uint64 => RoundData))`). Proxy: slot
  0 `s_owner`, slot 1 `s_pending`, slot 2 `s_minDecimals` (`mapping(bytes32 => OptionalU32)`),
  slot 3 `s_cache` (`address`). Contracts are immutable (I.3), so this is informational.

## [BEHAVIOUR]

- **[BEHAVIOUR] B1 — pending-offer presence flag.** The pending ownership offer is present iff
  its stored `liveUntilLedger != 0` (spec/06 B.2: a field that is never zero for a written
  record — `0` is the cancel branch and an offer below `now` is rejected). Consequently
  `transferOwnership(address(0), n)` is accepted (spec validates nothing about `new_owner`) and
  stores an offer nobody can accept; cancelling it needs `transferOwnership(address(0), 0)`.
- **[BEHAVIOUR] B2 — `recoverTokens` success criterion.** The overlay lists revert / `false` /
  no code. Concretely: `token.code.length == 0` → `TokenTransferFailed(token)` before any call;
  then `token.call(transfer(to, amount))`; the call is a success iff it did not revert **and**
  its return data is either empty (non-standard tokens that return nothing) or exactly 32
  bytes decoding to `true`. Any other return data (including `false` and malformed lengths) →
  `TokenTransferFailed(token)`. `TokenRecovered` is emitted after the transfer.
- **[BEHAVIOUR] B3 — strict report decoder, never a trap.** The report is decoded by a
  hand-written strict decoder (`src/libraries/ReportCodec.sol`), not `abi.decode`, so every
  failure maps to `CacheError(100)` (spec/06 F.2 "unless the decoder traps" — it does not):
  length `< 64`, head offset word `!= 32`, `length != 64 + 96 * count`, trailing bytes, or a
  `timestamp` word above `type(uint64).max`. Answer words are taken verbatim as `int256`; data
  ids are not validated (a mis-sized/unknown id is soft-skipped). Metadata is checked for
  length 64 **before** the report body (spec order; both are `100`).
- **[BEHAVIOUR] B4 — sequence unit.** `ledger_seq`, the window's `now` and ownership's `now`
  are all `uint32(block.number)` (truncating cast, spec/06 C.5); `round_ttl` is the constant
  `DATA_RETENTION_TTL = 1_296_000` (network maximum unbounded, C.3).
- **[BEHAVIOUR] B5 — owner-gating order.** Every owner-only function checks `OwnerNotSet`
  (2100) first, then `msg.sender == owner` (else `Unauthorized(msg.sender)`); `acceptOwnership`
  checks 2200 → 2203 → `Unauthorized(msg.sender)`; `transferOwnership(_, 0)` checks 2200 → 2202.
  `liveUntilLedger == now` is accepted (`< now` is the 2201 condition). The EVM has no maximum
  offer horizon (J's "where one exists" clause is empty).
- **[BEHAVIOUR] B6 — `renounceOwnership` discards an expired offer** (deletes it) as part of
  succeeding; an unexpired offer (`now <= liveUntilLedger`) is `TransferInProgress` (2101).
- **[BEHAVIOUR] B7 — "sender without host authorisation (host) fails" is not realisable.**
  Under spec/06 A.2 the sender *is* `msg.sender`; there is no argument to prove. The
  corresponding guarantee on the EVM is that no caller can name another sender: a
  non-permitted caller's report is soft-skipped with `InvalidUpdatePermission{…, sender:
  msg.sender, …}` (test `test_onReport_callerIsTheSender_noSpoofing`).
- **[BEHAVIOUR] B8 — conditions not applicable, with the rule.** `upgrade` swaps code /
  self-upgrade keeps data / proxy self-upgrade keeps routing → spec/06 I.3 (no entry point;
  tested as resurrection and cache-swap without an upgrade step, plus a runtime probe that the
  `upgrade(bytes32)` selector is not callable). "Network maximum below the network's minimum
  entry lifetime" and the TTL-varying window conditions through the public interface → C.3
  (tested against `RetentionWindow` directly via a harness). Every "refreshes the … lifetime"
  condition → C.3 (asserted as persistence after `vm.roll(+10_000_000)`). "The tip's temporary
  round entry has expired" → rounds are never deleted on the EVM; asserted as the tip being
  readable after the retention window has passed while non-tip rounds are masked.
- **[BEHAVIOUR] B9 — Proxy with a code-less Cache.** A feed read on a Proxy whose stored cache
  has no code reverts with empty revert data (Solidity's extcodesize check on a high-level call)
  — a host failure, never a spec code. `getCache`/`getMinDecimals` still answer.
- **[BEHAVIOUR] B10 — `setFeedConfigs` rewrite mechanics.** For an existing config every old
  `Permission` is deleted, the `FeedConfig` slot is `delete`d and repopulated, then every new
  `Permission` is set; a permission present in both lists is therefore deleted and re-set within
  the call (net effect: present). Not externally observable.
- **[BEHAVIOUR] B11 — `roundRange` reads the tip from `FeedState`**, not from the round store,
  for `id == tip`; all other ids come from the store and are masked by the window (spec/04 "the
  tip is always readable without consulting the round store or the window"). `findRound`
  probes use the same rule.

## [INTERNAL-NAME]

- Files: `src/interfaces/IDataFeedsCache.sol`, `src/interfaces/IDataFeedsProxy.sol`,
  `src/lifecycle/IVersioned.sol`, `src/lifecycle/Ownable.sol`, `src/lifecycle/TokenRecoverable.sol`,
  `src/libraries/RetentionWindow.sol`, `src/libraries/ReportCodec.sol`,
  `src/libraries/PermissionHash.sol`, `src/DataFeedsCache.sol`, `src/DataFeedsProxy.sol`.
- Interfaces `IDataFeedsCache` (events + functions), `IDataFeedsProxy`, `IVersioned`; abstract
  contracts `Ownable`, `TokenRecoverable`; libraries `RetentionWindow`, `ReportCodec`,
  `PermissionHash`, `CacheErrors`, `ProxyReadErrors`, `OwnableErrors`.
- Storage variables `s_owner`, `s_pending`, `s_feedAdmins`, `s_feedConfigs`, `s_permissions`,
  `s_feedStates`, `s_rounds`, `s_minDecimals`, `s_cache`; internal struct `Metadata
  {workflowCid, workflowName, workflowOwner, reportId}` and `Ownable.PendingTransfer`.
- Helpers: `_setOwner`, `_enforceOwner`, `_now`, `_enforceFeedAdmin`, `_record`, `_readRound`,
  `_roundTtl`, `_hasState`, `_isConfigured`, `_deletePermissions`, `_hashOf`,
  `_permissionEquals`, `_effectiveMin`, `_validateDecimals`, `_frozenCheck`, `_scale`, `_single`;
  `RetentionWindow.widthAt/isReadable/initial/next`; `ReportCodec.decodeMetadata/decodeReport`;
  `PermissionHash.compute`.

## [TEST-TECHNIQUE]

- Window conditions that vary the TTL run against `test/harness/WindowHarness.sol`, a thin
  wrapper over the `RetentionWindow` library (`test/RetentionWindow.t.sol`).
- Proxy unit tests use `test/mocks/MockCache.sol`: injectable latest/rounds/frozen/decimals/
  description and `setForcedRevert(bytes)` that makes every reader revert with arbitrary data —
  used both for "a Cache error traps the read with the Cache's code" and for "invalid precision
  fails before the Cache is consulted" (the forced revert must *not* surface).
- "Reads never write / never create `MinDecimals`": `vm.record()` + `vm.accesses(proxy)` assert
  zero storage writes across all readers, plus `getMinDecimals` staying at 18.
- Events: `vm.recordLogs()` filtered by `emitter` for "only"/count/order assertions (the `emit`
  paired with `vm.expectEmit` is itself a recorded log of the test contract, so filtering is
  required); `vm.expectEmit(true,true,true,true, emitter)` for exact-field assertions; raw
  `topics`/`data` compared with `abi.encode(...)` for the Cache events.
- "No `upgrade` entry point": a low-level call to the `upgrade(bytes32)` selector must fail.
- Lifetime-refresh conditions are asserted as persistence after `vm.roll(block.number + 10_000_000)`.
- `test/mocks/MockERC20.sol` has modes `Normal`, `ReturnFalse`, `Revert`, `ReturnNothing` to cover
  every `recoverTokens` outcome; the "no code" case uses a fresh address.
- `findRound` is additionally checked on a 40-round history against a closed-form expectation
  for both bounds at many probe timestamps.
- Host failures are asserted with `vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector,
  caller))`; spec codes with `CacheError.selector` / `ProxyReadError.selector` / `OwnableError.selector`.

## Counts

`[ABI]` 10 · `[BEHAVIOUR]` 11 · `[INTERNAL-NAME]` 4 entries · `[TEST-TECHNIQUE]` 9. Tests: 189
across 10 suites (`forge test`: 189 passed, 0 failed, 0 skipped). Phase 0: did not run.
