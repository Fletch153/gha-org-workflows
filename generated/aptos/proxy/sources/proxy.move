/// DataFeedsProxy (spec/03) — the consumer-facing reader. Holds one Cache instance address,
/// delegates every read to `data_feeds::cache`, adds precision scaling and a per-feed
/// minimum precision, and refuses to serve frozen feeds.
module data_feeds_proxy::proxy {
    use std::option::{Self, Option};
    use std::signer;
    use std::string::{Self, String};
    use std::vector;
    use aptos_std::table::{Self, Table};
    use aptos_framework::event;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::{Self, ExtendRef};
    use aptos_framework::primary_fungible_store;
    use data_feeds::cache;
    use data_feeds::host_error;
    use data_feeds::ledger;
    use data_feeds::ownable::{Self, OwnershipState};

    /// Precision of every Cache answer.
    const DECIMALS: u32 = 18;

    // ProxyReadError (spec/03), exact codes.
    const NoDataPresent: u64 = 50;
    const InvalidDecimals: u64 = 51;
    const RoundsToZero: u64 = 52;
    /// The Cache's code, raised by the Proxy when reading a frozen feed.
    const FeedFrozen: u64 = 109;

    /// Returned record.
    struct Round has copy, drop, store {
        round_id: u64,
        answer: u256,
        timestamp: u64,
    }

    /// The instance resource (storage layout, overlay axis B).
    struct Proxy has key {
        extend_ref: ExtendRef,
        ownership: OwnershipState,
        cache: address,
        min_decimals: Table<vector<u8>, u32>,
    }

    #[event]
    struct CacheSet has copy, drop, store {
        old_cache: address,
        new_cache: address,
    }

    #[event]
    struct MinDecimalsSet has copy, drop, store {
        data_id: vector<u8>,
        min: u32,
    }

    #[event]
    struct TokenRecovered has copy, drop, store {
        token: address,
        to: address,
        amount: u64,
    }

    // ----- constructor -----------------------------------------------------------------

    public entry fun create(creator: &signer, seed: vector<u8>, owner: address, cache: address) {
        let constructor_ref = object::create_named_object(creator, seed);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let instance_signer = object::generate_signer(&constructor_ref);
        move_to(&instance_signer, Proxy {
            extend_ref,
            ownership: ownable::new(owner),
            cache,
            min_decimals: table::new(),
        });
    }

    // ----- shared lifecycle ------------------------------------------------------------

    #[view]
    public fun version(): u32 { 1 }

    #[view]
    public fun type_and_version(): String { string::utf8(b"DataFeedsProxy 1.0.0") }

    #[view]
    public fun get_owner(proxy: address): Option<address> acquires Proxy {
        assert_instance(proxy);
        ownable::get_owner(&borrow_global<Proxy>(proxy).ownership)
    }

    public entry fun transfer_ownership(owner: &signer, proxy: address, new_owner: address, live_until_ledger: u32) acquires Proxy {
        assert_instance(proxy);
        let p = borrow_global_mut<Proxy>(proxy);
        ownable::transfer_ownership(&mut p.ownership, signer::address_of(owner), new_owner, live_until_ledger, ledger::sequence());
    }

    public entry fun accept_ownership(new_owner: &signer, proxy: address) acquires Proxy {
        assert_instance(proxy);
        let p = borrow_global_mut<Proxy>(proxy);
        ownable::accept_ownership(&mut p.ownership, signer::address_of(new_owner), ledger::sequence());
    }

    public entry fun renounce_ownership(owner: &signer, proxy: address) acquires Proxy {
        assert_instance(proxy);
        let p = borrow_global_mut<Proxy>(proxy);
        ownable::renounce_ownership(&mut p.ownership, signer::address_of(owner), ledger::sequence());
    }

