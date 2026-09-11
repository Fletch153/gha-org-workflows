# 07 — Conformance scenarios

`spec/scenarios.json` is the executable form of `05-tests.md`: every scenario is one test.
It is written in the spec's own vocabulary (function names of `02`/`03`, error codes, event
names and fields, actor roles), so each chain's implementation translates it into its native
test framework mechanically — one test per scenario, named `<id>` (case-converted if the
platform requires). Grading is the pass rate over applicable scenarios.

## Applicability

Each scenario lists `requires`: platform capability tags, all of which must be declared by
the overlay (`capabilities:` in its "Platform facts") for the scenario to apply. A scenario
whose tags are not all satisfied is **not implemented**; it is listed in the decision log
under `[TEST-TECHNIQUE]` with the `spec/06` rule that makes it inapplicable. Never adapt an
inapplicable scenario into something weaker.

| Tag | Meaning | Rule |
|---|---|---|
| `per_arg_auth` | the platform can prove authorisation for an address named in the arguments | `06` A.1 |
| `expiry` | stored entries have TTLs that can be read, pinned and refreshed | `06` C.2 |
| `network_max_variable` | the test harness can change the network's maximum TTL | `06` C.2 |
| `in_contract_upgrade` | the contract can replace its own code in place | `06` I.1 |
| `external_upgrade` | an external loader/publisher can replace code keeping state | `06` I.2 |
| `rent_reclaim` | the overlay defines `reclaim_round` | `06` C.4 |
| `events_indexed` | the platform indexes topic fields | `06` H.1 (assertions on topic vs data placement) |

A scenario with `requires: []` applies everywhere.

## Actors

Actors are named roles bound at scenario setup: `owner`, `admin`, `admin2`, `sender`,
`sender2`, `stranger`, `new_owner`, `payer`. `as` on a step is the caller identity: on A.1
platforms it is the address that must authorise; on A.2 platforms it is the transaction
caller/signer. `"as": "unauthorised"` means "the call is made without the required
authorisation" and is only meaningful on `per_arg_auth` platforms.

## Values

- `data_id`, hashes: 32-byte hex (`"0x…"`); `workflow_owner`: 20-byte hex; `workflow_name`:
  10-byte hex; `workflow_cid`: 32-byte hex; `report_id`: 2-byte hex. Short forms
  `"id:7"` = 32 zero bytes with byte 15 = 7 (the reference's `mock_feed_id`), `"wire:7:0xBB"` =
  byte 15 = 7 and byte 31 = 0xBB, `"owner:0x11"` = 20 bytes of 0x11, `"name:0x22"` = 10 bytes
  of 0x22, `"zero32"`/`"zero20"`/`"zero10"`.
- Answers (`I256`): decimal strings, may be negative or beyond 128 bits.
- Addresses: actor names, `"cache"`, `"proxy"`, `"cache2"`, `"token"`, or `"zero_address"`.
- `report`: `{ "metadata": { "owner": …, "name": …, "cid"?: …, "report_id"?: … },
  "entries": [ { "data_id", "answer", "timestamp" } ] }` — the test encodes metadata as the
  64-byte layout and the entries with the platform's canonical serialisation (`06` F).
  `"raw_metadata": "0x…"` / `"raw_report": "0x…"` give bytes verbatim for malformed cases.
- `FeedConfigEntry`: `{ "data_id", "description", "permissions": [ { "sender", "owner", "name" } ] }`.
- Optionals: `null` = absent.

## Steps

| Step | Fields | Meaning |
|---|---|---|
| `deploy` | `what: cache|proxy|cache2|token`, `owner`, `cache`? | deploy an instance; `cache2` is a second Cache; `token` a fungible token whose `mint` step credits the contract |
| `call` | `on: cache|proxy|cache2`, `fn`, `as`?, `args` (object keyed by spec argument name), `expect` | invoke; `expect` is one of `{"ok": true}`, `{"value": …}`, `{"error": <code>}`, `{"host_fail": true}`, `{"cache_error": <code>}` (a Cache code surfacing through the Proxy) |
| `advance` | `ledgers: n` | move the sequence forward by `n` units |
| `set_network_max` | `ttl: n` | requires `network_max_variable` |
| `expire_round` | `data_id`, `round_id` | test-only: remove the stored round entry (emulates TTL expiry) |
| `mint` | `to`, `amount` | mint `amount` of `token` to an address |
| `expect_events` | `on`, `events: [ { "name", "fields": {…} } ]`, `only`?: true, `count`?: n | events emitted by the last `call`; `only` = exactly these and nothing else; fields omitted are not asserted |
| `expect_state` | `on`, `present`/`absent`: record descriptor | presence of a record by spec key, e.g. `{ "record": "MinDecimals", "data_id": … }` |
| `expect_ttl` | `on`, `record`, `key…`, `is: "max"|"unchanged"|n` | requires `expiry` |
| `upgrade_self` | `on` | requires `in_contract_upgrade` or `external_upgrade`: replace code with a fresh self-build |
| `upgrade_to_peek` | `on` | requires `in_contract_upgrade`: replace with a distinct artifact exposing `peek()` and expect `peek()` to answer |

Multi-step scenarios execute in order against one fresh environment. Steps after a failing
`call` are still executed (the failure is expected and asserted).

## Scenario object

```
{ "id": "cache.on_report.equal_or_older_timestamp_is_stale",
  "source": "data-feeds-cache/src/tests/writer.rs::on_report::equal_or_older_timestamp_is_stale_and_emits_event",
  "requires": [],
  "steps": [ … ] }
```

`id` is `<contract>.<function or group>.<condition>` in snake_case and is the test name.
