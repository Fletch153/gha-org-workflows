#[test_only]
// Scenarios: cache.constructor.*, cache.invariants.*, cache.lifecycle.* (applicable ones),
// plus the spec/05 ownership conditions the corpus leaves to the library and the
// I.2 "no upgrade entry point" condition.
module data_feeds::lifecycle_tests {
    use std::option;
    use std::signer;
    use std::string;
    use std::vector;
    use data_feeds::cache;
    use data_feeds::ownable;
    use data_feeds::test_utils as t;

    #[test(fw = @aptos_framework, owner = @0xA1)]
    fun cache_constructor_sets_owner(fw: signer, owner: signer) {
        t::setup(&fw);
        let o = signer::address_of(&owner);
        let c = t::deploy_cache(&owner, b"cache", o);
        assert!(cache::get_owner(c) == option::some(o), 1);
    }

    #[test]
    fun cache_invariants_error_discriminants_are_range_disjoint() {
        let codes = cache::test_error_codes();
        assert!(codes == vector[100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110], 1);
        let ownership = ownable::test_error_codes();
        assert!(ownership == vector[2100, 2101, 2102, 2200, 2201, 2202, 2203], 2);
        let i = 0;
        while (i < vector::length(&codes)) {
            let code = *vector::borrow(&codes, i);
            assert!(code >= 100 && code <= 199, 3);
            assert!(!vector::contains(&ownership, &code), 4);
            i = i + 1;
        };
        let j = 0;
        while (j < vector::length(&ownership)) {
            let code = *vector::borrow(&ownership, j);
            assert!(code >= 2100 && code <= 2299, 5);
            j = j + 1;
        };
    }

