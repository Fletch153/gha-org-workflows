# Chain overlay — EVM (Solidity / Foundry)

Instantiation of `spec/06` for the EVM. Mechanics only; behaviour is in `spec/`.

## Platform facts (per `spec/06` axis)

- **capabilities:** `[events_indexed]`

- **A. Account model** — case A.2: caller identity is `msg.sender`. `sender`/`admin`
  arguments are dropped; host failures are a dedicated custom error
  `Unauthorized(address caller)` (no numeric code). A token transfer failure in
  `recoverTokens` (revert, `false`, or no code at `token`) is `TokenTransferFailed(address token)`.
  `recoverTokens` concretely: `token.code.length == 0` → `TokenTransferFailed` before any call;
  then `token.call(transfer(to, amount))` succeeds iff it does not revert and returns either
  no data or exactly 32 bytes decoding to `true`; anything else → `TokenTransferFailed`.
  `TokenRecovered` is emitted after the transfer. Every custom error is declared once at file
  scope (`CacheError`/`ProxyReadError` next to their interfaces, `OwnableError`/`Unauthorized`
  in `Ownable.sol`, `TokenTransferFailed` in `TokenRecoverable.sol`); the Proxy imports
  `CacheError` and reverts `CacheError(109)` for a frozen feed. The `05` condition "sender
  without host authorisation fails" has no realisation (the sender is `msg.sender`); the
  tested guarantee is that a non-permitted caller is soft-skipped with
  `InvalidUpdatePermission{sender: msg.sender}`. Constructors validate nothing: an
  `address(0)` owner yields an ownerless contract (2100 on owner-only calls); a code-less
  cache makes Proxy feed reads fail with an empty revert (host failure).
- **B. Storage** — mappings keyed by the spec keys; presence per B.2; instance singletons
  are plain state variables. No storage payer (gas only).
  Presence: `FeedConfig` ↔ `workflowPermissions.length != 0`; `FeedState`/`Round` ↔
  `roundId != 0`; `FeedAdmin`/`Permission` ↔ `bool`; `MinDecimals` ↔ `OptionalU32.present`;
  the pending ownership offer ↔ `liveUntilLedger != 0` (so `transferOwnership(address(0), n)`
  stores an unacceptable offer, cancelled with `(address(0), 0)`). `FeedState` is
  `{RoundData latestRound; Window window; bool frozen}`, `Window` is `{uint32 shortestTtl;
  uint32 growToTtl; uint32 growAtLedger}` (internal, not on the ABI). Slot order — Cache:
  0 `s_owner`, 1 `s_pending` (`address newOwner` + `uint32 liveUntilLedger` packed),
  2 `s_feedAdmins`, 3 `s_feedConfigs`, 4 `s_permissions`, 5 `s_feedStates`, 6 `s_rounds`;
  Proxy: 0 `s_owner`, 1 `s_pending`, 2 `s_minDecimals`, 3 `s_cache`. `roundRange`/`findRound`
  answer `id == tip` from `FeedState.latestRound`, never from the round store.
- **C. Expiry** — none (case C.3). Sequence unit is `block.number`. No reclaim. `ledger_seq`,
  the window's `now` and ownership's `now` are all `uint32(block.number)` (truncating cast);
  `round_ttl` is the constant `DATA_RETENTION_TTL`. Readers on both contracts are `view`
  (`version`/`typeAndVersion` are `pure`); readers return bare values, no `Result` wrapper.
- **D. Limits** — 24 KiB deployed code per contract (EIP-170); gas. Batches are bounded by gas
  only. No record declaration convention.
- **E. Errors** — one custom error per family carrying the code: `CacheError(uint32 code)`,
  `ProxyReadError(uint32 code)`, `OwnableError(uint32 code)`; names as constants. The
  names are `internal` constants of the libraries `CacheErrors`, `ProxyReadErrors`,
  `OwnableErrors` (spec spelling, e.g. `CacheErrors.MalformedReport = 100`); no public getters.
  `DECIMALS` and `DATA_RETENTION_TTL` are `internal constant`s.
- **F. Serialisation** — `abi.encode` for `encode(x)`; report body is exactly
  `abi.encode(ReportEntry[])` (strict decode; trailing bytes → `MalformedReport`). The
  decoder is hand-written (no `abi.decode`, so nothing traps): length `< 64`, head offset word
  `!= 32`, `length != 64 + 96 * count`, trailing bytes, or a `timestamp` word above
  `type(uint64).max` → `CacheError(100)`; answer words are taken verbatim as `int256`; ids are
  not validated. Metadata length is checked before the body.
