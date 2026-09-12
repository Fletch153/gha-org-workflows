# Chain overlay — <CHAIN> (<language> / <toolchain>)

Instantiation of `spec/06` for <CHAIN>. Mechanics only; behaviour is in `spec/`. Every
`<...>` must be replaced with a concrete statement; every axis must be answered even when the
answer is "as the spec". Use the **defaults** given in each axis unless the platform makes
them impossible; when you deviate from a default, the reason goes in the decision log.

## Platform facts (per `spec/06` axis)

- **capabilities:** `[<tags from spec/07: per_arg_auth, expiry, network_max_variable, in_contract_upgrade, external_upgrade, rent_reclaim, events_indexed>]`

- **A. Account model** — <case A.1 (per-argument auth: name the primitive) or A.2
  (caller identity: name it — `msg.sender`, signer account, `&signer`, …)>. <Which spec
  arguments are dropped (A.2: `sender` on `on_report`, `admin` on the three admin batches;
  never lookup keys).> Host failures: <the native failure, or a dedicated error type outside
  all numeric ranges, named here>. Default: A.2 if the platform has no per-argument auth.
- **B. Storage** — <the native unit for each record: `FeedAdmin`, `FeedConfig`, `Permission`,
  `FeedState`, `Round`, `MinDecimals`, and the instance singletons (owner, pending owner,
  `Cache`)>; <key/seed/slot derivation for each>; <presence mechanism>; <storage payer>;
  <if a record needs a discriminator/type tag: values>; <fixed vs variable size, resize and
  refund rules>. Default: one unit per record keyed exactly by the spec key tuple.
- **C. Expiry** — <case C.2 (expiry: name the TTL API and the tiers) / C.3 (none) / C.4
  (rent: reclaim instruction defined here — accounts, check order, error `RoundStillReadable = 111`)>.
  Sequence unit: <ledger / block / slot / version, and the API to read it>. Default: window
  realised in full; lifetimes no-op without expiry; reclaim only under C.4.
- **D. Limits** — <code size, tx size, compute/gas, return-data cap, accounts-per-tx>; <the
  declaration convention if records must be declared up front, else "none">. Default: no
  batch cap beyond the platform's; explicit `lo`/`hi` on `find_round` only when records must
  be declared.
- **E. Errors** — <the native primitive carrying the numeric code: enum / `Custom(code)` /
  typed error per family>; <how the names are kept>; <native variants used for host
  failures: wrong program, missing record, bad instruction data, …>.
- **F. Serialisation** — <canonical typed serialisation used for `encode(x)` and for the
  report body; the strict-decode failure form (error vs trap)>.
- **G. Optionals** — <native optional, or `{present, value}`; optional address encoding>.
- **H. Events** — <the emission primitive; how topic fields map (indexed / ordered)>.
- **I. Upgrade** — <case I.1 (in-contract: API) / I.2 (external loader: authority = owner) /
  I.3 (none)>. Default: never emulate.
- **J. Ownership** — <library name + version if one exists with two-step + expiry semantics;
  otherwise "implement the `spec/06` J table">; <unit of `live_until_ledger`>.
- **K. Naming** — <case convention for public identifiers, or "spec spelling">; <token amount
  type>; <address type for `workflow_owner`>; <widths for u32 values>.
- **L. Cross-contract** — <the call mechanism the Proxy uses to reach the Cache; how the
  callee's error propagates; how the Proxy raises `FeedFrozen` (109) and how that is
  distinguished from a propagated Cache error; any records the caller must declare>.
- **M. Interface surface** — <constructor name and full argument order (signer, instance-model
  arguments, then `owner`[, `cache`]); entry points that cannot take/return structs and the
  script/constructor workaround; accessor and constructor names for public records; whether
  admin reads are `Result`-wrapped>.
- **Retention constant** — <nominal seconds per sequence unit → `DATA_RETENTION_TTL = …`
  (180 days, `spec/04`)>.

## Toolchain

- <compiler/SDK name and exact version; how it was obtained (prefer offline/local; GitHub
  releases if a download is needed)>. <Any environment variable or config the build needs.>
- <test framework and how tests are run>. <Any known pitfalls of the test environment.>

## Layout and commands

- <project layout: crate/package names, module split; two deployables: Cache and Proxy>.
- Build: <command per deployable> → <artifact path pattern>. Tests: <command>.
- <dependency pins that are known to be required>.

## Type vocabulary

| Spec | <CHAIN> |
|---|---|
| `data_id`, `workflow_cid`, hashes (32 bytes) | <type> |
| `workflow_owner` (20 bytes) | <type> |
| `workflow_name` (10 bytes) | <type> |
| `report_id` (2 bytes) | <type> |
| `answer` (I256) | <type or encoding> |
| `String` | <type> |
| `List<T>` | <type> |
| `Bytes` | <type> |
| `Address` | <type> |
| records | <struct mechanism; whether field names/order are ABI> |
| `Bound` | <enum mechanism> |
| events | <mechanism> |

## Interface encoding and account conventions (part of the ABI)

<How entry points are addressed (function names / instruction tags in a fixed order) and
what each takes beyond the spec arguments (accounts, capabilities, signers). If nothing
beyond the spec arguments is needed, say so.>

## Testing notes

<How to: set the caller; assert native and coded failures; assert events (exact fields, and
"only" conditions); move the sequence; vary the network maximum (if C.2); deploy a mock
Cache for Proxy unit tests (and the `fail_with` substitution on statically linked platforms);
mint a token for `recover_tokens`; emulate round expiry (`expire_round`); read lifetimes
(`expect_ttl`, `age_ttl`) where `expiry` holds; assert record presence (`expect_state`); the
`by_retention` roll; test naming (`<id>` with dots → underscores); run upgrade conditions
(I.1) or assert the entry point is absent (I.2/I.3).>

## Decision log

Same format as `SKILL.md` step 6. With this overlay and `spec/06` applied there should be
no `[ABI]` or `[BEHAVIOUR]` entries; any that remain are written back into this overlay by
the run that produced them (SKILL.md step 7).
