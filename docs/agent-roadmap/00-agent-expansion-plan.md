# AI Agent Expansion Plan

How to take the chat agent from "draws things on one chart" to a genuine trading co-pilot.

---

## 1. Honest baseline — what the agent can do today

**Five actions, all single-stock chart analysis:**
`draw_trendline` · `draw_support_resistance` · `draw_fibonacci` · `backtest_strategy` · `simulate_trade`

**The core limitation: the agent is blind to the user.** It cannot see your positions, cash, P&L, open orders, watchlist, or trade history — even though the platform already exposes every one of those through working APIs (`/api/paper/positions`, `/api/paper/portfolio`, `/api/paper/orders`, `/api/paper/trades`, `/api/watchlist`, `/api/market/quote`, `/api/market/news`). It also cannot *do* anything — it can describe a trade but not place one.

The result is an assistant that gives generically-correct chart commentary rather than advice grounded in what the user actually holds and risks.

**Second limitation: it is not really agentic.** The current design is single-shot — one LLM call returns a message plus a fixed list of actions, which the backend then executes. The agent cannot look something up, react to what it found, and then decide what to do next. (Note: a true tool-calling loop *has* already been built and proven for signal generation — `get_candles` — so the pattern is established and working; it simply hasn't been applied to chat yet.)

---

## 2. Architectural change: single-shot → multi-step tool-calling agent

Replace the "return a list of actions" design with the tool-calling loop already proven in signal generation:

```
user question
   ↓
agent reasons → calls a tool → sees result → reasons again → calls another tool
   ↓ (up to a capped number of rounds)
final answer + any chart drawings / executed actions
```

This is what makes the difference between *"here's what support and resistance are"* and *"I checked your positions — you're already long 3 IT stocks, and INFY is sitting right on support with earnings in 2 days; here's the sizing that keeps your risk at 1%."*

**Guardrails required (non-negotiable):**
- Hard cap on tool-call rounds (prevents runaway loops and cost blowups).
- Any tool that *executes* rather than reads (placing orders) must require explicit user confirmation before it fires — never let the model trade unprompted.
- Read-only tools and action tools must be clearly separated in the code, so a prompt-injection style failure can't turn a question into a trade.

---

## 3. Tool catalogue (grouped by what they let the agent do)

### A. Market data
| Tool | What it enables |
|---|---|
| `get_candles(symbol, interval, count)` | Inspect real price action at 1m/5m/15m/1h/1d. *Already built for signal generation — just needs exposing to chat.* |
| `get_quote(symbol)` | Live price, day change, volume. |
| `compare_symbols([a, b])` | Head-to-head: "which setup is better right now, RELIANCE or TCS?" |

### B. Analysis
| Tool | What it enables |
|---|---|
| `get_indicators(symbol, list)` | Any of ~277 indicators available in the existing library (RSI, MACD, Stochastic, Ichimoku, ADX, OBV, MFI, CCI, Keltner, Donchian…). Today only ~8 are wired. |
| `detect_patterns(symbol)` | Candlestick patterns (Doji, Hammer, Engulfing, Marubozu, Inside Bar, Morning/Evening Star). **Correction:** an earlier draft claimed 62 patterns ship free with the current dependency — that is wrong. `pandas_ta` provides only three (doji, inside, z) unless the TA-Lib C library is installed. Rather than add that dependency, the ~10 patterns traders actually use are implemented natively in `app/signals/indicators.py`. |
| `find_levels(symbol)` | Support/resistance, trend lines, Fibonacci. *Exists.* |
| `backtest_strategy(symbol, strategy)` | *Exists* — EMA cross, RSI, MACD, Bollinger. |
| `multi_timeframe_check(symbol)` | Does the 1h trend agree with the 15m setup? Classic professional discipline; currently impossible to ask. |

### C. Chart control
| Tool | What it enables |
|---|---|
| `draw(kind, …)` | Trend lines, rays, horizontal levels, Fibonacci, rectangles, arrows, text labels. The manual drawing rail already supports more shapes than the agent can currently draw. |
| `add_indicator_to_chart(name)` | "Show me RSI and Bollinger on this chart" — the chart already supports this; the agent can't trigger it. |
| `clear_drawings()` | Housekeeping. |

### D. Portfolio awareness — **the biggest missing capability**
| Tool | What it enables |
|---|---|
| `get_positions()` | "What am I holding?" |
| `get_portfolio_summary()` | Cash, invested, total P&L, return %. |
| `get_orders()` / `get_trades()` | Open orders and trade history. |
| `analyse_exposure()` | Concentration warnings — "68% of your book is banking stocks." |
| `review_performance()` | Patterns in the user's *own* trading: "your losers are held 4× longer than your winners." |

### E. Risk & sizing — **highest practical value per unit of effort**
| Tool | What it enables |
|---|---|
| `position_size(entry, stop, risk_pct)` | The single most valuable calculation in trading: *how many shares can I buy without risking more than 1% of my account?* Pure arithmetic, tiny to build. Traders are ruined far more often by bad sizing than by bad stock picks. |
| `portfolio_risk()` | Aggregate open risk if every stop triggered at once. |
| `what_if(scenario)` | "What happens to my book if the market drops 2%?" |

### F. Execution & monitoring
| Tool | What it enables |
|---|---|
| `place_paper_order(...)` | Closes the loop: analysis → decision → trade, without leaving the chat. **Must be confirmation-gated.** |
| `set_alert(symbol, condition)` | "Tell me if RELIANCE breaks 1300." Requires a background checker + notification path (neither exists yet). |
| `scan_watchlist(criteria)` | Idea generation at scale: "which of my 15 stocks are near support with rising volume?" |

---

## 4. Suggested build order

**Phase 1 — Make the agent aware and useful (highest value, all infrastructure already exists)**
1. Convert chat to the multi-step tool-calling loop (pattern already proven in signal generation).
2. Portfolio tools (D) — read-only, safe, transforms answer quality immediately.
3. Position sizing + risk tools (E) — trivial maths, outsized practical benefit.
4. Expose `get_candles` and multi-timeframe checks to chat (B) — already built, not yet wired.

**Phase 2 — Deepen the analysis**
5. Full indicator access + candlestick pattern detection (B) — free with the current dependency.
6. Expanded chart drawing + indicator toggling from chat (C).
7. `compare_symbols` and `scan_watchlist` (A/F) — turns the agent into a screener.

**Phase 3 — Let it act**
8. Confirmation-gated paper order placement (F).
9. Price alerts (F) — needs a background job and a notification channel; largest new infrastructure.

**Phase 4 — Reflection**
10. `review_performance` on the user's own trade history (D) — the "why do I keep losing?" feature, genuinely rare in retail tools.

---

## 5. What this does *not* fix

Worth stating plainly: **none of this makes the underlying trade signals more accurate.** Signal quality is a separate, measured problem tracked in [../signal-quality/](../signal-quality/00-index.md) — currently sitting near breakeven, with the finding that an LLM-per-decision architecture cannot be tuned measurably at feasible cost.

This roadmap makes the agent a far better *analyst, risk manager, and interface*. It does not turn a near-breakeven signal into a profitable one. Both tracks matter; they should not be confused with each other.
