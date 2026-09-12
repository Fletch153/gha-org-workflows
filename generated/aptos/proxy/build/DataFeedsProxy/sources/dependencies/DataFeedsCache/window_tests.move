#[test_only]
// spec/05 "retention window" conditions that vary the TTL: on Aptos the network maximum
// cannot vary (spec/06 C.3), so they are exercised directly against `data_feeds::window`.
// Also covers the byte-width host checks and the `Bound` discriminant check of the overlay.
module data_feeds::window_tests {
    use std::signer;
    use std::vector;
    use data_feeds::cache;
    use data_feeds::window;
    use data_feeds::test_utils as t;

    #[test]
    fun window_initial_has_no_grow_date() {
        let w = window::initial(50);
        assert!(window::shortest_ttl(&w) == 50 && window::grow_to_ttl(&w) == 50 && window::grow_at_ledger(&w) == 0, 1);
        assert!(window::width_at(&w, 0) == 50, 2);
        assert!(window::width_at(&w, 1_000_000) == 50, 3);
    }

    #[test]
    fun window_shrinks_immediately_when_the_ttl_drops() {
        // rounds at 1000 (ttl 10000) and 1010; ttl drops to 50 at the append at 1030
        let w = window::initial(10000);
        let w = window::next(&w, 1000, 10000, 1010);
        let w = window::next(&w, 1010, 50, 1030);
        assert!(window::shortest_ttl(&w) == 50, 1);
        assert!(window::grow_to_ttl(&w) == 50, 2);
        assert!(window::grow_at_ledger(&w) == 1061, 3);
        assert!(window::width_at(&w, 1055) == 50, 4);
        assert!(!window::is_readable(&w, 1000, 1055), 5);
        assert!(window::is_readable(&w, 1010, 1055), 6);
        assert!(window::is_readable(&w, 1030, 1055), 7);
    }

    #[test]
    fun window_grows_only_at_grow_at_ledger() {
        // round at 1000 (ttl 50); ttl rises to 10000 at 1100; another append at 1200
        let w = window::initial(50);
        let w = window::next(&w, 1000, 10000, 1100);
        assert!(window::shortest_ttl(&w) == 50 && window::grow_to_ttl(&w) == 10000, 1);
        assert!(window::grow_at_ledger(&w) == 11001, 2);
        let w = window::next(&w, 1100, 10000, 1200);
        assert!(window::grow_at_ledger(&w) == 11001, 3);
        assert!(window::shortest_ttl(&w) == 50, 4);
        // before the grow date the width is still 50
        assert!(window::width_at(&w, 11000) == 50, 5);
        assert!(!window::is_readable(&w, 1000, 11000), 6);
        assert!(!window::is_readable(&w, 1100, 11000), 7);
        // switches exactly at grow_at_ledger
        assert!(window::width_at(&w, 11001) == 10000, 8);
        assert!(window::is_readable(&w, 1100, 11001), 9);
        assert!(window::is_readable(&w, 1200, 11001), 10);
    }

    #[test]
    fun window_second_change_before_grow_date_replaces_the_pending_plan() {
        let w = window::initial(50);
        let w = window::next(&w, 1000, 10000, 1100);
        assert!(window::grow_at_ledger(&w) == 11001, 1);
        let w = window::next(&w, 1100, 2000, 1200);
        assert!(window::grow_at_ledger(&w) == 1100 + 2000 + 1, 2);
        assert!(window::grow_to_ttl(&w) == 2000, 3);
        assert!(window::shortest_ttl(&w) == 50, 4);
    }

    #[test]
    fun window_same_ledger_writes_share_the_window() {
        let w = window::initial(100);
        let w2 = window::next(&w, 1000, 100, 1000);
        assert!(w == w2, 1);
        assert!(window::is_readable(&w2, 1000, 1000), 2);
    }

    #[test]
    fun window_raised_ttl_reaches_only_new_rounds() {
        let w = window::initial(50);
        let w = window::next(&w, 1000, 10000, 1100);
        // at the grow date the old round (1000) is out, the new one (1100) is in
        assert!(!window::is_readable(&w, 1000, 11001), 1);
        assert!(window::is_readable(&w, 1100, 11001), 2);
    }

    #[test]
    fun window_lowered_ttl_reaches_new_rounds_immediately() {
        let w = window::initial(10000);
        let w = window::next(&w, 1000, 50, 1030);
        assert!(window::width_at(&w, 1030) == 50, 1);
        assert!(!window::is_readable(&w, 1030, 1081), 2);
        assert!(window::is_readable(&w, 1030, 1080), 3);
    }

    #[test]
    fun window_write_after_grow_date_locks_in_the_grown_width() {
        let w = window::initial(50);
        let w = window::next(&w, 1000, 10000, 1100);
        let w = window::next(&w, 1100, 10000, 12000);
        assert!(window::shortest_ttl(&w) == 10000, 1);
        assert!(window::grow_to_ttl(&w) == 10000, 2);
        assert!(window::grow_at_ledger(&w) == 11001, 3);
        assert!(window::width_at(&w, 12000) == 10000, 4);
    }

    #[test]
    fun window_cutoff_saturates_at_zero() {
        let w = window::initial(1000);
        assert!(window::is_readable(&w, 0, 500), 1);
        assert!(window::is_readable(&w, 0, 1000), 2);
        assert!(!window::is_readable(&w, 0, 1001), 3);
    }

