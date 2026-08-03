# 05 — Honest Reporting

**Aim:** every number the product shows teaches the user something true.

**Status:** DONE (2026-07-27). Win rate coloured against computed breakeven, expectancy
and CI shown, small buckets suppressed, "confidence" renamed, in-sample caveat added.

---

## Why it matters

### The scoreboard is coloured against the wrong bar

This is the one that needs explaining, because the instinct is wrong.

**A good trading system does not need to win more than half the time.** What
matters is expected value per trade:

```
expectancy = win_rate × avg_win − loss_rate × avg_loss
```

If your average win is 3× your average loss, you break even at a **25% win rate**
and make money at 35%. Real trend-following funds run 30–40% win rates and are
very profitable. The inverse also holds: a 90%-win-rate system that occasionally
loses 20× its average win is a slow-motion disaster.

So every system has a **breakeven win rate** determined by its own win/loss ratio
and its costs. That is the only meaningful bar.

**For this system, breakeven is ~34.6%.**

The Performance page colours the win rate red below **50%**
(`signals/page.tsx:260` and `:288`). A genuinely profitable 45% renders as
failure. Every user who looks at that page learns the wrong mental model, and
then evaluates the product against a standard it was never designed to meet.

### Buckets of one trade display as 100%

The per-symbol and per-confidence breakdowns show any bucket, including ones with
a single trade. A row reading "RELIANCE — 100%" off one lucky trade looks like a
finding. It is noise rendered as a statistic.

### "Confidence" is an uncalibrated word

The pre-market bias score sums hand-picked weights and labels anything above 1.2
"high confidence." Nothing has ever measured whether it predicts anything. In a
financial product, "confidence" implies calibration — that 80% confidence is
right about 80% of the time. Nothing here supports that.

### Disclaimers are on two pages

Present on the landing and brief pages. Missing from signals, terminal and
portfolio — the three pages where a user is actually looking at trade
suggestions.

---

## Tasks

- [x] **Colour the win rate against computed breakeven, not 50%.** Compute it
      from the actual win/loss ratio and cost model, and show it beside the win
      rate so the comparison is visible rather than implied.

- [x] **Show sample size and expectancy next to the win rate.** Expectancy is the
      number that decides whether the system makes money. It should not be
      hidden behind a win-rate percentage.

- [x] **Show the confidence interval, not just the point estimate.** The current
      95% CI on expectancy is `[−0.31%, +0.14%]` — it spans zero. Presenting
      `−0.086%` alone implies a precision the data does not support.

- [x] **Suppress buckets with n < 20.** Or render them greyed with an explicit
      "insufficient sample" label. Never as a percentage.

- [x] **Rename or measure "confidence."** Either measure the bias score against
      next-day Nifty open gaps and publish the real hit rate, or drop the word
      and call it a summary. Renaming is a perfectly acceptable Phase 1 answer.

- [x] **Disclaimers on every page showing trade suggestions.** Analysis and paper
      trading, not investment advice. No profitability claims anywhere in the UI
      or marketing copy.

- [x] **State the in-sample caveat wherever accuracy appears.** Every threshold
      was tuned on the only 58 days of history yfinance provides, so the measured
      number is in-sample and the true number is worse.

**Effort:** ~1 day. Mostly frontend.

---

## The number to quote

> n=99, 30.3% win rate against a 34.6% breakeven, expectancy −0.086% per trade,
> 95% CI `[−0.31%, +0.14%]`.
>
> In plain terms: **not shown to make money, not shown to lose money either.**
> The point estimate leans negative and that is what we act on.

---

## Files

| | |
|---|---|
| Performance page | `ai-trader-frontend/app/dashboard/signals/page.tsx` |
| Summary computation | `ai-trader-api/src/signals/signals.service.ts`, `eval.ts` |
| Bias score | `ai-trader-signals/app/market/global_cues.py` |
