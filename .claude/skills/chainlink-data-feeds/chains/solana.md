# Chain overlay — Solana (native Rust, Borsh, program-test)

Instantiation of `spec/06` for Solana. Mechanics only; behaviour is in `spec/`.

## Platform facts (per `spec/06` axis)

- **A. Account model** — case A.2. The authorised principal of an instruction is a
  **signer account** in a fixed position (see account conventions). `sender`/`admin`
  arguments are dropped from instruction data. Owner-only instructions require the owner
  recorded in the config account to sign. Host failure = `ProgramError::MissingRequiredSignature`
  (no numeric code).
- **B. Storage** — every record is a **PDA of the program**, seeds = the spec key, Borsh
  payload with a 1-byte record-type discriminator first. Presence = the account exists and is
  owned by the program. Instance singletons live in a **config PDA**. Creating an account is
  paid by a writable signer `payer` account supplied to the instruction (rent-exempt
  minimum, system program CPI). Seeds (byte strings, then key components in order):

  | Record | Seeds |
  |---|---|
  | Cache config (owner, pending owner + live_until) | `["config"]` |
  | `FeedAdmin(admin)` | `["admin", admin]` |
  | `FeedConfig(data_id)` | `["feed_config", data_id]` |
  | `Permission(data_id, phash)` | `["permission", data_id, phash]` |
  | `FeedState(data_id)` | `["feed_state", data_id]` |
  | `Round(data_id, round_id)` | `["round", data_id, round_id as u64 little-endian]` |
  | Proxy config (owner, pending, cache) | `["config"]` |
  | `MinDecimals(data_id)` | `["min_decimals", data_id]` |

  Round accounts additionally store the `payer` pubkey (outside the `RoundData` ABI) for reclaim.
  Record-type discriminators: Cache — config 1, `FeedAdmin` 2, `FeedConfig` 3, `Permission` 4,
  `FeedState` 5, `Round` 6; Proxy — config 1, `MinDecimals` 2. Unit records hold only the
  discriminator. Config accounts are allocated at the maximum Borsh size of their layout and
  zero-padded (a pending offer must fit without resizing); deserialisation tolerates trailing
  zero bytes. Deleting a record refunds its lamports to the instruction's `payer`; within one
  instruction, closes happen after all creations (the runtime requires balanced lamports at
  every CPI boundary), and a permission present in both the old and the new list of a
  `set_feed_configs` entry is kept in place rather than deleted and recreated. Overwriting a
  variable-size record (`FeedConfig`) resizes the account, topping up rent from `payer` when it
  grows and refunding nothing when it shrinks.
- **C. Expiry** — case C.4. Sequence unit is `Clock::get()?.slot` truncated to u32.
  Reclaim **is defined**: a permissionless instruction `reclaim_round(data_id, round_id)`
  closes the round account and refunds its lamports to the recorded payer, allowed only if
  the round is a non-tip round that is **not readable** (outside the window). Otherwise
  error `RoundStillReadable = 111` (Cache range). Accounts: `[feed_state, round (w), payer (w)]`;
  `payer` must equal the recorded payer (`ProgramError::InvalidArgument`); a missing round or
  state is `ProgramError::UninitializedAccount`.
- **D. Limits** — 1232-byte transactions, ~1.4M compute units, every touched account
  declared. Account declaration convention: fixed accounts first (listed per instruction
  below), then per-item accounts in item order. Uninitialised records are passed as their
  derived address (system-owned, zero data) and read as absent. Wrong or missing accounts
  fail with native `ProgramError::InvalidSeeds` / `NotEnoughAccountKeys` (no numeric code).
  History reads take an explicit contiguous id range per `06` D.5: `round_range(data_id,
  from, to)` uses supplied rounds for `[from, to]`; `find_round(data_id, timestamp, bound,
  lo, hi)` searches `[lo, hi]`.
- **E. Errors** — `ProgramError::Custom(code)` with the spec codes; names as an enum.
  `initialize` on an existing config → `OwnerAlreadySet` (2102); any other instruction whose
  config account does not exist → `ProgramError::UninitializedAccount`.
