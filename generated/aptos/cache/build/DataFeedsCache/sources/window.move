/// The retention window of `spec/04` (behaviour on every chain, spec/06 C.1).
module data_feeds::window {
    struct Window has copy, drop, store {
        shortest_ttl: u32,
        grow_to_ttl: u32,
        grow_at_ledger: u32,
    }

    /// Window for a feed's first round: `{ ttl, ttl, 0 }`.
    public fun initial(ttl: u32): Window {
        Window { shortest_ttl: ttl, grow_to_ttl: ttl, grow_at_ledger: 0 }
    }

    /// `grow_to_ttl` once `now >= grow_at_ledger`, else `shortest_ttl`.
    public fun width_at(w: &Window, now: u32): u32 {
        if (now >= w.grow_at_ledger) w.grow_to_ttl else w.shortest_ttl
    }

    /// Next window on an append with prior state `p` whose tip was written at
    /// `prev_tip_ledger_seq`, with `ttl = round_ttl` at the time of the append and `seq` = now.
    public fun next(p: &Window, prev_tip_ledger_seq: u32, ttl: u32, seq: u32): Window {
        let grow_at_ledger = if (ttl != p.grow_to_ttl) {
            saturating_add(saturating_add(prev_tip_ledger_seq, ttl), 1)
        } else {
            p.grow_at_ledger
        };
        let current = width_at(p, seq);
        let shortest_ttl = if (current < ttl) current else ttl;
        Window { shortest_ttl, grow_to_ttl: ttl, grow_at_ledger }
    }

    /// A stored round is inside the window iff `round_ledger_seq >= now - width_at(now)`
    /// (saturating at zero).
    public fun is_readable(w: &Window, round_ledger_seq: u32, now: u32): bool {
        let width = width_at(w, now);
        let cutoff = if (now > width) now - width else 0;
        round_ledger_seq >= cutoff
    }

    fun saturating_add(a: u32, b: u32): u32 {
        let sum = (a as u64) + (b as u64);
        if (sum > 0xFFFF_FFFF) 0xFFFF_FFFF else (sum as u32)
    }

    public fun shortest_ttl(w: &Window): u32 { w.shortest_ttl }
    public fun grow_to_ttl(w: &Window): u32 { w.grow_to_ttl }
    public fun grow_at_ledger(w: &Window): u32 { w.grow_at_ledger }
}
