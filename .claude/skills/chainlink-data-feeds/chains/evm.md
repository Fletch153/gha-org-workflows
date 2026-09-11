# Chain overlay — EVM (Solidity / Foundry)

This overlay gives **mechanics only**. The spec was written against a platform with explicit
per-argument authorisation, state expiry, numeric error codes, optional return values and
in-place code upgrade. Where the EVM has no direct equivalent, **you** choose the closest
faithful realisation and you **must record every such choice** (see "Decision log" below).
Do not skip a spec behaviour because it is awkward on the EVM; realise it or record why it
cannot be realised.

## Toolchain

- Foundry (`forge`, `cast`, `anvil`) at `~/.foundry/bin` — add it to `PATH`.
- Solidity `0.8.30`, static binary at `~/.foundry/bin/solc`. Compiler downloads are blocked, so
  `foundry.toml` must contain `solc = "/root/.foundry/bin/solc"` (absolute path) and
  `solc_version` must not be set.
- `forge-std` via `forge init` / `forge install` (git access works). No other dependency is
  mandated; if you take one (e.g. an ownership or ERC-20 library), record it as a decision.

## Layout

A Foundry project at `out_dir`: `src/DataFeedsCache.sol`, `src/DataFeedsProxy.sol`, shared
pieces under `src/` (interfaces, shared abstract contracts, libraries), tests under `test/`.
Deployable artifacts: `forge build` → `out/<File>.sol/<Contract>.json` (ABI + bytecode).
Tests: `forge test`.

## Type vocabulary

| Spec | Solidity |
|---|---|
| `data_id`, `workflow_cid`, hashes | `bytes32` |
| `workflow_owner` (20 bytes) | `bytes20` or `address` — your call, record it |
| `workflow_name` (10 bytes) | `bytes10` |
| `report_id` | `bytes2` |
| `answer` (I256) | `int256` |
| `String` | `string` |
| `List<T>` | `T[]` (memory for arguments/returns) |
| `Bytes` | `bytes` |
| `Address` | `address` |
| records | `struct`s; field **names** and **order** are ABI |
| `Bound` | `enum` with the given ordering |
| events | `event`s; spec "topic fields" become `indexed` parameters, in the listed order |
| ledger sequence / `live_until_ledger` | `block.number` |

## Testing notes

`vm.prank` / `vm.startPrank` to set the caller; `vm.expectRevert` (with the exact error
selector/data) for failures; `vm.expectEmit` for events; `vm.roll` to move block numbers;
a minimal ERC-20 mock for `recover_tokens`. For "upgrade"-style conditions, test whatever
realisation you chose.

## Decision log (mandatory)

Write `out_dir/DECISIONS.md`. One entry per choice the spec + this overlay did not determine.
Format per entry:

- **Q** — the question, quoting the spec line(s) that triggered it.
- **Options** — the realisations you considered.
- **Chose** — what you did.
- **Why** — the reasoning.
- **Rule** — the single chain-agnostic sentence that, if it were in `spec/`, would have made
  this decision deterministic for *any* chain.

Expected areas (not exhaustive): the account model ("host-authorise `x`" vs `msg.sender`);
what happens to the `sender`/`admin` arguments; state expiry and the retention window; error
signalling (numeric codes vs custom errors); `Option` returns and batch reads; the canonical
serialisation used for the permission hash and for report decoding; in-place upgrade; the
ownership model and `live_until_ledger`; "refresh lifetime" no-ops; the meaning of the
`FeedFrozen` code raised by the Proxy; naming conventions (snake_case spec vs Solidity style).
