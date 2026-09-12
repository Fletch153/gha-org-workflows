# Mutation grader

Objective, chain-agnostic check that a generated test suite is a faithful translation of the
scenario corpus. Each mutant is a behavioural change described in spec terms; the grader
applies it to the generated **contract source** (never the tests), runs the full suite, and
records whether at least one test fails. A faithful suite catches every mutant. Restore the
source between mutants. Report: caught / not caught per mutant, with the failing test names.

| # | Mutant (apply to the generated source) | Scenario family that must catch it |
|---|---|---|
| M1 | `on_report`: stale check `timestamp <= stored_ts` → `timestamp < stored_ts` (equal timestamps now land) | `cache.on_report.equal_or_older_timestamp_is_stale*` |
| M2 | `on_report`: emit `FeedUpdated` with `primary = false` | `cache.on_report.first_accept_assigns_round_one*`, event-field scenarios |
| M3 | `on_report`: do not emit `InvalidUpdatePermission` on the permission miss (still skip) | `cache.on_report.unconfigured_feed_soft_skips*` |
| M4 | `set_feed_configs`: return `FeedNotConfigured` (102) instead of `EmptyConfig` (103) for an empty batch | `cache.set_feed_configs.empty_entries_is_empty_config` |
| M5 | `set_feed_configs`: on reconfigure, skip the `FeedConfigRemoved` event | `cache.set_feed_configs.reconfigure_is_full_replace_removed_then_set` |
| M6 | `set_feed_configs`: keep the old permissions when reconfiguring (append instead of replace) | `cache.set_feed_configs.reconfigure_is_full_replace*`, `cache.on_report.revoked_sender*` |
| M7 | `remove_feed_configs`: also delete `FeedState` | `cache.set_feed_configs.stale_feed_state_resurrects*`, `re_add*` |
| M8 | `set_feed_frozen`: silently skip ids without state instead of failing with 110 | `cache.set_feed_frozen.a_feed_without_state_aborts_the_whole_batch` |
| M9 | `round_range`: exclusive upper bound (`to` not included) | `cache.round_range.bounded_range_inclusive` |
| M10 | `find_round`: `AtOrBefore` returns the oldest qualifying round instead of the newest | `cache.find_round.at_or_before_picks_newest` |
| M11 | window: `width_at(now)` returns `grow_to_ttl + 2` (widens the mask; ignore `grow_at_ledger`) | `cache.retention.non_tip_rounds_outside_the_window_are_masked_on_every_read` (universal), plus `window_grows_at_grow_at_ledger` where the TTL can vary |
| M12 | Proxy: skip the frozen check | `proxy.*.rejects_a_frozen_feed` |
| M13 | Proxy: `RoundsToZero` check removed (return 0) | `proxy.precision.non_zero_answer_scaling_to_zero_fails` |
| M14 | Proxy: `set_min_decimals` accepts `min > 18` | `proxy.set_min_decimals.min_above_cache_precision_is_rejected` |
| M15 | Proxy: `set_cache` does not emit `CacheSet` | `proxy.set_cache.set_cache_swaps_routing_and_emits` |
| M16 | `add_feed_admin`: no owner check (anyone may add) | `cache.add_feed_admin.add_admin_by_non_owner_host_fails` |

Score = mutants caught / mutants applicable (M11 needs a window-observing scenario; on
non-expiry chains it is caught by the retention mask scenarios).
| M17 | `set_feed_configs`: on overwrite of an existing config, do not refresh the `FeedConfig` entry's lifetime (`expiry` chains only; n/a elsewhere) | `cache.set_feed_configs.extends_contract_config_and_permission_ttls` |
