# 04 — Signal Integrity

**Aim:** every stored signal is one distinct trade, decided on finished data.

**Status:** DONE (2026-07-26), with tests.

---

## Why it matters

### One trend gets counted as twenty trades

The screener re-evaluates every symbol every 15 minutes. If a setup persists —
and a decent trend persists for hours — it regenerates each time, and **each copy
is stored and scored as an independent trade.**

A single two-hour trend can therefore occupy 20% of a 100-trade performance
sample. If it wins, the win rate is inflated by one lucky idea; if it loses, the
reverse. Either way the statistic is measuring *persistence*, not *accuracy*, and
the effective sample size is far smaller than the row count suggests.

> **Not the same as the SQS fix.** A unique index on
> `(symbol, generatedAt, direction)` was added during the code audit. That is
> idempotency for at-least-once queue redelivery — the *identical* message
> arriving twice. This is a *different* signal, generated 15 minutes later, that
> happens to describe the same idea. The index does not touch it.

### Indicators are computed on a candle that hasn't finished

Indicators read `iloc[-1]` — the last row. For intraday yfinance data that row is
a **partially-formed bar**: a 15-minute candle that is currently 4 minutes old,
on a feed that is itself 15–20 minutes delayed.

Its high, low and close will all change before it closes. So RSI, MACD,
SuperTrend and the rest are being computed on a number that does not exist yet,
and a signal can fire on a "breakout" that unwinds before the bar completes.

This is the intraday equivalent of reading a partially-written file.

### The confluence gate votes BUY at RSI 85

The gate requires ≥75% of rule-based indicators to agree with the LLM's chosen
direction. But RSI voting "BUY" simply means `rsi > 50` — so RSI at **85**, which
is a stretched, extended market, counts as a vote *for* buying. The gate is
selecting for maximum extension rather than filtering it.

A full fix (genuinely orthogonal inputs) is Phase 2. One cheap veto is worth
doing now.

---

## Tasks

- [x] **Deduplicate at ingest.** Suppress a new signal matching an existing one
      on `(symbol, direction, entry rounded to ~0.5%)` within a ~4-hour window.
      Do it at ingest in `signals.service.ts` so the stored data is clean and
      every downstream statistic inherits the fix. **~half a day.**

- [x] **Drop the incomplete bar.** Before computing indicators, drop the last row
      unless it is known-closed. **~1 hour.**

- [x] **Reject stale data.** If the newest *closed* bar is older than two
      intervals, return no signal with an explicit reason rather than computing
      on stale prices. `SignalResult` already carries machine-readable reasons —
      add `stale_data`.

- [x] **Add an RSI extreme veto.** Reject a BUY at RSI > 75 and a SELL at
      RSI < 25, regardless of what the rest of the confluence says. Goes in
      `app/signals/validation.py` next to the existing gates, with a test.
      **~1 hour.**

**Effort:** ~1 day total.

---

## Files

| | |
|---|---|
| Dedupe | `ai-trader-api/src/signals/signals.service.ts` |
| Bar handling | `ai-trader-signals/app/signals/service.py`, `indicators.py` |
| Confluence gate | `ai-trader-signals/app/signals/validation.py` |
| Tests | `ai-trader-signals/tests/test_validation.py` |
