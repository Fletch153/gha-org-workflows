# Decision log — Chainlink Data Feeds on the EVM (Solidity / Foundry)

One entry per choice that `spec/` plus `chains/evm.md` did not determine. Format: **Q**
(question, quoting the triggering spec text), **Options**, **Chose**, **Why**, **Rule** (the
chain-agnostic sentence that would have made the choice deterministic).

---

## 1. Host authorisation ("host-authorise `x`")

- **Q** — spec/01: "Host authorisation — the caller must prove they are `X` … Failure is a
  chain-level authorisation failure, not a contract error code." The EVM has no per-argument
  auth; `on_report(sender, …)` and the admin functions carry the authorised address as an
  argument.
- **Options** — (a) drop the `sender`/`admin` argument and use `msg.sender`; (b) keep the
  argument and require `msg.sender == x`; (c) signature-based authorisation of `x`.
- **Chose** — (b). Every "host-authorise `x`" is `msg.sender == x`, otherwise revert with the
  custom error `HostAuthorizationFailed(address required, address caller)`
  (`src/lifecycle/HostAuth.sol`). The arguments stay on the ABI with their spec names.
- **Why** — argument names are normative ABI; `msg.sender` is the only proof of identity the
  EVM offers; a dedicated custom error outside every numeric range keeps host failures
  distinguishable from contract errors, as the spec requires. (c) adds a feature.
- **Rule** — "Host-authorising `x` means the platform's caller identity must equal `x`; on
  chains without per-argument authorisation the argument is kept and compared to the caller,
  and a mismatch fails with a platform-level (non-numeric) error."

## 2. Ownership module (no EVM library named)

- **Q** — spec/01: "The overlay names the library that provides ownership; use it rather than
  re-implementing." The EVM overlay names none ("No other dependency is mandated").
- **Options** — (a) OpenZeppelin `Ownable2Step` (no `live_until_ledger`, no numeric codes, no
  renounce-while-pending rule); (b) implement the spec's table directly in `src/lifecycle/Ownable.sol`.
- **Chose** — (b), with exactly the behaviour listed in spec/01: codes `OwnerNotSet = 2100`,
  `TransferInProgress = 2101`, `OwnerAlreadySet = 2102`, and one pending-transfer fault in the
  2200 range, `NoPendingTransfer = 2200` (raised by `accept_ownership` when no offer is
  pending or the offer expired). All raised as `OwnableError(uint32 code)`.
- **Why** — no library reproduces the spec's semantics; a direct realisation is smaller than
  adapting one and keeps the numeric codes.
- **Rule** — "If the overlay names no ownership library, implement the ownership table of
  spec/01 verbatim with the codes 2100–2102 and a single 2200 code for a missing/expired
  pending offer."

## 3. Pending-offer expiry, cancellation and `OwnerNotSet`

- **Q** — spec/01: "records a pending offer that expires at `live_until_ledger`";
  "`transfer_ownership` with `live_until_ledger = 0` cancels a pending transfer";
  "`renounce_ownership` fails only while a pending transfer is *unexpired*". Inclusive or
  exclusive expiry? Does a cancel emit? What happens to owner-only calls after renounce?
- **Options** — expiry inclusive (`block.number <= live_until`) vs exclusive; cancel emits
  `ownership_transfer{…, 0}` vs silent; owner-only after renounce → host failure vs `OwnerNotSet`.
- **Chose** — an offer is live while `block.number <= live_until_ledger`; a cancel emits
  `ownership_transfer { old_owner, new_owner, 0 }` (the function "emits" unconditionally in
  the spec); a non-zero `live_until_ledger` in the past is accepted as an already-expired
  offer (no extra validation); owner-only entry points after renounce revert
  `OwnableError(2100)`; `accept_ownership` checks that a live offer exists (else 2200) and
  then host-authorises the pending owner.
