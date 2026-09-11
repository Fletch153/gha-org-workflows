#!/usr/bin/env bash
# Grade a generated data-feeds workspace against the reference conformance suite.
#   grade.sh <generated_workspace_dir> <grader_dir>
# grader_dir = a checkout of smartcontractkit/chainlink-stellar/contracts/data-feeds with
# grader.patch applied (test harnesses deploy fixtures/gen_{cache,proxy}.wasm instead of the
# in-crate contracts).
set -uo pipefail
GEN=$1; GRADER=$2
export SOROBAN_SDK_BUILD_SYSTEM_SUPPORTS_SPEC_SHAKING_V2=1
summary=()
step() { echo; echo "### $1"; }

step "G1: generated workspace builds to wasm"
ok=1
for p in data-feeds-cache data-feeds-proxy; do
  (cd "$GEN" && cargo build --release --target wasm32v1-none -p $p 2>&1 | grep -E '^(error|warning: unused)' | head -20) || true
  f="$GEN/target/wasm32v1-none/release/${p//-/_}.wasm"
  if [ -f "$f" ]; then echo "built $f ($(stat -c%s "$f") bytes)"; else echo "MISSING $f"; ok=0; fi
done
summary+=("G1 wasm build: $([ $ok = 1 ] && echo PASS || echo FAIL)")

step "G2: generated workspace's own tests"
out=$(cd "$GEN" && cargo test --workspace 2>&1)
echo "$out" | grep -E '^test result|FAILED|panicked|^error' | head -40
g2=$(echo "$out" | grep -cE '^test result: FAILED' || true)
g2p=$(echo "$out" | grep -E '^test result' | sed -E 's/.* ([0-9]+) passed.*/\1/' | paste -sd+ | bc)
g2f=$(echo "$out" | grep -E '^test result' | sed -E 's/.* ([0-9]+) failed.*/\1/' | paste -sd+ | bc)
summary+=("G2 own tests: passed=$g2p failed=$g2f $([ "$g2f" = 0 ] && [ "$g2p" -gt 0 ] && echo PASS || echo FAIL)")

step "G3: reference conformance suite against generated wasm"
if [ $ok = 1 ]; then
  cp "$GEN/target/wasm32v1-none/release/data_feeds_cache.wasm" "$GRADER/fixtures/gen_cache.wasm"
  cp "$GEN/target/wasm32v1-none/release/data_feeds_proxy.wasm" "$GRADER/fixtures/gen_proxy.wasm"
  c=$(cd "$GRADER" && cargo test -p data-feeds-cache -- tests:: --skip domain:: --skip storage:: 2>&1)
  p=$(cd "$GRADER" && cargo test -p data-feeds-proxy -- tests:: 2>&1)
  for name in c p; do
    o=${!name}
    echo "--- $([ $name = c ] && echo cache || echo proxy) failures:"
    echo "$o" | grep -E '^test .* FAILED$' | sed 's/^test //'
    echo "$o" | grep -E '^test result'
  done
  cf=$(echo "$c" | grep -E '^test result' | sed -E 's/.* ([0-9]+) failed.*/\1/'); cp_=$(echo "$c" | grep -E '^test result' | sed -E 's/.* ([0-9]+) passed.*/\1/')
  pf=$(echo "$p" | grep -E '^test result' | sed -E 's/.* ([0-9]+) failed.*/\1/'); pp=$(echo "$p" | grep -E '^test result' | sed -E 's/.* ([0-9]+) passed.*/\1/')
  summary+=("G3 conformance: cache ${cp_:-0}/117 proxy ${pp:-0}/62 $([ "${cf:-1}" = 0 ] && [ "${pf:-1}" = 0 ] && [ -n "$cp_" ] && [ -n "$pp" ] && echo PASS || echo FAIL)")
  # keep full logs for diagnosis
  echo "$c" > "$GRADER/last_cache.log"; echo "$p" > "$GRADER/last_proxy.log"
else
  summary+=("G3 conformance: SKIPPED (no wasm)")
fi

echo; echo "===== SUMMARY ====="; printf '%s\n' "${summary[@]}"
