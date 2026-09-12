#[test_only]
// Scenarios: cache.set_feed_configs.*, cache.remove_feed_configs.*, cache.add_feed_admin.*,
// cache.remove_feed_admin.*, cache.get_feed_permissions.*, cache.has_permission.*.
module data_feeds::config_tests {
    use std::option;
    use std::signer;
    use std::string;
    use std::vector;
    use data_feeds::cache;
    use data_feeds::test_utils as t;

    // ----- set_feed_configs ------------------------------------------------------------

    #[test(fw = @aptos_framework, owner = @0xA1, sender = @0xB1, stranger = @0xC1)]
    #[expected_failure(abort_code = 101, location = data_feeds::cache)]
    fun cache_set_feed_configs_non_admin_caller_is_unauthorized(fw: signer, owner: signer, sender: signer, stranger: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        t::configure(&stranger, c, t::id(1), b"X", signer::address_of(&sender));
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2)]
    #[expected_failure(abort_code = 103, location = data_feeds::cache)]
    fun cache_set_feed_configs_empty_entries_is_empty_config(fw: signer, owner: signer, admin: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
        cache::set_feed_configs(&admin, c, vector[]);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    #[expected_failure(abort_code = 107, location = data_feeds::cache)]
    fun cache_set_feed_configs_zero_data_id_is_rejected(fw: signer, owner: signer, admin: signer, sender: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
        t::configure(&admin, c, t::zero32(), b"X", signer::address_of(&sender));
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2)]
    #[expected_failure(abort_code = 103, location = data_feeds::cache)]
    fun cache_set_feed_configs_entry_with_no_permissions_is_empty_config(fw: signer, owner: signer, admin: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
        cache::set_feed_configs(&admin, c, vector[t::config_entry(t::id(1), b"X", vector[])]);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    #[expected_failure(abort_code = 105, location = data_feeds::cache)]
    fun cache_set_feed_configs_permission_with_zero_workflow_name_is_invalid_name(fw: signer, owner: signer, admin: signer, sender: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
        cache::set_feed_configs(&admin, c, vector[t::config_entry(t::id(1), b"X",
            vector[t::perm(signer::address_of(&sender), t::owner_bytes(0x11), t::zero10())])]);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    #[expected_failure(abort_code = 106, location = data_feeds::cache)]
    fun cache_set_feed_configs_duplicate_permission_in_one_config_is_rejected(fw: signer, owner: signer, admin: signer, sender: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
        let s = signer::address_of(&sender);
        cache::set_feed_configs(&admin, c, vector[t::config_entry(t::id(1), b"X",
            vector[t::default_perm(s), t::default_perm(s)])]);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1, sender2 = @0xB2)]
    #[expected_failure(abort_code = 104, location = data_feeds::cache)]
    fun cache_set_feed_configs_invalid_entry_aborts_the_whole_batch(fw: signer, owner: signer, admin: signer, sender: signer, sender2: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
        let s = signer::address_of(&sender);
        // post-failure reads (run first; the batch is atomic)
        assert!(!cache::has_permission(c, t::id(1), s, t::owner_bytes(0x11), t::name_bytes(0x22)), 1);
        assert!(vector::is_empty(&cache::get_feed_permissions(c, t::id(1))), 2);
        cache::set_feed_configs(&admin, c, vector[
            t::config_entry(t::id(1), b"A", vector[t::default_perm(s)]),
            t::config_entry(t::id(2), b"B", vector[t::perm(signer::address_of(&sender2), t::zero20(), t::name_bytes(0x22))]),
        ]);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_set_feed_configs_first_time_config_emits_only_feed_config_set_with_derived_decimals(fw: signer, owner: signer, admin: signer, sender: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
        let s = signer::address_of(&sender);
        let before = t::snapshot();
        t::configure(&admin, c, t::id(1), b"BTC/USD", s);
        t::assert_only(&before, t::e_feed_config_set(), 1);
        assert!(t::emitted(&cache::feed_config_set_event(t::id(1), 18, string::utf8(b"BTC/USD"), vector[t::default_perm(s)])), 1);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1, sender2 = @0xB2)]
    fun cache_set_feed_configs_reconfigure_is_full_replace_removed_then_set(fw: signer, owner: signer, admin: signer, sender: signer, sender2: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
        let s = signer::address_of(&sender);
        let s2 = signer::address_of(&sender2);
        t::configure(&admin, c, t::id(1), b"old", s);
        let before = t::snapshot();
        t::configure(&admin, c, t::id(1), b"new", s2);
        // ordered: FeedConfigRemoved then FeedConfigSet — the harness cannot observe cross-type
        // order; both are asserted and the emission order is kept in the code.
        t::assert_count(&before, t::e_feed_config_removed(), 1);
        t::assert_count(&before, t::e_feed_config_set(), 1);
        assert!(t::emitted(&cache::feed_config_removed_event(t::id(1))), 1);
        assert!(t::emitted(&cache::feed_config_set_event(t::id(1), 18, string::utf8(b"new"), vector[t::default_perm(s2)])), 2);
        assert!(!cache::has_permission(c, t::id(1), s, t::owner_bytes(0x11), t::name_bytes(0x22)), 3);
        assert!(cache::has_permission(c, t::id(1), s2, t::owner_bytes(0x11), t::name_bytes(0x22)), 4);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1, sender2 = @0xB2)]
    fun cache_set_feed_configs_multiple_permitted_workflows_per_single_feed(fw: signer, owner: signer, admin: signer, sender: signer, sender2: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
        let s = signer::address_of(&sender);
        let s2 = signer::address_of(&sender2);
        cache::set_feed_configs(&admin, c, vector[t::config_entry(t::id(1), b"BTC/USD", vector[t::default_perm(s), t::default_perm(s2)])]);
        assert!(vector::length(&cache::get_feed_permissions(c, t::id(1))) == 2, 1);
        assert!(cache::has_permission(c, t::id(1), s, t::owner_bytes(0x11), t::name_bytes(0x22)), 2);
        assert!(cache::has_permission(c, t::id(1), s2, t::owner_bytes(0x11), t::name_bytes(0x22)), 3);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1, sender2 = @0xB2)]
    fun cache_set_feed_configs_feed_config_set_event_carries_every_permission(fw: signer, owner: signer, admin: signer, sender: signer, sender2: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
        let s = signer::address_of(&sender);
        let s2 = signer::address_of(&sender2);
        cache::set_feed_configs(&admin, c, vector[t::config_entry(t::id(1), b"MULTI", vector[t::default_perm(s), t::default_perm(s2)])]);
        assert!(t::emitted(&cache::feed_config_set_event(t::id(1), 18, string::utf8(b"MULTI"), vector[t::default_perm(s), t::default_perm(s2)])), 1);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1, sender2 = @0xB2)]
    #[expected_failure(abort_code = 108, location = data_feeds::cache)]
    fun cache_set_feed_configs_duplicate_id_in_one_batch_is_rejected(fw: signer, owner: signer, admin: signer, sender: signer, sender2: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
        cache::set_feed_configs(&admin, c, vector[
            t::config_entry(t::id(1), b"A", vector[t::default_perm(signer::address_of(&sender))]),
            t::config_entry(t::id(1), b"B", vector[t::default_perm(signer::address_of(&sender2))]),
        ]);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1, sender2 = @0xB2)]
    fun cache_set_feed_configs_batch_configures_multiple_distinct_feeds(fw: signer, owner: signer, admin: signer, sender: signer, sender2: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
        let s = signer::address_of(&sender);
        let s2 = signer::address_of(&sender2);
        cache::set_feed_configs(&admin, c, vector[
            t::config_entry(t::id(1), b"A", vector[t::default_perm(s)]),
            t::config_entry(t::id(2), b"B", vector[t::default_perm(s2)]),
        ]);
        assert!(vector::length(&cache::get_feed_permissions(c, t::id(1))) == 1, 1);
        assert!(vector::length(&cache::get_feed_permissions(c, t::id(2))) == 1, 2);
        assert!(cache::has_permission(c, t::id(1), s, t::owner_bytes(0x11), t::name_bytes(0x22)), 3);
        assert!(cache::has_permission(c, t::id(2), s2, t::owner_bytes(0x11), t::name_bytes(0x22)), 4);
        assert!(!cache::has_permission(c, t::id(1), s2, t::owner_bytes(0x11), t::name_bytes(0x22)), 5);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1, sender2 = @0xB2)]
    fun cache_set_feed_configs_re_add_by_a_different_workflow_inherits_prior_history_and_counter(fw: signer, owner: signer, admin: signer, sender: signer, sender2: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        t::advance_to(1000);
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
        let s = signer::address_of(&sender);
        let s2 = signer::address_of(&sender2);
        t::configure(&admin, c, t::id(1), b"BTC/USD", s);
        t::report(&sender, c, vector[t::entry(t::id(1), 111, 10)]);
        t::report(&sender, c, vector[t::entry(t::id(1), 222, 20)]);
        assert!(cache::round_data_round_id(&t::latest(c, t::id(1))) == 2, 1);
        cache::remove_feed_configs(&admin, c, vector[t::id(1)]);
        cache::set_feed_configs(&admin, c, vector[t::config_entry(t::id(1), b"REPURPOSED FEED",
            vector[t::perm(s2, t::owner_bytes(0x77), t::name_bytes(0x66))])]);
        t::assert_round(&t::latest(c, t::id(1)), 2, 222, 20);
        let r1 = option::destroy_some(cache::get_round(c, t::id(1), 1));
        assert!(cache::round_data_answer(&r1) == 111 && cache::round_data_timestamp(&r1) == 10, 2);
        assert!(vector::length(&t::full_range(c, t::id(1))) == 2, 3);
        t::report_as(&sender2, c, t::owner_bytes(0x77), t::name_bytes(0x66), vector[t::entry(t::id(1), 999, 30)]);
        let l = t::latest(c, t::id(1));
        assert!(cache::round_data_round_id(&l) == 3 && cache::round_data_answer(&l) == 999, 4);
        t::report(&sender, c, vector[t::entry(t::id(1), 555, 40)]);
        assert!(cache::round_data_round_id(&t::latest(c, t::id(1))) == 3, 5);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_set_feed_configs_re_add_first_report_is_rejected_stale_against_the_resurrected_timestamp(fw: signer, owner: signer, admin: signer, sender: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        t::advance_to(1000);
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
        let s = signer::address_of(&sender);
        t::configure(&admin, c, t::id(1), b"BTC/USD", s);
        t::report(&sender, c, vector[t::entry(t::id(1), 100, 1000000)]);
        assert!(cache::round_data_timestamp(&t::latest(c, t::id(1))) == 1000000, 1);
        cache::remove_feed_configs(&admin, c, vector[t::id(1)]);
        t::configure(&admin, c, t::id(1), b"BTC/USD", s);
        t::report(&sender, c, vector[t::entry(t::id(1), 200, 500000)]);
        assert!(t::emitted(&cache::stale_report_event(t::id(1), 500000, 1000000)), 2);
        let l = t::latest(c, t::id(1));
        assert!(cache::round_data_round_id(&l) == 1 && cache::round_data_answer(&l) == 100, 3);
        t::report(&sender, c, vector[t::entry(t::id(1), 300, 1000001)]);
        let l = t::latest(c, t::id(1));
        assert!(cache::round_data_round_id(&l) == 2 && cache::round_data_timestamp(&l) == 1000001, 4);
    }

    // ----- remove_feed_configs ---------------------------------------------------------

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1, stranger = @0xC1)]
    #[expected_failure(abort_code = 101, location = data_feeds::cache)]
    fun cache_remove_feed_configs_non_admin_caller_is_unauthorized(fw: signer, owner: signer, admin: signer, sender: signer, stranger: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
        t::configure(&admin, c, t::id(1), b"BTC/USD", signer::address_of(&sender));
        cache::remove_feed_configs(&stranger, c, vector[t::id(1)]);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2)]
    fun cache_remove_feed_configs_empty_batch_is_noop_success(fw: signer, owner: signer, admin: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
        let before = t::snapshot();
        cache::remove_feed_configs(&admin, c, vector[]);
        t::assert_no_events(&before);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_remove_feed_configs_deletes_config_and_permissions(fw: signer, owner: signer, admin: signer, sender: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
        let s = signer::address_of(&sender);
        t::configure(&admin, c, t::id(1), b"BTC/USD", s);
        cache::remove_feed_configs(&admin, c, vector[t::id(1)]);
        assert!(t::emitted(&cache::feed_config_removed_event(t::id(1))), 1);
        assert!(!cache::has_permission(c, t::id(1), s, t::owner_bytes(0x11), t::name_bytes(0x22)), 2);
        assert!(vector::is_empty(&cache::get_feed_permissions(c, t::id(1))), 3);
        assert!(cache::description(c, vector[t::id(1)]) == vector[option::none()], 4);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    #[expected_failure(abort_code = 102, location = data_feeds::cache)]
    fun cache_remove_feed_configs_containing_unconfigured_feed_aborts_atomically(fw: signer, owner: signer, admin: signer, sender: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
        let s = signer::address_of(&sender);
        t::configure(&admin, c, t::id(1), b"BTC/USD", s);
        assert!(cache::has_permission(c, t::id(1), s, t::owner_bytes(0x11), t::name_bytes(0x22)), 1);
        assert!(vector::length(&cache::get_feed_permissions(c, t::id(1))) == 1, 2);
        assert!(cache::description(c, vector[t::id(1)]) == vector[option::some(string::utf8(b"BTC/USD"))], 3);
        cache::remove_feed_configs(&admin, c, vector[t::id(1), t::id(9)]);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    #[expected_failure(abort_code = 108, location = data_feeds::cache)]
    fun cache_remove_feed_configs_duplicate_id_in_one_batch_is_rejected_and_removes_nothing(fw: signer, owner: signer, admin: signer, sender: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
        let s = signer::address_of(&sender);
        t::configure(&admin, c, t::id(1), b"BTC/USD", s);
        assert!(cache::has_permission(c, t::id(1), s, t::owner_bytes(0x11), t::name_bytes(0x22)), 1);
        assert!(vector::length(&cache::get_feed_permissions(c, t::id(1))) == 1, 2);
        assert!(cache::description(c, vector[t::id(1)]) == vector[option::some(string::utf8(b"BTC/USD"))], 3);
        cache::remove_feed_configs(&admin, c, vector[t::id(1), t::id(1)]);
    }

    // ----- add_feed_admin --------------------------------------------------------------

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, stranger = @0xC1)]
    #[expected_failure(abort_code = 0x50001, location = data_feeds::ownable)]
    fun cache_add_feed_admin_by_non_owner_host_fails(fw: signer, owner: signer, admin: signer, stranger: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::add_feed_admin(&stranger, c, signer::address_of(&admin));
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2)]
    fun cache_add_feed_admin_add_emits_and_registers(fw: signer, owner: signer, admin: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        let a = signer::address_of(&admin);
        let before = t::snapshot();
        cache::add_feed_admin(&owner, c, a);
        t::assert_only(&before, t::e_feed_admin_added(), 1);
        assert!(t::emitted(&cache::feed_admin_added_event(a)), 1);
        assert!(cache::is_feed_admin(c, a), 2);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2)]
    fun cache_add_feed_admin_re_add_emits_and_stays_registered(fw: signer, owner: signer, admin: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        let a = signer::address_of(&admin);
        cache::add_feed_admin(&owner, c, a);
        let before = t::snapshot();
        cache::add_feed_admin(&owner, c, a);
        t::assert_count(&before, t::e_feed_admin_added(), 1);
        assert!(t::emitted(&cache::feed_admin_added_event(a)), 1);
        assert!(cache::is_feed_admin(c, a), 2);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, admin2 = @0xA3)]
    #[expected_failure(abort_code = 0x50001, location = data_feeds::ownable)]
    fun cache_add_feed_admin_feed_admin_cannot_set_admin(fw: signer, owner: signer, admin: signer, admin2: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
        cache::add_feed_admin(&admin, c, signer::address_of(&admin2));
    }

    // ----- remove_feed_admin -----------------------------------------------------------

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2)]
    fun cache_remove_feed_admin_remove_then_not_admin_and_idempotent_emits(fw: signer, owner: signer, admin: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        let a = signer::address_of(&admin);
        cache::add_feed_admin(&owner, c, a);
        let before = t::snapshot();
        cache::remove_feed_admin(&owner, c, a);
        t::assert_count(&before, t::e_feed_admin_removed(), 1);
        assert!(t::emitted(&cache::feed_admin_removed_event(a)), 1);
        assert!(!cache::is_feed_admin(c, a), 2);
        let before = t::snapshot();
        cache::remove_feed_admin(&owner, c, a);
        t::assert_count(&before, t::e_feed_admin_removed(), 1);
        assert!(t::emitted(&cache::feed_admin_removed_event(a)), 3);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, stranger = @0xC1)]
    #[expected_failure(abort_code = 0x50001, location = data_feeds::ownable)]
    fun cache_remove_feed_admin_by_non_owner_host_fails(fw: signer, owner: signer, admin: signer, stranger: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::remove_feed_admin(&stranger, c, signer::address_of(&admin));
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    #[expected_failure(abort_code = 101, location = data_feeds::cache)]
    fun cache_remove_feed_admin_removed_admin_can_no_longer_configure(fw: signer, owner: signer, admin: signer, sender: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        let a = signer::address_of(&admin);
        cache::add_feed_admin(&owner, c, a);
        cache::remove_feed_admin(&owner, c, a);
        t::configure(&admin, c, t::id(1), b"X", signer::address_of(&sender));
    }

    // ----- get_feed_permissions --------------------------------------------------------

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_get_feed_permissions_configured_feed_returns_its_whole_permission_list(fw: signer, owner: signer, admin: signer, sender: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
        let s = signer::address_of(&sender);
        t::configure(&admin, c, t::id(1), b"BTC/USD", s);
        let perms = cache::get_feed_permissions(c, t::id(1));
        assert!(vector::length(&perms) == 1, 1);
        t::assert_permission(vector::borrow(&perms, 0), s, t::owner_bytes(0x11), t::name_bytes(0x22));
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_get_feed_permissions_unconfigured_feed_returns_empty(fw: signer, owner: signer, admin: signer, sender: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
        t::configure(&admin, c, t::id(1), b"BTC/USD", signer::address_of(&sender));
        assert!(vector::is_empty(&cache::get_feed_permissions(c, t::id(9))), 1);
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    fun cache_get_feed_permissions_zero_id_is_empty_not_rejected(fw: signer, owner: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        assert!(vector::is_empty(&cache::get_feed_permissions(c, t::zero32())), 1);
    }

    // ----- has_permission --------------------------------------------------------------

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_has_permission_true_for_configured_sender_owner_name(fw: signer, owner: signer, admin: signer, sender: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
        let s = signer::address_of(&sender);
        t::configure(&admin, c, t::id(1), b"BTC/USD", s);
        assert!(cache::has_permission(c, t::id(1), s, t::owner_bytes(0x11), t::name_bytes(0x22)), 1);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1, stranger = @0xC1)]
    fun cache_has_permission_false_for_unknown_sender_or_feed(fw: signer, owner: signer, admin: signer, sender: signer, stranger: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
        let s = signer::address_of(&sender);
        t::configure(&admin, c, t::id(1), b"BTC/USD", s);
        assert!(!cache::has_permission(c, t::id(1), signer::address_of(&stranger), t::owner_bytes(0x11), t::name_bytes(0x22)), 1);
        assert!(!cache::has_permission(c, t::id(9), s, t::owner_bytes(0x11), t::name_bytes(0x22)), 2);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, stranger = @0xC1)]
    fun cache_has_permission_zero_id_is_false_not_rejected(fw: signer, owner: signer, stranger: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        assert!(!cache::has_permission(c, t::zero32(), signer::address_of(&stranger), t::owner_bytes(0x11), t::name_bytes(0x22)), 1);
    }
}
