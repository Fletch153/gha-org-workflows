#[test_only]
/// Shared test harness: actors, byte helpers, report encoding, the `seed` macro, token
/// helpers and event-delta assertions. Lives in the Cache package so the Proxy tests reuse it.
module data_feeds::test_utils {
    use std::bcs;
    use std::option;
    use std::signer;
    use std::string;
    use std::vector;
    use aptos_framework::event;
    use aptos_framework::fungible_asset::{Self, Metadata, MintRef};
    use aptos_framework::object;
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;
    use data_feeds::cache::{Self, ReportEntry, WorkflowPermission, FeedConfigEntry};

    // Event-count indices (see `cache::test_event_counts`).
    const E_FEED_UPDATED: u64 = 0;
    const E_STALE_REPORT: u64 = 1;
    const E_INVALID_UPDATE_PERMISSION: u64 = 2;
    const E_FEED_CONFIG_SET: u64 = 3;
    const E_FEED_CONFIG_REMOVED: u64 = 4;
    const E_FEED_FROZEN_SET: u64 = 5;
    const E_FEED_ADMIN_ADDED: u64 = 6;
    const E_FEED_ADMIN_REMOVED: u64 = 7;

    public fun e_feed_updated(): u64 { E_FEED_UPDATED }
    public fun e_stale_report(): u64 { E_STALE_REPORT }
    public fun e_invalid_update_permission(): u64 { E_INVALID_UPDATE_PERMISSION }
    public fun e_feed_config_set(): u64 { E_FEED_CONFIG_SET }
    public fun e_feed_config_removed(): u64 { E_FEED_CONFIG_REMOVED }
    public fun e_feed_frozen_set(): u64 { E_FEED_FROZEN_SET }
    public fun e_feed_admin_added(): u64 { E_FEED_ADMIN_ADDED }
    public fun e_feed_admin_removed(): u64 { E_FEED_ADMIN_REMOVED }

    // ----- environment -----------------------------------------------------------------

    /// Starts the chain clock (sequence 0).
    public fun setup(fw: &signer) {
        timestamp::set_time_has_started_for_testing(fw);
    }

    /// `advance {to: n}`: set the sequence to absolute `n`; a no-op when already there.
    public fun advance_to(n: u64) {
        if (n > timestamp::now_seconds()) {
            timestamp::update_global_time_for_test_secs(n);
        };
    }

    public fun now(): u64 { timestamp::now_seconds() }

    /// Deploys a Cache instance and returns its address.
    public fun deploy_cache(creator: &signer, seed: vector<u8>, owner: address): address {
        cache::create(creator, seed, owner);
        object::create_object_address(&signer::address_of(creator), seed)
    }

    // ----- byte values (spec/07) -------------------------------------------------------

    /// `"id:n"` = 32 zero bytes with byte 15 = n.
    public fun id(n: u8): vector<u8> {
        let v = zero32();
        *vector::borrow_mut(&mut v, 15) = n;
        v
    }

    /// `"wire:n:last"` = byte 15 = n and byte 31 = last.
    public fun wire(n: u8, last: u8): vector<u8> {
        let v = id(n);
        *vector::borrow_mut(&mut v, 31) = last;
        v
    }

    public fun zero32(): vector<u8> { repeat(0, 32) }
    public fun zero20(): vector<u8> { repeat(0, 20) }
    public fun zero10(): vector<u8> { repeat(0, 10) }

    /// `"owner:0xNN"` = 20 bytes of NN.
    public fun owner_bytes(b: u8): vector<u8> { repeat(b, 20) }
    /// `"name:0xNN"` = 10 bytes of NN.
    public fun name_bytes(b: u8): vector<u8> { repeat(b, 10) }

    public fun repeat(b: u8, n: u64): vector<u8> {
        let v = vector::empty<u8>();
        let i = 0;
        while (i < n) { vector::push_back(&mut v, b); i = i + 1; };
        v
    }

