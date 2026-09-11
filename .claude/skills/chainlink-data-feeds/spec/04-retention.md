# 04 — Storage lifetimes and the retention window (Cache)

This file applies to chains where stored entries have a **time-to-live (TTL)** measured in
ledgers and expire unless refreshed (state expiration / rent). The overlay maps the vocabulary
(`max_ttl`, tiers, "refresh") to concrete platform calls. On a chain without expiry, treat every
lifetime rule as a no-op and the window as unbounded.

## Tiers and lifetimes

| Record | Tier | Lifetime rule |
|---|---|---|
| contract instance (code + instance entries) | instance | every state-changing entry point (constructors, `on_report`, all admin mutators, Proxy admin and Proxy readers) refreshes it to the network maximum |
| `FeedAdmin`, `FeedConfig`, `Permission`, `FeedState`, `MinDecimals` | persistent | on **first write** pin to the network maximum; an overwrite of an existing entry does **not** re-pin; an explicit **refresh** (where the spec says "refresh its lifetime") sets it back to the network maximum and is a no-op for an absent entry |
| `Round(data_id, round_id)` | temporary | on first write pin to `round_ttl = min(DATA_RETENTION_TTL, network maximum)`; **never refreshed afterwards**; expires naturally |

`DATA_RETENTION_TTL = 3_110_400` ledgers (180 days of 5-second ledgers). Round history older
than that is unreadable by design.

"Refresh to the network maximum" means: extend so the entry lives for the maximum the network
allows from now (threshold = maximum − 1 so the extension always applies; extend-to = maximum).

## The window

Because `round_ttl` can change over time (the network maximum can be lowered or raised, or the
constant can change on upgrade), reads must not return a round that was written under a
*longer* retention than the one currently in force, and must not pretend a shorter one applies
to rounds that were written with a longer one. `FeedState.window` encodes this:

`Window { shortest_ttl: u32, grow_to_ttl: u32, grow_at_ledger: u32 }`

- `width_at(now)` = `grow_to_ttl` if `now >= grow_at_ledger`, else `shortest_ttl`.
- A stored round is **readable** iff it still exists **and** `round.ledger_seq >= now − width_at(now)`
  (saturating at zero). The tip (`FeedState.latest_round`) is always readable without
  consulting the round store or the window.

Updating the window on every **append** (stale reports do not touch it), with `ttl = round_ttl`
at the time of the append and `seq` = current ledger:

- no prior state → `{ shortest_ttl: ttl, grow_to_ttl: ttl, grow_at_ledger: 0 }`.
- prior state `p`:
  - `grow_at_ledger` = `p.grow_at_ledger`, unless `ttl != p.grow_to_ttl`, in which case
    `grow_at_ledger = p.latest_round.ledger_seq + ttl + 1` (saturating) — the date by which
    every round written under the previous plan has aged out.
  - `shortest_ttl = min(p.width_at(seq), ttl)` — a lowered TTL narrows the window immediately;
    a raised TTL does not widen it until `grow_at_ledger`.
  - `grow_to_ttl = ttl`.

Consequences the implementation must exhibit:
- lowering the network maximum narrows reads immediately, even for rounds still alive;
- raising it widens reads only once `grow_at_ledger` passes, and only rounds written after the
  raise have the longer life;
- a second TTL change before the grow date replaces the pending plan;
- a write after the grow date locks in the grown width as the new `shortest_ttl`;
- reads of an explicit round id, ranges, and timestamp searches all apply the same mask.
