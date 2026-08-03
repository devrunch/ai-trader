# Agent Roadmap

Plans for expanding the AI chat agent from a chart-analysis assistant into a trading co-pilot.

| # | Document | Contents |
|---|---|---|
| 00 | [Agent Expansion Plan](00-agent-expansion-plan.md) | Current baseline, the shift to multi-step tool calling, full tool catalogue (market data, analysis, charting, portfolio awareness, risk/sizing, execution), phased build order |
| 01 | [Strategy Engine](01-strategy-engine.md) | Agent-built trading strategies — the rules-not-code safety decision, strategy DSL, capability levels, overfitting guardrails, auto-execution limits |
| 02 | [Agentic Charting](02-agentic-charting.md) | Custom indicators and chart drawings from plain language — the agentic answer to Pine Script; visual DSL, shared condition engine, rendering path, safety |
| 03 | [Algo Simulation](03-simulation.md) | Modelling what a strategy does to real money — capital, sizing, costs, drawdown; Monte Carlo robustness, portfolio and forward paper simulation, replay, stress scenarios, and what simulation cannot tell you |
| 04 | [Trader Questions](04-trader-questions.md) | Specification by example — what an experienced trader actually asks, which tools answer it, and the quality bar for responses. Doubles as a test script per phase |
| 05 | [Delivering the Client Vision](05-delivering-client-vision.md) | How to build what the client actually asked for — pre-market overnight pipeline, morning report, profile/allocation engine, and which delivery pattern each needs (batch vs agent vs rules engine vs digest) |
| 06 | [UX Flows](06-ux-flows.md) | Screen-level design — IA change (Signals → Brief), time-aware landing, morning routine, onboarding/profiling, allocation management, weekly review, brief→agent→action drill-down, notification budget |

## Build status

**Phase 1 — Aware + agentic** ✅ **shipped**
Chat is now a multi-step tool-calling agent (capped at 6 rounds) with portfolio/position/P&L awareness, position sizing, aggregate risk, multi-timeframe candles, levels, backtests and chart drawing. `userId` comes from the verified JWT and portfolio access runs over an internal endpoint gated by a shared secret, so one user's agent cannot read another's account.

**Phase 2 — Deeper analysis** ✅ **shipped**
26-indicator allow-listed catalogue, native candlestick pattern detection, symbol comparison, watchlist screening, and agent-driven chart indicator toggling.

*Original Phase 2 scope, for reference:*
Full indicator access, natively-implemented candlestick pattern detection, expanded chart drawing and indicator toggling from chat, stock comparison, watchlist scanning.

*Note on pattern detection:* early planning assumed 62 candlestick detectors came free with `pandas_ta`. They do not — only three (doji, inside, z) are available without the TA-Lib C library. The ~10 patterns traders actually use are now implemented natively instead, avoiding a heavy dependency and keeping the definitions explicit.

**Phase 3 — Condition engine** ✅ **shipped** ([01](01-strategy-engine.md) + [02](02-agentic-charting.md))
`app/signals/conditions.py` is the validated DSL: an allow-listed series layer, bounded parameters, depth and node caps, unknown fields rejected rather than ignored, and an evaluator that turns a condition tree into boolean series over the bars. `run_strategy()` wires it to the backtester, taking the stop from the spec's own `stop_loss` node (ATR-multiple or percent), filling entries at the next bar's open and deducting round-trip costs. Exposed to the agent as `build_strategy`, which returns the exact validation error and the available indicator list when a spec is rejected — that is the model's feedback loop.

**Capability level 2 of 5** from [01](01-strategy-engine.md) is complete: the user describes rules in their own words and gets a real backtest. Levels 3–5 (parameter sweep with overfitting guardrails, persistence + scheduled monitoring, auto-traded on paper) are not built.

This is the one capability area where quality is *cheaply and rigorously measurable*, because rule-based strategies need no LLM in the evaluation loop. 30 tests cover it, and the safety tests come first: hostile indicator names, `getattr` reach, oversized and over-deep trees, out-of-range parameters, and unknown-field rejection.

**Still to build on top of it** — the same engine drives custom chart drawings ([02](02-agentic-charting.md)), custom alerts, and custom screeners. None of those are wired yet; each is now a thin layer rather than a new system.

**Alongside — simulation** ([03](03-simulation.md))
Today's backtester tracks percentage moves only: one position, long-only, no capital, no costs, no drawdown. Turning that into a real simulation (capital, position sizing, transaction costs, equity curve, maximum drawdown, Monte Carlo robustness) upgrades every strategy result the platform produces, and is the difference between "these rules won often" and "here is what would have happened to your account."

## Standing design rules

Three decisions apply across every document here and should not be revisited casually:

1. **The agent emits declarative specifications, never executable code.** Having an LLM write code that the server runs is remote code execution — one prompt injection compromises the database and all stored credentials. Validated JSON specs stay expressive without that risk.
2. **All price geometry is computed server-side from real data.** The agent supplies intent; deterministic maths supplies coordinates. This is what stops the model hallucinating price levels, and it is already the pattern used for support/resistance and trend lines.
3. **No performance number is shown without its risk context.** Win rate and total return alone are the least informative figures available and the easiest to mislead with. Anything presented to a user carries costs, drawdown, sample size, and — where a search was involved — how many variants were tried. The [signal-quality investigation](../signal-quality/01-findings.md) documented exactly how badly small samples and uncontrolled comparisons mislead; the same discipline applies to every strategy and simulation result.

## Related

Signal accuracy is a separate track — see [../signal-quality/](../signal-quality/00-index.md). Improving the agent's capabilities does not improve signal accuracy, and the two should not be conflated.