- **G. Optionals** — `{bool present; T value;}` structs named `OptionalRoundData`,
  `OptionalU32`, `OptionalString`; optional address = `address(0)`. `getOwner()` returns
  `address` with `address(0)` = `None`. `Bound` is `enum Bound { AtOrBefore, AtOrAfter }`
  (`uint8` 0/1); an out-of-range value is a Solidity panic (host failure).
- **H. Events** — `indexed` for topic fields. Ownership events, `TokenRecovered` and `CacheSet`
  have no `indexed` fields. Ownership event names under axis K: `OwnershipTransfer(address
  oldOwner, address newOwner, uint32 liveUntilLedger)`, `OwnershipTransferCompleted(address
  newOwner)`, `OwnershipRenounced(address oldOwner)`.
- **I. Upgrade** — case I.3: no `upgrade`/`Upgraded`; contracts are immutable.
- **J. Ownership** — no library; implement the table (`live_until_ledger` in blocks). Check
  order: every owner-only function checks `OwnerNotSet` (2100) before `msg.sender == owner`
  (`Unauthorized`); `acceptOwnership` checks 2200 → 2203 → `Unauthorized`; `liveUntilLedger ==
  now` is accepted; no maximum offer horizon; `renounceOwnership` deletes an expired offer.
- **K. Naming** — mechanical snake_case → camelCase for functions, arguments, event names
  and event/struct fields (`latest_round` → `latestRound`, `data_ids` → `dataIds`,
  `ownership_transfer` → `OwnershipTransfer`); error/enum/constant names unchanged.
  Token amount is `uint256`. `workflow_owner` is `address`. The Proxy's precision argument is
  named `decimals` (spec spelling; it shadows the `decimals(bytes32)` function inside those
  bodies — warning only). Shared struct/enum types are file-scope declarations in
  `src/interfaces/IDataFeedsCache.sol` (`Round` in `IDataFeedsProxy.sol`).
- **L. Cross-contract** — high-level interface calls; the Cache's revert data bubbles
  through the Proxy unchanged. A Proxy whose cache has no code fails feed reads with an empty
  revert (Solidity's extcodesize check) — a host failure.

## Toolchain

- Foundry (`forge`, `cast`, `anvil`) at `~/.foundry/bin` — add it to `PATH`.
- Solidity `0.8.30`, static binary at `~/.foundry/bin/solc`. Compiler downloads are blocked, so
  `foundry.toml` must contain `solc = "/root/.foundry/bin/solc"` (absolute path) and no
  `solc_version`; `[profile.default]` also sets `optimizer = true`, `optimizer_runs = 200`,
  `evm_version = "cancun"`; a `[lint]` section sets `lint_on_build = false` (forge 1.5 reads
  it there, not under the profile).
- `forge-std` via `forge init` / `forge install` (git access works). No other dependency.

## Layout and commands

Foundry project at `out_dir`: `src/DataFeedsCache.sol`, `src/DataFeedsProxy.sol`, shared
pieces under `src/` (interfaces, abstract lifecycle contracts, libraries), tests under `test/`.
Artifacts: `forge build` → `out/<File>.sol/<Contract>.json`. Tests: `forge test`.

## Type vocabulary

`bytes32` for ids/hashes; `bytes10` workflow name; `bytes2` report id; `int256` answer;
`string`; `T[]` lists; `bytes`; `address`; `struct`s with spec field order; `enum Bound`.

## Testing notes

`vm.prank`/`vm.startPrank` for callers; `vm.expectRevert(abi.encodeWithSelector(...))` for
exact errors; `vm.expectEmit`/`vm.recordLogs` for events (recorded logs are not rolled back
on revert — assert atomicity via state); `vm.roll` for block numbers; a minimal ERC-20 mock
for `recover_tokens`. Retention-window conditions that vary the network maximum do not apply
(it is unbounded); cover the window with `vm.roll` past `ledger_seq + round_ttl`. Test
the TTL-varying window conditions against a harness contract wrapping `RetentionWindow`; assert
lifetime-refresh conditions as persistence after a large `vm.roll`; assert "reads never write"
with `vm.record` + `vm.accesses`; the `emit` paired with `vm.expectEmit` is itself a recorded log,
so filter `vm.getRecordedLogs()` by `emitter` for "only"/count assertions; probe the absent
`upgrade(bytes32)` selector with a low-level call that must fail; a mock Cache with a forced
revert (arbitrary revert data) proves both error bubbling and "invalid precision fails before
the Cache is consulted".

## Decision log

Same format as `SKILL.md` step 6. With this overlay and `spec/06` applied there should be
few or no entries; anything left is a gap to report.

## Retention constant

Sequence unit nominal duration: 12-second blocks (nominal; the overlay may state the target network's actual block time) → `DATA_RETENTION_TTL = 1_296_000` (180 days, `spec/04`).
