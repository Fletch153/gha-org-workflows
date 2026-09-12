/// The chain sequence unit (spec/06 C.5): the chain timestamp in seconds, truncated to u32.
/// Used for `ledger_seq`, `live_until_ledger` and the retention window arithmetic.
module data_feeds::ledger {
    use aptos_framework::timestamp;

    /// Current sequence: `now_seconds()` truncated to the spec's u32 width.
    public fun sequence(): u32 {
        ((timestamp::now_seconds() & 0xFFFF_FFFF) as u32)
    }
}
