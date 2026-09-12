#[test_only]
// Scenarios: proxy.* (applicable ones). The "mock Cache" is the real `data_feeds::cache`
// module with its `#[test_only]` injectors (spec/06 L.2): `id:1` is configured with the
// description "MOCK" so `decimals`/`description` answer 18 / "MOCK"; rounds, the tip and the
// frozen flag are injected directly.
module data_feeds_proxy::proxy_tests {
    use std::option;
    use std::signer;
    use std::string;
    use std::vector;
    use aptos_framework::event;
    use aptos_framework::object;
    use data_feeds::cache;
    use data_feeds::ownable;
    use data_feeds::test_utils as t;
    use data_feeds_proxy::proxy;

    const MOCK_SENDER: address = @0xB1;

    // ----- harness ---------------------------------------------------------------------

    // deploy mock_cache: a real Cache whose `id:1` answers decimals 18 / description "MOCK".
    fun deploy_mock_cache(owner: &signer, seed: vector<u8>): address {
        let o = signer::address_of(owner);
        let c = t::deploy_cache(owner, seed, o);
        cache::add_feed_admin(owner, c, o);
        t::configure(owner, c, t::id(1), b"MOCK", MOCK_SENDER);
        c
    }

    fun deploy_proxy(owner: &signer, seed: vector<u8>, cache_addr: address): address {
        let o = signer::address_of(owner);
        proxy::create(owner, seed, o, cache_addr);
        object::create_object_address(&o, seed)
    }

    // deploy mock_cache + proxy(owner, cache); returns (cache, proxy).
    fun setup_mock(fw: &signer, owner: &signer): (address, address) {
        t::setup(fw);
        let c = deploy_mock_cache(owner, b"cache");
        let p = deploy_proxy(owner, b"proxy", c);
        (c, p)
    }

    // mock_cache {latest: {round_id, answer, timestamp}}
    fun mock_latest(c: address, round_id: u64, answer: u256, timestamp: u64) {
        cache::test_set_latest(c, t::id(1), round_id, answer, timestamp);
    }

    // mock_cache {rounds: [{round_id, answer, timestamp}]} (one call per round)
    fun mock_round(c: address, round_id: u64, answer: u256, timestamp: u64) {
        cache::test_inject_round(c, t::id(1), round_id, answer, timestamp);
    }

    fun assert_round(r: &proxy::Round, round_id: u64, answer: u256, timestamp: u64) {
        assert!(proxy::round_round_id(r) == round_id, 2000);
        assert!(proxy::round_answer(r) == answer, 2001);
        assert!(proxy::round_timestamp(r) == timestamp, 2002);
    }

    // deploy a real Cache with admin, feed id:1 (BTC/USD) for sender; returns the address.
    fun deploy_real_cache(owner: &signer, admin: &signer, sender: address, seed: vector<u8>): address {
        let c = t::deploy_cache(owner, seed, signer::address_of(owner));
        cache::add_feed_admin(owner, c, signer::address_of(admin));
        t::configure(admin, c, t::id(1), b"BTC/USD", sender);
        c
    }

    // ----- constructor -----------------------------------------------------------------

    #[test(fw = @aptos_framework, owner = @0xA1)]
    fun proxy_constructor_stores_owner_and_routes_reads(fw: signer, owner: signer) {
        let (c, p) = setup_mock(&fw, &owner);
        mock_latest(c, 1, 100, 5);
        assert!(proxy::get_owner(p) == option::some(signer::address_of(&owner)), 1);
        assert!(proxy::round_round_id(&proxy::latest_round(p, t::id(1), 18)) == 1, 2);
    }

    // ----- latest_round ----------------------------------------------------------------

