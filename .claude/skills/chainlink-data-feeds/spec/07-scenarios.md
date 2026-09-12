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

## Additions used by the corpus (normative; `scenarios.json` `_readme` restates them)

- **`constants` / `macros`** objects at the top of the file. Macro `seed`:
  `{"step":"seed","on":C,"data_id":D,"as":S,"n":N}` = for k in 1..=N: `advance {to: 100+k}`
  then `on_report` as S with default metadata (`owner:0x11`, `name:0x22`, cid `zero32`,
  report_id `0x0000`) and one entry `{data_id: D, answer: k*100, timestamp: k*10}`, expected ok.
- `advance` also takes `{"to": n}` — set the sequence to absolute `n` (environment starts at 0;
  every `to` is monotone within a scenario).
- `{"step":"age_ttl"}` — advance to half the network maximum so every refreshable lifetime is
  measurably below the maximum; requires `expiry`.
- `expect_ttl.is` also accepts `"below_max"`. Keys: `record` is `instance`, or
  `FeedConfig`/`FeedState`/`MinDecimals` with `data_id`, `FeedAdmin` with `admin`,
  `Permission` with `data_id`+`sender`+`owner`+`name`.
- `expect_events.ordered: true` — the listed events must appear in that relative order.
- `deploy` also takes `what: mock_cache | mock_cache2` (bound to the names `cache`/`cache2`): a
  Cache double with injectable state, used by every Proxy unit scenario. State is set with
  `{"step":"mock_cache","on":…,"data_id":D,"rounds":[…],"latest":{…},"frozen":bool,"fail_with":code}`
  (only the given fields change). The double answers `decimals([..])` with 18 and
  `description([..])` with `"MOCK"` for any id; `latest_round`/`get_round` from `latest`/`rounds`
  (`null` when unset); `is_frozen` from `frozen` (false when unset); once `fail_with` is set,
  every `latest_round`/`get_round`/`decimals`/`description` call returns that Cache error
  (`is_frozen` still answers). Rounds carry `round_id`, `answer`, `timestamp`.
- `{"step":"expect_balance","token":"token","of":ACTOR,"is":n}` — token balance of an actor.
- `{"step":"expect_error_codes","contract":C,"codes":{Name:code},"range":[lo,hi],"ownership_range":[lo,hi]}`
  — static assertion on error numbering (see `06` E).
- `call.expect` also accepts `{"decode_fail": true}` — the platform decoder's failure for
  undecodable report bytes (`06` F.2; `MalformedReport` where the decoder returns an error).
- `on_report` takes `args: {sender, report}`; the test splits `report` into the metadata and
  body byte arguments. `report.trailing_bytes` (hex) is appended after the canonical body;
  `raw_metadata`/`raw_report` replace the encoded form verbatim.
- `expire_round` carries `on`.
- **Value matching** in `expect.value`: an object asserts only the fields it lists (partial match); a list asserts length and each element positionally; `null` asserts absence/None; `"_"` matches anything at that position; `"some"` matches any non-null value. Addresses are actor names or contract names (`cache`, `cache2`, `proxy`). Answers are decimal strings. `bound` is `AtOrBefore`|`AtOrAfter`. Permissions in values/events/entries are `{sender, owner, name}` (the spec's `allowed_sender`, `allowed_workflow_owner`, `allowed_workflow_name`).

## Harness portability rules

- **Harnesses that cannot continue after a failure** (an abort ends the test): run every
  non-failing step first, then the failing `call` as the terminal statement under the
  harness's expected-failure attribute. This is sound only because no scenario has a
  state-changing step after a failing call. A scenario with *k* failing calls becomes one test
  named `<id>` (first failing call) plus companion tests `<id>__alt2` … `<id>__altk`, each
  ending in the next failing call; the coverage grader counts the `<id>` test.
- **`fail_with` on statically-linked platforms** (`06` L.2, the mock is the real Cache module):
  the scenario's asserted property is "a Cache failure surfaces through the Proxy with the
  Cache's own code and origin, untranslated". Realise it by routing the Proxy at an address
  with no Cache instance and asserting the Cache's host failure propagates; record this
  substitution in the decision log.
- **`expect_events.ordered`** where the harness cannot observe cross-type order: assert all
  listed events were emitted by the call and keep the emission order in the code; note it.
- **Events that accumulate over a test** (no per-call log): snapshot per-type counts before
  the call and assert the delta for `only`/`count`.
- **`advance {to: n}`** with `n` equal to the current sequence is a no-op; a lower `n` is a
  scenario error.
- **Mock Cache scope**: "answers for any id" may be realised only for the ids the corpus
  actually uses (all mock scenarios use `id:1`); `frozen` without rounds may need a test-only
  state record with a zero tip.
- **`expect_error_codes.ownership_range`** is `[2100, 2299]` and covers both the owner codes
  (2100–2102) and the pending-transfer codes (2200–2203).
- **Dropped arguments** (`06` A.2): the corpus still carries `sender`/`admin` in `args`; on
  caller-identity platforms the harness ignores them and uses `as`.
- **`find_round` without `lo`/`hi`** on declared-record platforms: supply `1..=tip`.
  `round_range` accounts: `max(from,1)..=min(to,tip)`.
- **`recover_tokens` on token-account platforms**: `to: <actor>` resolves to a token account
  of that actor created by the harness; `mint {to: "cache"}` credits a token account owned by
  the contract's authority; `expect_balance` reads the actor's token account.
- **Native failures beyond `host_fail`**: a harness may add `{"host_error": <name>}` for
  platform-specific variants; the corpus itself never needs it.