    /// Two's-complement encoding of `-x` as u256.
    public fun neg(x: u256): u256 {
        (0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF - x) + 1
    }

    // ----- report encoding -------------------------------------------------------------

    /// 64-byte metadata: cid[32] || name[10] || owner[20] || report_id[2].
    public fun metadata_with(cid: vector<u8>, name: vector<u8>, owner: vector<u8>, report_id: vector<u8>): vector<u8> {
        let m = cid;
        vector::append(&mut m, name);
        vector::append(&mut m, owner);
        vector::append(&mut m, report_id);
        m
    }

    /// Metadata with cid zero32 and report_id 0x0000.
    public fun metadata(owner: vector<u8>, name: vector<u8>): vector<u8> {
        metadata_with(zero32(), name, owner, vector[0, 0])
    }

    /// The default metadata: owner:0x11, name:0x22.
    public fun default_metadata(): vector<u8> {
        metadata(owner_bytes(0x11), name_bytes(0x22))
    }

    public fun entry(data_id: vector<u8>, answer: u256, timestamp: u64): ReportEntry {
        cache::new_report_entry(data_id, answer, timestamp)
    }

    /// Canonical BCS serialisation of `List<ReportEntry>`.
    public fun encode_report(entries: vector<ReportEntry>): vector<u8> {
        bcs::to_bytes(&entries)
    }

    /// `on_report` with the default metadata.
    public fun report(sender: &signer, cache_addr: address, entries: vector<ReportEntry>) {
        cache::on_report(sender, cache_addr, default_metadata(), encode_report(entries));
    }

    /// `on_report` with explicit metadata owner/name.
    public fun report_as(sender: &signer, cache_addr: address, owner: vector<u8>, name: vector<u8>, entries: vector<ReportEntry>) {
        cache::on_report(sender, cache_addr, metadata(owner, name), encode_report(entries));
    }

    /// The `seed` macro: for k in 1..=n, advance to 100+k and report {data_id, k*100, k*10}.
    public fun seed(sender: &signer, cache_addr: address, data_id: vector<u8>, n: u64) {
        let k = 1;
        while (k <= n) {
            advance_to(100 + k);
            report(sender, cache_addr, vector[entry(data_id, ((k * 100) as u256), k * 10)]);
            k = k + 1;
        };
    }

    // ----- config helpers --------------------------------------------------------------

    public fun perm(sender: address, owner: vector<u8>, name: vector<u8>): WorkflowPermission {
        cache::new_workflow_permission(sender, owner, name)
    }

    /// The default permission for `sender`: owner:0x11, name:0x22.
    public fun default_perm(sender: address): WorkflowPermission {
        perm(sender, owner_bytes(0x11), name_bytes(0x22))
    }

    public fun config_entry(data_id: vector<u8>, description: vector<u8>, permissions: vector<WorkflowPermission>): FeedConfigEntry {
        cache::new_feed_config_entry(data_id, cache::new_feed_config(string::utf8(description), permissions))
    }

    /// `set_feed_configs` with one entry `{data_id, description, [default_perm(sender)]}`.
    public fun configure(admin: &signer, cache_addr: address, data_id: vector<u8>, description: vector<u8>, sender: address) {
        cache::set_feed_configs(admin, cache_addr, vector[config_entry(data_id, description, vector[default_perm(sender)])]);
    }

    // ----- round assertions ------------------------------------------------------------

    public fun assert_round(r: &cache::RoundData, round_id: u64, answer: u256, timestamp: u64) {
        assert!(cache::round_data_round_id(r) == round_id, 1000);
        assert!(cache::round_data_answer(r) == answer, 1001);
        assert!(cache::round_data_timestamp(r) == timestamp, 1002);
    }

    public fun assert_round_full(r: &cache::RoundData, round_id: u64, answer: u256, timestamp: u64, ledger_seq: u32, primary: bool) {
        assert_round(r, round_id, answer, timestamp);
        assert!(cache::round_data_ledger_seq(r) == ledger_seq, 1003);
        assert!(cache::round_data_primary(r) == primary, 1004);
    }