    public entry fun recover_tokens(owner: &signer, proxy: address, token: address, to: address, amount: u64) acquires Proxy {
        assert_instance(proxy);
        let p = borrow_global<Proxy>(proxy);
        ownable::assert_owner(&p.ownership, signer::address_of(owner));
        let instance_signer = object::generate_signer_for_extending(&p.extend_ref);
        primary_fungible_store::transfer(&instance_signer, object::address_to_object<Metadata>(token), to, amount);
        event::emit(TokenRecovered { token, to, amount });
    }

    // ----- reader ----------------------------------------------------------------------

    #[view]
    public fun latest_round(proxy: address, data_id: vector<u8>, decimals: u32): Round acquires Proxy {
        assert_instance(proxy);
        let p = borrow_global<Proxy>(proxy);
        // prologue (instance / MinDecimals lifetime refreshes): no-op on Aptos
        validate_decimals(p, &data_id, decimals);
        assert_not_frozen(p.cache, &data_id);
        let answer = cache::latest_round(p.cache, vector[data_id]);
        let round = vector::pop_back(&mut answer);
        assert!(option::is_some(&round), NoDataPresent);
        project(&option::destroy_some(round), decimals)
    }

    #[view]
    public fun get_round(proxy: address, data_id: vector<u8>, round_id: u64, decimals: u32): Round acquires Proxy {
        assert_instance(proxy);
        let p = borrow_global<Proxy>(proxy);
        validate_decimals(p, &data_id, decimals);
        assert_not_frozen(p.cache, &data_id);
        let round = cache::get_round(p.cache, data_id, round_id);
        assert!(option::is_some(&round), NoDataPresent);
        project(&option::destroy_some(round), decimals)
    }

    #[view]
    public fun decimals(proxy: address, data_id: vector<u8>): u32 acquires Proxy {
        assert_instance(proxy);
        let p = borrow_global<Proxy>(proxy);
        assert_not_frozen(p.cache, &data_id);
        let answer = cache::decimals(p.cache, vector[data_id]);
        let d = vector::pop_back(&mut answer);
        assert!(option::is_some(&d), NoDataPresent);
        option::destroy_some(d)
    }

    #[view]
    public fun description(proxy: address, data_id: vector<u8>): String acquires Proxy {
        assert_instance(proxy);
        let p = borrow_global<Proxy>(proxy);
        assert_not_frozen(p.cache, &data_id);
        let answer = cache::description(p.cache, vector[data_id]);
        let d = vector::pop_back(&mut answer);
        assert!(option::is_some(&d), NoDataPresent);
        option::destroy_some(d)
    }

    #[view]
    public fun get_min_decimals(proxy: address, data_id: vector<u8>): u32 acquires Proxy {
        assert_instance(proxy);
        effective_min(borrow_global<Proxy>(proxy), &data_id)
    }

    #[view]
    public fun get_cache(proxy: address): address acquires Proxy {
        assert_instance(proxy);
        borrow_global<Proxy>(proxy).cache
    }

    // ----- admin -----------------------------------------------------------------------

    public entry fun set_cache(owner: &signer, proxy: address, cache: address) acquires Proxy {
        assert_instance(proxy);
        let p = borrow_global_mut<Proxy>(proxy);
        ownable::assert_owner(&p.ownership, signer::address_of(owner));
        let old_cache = p.cache;
        p.cache = cache;
        event::emit(CacheSet { old_cache, new_cache: cache });
    }

    public entry fun set_min_decimals(owner: &signer, proxy: address, data_id: vector<u8>, min: u32) acquires Proxy {
        assert_instance(proxy);
        let p = borrow_global_mut<Proxy>(proxy);
        ownable::assert_owner(&p.ownership, signer::address_of(owner));
        assert!(vector::length(&data_id) == 32, host_error::invalid_argument());
        assert!(min <= DECIMALS, InvalidDecimals);
        table::upsert(&mut p.min_decimals, data_id, min);
        event::emit(MinDecimalsSet { data_id, min });
    }

    // ----- precision -------------------------------------------------------------------

    fun effective_min(p: &Proxy, data_id: &vector<u8>): u32 {
        if (table::contains(&p.min_decimals, *data_id)) {
            *table::borrow(&p.min_decimals, *data_id)
        } else {
            DECIMALS
        }
    }

