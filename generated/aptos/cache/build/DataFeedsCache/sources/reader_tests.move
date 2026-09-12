#[test_only]
// Scenarios: cache.latest_round.*, cache.get_round.*, cache.round_range.*, cache.find_round.*,
// cache.decimals.*, cache.description.*, cache.is_configured.*, cache.is_frozen.*,
// cache.retention.*
module data_feeds::reader_tests {
    use std::option;
    use std::signer;
    use std::string;
    use std::vector;
    use data_feeds::cache;
    use data_feeds::test_utils as t;

    fun setup_feed(fw: &signer, owner: &signer, admin: &signer, sender: &signer): address {
        t::setup(fw);
        let c = t::deploy_cache(owner, b"cache", signer::address_of(owner));
        cache::add_feed_admin(owner, c, signer::address_of(admin));
        t::configure(admin, c, t::id(1), b"BTC/USD", signer::address_of(sender));
        c
    }

    fun round_ids(rounds: &vector<cache::RoundData>): vector<u64> {
        let out = vector::empty<u64>();
        let i = 0;
        while (i < vector::length(rounds)) {
            vector::push_back(&mut out, cache::round_data_round_id(vector::borrow(rounds, i)));
            i = i + 1;
        };
        out
    }

    // ----- latest_round ----------------------------------------------------------------

