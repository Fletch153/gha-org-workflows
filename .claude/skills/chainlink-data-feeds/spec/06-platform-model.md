# 06 — Platform model: how the spec maps onto any chain

The behavioural spec (`01`–`05`) is written against an abstract platform. Real chains differ
along the axes below. For each axis this file gives (a) the abstract notion the spec relies
on, (b) the **rule** that decides the realisation on any chain, and (c) what an overlay must
state. These rules **take precedence** over the byte-for-byte naming rule in `SKILL.md`
wherever a platform cannot express the spec's form directly; everything else in `01`–`05`
stays normative. An overlay may only *instantiate* these rules (fill in platform facts); it
may not contradict them. If, after applying these rules and the overlay, a choice is still
open, log it in `DECISIONS.md` — the goal is that this file leaves nothing open.

## A. Account and authorisation model

Abstract notion: "host-authorise `x`" — the platform proves the caller is `x`.

Rule:
1. If the platform can prove authorisation for an arbitrary address named in the arguments
   (per-argument auth, e.g. Soroban `require_auth`), the spec's `sender`/`admin` arguments
   stay on the interface and are authorised that way.
2. If the platform only proves the **caller's** identity (EVM `msg.sender`, Solana signer
   accounts, Move `signer`), the authorised principal **is the caller**: the `sender`/`admin`
   argument is **removed** from the interface (it would be redundant and a spoofing footgun),
   and every rule in the spec that reads "host-authorise `sender`" reads "the caller is the
   sender". Events and records that carry `sender` use the caller identity.
3. Host authorisation failures are the platform's native failure (a missing signer, an
   unauthorised caller), never a spec error code. On platforms where every failure is a
   contract revert, use a dedicated error *type* that lies outside all numeric ranges.
4. The owner is a stored address, not the deployer implicitly. Constructors take `owner`.

Overlay states: which case applies; what the caller identity is; the host-failure form.

## B. Storage model

Abstract notion: the spec's *records* (`FeedAdmin`, `FeedConfig`, `Permission`, `FeedState`,
`Round`, `MinDecimals`, `Cache`) are addressable entries with presence semantics.

Rule:
1. Each record maps to the platform's native addressable unit keyed by the spec key:
   key-value entry (Soroban), storage mapping (EVM), a program-derived account whose seeds
   are the key tuple (Solana), a resource/table item (Move). The key tuple's components and
   order are as given in `02`/`03`.
2. Presence: use the platform's presence primitive (entry `has`, account exists). Where none
   exists, a record is present iff a field that is never zero for a written record is
   non-zero (`FeedConfig` → non-empty permissions; `FeedState`/`Round` → `round_id != 0`;
   sets → boolean). `MinDecimals` is the exception — `0` is a valid minimum — so it carries an
   explicit presence flag.
3. "Instance" storage (the contract's own singletons: owner, `Cache`) lives in the
   contract's own state unit (instance storage, contract storage slots, a config account).
4. Storage layout (keys, seeds, slot order, account layouts) is part of the upgrade contract
   and must be stated by the overlay if the platform supports upgrades.
5. Who pays for storage: where writes require an explicit payer (rent, account creation),
   the payer is the transaction's fee payer / the authorised caller of that entry point; the
   contract never fronts storage costs.

Overlay states: the unit per record, the presence mechanism, the payer.

## C. State expiry and history retention

Abstract notion: rounds are retained for `DATA_RETENTION_TTL` ledgers; older history is not
served. Configuration and state records live as long as the contract is used.

Rule:
1. The **retention window of `04` is behaviour, not an optimisation, and is realised on every
   chain**: a non-tip round is readable iff it exists and lies inside the window computed
   from `ledger_seq`. The tip is always readable.
2. Platforms **with expiry** (TTL/rent that deletes entries): apply the lifetime rules of `04`
   literally (pin, refresh, temporary rounds never refreshed).
3. Platforms **without expiry**: every "pin/refresh lifetime" is a no-op; the "network
   maximum" is unbounded so `round_ttl = DATA_RETENTION_TTL`; rounds are never deleted by the
   contract. Readers whose only writes were lifetime refreshes become pure reads. The window
   arithmetic of `04` is still implemented in full; the `05` conditions that vary the TTL are
   tested directly against the window helper (the public interface cannot vary it), the
   lifetime-refresh conditions are tested as persistence, and the "network maximum below the
   minimum entry lifetime" condition does not apply.
4. Platforms with **rent-exempt persistent accounts** (Solana): as 3, and the overlay may
   add a permissionless *reclaim* of a round that is no longer readable (returning rent to
   its payer). Reclaim must not affect any readable round or the tip; if the overlay does not
   define it, it does not exist.
5. `ledger_seq` is the platform's monotonically increasing sequence (ledger, block, slot),
   stored at the spec's width (u32) by truncating cast, no extra validation. Timestamps in
   reports are never compared with chain time.

Overlay states: which case; the sequence source; reclaim (if any).

## D. Transaction, compute and size limits

Abstract notion: batch entry points (`set_feed_configs`, `remove_feed_configs`,
`set_feed_frozen`, `on_report`, batch readers) take unbounded lists.

Rule:
1. The spec imposes no batch cap; the platform's transaction limits bound batches. Never
   silently truncate or partially apply a batch: a batch that does not fit fails as a whole
   with the platform's native limit failure (or, where every touched record must be declared
   up front, with a dedicated "record not supplied" error type outside all numeric ranges).