    /// `latest_round([data_id])[0]` unwrapped.
    public fun latest(cache_addr: address, data_id: vector<u8>): cache::RoundData {
        let v = cache::latest_round(cache_addr, vector[data_id]);
        assert!(vector::length(&v) == 1, 1010);
        option::destroy_some(vector::pop_back(&mut v))
    }

    public fun latest_is_none(cache_addr: address, data_id: vector<u8>): bool {
        let v = cache::latest_round(cache_addr, vector[data_id]);
        assert!(vector::length(&v) == 1, 1011);
        option::is_none(vector::borrow(&v, 0))
    }

    /// Full-range `round_range` (from 0 to u64::MAX).
    public fun full_range(cache_addr: address, data_id: vector<u8>): vector<cache::RoundData> {
        cache::round_range(cache_addr, data_id, 0, 18446744073709551615)
    }

    public fun assert_permission(p: &WorkflowPermission, sender: address, owner: vector<u8>, name: vector<u8>) {
        assert!(cache::workflow_permission_allowed_sender(p) == sender, 1020);
        assert!(cache::workflow_permission_allowed_workflow_owner(p) == owner, 1021);
        assert!(cache::workflow_permission_allowed_workflow_name(p) == name, 1022);
    }

    // ----- events ----------------------------------------------------------------------

    /// Snapshot of the Cache's per-type event counts.
    public fun snapshot(): vector<u64> { cache::test_event_counts() }

    /// Asserts the per-type deltas since `before`: exactly `n` events of type `idx` and no
    /// other Cache event (the `only` condition).
    public fun assert_only(before: &vector<u64>, idx: u64, n: u64) {
        let after = cache::test_event_counts();
        let i = 0;
        let len = vector::length(&after);
        while (i < len) {
            let delta = *vector::borrow(&after, i) - *vector::borrow(before, i);
            if (i == idx) {
                assert!(delta == n, 1100 + i);
            } else {
                assert!(delta == 0, 1200 + i);
            };
            i = i + 1;
        };
    }

    /// Asserts the delta of one event type only (other types unconstrained).
    public fun assert_count(before: &vector<u64>, idx: u64, n: u64) {
        let after = cache::test_event_counts();
        assert!(*vector::borrow(&after, idx) - *vector::borrow(before, idx) == n, 1300 + idx);
    }

    /// Asserts no Cache event at all was emitted since `before`.
    public fun assert_no_events(before: &vector<u64>) {
        let after = cache::test_event_counts();
        let i = 0;
        let len = vector::length(&after);
        while (i < len) {
            assert!(*vector::borrow(&after, i) == *vector::borrow(before, i), 1400 + i);
            i = i + 1;
        };
    }

    public fun emitted<T: drop + store>(e: &T): bool { event::was_event_emitted(e) }

    // ----- token -----------------------------------------------------------------------

    /// Deploys a primary-store-enabled fungible asset with unlimited supply; returns its
    /// metadata address and the mint ref.
    public fun deploy_token(creator: &signer): (address, MintRef) {
        let constructor_ref = object::create_named_object(creator, b"TOKEN");
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &constructor_ref,
            option::none(),
            string::utf8(b"Test Token"),
            string::utf8(b"TT"),
            8,
            string::utf8(b""),
            string::utf8(b""),
        );
        let mint_ref = fungible_asset::generate_mint_ref(&constructor_ref);
        (object::address_from_constructor_ref(&constructor_ref), mint_ref)
    }

    public fun mint(mint_ref: &MintRef, to: address, amount: u64) {
        primary_fungible_store::mint(mint_ref, to, amount);
    }

    public fun balance(of: address, token: address): u64 {
        primary_fungible_store::balance(of, object::address_to_object<Metadata>(token))
    }
}
