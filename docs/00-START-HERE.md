# Start Here

**Audience: a good programmer who has never traded.** No finance background
assumed. This file exists so the task lists in
[`checklist/`](checklist/00-index.md) make sense.

**The remaining work lives in [`checklist/`](checklist/00-index.md)** — one file
per topic, each stating its aim, why it matters, and its tasks.

---

## 1. What this is

An **intraday paper-trading and analysis product for Indian equities** (NSE/BSE).

Three things it does:

1. **Generates trade suggestions** ("signals") for a watchlist, using technical
   indicators plus an LLM that reasons over them.
2. **Provides an AI analyst you can chat with**, inside a charting terminal. It
   has tools — pull candles, compute indicators, find price levels, read your
   portfolio, size a position, run a backtest, draw on your chart.
3. **Lets you trade those ideas with fake money**, then reports honestly how the
   signals actually did.

"Intraday" means positions open and close the same day. Nothing is held
overnight. That constraint drives much of the design.

**It is not a broker, it places no real orders, and it is not a profitable signal
service.**

---

## 2. The aim

> **Phase 1: an AI analyst that shows its work and manages your risk properly,
> with a measured and published track record.**

Not "profitable signals before the open." The first is largely built and
defensible. The second needs Phase 2 — paid data, a trained model, and enough
trades to prove it.

Almost every remaining task exists because the system currently **makes a claim
it cannot support, produces something a user cannot act on, or reports a number
that misleads.** Those are honesty bugs. They are cheaper to fix than to explain
later.

---

## 3. Vocabulary

Not complicated, just unfamiliar. You will meet all of this in the checklist.

### Price data

| Term | Meaning |
|---|---|
| **OHLCV** | One time slice: **O**pen, **H**igh, **L**ow, **C**lose, **V**olume. |
| **Candle** / **bar** | One OHLCV row. A "15m candle" summarises 15 minutes. |
| **Interval** | Bar width: `1m`, `5m`, `15m`, `1h`, `1d`. The engine reasons on `15m`. |
| **LTP** | Last Traded Price — the current price. |
| **Session** | One trading day. NSE runs 09:15–15:30 IST, weekdays, minus holidays. |
| **Gap** | Price jumping between one session's close and the next session's open, with no trading in between. |

Data comes from **yfinance**: free, unofficial, ~15–20 min delayed, aggressively
rate-limited, and capped at **58 days** of 15-minute history. That single limit
shapes most of what can and cannot be proven — see
[checklist/10](checklist/10-phase-2-deferred.md).

### A trade

A signal is a proposal with four parts:

```
direction    BUY or SELL
entry        the price you get in at
target       the price you take profit at
stop         the price you cut the loss at
```

- **BUY** (going "long"): profit if price rises. Target above entry, stop below.
- **SELL** (going "short"): profit if price falls. Target below entry, stop
  above. Everything mirrored. **Shorting is not implemented in the paper
  account** — see [checklist/02](checklist/02-tradability.md).

The trade ends when price touches the target or the stop, whichever comes first.
That is the whole game.

| Term | Meaning |
|---|---|
| **Stop-loss** | The exit that caps your loss. Non-negotiable in a real system. |
| **R:R** | Reward-to-risk: `abs(target − entry) / abs(entry − stop)`. R:R of 2 = risking ₹1 to make ₹2. |
| **Position size** | How many shares. Derived from how much you can afford to *lose*, not what you can afford to buy. |
| **Slippage** | You rarely fill at exactly the price you wanted. The gap is a real cost. |
| **Square-off** | Closing everything before the session ends. |

### The two things that make backtests lie

This explains why parts of the code look paranoid.

**Gaps.** Your stop is at ₹95. Overnight, bad news. The stock *opens* at ₹90 — it
never traded at ₹95. You exit at ₹90, not ₹95. A naive backtest books every stop
at exactly the stop price and systematically understates losses. Our evaluator
fills a gapped stop at the bar's **open**.

**Costs.** A round trip on NSE costs ~**0.12%** — brokerage, STT, exchange fees,
GST, stamp duty, SEBI fee, plus realistic slippage. That sounds like a rounding
error. It is not: this system's average edge per trade is *smaller than 0.12%*,
so a zero-cost backtest **flips the sign of the result**.

Both live in
[`app/signals/backtest/evaluator.py`](../ai-trader-signals/app/signals/backtest/evaluator.py),
tested in `tests/test_evaluator.py`.

### Indicators

Deterministic functions over a DataFrame of bars. Each compresses price history
into a number. **None of them predict anything** — they describe what already
happened. Treat them as feature extraction.

| Indicator | One-line reading |
|---|---|
| **RSI(14)** | 0–100 momentum. >70 "overbought", <30 "oversold" — much weaker signals than those labels suggest. |
| **MACD** | Difference of two moving averages plus a signal line. Crossovers suggest momentum shifts. |
| **EMA20 / EMA50** | Exponential moving averages. EMA20 above EMA50 is conventionally "uptrend". |
| **ADX(14)** | 0–100 trend *strength*, direction-agnostic. Below ~20 means chop — no trend to trade. Used as a gate. |
| **ATR(14)** | Average True Range — typical bar size in rupees. **The important one:** our unit of "normal noise", used to size stops. A stop tighter than 1×ATR sits inside routine noise and gets hit regardless of whether the idea was right. |
| **SuperTrend** | ATR-based trend follower. Emits +1 or −1. |
| **VWAP** | Volume-Weighted Average Price. Must reset every session. |

