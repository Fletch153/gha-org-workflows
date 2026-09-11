# Chain overlay — EVM (Solidity / Foundry)

Instantiation of `spec/06` for the EVM. Mechanics only; behaviour is in `spec/`.

## Platform facts (per `spec/06` axis)

- **A. Account model** — case A.2: caller identity is `msg.sender`. `sender`/`admin`
  arguments are dropped; host failures are a dedicated custom error
  `Unauthorized(address caller)` (no numeric code).
- **B. Storage** — mappings keyed by the spec keys; presence per B.2; instance singletons
  are plain state variables. No storage payer (gas only).
- **C. Expiry** — none (case C.3). Sequence unit is `block.number`. No reclaim.
- **D. Limits** — 24 KiB deployed code per contract (EIP-170); gas. Batches are bounded by gas
  only. No record declaration convention.
- **E. Errors** — one custom error per family carrying the code: `CacheError(uint32 code)`,
  `ProxyReadError(uint32 code)`, `OwnableError(uint32 code)`; names as constants.
- **F. Serialisation** — `abi.encode` for `encode(x)`; report body is exactly
  `abi.encode(ReportEntry[])` (strict decode; trailing bytes → `MalformedReport`).
- **G. Optionals** — `{bool present; T value;}` structs named `OptionalRoundData`,
  `OptionalU32`, `OptionalString`; optional address = `address(0)`.
- **H. Events** — `indexed` for topic fields.
- **I. Upgrade** — case I.3: no `upgrade`/`Upgraded`; contracts are immutable.
- **J. Ownership** — no library; implement the table (`live_until_ledger` in blocks).
- **K. Naming** — mechanical snake_case → camelCase for functions, arguments, event names
  and event/struct fields (`latest_round` → `latestRound`, `data_ids` → `dataIds`,
  `ownership_transfer` → `OwnershipTransfer`); error/enum/constant names unchanged.
  Token amount is `uint256`. `workflow_owner` is `address`.
- **L. Cross-contract** — high-level interface calls; the Cache's revert data bubbles
  through the Proxy unchanged.

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
(it is unbounded); cover the window with `vm.roll` past `ledger_seq + round_ttl`.

## Decision log

Same format as `SKILL.md` step 6. With this overlay and `spec/06` applied there should be
few or no entries; anything left is a gap to report.
