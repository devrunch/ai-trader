# 13 — Stale Data

**Aim:** the user always knows how old the number in front of them is.

**Status:** mostly DONE (2026-07-26). Market state is global via the dashboard layout,
the delay is labelled, `degraded` is surfaced, and past-session signals are marked.
Poll-stops-when-closed not separately verified.

Source: [`docs/ux-audit.md`](../ux-audit.md) §4.

---

## Why it matters

Two facts the UI currently hides:

**The data is 15–20 minutes delayed.** yfinance is a free, unofficial feed. The
provider's own docstring says so. The terminal polls it **every 5 seconds** into
a live-ticking candle. The visual language — a ticking price, a moving candle —
communicates "real time." The data is a quarter of an hour old.

**The market is shut most of the time.** NSE trades 09:15–15:30 IST on weekdays
minus holidays: roughly 6 hours out of 24, five days in seven. The rest of the
time the UI shows the last available prices with no indication they are frozen —
a user opening the app at 8pm sees this afternoon's close presented exactly like
a live quote.

For a trading product this is the difference between a tool and a toy. A trader
who acts on a price they believe is live, that is 20 minutes old, has been misled
by the interface.

**The backend already solved this.** `/market/status` returns `nse_open`,
`is_holiday`, `is_square_off`, `next_open` and a `degraded` flag. The signals
service sets `degraded` when a data source fails. **The frontend's type
declaration drops these fields**, so the information reaches the browser and is
discarded.

---

## Tasks

- [x] **Add the dropped fields to the frontend types** and read them. The data is
      already on the wire.

- [x] **Show a persistent market-state indicator.** Open / Closed / Holiday /
      Pre-open, with `next_open` when shut. Every page that shows a price.

- [x] **Label the delay.** "Delayed ~15 min" next to live-looking prices. Once,
      visibly, not buried in a tooltip.

- [x] **Surface `degraded`.** When the backend says a data source failed, say so
      rather than rendering the last good value as current.

- [x] **Polling stops when the market is closed.** The terminal's 5-second quote
      poll already gated on `marketIsLive`; the Signals page's 30-second poll did
      not, and nothing generates signals outside market hours — so it spent rate
      limit re-fetching a list that could not have changed. Both now fetch once
      and stop until the market reopens.

- [x] **Show signal age.** Stored signals render with no timestamp, so a signal
      from yesterday looks like one from a minute ago. Show age, and visually
      de-emphasise signals older than the current session — an intraday signal
      from a previous session is not actionable.

**Effort:** ~1 day.

---

## Files

| | |
|---|---|
| Types dropping the fields | `ai-trader-frontend/lib/api.ts` |
| Market status | `ai-trader-signals/app/market/router.py`, `app/market/calendar.py` |
| Terminal poll | `ai-trader-frontend/app/dashboard/terminal/page.tsx` |
| Signals list | `ai-trader-frontend/app/dashboard/signals/page.tsx` |