    #[test(fw = @aptos_framework, owner = @0xA1)]
    fun cache_latest_round_absent_is_none(fw: signer, owner: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        assert!(cache::latest_round(c, vector[t::id(1)]) == vector[option::none()], 1);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_latest_round_returns_newest(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        t::seed(&sender, c, t::id(1), 3);
        t::assert_round(&t::latest(c, t::id(1)), 3, 300, 30);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_latest_round_returns_latest_after_round_expires(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        t::seed(&sender, c, t::id(1), 3);
        cache::test_expire_round(c, t::id(1), 3);
        assert!(cache::round_data_round_id(&t::latest(c, t::id(1))) == 3, 1);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_latest_round_batch_preserves_order_and_handles_duplicates_and_missing(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        t::seed(&sender, c, t::id(1), 2);
        let v = cache::latest_round(c, vector[t::id(1), t::id(9), t::id(1)]);
        assert!(vector::length(&v) == 3, 1);
        assert!(cache::round_data_round_id(option::borrow(vector::borrow(&v, 0))) == 2, 2);
        assert!(option::is_none(vector::borrow(&v, 1)), 3);
        assert!(cache::round_data_round_id(option::borrow(vector::borrow(&v, 2))) == 2, 4);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_latest_round_frozen_feeds_read_normally(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        t::seed(&sender, c, t::id(1), 3);
        cache::set_feed_frozen(&admin, c, vector[t::id(1)], true);
        assert!(cache::is_frozen(c, vector[t::id(1)]) == vector[true], 1);
        assert!(cache::round_data_round_id(&t::latest(c, t::id(1))) == 3, 2);
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    fun cache_latest_round_empty_ids_returns_empty(fw: signer, owner: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        assert!(vector::is_empty(&cache::latest_round(c, vector[])), 1);
    }

    // ----- get_round -------------------------------------------------------------------

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_get_round_returns_by_id(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        t::seed(&sender, c, t::id(1), 3);
        assert!(cache::round_data_round_id(&option::destroy_some(cache::get_round(c, t::id(1), 2))) == 2, 1);
        assert!(option::is_none(&cache::get_round(c, t::id(1), 9)), 2);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_get_round_returns_none_if_no_round_present(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        assert!(option::is_none(&cache::get_round(c, t::id(1), 1)), 1);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_get_round_tip_survives_expiry_non_tip_does_not(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        t::seed(&sender, c, t::id(1), 3);
        cache::test_expire_round(c, t::id(1), 1);
        cache::test_expire_round(c, t::id(1), 3);
        assert!(option::is_none(&cache::get_round(c, t::id(1), 1)), 1);
        assert!(cache::round_data_round_id(&option::destroy_some(cache::get_round(c, t::id(1), 3))) == 3, 2);
    }

    // ----- round_range -----------------------------------------------------------------

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_round_range_empty_when_no_round_exists(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        assert!(vector::is_empty(&t::full_range(c, t::id(1))), 1);
        assert!(vector::is_empty(&t::full_range(c, t::id(2))), 2);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_round_range_full_history_oldest_first(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        t::seed(&sender, c, t::id(1), 5);
        let r = t::full_range(c, t::id(1));
        assert!(vector::length(&r) == 5, 1);
        assert!(cache::round_data_round_id(vector::borrow(&r, 0)) == 1, 2);
        assert!(cache::round_data_round_id(vector::borrow(&r, 4)) == 5, 3);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_round_range_bounded_range_inclusive(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        t::seed(&sender, c, t::id(1), 5);
        let r = cache::round_range(c, t::id(1), 2, 4);
        assert!(vector::length(&r) == 3, 1);
        assert!(cache::round_data_round_id(vector::borrow(&r, 0)) == 2, 2);
        assert!(cache::round_data_round_id(vector::borrow(&r, 2)) == 4, 3);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_round_range_expired_rounds_drop_out_of_a_full_range(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        t::seed(&sender, c, t::id(1), 6);
        cache::test_expire_round(c, t::id(1), 1);
        cache::test_expire_round(c, t::id(1), 2);
        cache::test_expire_round(c, t::id(1), 3);
        let r = t::full_range(c, t::id(1));
        assert!(vector::length(&r) == 3, 1);
        assert!(cache::round_data_round_id(vector::borrow(&r, 0)) == 4, 2);
        assert!(cache::round_data_round_id(vector::borrow(&r, 2)) == 6, 3);
    }

    // ----- find_round ------------------------------------------------------------------

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_find_round_empty_feed_is_none(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        assert!(option::is_none(&cache::find_round(c, t::id(1), 100, 0)), 1);
        assert!(option::is_none(&cache::find_round(c, t::id(1), 100, 1)), 2);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_find_round_at_or_before_picks_newest(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        t::seed(&sender, c, t::id(1), 5);
        assert!(cache::round_data_round_id(&option::destroy_some(cache::find_round(c, t::id(1), 35, 0))) == 3, 1);
        assert!(cache::round_data_round_id(&option::destroy_some(cache::find_round(c, t::id(1), 999, 0))) == 5, 2);
        assert!(option::is_none(&cache::find_round(c, t::id(1), 5, 0)), 3);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_find_round_at_or_after_picks_oldest(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        t::seed(&sender, c, t::id(1), 5);
        assert!(cache::round_data_round_id(&option::destroy_some(cache::find_round(c, t::id(1), 35, 1))) == 4, 1);
        assert!(cache::round_data_round_id(&option::destroy_some(cache::find_round(c, t::id(1), 5, 1))) == 1, 2);
        assert!(option::is_none(&cache::find_round(c, t::id(1), 999, 1)), 3);
    }

    // ----- decimals --------------------------------------------------------------------

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_decimals_always_eighteen_for_configured_feeds(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        assert!(cache::decimals(c, vector[t::id(1)]) == vector[option::some(18)], 1);
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    fun cache_decimals_unconfigured_feed_is_none(fw: signer, owner: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        assert!(cache::decimals(c, vector[t::id(123)]) == vector[option::none()], 1);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_decimals_batch_preserves_order_and_handles_duplicates_and_missing(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        assert!(cache::decimals(c, vector[t::id(1), t::id(9), t::id(1)]) == vector[option::some(18), option::none(), option::some(18)], 1);
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    fun cache_decimals_empty_ids_returns_empty(fw: signer, owner: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        assert!(vector::is_empty(&cache::decimals(c, vector[])), 1);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_decimals_frozen_feeds_read_normally(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        t::seed(&sender, c, t::id(1), 1);
        cache::set_feed_frozen(&admin, c, vector[t::id(1)], true);
        assert!(cache::is_frozen(c, vector[t::id(1)]) == vector[true], 1);
        assert!(cache::decimals(c, vector[t::id(1)]) == vector[option::some(18)], 2);
    }

    // ----- description -----------------------------------------------------------------

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_description_returns_stored_description(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        assert!(cache::description(c, vector[t::id(1)]) == vector[option::some(string::utf8(b"BTC/USD"))], 1);
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    fun cache_description_unconfigured_feed_is_none(fw: signer, owner: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        assert!(cache::description(c, vector[t::id(99)]) == vector[option::none()], 1);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_description_batch_preserves_order_and_handles_duplicates_and_missing(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        let d = string::utf8(b"BTC/USD");
        assert!(cache::description(c, vector[t::id(1), t::id(9), t::id(1)]) == vector[option::some(d), option::none(), option::some(d)], 1);
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    fun cache_description_empty_ids_returns_empty(fw: signer, owner: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        assert!(vector::is_empty(&cache::description(c, vector[])), 1);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_description_frozen_feeds_read_normally(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        t::seed(&sender, c, t::id(1), 1);
        cache::set_feed_frozen(&admin, c, vector[t::id(1)], true);
        assert!(cache::is_frozen(c, vector[t::id(1)]) == vector[true], 1);
        assert!(cache::description(c, vector[t::id(1)]) == vector[option::some(string::utf8(b"BTC/USD"))], 2);
    }

    // ----- is_configured ---------------------------------------------------------------

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_is_configured_tracks_the_feed_config(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        assert!(cache::is_configured(c, vector[t::id(1)]) == vector[true], 1);
        assert!(cache::is_configured(c, vector[t::id(99)]) == vector[false], 2);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_is_configured_agrees_with_the_config_backed_getters(fw: signer, owner: signer, admin: signer, sender: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
        t::configure(&admin, c, t::id(2), b"", signer::address_of(&sender));
        assert!(cache::is_configured(c, vector[t::id(2)]) == vector[true], 1);
        assert!(option::is_some(vector::borrow(&cache::decimals(c, vector[t::id(2)]), 0)), 2);
        assert!(option::is_some(vector::borrow(&cache::description(c, vector[t::id(2)]), 0)), 3);
        cache::remove_feed_configs(&admin, c, vector[t::id(2)]);
        assert!(cache::is_configured(c, vector[t::id(2)]) == vector[false], 4);
        assert!(cache::decimals(c, vector[t::id(2)]) == vector[option::none()], 5);
        assert!(cache::description(c, vector[t::id(2)]) == vector[option::none()], 6);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_is_configured_batch_preserves_order_and_handles_duplicates_and_missing(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        assert!(cache::is_configured(c, vector[t::id(1), t::id(9), t::id(1)]) == vector[true, false, true], 1);
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    fun cache_is_configured_empty_ids_returns_empty(fw: signer, owner: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        assert!(vector::is_empty(&cache::is_configured(c, vector[])), 1);
    }

    // ----- is_frozen -------------------------------------------------------------------

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, admin2 = @0xA3, sender = @0xB1, sender2 = @0xB2)]
    fun cache_is_frozen_batch_preserves_order_and_handles_duplicates_and_missing(fw: signer, owner: signer, admin: signer, admin2: signer, sender: signer, sender2: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        cache::add_feed_admin(&owner, c, signer::address_of(&admin2));
        t::configure(&admin2, c, t::id(2), b"BTC/USD", signer::address_of(&sender2));
        t::seed(&sender, c, t::id(1), 1);
        cache::set_feed_frozen(&admin, c, vector[t::id(1)], true);
        assert!(cache::is_frozen(c, vector[t::id(1), t::id(2), t::id(9), t::id(1)]) == vector[true, false, false, true], 1);
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    fun cache_is_frozen_empty_ids_returns_empty(fw: signer, owner: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        assert!(vector::is_empty(&cache::is_frozen(c, vector[])), 1);
    }

    // ----- retention (window mask through the public interface) ------------------------

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_retention_non_tip_rounds_outside_the_window_are_masked_on_every_read(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        t::seed(&sender, c, t::id(1), 3);
        // advance {by_retention, plus: 1}: ledger_seq of the most recent round (103) + TTL + 1
        let last_seq = (cache::round_data_ledger_seq(&t::latest(c, t::id(1))) as u64);
        t::advance_to(last_seq + (cache::test_data_retention_ttl() as u64) + 1);
        t::assert_round(&t::latest(c, t::id(1)), 3, 300, 30);
        t::assert_round(&option::destroy_some(cache::get_round(c, t::id(1), 3)), 3, 300, 30);
        assert!(option::is_none(&cache::get_round(c, t::id(1), 1)), 1);
        assert!(option::is_none(&cache::get_round(c, t::id(1), 2)), 2);
        let r = t::full_range(c, t::id(1));
        assert!(vector::length(&r) == 1, 3);
        t::assert_round(vector::borrow(&r, 0), 3, 300, 30);
        assert!(option::is_none(&cache::find_round(c, t::id(1), 25, 0)), 4);
        t::assert_round(&option::destroy_some(cache::find_round(c, t::id(1), 25, 1)), 3, 300, 30);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_retention_rounds_inside_the_window_stay_readable_just_before_it_closes(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        t::seed(&sender, c, t::id(1), 3);
        // The scenario's `advance {by_retention, plus: -1}` (most recent round's ledger_seq
        // 103 + TTL - 1) is one past the window of round 1 (written at 101; readable iff
        // ledger_seq >= now - TTL, spec/04), so the corpus step cannot hold with the
        // asserted value. This test moves to the last sequence at which all three seeded
        // rounds are still inside the window: oldest ledger_seq (101) + TTL. See DECISIONS.md.
        let first_seq = (cache::round_data_ledger_seq(&option::destroy_some(cache::get_round(c, t::id(1), 1))) as u64);
        t::advance_to(first_seq + (cache::test_data_retention_ttl() as u64));
        let r = t::full_range(c, t::id(1));
        assert!(vector::length(&r) == 3, 1);
        t::assert_round(vector::borrow(&r, 0), 1, 100, 10);
        t::assert_round(vector::borrow(&r, 1), 2, 200, 20);
        t::assert_round(vector::borrow(&r, 2), 3, 300, 30);
        // one sequence later the oldest round leaves the window
        t::advance_to(first_seq + (cache::test_data_retention_ttl() as u64) + 1);
        assert!(round_ids(&t::full_range(c, t::id(1))) == vector[2, 3], 2);
    }
}
