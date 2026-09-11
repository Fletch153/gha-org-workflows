# Decision log — DataFeedsCache / DataFeedsProxy on the EVM

One entry per choice that `spec/01`–`06` plus `chains/evm.md` did not determine. Everything
else (names, codes, check orders, event shapes, storage keys, toolchain) is taken verbatim
from the spec and the overlay. Tags: `[ABI]` visible on the public interface;
`[BEHAVIOUR]` observable behaviour; `[INTERNAL-NAME]` a name of an internal helper/file;
`[TEST-TECHNIQUE]` how a test condition is realised.

1. `[ABI]` **Name of the host-style token-failure error.** Spec 06 K.2 requires that a token
   which reverts, returns `false`, or has no code fails `recoverTokens` "with a host-style
   error type outside all numeric ranges" but names none (the overlay names only
   `Unauthorized(address)`). Chosen: `error TokenTransferFailed(address token)` in
   `src/lib/Errors.sol`. It carries no numeric code.

2. `[BEHAVIOUR]` **`now` for ownership uses the truncated `uint32(block.number)`.** Spec 06 J
   says `now` is "the platform sequence unit of C.5", and C.5 says the sequence is stored at the
   spec width by truncating cast. `live_until_ledger` is `u32`, so all ownership comparisons are
   done on `uint32(block.number)`, the same `_ledger()` value the Cache stores as `ledgerSeq`.
   (Only observable if a chain's block number ever exceeds 2^32.)

3. `[BEHAVIOUR]` **`acceptOwnership` check order.** Spec 06 J lists: no pending offer (2200),
   then expiry (2203), then host-authorise the pending address. Implemented in exactly that
   order, so a wrong caller on an expired offer sees 2203 rather than `Unauthorized`. Recorded
   because the table does not state it is normative for the EVM's `Unauthorized` case.

4. `[BEHAVIOUR]` **`DECIMALS` and `DATA_RETENTION_TTL` are file-level `internal` constants, not
   public getters.** The spec reports `DECIMALS` only through `decimals(...)`/`FeedConfigSet`;
   exposing a `DECIMALS()` getter would add an ABI function the spec does not list.

5. `[BEHAVIOUR]` **Strict report decoder is hand-written, not `abi.decode`.** Solidity's
   `abi.decode` ignores trailing bytes, so the overlay's "strict decode; trailing bytes →
   MalformedReport" cannot be met with it. `_decodeReport` checks: length ≥ 64, head offset word
   == 32, `length == 64 + n·96`, and every `uint64` timestamp word has clean upper bits; any
   violation reverts `CacheError(100)`. This realises spec 06 F.2 ("undecodable, truncated,
   non-canonical or trailing bytes are a decode failure"). Because the decoder never traps, the
   "platform decoder trap" alternative does not arise on the EVM.

6. `[INTERNAL-NAME]` **Module split under `src/`.** `Lifecycle.sol` (abstract: ownership per
   spec 06 J, `recoverTokens`, `version`), `interfaces/IDataFeedsCache.sol` (the Cache's public
   surface, used by the Proxy per overlay L), `interfaces/IERC20Minimal.sol` (`transfer` only),
   `lib/Types.sol` (structs, enum, constants), `lib/Errors.sol` (error families + code-name
   libraries `CacheErrors`, `ProxyReadErrors`, `OwnableErrors`), `lib/RetentionWindow.sol`
   (spec 04 window arithmetic: `widthAt`, `isReadable`, `initial`, `next`). Private helpers
   inside the contracts (`_record`, `_readableRound`, `_permissionHash`, `_decodeReport`,
   `_decodeMetadata`, `_requireFeedAdmin`, `_requireOwner`, `_scale`, `_effectiveMin`,
   `_requireNotFrozen`, `_single`) are likewise mine.

7. `[INTERNAL-NAME]` **`MinDecimals` storage reuses the `OptionalU32` struct** as the
   `{present, value}` record spec 06 B.2 requires for that key. Not observable on the ABI.

8. `[TEST-TECHNIQUE]` **"host" condition for `on_report`'s sender.** On a caller-identity chain
   there is no `sender` argument, so "sender without host authorisation fails" cannot be
   triggered — a caller *is* the sender. It is covered by
   `test_onReport_senderIsCallerIdentity_unlistedCallerCannotImpersonate`: an unlisted caller
   is soft-skipped with its own identity in `InvalidUpdatePermission` and cannot claim the
   permitted sender's identity.

9. `[TEST-TECHNIQUE]` **Lifetime-refresh conditions are tested as persistence** (spec 06 C.3):
   after the call, `vm.roll` far past `DATA_RETENTION_TTL` and assert the records are still
   present. TTL-varying window conditions (shrink/grow/replace plan/lock-in/saturation) are
   tested directly against `RetentionWindow` in `test/RetentionWindow.t.sol`; the "network
   maximum below the minimum entry lifetime" condition does not apply and has no test.

10. `[TEST-TECHNIQUE]` **Self-upgrade conditions.** Per spec 06 I.3/I.4 the resurrection and
    cache-swap conditions are tested without the upgrade step, and
    `test_upgrade_entryPointDoesNotExist` (both contracts) asserts a call to `upgrade(bytes32)`
    fails, including from the owner.

11. `[TEST-TECHNIQUE]` **Event "only" assertions** use `vm.recordLogs` filtered by emitter,
    checking count, selector, indexed topics and decoded data; atomicity of failed batches is
    asserted via state (overlay: recorded logs are not rolled back on revert).

12. `[TEST-TECHNIQUE]` **Mock Cache for Proxy tests** (`test/helpers/MockDataFeedsCache.sol`)
    implements `IDataFeedsCache` with scriptable answers and a `setRevertCode(code, onIsFrozen)`
    switch to prove Cache revert data bubbles through the Proxy unchanged.
