#[test_only]
// Scenarios: cache.set_feed_frozen.*
module data_feeds::frozen_tests {
    use std::option;
    use std::signer;
    use std::string;
    use std::vector;
    use data_feeds::cache;
    use data_feeds::test_utils as t;

    // deploy, add admin, configure id:1 for sender; returns the cache address.
    fun setup_feed(fw: &signer, owner: &signer, admin: &signer, sender: &signer): address {
        t::setup(fw);
        let c = t::deploy_cache(owner, b"cache", signer::address_of(owner));
        cache::add_feed_admin(owner, c, signer::address_of(admin));
        t::configure(admin, c, t::id(1), b"BTC/USD", signer::address_of(sender));
        c
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_set_feed_frozen_every_read_stays_raw_while_frozen(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        t::seed(&sender, c, t::id(1), 3);
        cache::set_feed_frozen(&admin, c, vector[t::id(1)], true);
        assert!(cache::is_frozen(c, vector[t::id(1)]) == vector[true], 1);
        assert!(cache::round_data_round_id(&t::latest(c, t::id(1))) == 3, 2);
        assert!(cache::round_data_round_id(&option::destroy_some(cache::get_round(c, t::id(1), 1))) == 1, 3);
        assert!(cache::round_data_round_id(&option::destroy_some(cache::find_round(c, t::id(1), 10, 0))) == 1, 4);
        assert!(vector::length(&t::full_range(c, t::id(1))) == 3, 5);
        assert!(cache::decimals(c, vector[t::id(1)]) == vector[option::some(18)], 6);
        let d = cache::description(c, vector[t::id(1)]);
        assert!(vector::length(&d) == 1 && option::is_some(vector::borrow(&d, 0)), 7);
        assert!(cache::is_configured(c, vector[t::id(1)]) == vector[true], 8);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_set_feed_frozen_unfreezing_restores_every_read(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        t::seed(&sender, c, t::id(1), 3);
        cache::set_feed_frozen(&admin, c, vector[t::id(1)], true);
        cache::set_feed_frozen(&admin, c, vector[t::id(1)], false);
        assert!(cache::is_frozen(c, vector[t::id(1)]) == vector[false], 1);
        assert!(cache::round_data_round_id(&t::latest(c, t::id(1))) == 3, 2);
        assert!(cache::round_data_round_id(&option::destroy_some(cache::get_round(c, t::id(1), 1))) == 1, 3);
        assert!(cache::round_data_round_id(&option::destroy_some(cache::find_round(c, t::id(1), 10, 0))) == 1, 4);
        assert!(vector::length(&t::full_range(c, t::id(1))) == 3, 5);
        assert!(cache::decimals(c, vector[t::id(1)]) == vector[option::some(18)], 6);
        assert!(cache::description(c, vector[t::id(1)]) == vector[option::some(string::utf8(b"BTC/USD"))], 7);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_set_feed_frozen_updates_still_land_and_stay_frozen(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        t::seed(&sender, c, t::id(1), 1);
        cache::set_feed_frozen(&admin, c, vector[t::id(1)], true);
        t::report(&sender, c, vector[t::entry(t::id(1), 500, 99)]);
        assert!(cache::is_frozen(c, vector[t::id(1)]) == vector[true], 1);
        cache::set_feed_frozen(&admin, c, vector[t::id(1)], false);
        let l = t::latest(c, t::id(1));
        assert!(cache::round_data_round_id(&l) == 2 && cache::round_data_answer(&l) == 500, 2);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_set_feed_frozen_outlives_config_removal(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        t::seed(&sender, c, t::id(1), 1);
        cache::set_feed_frozen(&admin, c, vector[t::id(1)], true);
        cache::remove_feed_configs(&admin, c, vector[t::id(1)]);
        assert!(cache::is_configured(c, vector[t::id(1)]) == vector[false], 1);
        assert!(cache::is_frozen(c, vector[t::id(1)]) == vector[true], 2);
        assert!(!t::latest_is_none(c, t::id(1)), 3);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, admin2 = @0xA3, sender = @0xB1, sender2 = @0xB2)]
    fun cache_set_feed_frozen_freezing_one_feed_leaves_its_sibling_readable(fw: signer, owner: signer, admin: signer, admin2: signer, sender: signer, sender2: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        t::seed(&sender, c, t::id(1), 1);
        cache::add_feed_admin(&owner, c, signer::address_of(&admin2));
        t::configure(&admin2, c, t::id(2), b"BTC/USD", signer::address_of(&sender2));
        t::seed(&sender2, c, t::id(2), 1);
        cache::set_feed_frozen(&admin, c, vector[t::id(1)], true);
        assert!(cache::is_frozen(c, vector[t::id(1)]) == vector[true], 1);
        assert!(!t::latest_is_none(c, t::id(1)), 2);
        assert!(cache::round_data_round_id(&t::latest(c, t::id(2))) == 1, 3);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_set_feed_frozen_every_call_emits_even_without_a_change(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        t::seed(&sender, c, t::id(1), 1);
        let before = t::snapshot();
        cache::set_feed_frozen(&admin, c, vector[t::id(1)], true);
        t::assert_count(&before, t::e_feed_frozen_set(), 1);
        assert!(t::emitted(&cache::feed_frozen_set_event(t::id(1), true)), 1);
        let before = t::snapshot();
        cache::set_feed_frozen(&admin, c, vector[t::id(1)], true);
        t::assert_count(&before, t::e_feed_frozen_set(), 1);
        assert!(t::emitted(&cache::feed_frozen_set_event(t::id(1), true)), 2);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    #[expected_failure(abort_code = 110, location = data_feeds::cache)]
    fun cache_set_feed_frozen_a_feed_without_state_aborts_the_whole_batch(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        t::seed(&sender, c, t::id(1), 1);
        t::configure(&admin, c, t::id(2), b"X", signer::address_of(&sender));
        assert!(cache::is_frozen(c, vector[t::id(1)]) == vector[false], 1);
        cache::set_feed_frozen(&admin, c, vector[t::id(1), t::id(2)], true);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    #[expected_failure(abort_code = 110, location = data_feeds::cache)]
    fun cache_set_feed_frozen_a_feed_without_state_aborts_the_whole_batch__alt2(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        t::seed(&sender, c, t::id(1), 1);
        t::configure(&admin, c, t::id(2), b"X", signer::address_of(&sender));
        assert!(cache::is_frozen(c, vector[t::id(1)]) == vector[false], 1);
        cache::set_feed_frozen(&admin, c, vector[t::id(1), t::id(9)], true);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    #[expected_failure(abort_code = 108, location = data_feeds::cache)]
    fun cache_set_feed_frozen_duplicate_ids_are_rejected_and_change_nothing(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        t::seed(&sender, c, t::id(1), 1);
        assert!(cache::is_frozen(c, vector[t::id(1)]) == vector[false], 1);
        cache::set_feed_frozen(&admin, c, vector[t::id(1), t::id(1)], true);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2)]
    fun cache_set_feed_frozen_empty_batch_is_a_no_op(fw: signer, owner: signer, admin: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
        let before = t::snapshot();
        cache::set_feed_frozen(&admin, c, vector[], true);
        t::assert_no_events(&before);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1, stranger = @0xC1)]
    #[expected_failure(abort_code = 101, location = data_feeds::cache)]
    fun cache_set_feed_frozen_non_admin_caller_is_unauthorized(fw: signer, owner: signer, admin: signer, sender: signer, stranger: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        t::seed(&sender, c, t::id(1), 1);
        cache::set_feed_frozen(&stranger, c, vector[t::id(1)], true);
    }
}
