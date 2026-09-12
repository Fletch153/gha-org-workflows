/// DataFeedsCache (spec/02, spec/04) — the source of truth for feed configuration, round
/// history and feed state. One instance = one Aptos object holding a `Cache` resource.
module data_feeds::cache {
    use std::bcs;
    use std::option::{Self, Option};
    use std::signer;
    use std::string::{Self, String};
    use std::vector;
    use aptos_std::aptos_hash;
    use aptos_std::table::{Self, Table};
    use aptos_framework::event;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::{Self, ExtendRef};
    use aptos_framework::primary_fungible_store;
    use data_feeds::host_error;
    use data_feeds::ledger;
    use data_feeds::ownable::{Self, OwnershipState};
    use data_feeds::window::{Self, Window};

    // ----- constants -------------------------------------------------------------------

    /// Precision of every stored answer.
    const DECIMALS: u32 = 18;
    /// 180 days in the sequence unit (seconds): round(180 * 86_400 / 1).
    const DATA_RETENTION_TTL: u32 = 15_552_000;

    // CacheError (spec/02), exact codes.
    const MalformedReport: u64 = 100;
    const UnauthorizedCaller: u64 = 101;
    const FeedNotConfigured: u64 = 102;
    const EmptyConfig: u64 = 103;
    const InvalidAddress: u64 = 104;
    const InvalidWorkflowName: u64 = 105;
    const DuplicatePermission: u64 = 106;
    const InvalidDataId: u64 = 107;
    const DuplicateFeedConfig: u64 = 108;
    /// Raised by the Proxy only; defined here for table completeness.
    const FeedFrozen: u64 = 109;
    const NoFeedState: u64 = 110;

    // ----- records ---------------------------------------------------------------------

    struct RoundData has copy, drop, store {
        round_id: u64,
        answer: u256,
        timestamp: u64,
        ledger_seq: u32,
        primary: bool,
    }

    struct WorkflowPermission has copy, drop, store {
        allowed_sender: address,
        allowed_workflow_owner: vector<u8>,
        allowed_workflow_name: vector<u8>,
    }

    struct FeedConfig has copy, drop, store {
        description: String,
        workflow_permissions: vector<WorkflowPermission>,
    }

    struct FeedConfigEntry has copy, drop, store {
        data_id: vector<u8>,
        config: FeedConfig,
    }

    struct ReportEntry has copy, drop, store {
        data_id: vector<u8>,
        answer: u256,
        timestamp: u64,
    }

    struct FeedState has copy, drop, store {
        latest_round: RoundData,
        window: Window,
        frozen: bool,
    }

    struct PermissionKey has copy, drop, store {
        data_id: vector<u8>,
        phash: vector<u8>,
    }

    struct RoundKey has copy, drop, store {
        data_id: vector<u8>,
        round_id: u64,
    }

    /// The instance resource (storage layout, overlay axis B).
    struct Cache has key {
        extend_ref: ExtendRef,
        ownership: OwnershipState,
        feed_admins: Table<address, bool>,
        feed_configs: Table<vector<u8>, FeedConfig>,
        permissions: Table<PermissionKey, bool>,
        feed_states: Table<vector<u8>, FeedState>,
        rounds: Table<RoundKey, RoundData>,
    }

    // ----- events ----------------------------------------------------------------------

    #[event]
    struct FeedUpdated has copy, drop, store {
        data_id: vector<u8>,
        round_id: u64,
        timestamp: u64,
        answer: u256,
        ledger_seq: u32,
        primary: bool,
    }

    #[event]
    struct StaleReport has copy, drop, store {
        data_id: vector<u8>,
        report_ts: u64,
        stored_ts: u64,
    }

    #[event]
    struct InvalidUpdatePermission has copy, drop, store {
        data_id: vector<u8>,
        sender: address,
        workflow_owner: vector<u8>,
        workflow_name: vector<u8>,
    }

    #[event]
    struct FeedConfigSet has copy, drop, store {
        data_id: vector<u8>,
        decimals: u32,
        description: String,
        workflow_permissions: vector<WorkflowPermission>,
    }

    #[event]
    struct FeedConfigRemoved has copy, drop, store {
        data_id: vector<u8>,
    }

    #[event]
    struct FeedFrozenSet has copy, drop, store {
        data_id: vector<u8>,
        frozen: bool,
    }

    #[event]
    struct FeedAdminAdded has copy, drop, store {
        admin: address,
    }

    #[event]
    struct FeedAdminRemoved has copy, drop, store {
        admin: address,
    }

    #[event]
    struct TokenRecovered has copy, drop, store {
        token: address,
        to: address,
        amount: u64,
    }