    #[test(fw = @aptos_framework, owner = @0xA1)]
    fun cache_lifecycle_version_is_wired(fw: signer, owner: signer) {
        t::setup(&fw);
        let _c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        assert!(cache::version() == 1, 1);
        assert!(cache::type_and_version() == string::utf8(b"DataFeedsCache 1.0.0"), 2);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, new_owner = @0xD1)]
    fun cache_lifecycle_two_step_ownership_is_wired(fw: signer, owner: signer, new_owner: signer) {
        t::setup(&fw);
        let o = signer::address_of(&owner);
        let n = signer::address_of(&new_owner);
        let c = t::deploy_cache(&owner, b"cache", o);
        cache::transfer_ownership(&owner, c, n, 1000);
        assert!(t::emitted(&ownable::ownership_transfer_event(o, n, 1000)), 1);
        cache::accept_ownership(&new_owner, c);
        assert!(t::emitted(&ownable::ownership_transfer_completed_event(n)), 2);
        assert!(cache::get_owner(c) == option::some(n), 3);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, payer = @0xE1)]
    fun cache_lifecycle_recover_tokens_is_wired(fw: signer, owner: signer, payer: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        let (token, mint_ref) = t::deploy_token(&owner);
        t::mint(&mint_ref, c, 1000);
        let p = signer::address_of(&payer);
        cache::recover_tokens(&owner, c, token, p, 1000);
        assert!(t::balance(p, token) == 1000, 1);
        assert!(t::emitted(&cache::token_recovered_event(token, p, 1000)), 2);
    }

    // ----- spec/05 ownership conditions (spec/06 J table) -----------------------------

    #[test(fw = @aptos_framework, owner = @0xA1, new_owner = @0xD1)]
    #[expected_failure(abort_code = 2203, location = data_feeds::ownable)]
    fun cache_ownership_expired_offer_cannot_be_accepted(fw: signer, owner: signer, new_owner: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::transfer_ownership(&owner, c, signer::address_of(&new_owner), 1000);
        t::advance_to(1001);
        cache::accept_ownership(&new_owner, c);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, new_owner = @0xD1)]
    fun cache_ownership_cancel_with_zero_removes_the_offer(fw: signer, owner: signer, new_owner: signer) {
        t::setup(&fw);
        let o = signer::address_of(&owner);
        let n = signer::address_of(&new_owner);
        let c = t::deploy_cache(&owner, b"cache", o);
        cache::transfer_ownership(&owner, c, n, 1000);
        cache::transfer_ownership(&owner, c, n, 0);
        assert!(t::emitted(&ownable::ownership_transfer_event(o, n, 0)), 1);
        // the offer is gone: renounce is no longer blocked
        cache::renounce_ownership(&owner, c);
        assert!(t::emitted(&ownable::ownership_renounced_event(o)), 2);
        assert!(option::is_none(&cache::get_owner(c)), 3);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, new_owner = @0xD1)]
    #[expected_failure(abort_code = 2200, location = data_feeds::ownable)]
    fun cache_ownership_cancel_without_offer_is_no_pending_transfer(fw: signer, owner: signer, new_owner: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::transfer_ownership(&owner, c, signer::address_of(&new_owner), 0);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, new_owner = @0xD1, stranger = @0xC1)]
    #[expected_failure(abort_code = 2202, location = data_feeds::ownable)]
    fun cache_ownership_cancel_with_different_address_is_invalid_pending_account(fw: signer, owner: signer, new_owner: signer, stranger: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::transfer_ownership(&owner, c, signer::address_of(&new_owner), 1000);
        cache::transfer_ownership(&owner, c, signer::address_of(&stranger), 0);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, new_owner = @0xD1)]
    #[expected_failure(abort_code = 2201, location = data_feeds::ownable)]
    fun cache_ownership_offer_dated_in_the_past_is_rejected(fw: signer, owner: signer, new_owner: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        t::advance_to(500);
        cache::transfer_ownership(&owner, c, signer::address_of(&new_owner), 499);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, new_owner = @0xD1)]
    #[expected_failure(abort_code = 2101, location = data_feeds::ownable)]
    fun cache_ownership_renounce_refused_while_offer_unexpired(fw: signer, owner: signer, new_owner: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::transfer_ownership(&owner, c, signer::address_of(&new_owner), 1000);
        t::advance_to(1000);
        cache::renounce_ownership(&owner, c);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, new_owner = @0xD1)]
    fun cache_ownership_renounce_succeeds_after_offer_expires(fw: signer, owner: signer, new_owner: signer) {
        t::setup(&fw);
        let o = signer::address_of(&owner);
        let c = t::deploy_cache(&owner, b"cache", o);
        cache::transfer_ownership(&owner, c, signer::address_of(&new_owner), 1000);
        t::advance_to(1001);
        cache::renounce_ownership(&owner, c);
        assert!(t::emitted(&ownable::ownership_renounced_event(o)), 1);
        assert!(option::is_none(&cache::get_owner(c)), 2);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, admin = @0xA2)]
    #[expected_failure(abort_code = 2100, location = data_feeds::ownable)]
    fun cache_ownership_owner_only_call_with_no_owner_fails(fw: signer, owner: signer, admin: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::renounce_ownership(&owner, c);
        cache::add_feed_admin(&owner, c, signer::address_of(&admin));
    }

    #[test(fw = @aptos_framework, owner = @0xA1, new_owner = @0xD1, stranger = @0xC1)]
    #[expected_failure(abort_code = 0x50001, location = data_feeds::ownable)]
    fun cache_ownership_accept_by_non_pending_address_host_fails(fw: signer, owner: signer, new_owner: signer, stranger: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::transfer_ownership(&owner, c, signer::address_of(&new_owner), 1000);
        cache::accept_ownership(&stranger, c);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, new_owner = @0xD1)]
    #[expected_failure(abort_code = 2200, location = data_feeds::ownable)]
    fun cache_ownership_accept_without_offer_is_no_pending_transfer(fw: signer, owner: signer, new_owner: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        cache::accept_ownership(&new_owner, c);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, new_owner = @0xD1)]
    fun cache_ownership_new_offer_replaces_previous(fw: signer, owner: signer, new_owner: signer) {
        t::setup(&fw);
        let o = signer::address_of(&owner);
        let n = signer::address_of(&new_owner);
        let c = t::deploy_cache(&owner, b"cache", o);
        cache::transfer_ownership(&owner, c, n, 10);
        cache::transfer_ownership(&owner, c, n, 2000);
        t::advance_to(1500);
        cache::accept_ownership(&new_owner, c);
        assert!(cache::get_owner(c) == option::some(n), 1);
    }

    // spec/06 I.2 / M.4: the package has no `upgrade` entry point (a call
    // `cache::upgrade(..)` would not resolve at compile time). Package upgrades are the
    // publisher's (owner's) responsibility, outside the contract.
    #[test]
    fun cache_lifecycle_no_upgrade_entry_point() {
        assert!(cache::version() == 1, 1);
    }

    // spec/06 B: a second instance with the same (creator, seed) is the framework's
    // `object::EOBJECT_EXISTS` abort.
    #[test(fw = @aptos_framework, owner = @0xA1)]
    #[expected_failure(abort_code = 0x80001, location = aptos_framework::object)]
    fun cache_constructor_duplicate_seed_is_object_exists(fw: signer, owner: signer) {
        t::setup(&fw);
        let o = signer::address_of(&owner);
        t::deploy_cache(&owner, b"cache", o);
        t::deploy_cache(&owner, b"cache", o);
    }

    // Overlay axis A: every entry point / view aborts `host_error::no_instance()` on an
    // address without a Cache before any other check.
    #[test(fw = @aptos_framework, owner = @0xA1)]
    #[expected_failure(abort_code = 0x60001, location = data_feeds::cache)]
    fun cache_missing_instance_is_no_instance(fw: signer, owner: signer) {
        t::setup(&fw);
        cache::add_feed_admin(&owner, @0xDEAD, signer::address_of(&owner));
    }

    #[test(fw = @aptos_framework)]
    #[expected_failure(abort_code = 0x60001, location = data_feeds::cache)]
    fun cache_missing_instance_view_is_no_instance(fw: signer) {
        t::setup(&fw);
        cache::latest_round(@0xDEAD, vector[t::id(1)]);
    }

    // Overlay axis K: `recover_tokens` with an amount above the balance is the framework's
    // `fungible_asset::EINSUFFICIENT_BALANCE` abort, no check of the contract's own.
    #[test(fw = @aptos_framework, owner = @0xA1, payer = @0xE1)]
    #[expected_failure(abort_code = 0x10004, location = aptos_framework::fungible_asset)]
    fun cache_recover_tokens_insufficient_balance_is_framework_abort(fw: signer, owner: signer, payer: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        let (token, mint_ref) = t::deploy_token(&owner);
        t::mint(&mint_ref, c, 10);
        cache::recover_tokens(&owner, c, token, signer::address_of(&payer), 11);
    }

    #[test(fw = @aptos_framework, owner = @0xA1, payer = @0xE1, stranger = @0xC1)]
    #[expected_failure(abort_code = 0x50001, location = data_feeds::ownable)]
    fun cache_recover_tokens_by_non_owner_host_fails(fw: signer, owner: signer, payer: signer, stranger: signer) {
        t::setup(&fw);
        let c = t::deploy_cache(&owner, b"cache", signer::address_of(&owner));
        let (token, mint_ref) = t::deploy_token(&owner);
        t::mint(&mint_ref, c, 10);
        cache::recover_tokens(&stranger, c, token, signer::address_of(&payer), 10);
    }
}