2. Where the caller must declare touched records in advance (Solana accounts), the overlay
   defines the declaration convention (ordering, derivation) and the entry point validates
   every supplied record against its expected derivation before use.
3. Code size limits (e.g. 24 KiB EVM) are met by internal module/library splitting, never by
   dropping behaviour or splitting one logical contract into two deployables with different
   entry points. Two deployables total: Cache and Proxy.
4. Deep history reads (`round_range` over long ranges, `find_round` on long histories) are
   allowed to be bounded by compute limits; they must never return partial results as if
   complete — they fail with the platform's limit failure.
5. Where the caller must declare every record a read touches (D.2), the history reads
   `round_range` and `find_round` take the round records for one contiguous id range the
   caller chose, and their result is defined **relative to that range**: `round_range`
   iterates the intersection of `[from, to]` with the supplied range; `find_round` searches
   the supplied range (the overlay adds explicit `lo`/`hi` arguments naming it). The tip is
   always taken from `FeedState`, never from the supplied range.

Overlay states: the concrete limits and the declaration convention.

## E. Error signalling

Abstract notion: errors are identified by numeric code in disjoint ranges (Cache 100–199,
Proxy 50–99, ownership 2100–2299).

Rule:
1. Every spec error is realised as the platform's native error primitive carrying **exactly**
   that code: contract-error enums (Soroban), `Custom(code)` program errors (Solana), one
   typed error per family carrying the code (EVM `error CacheError(uint32 code)`).
2. Names are kept as constants/enum variants alongside the codes.
3. A failure propagates across contracts with the callee's type and code unchanged.
4. Host failures (auth, decode traps, limits) are never given a spec code (see A.3, D.1).

Ownership error table (complete): `OwnerNotSet = 2100`, `TransferInProgress = 2101`,
`OwnerAlreadySet = 2102`, `NoPendingTransfer = 2200`, `InvalidLiveUntilLedger = 2201`,
`InvalidPendingAccount = 2202`, `TransferExpired = 2203`.

## F. Serialisation

Rule:
1. `encode(x)` in the permission hash is the platform's canonical typed serialisation of the
   value (XDR, ABI encoding, Borsh). Concatenate the three encodings and hash with keccak256.
2. The report body is the canonical serialisation of `List<ReportEntry>` and must decode
   **exactly**: undecodable, truncated, non-canonical or trailing bytes are a decode failure.
   A decode failure is `MalformedReport` (100) unless the platform's decoder traps before
   contract code can map it, in which case that trap is the behaviour.
3. Metadata is the raw 64-byte layout of `02` on every chain (no platform serialisation).

## G. Optional values and results

Rule:
1. `Option<T>` uses the platform's native optional if it has one (Soroban `Option`, Borsh
   `Option`). Otherwise a `{present: bool, value: T}` struct; an optional **address** may
   instead use the platform's zero/default address as "absent".
2. `Result<T, E>` is the platform's native return/failure channel; readers that never fail
   simply return `T` on platforms without a `Result` type.

## H. Events