    // ----- constructor -----------------------------------------------------------------

    /// Creates the instance at `object::create_object_address(&creator, seed)` and records
    /// `owner`.
    public entry fun create(creator: &signer, seed: vector<u8>, owner: address) {
        let constructor_ref = object::create_named_object(creator, seed);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let instance_signer = object::generate_signer(&constructor_ref);
        move_to(&instance_signer, Cache {
            extend_ref,
            ownership: ownable::new(owner),
            feed_admins: table::new(),
            feed_configs: table::new(),
            permissions: table::new(),
            feed_states: table::new(),
            rounds: table::new(),
        });
        // instance lifetime refresh: no-op on Aptos (spec/06 C.3)
    }

    // ----- shared lifecycle ------------------------------------------------------------

    #[view]
    public fun version(): u32 { 1 }

    #[view]
    public fun type_and_version(): String { string::utf8(b"DataFeedsCache 1.0.0") }

    #[view]
    public fun get_owner(cache: address): Option<address> acquires Cache {
        assert_instance(cache);
        ownable::get_owner(&borrow_global<Cache>(cache).ownership)
    }

    public entry fun transfer_ownership(owner: &signer, cache: address, new_owner: address, live_until_ledger: u32) acquires Cache {
        assert_instance(cache);
        let c = borrow_global_mut<Cache>(cache);
        ownable::transfer_ownership(&mut c.ownership, signer::address_of(owner), new_owner, live_until_ledger, ledger::sequence());
    }

    public entry fun accept_ownership(new_owner: &signer, cache: address) acquires Cache {
        assert_instance(cache);
        let c = borrow_global_mut<Cache>(cache);
        ownable::accept_ownership(&mut c.ownership, signer::address_of(new_owner), ledger::sequence());
    }

    public entry fun renounce_ownership(owner: &signer, cache: address) acquires Cache {
        assert_instance(cache);
        let c = borrow_global_mut<Cache>(cache);
        ownable::renounce_ownership(&mut c.ownership, signer::address_of(owner), ledger::sequence());
    }

    /// Transfers `amount` of the fungible asset `token` held by the instance to `to`.
    public entry fun recover_tokens(owner: &signer, cache: address, token: address, to: address, amount: u64) acquires Cache {
        assert_instance(cache);
        let c = borrow_global<Cache>(cache);
        ownable::assert_owner(&c.ownership, signer::address_of(owner));
        let instance_signer = object::generate_signer_for_extending(&c.extend_ref);
        primary_fungible_store::transfer(&instance_signer, object::address_to_object<Metadata>(token), to, amount);
        event::emit(TokenRecovered { token, to, amount });
    }

    // ----- reader ----------------------------------------------------------------------

    #[view]
    public fun latest_round(cache: address, data_ids: vector<vector<u8>>): vector<Option<RoundData>> acquires Cache {
        assert_instance(cache);
        let c = borrow_global<Cache>(cache);
        let out = vector::empty<Option<RoundData>>();
        let i = 0;
        let n = vector::length(&data_ids);
        while (i < n) {
            let id = vector::borrow(&data_ids, i);
            if (table::contains(&c.feed_states, *id)) {
                vector::push_back(&mut out, option::some(table::borrow(&c.feed_states, *id).latest_round));
            } else {
                vector::push_back(&mut out, option::none());
            };
            i = i + 1;
        };
        out
    }

    #[view]
    public fun decimals(cache: address, data_ids: vector<vector<u8>>): vector<Option<u32>> acquires Cache {
        assert_instance(cache);
        let c = borrow_global<Cache>(cache);
        let out = vector::empty<Option<u32>>();
        let i = 0;
        let n = vector::length(&data_ids);
        while (i < n) {
            let id = vector::borrow(&data_ids, i);
            if (table::contains(&c.feed_configs, *id)) {
                vector::push_back(&mut out, option::some(DECIMALS));
            } else {
                vector::push_back(&mut out, option::none());
            };
            i = i + 1;
        };
        out
    }

    #[view]
    public fun description(cache: address, data_ids: vector<vector<u8>>): vector<Option<String>> acquires Cache {
        assert_instance(cache);
        let c = borrow_global<Cache>(cache);
        let out = vector::empty<Option<String>>();
        let i = 0;
        let n = vector::length(&data_ids);
        while (i < n) {
            let id = vector::borrow(&data_ids, i);
            if (table::contains(&c.feed_configs, *id)) {
                vector::push_back(&mut out, option::some(table::borrow(&c.feed_configs, *id).description));
            } else {
                vector::push_back(&mut out, option::none());
            };
            i = i + 1;
        };
        out
    }