    fun validate_decimals(p: &Proxy, data_id: &vector<u8>, decimals: u32) {
        assert!(decimals >= effective_min(p, data_id) && decimals <= DECIMALS, InvalidDecimals);
    }

    fun assert_not_frozen(cache_addr: address, data_id: &vector<u8>) {
        let flags = cache::is_frozen(cache_addr, vector[*data_id]);
        assert!(!vector::pop_back(&mut flags), FeedFrozen);
    }

    /// Scales the answer to `decimals` (truncating toward zero) and projects the record.
    fun project(r: &cache::RoundData, decimals: u32): Round {
        Round {
            round_id: cache::round_data_round_id(r),
            answer: scale(cache::round_data_answer(r), decimals),
            timestamp: cache::round_data_timestamp(r),
        }
    }

    /// Integer-divides the two's-complement answer by `10^(DECIMALS - decimals)`, truncating
    /// toward zero; a non-zero answer that scales to zero is `RoundsToZero`.
    fun scale(answer: u256, decimals: u32): u256 {
        let divisor = pow10(DECIMALS - decimals);
        if (divisor == 1) return answer;
        if (answer == 0) return 0;
        let negative = is_negative(answer);
        let magnitude = if (negative) negate(answer) else answer;
        let scaled = magnitude / divisor;
        assert!(scaled != 0, RoundsToZero);
        if (negative) negate(scaled) else scaled
    }

    fun pow10(n: u32): u256 {
        let v: u256 = 1;
        let i = 0;
        while (i < n) {
            v = v * 10;
            i = i + 1;
        };
        v
    }

    fun is_negative(x: u256): bool {
        (x >> 255) == 1
    }

    /// Two's-complement negation of a non-zero value.
    fun negate(x: u256): u256 {
        (0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF - x) + 1
    }

    fun assert_instance(proxy: address) {
        assert!(exists<Proxy>(proxy), host_error::no_instance());
    }

    // ----- accessors (spec/06 M.2) -----------------------------------------------------

    public fun round_round_id(r: &Round): u64 { r.round_id }
    public fun round_answer(r: &Round): u256 { r.answer }
    public fun round_timestamp(r: &Round): u64 { r.timestamp }

    // ----- test support ----------------------------------------------------------------

    #[test_only]
    public fun test_has_min_decimals(proxy: address, data_id: vector<u8>): bool acquires Proxy {
        table::contains(&borrow_global<Proxy>(proxy).min_decimals, data_id)
    }

    #[test_only]
    /// The Proxy codes in spec order: [NoDataPresent, InvalidDecimals, RoundsToZero].
    public fun test_error_codes(): vector<u64> {
        vector[NoDataPresent, InvalidDecimals, RoundsToZero]
    }

    #[test_only]
    /// Accumulated per-type event counts, in this order:
    /// [CacheSet, MinDecimalsSet, OwnershipTransfer, OwnershipTransferCompleted,
    ///  OwnershipRenounced, TokenRecovered].
    public fun test_event_counts(): vector<u64> {
        vector[
            vector::length(&event::emitted_events<CacheSet>()),
            vector::length(&event::emitted_events<MinDecimalsSet>()),
            vector::length(&event::emitted_events<ownable::OwnershipTransfer>()),
            vector::length(&event::emitted_events<ownable::OwnershipTransferCompleted>()),
            vector::length(&event::emitted_events<ownable::OwnershipRenounced>()),
            vector::length(&event::emitted_events<TokenRecovered>()),
        ]
    }

    #[test_only]
    public fun cache_set_event(old_cache: address, new_cache: address): CacheSet {
        CacheSet { old_cache, new_cache }
    }

    #[test_only]
    public fun min_decimals_set_event(data_id: vector<u8>, min: u32): MinDecimalsSet {
        MinDecimalsSet { data_id, min }
    }

    #[test_only]
    public fun token_recovered_event(token: address, to: address, amount: u64): TokenRecovered {
        TokenRecovered { token, to, amount }
    }
}
