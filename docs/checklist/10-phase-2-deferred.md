# 10 — Phase 2 (Deferred)

**Aim:** record what is genuinely wrong but cannot be fixed with free data or
without a trained model — so it is not rediscovered as a surprise later.

**Status:** all deferred by decision, not oversight.

**Phase 2 scope:** paid market data, a trained model, real accuracy, forex and
other markets.

---

## The constraint behind almost all of these

**yfinance gives us 58 days of 15-minute history.** Free, unofficial, ~15–20
minutes delayed, aggressively rate-limited, no SLA. Nearly every item below is
that limit expressed a different way.

The data layer sits behind a provider `Protocol`
(`app/market/providers/base.py`), so swapping in a paid feed is genuinely a
one-line change. That was designed for; it is the part of the architecture most
worth preserving.

---

## Deferred items

### The backtest cannot be used for tuning

This is the most important entry here and the strongest argument for a trained
model.

At ~100 resolved trades, the smallest difference the backtest can detect is
**~18 percentage points**. The gap we need to close is **~2 points**. Detecting
that reliably would need roughly **7,900 trades per experiment** — and every
trade costs an LLM call.

So the backtest is a **correctness tool** — it has caught three real bugs — and
**not an optimisation tool**. Do not tune a threshold against it; any improvement
you appear to measure is noise.

A trained classifier changes this completely: it can be evaluated over tens of
thousands of trades for free, which is the only way this system's accuracy ever
gets measured properly.

### Everything is in-sample

Every threshold was tuned on the only 58 days available. The measured expectancy
is therefore in-sample, and the true out-of-sample number is worse — always is.
Needs deeper history, which means a paid feed. Until then, state the caveat
wherever the number appears (see [05](05-honest-reporting.md)).

### The sample is smaller than it looks

99 trades from a single 2.5-month regime across 25 correlated large caps is
effectively **n ≈ 64** independent observations. The 95% confidence interval
spans both zero and the breakeven win rate.

Nothing to fix in code. Publish the interval and stop treating the point estimate
as settled.

### Betas are not statistically significant

The sensitivity engine labels a relationship "meaningful" at correlations that,
at n≈25 daily observations, cannot be distinguished from zero. It also **sums
univariate betas across correlated drivers as if they were independent** —
NASDAQ, crude and USD/INR all move together, so adding their individual effects
double-counts.

Needs longer history and a proper multivariate regression.

*(The one thing already fixed: US indices are lagged one day while crude/FX/Asia
are contemporaneous, because of session alignment. Applying a blanket lag-1
destroyed the crude signal — measured on BPCL, lag-1 correlation −0.11 vs
same-day −0.48.)*

### Asian market data is a session stale

Asia carries the highest weight in the pre-market bias model, but on daily bars
at 06:30 IST its data is one session older than the US data it is being combined
with. Fixing this properly needs intraday global quotes.

### The confluence gate is four correlated votes

EMA, SuperTrend, MACD and RSI all read the same trend on the same close series.
Requiring 3-of-4 agreement after an ADX filter therefore selects for **maximum
extension** rather than adding independent confirmation — they agree most
strongly exactly when a move is most stretched.

Replacing them with genuinely orthogonal inputs — volume profile, relative
strength versus Nifty, VWAP distance — is model work.

> One cheap exception is already pulled forward into
> [04](04-signal-integrity.md): an RSI > 75 / < 25 veto.

### Illiquid symbols are not screened

`dropna()` silently removes zero-volume bars, leaving indicators computing across
gaps as if no time passed. There is no liquidity screen. Mitigated for now by
keeping the universe to liquid large caps, which the brief already does.

### FinBERT runs in live signals but not in the backtest

The measured performance therefore does not describe the live system. Fixing it
needs historical point-in-time news, which NewsAPI does not provide — and its
keyword search on tickers like "ITC" returns mostly noise anyway.

### LLM timestamp leakage

The backtest shows the model real dates and real symbol names for periods almost
certainly inside its training data. **No amount of slicing discipline closes
this** — the model may simply know what happened next. It is an inherent limit of
LLM-in-the-loop backtesting and another argument for a trained model.

### Accuracy itself

Currently below breakeven once costs are counted. The right fix is a trained
classifier evaluated over thousands of trades, not more prompt tuning.