    #[view]
    public fun is_configured(cache: address, data_ids: vector<vector<u8>>): vector<bool> acquires Cache {
        assert_instance(cache);
        let c = borrow_global<Cache>(cache);
        let out = vector::empty<bool>();
        let i = 0;
        let n = vector::length(&data_ids);
        while (i < n) {
            vector::push_back(&mut out, table::contains(&c.feed_configs, *vector::borrow(&data_ids, i)));
            i = i + 1;
        };
        out
    }

    #[view]
    public fun is_frozen(cache: address, data_ids: vector<vector<u8>>): vector<bool> acquires Cache {
        assert_instance(cache);
        let c = borrow_global<Cache>(cache);
        let out = vector::empty<bool>();
        let i = 0;
        let n = vector::length(&data_ids);
        while (i < n) {
            let id = vector::borrow(&data_ids, i);
            let frozen = if (table::contains(&c.feed_states, *id)) {
                table::borrow(&c.feed_states, *id).frozen
            } else {
                false
            };
            vector::push_back(&mut out, frozen);
            i = i + 1;
        };
        out
    }

    #[view]
    public fun get_round(cache: address, data_id: vector<u8>, round_id: u64): Option<RoundData> acquires Cache {
        assert_instance(cache);
        let c = borrow_global<Cache>(cache);
        if (!table::contains(&c.feed_states, data_id)) {
            return option::none()
        };
        let state = table::borrow(&c.feed_states, data_id);
        readable_round(c, state, &data_id, round_id, ledger::sequence())
    }

    #[view]
    public fun round_range(cache: address, data_id: vector<u8>, from: u64, to: u64): vector<RoundData> acquires Cache {
        assert_instance(cache);
        let c = borrow_global<Cache>(cache);
        let out = vector::empty<RoundData>();
        if (!table::contains(&c.feed_states, data_id)) {
            return out
        };
        let state = table::borrow(&c.feed_states, data_id);
        let now = ledger::sequence();
        let tip_id = state.latest_round.round_id;
        let lo = if (from < 1) 1 else from;
        let hi = if (to < tip_id) to else tip_id;
        let i = lo;
        while (i <= hi) {
            let r = readable_round(c, state, &data_id, i, now);
            if (option::is_some(&r)) {
                vector::push_back(&mut out, option::destroy_some(r));
            };
            if (i == hi) break;
            i = i + 1;
        };
        out
    }

    #[view]
    /// `bound`: `0` = AtOrBefore (newest readable round with `timestamp <= timestamp`),
    /// `1` = AtOrAfter (oldest readable round with `timestamp >= timestamp`).
    public fun find_round(cache: address, data_id: vector<u8>, timestamp: u64, bound: u8): Option<RoundData> acquires Cache {
        assert_instance(cache);
        assert!(bound == 0 || bound == 1, host_error::invalid_argument());
        let c = borrow_global<Cache>(cache);
        if (!table::contains(&c.feed_states, data_id)) {
            return option::none()
        };
        let state = table::borrow(&c.feed_states, data_id);
        let now = ledger::sequence();
        let best = option::none<RoundData>();
        let lo: u64 = 1;
        let hi: u64 = state.latest_round.round_id;
        while (lo <= hi) {
            let mid = lo + (hi - lo) / 2;
            let probe = readable_round(c, state, &data_id, mid, now);
            if (option::is_none(&probe)) {
                // unreadable ids form a low prefix: move up for both bounds
                lo = mid + 1;
            } else {
                let r = option::destroy_some(probe);
                if (bound == 0) {
                    if (r.timestamp <= timestamp) {
                        best = option::some(r);
                        lo = mid + 1;
                    } else {
                        hi = mid - 1;
                    }
                } else {
                    if (r.timestamp >= timestamp) {
                        best = option::some(r);
                        hi = mid - 1;
                    } else {
                        lo = mid + 1;
                    }
                }
            };
        };
        best
    }

    /// The tip is always readable; another id is readable iff the round exists and lies
    /// inside the window.
    fun readable_round(c: &Cache, state: &FeedState, data_id: &vector<u8>, round_id: u64, now: u32): Option<RoundData> {
        if (round_id == state.latest_round.round_id) {
            return option::some(state.latest_round)
        };
        let key = RoundKey { data_id: *data_id, round_id };
        if (!table::contains(&c.rounds, key)) {
            return option::none()
        };
        let round = table::borrow(&c.rounds, key);
        if (window::is_readable(&state.window, round.ledger_seq, now)) {
            option::some(*round)
        } else {
            option::none()
        }
    }

    // ----- writer ----------------------------------------------------------------------

