# 05 — Required test conditions

Every condition below must be covered by at least one test in the generated project, exercised
through the public contract interface (deploy the contract in the platform's test environment
and call it as a client). Conditions marked **(host)** must be asserted via the host-level
failure the platform produces, not a contract error code. "Emits X" means the exact event with
the exact fields is among the events of that contract, and no unexpected extra event is present
where the condition says "only".

## Cache — constructor / lifecycle
- constructor stores the owner; `get_owner` returns it.
- `version() == 1`; `type_and_version() == "DataFeedsCache 1.0.0"`.
- two-step ownership: transfer then accept makes the new owner the owner.
- `recover_tokens` moves the requested amount of a token held by the contract to the destination.
- `upgrade` swaps code in place (upgrade to a distinct artifact, prove the new code runs at the
  same address).
- **all persistent and temporary feed data survives a self-upgrade**: after seeding rounds
  (including one with an answer and timestamp beyond 32 bits), config, permissions and an
  admin, upgrading the Cache to a freshly built artifact of itself keeps: every historical
  round field-for-field, the tip, decimals, description, permissions, admin membership,
  and `version()`.
- error codes: every `CacheError` has the listed numeric value, lies in 100–199, and is
  disjoint from the ownership library's codes (which lie in 2100–2199).

## Cache — set_feed_configs
- non-admin caller → 101; empty batch → 103; all-zero id → 107; entry without permissions →
  103; permission with all-zero workflow name → 105; duplicate permission in one entry → 106;
  duplicate id in one batch → 108.
- an invalid entry aborts the whole batch (earlier valid entries are not written).
- first-time config emits only `FeedConfigSet` with `decimals = 18`; reconfiguring emits
  `FeedConfigRemoved` then `FeedConfigSet` and fully replaces the permission list.
- a feed may hold several permitted workflows; `FeedConfigSet` carries every permission.
- a batch configures multiple distinct feeds.
- the call refreshes the instance lifetime and the config and permission entry lifetimes.
- **resurrection**: after rounds are written, removing the config keeps `latest_round` and
  history; a self-upgrade keeps them; re-adding the config resumes the round counter (next
  round is previous tip + 1) and old rounds remain readable.
- re-adding under a different workflow inherits prior history and counter; the old sender is
  then no longer permitted (soft-skipped).
- after re-add, a first report with a timestamp not above the surviving tip is stale (emits
  `StaleReport` with the surviving `stored_ts`); a later, higher timestamp lands as tip + 1.

## Cache — remove_feed_configs
- non-admin → 101; empty batch succeeds with no events; removal deletes config and
  permissions (`get_feed_permissions` empty, `description` none, `has_permission` false).
- a batch containing an unconfigured id aborts atomically (102); a duplicate id aborts and
  removes nothing (108); the call refreshes the instance lifetime.

## Cache — feed admins
- `add_feed_admin` by non-owner **(host)** fails; by the owner emits `FeedAdminAdded` and
  `is_feed_admin` becomes true; re-adding emits again and stays registered; the call refreshes
  the instance and admin entry lifetimes; a feed admin cannot add admins **(host)**.
- `remove_feed_admin`: removed address is no longer admin, removing again still emits
  `FeedAdminRemoved`; by non-owner **(host)** fails; a removed admin can no longer configure
  (101); the call refreshes the instance lifetime.

## Cache — permissions reads
- `get_feed_permissions` returns the whole list for a configured feed, empty for an
  unconfigured feed, and empty (not an error) for the all-zero id.
- `has_permission` is true for a configured `(sender, owner, name)`, false for an unknown
  sender or feed, and false (not an error) for the all-zero id.

## Cache — set_feed_frozen
- while frozen, every Cache read (`latest_round`, `get_round`, `round_range`, `find_round`,
  `decimals`, `description`, `is_configured`) answers as normal; unfreezing changes nothing
  about them; `is_frozen` reflects the flag.
- reports still land while frozen and the feed stays frozen.
- the flag outlives config removal (can still be toggled after `remove_feed_configs`).
- freezing one feed leaves a sibling readable/unfrozen.
- every call emits `FeedFrozenSet` per id even without a change.
- an id without feed state aborts the whole batch (110); duplicate ids abort and change nothing
  (108); empty batch is a no-op; non-admin → 101.

## Cache — on_report
- sender without host authorisation **(host)** fails.
- metadata of 63 or 65 bytes → 100.
- undecodable report bytes, and a valid report followed by trailing bytes, fail with the
  platform decoder's failure (see overlay for what that is).
- empty entry list succeeds with zero events.
- the report's `data_id` must equal the configured id exactly (an id differing in one low byte
  is a different feed and is soft-skipped).
- unconfigured feed: only `InvalidUpdatePermission` is emitted (with the report's id, sender,
  owner, name) and nothing is written.
- wrong owner, wrong name, or wrong sender does not record.
- a sender revoked by reconfiguration is soft-skipped; a sender of a removed feed is
  soft-skipped.
