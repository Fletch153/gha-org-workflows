---
name: chainlink-data-feeds
description: Implement the Chainlink Data Feeds contract pair (Cache + Proxy) on a target chain from a chain-agnostic behavioural spec plus a per-chain overlay. Use when asked to build, port, or regenerate the data-feeds contracts for a chain.
---

# Chainlink Data Feeds — contract generator

You are producing a **complete, tested implementation** of two contracts, `DataFeedsCache` and
`DataFeedsProxy`, for one target chain. Everything you need is in this skill directory. Do not
look for prior implementations; the spec is the source of truth and is deliberately exhaustive.

## Inputs

- `chain` — the target chain. Overlay lives at `chains/<chain>.md`. If no overlay exists, stop and say so.
- `out_dir` — where to create the project. Create it if missing; do not write anywhere else.

## Procedure

1. Read, in order, every file under `spec/` (numbered), then `chains/<chain>.md`. Read all of it
   before writing anything — later files constrain earlier ones. `spec/06-platform-model.md`
   decides how the abstract platform of `01`–`05` maps onto the target chain; its rules win
   over any literal reading of `01`–`05` that the chain cannot express.
2. Create the project layout the overlay prescribes (crate names, module split, manifests,
   toolchain pins) exactly. Names on the public surface (functions, argument names, types,
   fields, error codes, event names and fields, storage keys) are part of the on-chain ABI and
   must match the spec byte-for-byte, subject only to the mappings of `spec/06` (dropped
   `sender` arguments on caller-identity chains, a declared case convention, omitted
   `upgrade`); internal helper names are yours.
3. Implement the shared lifecycle pieces first (`spec/01`), then the Cache (`spec/02`, `spec/04`),
   then the Proxy (`spec/03`).
4. Write the tests listed in `spec/05-tests.md`. Each listed condition must be covered by at
   least one test whose name makes the condition recognisable. Add more if you find gaps.
5. Verify, and fix until all three hold:
   - the whole workspace's tests pass;
   - each contract builds to the chain's deployable artifact using the overlay's build command;
   - where the platform has a contract-invocable upgrade (`spec/06` I.1), the upgrade-related
     tests run against artifacts you built from your own crates.
6. Keep a decision log at `out_dir/DECISIONS.md`: one entry for every choice that the spec
   plus the overlay did not determine (the overlay says what format to use). If the overlay
   determines everything, the file says so. Never silently pick; write it down.
7. Finish with a short summary: paths of the two deployable artifacts, the test count, and
   the number of entries in the decision log.

## Rules of construction

- Every entry point's **check order** in the spec is normative. Perform checks in that order;
  a failing check must return/raise the listed error and leave no partial state or events.
- "Batch" read functions return exactly one output per input, in input order; duplicates are
  answered independently; an empty input yields an empty output.
- Feed *configuration* (who may write, description) and feed *state* (round history, frozen
  flag, retention window) are separate records with separate lifetimes. Removing a config never
  touches state; reconfiguring never resets round numbering. This is deliberate.
- Events are emitted only on success paths, exactly once per described occurrence, with the
  exact names and fields given. No extra events.
- Do not add features, parameters, admin conveniences, or "sensible" validations the spec does
  not list. If the spec is silent, the behaviour is "do nothing extra".