    public entry fun on_report(sender: &signer, cache: address, metadata: vector<u8>, report: vector<u8>) acquires Cache {
        assert_instance(cache);
        let sender_addr = signer::address_of(sender);
        // instance lifetime refresh: no-op
        assert!(vector::length(&metadata) == 64, MalformedReport);
        let workflow_name = vector::slice(&metadata, 32, 42);
        let workflow_owner = vector::slice(&metadata, 42, 62);
        let entries = decode_report(&report);
        let seq = ledger::sequence();
        let phash = permission_hash(sender_addr, &workflow_owner, &workflow_name);
        let c = borrow_global_mut<Cache>(cache);
        let i = 0;
        let n = vector::length(&entries);
        while (i < n) {
            let entry = vector::borrow(&entries, i);
            let key = PermissionKey { data_id: entry.data_id, phash };
            if (!table::contains(&c.permissions, key)) {
                event::emit(InvalidUpdatePermission {
                    data_id: entry.data_id,
                    sender: sender_addr,
                    workflow_owner,
                    workflow_name,
                });
            } else {
                record(c, entry.data_id, entry.answer, entry.timestamp, seq);
            };
            i = i + 1;
        };
    }

    fun record(c: &mut Cache, data_id: vector<u8>, answer: u256, timestamp: u64, seq: u32) {
        let has_state = table::contains(&c.feed_states, data_id);
        let stored_ts = if (has_state) table::borrow(&c.feed_states, data_id).latest_round.timestamp else 0;
        if (timestamp <= stored_ts) {
            event::emit(StaleReport { data_id, report_ts: timestamp, stored_ts });
        } else {
            let ttl = round_ttl();
            let (round_id, win, frozen) = if (has_state) {
                let prev = table::borrow(&c.feed_states, data_id);
                (prev.latest_round.round_id + 1,
                 window::next(&prev.window, prev.latest_round.ledger_seq, ttl, seq),
                 prev.frozen)
            } else {
                (1, window::initial(ttl), false)
            };
            let round = RoundData { round_id, answer, timestamp, ledger_seq: seq, primary: true };
            let key = RoundKey { data_id, round_id };
            // a round that already exists at tip + 1 is an inconsistent state: table::add aborts
            table::add(&mut c.rounds, key, round);
            table::upsert(&mut c.feed_states, data_id, FeedState { latest_round: round, window: win, frozen });
            event::emit(FeedUpdated { data_id, round_id, timestamp, answer, ledger_seq: seq, primary: true });
        };
        // lifetime refreshes of FeedState / FeedConfig / Permissions: no-op on Aptos
    }

    /// `round_ttl = min(DATA_RETENTION_TTL, network maximum)`; the maximum is unbounded here.
    fun round_ttl(): u32 { DATA_RETENTION_TTL }

    // ----- admin -----------------------------------------------------------------------

    public fun set_feed_configs(admin: &signer, cache: address, entries: vector<FeedConfigEntry>) acquires Cache {
        assert_instance(cache);
        let c = borrow_global_mut<Cache>(cache);
        assert_feed_admin(c, signer::address_of(admin));
        let n = vector::length(&entries);
        assert!(n > 0, EmptyConfig);
        // validate every entry before writing any
        let i = 0;
        while (i < n) {
            let entry = vector::borrow(&entries, i);
            // host-level width checks for this entry precede its spec checks
            assert!(vector::length(&entry.data_id) == 32, host_error::invalid_argument());
            let perms = &entry.config.workflow_permissions;
            let m = vector::length(perms);
            let j = 0;
            while (j < m) {
                let p = vector::borrow(perms, j);
                assert!(vector::length(&p.allowed_workflow_owner) == 20, host_error::invalid_argument());
                assert!(vector::length(&p.allowed_workflow_name) == 10, host_error::invalid_argument());
                j = j + 1;
            };
            assert!(!is_all_zero(&entry.data_id), InvalidDataId);
            let k = i + 1;
            while (k < n) {
                assert!(vector::borrow(&entries, k).data_id != entry.data_id, DuplicateFeedConfig);
                k = k + 1;
            };
            assert!(m > 0, EmptyConfig);
            j = 0;
            while (j < m) {
                let p = vector::borrow(perms, j);
                assert!(!is_all_zero(&p.allowed_workflow_owner), InvalidAddress);
                assert!(!is_all_zero(&p.allowed_workflow_name), InvalidWorkflowName);
                let k = j + 1;
                while (k < m) {
                    assert!(*vector::borrow(perms, k) != *p, DuplicatePermission);
                    k = k + 1;
                };
                j = j + 1;
            };
            i = i + 1;
        };
        // write phase
        i = 0;
        while (i < n) {
            let entry = vector::borrow(&entries, i);
            let existed = table::contains(&c.feed_configs, entry.data_id);
            if (existed) {
                let old = table::remove(&mut c.feed_configs, entry.data_id);
                delete_permissions(c, &entry.data_id, &old.workflow_permissions);
            };
            table::add(&mut c.feed_configs, entry.data_id, entry.config);
            let perms = &entry.config.workflow_permissions;
            let m = vector::length(perms);
            let j = 0;
            while (j < m) {
                let p = vector::borrow(perms, j);
                let phash = permission_hash(p.allowed_sender, &p.allowed_workflow_owner, &p.allowed_workflow_name);
                table::add(&mut c.permissions, PermissionKey { data_id: entry.data_id, phash }, true);
                j = j + 1;
            };
            if (existed) {
                event::emit(FeedConfigRemoved { data_id: entry.data_id });
            };
            event::emit(FeedConfigSet {
                data_id: entry.data_id,
                decimals: DECIMALS,
                description: entry.config.description,
                workflow_permissions: entry.config.workflow_permissions,
            });
            i = i + 1;
        };
    }

