# 02 — DataFeedsCache

Contract name: `DataFeedsCache`. Constructor argument: `owner: Address`.
On construction: record the owner; refresh the contract-instance lifetime.

Errors (`CacheError`, exact codes):

| Code | Name | Raised by |
|---|---|---|
| 100 | `MalformedReport` | `on_report` — metadata not exactly 64 bytes, or report bytes undecodable |
| 101 | `UnauthorizedCaller` | admin entry points — `admin` not in the admin set |
| 102 | `FeedNotConfigured` | `remove_feed_configs` — an id in the batch has no config |
| 103 | `EmptyConfig` | `set_feed_configs` — empty batch, or an entry with no permissions |
| 104 | `InvalidAddress` | `set_feed_configs` — a permission's workflow owner is all-zero |
| 105 | `InvalidWorkflowName` | `set_feed_configs` — a permission's workflow name is all-zero |
| 106 | `DuplicatePermission` | `set_feed_configs` — the same permission triple twice in one entry |
| 107 | `InvalidDataId` | `set_feed_configs` — an entry's id is all-zero |
| 108 | `DuplicateFeedConfig` | `set_feed_configs`, `remove_feed_configs`, `set_feed_frozen` — the same id twice in one batch |
| 109 | `FeedFrozen` | raised by the **Proxy** (using this code) when reading a frozen feed; the Cache itself never raises it |
| 110 | `NoFeedState` | `set_feed_frozen` — an id in the batch has no feed state |

Events (name → topic fields ; data fields). Topic fields are indexed; data fields are the payload.

| Event | Topic fields | Data fields |
|---|---|---|
| `FeedUpdated` | `data_id` | `round_id: u64, timestamp: u64, answer: I256, ledger_seq: u32, primary: bool` |
| `StaleReport` | `data_id` | `report_ts: u64, stored_ts: u64` |
| `InvalidUpdatePermission` | `data_id` | `sender: Address, workflow_owner: 20 bytes, workflow_name: 10 bytes` |
| `FeedConfigSet` | `data_id` | `decimals: u32, description: String, workflow_permissions: List<WorkflowPermission>` |
| `FeedConfigRemoved` | `data_id` | — |
| `FeedFrozenSet` | `data_id` | `frozen: bool` |
| `FeedAdminAdded` | `admin` | — |
| `FeedAdminRemoved` | `admin` | — |

Storage records (tiers and lifetimes are specified in `04-retention.md`):

| Key | Value | Notes |
|---|---|---|
| `FeedAdmin(Address)` | unit | membership in the admin set |
| `FeedConfig(data_id)` | `FeedConfig` | present iff the feed is configured |
| `Permission(data_id, permission_hash)` | unit | one per permission of the current config; membership test used by `on_report` |
| `FeedState(data_id)` | `FeedState` | created by the first accepted round; never removed |
| `Round(data_id, round_id)` | `RoundData` | one per accepted round |

Public function groups below. Argument names are normative.

## Reader (no auth, no writes, no events)

Batch functions take `data_ids: List<data_id>` and return a list of the same length in order.

| Function | Returns | Per-id answer |
|---|---|---|
| `latest_round(data_ids)` | `List<Option<RoundData>>` | `FeedState.latest_round` if state exists, else `None`. Frozen feeds answer normally. |
| `decimals(data_ids)` | `List<Option<u32>>` | `Some(DECIMALS)` iff the feed is configured, else `None` |
| `description(data_ids)` | `List<Option<String>>` | config's description iff configured, else `None` |
| `is_configured(data_ids)` | `List<bool>` | config present |
| `is_frozen(data_ids)` | `List<bool>` | `FeedState.frozen`, or `false` without state |

Single-feed history reads. "Readable" is defined in `04-retention.md` (the tip is always
readable; an older round is readable iff it still exists and is inside the window).

| Function | Returns | Behaviour |
|---|---|---|
| `get_round(data_id, round_id: u64)` | `Option<RoundData>` | `None` without state. If `round_id` equals the tip's id, the tip. Otherwise the stored round if readable, else `None`. |
| `round_range(data_id, from: u64, to: u64)` | `List<RoundData>` | Empty without state. Iterate ids from `max(from, 1)` to `min(to, tip id)` inclusive, ascending; include each readable round; skip unreadable ones. `from > to` yields empty. |
| `find_round(data_id, timestamp: u64, bound: Bound)` | `Option<RoundData>` | `None` without state. Over ids `1..=tip`, `AtOrBefore` returns the **newest** readable round with `round.timestamp <= timestamp`; `AtOrAfter` returns the **oldest** readable round with `round.timestamp >= timestamp`. `None` if no round qualifies. |

`find_round` must be a binary search over the id range (timestamps are non-decreasing in id
order), treating an unreadable id as "absent". Unreadable ids can only form a prefix at the low
end of the range (expiry removes oldest first), and the search may rely on that: when the probe
at `mid` is absent, `AtOrBefore` moves the search **up** (treat as acceptable-but-empty),
`AtOrAfter` also moves **up** (treat as unacceptable). Reader results are wrapped in the
contract's error type (`Result<_, CacheError>`) except `is_frozen`, which returns the bare list;
no reader ever actually returns an error. The admin reads (`get_feed_permissions`,
`has_permission`, `is_feed_admin`) return bare values.

## Writer

`on_report(sender: Address, metadata: Bytes, report: Bytes) -> Result<(), CacheError>`

Check/act order:

1. Host-authorise `sender`.
2. Refresh the contract-instance lifetime.
3. Decode `metadata`: length must be exactly 64 bytes, laid out as
   `[0,32) workflow_cid`, `[32,42) workflow_name`, `[42,62) workflow_owner`, `[62,64) report_id`.
   Any other length → `MalformedReport`.