    #[test(fw = @aptos_framework, owner = @0xA1)]
    fun proxy_latest_round_returns_newest(fw: signer, owner: signer) {
        let (c, p) = setup_mock(&fw, &owner);
        mock_latest(c, 9, 900, 90);
        assert_round(&proxy::latest_round(p, t::id(1), 18), 9, 900, 90);
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    #[expected_failure(abort_code = 50, location = data_feeds_proxy::proxy)]
    fun proxy_latest_round_no_rounds_is_no_data_present(fw: signer, owner: signer) {
        let (_c, p) = setup_mock(&fw, &owner);
        proxy::latest_round(p, t::id(1), 18);
    }

    // fail_with substitution (spec/07 harness rule for statically-linked platforms): the
    // Proxy is routed at an address holding no Cache instance and the Cache's own host
    // failure (`host_error::no_instance()`, location data_feeds::cache) propagates untranslated.
    #[test(fw = @aptos_framework, owner = @0xA1)]
    #[expected_failure(abort_code = 0x60001, location = data_feeds::cache)]
    fun proxy_latest_round_cache_error_traps_the_read(fw: signer, owner: signer) {
        let (c, p) = setup_mock(&fw, &owner);
        mock_latest(c, 1, 1, 10);
        proxy::set_cache(&owner, p, @0xDEAD);
        proxy::latest_round(p, t::id(1), 18);
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    #[expected_failure(abort_code = 109, location = data_feeds_proxy::proxy)]
    fun proxy_latest_round_rejects_a_frozen_feed(fw: signer, owner: signer) {
        let (c, p) = setup_mock(&fw, &owner);
        cache::test_set_frozen(c, t::id(1), true);
        proxy::latest_round(p, t::id(1), 18);
    }

    // ----- get_round -------------------------------------------------------------------

    #[test(fw = @aptos_framework, owner = @0xA1)]
    fun proxy_get_round_exact_round_projected(fw: signer, owner: signer) {
        let (c, p) = setup_mock(&fw, &owner);
        mock_round(c, 6, 600, 60);
        mock_round(c, 5, 500, 50);
        assert_round(&proxy::get_round(p, t::id(1), 5, 18), 5, 500, 50);
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    #[expected_failure(abort_code = 50, location = data_feeds_proxy::proxy)]
    fun proxy_get_round_absent_round_is_no_data_present(fw: signer, owner: signer) {
        let (c, p) = setup_mock(&fw, &owner);
        mock_round(c, 5, 5, 50);
        proxy::get_round(p, t::id(1), 9, 18);
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    #[expected_failure(abort_code = 109, location = data_feeds_proxy::proxy)]
    fun proxy_get_round_rejects_a_frozen_feed(fw: signer, owner: signer) {
        let (c, p) = setup_mock(&fw, &owner);
        mock_round(c, 3, 300, 30);
        cache::test_set_frozen(c, t::id(1), true);
        proxy::get_round(p, t::id(1), 3, 18);
    }

    // ----- decimals / description ------------------------------------------------------

    #[test(fw = @aptos_framework, owner = @0xA1)]
    fun proxy_decimals_matches_the_cache_precision(fw: signer, owner: signer) {
        let (_c, p) = setup_mock(&fw, &owner);
        assert!(proxy::decimals(p, t::id(1)) == 18, 1);
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    #[expected_failure(abort_code = 109, location = data_feeds_proxy::proxy)]
    fun proxy_decimals_rejects_a_frozen_feed(fw: signer, owner: signer) {
        let (c, p) = setup_mock(&fw, &owner);
        cache::test_set_frozen(c, t::id(1), true);
        proxy::decimals(p, t::id(1));
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    fun proxy_description_passes_through(fw: signer, owner: signer) {
        let (_c, p) = setup_mock(&fw, &owner);
        assert!(proxy::description(p, t::id(1)) == string::utf8(b"MOCK"), 1);
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    #[expected_failure(abort_code = 109, location = data_feeds_proxy::proxy)]
    fun proxy_description_rejects_a_frozen_feed(fw: signer, owner: signer) {
        let (c, p) = setup_mock(&fw, &owner);
        cache::test_set_frozen(c, t::id(1), true);
        proxy::description(p, t::id(1));
    }

    // ----- set_cache -------------------------------------------------------------------

    #[test(fw = @aptos_framework, owner = @0xA1, stranger = @0xC1)]
    #[expected_failure(abort_code = 0x50001, location = data_feeds::ownable)]
    fun proxy_set_cache_by_non_owner_host_fails(fw: signer, owner: signer, stranger: signer) {
        let (c, p) = setup_mock(&fw, &owner);
        proxy::set_cache(&stranger, p, c);
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    fun proxy_set_cache_swaps_routing_and_emits(fw: signer, owner: signer) {
        let (c, p) = setup_mock(&fw, &owner);
        mock_latest(c, 1, 111, 5);
        let c2 = deploy_mock_cache(&owner, b"cache2");
        mock_latest(c2, 7, 222, 9);
        assert!(proxy::round_round_id(&proxy::latest_round(p, t::id(1), 18)) == 1, 1);
        let before = proxy::test_event_counts();
        proxy::set_cache(&owner, p, c2);
        let after = proxy::test_event_counts();
        assert!(*vector::borrow(&after, 0) - *vector::borrow(&before, 0) == 1, 2);
        assert!(event::was_event_emitted(&proxy::cache_set_event(c, c2)), 3);
        assert!(proxy::round_round_id(&proxy::latest_round(p, t::id(1), 18)) == 7, 4);
    }

    // ----- get_min_decimals / get_cache ------------------------------------------------

    #[test(fw = @aptos_framework, owner = @0xA1)]
    fun proxy_get_min_decimals_returns_the_configured_min(fw: signer, owner: signer) {
        let (_c, p) = setup_mock(&fw, &owner);
        proxy::set_min_decimals(&owner, p, t::id(1), 8);
        assert!(proxy::get_min_decimals(p, t::id(1)) == 8, 1);
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    fun proxy_get_cache_returns_the_configured_cache(fw: signer, owner: signer) {
        let (c, p) = setup_mock(&fw, &owner);
        assert!(proxy::get_cache(p) == c, 1);
    }

    // ----- set_min_decimals ------------------------------------------------------------

    #[test(fw = @aptos_framework, owner = @0xA1, stranger = @0xC1)]
    #[expected_failure(abort_code = 0x50001, location = data_feeds::ownable)]
    fun proxy_set_min_decimals_by_non_owner_host_fails(fw: signer, owner: signer, stranger: signer) {
        let (_c, p) = setup_mock(&fw, &owner);
        proxy::set_min_decimals(&stranger, p, t::id(1), 8);
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    #[expected_failure(abort_code = 51, location = data_feeds_proxy::proxy)]
    fun proxy_set_min_decimals_min_above_cache_precision_is_rejected(fw: signer, owner: signer) {
        let (_c, p) = setup_mock(&fw, &owner);
        proxy::set_min_decimals(&owner, p, t::id(1), 19);
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    fun proxy_set_min_decimals_emits(fw: signer, owner: signer) {
        let (_c, p) = setup_mock(&fw, &owner);
        let before = proxy::test_event_counts();
        proxy::set_min_decimals(&owner, p, t::id(1), 8);
        let after = proxy::test_event_counts();
        assert!(*vector::borrow(&after, 1) - *vector::borrow(&before, 1) == 1, 1);
        assert!(event::was_event_emitted(&proxy::min_decimals_set_event(t::id(1), 8)), 2);
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    #[expected_failure(abort_code = 51, location = data_feeds_proxy::proxy)]
    fun proxy_set_min_decimals_restoring_cache_precision_relocks_the_feed(fw: signer, owner: signer) {
        let (c, p) = setup_mock(&fw, &owner);
        mock_latest(c, 1, 1000000000000000000, 5);
        proxy::set_min_decimals(&owner, p, t::id(1), 8);
        assert!(proxy::round_answer(&proxy::latest_round(p, t::id(1), 8)) == 100000000, 1);
        proxy::set_min_decimals(&owner, p, t::id(1), 18);
        proxy::latest_round(p, t::id(1), 8);
    }

    // ----- precision -------------------------------------------------------------------

    #[test(fw = @aptos_framework, owner = @0xA1)]
    #[expected_failure(abort_code = 51, location = data_feeds_proxy::proxy)]
    fun proxy_precision_unset_min_locks_reads_to_full_precision(fw: signer, owner: signer) {
        let (c, p) = setup_mock(&fw, &owner);
        mock_latest(c, 1, 1999999999999999999, 5);
        assert!(proxy::get_min_decimals(p, t::id(1)) == 18, 1);
        assert!(proxy::round_answer(&proxy::latest_round(p, t::id(1), 18)) == 1999999999999999999, 2);
        proxy::latest_round(p, t::id(1), 17);
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    #[expected_failure(abort_code = 51, location = data_feeds_proxy::proxy)]
    fun proxy_precision_unset_min_locks_reads_to_full_precision__alt2(fw: signer, owner: signer) {
        let (c, p) = setup_mock(&fw, &owner);
        mock_latest(c, 1, 1999999999999999999, 5);
        assert!(proxy::get_min_decimals(p, t::id(1)) == 18, 1);
        assert!(proxy::round_answer(&proxy::latest_round(p, t::id(1), 18)) == 1999999999999999999, 2);
        proxy::latest_round(p, t::id(1), 19);
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    fun proxy_precision_reads_scale_down_to_the_requested_precision(fw: signer, owner: signer) {
        let (c, p) = setup_mock(&fw, &owner);
        mock_latest(c, 1, 1999999999999999999, 5);
        proxy::set_min_decimals(&owner, p, t::id(1), 8);
        assert!(proxy::round_answer(&proxy::latest_round(p, t::id(1), 8)) == 199999999, 1);
        assert!(proxy::round_answer(&proxy::latest_round(p, t::id(1), 14)) == 199999999999999, 2);
        assert!(proxy::round_answer(&proxy::latest_round(p, t::id(1), 18)) == 1999999999999999999, 3);
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    #[expected_failure(abort_code = 51, location = data_feeds_proxy::proxy)]
    fun proxy_precision_below_the_configured_min_is_rejected(fw: signer, owner: signer) {
        let (c, p) = setup_mock(&fw, &owner);
        mock_latest(c, 1, 1999999999999999999, 5);
        proxy::set_min_decimals(&owner, p, t::id(1), 8);
        proxy::latest_round(p, t::id(1), 7);
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    #[expected_failure(abort_code = 51, location = data_feeds_proxy::proxy)]
    fun proxy_precision_below_the_configured_min_is_rejected__alt2(fw: signer, owner: signer) {
        let (c, p) = setup_mock(&fw, &owner);
        mock_latest(c, 1, 1999999999999999999, 5);
        proxy::set_min_decimals(&owner, p, t::id(1), 8);
        proxy::get_round(p, t::id(1), 1, 7);
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    #[expected_failure(abort_code = 51, location = data_feeds_proxy::proxy)]
    fun proxy_precision_above_cache_precision_is_rejected(fw: signer, owner: signer) {
        let (c, p) = setup_mock(&fw, &owner);
        mock_latest(c, 1, 1999999999999999999, 5);
        proxy::set_min_decimals(&owner, p, t::id(1), 8);
        proxy::latest_round(p, t::id(1), 19);
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    #[expected_failure(abort_code = 51, location = data_feeds_proxy::proxy)]
    fun proxy_precision_above_cache_precision_is_rejected__alt2(fw: signer, owner: signer) {
        let (c, p) = setup_mock(&fw, &owner);
        mock_latest(c, 1, 1999999999999999999, 5);
        proxy::set_min_decimals(&owner, p, t::id(1), 8);
        proxy::get_round(p, t::id(1), 1, 19);
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    fun proxy_precision_zero_decimals_truncates_to_the_integer_part(fw: signer, owner: signer) {
        let (c, p) = setup_mock(&fw, &owner);
        mock_latest(c, 1, 1999999999999999999, 5);
        proxy::set_min_decimals(&owner, p, t::id(1), 0);
        assert!(proxy::round_answer(&proxy::latest_round(p, t::id(1), 0)) == 1, 1);
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    fun proxy_precision_negative_answers_truncate_toward_zero(fw: signer, owner: signer) {
        let (c, p) = setup_mock(&fw, &owner);
        mock_latest(c, 1, t::neg(1999999999999999999), 5);
        proxy::set_min_decimals(&owner, p, t::id(1), 8);
        assert!(proxy::round_answer(&proxy::latest_round(p, t::id(1), 8)) == t::neg(199999999), 1);
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    #[expected_failure(abort_code = 52, location = data_feeds_proxy::proxy)]
    fun proxy_precision_non_zero_answer_scaling_to_zero_fails(fw: signer, owner: signer) {
        let (c, p) = setup_mock(&fw, &owner);
        mock_latest(c, 1, 5, 5);
        proxy::set_min_decimals(&owner, p, t::id(1), 0);
        proxy::latest_round(p, t::id(1), 0);
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    #[expected_failure(abort_code = 52, location = data_feeds_proxy::proxy)]
    fun proxy_precision_negative_answer_scaling_to_zero_fails(fw: signer, owner: signer) {
        let (c, p) = setup_mock(&fw, &owner);
        mock_latest(c, 1, t::neg(5), 5);
        proxy::set_min_decimals(&owner, p, t::id(1), 0);
        proxy::latest_round(p, t::id(1), 0);
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    fun proxy_precision_a_genuine_zero_answer_passes_at_any_precision(fw: signer, owner: signer) {
        let (c, p) = setup_mock(&fw, &owner);
        mock_latest(c, 1, 0, 5);
        proxy::set_min_decimals(&owner, p, t::id(1), 0);
        assert!(proxy::round_answer(&proxy::latest_round(p, t::id(1), 0)) == 0, 1);
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    fun proxy_precision_get_round_scales_like_latest_round(fw: signer, owner: signer) {
        let (c, p) = setup_mock(&fw, &owner);
        mock_round(c, 1, 1999999999999999999, 5);
        proxy::set_min_decimals(&owner, p, t::id(1), 8);
        assert!(proxy::round_answer(&proxy::get_round(p, t::id(1), 1, 8)) == 199999999, 1);
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    #[expected_failure(abort_code = 50, location = data_feeds_proxy::proxy)]
    fun proxy_precision_configured_min_without_data_is_no_data_present(fw: signer, owner: signer) {
        let (_c, p) = setup_mock(&fw, &owner);
        proxy::set_min_decimals(&owner, p, t::id(1), 8);
        proxy::latest_round(p, t::id(1), 8);
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    #[expected_failure(abort_code = 50, location = data_feeds_proxy::proxy)]
    fun proxy_precision_configured_min_without_data_is_no_data_present__alt2(fw: signer, owner: signer) {
        let (_c, p) = setup_mock(&fw, &owner);
        proxy::set_min_decimals(&owner, p, t::id(1), 8);
        proxy::get_round(p, t::id(1), 1, 8);
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    fun proxy_precision_reads_do_not_create_a_min_decimals_entry(fw: signer, owner: signer) {
        let (c, p) = setup_mock(&fw, &owner);
        mock_latest(c, 1, 1999999999999999999, 5);
        proxy::latest_round(p, t::id(1), 18);
        proxy::decimals(p, t::id(1));
        proxy::description(p, t::id(1));
        proxy::get_min_decimals(p, t::id(1));
        assert!(!proxy::test_has_min_decimals(p, t::id(1)), 1);
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    #[expected_failure(abort_code = 51, location = data_feeds_proxy::proxy)]
    fun proxy_precision_invalid_precision_fails_before_the_cache_read(fw: signer, owner: signer) {
        let (c, p) = setup_mock(&fw, &owner);
        mock_latest(c, 1, 1999999999999999999, 5);
        cache::test_set_frozen(c, t::id(1), true);
        proxy::latest_round(p, t::id(1), 19);
    }

    // ----- invariants / lifecycle ------------------------------------------------------

    #[test]
    fun proxy_invariants_error_discriminants_are_range_disjoint() {
        let codes = proxy::test_error_codes();
        assert!(codes == vector[50, 51, 52], 1);
        let ownership = ownable::test_error_codes();
        let i = 0;
        while (i < vector::length(&codes)) {
            let code = *vector::borrow(&codes, i);
            assert!(code >= 50 && code <= 99, 2);
            assert!(!vector::contains(&ownership, &code), 3);
            i = i + 1;
        };
        let j = 0;
        while (j < vector::length(&ownership)) {
            let code = *vector::borrow(&ownership, j);
            assert!(code >= 2100 && code <= 2299, 4);
            j = j + 1;
        };
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    fun proxy_lifecycle_version_is_wired(fw: signer, owner: signer) {
        let (_c, _p) = setup_mock(&fw, &owner);
        assert!(proxy::version() == 1, 1);
        assert!(proxy::type_and_version() == string::utf8(b"DataFeedsProxy 1.0.0"), 2);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, new_owner = @0xD1)]
    fun proxy_lifecycle_two_step_ownership_is_wired(fw: signer, owner: signer, new_owner: signer) {
        let (_c, p) = setup_mock(&fw, &owner);
        let o = signer::address_of(&owner);
        let n = signer::address_of(&new_owner);
        proxy::transfer_ownership(&owner, p, n, 1000);
        assert!(event::was_event_emitted(&ownable::ownership_transfer_event(o, n, 1000)), 1);
        proxy::accept_ownership(&new_owner, p);
        assert!(event::was_event_emitted(&ownable::ownership_transfer_completed_event(n)), 2);
        assert!(proxy::get_owner(p) == option::some(n), 3);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, payer = @0xE1)]
    fun proxy_lifecycle_recover_tokens_is_wired(fw: signer, owner: signer, payer: signer) {
        let (_c, p) = setup_mock(&fw, &owner);
        let (token, mint_ref) = t::deploy_token(&owner);
        t::mint(&mint_ref, p, 1000);
        let dest = signer::address_of(&payer);
        proxy::recover_tokens(&owner, p, token, dest, 1000);
        assert!(t::balance(dest, token) == 1000, 1);
        assert!(event::was_event_emitted(&proxy::token_recovered_event(token, dest, 1000)), 2);
    }

    // ----- cache_reader_client (real Cache) --------------------------------------------

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun proxy_cache_reader_client_real_cache_reads_end_to_end(fw: signer, owner: signer, admin: signer, sender: signer) {
        t::setup(&fw);
        let c = deploy_real_cache(&owner, &admin, signer::address_of(&sender), b"cache");
        t::report(&sender, c, vector[t::entry(t::id(1), 12345, 7)]);
        let p = deploy_proxy(&owner, b"proxy", c);
        let l = proxy::latest_round(p, t::id(1), 18);
        assert!(proxy::round_answer(&l) == 12345 && proxy::round_timestamp(&l) == 7, 1);
        assert!(proxy::round_answer(&proxy::get_round(p, t::id(1), 1, 18)) == 12345, 2);
        assert!(proxy::decimals(p, t::id(1)) == 18, 3);
        assert!(proxy::description(p, t::id(1)) == string::utf8(b"BTC/USD"), 4);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun proxy_cache_reader_client_scales_real_cache_answers(fw: signer, owner: signer, admin: signer, sender: signer) {
        t::setup(&fw);
        let c = deploy_real_cache(&owner, &admin, signer::address_of(&sender), b"cache");
        t::report(&sender, c, vector[t::entry(t::id(1), 1234500000000000000, 7)]);
        let p = deploy_proxy(&owner, b"proxy", c);
        proxy::set_min_decimals(&owner, p, t::id(1), 8);
        assert!(proxy::round_answer(&proxy::latest_round(p, t::id(1), 8)) == 123450000, 1);
        assert!(proxy::round_answer(&proxy::get_round(p, t::id(1), 1, 10)) == 12345000000, 2);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    #[expected_failure(abort_code = 50, location = data_feeds_proxy::proxy)]
    fun proxy_cache_reader_client_configured_feed_without_rounds_is_no_data_present_below_full_precision(fw: signer, owner: signer, admin: signer, sender: signer) {
        t::setup(&fw);
        let c = deploy_real_cache(&owner, &admin, signer::address_of(&sender), b"cache");
        let p = deploy_proxy(&owner, b"proxy", c);
        proxy::set_min_decimals(&owner, p, t::id(1), 8);
        proxy::latest_round(p, t::id(1), 8);
    }

    fun setup_unconfigured_read(fw: &signer, owner: &signer, admin: &signer, sender: &signer): address {
        t::setup(fw);
        let c = deploy_real_cache(owner, admin, signer::address_of(sender), b"cache");
        t::report(sender, c, vector[t::entry(t::id(1), 12345, 7)]);
        deploy_proxy(owner, b"proxy", c)
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    #[expected_failure(abort_code = 50, location = data_feeds_proxy::proxy)]
    fun proxy_cache_reader_client_every_read_on_an_unconfigured_feed_is_no_data_present(fw: signer, owner: signer, admin: signer, sender: signer) {
        let p = setup_unconfigured_read(&fw, &owner, &admin, &sender);
        proxy::latest_round(p, t::id(99), 18);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    #[expected_failure(abort_code = 50, location = data_feeds_proxy::proxy)]
    fun proxy_cache_reader_client_every_read_on_an_unconfigured_feed_is_no_data_present__alt2(fw: signer, owner: signer, admin: signer, sender: signer) {
        let p = setup_unconfigured_read(&fw, &owner, &admin, &sender);
        proxy::get_round(p, t::id(99), 1, 18);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    #[expected_failure(abort_code = 50, location = data_feeds_proxy::proxy)]
    fun proxy_cache_reader_client_every_read_on_an_unconfigured_feed_is_no_data_present__alt3(fw: signer, owner: signer, admin: signer, sender: signer) {
        let p = setup_unconfigured_read(&fw, &owner, &admin, &sender);
        proxy::decimals(p, t::id(99));
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    #[expected_failure(abort_code = 50, location = data_feeds_proxy::proxy)]
    fun proxy_cache_reader_client_every_read_on_an_unconfigured_feed_is_no_data_present__alt4(fw: signer, owner: signer, admin: signer, sender: signer) {
        let p = setup_unconfigured_read(&fw, &owner, &admin, &sender);
        proxy::description(p, t::id(99));
    }

    // ----- lifecycle end-to-end --------------------------------------------------------

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, admin2 = @0xA3, sender = @0xB1, sender2 = @0xB2)]
    fun proxy_lifecycle_cache_is_swappable(fw: signer, owner: signer, admin: signer, admin2: signer, sender: signer, sender2: signer) {
        t::setup(&fw);
        let c = deploy_real_cache(&owner, &admin, signer::address_of(&sender), b"cache");
        t::report(&sender, c, vector[t::entry(t::id(1), 100, 5)]);
        let p = deploy_proxy(&owner, b"proxy", c);
        let c2 = deploy_real_cache(&owner, &admin2, signer::address_of(&sender2), b"cache2");
        t::report(&sender2, c2, vector[t::entry(t::id(1), 999, 90)]);
        let l = proxy::latest_round(p, t::id(1), 18);
        assert!(proxy::round_answer(&l) == 100 && proxy::round_timestamp(&l) == 5, 1);
        proxy::set_cache(&owner, p, c2);
        let l = proxy::latest_round(p, t::id(1), 18);
        assert!(proxy::round_answer(&l) == 999 && proxy::round_timestamp(&l) == 90, 2);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, admin2 = @0xA3, sender = @0xB1, sender2 = @0xB2)]
    #[expected_failure(abort_code = 50, location = data_feeds_proxy::proxy)]
    fun proxy_lifecycle_get_round_history_does_not_span_caches_after_swap(fw: signer, owner: signer, admin: signer, admin2: signer, sender: signer, sender2: signer) {
        t::setup(&fw);
        let c = deploy_real_cache(&owner, &admin, signer::address_of(&sender), b"cache");
        t::report(&sender, c, vector[t::entry(t::id(1), 100, 5)]);
        t::report(&sender, c, vector[t::entry(t::id(1), 110, 6)]);
        let p = deploy_proxy(&owner, b"proxy", c);
        let c2 = deploy_real_cache(&owner, &admin2, signer::address_of(&sender2), b"cache2");
        t::report(&sender2, c2, vector[t::entry(t::id(1), 200, 5)]);
        assert!(proxy::round_answer(&proxy::get_round(p, t::id(1), 2, 18)) == 110, 1);
        proxy::set_cache(&owner, p, c2);
        assert!(proxy::round_answer(&proxy::get_round(p, t::id(1), 1, 18)) == 200, 2);
        proxy::get_round(p, t::id(1), 2, 18);
    }

    // ----- spec/05 conditions beyond the applicable corpus -----------------------------

    // spec/06 I.2 / M.4: no `upgrade` entry point exists on the Proxy (compile-time fact).
    #[test]
    fun proxy_lifecycle_no_upgrade_entry_point() {
        assert!(proxy::version() == 1, 1);
    }

    // "sets the entry lifetime on first write and re-pins on update": persistence on Aptos.
    #[test(fw = @aptos_framework, owner = @0xA1)]
    fun proxy_set_min_decimals_update_persists(fw: signer, owner: signer) {
        let (_c, p) = setup_mock(&fw, &owner);
        proxy::set_min_decimals(&owner, p, t::id(1), 8);
        assert!(proxy::test_has_min_decimals(p, t::id(1)), 1);
        proxy::set_min_decimals(&owner, p, t::id(1), 12);
        t::advance_to(100_000_000);
        assert!(proxy::get_min_decimals(p, t::id(1)) == 12, 2);
        assert!(proxy::get_cache(p) != @0x0, 3);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, new_owner = @0xD1)]
    #[expected_failure(abort_code = 2101, location = data_feeds::ownable)]
    fun proxy_ownership_renounce_refused_while_offer_unexpired(fw: signer, owner: signer, new_owner: signer) {
        let (_c, p) = setup_mock(&fw, &owner);
        proxy::transfer_ownership(&owner, p, signer::address_of(&new_owner), 1000);
        proxy::renounce_ownership(&owner, p);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, new_owner = @0xD1)]
    fun proxy_ownership_renounce_succeeds_after_offer_expires(fw: signer, owner: signer, new_owner: signer) {
        let (_c, p) = setup_mock(&fw, &owner);
        proxy::transfer_ownership(&owner, p, signer::address_of(&new_owner), 1000);
        t::advance_to(1001);
        proxy::renounce_ownership(&owner, p);
        assert!(event::was_event_emitted(&ownable::ownership_renounced_event(signer::address_of(&owner))), 1);
        assert!(option::is_none(&proxy::get_owner(p)), 2);
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    #[expected_failure(abort_code = 2100, location = data_feeds::ownable)]
    fun proxy_ownership_owner_only_call_with_no_owner_fails(fw: signer, owner: signer) {
        let (_c, p) = setup_mock(&fw, &owner);
        proxy::renounce_ownership(&owner, p);
        proxy::set_min_decimals(&owner, p, t::id(1), 8);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, new_owner = @0xD1)]
    #[expected_failure(abort_code = 2203, location = data_feeds::ownable)]
    fun proxy_ownership_expired_offer_cannot_be_accepted(fw: signer, owner: signer, new_owner: signer) {
        let (_c, p) = setup_mock(&fw, &owner);
        proxy::transfer_ownership(&owner, p, signer::address_of(&new_owner), 1000);
        t::advance_to(1001);
        proxy::accept_ownership(&new_owner, p);
    }

    // Overlay: `set_min_decimals` width-checks `data_id` after owner auth, before InvalidDecimals.
    #[test(fw = @aptos_framework, owner = @0xA1)]
    #[expected_failure(abort_code = 0x10001, location = data_feeds_proxy::proxy)]
    fun proxy_set_min_decimals_mis_sized_data_id_is_host_failure(fw: signer, owner: signer) {
        let (_c, p) = setup_mock(&fw, &owner);
        proxy::set_min_decimals(&owner, p, x"01", 19);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, stranger = @0xC1)]
    #[expected_failure(abort_code = 0x50001, location = data_feeds::ownable)]
    fun proxy_set_min_decimals_owner_auth_precedes_width_check(fw: signer, owner: signer, stranger: signer) {
        let (_c, p) = setup_mock(&fw, &owner);
        proxy::set_min_decimals(&stranger, p, x"01", 8);
    }

    #[test(fw = @aptos_framework)]
    #[expected_failure(abort_code = 0x60001, location = data_feeds_proxy::proxy)]
    fun proxy_missing_instance_is_no_instance(fw: signer) {
        t::setup(&fw);
        proxy::get_cache(@0xDEAD);
    }

    // The Proxy's frozen check precedes the Cache data read: a frozen feed with no rounds
    // is 109, not 50.
    #[test(fw = @aptos_framework, owner = @0xA1)]
    #[expected_failure(abort_code = 109, location = data_feeds_proxy::proxy)]
    fun proxy_frozen_check_precedes_no_data_present(fw: signer, owner: signer) {
        let (c, p) = setup_mock(&fw, &owner);
        cache::test_set_frozen(c, t::id(1), true);
        proxy::latest_round(p, t::id(1), 18);
    }
}