    #[test]
    fun window_grow_at_ledger_saturates() {
        let w = window::initial(10);
        let w = window::next(&w, 0xFFFF_FFF0, 0xFFFF_FFFF, 0xFFFF_FFF1);
        assert!(window::grow_at_ledger(&w) == 0xFFFF_FFFF, 1);
    }

    // ----- retention constant and per-round ttl ----------------------------------------

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    fun cache_retention_new_round_window_uses_data_retention_ttl(fw: signer, owner: signer, admin: signer, sender: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
        t::configure(&admin, c, t::id(1), b"BTC/USD", signer::address_of(&sender));
        assert!(cache::test_data_retention_ttl() == 15_552_000, 1);
        t::seed(&sender, c, t::id(1), 2);
        let w = cache::test_window(c, t::id(1));
        assert!(window::shortest_ttl(&w) == 15_552_000, 2);
        assert!(window::grow_to_ttl(&w) == 15_552_000, 3);
        assert!(window::grow_at_ledger(&w) == 0, 4);
    }

    // ----- permission hash -------------------------------------------------------------

    #[test]
    fun permission_hash_is_keccak_of_bcs_encodings() {
        let sender = @0xB1;
        let h = cache::test_permission_hash(sender, t::owner_bytes(0x11), t::name_bytes(0x22));
        let buf = std::bcs::to_bytes(&sender);
        vector::append(&mut buf, std::bcs::to_bytes(&t::owner_bytes(0x11)));
        vector::append(&mut buf, std::bcs::to_bytes(&t::name_bytes(0x22)));
        assert!(h == aptos_std::aptos_hash::keccak256(buf), 1);
        assert!(vector::length(&h) == 32, 2);
        // encode(owner) = ULEB128 length (20) || bytes, encode(name) = 10 || bytes
        assert!(vector::length(&buf) == 32 + 21 + 11, 3);
    }

    // ----- host-level byte-width and discriminant checks (overlay) ---------------------

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    #[expected_failure(abort_code = 0x10001, location = data_feeds::cache)]
    fun cache_set_feed_configs_mis_sized_data_id_is_host_failure(fw: signer, owner: signer, admin: signer, sender: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
        t::configure(&admin, c, x"01", b"X", signer::address_of(&sender));
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    #[expected_failure(abort_code = 0x10001, location = data_feeds::cache)]
    fun cache_set_feed_configs_mis_sized_owner_is_host_failure(fw: signer, owner: signer, admin: signer, sender: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
        cache::set_feed_configs(&admin, c, vector[t::config_entry(t::id(1), b"X",
            vector[t::perm(signer::address_of(&sender), t::repeat(0x11, 19), t::name_bytes(0x22))])]);
    }

    // Within one entry every width check precedes every spec check: a zero name in
    // permission 0 does not pre-empt a mis-sized owner in permission 1.
    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    #[expected_failure(abort_code = 0x10001, location = data_feeds::cache)]
    fun cache_set_feed_configs_width_checks_precede_spec_checks_within_an_entry(fw: signer, owner: signer, admin: signer, sender: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
        let s = signer::address_of(&sender);
        cache::set_feed_configs(&admin, c, vector[t::config_entry(t::id(1), b"X",
            vector[t::perm(s, t::owner_bytes(0x11), t::zero10()), t::perm(s, t::repeat(0x11, 21), t::name_bytes(0x22))])]);
    }

    // Entries are validated in order: a spec error in entry 1 precedes a width error in entry 2.
    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    #[expected_failure(abort_code = 105, location = data_feeds::cache)]
    fun cache_set_feed_configs_spec_error_in_earlier_entry_precedes_width_error_in_later(fw: signer, owner: signer, admin: signer, sender: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
        let s = signer::address_of(&sender);
        cache::set_feed_configs(&admin, c, vector[
            t::config_entry(t::id(1), b"X", vector[t::perm(s, t::owner_bytes(0x11), t::zero10())]),
            t::config_entry(x"01", b"Y", vector[t::default_perm(s)]),
        ]);
    }

    // The width checks come after the admin check (101) and the empty-batch check (103).
    #[test(fw = @aptos_framework, owner = @0xA1, sender = @0xB1, stranger = @0xC1)]
    #[expected_failure(abort_code = 101, location = data_feeds::cache)]
    fun cache_set_feed_configs_unauthorized_precedes_width_check(fw: signer, owner: signer, sender: signer, stranger: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        t::configure(&stranger, c, x"01", b"X", signer::address_of(&sender));
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2, sender = @0xB1)]
    #[expected_failure(abort_code = 0x10001, location = data_feeds::cache)]
    fun cache_find_round_unknown_bound_is_host_failure(fw: signer, owner: signer, admin: signer, sender: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
        t::configure(&admin, c, t::id(1), b"BTC/USD", signer::address_of(&sender));
        // aborts even without feed state
        cache::find_round(c, t::id(1), 10, 2);
    }

    // Lookup-only arguments are not width-checked: a mis-sized id is simply an unknown feed.
    #[test(fw = @aptos_framework, owner = @0xA1)]
    fun cache_lookup_arguments_are_not_width_checked(fw: signer, owner: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        assert!(cache::is_configured(c, vector[x"01"]) == vector[false], 1);
        assert!(vector::is_empty(&cache::get_feed_permissions(c, x"01")), 2);
        assert!(!cache::has_permission(c, x"01", @0xB1, x"11", x"22"), 3);
        assert!(std::option::is_none(&cache::get_round(c, x"01", 1)), 4);
    }
}
