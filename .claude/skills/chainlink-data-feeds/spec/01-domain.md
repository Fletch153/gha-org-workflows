# 01 — Domain model and shared lifecycle

## Purpose

A **Data Feed** publishes a time series of numeric answers (e.g. BTC/USD) written on-chain by
authorised off-chain workflows. Two contracts implement it:

- **Cache** — the source of truth. Stores feed configuration, round history and feed state.
  Written by permitted workflow senders; read by anyone. Batched, raw (unscaled) reads.
- **Proxy** — the consumer-facing reader. Holds the address of one Cache, delegates every read
  to it, adds precision scaling and a per-feed minimum precision, and refuses to serve frozen
  feeds. Single-feed reads. The Cache behind a Proxy can be swapped by the owner.

## Identifiers and scalars

| Name | Width | Meaning |
|---|---|---|
| `data_id` | 32 bytes | Feed identifier. All 32 bytes are significant; two ids differing in any byte are different feeds. The all-zero id is invalid for configuration but must be tolerated (answered as "unknown feed") by every read. |
| `workflow_owner` | 20 bytes | Owner of the writing workflow. All-zero is invalid in a permission. |
| `workflow_name` | 10 bytes | Name of the writing workflow. All-zero is invalid in a permission. |
| `workflow_cid` | 32 bytes | Content id of the workflow. Carried in report metadata; never validated or stored. |
| `report_id` | 2 bytes | Carried in report metadata; never validated or stored. |
| `answer` | signed 256-bit integer | Feed value at fixed precision `DECIMALS`. |
| `DECIMALS` | constant `18` | Precision of every stored answer. The Cache reports it for any configured feed and never stores a per-feed value. |
| `timestamp` | u64 | Observation time carried in the report. The contract never compares it to chain time. |
| `round_id` | u64 | Per-feed counter. First accepted round is `1`; each accepted round is previous + 1. Never reset. |
| `ledger_seq` | u32 | Chain sequence/height at the moment a round was written. |
| `live_until_ledger` | u32 | Expiry for a pending ownership offer. |

## Records

**RoundData** `{ round_id: u64, answer: I256, timestamp: u64, ledger_seq: u32, primary: bool }`
— `primary` is always `true` for rounds written by this contract (reserved for future
secondary sources).

**WorkflowPermission** `{ allowed_sender: Address, allowed_workflow_owner: 20 bytes, allowed_workflow_name: 10 bytes }`
— a permission is identified by the triple. Its *permission hash* is
`keccak256( encode(allowed_sender) ‖ encode(allowed_workflow_owner) ‖ encode(allowed_workflow_name) )`
where `encode` is the chain's canonical serialisation of the value (see overlay). Equality of
permissions is field-wise equality of the triple.

**FeedConfig** `{ description: String, workflow_permissions: List<WorkflowPermission> }`.
The description may be empty.

**FeedConfigEntry** `{ data_id, config: FeedConfig }` — one element of a configuration batch.

**ReportEntry** `{ data_id, answer: I256, timestamp: u64 }` — one element of a report.

**Metadata** `{ workflow_cid, workflow_name, workflow_owner, report_id }` — decoded from the
64-byte metadata blob that accompanies a report.

**FeedState** `{ latest_round: RoundData, window: Window, frozen: bool }` — exists from the first
accepted round onward and is **never deleted** by any entry point. `Window` is defined in
`04-retention.md`.

**Bound** — enum `AtOrBefore` (discriminant 0), `AtOrAfter` (discriminant 1).

## Actors and authority

| Actor | How established | May |
|---|---|---|
| **Owner** | set in the constructor; changed by two-step transfer; may renounce | add/remove feed admins (Cache); set cache and min-decimals (Proxy); upgrade; recover tokens; transfer/renounce ownership |
| **Feed admin** (Cache only) | address in the admin set, managed by the owner | set/remove feed configs; freeze/unfreeze feeds |
| **Permitted sender** (Cache only) | `(sender, workflow_owner, workflow_name)` listed in a feed's config | have reports for that feed accepted |
| **Anyone** | — | every read |

Authority checks come in two flavours and must surface differently:

- **Host authorisation** — the caller must prove they are `X` (the owner, or the `sender`/`admin`
  address passed as an argument). Failure is a chain-level authorisation failure, *not* a
  contract error code.
- **Contract authorisation** — after host authorisation, the address is checked against a set
  (e.g. is `admin` in the admin set). Failure is the contract error listed for that entry point.

The owner is **not** implicitly a feed admin. A feed admin is **not** the owner.

## Shared lifecycle surface (both contracts)

Every contract exposes, in addition to its own functions:

| Function | Auth | Behaviour |
|---|---|---|
| `version() -> u32` | none | returns `1` |
| `type_and_version() -> String` | none | `"DataFeedsCache 1.0.0"` / `"DataFeedsProxy 1.0.0"` |
| `get_owner() -> Option<Address>` | none | current owner, `None` after renounce |
| `transfer_ownership(new_owner: Address, live_until_ledger: u32)` | owner (host) | records a pending offer that expires at `live_until_ledger`; emits `ownership_transfer { old_owner, new_owner, live_until_ledger }` |
| `accept_ownership()` | pending new owner (host) | completes the transfer; emits `ownership_transfer_completed { new_owner }` |
| `renounce_ownership()` | owner (host) | clears the owner; fails if a transfer is pending; emits `ownership_renounced { old_owner }` |
| `upgrade(new_wasm_hash: 32 bytes)` | owner (host) | replaces the contract code in place, keeping address and all storage; emits `Upgraded { new_wasm_hash }` (no topic fields) |
| `recover_tokens(token: Address, to: Address, amount: i128)` | owner (host) | transfers `amount` of `token` held by the contract to `to`; emits `TokenRecovered { token, to, amount }` (no topic fields) |

Event names are exact, including case: the ownership events are snake_case (they come from the
ownership library), `Upgraded` and `TokenRecovered` are PascalCase. None of the lifecycle
functions (`upgrade`, `recover_tokens`, ownership functions) refreshes any storage lifetime.

Ownership error codes live in the range 2100–2199 (`OwnerNotSet = 2100`,
`TransferInProgress = 2101`, `OwnerAlreadySet = 2102`) and must not collide with either
contract's own error range. The overlay names the library that provides ownership; use it
rather than re-implementing.

## Global invariants

1. Error codes: Cache uses 100–199, Proxy uses 50–99, ownership 2100–2199. Disjoint.
2. Every state-changing entry point that succeeds leaves all of its writes and events; every
   one that fails leaves none of them (atomic per call).
3. Reads never write feed data, never create records, and never emit events. (They may
   refresh storage lifetimes where the retention spec says so.)
4. Round history for a feed lives only in the Cache that recorded it; swapping a Proxy's cache
   changes what every round id resolves to.
