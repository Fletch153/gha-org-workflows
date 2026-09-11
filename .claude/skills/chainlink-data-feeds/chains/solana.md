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
- **C. Expiry** — case C.4. Sequence unit is `Clock::get()?.slot` truncated to u32.
  Reclaim **is defined**: a permissionless instruction `reclaim_round(data_id, round_id)`
  closes the round account and refunds its lamports to the recorded payer, allowed only if
  the round is a non-tip round that is **not readable** (outside the window). Otherwise
  error `RoundStillReadable = 111` (Cache range).
- **D. Limits** — 1232-byte transactions, ~1.4M compute units, every touched account
  declared. Account declaration convention: fixed accounts first (listed per instruction
  below), then per-item accounts in item order. Uninitialised records are passed as their
  derived address (system-owned, zero data) and read as absent. Wrong or missing accounts
  fail with native `ProgramError::InvalidSeeds` / `NotEnoughAccountKeys` (no numeric code).
  History reads take an explicit contiguous id range per `06` D.5: `round_range(data_id,
  from, to)` uses supplied rounds for `[from, to]`; `find_round(data_id, timestamp, bound,
  lo, hi)` searches `[lo, hi]`.
- **E. Errors** — `ProgramError::Custom(code)` with the spec codes; names as an enum.
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

## Account conventions (fixed accounts, in order)

Cache: `initialize(owner)`: `[config (w), payer (s,w), system_program]`.
`on_report(metadata, report)`: `[sender (s), payer (s,w), config, system_program, clock?]`
then per entry: `[permission, feed_config, feed_state (w), round (w, the new round id =
tip+1 — pass the derived address for `tip+1`)]`. Admin batch instructions: `[admin (s),
payer (s,w), config, system_program]` then per item the records the item touches
(`feed_config (w)`, then one `permission (w)` per **old** permission, then one per new
permission, for `set_feed_configs`; `feed_config (w)` + old permissions for
`remove_feed_configs`; `feed_state (w)` for `set_feed_frozen`). `add_feed_admin` /
`remove_feed_admin`: `[owner (s), payer (s,w), config, admin_record (w), system_program]`.
Readers: `[config]` then per id the records named in the spec for that reader.
Proxy: `initialize(owner, cache)`: `[config (w), payer (s,w), system_program]`; readers:
`[config, cache_program, cache_config, min_decimals]` then the Cache accounts the CPI
needs, in the Cache's own convention; `set_cache`/`set_min_decimals`: `[owner (s), payer
(s,w), config (w), (min_decimals (w)), system_program]`. Document any refinement of this
convention in the project README; it is part of the ABI.

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
`log_messages` (`Program data:` lines, base64). Host failures assert the native
`ProgramError` variant; spec errors assert `Custom(code)`.

## Decision log

Same format as `SKILL.md` step 6. With this overlay and `spec/06` applied there should be
few or no entries; anything left is a gap to report.