- **Why** — "expires at L" reads most naturally as "still valid at L"; the spec never lists
  a cancel-specific event; `OwnerNotSet` is the listed code for the no-owner condition.
- **Rule** — "A pending offer is valid through `live_until_ledger` inclusive; every
  `transfer_ownership` call emits `ownership_transfer`; owner-gated calls with no owner fail
  with `OwnerNotSet`."

## 4. Ownership event topic layout

- **Q** — spec/01 lists ownership events as `ownership_transfer { old_owner, new_owner,
  live_until_ledger }` etc. without the topic/data split used elsewhere.
- **Options** — all fields as data; or index the addresses.
- **Chose** — all fields non-indexed (data).
- **Why** — the other tables mark topics explicitly; absence of marking means no topics.
- **Rule** — "An event whose table gives no topic fields has none."

## 5. `get_owner() -> Option<Address>`

- **Q** — spec/01: "`get_owner() -> Option<Address>` — current owner, `None` after renounce."
- **Options** — wrapper struct `{present, value}`; `address(0)` as `None`.
- **Chose** — `address(0)` means `None`.
- **Why** — idiomatic on the EVM; the zero address can never act as an owner (it cannot be
  `msg.sender`), so the encoding loses nothing.
- **Rule** — "An optional address is encoded as the zero address when absent."

## 6. Error signalling (numeric codes)

- **Q** — spec/01: "Error codes: Cache uses 100–199, Proxy uses 50–99, ownership library
  2100–2299." Solidity enums cannot carry explicit discriminants.
- **Options** — (a) one custom error per name; (b) revert strings; (c) one custom error per
  error type carrying the numeric code, with named constants.
- **Chose** — (c): `error CacheError(uint32 code)`, `error ProxyReadError(uint32 code)`,
  `error OwnableError(uint32 code)`; the names live in libraries `CacheErrors`,
  `ProxyReadErrors`, `OwnableErrors` with the exact values.
- **Why** — the numeric code is the ABI-level identity in the spec and the Proxy must surface
  Cache codes (109 and any propagated code) unchanged; (a) would lose the numbers, (b) the
  type.
- **Rule** — "Each error type is signalled as a single typed error carrying its numeric code."

## 7. `Result<_, E>` readers that never fail

- **Q** — spec/02: "Reader results are wrapped in the contract's error type … no reader ever
  actually returns an error."
- **Chose** — plain return values; there is no separate `Result` on the EVM (a revert is the
  error channel).
- **Rule** — "A `Result` return maps to the platform's native return/failure channel."

## 8. `Option<T>` returns of the Cache readers

- **Q** — spec/02: `latest_round -> List<Option<RoundData>>`, `decimals -> List<Option<u32>>`,
  `description -> List<Option<String>>`, `get_round/find_round -> Option<RoundData>`.
- **Options** — sentinel values (impossible for `description`: the empty string is a valid
  description); parallel `bool[]` arrays; wrapper structs.
- **Chose** — wrapper structs `OptionRoundData`, `OptionU32`, `OptionString`, each
  `{ bool present; T value; }`; `present == false` is `None` and `value` is then zeroed.
- **Why** — one uniform, self-describing encoding that works for every payload type.
- **Rule** — "An optional non-address value is returned as `{present: bool, value: T}`."

## 9. `workflow_owner` type

- **Q** — overlay: "`workflow_owner` (20 bytes) | `bytes20` or `address` — your call".
- **Chose** — `address` (in `WorkflowPermission.allowed_workflow_owner`, `Metadata`,
  `InvalidUpdatePermission`, `has_permission`). Metadata bytes `[42,62)` are read as
  `address(bytes20(...))`.
- **Why** — the field is an account identity; `address` is what EVM consumers expect and the
  all-zero check reads naturally.
- **Rule** — "A 20-byte account identifier is the platform's native address type."

## 10. Permission hash `encode`

- **Q** — spec/01: permission hash = `keccak256(encode(sender) ‖ encode(owner) ‖ encode(name))`
  "where `encode` is the chain's canonical serialisation".
