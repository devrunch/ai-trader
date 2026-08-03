# Algo Simulation

Modelling what a strategy actually does to your money — before it does it with real money.

---

## 1. Backtest vs. simulation

These get conflated, and the difference matters:

| | Backtest | Simulation |
|---|---|---|
| Question | "Did these entry/exit rules produce winning trades?" | "What would have happened to my account?" |
| Output | Win rate, trade list | Equity curve, drawdown, risk of ruin, capital efficiency |
| Models capital | No | Yes |
| Models position size | No | Yes |
| Models costs | No | Yes |
| Models concurrency | No | Yes |

**What exists today is a backtest, and a thin one.** `analysis._run_signals()` tracks percentage moves through a sequence of trades. It assumes: one position at a time, long-only, entered and exited at the closing price, with no capital constraint, no position sizing, no brokerage, no slippage. It reports win rate, trade count, and a compounded percentage return.

That is genuinely useful for comparing rule sets — and it is **not** a statement about what happens to an account. A strategy showing "+13% total return" there might, with realistic sizing and costs, be flat or negative. Two strategies with identical win rates can have wildly different drawdowns, and drawdown is what actually causes people to abandon a strategy or blow up.

---

## 2. What a real simulation must model

**Capital and position sizing.** Start with an account balance. Each trade takes a position sized by a rule — fixed amount, fixed percentage, or (best) risk-based sizing off the stop distance, which is the [`position_size` tool](00-agent-expansion-plan.md) in Phase 1. Cannot enter a trade without sufficient free capital.

**Transaction costs.** Brokerage, exchange fees, STT, stamp duty, GST. On Indian intraday equity these are small per trade but compound brutally at high trade frequency — a strategy taking 40 trades a day can be profitable before costs and clearly negative after. Any simulation that omits them is misleading, not approximate.

**Slippage.** Real fills differ from the printed close. A fixed assumption (e.g. a few basis points, or a fraction of the bar's range) is crude but far better than assuming perfect fills.

**Concurrency and portfolio constraints.** Multiple positions open at once, a cap on how many, and a cap on exposure to one sector or one correlated group. Today's engine can hold exactly one position and knows about exactly one symbol — a real strategy run across a 15-stock watchlist behaves nothing like that.

**Short positions.** The current engine is long-only; SELL signals cannot be simulated as actual short trades.

---

## 3. Metrics that matter

Win rate and total return are the least informative numbers in the set. What a trader actually needs to see:

| Metric | Why it matters |
|---|---|
| **Equity curve** | The shape tells you more than any summary statistic — steady climb vs. one lucky spike. |
| **Maximum drawdown** | Largest peak-to-trough fall. The number that determines whether a strategy is psychologically survivable. |
| **Expectancy per trade** | Average profit per trade in ₹ and in R (risk units). The core profitability number. |
| **Profit factor** | Gross profit ÷ gross loss. Below 1.0 = losing system, regardless of win rate. |
| **Sharpe / Sortino** | Return per unit of volatility; Sortino counts only downside volatility. |
| **Exposure time** | Percentage of time capital was actually deployed — a strategy earning 8% while invested 4% of the time is very different from one fully invested. |
| **Longest losing streak** | Determines whether a user will realistically stick with it. |
| **Return after costs** | Always shown alongside the before-costs figure, so the gap is visible. |

---

## 4. Simulation modes

### A. Realistic historical simulation
The upgrade to today's backtest: capital, sizing, costs, slippage, concurrency, shorts, and the full metric set above. Everything else builds on this.

### B. Monte Carlo robustness
Take the strategy's trade results and resample them thousands of times in random orders (and/or bootstrap with replacement) to produce a *distribution* of outcomes rather than a single history.

This directly answers the question the [signal-quality work](../signal-quality/01-findings.md) showed we cannot ignore: **"was this backtest just lucky?"** Instead of "+13% return, 34% win rate", the user sees: *"median outcome +9%, 5th percentile −4%, 95% of simulated runs had a maximum drawdown between 6% and 21%."* That reframes a single hopeful number as a risk range — and it costs almost nothing to compute, since it reuses trades already generated.

### C. Portfolio simulation
Run one strategy across many symbols, or several strategies together, sharing one capital pool. Surfaces effects invisible in single-symbol tests: signals competing for the same capital, correlated positions all losing simultaneously, and whether diversification actually smooths the equity curve.

### D. Forward paper simulation — **the missing middle layer**
A strategy runs on live market data going forward, placing simulated trades into a dedicated virtual account, tracked over days and weeks.

This is the proving ground between "the backtest looked good" and "trade this with real money", and it is the single most honest test available: it cannot be overfitted, because the data did not exist when the strategy was written. It reuses the existing paper-trading engine and the 15-minute screener cadence, with strategy-tagged orders kept separate from the user's manual trades.

### E. Replay simulation
Step through history bar by bar, watching the strategy trade on the chart in motion — pause, step, adjust speed. Primarily a comprehension and trust-building tool: seeing *where* a strategy entered and exited teaches far more than a summary table, and often reveals obviously broken behaviour that good-looking statistics hide.

### F. Stress scenarios
Re-run a strategy through deliberately chosen hostile conditions — a market crash window, a high-volatility regime, a flat/choppy period — to expose where it breaks. A strategy that only works in trending markets should be *known* to only work in trending markets.

---

## 5. Build order

1. **Realistic historical simulation (A)** — capital, sizing, costs, slippage, equity curve, drawdown. Upgrades every existing backtest result at once.
2. **Monte Carlo (B)** — cheap to add once (A) produces trade lists, and it is the strongest guard against presenting lucky results as skill.
3. **Chart visualisation of simulated trades** — entries, exits, and the equity curve rendered on-screen (reuses the [agentic charting](02-agentic-charting.md) rendering path).
4. **Portfolio simulation (C)** — needed before any multi-symbol strategy claim is credible.
5. **Forward paper simulation (D)** — needs strategy persistence and scheduled evaluation; the highest-value proof of a strategy's worth.
6. **Replay (E)** and **stress scenarios (F)** — comprehension and robustness polish.

---

## 6. Honest limits — what simulation cannot tell you

Worth stating plainly, because convincing-looking simulation output is precisely how retail traders get misled:

- **Fills are assumed, not real.** Simulations fill at a modelled price. Real orders face spreads, partial fills, and gaps. Wider stops and liquid large-caps are more forgiving; tight stops on illiquid stocks are where simulated and real results diverge most.
- **Liquidity is not modelled.** The simulation will happily "buy" a size the market could not actually absorb at that price.
- **Past regimes are not future regimes.** A strategy fitted through a trending period will look excellent and can fail immediately when the market ranges. This is what stress scenarios (F) and forward simulation (D) exist to expose.
- **Data quality bounds everything.** Current historical data comes from a free, delayed, adjusted source with a ~58-day intraday limit. Better data (a paid feed) would materially improve fidelity — the current source is adequate for relative comparison between strategies, not for precise absolute claims.
- **Optimised results are optimistic by construction.** Anything selected as "best of N" carries selection bias; out-of-sample and forward testing are the only real corrections. See the [overfitting guardrails](01-strategy-engine.md) — mandatory here too.

The right framing for users: **simulation ranks and screens candidates and reveals risk; it does not predict returns.** A strategy that fails simulation is reliably bad. A strategy that passes is merely *not yet disproven* — which is exactly why forward paper simulation (D) matters before real capital is ever involved.
