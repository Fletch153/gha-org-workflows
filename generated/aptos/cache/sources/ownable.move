/// Two-step ownership with an expiring offer, implementing the `spec/06` J table exactly.
/// The state value is embedded in each instance resource; every function takes the state,
/// the caller address and `now` (the `data_feeds::ledger` sequence), so it can only be
/// driven by the module that owns the instance.
module data_feeds::ownable {
    use std::option::{Self, Option};
    use aptos_framework::event;
    use data_feeds::host_error;

    // Ownership error codes (spec/06 E, complete table).
    const OwnerNotSet: u64 = 2100;
    const TransferInProgress: u64 = 2101;
    const OwnerAlreadySet: u64 = 2102;
    const NoPendingTransfer: u64 = 2200;
    const InvalidLiveUntilLedger: u64 = 2201;
    const InvalidPendingAccount: u64 = 2202;
    const TransferExpired: u64 = 2203;

    struct PendingTransfer has copy, drop, store {
        new_owner: address,
        live_until_ledger: u32,
    }

    struct OwnershipState has store {
        owner: Option<address>,
        pending: Option<PendingTransfer>,
    }

    #[event]
    /// spec `ownership_transfer { old_owner, new_owner, live_until_ledger }`.
    struct OwnershipTransfer has copy, drop, store {
        old_owner: address,
        new_owner: address,
        live_until_ledger: u32,
    }

    #[event]
    /// spec `ownership_transfer_completed { new_owner }`.
    struct OwnershipTransferCompleted has copy, drop, store {
        new_owner: address,
    }

    #[event]
    /// spec `ownership_renounced { old_owner }`.
    struct OwnershipRenounced has copy, drop, store {
        old_owner: address,
    }

    /// Constructor path: records `owner`.
    public fun new(owner: address): OwnershipState {
        let state = OwnershipState { owner: option::none(), pending: option::none() };
        set_owner(&mut state, owner);
        state
    }

    /// Internal set-owner helper; `OwnerAlreadySet` is unreachable through the public surface.
    fun set_owner(state: &mut OwnershipState, owner: address) {
        assert!(option::is_none(&state.owner), OwnerAlreadySet);
        state.owner = option::some(owner);
    }

    /// The recorded owner, or none after renounce.
    public fun get_owner(state: &OwnershipState): Option<address> {
        state.owner
    }

    /// Owner gating: no owner recorded -> `OwnerNotSet`; then the caller must be the owner
    /// (host failure otherwise).
    public fun assert_owner(state: &OwnershipState, caller: address) {
        assert!(option::is_some(&state.owner), OwnerNotSet);
        assert!(*option::borrow(&state.owner) == caller, host_error::unauthorized());
    }

    public fun transfer_ownership(
        state: &mut OwnershipState,
        caller: address,
        new_owner: address,
        live_until_ledger: u32,
        now: u32,
    ) {
        assert_owner(state, caller);
        let old_owner = *option::borrow(&state.owner);
        if (live_until_ledger == 0) {
            // cancel branch
            assert!(option::is_some(&state.pending), NoPendingTransfer);
            assert!(option::borrow(&state.pending).new_owner == new_owner, InvalidPendingAccount);
            state.pending = option::none();
        } else {
            assert!(live_until_ledger >= now, InvalidLiveUntilLedger);
            state.pending = option::some(PendingTransfer { new_owner, live_until_ledger });
        };
        event::emit(OwnershipTransfer { old_owner, new_owner, live_until_ledger });
    }

    public fun accept_ownership(state: &mut OwnershipState, caller: address, now: u32) {
        assert!(option::is_some(&state.pending), NoPendingTransfer);
        let pending = *option::borrow(&state.pending);
        assert!(now <= pending.live_until_ledger, TransferExpired);
        assert!(pending.new_owner == caller, host_error::unauthorized());
        state.owner = option::some(pending.new_owner);
        state.pending = option::none();
        event::emit(OwnershipTransferCompleted { new_owner: pending.new_owner });
    }

    public fun renounce_ownership(state: &mut OwnershipState, caller: address, now: u32) {
        assert_owner(state, caller);
        if (option::is_some(&state.pending)) {
            let pending = *option::borrow(&state.pending);
            assert!(now > pending.live_until_ledger, TransferInProgress);
            // an expired offer is simply discarded
            state.pending = option::none();
        };
        let old_owner = option::extract(&mut state.owner);
        event::emit(OwnershipRenounced { old_owner });
    }

    // ----- test support -----------------------------------------------------------------

    #[test_only]
    /// The ownership codes in table order:
    /// [OwnerNotSet, TransferInProgress, OwnerAlreadySet, NoPendingTransfer,
    ///  InvalidLiveUntilLedger, InvalidPendingAccount, TransferExpired].
    public fun test_error_codes(): vector<u64> {
        vector[OwnerNotSet, TransferInProgress, OwnerAlreadySet, NoPendingTransfer,
               InvalidLiveUntilLedger, InvalidPendingAccount, TransferExpired]
    }

    #[test_only]
    public fun ownership_transfer_event(old_owner: address, new_owner: address, live_until_ledger: u32): OwnershipTransfer {
        OwnershipTransfer { old_owner, new_owner, live_until_ledger }
    }

    #[test_only]
    public fun ownership_transfer_completed_event(new_owner: address): OwnershipTransferCompleted {
        OwnershipTransferCompleted { new_owner }
    }

    #[test_only]
    public fun ownership_renounced_event(old_owner: address): OwnershipRenounced {
        OwnershipRenounced { old_owner }
    }
}