4. Decode `report` as the chain's canonical serialisation of `List<ReportEntry>`. A decode
   failure is reported as `MalformedReport` where the decoder returns an error; if the
   platform's decoder traps instead, that trap is the observable behaviour (see overlay).
5. Let `seq` = current chain sequence; `phash` = permission hash of
   `(sender, metadata.workflow_owner, metadata.workflow_name)`.
6. For each entry, **in order**, with `data_id` taken verbatim from the entry:
   - If `Permission(data_id, phash)` is absent → emit `InvalidUpdatePermission { data_id, sender,
     workflow_owner, workflow_name }` and continue. (Unconfigured feeds hit this path.)
   - Else **record** the entry (below). Recording is independent of `frozen`.
7. Return success. An empty entry list is a successful no-op with no events.

**Record** `(data_id, answer, timestamp)`:

- `stored_ts` = `FeedState.latest_round.timestamp`, or `0` if no state.
- If `timestamp <= stored_ts` → **stale**: emit `StaleReport { data_id, report_ts: timestamp,
  stored_ts }`. Nothing is written except lifetime refreshes.
- Else **append**: `round_id` = previous tip id + 1 (or `1`); write `Round(data_id, round_id)` =
  `{ round_id, answer, timestamp, ledger_seq: seq, primary: true }`; write `FeedState` with
  `latest_round` = that round, `window` = next window per `04-retention.md`, `frozen` = previous
  `frozen` (or `false` for a new state); emit `FeedUpdated { data_id, round_id, timestamp, answer,
  ledger_seq: seq, primary: true }`.
- In both outcomes, refresh the lifetimes of `FeedState(data_id)` and, if the feed is
  configured, of `FeedConfig(data_id)` and of every `Permission` of that config.
- Within one batch, each entry is evaluated against state as updated by earlier entries of the
  same batch (two entries for one feed with rising timestamps land as two rounds; a later entry
  with a timestamp not above the running tip is stale).

## Admin

All admin mutators: `admin`-argument functions host-authorise `admin`, refresh the instance
lifetime, then require `admin` ∈ admin set (else `UnauthorizedCaller`; a successful membership
check also refreshes that admin entry's lifetime). Owner-only functions host-authorise the owner
and refresh the instance lifetime. Any error aborts the whole call with no writes and no events.

`set_feed_configs(admin, entries: List<FeedConfigEntry>) -> Result<(), CacheError>`
1. auth as above; 2. `entries` empty → `EmptyConfig`;
3. validate **every** entry before writing any, for entry `i` in order:
   `data_id` all-zero → `InvalidDataId`; same `data_id` as any later entry → `DuplicateFeedConfig`;
   then the config: no permissions → `EmptyConfig`; for each permission in order: owner
   all-zero → `InvalidAddress`; name all-zero → `InvalidWorkflowName`; equal to any later
   permission in the same entry → `DuplicatePermission`.
4. for each entry in order: `existed` = config present. If existed, delete every `Permission`
   of the old config. Write `FeedConfig`, write one `Permission` per new permission, then
   refresh the lifetimes of **both** the `FeedConfig` entry (also when it was overwritten) and
   every new `Permission` entry. If `existed` emit `FeedConfigRemoved { data_id }`; then always emit
   `FeedConfigSet { data_id, decimals: DECIMALS, description, workflow_permissions }` (the full
   list). Never touch `FeedState` or rounds: reconfiguring a feed keeps its history and counter,
   and a re-added feed's first report is judged stale against the surviving tip timestamp.

`remove_feed_configs(admin, data_ids: List<data_id>) -> Result<(), CacheError>`
1. auth; 2. empty list → success, no events;
3. validate every id before writing any, for id `i` in order: equal to a later id →
   `DuplicateFeedConfig`; not configured → `FeedNotConfigured`.
4. for each id: delete its permissions and config; emit `FeedConfigRemoved { data_id }`.
   `FeedState` and rounds are untouched (they resurface if the feed is configured again).

`set_feed_frozen(admin, data_ids: List<data_id>, frozen: bool) -> Result<(), CacheError>`
1. auth; 2. validate: any id equal to a later id → `DuplicateFeedConfig`;
3. for each id in order: no `FeedState` → `NoFeedState` (aborts everything); else set
   `FeedState.frozen = frozen`, refresh its lifetime, emit `FeedFrozenSet { data_id, frozen }`
   — emitted on every call, even when the flag did not change. Empty list → success, no events.
   A feed whose config was removed can still be frozen/unfrozen (state outlives config).
   Freezing does not stop reports from landing on the Cache.

`add_feed_admin(new_admin: Address) -> Result<(), CacheError>` — owner; write
`FeedAdmin(new_admin)` (idempotent), refresh its lifetime, emit `FeedAdminAdded { admin: new_admin }`
(also on re-add).

`remove_feed_admin(admin: Address) -> Result<(), CacheError>` — owner; delete
`FeedAdmin(admin)` (no-op if absent), emit `FeedAdminRemoved { admin }` regardless.

Admin reads (no auth, no writes):

| Function | Returns |
|---|---|
| `get_feed_permissions(data_id) -> List<WorkflowPermission>` | the current config's list, or empty (also for the all-zero id) |
| `has_permission(data_id, sender: Address, workflow_owner, workflow_name) -> bool` | `Permission(data_id, hash(sender, workflow_owner, workflow_name))` present |
| `is_feed_admin(admin: Address) -> bool` | `FeedAdmin(admin)` present |