- a successful report refreshes the instance, state, config and every permission lifetime;
  it refreshes **all** permissions of the feed, not only the reporting one.
- equal or older timestamp is stale: emits `StaleReport {report_ts, stored_ts}`; with no prior
  state `stored_ts` is 0 and any timestamp above 0 lands.
- within a batch, stale entries compare against the running tip and do not block later accepts.
- two reports for one feed advance the counter twice; the first accept is round 1 and stores
  `ledger_seq` = the ledger at write time and `primary = true`; counters are independent per feed.
- answers preserve full signed 256-bit fidelity, including values beyond 128 bits.
- a mixed batch lands the valid entries, soft-skips the rest, and returns success; two accepts
  emit exactly two `FeedUpdated` and nothing else; two feeds in one batch land independently
  with correct event fields; a stale entry on one feed does not corrupt a sibling accept.

## Cache — reads
- `latest_round`: absent → none; returns the newest; still returns the tip after the tip's
  temporary round entry has expired; batch preserves order and handles duplicates and missing
  ids; frozen feeds read normally; empty ids → empty.
- `get_round`: by id; none when absent; explicit-id reads share the retention window with
  ranges; the tip survives expiry but a non-tip round does not.
- `round_range`: empty without rounds; full history oldest-first; inclusive bounds; expired
  rounds drop out of a full range; the window shrinks immediately when the TTL drops; grows at
  `grow_at_ledger`.
- `find_round`: empty feed → none; `AtOrBefore` picks the newest qualifying; `AtOrAfter` picks
  the oldest qualifying; between two rounds picks the correct neighbour; before the earliest /
  after the latest → none for the respective bound; exact timestamp match; returns the tip
  after history expires; window shrink/grow behave as for ranges.
- `decimals`: always 18 for configured feeds; none when unconfigured; batch semantics; frozen
  feeds read normally; empty → empty.
- `description`: stored value; none when unconfigured; may be empty string; batch; frozen
  reads normally; empty → empty.
- `is_configured` tracks the config and agrees with `decimals`/`description` presence; batch.
- `is_frozen`: batch preserves order, duplicates and missing; empty → empty.

## Cache — retention window (through the public interface)
- a new round's lifetime is `min(3_110_400, network maximum)`; overwriting never re-pins;
  refresh restores to full.
- window switches width exactly at `grow_at_ledger`; shrinks immediately when TTL drops; grows
  at the expected ledger when TTL rises; a second change replaces the pending plan; same-ledger
  writes share the window; raised TTL reaches only new rounds; lowered TTL reaches new rounds
  immediately; a network maximum below the fresh minimum stays safe; a write after the grow date
  locks in the grown width.

## Proxy — constructor / lifecycle
- stores the owner and routes reads to the given cache; refreshes the instance lifetime.
- `version() == 1`; `type_and_version() == "DataFeedsProxy 1.0.0"`; two-step ownership;
  `recover_tokens`; `upgrade` to a self-built artifact keeps address and routing.
- error codes 50/51/52 lie in 50–99 and are disjoint from the ownership library's codes.

## Proxy — reads (against a mock cache **and** against the real Cache)
- `latest_round` returns the newest; no rounds → 50; refreshes the instance lifetime and the
  `MinDecimals` lifetime; a Cache error traps the read with the Cache's code; a frozen feed
  fails with 109.
- `get_round`: exact round projected; absent → 50; lifetimes as above; frozen → 109.
- `decimals` matches the Cache precision (18); `description` passes through; both refresh
  lifetimes and reject frozen feeds (109).
- `get_min_decimals` returns the configured minimum (18 when unset) and refreshes lifetimes.
- `get_cache` returns the configured cache and refreshes the instance lifetime.
- precision: with no minimum set, only 18 is accepted; reads scale down to the requested
  precision; below the minimum → 51; above 18 → 51; zero decimals truncates to the integer
  part; negative answers truncate toward zero; a non-zero (positive or negative) answer that
  scales to zero → 52; a genuine zero passes at any precision; `get_round` scales like
  `latest_round`; a configured minimum with no data → 50; reads never create a `MinDecimals`
  entry; invalid precision fails before the Cache is consulted.
- against the real Cache: end-to-end reads; scaling of real answers; a configured feed without
  rounds → 50 below full precision; every read on an unconfigured feed → 50.

## Proxy — admin
- `set_cache` by non-owner **(host)** fails; by owner swaps routing and emits `CacheSet`;
  refreshes the instance lifetime; after a swap, round ids resolve only against the new Cache
  (an old round id absent in the new Cache → 50).
- `set_min_decimals` by non-owner **(host)** fails; `min > 18` → 51; sets the entry lifetime on
  first write and re-pins on update; refreshes the instance lifetime; emits `MinDecimalsSet`;
  restoring 18 re-locks the feed.
- lifecycle end-to-end: proxy self-upgrade keeps routing; Cache self-upgrade keeps latest and
  historical rounds and keeps operating; the cache is swappable.