    public entry fun remove_feed_configs(admin: &signer, cache: address, data_ids: vector<vector<u8>>) acquires Cache {
        assert_instance(cache);
        let c = borrow_global_mut<Cache>(cache);
        assert_feed_admin(c, signer::address_of(admin));
        let n = vector::length(&data_ids);
        let i = 0;
        while (i < n) {
            let id = vector::borrow(&data_ids, i);
            let k = i + 1;
            while (k < n) {
                assert!(vector::borrow(&data_ids, k) != id, DuplicateFeedConfig);
                k = k + 1;
            };
            assert!(table::contains(&c.feed_configs, *id), FeedNotConfigured);
            i = i + 1;
        };
        i = 0;
        while (i < n) {
            let id = *vector::borrow(&data_ids, i);
            let old = table::remove(&mut c.feed_configs, id);
            delete_permissions(c, &id, &old.workflow_permissions);
            event::emit(FeedConfigRemoved { data_id: id });
            i = i + 1;
        };
    }

    public entry fun set_feed_frozen(admin: &signer, cache: address, data_ids: vector<vector<u8>>, frozen: bool) acquires Cache {
        assert_instance(cache);
        let c = borrow_global_mut<Cache>(cache);
        assert_feed_admin(c, signer::address_of(admin));
        let n = vector::length(&data_ids);
        let i = 0;
        while (i < n) {
            let id = vector::borrow(&data_ids, i);
            let k = i + 1;
            while (k < n) {
                assert!(vector::borrow(&data_ids, k) != id, DuplicateFeedConfig);
                k = k + 1;
            };
            i = i + 1;
        };
        i = 0;
        while (i < n) {
            let id = *vector::borrow(&data_ids, i);
            assert!(table::contains(&c.feed_states, id), NoFeedState);
            table::borrow_mut(&mut c.feed_states, id).frozen = frozen;
            event::emit(FeedFrozenSet { data_id: id, frozen });
            i = i + 1;
        };
    }

    public entry fun add_feed_admin(owner: &signer, cache: address, new_admin: address) acquires Cache {
        assert_instance(cache);
        let c = borrow_global_mut<Cache>(cache);
        ownable::assert_owner(&c.ownership, signer::address_of(owner));
        table::upsert(&mut c.feed_admins, new_admin, true);
        event::emit(FeedAdminAdded { admin: new_admin });
    }

    public entry fun remove_feed_admin(owner: &signer, cache: address, admin: address) acquires Cache {
        assert_instance(cache);
        let c = borrow_global_mut<Cache>(cache);
        ownable::assert_owner(&c.ownership, signer::address_of(owner));
        if (table::contains(&c.feed_admins, admin)) {
            table::remove(&mut c.feed_admins, admin);
        };
        event::emit(FeedAdminRemoved { admin });
    }

    #[view]
    public fun get_feed_permissions(cache: address, data_id: vector<u8>): vector<WorkflowPermission> acquires Cache {
        assert_instance(cache);
        let c = borrow_global<Cache>(cache);
        if (table::contains(&c.feed_configs, data_id)) {
            table::borrow(&c.feed_configs, data_id).workflow_permissions
        } else {
            vector::empty()
        }
    }

    #[view]
    public fun has_permission(cache: address, data_id: vector<u8>, sender: address, workflow_owner: vector<u8>, workflow_name: vector<u8>): bool acquires Cache {
        assert_instance(cache);
        let c = borrow_global<Cache>(cache);
        let phash = permission_hash(sender, &workflow_owner, &workflow_name);
        table::contains(&c.permissions, PermissionKey { data_id, phash })
    }