- **F. Serialisation** — Borsh for `encode(x)` (`Pubkey` = 32 bytes, `[u8;20]`, `[u8;10]`)
  and for the report body (`Vec<ReportEntry>`, `try_from_slice` — trailing bytes are a
  failure → `MalformedReport`).
- **G. Optionals** — Borsh `Option<T>`.
- **H. Events** — `sol_log_data` with slices `[event_name_bytes, borsh(field_1), …]` in
  spec field order (topic fields first, then data fields).
- **I. Upgrade** — case I.2: no `upgrade`/`Upgraded`; the BPF upgradeable loader's authority
  is operated by the owner off-chain.
- **J. Ownership** — no library; implement the table in the config PDA; `live_until_ledger`
  in slots.
- **K. Naming** — spec spelling (snake_case is native). Token amount `u64` (SPL Token
  transfer by CPI, signed by the config PDA which owns the program's token accounts).
  Address = `Pubkey`. `I256` answers: `ethnum::I256`, Borsh-encoded as 32 bytes
  little-endian two's complement (`RoundData.answer` is `[u8; 32]` on the wire).
- **L. Cross-contract** — the Proxy invokes Cache reader instructions by CPI (`invoke`)
  passing through the caller-supplied Cache accounts, and reads results from
  `get_return_data`. Readers on both programs publish their result with
  `set_return_data(borsh(result))`; off-chain callers use transaction simulation return data.

## Readers as instructions

Every reader in the spec is an instruction with no signer requirement; its result is Borsh
in return data. Proxy readers CPI the Cache and then set their own return data.

## Instruction encoding and account conventions (part of the ABI)

Instruction data is a Borsh enum; tags are the variant indices in this order — Cache:
`initialize`, `on_report`, `set_feed_configs`, `remove_feed_configs`, `set_feed_frozen`,
`add_feed_admin`, `remove_feed_admin`, `get_feed_permissions`, `has_permission`,
`is_feed_admin`, `latest_round`, `get_round`, `round_range`, `find_round`, `decimals`,
`description`, `is_configured`, `is_frozen`, `version`, `type_and_version`, `get_owner`,
`transfer_ownership`, `accept_ownership`, `renounce_ownership`, `recover_tokens`,
`reclaim_round`; Proxy: `initialize`, `latest_round`, `get_round`, `decimals`, `description`,
`get_min_decimals`, `get_cache`, `set_cache`, `set_min_decimals`, `version`,
`type_and_version`, `get_owner`, `transfer_ownership`, `accept_ownership`,
`renounce_ownership`, `recover_tokens`. Arguments are the spec's, minus dropped
`sender`/`admin`, plus `lo`/`hi` on `find_round`.

Fixed accounts, in order (s = signer, w = writable); surplus accounts are ignored:

- Cache `initialize(owner)`: `[config (w), payer (s,w), system_program]`.
- `on_report(metadata, report)`: `[sender (s), payer (s,w), config, system_program]`, then
  per entry `[permission, feed_config, feed_state (w), round (w)]` where `round` is the derived
  address for `tip + 1` at the time the entry is processed; `permission`, `feed_config` and
  `feed_state` are validated for every entry, `round` only when the entry appends. The Clock
  sysvar is read by syscall, not passed.
- Admin batches (`set_feed_configs`, `remove_feed_configs`, `set_feed_frozen`):
  `[admin (s), payer (s,w), config, admin_record, system_program]`, then per item:
  `set_feed_configs` → `feed_config (w)`, one `permission (w)` per **old** permission, then one
  per new permission; `remove_feed_configs` → `feed_config (w)` + old permissions (w);
  `set_feed_frozen` → `feed_state (w)`.
- `add_feed_admin` / `remove_feed_admin`: `[owner (s), payer (s,w), config, admin_record (w),
  system_program]`.
- Ownership: `transfer_ownership` / `renounce_ownership`: `[owner (s), config (w)]`;
  `accept_ownership`: `[pending_owner (s), config (w)]`.
- `recover_tokens(token, to, amount)`: `token` is the mint, `to` the destination token
  account; accounts `[owner (s), config, source (w), destination (w), token_program]`; `source`
  must be a token account of that mint owned by the config PDA, which signs the CPI.
- Cache readers: `[config]`, then per id the records the spec names for that reader (e.g.
  `latest_round` → `feed_state` per id; `get_round` → `feed_state, round`; `decimals` /
  `description` / `is_configured` → `feed_config`; `is_frozen` → `feed_state`;
  `get_feed_permissions` → `feed_config`; `has_permission` → `permission`; `is_feed_admin` →
  `admin_record`). `round_range(data_id, from, to)`: `[config, feed_state]` then the round
  accounts for `from..=to` (index `id − from`; accounts above the tip may be omitted).
  `find_round(data_id, timestamp, bound, lo, hi)`: `[config, feed_state]` then rounds for
  `lo..=hi` (index `id − lo`). The tip is answered from `feed_state`; a supplied tip account is
  validated but not read. `version`, `type_and_version`, `get_owner`: `[config]`.
- Proxy `initialize(owner, cache)`: `[config (w), payer (s,w), system_program]`. CPI readers
  (`latest_round`, `get_round`, `decimals`, `description`): `[config, cache_program,
  cache_config, min_decimals]` then the Cache accounts in the Cache's own convention for
  `is_frozen` and the delegated reader (the Proxy validates `cache_program` against the stored
  cache and derives/validates every Cache record before the CPI). `get_min_decimals`: `[config,
  min_decimals]`; `get_cache`, `version`, `type_and_version`, `get_owner`: `[config]`.
  `set_cache`: `[owner (s), payer (s,w), config (w), system_program]`; `set_min_decimals`:
  `[owner (s), payer (s,w), config (w), min_decimals (w), system_program]`; ownership and
  `recover_tokens` as for the Cache.

Document the full table (tags, accounts, seeds, layouts, events, errors) in the project README.

## Toolchain

- Agave 3.1.9 at `~/.local/share/solana3/solana-release/bin` (add to `PATH`); `cargo
  build-sbf` works (platform-tools v1.52 already installed). Host toolchain: stable Rust.
- Crates: `solana-program = "2.3"`, `borsh = "1"`, `ethnum = "1"`, `spl-token = { version =
  "8", features = ["no-entrypoint"] }`; dev: `solana-program-test = "2.3"`, `solana-sdk =
  "2.3"`, `tokio` (macros, rt).
- Workspace at `out_dir`: `crates/data-feeds-common` (types, Borsh, ownership, events,
  errors), `programs/data-feeds-cache`, `programs/data-feeds-proxy` (`crate-type =
  ["cdylib", "lib"]`, entrypoint gated behind a `no-entrypoint` feature so the Proxy can
  depend on the Cache crate for its types).
- Artifacts: `cargo build-sbf --manifest-path programs/<p>/Cargo.toml` → `target/deploy/<p>.so`.
  Tests: `cargo test --workspace` using `ProgramTest` with `processor!` for both programs
  (the Proxy tests load both).

## Testing notes

`ProgramTest::new(name, id, processor!(process))` + `add_program` for the second program;
`banks_client.process_transaction` for writes; `simulate_transaction` → `return_data` for
readers; `context.warp_to_slot(n)` to move the sequence; `banks_client.get_account` to
check presence/absence and rent refunds; events are read from the simulation's
`log_messages` (`Program data:` lines, base64) — `solana-program-test`'s native processor does
not route `sol_log_data` into the log, so on non-SBF builds mirror the exact `Program data:`
line through `program_stubs::sol_log` (the SBF build uses `sol_log_data`). Host failures assert
the native `ProgramError` variant; spec errors assert `Custom(code)`. Set the bank's compute
limit to 1.4M CU; return data is capped at 1024 bytes (long `round_range` results abort with
the platform failure); set `RUST_TEST_THREADS=4` in `.cargo/config.toml` (parallel banks
exhaust file handles). Upgrade conditions: deploy the `.so` files behind the upgradeable
loader with the owner as upgrade authority and upgrade via buffer accounts.

## Decision log

Same format as `SKILL.md` step 6. With this overlay and `spec/06` applied there should be
few or no entries; anything left is a gap to report.
