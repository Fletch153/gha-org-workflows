---
name: chainlink-data-feeds
description: Implement the Chainlink Data Feeds contract pair (Cache + Proxy) on any target chain from a chain-agnostic behavioural spec. Use when asked to build, port, or regenerate the data-feeds contracts for a chain — including a chain with no overlay yet; the skill authors the overlay itself.
---

# Chainlink Data Feeds — contract generator

You are producing a **complete, tested implementation** of two contracts, `DataFeedsCache` and
`DataFeedsProxy`, for one target chain, functionally identical to the reference behaviour in
`spec/`. Everything you need is in this skill directory plus the target platform's own SDK and
tooling. Do not look for prior implementations; the spec is the source of truth and is
deliberately exhaustive. Make decisions yourself using the rules in `spec/06`; do not stop to
ask unless the platform makes a spec behaviour genuinely impossible *and* `spec/06` has no
rule for it.

## Inputs

- `chain` — the target chain (e.g. `stellar`, `evm`, `solana`, `aptos`, `sui`, `ton`).
- `out_dir` — where to create the project. Create it if missing; do not write anywhere else
  except `chains/<chain>.md` in this skill (Phase 0 and step 7).

## Phase 0 — overlay (only when `chains/<chain>.md` does not exist)

1. Read every file under `spec/` in order. `spec/06` is the decision procedure: for each axis
   it gives the default and the rule; you will instantiate it for the platform.
2. Establish the toolchain: find the platform's compiler/SDK/test framework locally; if
   missing, install it (prefer GitHub release binaries; network for package registries is
   normally available, arbitrary HTTP often is not). Verify with a hello-world build and test
   *before* writing the overlay. Record exact versions.
3. Copy `chains/_template.md` to `chains/<chain>.md` and answer every section. Consult the
   platform's SDK sources/docs for API names. Each answer must be a concrete statement, not a
   choice list. Where the template gives a default, take it unless impossible.
4. Continue with Phase 1 using the overlay you just wrote.

## Phase 1 — implementation

1. Read, in order, every file under `spec/` (numbered), then `chains/<chain>.md`. Read all of it
   before writing anything — later files constrain earlier ones. `spec/06-platform-model.md`
   decides how the abstract platform of `01`–`05` maps onto the target chain; its rules win
   over any literal reading of `01`–`05` that the chain cannot express.
2. Create the project layout the overlay prescribes exactly. Names on the public surface
   (functions, argument names, types, fields, error codes, event names and fields, storage
   keys) are part of the on-chain ABI and must match the spec byte-for-byte, subject only to
   the mappings of `spec/06` (dropped `sender` arguments on caller-identity chains, a declared
   case convention, omitted `upgrade`); internal helper names are yours.
3. Implement the shared lifecycle pieces first (`spec/01`), then the Cache (`spec/02`, `spec/04`),
   then the Proxy (`spec/03`).
4. Write the tests. The primary source is `spec/scenarios.json` (schema in
   `spec/07-scenarios.md`): implement **one test per scenario whose `requires` tags are all
   in the overlay's `capabilities`**, named by the full scenario `id` including its `cache.`/
   `proxy.` prefix (dots → underscores, case-converted only if the platform requires),
   asserting exactly what the scenario asserts — every step, every expected value, event
   field and count; never a weaker paraphrase. List every inapplicable scenario in the decision log under
   `[TEST-TECHNIQUE]` with the `spec/06` rule. Then check `spec/05-tests.md` (the human
   summary) for conditions the scenarios do not cover on this platform and add tests for them.
5. Verify, and fix until all hold:
   - the whole workspace's tests pass;
   - each deployable builds with the overlay's build command;
   - where the platform has a contract-invocable upgrade (`spec/06` I.1), the upgrade-related
     tests run against artifacts you built from your own crates.
6. Keep a decision log at `out_dir/DECISIONS.md`: one entry for every choice that the spec
   plus the overlay did not determine. Tag each `[ABI]`, `[BEHAVIOUR]`, `[INTERNAL-NAME]` or
   `[TEST-TECHNIQUE]`. Never silently pick; write it down.
7. **Write back.** Every `[ABI]` and `[BEHAVIOUR]` entry is an overlay gap: add the concrete
   statement to `chains/<chain>.md` in the matching section so the next run on this chain
   makes no such decision. If an entry reveals a gap in `spec/06` itself (a question no axis
   answers on any chain), do not edit `spec/`; report it.
8. Finish with a short summary: paths of the two deployable artifacts, the test count, the
   number of log entries by tag, and whether Phase 0 ran.

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
  not list. If the spec is silent, the behaviour is "do nothing extra" — but `spec/06` D.2
  validation of supplied records/accounts is never "extra".
- Functional alignment with the reference beats platform idiom: when the platform's usual
  pattern and the spec disagree, the spec wins unless `spec/06` says otherwise.
