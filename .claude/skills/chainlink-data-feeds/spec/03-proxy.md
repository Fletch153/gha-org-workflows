# 03 — DataFeedsProxy

Contract name: `DataFeedsProxy`. Constructor arguments: `owner: Address, cache: Address`.
On construction: record the owner; refresh the contract-instance lifetime; store `cache`.

Errors (`ProxyReadError`, exact codes; range 50–99):

| Code | Name | Raised by |
|---|---|---|
| 50 | `NoDataPresent` | a read whose Cache answer is `None` |
| 51 | `InvalidDecimals` | a read with `decimals` outside `[min, DECIMALS]`; `set_min_decimals` with `min > DECIMALS` |
| 52 | `RoundsToZero` | scaling a non-zero answer yields zero |

Additionally, every feed-reading function **fails with the Cache's `FeedFrozen` (109)** when the
feed is frozen. This is a hard failure of the call (a trap/panic carrying that code), not a
`ProxyReadError`.

Events:

| Event | Topic fields | Data fields |
|---|---|---|
| `CacheSet` | — | `old_cache: Address, new_cache: Address` |
| `MinDecimalsSet` | `data_id` | `min: u32` |

Storage:

| Key | Tier | Value |
|---|---|---|
| `Cache` | instance | `Address` of the current Cache |
| `MinDecimals(data_id)` | persistent | `u32`; absent means "no minimum set" |

Returned record **Round** `{ round_id: u64, answer: I256, timestamp: u64 }`.

## Precision

- `effective_min(data_id)` = stored `MinDecimals` or `DECIMALS` when absent. So with no minimum
  set, only `decimals == DECIMALS` is accepted.
- **Validate** `decimals`: `decimals < effective_min` or `decimals > DECIMALS` → `InvalidDecimals`.
- **Scale** an answer to `decimals`: integer-divide by `10^(DECIMALS - decimals)`, truncating
  toward zero (negative answers truncate toward zero too). If the original answer is non-zero and
  the result is zero → `RoundsToZero`. A genuine zero answer scales to zero at any precision.
  `decimals = 0` yields the integer part.

## Reader

Common prologue for every reader below, in order: (a) refresh the instance lifetime;
(b) if `MinDecimals(data_id)` exists, refresh its lifetime (never create it).

| Function | Steps after prologue |
|---|---|
| `latest_round(data_id, decimals: u32) -> Result<Round, ProxyReadError>` | validate `decimals` (before any Cache call) → frozen check → Cache `latest_round([data_id])[0]`; `None` → `NoDataPresent`; else scale → `Round` |
| `get_round(data_id, round_id: u64, decimals: u32) -> Result<Round, ProxyReadError>` | validate → frozen check → Cache `get_round(data_id, round_id)`; `None` → `NoDataPresent`; else scale |
| `decimals(data_id) -> Result<u32, ProxyReadError>` | frozen check → Cache `decimals([data_id])[0]`; `None` → `NoDataPresent` |
| `description(data_id) -> Result<String, ProxyReadError>` | frozen check → Cache `description([data_id])[0]`; `None` → `NoDataPresent` |
| `get_min_decimals(data_id) -> u32` | `effective_min(data_id)` (no frozen check) |
| `get_cache() -> Address` | stored cache (prologue step (a) only) |

**Frozen check**: call the Cache's `is_frozen([data_id])`; if `true`, fail the call with
`FeedFrozen` (109). Any error returned by a Cache call propagates as a failure of the Proxy call
carrying the Cache's error code (the Proxy does not translate it).

## Admin (owner only, host-authorised)

`set_cache(cache: Address)` — refresh instance lifetime; emit `CacheSet { old_cache, new_cache: cache }`;
store the new address. Round ids resolve against the new Cache from then on.

`set_min_decimals(data_id, min: u32) -> Result<(), ProxyReadError>` — in order: owner auth;
`min > DECIMALS` → `InvalidDecimals`; refresh instance lifetime; write
`MinDecimals(data_id)` and pin/refresh its lifetime to the maximum; emit
`MinDecimalsSet { data_id, min }`. Setting `min = DECIMALS` re-locks reads to full precision.