Full catalogue (26):
[`app/signals/indicators.py`](../ai-trader-signals/app/signals/indicators.py).

---

## 4. The one genuinely counterintuitive thing

**Win rate is not the metric. Expectancy is.**

Every non-trader's instinct is "a good system wins more than half the time."
That is wrong, and building to it produces a worse system.

```
expectancy = win_rate × avg_win − loss_rate × avg_loss
```

If your average win is 3× your average loss, you break even at a **25% win rate**
and print money at 35%. Real trend-following funds run 30–40% win rates
profitably. Conversely, a 90%-win-rate system that occasionally loses 20× its
average win is a slow-motion disaster.

So every system has a **breakeven win rate**, set by its own win/loss ratio and
costs. That is the only bar that means anything.

**For this system, breakeven is ~34.6%** — which is why one of the open bugs is
that the UI colours the win rate red below 50%. See
[checklist/05](checklist/05-honest-reporting.md).

---

## 5. How well does it actually work?

**Not shown to make money. Not shown to lose money either.** The point estimate
leans slightly negative. That is the honest statement and should be the one used
everywhere.

Most recent walk-forward run, with costs and gap fills applied:

```
resolved trades          99
win rate              30.3%
avg win               +1.31%
avg loss              -0.69%
breakeven win rate    34.6%      <- the bar that matters
expectancy           -0.086%     per trade
95% CI on expectancy [-0.31%, +0.14%]   <- spans zero
```

Two consequences:

**The confidence interval spans zero.** At n=99 this is indistinguishable from a
coin flip in either direction. Don't let the point estimate be quoted as settled.

**The backtest cannot be used for tuning.** At ~100 trades the smallest
detectable difference is ~18 percentage points; the gap to close is ~2 points.
Detecting that needs ~7,900 trades per experiment, each costing an LLM call. So
it is a **correctness tool** (it caught three real bugs) and **not an
optimisation tool.** This is the strongest argument for a trained model, where
evaluating tens of thousands of trades is free.

---

## 6. What is built

Three services, Docker Compose locally.

```
ai-trader-frontend    Next.js 16      terminal, dashboard, brief
       |
ai-trader-api         NestJS + MongoDB
                      auth, paper trading, watchlists, signal storage,
                      WebSocket push, brief storage
       |
ai-trader-signals     FastAPI + Celery + Python
                      market data, indicators, signal generation,
                      chat agent, backtesting, morning brief
```

HTTP between services with a shared `INTERNAL_API_KEY`; **SQS** for signals → API.
LLM calls go to AWS Bedrock.

### Where things live in `ai-trader-signals`

| Path | Owns |
|---|---|
| `app/market/providers/` | Data vendors behind a `Protocol`. Swapping yfinance for a paid feed is one line. |
| `app/market/intervals.py` | The single interval→history-window table. |
| `app/market/calendar.py` | NSE hours, holidays, square-off. **Built, not yet wired.** |
| `app/signals/indicators.py` | The 26-indicator catalogue. One implementation. |
| `app/signals/analysis.py` | Support/resistance, trend lines, Fibonacci, strategy backtests. Pure. |
| `app/signals/validation.py` | The six gates deciding whether a signal is emitted. Pure. |
| `app/signals/backtest/evaluator.py` | **The** outcome evaluator. Gaps + costs. Pure. |
| `app/signals/agent/` | Chat agent: orchestrator, schemas, toolbox, portfolio tools. |
| `app/llm/client.py` | Bedrock client + key rotation. |

### The architectural rule worth preserving

> **Deterministic maths produces every number. The LLM only chooses and
> narrates.**

The agent never invents a price level, position size or statistic — it calls a
tool, the tool computes, the model interprets. This is why the LLM integration is
not the scariest part of the codebase, and why chart drawing cannot be
prompt-injected into executing code: the model emits validated JSON specs, never
executable strings.

### Testing

```
ai-trader-signals    83 tests    pytest, ruff clean, mypy clean
ai-trader-api        15 tests    jest, builds under full TS strict
```

Both suites written from zero. **If you are new, read the tests first** —
`tests/test_evaluator.py` and `tests/test_validation.py` teach the domain rules
faster than the source does.

---

## 7. Where to go next

| | |
|---|---|
| **[checklist/](checklist/00-index.md)** | **All remaining work.** One file per topic: aim, why, tasks. |
| [client-expects.md](client-expects.md) | What the client asked for. |
| [pre-deploy-checklist.md](pre-deploy-checklist.md) | The original trader audit, with fuller reasoning behind the checklist items. |
| [agent-roadmap/](agent-roadmap/README.md) | AI analyst feature plans. Partly implemented. |
| [vision-gap-analysis.md](vision-gap-analysis.md) / [client-status-report.md](client-status-report.md) | Promised vs built. |