    #[view]
    public fun is_feed_admin(cache: address, admin: address): bool acquires Cache {
        assert_instance(cache);
        table::contains(&borrow_global<Cache>(cache).feed_admins, admin)
    }

    // ----- internal helpers ------------------------------------------------------------

    fun assert_instance(cache: address) {
        assert!(exists<Cache>(cache), host_error::no_instance());
    }

    fun assert_feed_admin(c: &Cache, admin: address) {
        assert!(table::contains(&c.feed_admins, admin), UnauthorizedCaller);
    }

    fun delete_permissions(c: &mut Cache, data_id: &vector<u8>, perms: &vector<WorkflowPermission>) {
        let m = vector::length(perms);
        let j = 0;
        while (j < m) {
            let p = vector::borrow(perms, j);
            let phash = permission_hash(p.allowed_sender, &p.allowed_workflow_owner, &p.allowed_workflow_name);
            let key = PermissionKey { data_id: *data_id, phash };
            if (table::contains(&c.permissions, key)) {
                table::remove(&mut c.permissions, key);
            };
            j = j + 1;
        };
    }

    fun is_all_zero(bytes: &vector<u8>): bool {
        let i = 0;
        let n = vector::length(bytes);
        while (i < n) {
            if (*vector::borrow(bytes, i) != 0) return false;
            i = i + 1;
        };
        true
    }

    /// `keccak256( bcs(sender) || bcs(owner) || bcs(name) )`.
    fun permission_hash(sender: address, workflow_owner: &vector<u8>, workflow_name: &vector<u8>): vector<u8> {
        let buf = bcs::to_bytes(&sender);
        vector::append(&mut buf, bcs::to_bytes(workflow_owner));
        vector::append(&mut buf, bcs::to_bytes(workflow_name));
        aptos_hash::keccak256(buf)
    }

    // ----- strict BCS decoder for `vector<ReportEntry>` --------------------------------

    struct Reader has drop {
        bytes: vector<u8>,
        pos: u64,
    }

    fun decode_report(report: &vector<u8>): vector<ReportEntry> {
        let r = Reader { bytes: *report, pos: 0 };
        let count = read_uleb128(&mut r);
        let out = vector::empty<ReportEntry>();
        let i = 0;
        while (i < count) {
            let len = read_uleb128(&mut r);
            let data_id = read_bytes(&mut r, len);
            let answer = read_u256_le(&mut r);
            let timestamp = read_u64_le(&mut r);
            vector::push_back(&mut out, ReportEntry { data_id, answer, timestamp });
            i = i + 1;
        };
        assert!(r.pos == vector::length(&r.bytes), MalformedReport);
        out
    }

    fun read_u8(r: &mut Reader): u8 {
        assert!(r.pos < vector::length(&r.bytes), MalformedReport);
        let b = *vector::borrow(&r.bytes, r.pos);
        r.pos = r.pos + 1;
        b
    }

    /// Canonical (minimal) ULEB128 of a u32, at most 5 bytes.
    fun read_uleb128(r: &mut Reader): u64 {
        let value: u64 = 0;
        let shift: u8 = 0;
        let first = true;
        loop {
            let b = read_u8(r);
            let low = ((b & 0x7f) as u64);
            if (shift == 28) {
                assert!(low <= 0x0f, MalformedReport);
            };
            value = value | (low << shift);
            if ((b & 0x80) == 0) {
                // a non-first terminating byte of zero is a non-minimal encoding
                assert!(first || b != 0, MalformedReport);
                return value
            };
            first = false;
            shift = shift + 7;
            assert!(shift <= 28, MalformedReport);
        }
    }

    fun read_bytes(r: &mut Reader, len: u64): vector<u8> {
        assert!(len <= vector::length(&r.bytes) - r.pos, MalformedReport);
        let out = vector::slice(&r.bytes, r.pos, r.pos + len);
        r.pos = r.pos + len;
        out
    }

    fun read_u64_le(r: &mut Reader): u64 {
        let v: u64 = 0;
        let i: u8 = 0;
        while (i < 8) {
            v = v | ((read_u8(r) as u64) << (i * 8));
            i = i + 1;
        };
        v
    }

    fun read_u256_le(r: &mut Reader): u256 {
        let v: u256 = 0;
        let i: u8 = 0;
        while (i < 32) {
            v = v | ((read_u8(r) as u256) << (i * 8));
            i = i + 1;
        };
        v
    }

    // ----- public record constructors and accessors (spec/06 M.2) ----------------------