- **Options** — `abi.encode` (32-byte-padded words) vs `abi.encodePacked`.
- **Chose** — `keccak256(abi.encode(allowed_sender, allowed_workflow_owner, allowed_workflow_name))`.
- **Why** — ABI encoding is the EVM's canonical serialisation; packed encoding is not
  injective in general.
- **Rule** — "`encode` is the platform's standard ABI/XDR serialisation of the typed value."

## 11. Report body decoding and the "platform decoder failure"

- **Q** — spec/02 step 4: decode `report` as the canonical serialisation of
  `List<ReportEntry>`; "A decode failure is reported as `MalformedReport` where the decoder
  returns an error; if the platform's decoder traps instead, that trap is the observable
  behaviour." spec/05: undecodable bytes and "a valid report followed by trailing bytes" must
  fail. Solidity's `abi.decode` *accepts* trailing bytes and traps with empty revert data.
- **Options** — (a) `abi.decode` (trailing bytes would be silently accepted — violates the
  test condition); (b) `abi.decode` plus a re-encode equality check; (c) a strict canonical
  decoder that returns an error.
- **Chose** — (c), `src/cache/ReportCodec.sol`: the body must be exactly
  `abi.encode(ReportEntry[])` — head offset 32, length word, `64 + n*96` bytes total, each
  timestamp `< 2^64`. Every failure (undecodable, truncated, non-canonical head, trailing
  bytes, oversized timestamp) reverts `CacheError(100)`. On the EVM the "platform decoder
  failure" therefore *is* `MalformedReport`.
- **Why** — the decoder returns an error, so the spec's first branch applies and the
  observable behaviour is a single, documented code.
- **Rule** — "The report body must be the exact canonical serialisation of `List<ReportEntry>`
  with no trailing bytes; any deviation is `MalformedReport` unless the platform decoder
  itself traps first."

## 12. In-place upgrade (`upgrade(new_wasm_hash)`)

- **Q** — spec/01: "`upgrade(new_wasm_hash: 32 bytes)` … replaces the contract code in place,
  keeping address and all storage." The EVM cannot change an account's code, and the
  constructor (`owner`, `cache`) is normative, which rules out an initializer-based proxy.
- **Options** — (a) ERC-1967 proxy + implementation with an `initialize` function (changes
  the constructor and adds surface); (b) metamorphic/`selfdestruct` redeploy (unavailable
  post-Cancun); (c) the contract forwards to new code after `upgrade`: a self-forwarding
  `delegatecall` design.
- **Chose** — (c), `src/lifecycle/Upgradeable.sol`. `new_wasm_hash` is the address of the new
  code left-padded to 32 bytes, stored in the ERC-1967 implementation slot. Every entry point
  carries `upgradeable` (non-view: `delegatecall` and return) or `upgradeableView` (view:
  `staticcall` to self with a marker selector, unwrapped in `fallback` into a `delegatecall`
  — required because Solidity forbids `delegatecall` in `view` bodies). Both are inert when
  the code runs as delegated code (`address(this) != __self`, an immutable) or before any
  upgrade. Unknown selectors reach the new code through `fallback`. The constructor is
  unchanged, the address and all storage are kept, and the ABI artifact is the deployable.
  The host-level precondition "the hash names uploaded code" is realised as: high 12 bytes
  zero and `extcodesize > 0`, else `UpgradeTargetHasNoCode(bytes32)` (not a numeric code).
- **Why** — the only realisation that keeps constructor, address, storage and full ABI at
  once; tests prove a distinct artifact (`PeekContract`) and a fresh self-build both run at
  the same address with all data intact.
- **Rule** — "`upgrade` takes the platform's 32-byte code reference; afterwards every call to
  the same address executes the referenced code against the existing storage, and an unknown
  reference fails at platform level."

## 13. State expiry, lifetimes and the retention window

