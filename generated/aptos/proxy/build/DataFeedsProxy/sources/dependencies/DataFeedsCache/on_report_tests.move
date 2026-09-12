#[test_only]
// Scenarios: cache.on_report.* (applicable ones) plus the A.2 equivalent of
// `sender_without_auth_host_fails` and decoder-strictness conditions.
module data_feeds::on_report_tests {
    use std::option;
    use std::signer;
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

    #[test(fw = @aptos_framework, owner = @0xA1, sender = @0xB1)]
    #[expected_failure(abort_code = 100, location = data_feeds::cache)]
    fun cache_on_report_metadata_63_bytes_is_malformed(fw: signer, owner: signer, sender: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::on_report(&sender, c, t::repeat(0, 63), t::encode_report(vector[]));
    }

    #[test(fw = @aptos_framework, owner = @0xA1, sender = @0xB1)]
    #[expected_failure(abort_code = 100, location = data_feeds::cache)]
    fun cache_on_report_metadata_65_bytes_is_malformed(fw: signer, owner: signer, sender: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::on_report(&sender, c, t::repeat(0, 65), t::encode_report(vector[]));
    }

    // decode_fail: the contract's strict decoder reports `MalformedReport` (100).
    #[test(fw = @aptos_framework, owner = @0xA1, sender = @0xB1)]
    #[expected_failure(abort_code = 100, location = data_feeds::cache)]
    fun cache_on_report_report_with_trailing_bytes_fails_to_decode(fw: signer, owner: signer, sender: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        let body = t::encode_report(vector[t::entry(t::id(1), 1, 1)]);
        vector::push_back(&mut body, 0x00);
        cache::on_report(&sender, c, t::default_metadata(), body);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, sender = @0xB1)]
    #[expected_failure(abort_code = 100, location = data_feeds::cache)]
    fun cache_on_report_undecodable_report_fails_to_decode(fw: signer, owner: signer, sender: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::on_report(&sender, c, t::default_metadata(), x"FFFFFFFFFFFFFF");
    }

    #[test(fw = @aptos_framework, owner = @0xA1, sender = @0xB1)]
    fun cache_on_report_empty_entry_vec_is_a_valid_no_op(fw: signer, owner: signer, sender: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        let before = t::snapshot();
        t::report(&sender, c, vector[]);
        t::assert_no_events(&before);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_on_report_data_id_must_match_the_configured_id_exactly(fw: signer, owner: signer, admin: signer, sender: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
        t::configure(&admin, c, t::id(7), b"BTC/USD", signer::address_of(&sender));
        t::report(&sender, c, vector[t::entry(t::id(7), 100, 5)]);
        t::report(&sender, c, vector[t::entry(t::wire(7, 0xBB), 200, 6)]);
        assert!(vector::length(&t::full_range(c, t::id(7))) == 1, 1);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, sender = @0xB1)]
    fun cache_on_report_unconfigured_feed_soft_skips_with_event_and_writes_nothing(fw: signer, owner: signer, sender: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        let s = signer::address_of(&sender);
        let before = t::snapshot();
        t::report(&sender, c, vector[t::entry(t::id(9), 100, 5)]);
        t::assert_only(&before, t::e_invalid_update_permission(), 1);
        assert!(t::emitted(&cache::invalid_update_permission_event(t::id(9), s, t::owner_bytes(0x11), t::name_bytes(0x22))), 1);
        assert!(vector::is_empty(&t::full_range(c, t::id(9))), 2);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1, stranger = @0xC1)]
    fun cache_on_report_wrong_owner_or_name_or_sender_does_not_record(fw: signer, owner: signer, admin: signer, sender: signer, stranger: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        t::report_as(&sender, c, t::owner_bytes(0x99), t::name_bytes(0x22), vector[t::entry(t::id(1), 1, 5)]);
        t::report_as(&sender, c, t::owner_bytes(0x11), t::name_bytes(0x99), vector[t::entry(t::id(1), 1, 6)]);
        t::report(&stranger, c, vector[t::entry(t::id(1), 1, 7)]);
        assert!(vector::is_empty(&t::full_range(c, t::id(1))), 1);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1, sender2 = @0xB2)]
    fun cache_on_report_revoked_sender_is_soft_skipped_after_reconfigure(fw: signer, owner: signer, admin: signer, sender: signer, sender2: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
        let s = signer::address_of(&sender);
        t::configure(&admin, c, t::id(1), b"old", s);
        t::report(&sender, c, vector[t::entry(t::id(1), 100, 5)]);
        assert!(vector::length(&t::full_range(c, t::id(1))) == 1, 1);
        t::configure(&admin, c, t::id(1), b"new", signer::address_of(&sender2));
        t::report(&sender, c, vector[t::entry(t::id(1), 200, 6)]);
        assert!(t::emitted(&cache::invalid_update_permission_event(t::id(1), s, t::owner_bytes(0x11), t::name_bytes(0x22))), 2);
        assert!(vector::length(&t::full_range(c, t::id(1))) == 1, 3);
        t::report(&sender2, c, vector[t::entry(t::id(1), 200, 6)]);
        assert!(vector::length(&t::full_range(c, t::id(1))) == 2, 4);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_on_report_removed_feed_sender_is_soft_skipped(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        let s = signer::address_of(&sender);
        t::report(&sender, c, vector[t::entry(t::id(1), 100, 5)]);
        assert!(vector::length(&t::full_range(c, t::id(1))) == 1, 1);
        cache::remove_feed_configs(&admin, c, vector[t::id(1)]);
        t::report(&sender, c, vector[t::entry(t::id(1), 200, 6)]);
        assert!(t::emitted(&cache::invalid_update_permission_event(t::id(1), s, t::owner_bytes(0x11), t::name_bytes(0x22))), 2);
        assert!(vector::length(&t::full_range(c, t::id(1))) == 1, 3);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_on_report_equal_or_older_timestamp_is_stale_and_emits_event(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        t::report(&sender, c, vector[t::entry(t::id(1), 100, 5)]);
        t::report(&sender, c, vector[t::entry(t::id(1), 999, 5)]);
        assert!(t::emitted(&cache::stale_report_event(t::id(1), 5, 5)), 1);
        t::report(&sender, c, vector[t::entry(t::id(1), 999, 4)]);
        assert!(vector::length(&t::full_range(c, t::id(1))) == 1, 2);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_on_report_absent_latest_means_stored_ts_zero(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        t::report(&sender, c, vector[t::entry(t::id(1), 7, 0)]);
        assert!(t::emitted(&cache::stale_report_event(t::id(1), 0, 0)), 1);
        t::report(&sender, c, vector[t::entry(t::id(1), 7, 1)]);
        assert!(cache::round_data_round_id(&t::latest(c, t::id(1))) == 1, 2);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_on_report_in_batch_stale_entries_use_running_ts_and_do_not_block_later_accepts(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        t::report(&sender, c, vector[t::entry(t::id(1), 10, 10)]);
        let before = t::snapshot();
        t::report(&sender, c, vector[t::entry(t::id(1), 100, 11), t::entry(t::id(1), 200, 11)]);
        // count: 2 events (one FeedUpdated, one StaleReport)
        t::assert_count(&before, t::e_feed_updated(), 1);
        t::assert_count(&before, t::e_stale_report(), 1);
        t::assert_count(&before, t::e_invalid_update_permission(), 0);
        assert!(t::emitted(&cache::stale_report_event(t::id(1), 11, 11)), 1);
        assert!(vector::length(&t::full_range(c, t::id(1))) == 2, 2);
        t::report(&sender, c, vector[t::entry(t::id(1), 300, 11), t::entry(t::id(1), 400, 12)]);
        assert!(vector::length(&t::full_range(c, t::id(1))) == 3, 3);
        assert!(cache::round_data_timestamp(&t::latest(c, t::id(1))) == 12, 4);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_on_report_multiple_reports_for_one_feed_advance_the_counter_twice(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        t::report(&sender, c, vector[t::entry(t::id(1), 100, 5), t::entry(t::id(1), 200, 6)]);
        let r = t::full_range(c, t::id(1));
        assert!(vector::length(&r) == 2, 1);
        assert!(cache::round_data_round_id(vector::borrow(&r, 0)) == 1, 2);
        assert!(cache::round_data_round_id(vector::borrow(&r, 1)) == 2, 3);
        assert!(cache::round_data_answer(vector::borrow(&r, 1)) == 200, 4);
        assert!(cache::round_data_timestamp(&t::latest(c, t::id(1))) == 6, 5);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_on_report_first_accept_assigns_round_one_and_stores_provenance(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        t::advance_to(4242);
        t::report(&sender, c, vector[t::entry(t::id(1), 100, 5)]);
        t::assert_round_full(&t::latest(c, t::id(1)), 1, 100, 5, 4242, true);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_on_report_round_id_increments_per_feed_independently(fw: signer, owner: signer, admin: signer, sender: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
        let s = signer::address_of(&sender);
        t::configure(&admin, c, t::id(1), b"A", s);
        t::configure(&admin, c, t::id(2), b"B", s);
        t::report(&sender, c, vector[t::entry(t::id(1), 1, 5)]);
        t::report(&sender, c, vector[t::entry(t::id(1), 2, 6)]);
        t::report(&sender, c, vector[t::entry(t::id(2), 9, 5)]);
        assert!(cache::round_data_round_id(&t::latest(c, t::id(1))) == 2, 1);
        assert!(cache::round_data_round_id(&t::latest(c, t::id(2))) == 1, 2);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_on_report_i256_answer_fidelity_across_full_range(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        let max_i128: u256 = 170141183460469231731687303715884105727;
        t::report(&sender, c, vector[t::entry(t::id(1), max_i128, 5)]);
        assert!(cache::round_data_answer(&t::latest(c, t::id(1))) == max_i128, 1);
        let min_i128 = t::neg(170141183460469231731687303715884105728);
        t::report(&sender, c, vector[t::entry(t::id(1), min_i128, 6)]);
        assert!(cache::round_data_answer(&t::latest(c, t::id(1))) == min_i128, 2);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_on_report_i256_answer_beyond_i128_survives(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        let max_i256: u256 = 57896044618658097711785492504343953926634992332820282019728792003956564819967;
        t::report(&sender, c, vector[t::entry(t::id(1), max_i256, 5)]);
        assert!(cache::round_data_answer(&t::latest(c, t::id(1))) == max_i256, 1);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_on_report_mixed_batch_lands_valid_skips_soft_and_returns_ok(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        t::report(&sender, c, vector[t::entry(t::id(1), 10, 10)]);
        t::report(&sender, c, vector[
            t::entry(t::id(1), 11, 11),
            t::entry(t::id(9), 99, 99),
            t::entry(t::id(1), 5, 5),
            t::entry(t::id(1), 12, 12),
        ]);
        assert!(vector::length(&t::full_range(c, t::id(1))) == 3, 1);
        let l = t::latest(c, t::id(1));
        assert!(cache::round_data_round_id(&l) == 3 && cache::round_data_timestamp(&l) == 12, 2);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_on_report_two_accept_batch_emits_exactly_two_feed_updated(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        let before = t::snapshot();
        t::report(&sender, c, vector[t::entry(t::id(1), 1, 5), t::entry(t::id(1), 2, 6)]);
        t::assert_only(&before, t::e_feed_updated(), 2);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_on_report_mixed_batch_two_feeds_land_independently_with_correct_event_fields(fw: signer, owner: signer, admin: signer, sender: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
        let s = signer::address_of(&sender);
        t::configure(&admin, c, t::id(1), b"A", s);
        t::configure(&admin, c, t::id(2), b"B", s);
        t::advance_to(100);
        t::report(&sender, c, vector[t::entry(t::id(1), 111, 10), t::entry(t::id(2), 222, 20), t::entry(t::id(1), 333, 11)]);
        assert!(t::emitted(&cache::feed_updated_event(t::id(2), 1, 20, 222, 100, true)), 1);
        assert!(cache::round_data_round_id(&t::latest(c, t::id(1))) == 2, 2);
        let l2 = t::latest(c, t::id(2));
        assert!(cache::round_data_round_id(&l2) == 1 && cache::round_data_answer(&l2) == 222, 3);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_on_report_stale_skip_on_one_feed_does_not_corrupt_a_sibling_accept_in_same_batch(fw: signer, owner: signer, admin: signer, sender: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
        let s = signer::address_of(&sender);
        t::configure(&admin, c, t::id(1), b"A", s);
        t::configure(&admin, c, t::id(2), b"B", s);
        t::report(&sender, c, vector[t::entry(t::id(1), 999, 20)]);
        t::report(&sender, c, vector[t::entry(t::id(1), 777, 15), t::entry(t::id(2), 222, 5)]);
        assert!(t::emitted(&cache::stale_report_event(t::id(1), 15, 20)), 1);
        t::assert_round(&t::latest(c, t::id(2)), 1, 222, 5);
        t::assert_round(&t::latest(c, t::id(1)), 1, 999, 20);
    }

    // ----- spec/05 conditions beyond the applicable corpus -----------------------------

    // A.2 equivalent of `sender_without_auth_host_fails`: a non-permitted caller is
    // soft-skipped with its own identity in `InvalidUpdatePermission` and cannot claim
    // another sender's permission.
    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1, stranger = @0xC1)]
    fun cache_on_report_caller_identity_is_the_sender(fw: signer, owner: signer, admin: signer, sender: signer, stranger: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        let before = t::snapshot();
        t::report(&stranger, c, vector[t::entry(t::id(1), 100, 5)]);
        t::assert_only(&before, t::e_invalid_update_permission(), 1);
        assert!(t::emitted(&cache::invalid_update_permission_event(t::id(1), signer::address_of(&stranger), t::owner_bytes(0x11), t::name_bytes(0x22))), 1);
        assert!(!t::emitted(&cache::invalid_update_permission_event(t::id(1), signer::address_of(&sender), t::owner_bytes(0x11), t::name_bytes(0x22))), 2);
        assert!(t::latest_is_none(c, t::id(1)), 3);
    }

    // Decoder strictness: a truncated body is `MalformedReport`.
    #[test(fw = @aptos_framework, owner = @0xA1, sender = @0xB1)]
    #[expected_failure(abort_code = 100, location = data_feeds::cache)]
    fun cache_on_report_truncated_report_fails_to_decode(fw: signer, owner: signer, sender: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        let body = t::encode_report(vector[t::entry(t::id(1), 1, 1)]);
        vector::pop_back(&mut body);
        cache::on_report(&sender, c, t::default_metadata(), body);
    }

    // Decoder strictness: a non-minimal ULEB128 count (0x80 0x00 = 0) is `MalformedReport`.
    #[test(fw = @aptos_framework, owner = @0xA1, sender = @0xB1)]
    #[expected_failure(abort_code = 100, location = data_feeds::cache)]
    fun cache_on_report_non_minimal_uleb128_fails_to_decode(fw: signer, owner: signer, sender: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::on_report(&sender, c, t::default_metadata(), x"8000");
    }

    // Decoder strictness: a count above u32 is `MalformedReport`.
    #[test(fw = @aptos_framework, owner = @0xA1, sender = @0xB1)]
    #[expected_failure(abort_code = 100, location = data_feeds::cache)]
    fun cache_on_report_length_above_u32_fails_to_decode(fw: signer, owner: signer, sender: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::on_report(&sender, c, t::default_metadata(), x"8080808010");
    }

    // The decoder does not check id widths: a mis-sized id decodes and is soft-skipped.
    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_on_report_mis_sized_id_is_soft_skipped(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        let before = t::snapshot();
        t::report(&sender, c, vector[t::entry(x"0102", 100, 5)]);
        t::assert_only(&before, t::e_invalid_update_permission(), 1);
        assert!(t::emitted(&cache::invalid_update_permission_event(x"0102", signer::address_of(&sender), t::owner_bytes(0x11), t::name_bytes(0x22))), 1);
    }

    // Metadata layout: the report is judged against `[32,42) name` / `[42,62) owner`; the
    // cid and report_id bytes are carried but never validated.
    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_on_report_cid_and_report_id_are_not_validated(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        let md = t::metadata_with(t::repeat(0xAB, 32), t::name_bytes(0x22), t::owner_bytes(0x11), x"FFFF");
        cache::on_report(&sender, c, md, t::encode_report(vector[t::entry(t::id(1), 100, 5)]));
        t::assert_round(&t::latest(c, t::id(1)), 1, 100, 5);
    }

    // spec/06 B.6: a `Round` that must be created at tip + 1 but already exists is an
    // inconsistent state and fails with the platform's native "already exists" error
    // (`aptos_std::table` ALREADY_EXISTS = 0x6407), never a spec code. Unreachable through
    // the public interface; the state is forged with the test-only injector.
    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    #[expected_failure(abort_code = 0x6407, location = aptos_std::table)]
    fun cache_on_report_pre_existing_round_at_next_id_is_native_already_exists(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        t::seed(&sender, c, t::id(1), 1);
        cache::test_inject_round(c, t::id(1), 2, 5, 5);
        t::report(&sender, c, vector[t::entry(t::id(1), 200, 20)]);
    }

    // Lifetime refreshes are no-ops (spec/06 C.3): everything a report touches persists.
    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_on_report_refreshed_records_persist(fw: signer, owner: signer, admin: signer, sender: signer) {
        let c = setup_feed(&fw, &owner, &admin, &sender);
        let s = signer::address_of(&sender);
        t::seed(&sender, c, t::id(1), 2);
        t::advance_to(100_000_000);
        assert!(cache::is_feed_admin(c, signer::address_of(&admin)), 1);
        assert!(cache::is_configured(c, vector[t::id(1)]) == vector[true], 2);
        assert!(cache::has_permission(c, t::id(1), s, t::owner_bytes(0x11), t::name_bytes(0x22)), 3);
        t::assert_round(&t::latest(c, t::id(1)), 2, 200, 20);
        assert!(option::is_some(&cache::get_round(c, t::id(1), 2)), 4);
    }
}