    public fun new_workflow_permission(allowed_sender: address, allowed_workflow_owner: vector<u8>, allowed_workflow_name: vector<u8>): WorkflowPermission {
        WorkflowPermission { allowed_sender, allowed_workflow_owner, allowed_workflow_name }
    }

    public fun new_feed_config(description: String, workflow_permissions: vector<WorkflowPermission>): FeedConfig {
        FeedConfig { description, workflow_permissions }
    }

    public fun new_feed_config_entry(data_id: vector<u8>, config: FeedConfig): FeedConfigEntry {
        FeedConfigEntry { data_id, config }
    }

    public fun new_report_entry(data_id: vector<u8>, answer: u256, timestamp: u64): ReportEntry {
        ReportEntry { data_id, answer, timestamp }
    }

    public fun round_data_round_id(r: &RoundData): u64 { r.round_id }
    public fun round_data_answer(r: &RoundData): u256 { r.answer }
    public fun round_data_timestamp(r: &RoundData): u64 { r.timestamp }
    public fun round_data_ledger_seq(r: &RoundData): u32 { r.ledger_seq }
    public fun round_data_primary(r: &RoundData): bool { r.primary }

    public fun workflow_permission_allowed_sender(p: &WorkflowPermission): address { p.allowed_sender }
    public fun workflow_permission_allowed_workflow_owner(p: &WorkflowPermission): vector<u8> { p.allowed_workflow_owner }
    public fun workflow_permission_allowed_workflow_name(p: &WorkflowPermission): vector<u8> { p.allowed_workflow_name }

    public fun feed_config_description(c: &FeedConfig): String { c.description }
    public fun feed_config_workflow_permissions(c: &FeedConfig): vector<WorkflowPermission> { c.workflow_permissions }

    public fun feed_config_entry_data_id(e: &FeedConfigEntry): vector<u8> { e.data_id }
    public fun feed_config_entry_config(e: &FeedConfigEntry): FeedConfig { e.config }

    public fun report_entry_data_id(e: &ReportEntry): vector<u8> { e.data_id }
    public fun report_entry_answer(e: &ReportEntry): u256 { e.answer }
    public fun report_entry_timestamp(e: &ReportEntry): u64 { e.timestamp }

    // ----- test support (mock-Cache injectors, event constructors, static tables) -------

    #[test_only]
    public fun test_new_round_data(round_id: u64, answer: u256, timestamp: u64, ledger_seq: u32, primary: bool): RoundData {
        RoundData { round_id, answer, timestamp, ledger_seq, primary }
    }

    #[test_only]
    /// Ensures a `FeedState` exists for `data_id`; a state created here has a zero tip.
    fun test_ensure_state(c: &mut Cache, data_id: vector<u8>) {
        if (!table::contains(&c.feed_states, data_id)) {
            table::add(&mut c.feed_states, data_id, FeedState {
                latest_round: RoundData { round_id: 0, answer: 0, timestamp: 0, ledger_seq: 0, primary: true },
                window: window::initial(DATA_RETENTION_TTL),
                frozen: false,
            });
        };
    }

    #[test_only]
    /// Direct write of `Round(data_id, round_id)` (ledger_seq 1000, primary true); no business logic.
    public fun test_inject_round(cache: address, data_id: vector<u8>, round_id: u64, answer: u256, timestamp: u64) acquires Cache {
        let c = borrow_global_mut<Cache>(cache);
        test_ensure_state(c, data_id);
        table::upsert(&mut c.rounds, RoundKey { data_id, round_id },
            RoundData { round_id, answer, timestamp, ledger_seq: 1000, primary: true });
    }

    #[test_only]
    /// Sets `FeedState.latest_round` without touching the round table.
    public fun test_set_latest(cache: address, data_id: vector<u8>, round_id: u64, answer: u256, timestamp: u64) acquires Cache {
        let c = borrow_global_mut<Cache>(cache);
        test_ensure_state(c, data_id);
        table::borrow_mut(&mut c.feed_states, data_id).latest_round =
            RoundData { round_id, answer, timestamp, ledger_seq: 1000, primary: true };
    }

    #[test_only]
    /// Sets the frozen flag, creating a zero-tip state if absent.
    public fun test_set_frozen(cache: address, data_id: vector<u8>, frozen: bool) acquires Cache {
        let c = borrow_global_mut<Cache>(cache);
        test_ensure_state(c, data_id);
        table::borrow_mut(&mut c.feed_states, data_id).frozen = frozen;
    }

    #[test_only]
    /// Removes the stored round entry (emulates TTL expiry); the tip in `FeedState` is untouched.
    public fun test_expire_round(cache: address, data_id: vector<u8>, round_id: u64) acquires Cache {
        let c = borrow_global_mut<Cache>(cache);
        let key = RoundKey { data_id, round_id };
        if (table::contains(&c.rounds, key)) {
            table::remove(&mut c.rounds, key);
        };
    }