- **Q** — spec/04: "On a chain without expiry, treat every lifetime rule as a no-op and the
  window as unbounded." Yet the overlay says "Do not skip a spec behaviour because it is
  awkward on the EVM; realise it or record why", lists "state expiry and the retention
  window" as a decision area, and spec/05 requires window tests through the public interface.
- **Options** — (a) pure no-op: rounds readable forever, `Window` unused; (b) no entry expiry
  but the window and `round_ttl` fully realised as a readability mask over `ledger_seq`.
- **Chose** — (b). "Refresh"/"pin" lifetime operations are no-ops (nothing ever expires:
  `FeedAdmin`, `FeedConfig`, `Permission`, `FeedState`, `MinDecimals` and rounds persist).
  `round_ttl = min(DATA_RETENTION_TTL, network maximum)` with the EVM "network maximum"
  realised by the internal virtual hook `_networkMaxTtl()` returning `type(uint32).max`
  (unbounded), so production `round_ttl = 3_110_400` blocks. `FeedState.window` is stored and
  updated exactly per spec/04; a non-tip round is readable iff it was written and
  `ledger_seq >= now − width_at(now)`. "Still exists" is always true after a write, so a
  round's observable life is `ledger_seq + round_ttl`, matching a temporary entry that is
  never refreshed. A change of the network maximum (spec/04: "the network maximum can be
  lowered or raised, or the constant can change on upgrade") is realised — and tested — by
  upgrading the Cache to a build with a different hook value (`test/fixtures/CacheWithNetworkMax.sol`).
- **Why** — the window is pure ledger arithmetic and fully realisable; (b) is observably
  closer to the reference platform ("round history older than that is unreadable by design")
  and keeps the `FeedState` storage shape identical across chains; the no-op sentence of
  spec/04 is honoured for the lifetime rules themselves.
- **Rule** — "On a chain without entry expiry, lifetime refreshes are no-ops, the network
  maximum is unbounded, rounds are never deleted, and readability is decided solely by the
  retention window over `ledger_seq`."

## 14. Storage tiers and presence encoding

- **Q** — spec/02–04 assign tiers (instance/persistent/temporary) and speak of entries being
  "present"/"absent". Solidity mappings have no presence bit.
- **Chose** — all records are plain Solidity storage (tiers are no-ops). Presence:
  `FeedConfig` present iff `workflow_permissions.length > 0` (validation guarantees ≥ 1
  permission); `FeedState` present iff `latest_round.round_id != 0` (ids start at 1);
  `Round` present iff its `round_id != 0`; `FeedAdmin`/`Permission` are `bool` maps;
  `MinDecimals` is `{present, value}`. Layout is plain sequential storage (ownership slots
  first, then each contract's records) and must be preserved by any upgrade target.
- **Rule** — "Where the platform has no entry-presence primitive, a record is present iff a
  field that is never zero for a written record is non-zero."

## 15. Ledger sequence and `live_until_ledger` as `uint32(block.number)`

- **Q** — spec/01 types `ledger_seq` and `live_until_ledger` as u32; `block.number` is 256-bit.
- **Chose** — `uint32(block.number)` (truncating cast; `RoundData.ledger_seq` stays `uint32`
  as the ABI requires). No overflow guard: block numbers exceed 2^32 in ~1,600 years.
- **Rule** — "Chain height is stored as the spec's u32 without additional validation."

## 16. `recover_tokens(token, to, amount: i128)`

- **Q** — spec/01 types `amount` as i128; ERC-20 amounts are `uint256`; the overlay maps no
  i128. What if the token returns `false` or `amount` is negative?
- **Chose** — ABI type `int128` (kept from the spec); the amount is reinterpreted two's
  complement as `uint256` and handed to `IERC20.transfer` via a low-level call: a token
  revert bubbles up verbatim, a returned `false` reverts `TokenTransferFailed`, a missing
  return value (non-standard token) counts as success. A negative amount is thus decided by
  the token (no token can transfer 2^256 − |amount|), mirroring "the token contract rejects
  it" rather than adding a validation.
- **Rule** — "`recover_tokens` forwards `amount` to the token's transfer unchanged and treats
  any failure the token signals as a failure of the call."

## 17. `FeedFrozen` raised by the Proxy, and Cache-error propagation

- **Q** — spec/03: a frozen feed "fails with the Cache's `FeedFrozen` (109) … a hard failure
  of the call (a trap/panic carrying that code), not a `ProxyReadError`"; "Any error returned
  by a Cache call propagates … carrying the Cache's error code".
- **Chose** — the Proxy reverts `CacheError(109)` (the Cache's error type, never
  `ProxyReadError`); a reverting Cache call bubbles its revert data untouched (Solidity's
  default for high-level calls), so callers see the Cache's own `CacheError(code)`.
- **Rule** — "Cross-contract failures propagate with the callee's error type and code."

## 18. Naming: snake_case kept verbatim; style lints off

- **Q** — overlay lists "naming conventions (snake_case spec vs Solidity style)"; SKILL.md
  says public names "must match the spec byte-for-byte".
- **Chose** — every public function, argument, struct field, event and event field keeps the
  spec spelling (`latest_round`, `data_ids`, `ownership_transfer`, `Upgraded`, …). Internal
  helpers use Solidity style. Foundry style lints are disabled in `foundry.toml`. Two compiler
  warnings remain because the normative argument `decimals` shadows the function `decimals`.
- **Rule** — "Public identifiers are spelled exactly as in the spec regardless of the target
  language's conventions."

## 19. `Bound` and `DECIMALS` types

- **Chose** — `enum Bound { AtOrBefore, AtOrAfter }` (Solidity assigns 0 and 1); `DECIMALS`
  is a file-level `uint32 constant = 18` (u32 in every signature that mentions decimals).
- **Rule** — "Enums keep declaration order as discriminants; constants take the width of the
  fields they populate."

## 20. Reader mutability

- **Q** — Proxy readers "refresh the instance lifetime" (a write on the reference platform);
  Cache readers "never write".
- **Chose** — every reader of both contracts is `view` (lifetime refreshes are no-ops per
  decision 13), which lets the Proxy call the Cache readers with `staticcall` and keeps the
  ABI honest for off-chain callers.
- **Rule** — "A reader whose only writes are lifetime refreshes is a pure read on chains
  without expiry."

## 21. Dependencies and toolchain settings

- **Chose** — only `forge-std` (tests). No OpenZeppelin or other library. `foundry.toml`:
  `solc = "/root/.foundry/bin/solc"`, no `solc_version`, optimizer on (200 runs),
  `evm_version = "cancun"`, `lint_on_build = false`. Contracts pin `pragma solidity 0.8.30`.
- **Rule** — "Take no dependency beyond the test framework unless the overlay mandates one."

## 22. Test realisation notes (not contract behaviour)

- **(host)** conditions assert `HostAuthorizationFailed(required, caller)`; the "refreshes
  the … lifetime" conditions are exercised as no-op sanity tests (the call succeeds and the
  entry is still present far in the future) and say so in their doc comments.
- "Only X emitted" is asserted with `vm.recordLogs` filtered by emitter. For calls that
  revert after emitting, atomicity is asserted through state instead: Foundry's recorded logs
  are not rolled back on revert, whereas on-chain a reverted call leaves no logs by EVM
  definition.
- Self-upgrade fixtures are deployed from the compiled artifacts (`deployCode(
  "DataFeedsCache.sol:DataFeedsCache", …)` / `"DataFeedsProxy.sol:DataFeedsProxy"`), so the
  upgrade tests run against artifacts built from this project.
- Retention-window conditions that need a different network maximum upgrade the Cache to
  `CacheWithNetworkMax` (decision 13); the "network maximum below the network's minimum entry
  lifetime" condition is covered with maxima of 0 and 1.
