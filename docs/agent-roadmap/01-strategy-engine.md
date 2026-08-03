# Agent-Built Strategies ("make algos and run them")

Letting the agent design, test, save, and run trading strategies — safely.

---

## 1. Why this is a strong fit

Two things make this unusually well-suited to what already exists:

**The backtest engine already accepts arbitrary strategies.** `analysis._run_signals(df, entries, exits)` takes *any* pair of boolean entry/exit series and simulates the run. Today only four hardcoded strategies feed it (EMA cross, RSI, MACD, Bollinger). Anything that can produce those two boolean series plugs straight in — no rewrite needed.

**It sidesteps the measurement problem that blocks signal tuning.** The [signal-quality investigation](../signal-quality/01-findings.md) found that an LLM-per-decision architecture cannot be tuned measurably — you'd need ~7,900 LLM-driven trades per experiment to detect the effect sizes that matter. A *rule-based* strategy has no LLM in the evaluation loop: once the agent emits a rule specification, backtesting it over tens of thousands of historical trades costs nothing and takes seconds, and is perfectly repeatable. **The agent designs; deterministic maths evaluates.** That is exactly how real systematic trading desks work, and it means strategy quality here is genuinely measurable in a way raw LLM signals are not.

---

## 2. The critical safety decision: rules, not code

The obvious naive implementation is to have the LLM write Python and execute it. **This must not be done.** Executing model-generated code is arbitrary remote code execution — a single prompt injection, or simply a hallucinated `import os`, compromises the server, the database, and every stored credential. There is no sandbox configuration that makes this a good trade for this use case.

**Instead: a constrained strategy specification (a JSON DSL).** The agent emits a declarative rule spec; the backend validates it against a strict schema and interprets it with known-safe operations. The agent never supplies executable code — only data describing which known indicators to combine and how.

```json
{
  "name": "RSI dip in uptrend",
  "entry": {
    "all": [
      { "indicator": "rsi", "params": { "length": 14 }, "op": "<", "value": 35 },
      { "indicator": "ema", "params": { "length": 50 }, "op": "below", "compare_to": "close" }
    ]
  },
  "exit": {
    "any": [
      { "indicator": "rsi", "params": { "length": 14 }, "op": ">", "value": 65 },
      { "type": "stop_loss", "atr_multiple": 1.5 },
      { "type": "take_profit", "atr_multiple": 3.0 }
    ]
  }
}
```

**Validation requirements:**
- Indicator names must be on an allow-list (drawn from the ~277 available in the existing library).
- Numeric parameters bounded to sane ranges (no `length: 10_000_000`).
- Condition tree depth and node count capped.
- Unknown fields rejected outright rather than ignored.

This keeps the whole space expressive enough for real strategies while remaining provably safe to execute.

---

## 3. Capability levels (increasing ambition)

| Level | What the user can ask | What it needs |
|---|---|---|
| **1. Parameterised** | *"Backtest EMA cross but with 5/13 instead of 9/21"* | Expose parameters on the four existing strategies. Small change. |
| **2. Composed rules** | *"Buy when RSI drops under 30 while price is above the 50-EMA, exit at RSI 65 or a 1.5×ATR stop"* | The JSON DSL above + an interpreter that turns it into entry/exit boolean series. **This is the core build.** |
| **3. Optimised** | *"Find the best RSI thresholds for RELIANCE"* | Parameter sweep over the DSL, ranked by expectancy. Cheap — no LLM calls. Requires overfitting guardrails (§4). |
| **4. Saved & monitored** | *"Save this as 'my dip strategy' and tell me when it triggers on my watchlist"* | Persistence (a strategies collection), plus a scheduled evaluator reusing the existing 15-minute screener cadence. |
| **5. Auto-traded** | *"Run this strategy live on paper money"* | Strategy-driven paper order placement. Highest risk; needs hard limits (§5). |

---

## 4. Overfitting guardrails — mandatory, not optional

An optimiser searching hundreds of parameter combinations **will** find something that looks excellent purely by chance. Presenting that to a user as "this strategy wins 78%" would be actively harmful — it is the single most common way backtested strategies mislead people.

Required protections before any strategy result is shown:
- **Out-of-sample split.** Optimise on one period, report performance on a period never used for fitting. Show *both* numbers.
- **Walk-forward validation.** Reuse the existing walk-forward driver: repeatedly fit on a window, test on the following window.
- **Minimum trade count.** Refuse to report statistics below a threshold (~30 trades); a 90% win rate over 6 trades is noise. The [signal-quality work](../signal-quality/01-findings.md) already demonstrated exactly how badly small samples mislead — the same lesson applies with full force here.
- **Report expectancy and win/loss ratio, not just win rate.** A 30% win rate at 3:1 reward is excellent; a 70% win rate at 1:4 is ruinous.
- **Always show the parameter search size.** "Best of 200 combinations tested" is essential context for judging a headline number.
- **Realistic costs.** Include brokerage, and ideally slippage — a strategy that trades 40 times a day can look profitable purely from ignoring transaction costs.

---

## 5. Safety limits for live/auto execution (Level 5)

- Paper trading only until explicitly and separately authorised for real money.
- Per-strategy caps: maximum position size, maximum concurrent positions, maximum daily loss.
- A global kill switch that halts all strategy-driven trading instantly.
- Every strategy-placed order tagged with its originating strategy ID, for auditability.
- No strategy may be auto-enabled straight from a backtest result — the user must explicitly activate it after seeing out-of-sample numbers.

---

## 6. Suggested build order

1. **Strategy DSL + interpreter + schema validation** — the foundation everything else needs.
2. **Agent tool: `build_strategy(description)`** — natural language → validated rule spec, shown back to the user in plain English for confirmation before running.
3. **Agent tool: `backtest_strategy(spec, symbol)`** — reuse the existing engine; add out-of-sample splitting and cost modelling.
4. **Chart integration** — plot the strategy's entry/exit points on the chart, so the user can see *where* it traded, not just summary statistics.
5. **Parameter optimisation + walk-forward validation** — with every guardrail from §4 enforced.
6. **Persistence** — save, name, list, edit, delete strategies.
7. **Scheduled monitoring** — evaluate saved strategies on the watchlist each cycle; notify on trigger.
8. **Paper auto-trading** — last, behind every limit in §5.

---

## 7. Example of the target experience

> **User:** build me a strategy that buys dips in an uptrend
>
> **Agent:** *(calls `build_strategy`)* Here's what I've built — buy when RSI(14) falls below 35 while price holds above the 50-EMA (dip inside an uptrend), exit at RSI 65, with a 1.5×ATR stop and 3×ATR target. Want me to test it?
>
> **User:** yes, on my watchlist
>
> **Agent:** *(calls `backtest_strategy` per symbol)* Tested across your 15 stocks over 18 months.
> In-sample: 34% win rate, 2.6:1 reward/risk, +0.31% expectancy per trade, 214 trades.
> **Out-of-sample: 31% win rate, +0.19% expectancy, 88 trades** — weaker, but still positive, which is what matters.
> Best on RELIANCE and HDFCBANK; consistently loses on ITC. Costs included.
> I've marked the entries and exits on the chart. Want me to save it, or try tightening the stop?

That is a meaningfully different product from "here's what RSI means."
