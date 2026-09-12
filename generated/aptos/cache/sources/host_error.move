/// Host-failure abort codes (spec/06 A.3, D.2): failures that are the platform's, not the
/// contract's. All lie outside every spec range (Cache 100-199, Proxy 50-99, ownership
/// 2100-2299) because `std::error` places the category in the high 16 bits.
module data_feeds::host_error {
    use std::error;

    /// The signer is not the recorded owner / pending owner. `0x50001`.
    public fun unauthorized(): u64 { error::permission_denied(1) }

    /// No `Cache` / `Proxy` resource exists at the instance address. `0x60001`.
    public fun no_instance(): u64 { error::not_found(1) }

    /// A mis-sized fixed-width byte argument or an unknown `Bound` discriminant. `0x10001`.
    public fun invalid_argument(): u64 { error::invalid_argument(1) }
}