    #[test_only]
    public fun test_window(cache: address, data_id: vector<u8>): Window acquires Cache {
        table::borrow(&borrow_global<Cache>(cache).feed_states, data_id).window
    }

    #[test_only]
    public fun test_permission_hash(sender: address, workflow_owner: vector<u8>, workflow_name: vector<u8>): vector<u8> {
        permission_hash(sender, &workflow_owner, &workflow_name)
    }

    #[test_only]
    /// The Cache codes in spec order:
    /// [MalformedReport, UnauthorizedCaller, FeedNotConfigured, EmptyConfig, InvalidAddress,
    ///  InvalidWorkflowName, DuplicatePermission, InvalidDataId, DuplicateFeedConfig, FeedFrozen, NoFeedState].
    public fun test_error_codes(): vector<u64> {
        vector[MalformedReport, UnauthorizedCaller, FeedNotConfigured, EmptyConfig, InvalidAddress,
               InvalidWorkflowName, DuplicatePermission, InvalidDataId, DuplicateFeedConfig, FeedFrozen, NoFeedState]
    }

    #[test_only]
    public fun test_data_retention_ttl(): u32 { DATA_RETENTION_TTL }

    #[test_only]
    public fun test_decimals(): u32 { DECIMALS }

    #[test_only]
    /// Accumulated per-type event counts, in this order:
    /// [FeedUpdated, StaleReport, InvalidUpdatePermission, FeedConfigSet, FeedConfigRemoved,
    ///  FeedFrozenSet, FeedAdminAdded, FeedAdminRemoved, OwnershipTransfer,
    ///  OwnershipTransferCompleted, OwnershipRenounced, TokenRecovered].
    public fun test_event_counts(): vector<u64> {
        vector[
            vector::length(&event::emitted_events<FeedUpdated>()),
            vector::length(&event::emitted_events<StaleReport>()),
            vector::length(&event::emitted_events<InvalidUpdatePermission>()),
            vector::length(&event::emitted_events<FeedConfigSet>()),
            vector::length(&event::emitted_events<FeedConfigRemoved>()),
            vector::length(&event::emitted_events<FeedFrozenSet>()),
            vector::length(&event::emitted_events<FeedAdminAdded>()),
            vector::length(&event::emitted_events<FeedAdminRemoved>()),
            vector::length(&event::emitted_events<ownable::OwnershipTransfer>()),
            vector::length(&event::emitted_events<ownable::OwnershipTransferCompleted>()),
            vector::length(&event::emitted_events<ownable::OwnershipRenounced>()),
            vector::length(&event::emitted_events<TokenRecovered>()),
        ]
    }

    #[test_only]
    public fun feed_updated_event(data_id: vector<u8>, round_id: u64, timestamp: u64, answer: u256, ledger_seq: u32, primary: bool): FeedUpdated {
        FeedUpdated { data_id, round_id, timestamp, answer, ledger_seq, primary }
    }

    #[test_only]
    public fun stale_report_event(data_id: vector<u8>, report_ts: u64, stored_ts: u64): StaleReport {
        StaleReport { data_id, report_ts, stored_ts }
    }

    #[test_only]
    public fun invalid_update_permission_event(data_id: vector<u8>, sender: address, workflow_owner: vector<u8>, workflow_name: vector<u8>): InvalidUpdatePermission {
        InvalidUpdatePermission { data_id, sender, workflow_owner, workflow_name }
    }

    #[test_only]
    public fun feed_config_set_event(data_id: vector<u8>, decimals: u32, description: String, workflow_permissions: vector<WorkflowPermission>): FeedConfigSet {
        FeedConfigSet { data_id, decimals, description, workflow_permissions }
    }

    #[test_only]
    public fun feed_config_removed_event(data_id: vector<u8>): FeedConfigRemoved {
        FeedConfigRemoved { data_id }
    }

    #[test_only]
    public fun feed_frozen_set_event(data_id: vector<u8>, frozen: bool): FeedFrozenSet {
        FeedFrozenSet { data_id, frozen }
    }

    #[test_only]
    public fun feed_admin_added_event(admin: address): FeedAdminAdded {
        FeedAdminAdded { admin }
    }

    #[test_only]
    public fun feed_admin_removed_event(admin: address): FeedAdminRemoved {
        FeedAdminRemoved { admin }
    }

    #[test_only]
    public fun token_recovered_event(token: address, to: address, amount: u64): TokenRecovered {
        TokenRecovered { token, to, amount }
    }
}
