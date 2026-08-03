# 02 — Tradability

**Aim:** only produce output the user can actually act on, and only report risk
that actually exists.

**Status:** DONE (2026-07-26). Long-only for Phase 1; `portfolio_risk` now states
plainly that no stops exist. A real STOP order type remains optional/Phase 2.

---

## Why it matters

### Half the output is unusable

A **BUY** signal says "buy now, sell higher." A **SELL** signal says the reverse:
sell now, buy back lower — that is *short selling*, and it requires borrowing
shares you don't own.

The signal engine emits SELL signals, stores them, and counts them in the
published performance statistics. But the paper-trading account **rejects any
sell without an existing long position** — shorting was never implemented. So
roughly half of what the product generates cannot be traded inside the product.

Worse, those untradeable signals are in the win rate. The headline number
describes a system nobody could have run.

### Reporting risk against stops that do not exist

The chat agent has a `portfolio_risk` tool. It tells the user things like *"if
every stop hits, you lose ₹4,200."*

There is no stop-loss order type in the paper engine and no monitoring loop.
**No stops exist.** The tool is describing protection the user does not have,
which is worse than saying nothing — it converts unbounded risk into a specific,
reassuring number.

---

## Tasks

- [x] **Decide: long-only, or implement shorts.** For Phase 1, long-only is the
      honest call. Shorting needs margin rules, borrow availability and a forced
      square-off — that is Phase 2 scope.

- [x] **If long-only: filter SELLs out at the source.** Suppress them in the
      signal feed, the morning brief, and — critically — **the reported win
      rate**, so the number describes trades a user could have taken. Filtering
      the display but not the statistics would be the same dishonesty in a new
      place.

- [x] **Tell the truth in `portfolio_risk`.** Until a stop order type exists, the
      tool should say plainly: *"You have no stops set — your open risk is
      unbounded."* One hour, and it is the more useful answer.

- [ ] **(Optional, larger) Add a real stop-loss order type.** A `STOP` order type
      plus a monitoring loop that triggers it. Only then should `portfolio_risk`
      quote a stop-based number. This also unblocks the aggregate-risk cap in
      [01](01-risk-limits.md).

**Effort:** filtering + honest risk message ~half a day. Real stop orders ~2 days.

---

## Design note

If you go long-only, say so in the UI. "We only surface long setups in Phase 1"
is a credible product decision. Silently dropping half the signals is not.
