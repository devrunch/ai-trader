# 03 — Market Hours and Square-Off

**Aim:** only generate signals when the market is actually open, and never hold a
position overnight.

**Status:** DONE (2026-07-26) except the holiday-list verification, which needs a human
with the official NSE circular.

---

## Why it matters

### The screener runs when the market is shut

NSE trades **09:15–15:30 IST**, weekdays, minus roughly a dozen public holidays a
year.

Celery beat currently fires the screener every 15 minutes on
`hour="9-15", day_of_week="mon-fri"`. That is:

- **09:00 and 09:15** — before or at the open, on data from yesterday
- **15:45** — after the close
- **every trading holiday** — Diwali, Holi, Independence Day — on completely
  stale data

Each of those runs produces real signals, stores them, and scores them in the
performance statistics. They are noise generated against prices that cannot move.

`app/market/calendar.py` already implements `is_trading_day()`,
`is_market_open()`, `is_holiday()` and `next_open()`. **The fix is written. It is
simply not wired up.**

### Nothing enforces "intraday"

The signal prompt says *"intraday positions only."* Nothing enforces it:

- the paper account holds positions indefinitely
- the walk-forward backtest holds up to 10 hours, crossing session boundaries —
  which means overnight gap risk is being folded into results for trades that
  claim not to be exposed to it

`is_square_off_time()` (15:20 IST) exists. Nothing closes anything.

Until this is fixed, the product's central claim is not true of its own
behaviour.

---

## Tasks

- [x] **Gate the screener on the calendar.** Add an early return in
      `run_screener` when `not is_market_open()`. Tighten the beat schedule to
      the real window (~09:20–15:15 IST — a few minutes after the open so the
      first bar has formed, and before the close so there is time to act).
      **~1 hour.**

- [x] **Add a square-off task.** Celery beat at 15:20 IST: close every open paper
      position at market. Log what was closed. **~half a day.**

- [x] **Cap backtest holding period at the session end.** `forward_bars` should
      stop at the last bar of the signal's own session rather than running a
      fixed count across days. This will change the measured numbers — that is
      correct, the current ones include overnight risk the strategy claims not to
      take.

- [ ] **Verify the 2026 holiday list.** It was transcribed from model knowledge,
      **not fetched from nseindia.com**. Cross-check against the official NSE
      circular before relying on it. `holiday_calendar_known(year)` is exposed
      via `/market/status`, so a lapsed list is at least visible rather than
      silently treating a holiday as a trading day. See also
      [09](09-deploy-verification.md).

**Effort:** ~1 day total, most of it in the square-off task.

---

## Files

| | |
|---|---|
| Calendar (built) | `ai-trader-signals/app/market/calendar.py` |
| Beat schedule | `ai-trader-signals/app/worker/celery_app.py` |
| Screener | `ai-trader-signals/app/worker/tasks.py` |
| Backtest window | `ai-trader-signals/app/signals/backtest/runner.py` |
| Position closing | `ai-trader-api/src/portfolio/paper-trading.service.ts` |
