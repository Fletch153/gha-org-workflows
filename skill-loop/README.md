# Skill training loop — chainlink-data-feeds

Goal: iterate `.claude/skills/chainlink-data-feeds` until a context-free agent, given only
the skill, produces contracts functionally identical to
`smartcontractkit/chainlink-stellar/contracts/data-feeds`.

## Grader
`grader.patch` applies to `contracts/data-feeds` of the reference repo and makes its
contract-level test harnesses deploy `fixtures/gen_cache.wasm` / `fixtures/gen_proxy.wasm`
instead of the in-crate contracts. `grade.sh <generated_ws> <grader_dir>` then reports:

- G1 — both generated crates build to wasm
- G2 — the generated workspace's own tests pass
- G3 — the reference suite (117 cache + 62 proxy contract-level tests) passes against the
  generated wasm. This is the "functionally identical" bar; it covers ABI names, error codes,
  event shapes, storage layout (via TTL peeks and self-upgrade fixtures), and the retention
  window semantics.

Stop condition: G1, G2, G3 all PASS.

## Generator isolation
Each round spawns a fresh agent whose prompt names only the skill directory, the target chain
and an output directory. The reference checkout lives outside the workspace and the agent is
told not to read anything else. Rounds are logged in `LOG.md`.
