# 01 — Risk Limits

**Aim:** make it impossible for one bad session, or one bad streak, to wipe the
account.

**Status:** DONE (2026-07-27). Caps enforced in `placeOrder`, exposed to the chat agent,
and now shown in the order ticket before an order is attempted.

---

## Why it matters

Two facts combine badly.

**Streaks are expected, not exceptional.** The system currently wins ~30% of
trades. At that rate, a run of 10 consecutive losers inside 100 trades is not bad
luck — it is the *statistically expected* outcome. If each trade risks 1% of the
account, that streak is −10%. Nothing in the code notices or intervenes.

**The positions are not independent.** The universe is 25 large-cap Nifty names —
5 banks, 4 IT companies. When the index drops, they drop together. Holding 8
positions is not 8 independent bets with diversified risk; on a bad day it is
closer to 1 bet at 8× size. A naive "1% risk per trade" calculation says you are
risking 8%. The truth is nearer 8% *correlated*, which can all resolve in the
same hour.

This is the difference between a bad week and a dead account, and it is the
single largest gap in the product.

---

## Tasks

- [x] **Cap concurrent positions.** Reject new orders in `placeOrder` once N
      positions are open. Start at 5. This is the cheapest of the three and
      catches most of the risk.

- [x] **Cap aggregate open risk.** Sum `(entry − stop) × quantity` across open
      positions; reject a new order that would push the total past ~3% of account
      value. Requires stops to exist first — see [02](02-tradability.md).

- [x] **Daily loss limit.** Track realised P&L for the current session; once it
      breaches −3%, block all new orders until the next trading day. Needs the
      session boundary from `app/market/calendar.py` — see
      [03](03-market-hours.md).

- [x] **Surface the limits in the UI and to the agent.** A blocked order must say
      *why* ("daily loss limit reached"), not just fail. The chat agent should be
      able to read the current limit state so it stops suggesting trades the
      account cannot take.

**Effort:** ~1 day for all four. Entry point is
`ai-trader-api/src/portfolio/paper-trading.service.ts`.

---

## Design note

Put the checks in `placeOrder`, not `executeOrder`. Rejecting at placement gives
the user a clear message; rejecting at execution leaves an order in a failed
state and is harder to explain.

The cash movement in `executeOrder` is already atomic (a conditional
`findOneAndUpdate` with `$inc`), so limit checks can read a consistent balance.