Rule:
1. Event name and field names/order are as in the spec. "Topic fields" use the platform's
   indexing mechanism (Soroban topics, EVM `indexed`); on platforms without indexing the
   fields are emitted in order with the name as the first element.
2. Events are emitted only on success and are rolled back with the call on failure; where a
   platform's *test harness* does not roll logs back, tests assert atomicity via state.

## I. Upgradeability

Abstract notion: `upgrade(new_code_ref)` replaces the code behind the same address, keeping
state; owner-only; emits `Upgraded`.

Rule:
1. If the platform has a **native** in-place code replacement invocable from the contract
   (Soroban `update_current_contract_wasm`), realise `upgrade` with it.
2. If the platform has a native upgrade mechanism **outside** the contract (Solana
   upgradeable loader), omit `upgrade`/`Upgraded` from the interface and state in the overlay
   that the loader's upgrade authority is the owner's responsibility.
3. If the platform has **no** native mechanism (EVM), omit `upgrade`/`Upgraded`. Do **not**
   emulate with delegatecall/proxy patterns. The migration path is a new deployment plus the
   Proxy's `set_cache`.
4. In all cases the storage layout is documented. The self-upgrade test conditions of `05`
   and the "upgrade-related tests" step of `SKILL.md` apply only where rule 1 holds; under 2
   and 3 the resurrection and cache-swap conditions are tested without the upgrade step, and
   a test asserts that no `upgrade` entry point exists.

## J. Ownership and time

Rule: use the ownership library the overlay names (its exact behaviour is normative);
otherwise implement **exactly** the following, with `now` = the platform sequence unit of C.5.
Ownership events carry no topic fields.

- **Owner gating** (every owner-only function): no owner recorded → `OwnerNotSet` (2100);
  then host-authorise the recorded owner.
- **`transfer_ownership(new_owner, live_until_ledger)`** — owner-gated, then:
  - `live_until_ledger == 0` → *cancel*: no pending offer → `NoPendingTransfer` (2200);
    pending address ≠ `new_owner` → `InvalidPendingAccount` (2202); else remove the offer.
  - otherwise: `live_until_ledger < now` (or above the platform's maximum offer horizon,
    where one exists) → `InvalidLiveUntilLedger` (2201); else store `{new_owner,
    live_until_ledger}`, replacing any previous offer.
  - in both branches, on success emit `ownership_transfer { old_owner, new_owner,
    live_until_ledger }` with the arguments as passed.
- **`accept_ownership()`** — no pending offer → `NoPendingTransfer` (2200); `now >
  live_until_ledger` → `TransferExpired` (2203); host-authorise the pending address; set it as
  owner; clear the offer; emit `ownership_transfer_completed { new_owner }`.
- **`renounce_ownership()`** — owner-gated; a pending offer with `now <= live_until_ledger`
  → `TransferInProgress` (2101) (an expired offer is simply discarded); clear the owner; emit
  `ownership_renounced { old_owner }`.
- **`get_owner()`** — the recorded owner or absent.
- `OwnerAlreadySet` (2102) belongs to the internal set-owner helper (constructor path) and is
  unreachable through the public interface; define it for table completeness.

## K. Naming and numeric widths

Rule:
1. The spec spellings are canonical. An overlay may declare one **mechanical** case
   transformation for public identifiers (e.g. snake_case → camelCase for EVM functions,
   arguments, event and struct fields) applied uniformly; no other renaming.
2. Type widths are as in `01` except where the overlay maps a spec type to the platform's
   native equivalent: token amounts use the platform's native token amount type
   (`i128` Soroban, `uint256` EVM, `u64` Solana); addresses use the native address type.
   `recover_tokens` hands `amount` to the token's own transfer unchanged; any failure the
   token signals (revert, `false`, missing code) fails the call with a host-style error type
   outside all numeric ranges — the contract adds no validation of its own.
3. `DECIMALS` and every `decimals`/`min` value are u32 (or the platform's nearest unsigned
   width, stated by the overlay).

## L. Cross-contract calls

Rule: the Proxy calls the Cache through the platform's native cross-contract mechanism using
the Cache's public function names; on account-model platforms the Cache's records the Proxy
needs are declared by the caller per D.2, and the Proxy validates their derivation.
