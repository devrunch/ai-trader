# Pre-Deploy Checklist — Phase 1

Triage of the [trader audit](signal-quality/01-findings.md) against Phase 1 goals: **solvable with yfinance data, agent front-and-centre, client expectations broadly met, accuracy allowed to be imperfect.** Perfect accuracy, better data, a trained model and other markets are explicitly Phase 2.

---

## Already fixed ✅

Done and verified during the audit response — no action needed.

| | Was |
|---|---|
| Transaction costs | Zero costs modelled anywhere; expectancy was measured frictionless |
| Gap-through-stop | Every stop booked at exactly the stop price, ignoring gaps |
| Entry validity | Model could propose an entry the market never touched; evaluator booked P&L anyway |
| Position sizing | Fabricated a ₹1,00,000 account when the portfolio fetch failed |
| Concentration | "1% risk" could mean 99% of the account in one stock |
| Order security | IDOR on execute + `LIMIT BUY @ ₹1` filled at ₹1 (unlimited money) |
| Brief publishing | 06:30 brief signals priced off yesterday's close were scored as live intraday |
| VWAP | `cumsum()` over 58 days — not intraday VWAP at all |
| Risk filters | Failed *open* — passed silently when their input was missing |
| Reproducibility | `temperature` never pinned; backtests weren't repeatable |

---

## MUST DO before deploy 🔴

Safety, correctness and honesty. All cheap, all solvable with current data.

**1. Daily loss limit and max concurrent positions.**
There is still no cap on how much can be lost in a day or how many positions can be open at once. At a 70% loss rate, a 10-trade losing streak is statistically expected inside a 108-trade sample; at 1% risk each that is −10%, and with 5–8 correlated Nifty positions open a single bad session takes them all out together. Add hard caps in `placeOrder`: max 5 concurrent positions, max 3% aggregate open risk, and a −3% daily loss limit that blocks new orders once breached. Roughly a day's work, and it is the difference between a bad week and a wiped account.

**2. Decide what happens with SELL signals.**
The engine emits SELL signals and scores them in the performance stats, but the paper account rejects any sell without an existing long — so roughly half the product's output cannot be acted on inside the product. Either implement intraday shorts (with margin and a forced square-off) or stop generating SELL signals for Phase 1 and say so. Given Phase 1 scope, **long-only is the honest choice**: filter SELLs out of the brief and the feed, and remove them from the reported win rate so the number describes what a user can actually trade.

**3. Stop reporting risk against stops that do not exist.**
`portfolio_risk` tells the user "if every stop hits you lose ₹X" — but the paper engine has no stop-loss order type and no monitoring loop, so no stop exists. Either add a real stop order type, or have the tool say plainly: *"You have no stops set — your open risk is unbounded."* The second is a one-hour fix and is the more useful answer anyway.

**4. NSE holiday calendar and correct market hours.**
The screener runs `*/15` between 09:00–15:59 Mon–Fri, so it fires before the open, after the close, and on every trading holiday — generating signals against stale data. Gate the Celery task on an NSE trading calendar and restrict to 09:20–15:15 IST. Half a day using `pandas_market_calendars` or a hardcoded holiday list.

**5. Intraday square-off.**
The prompt says "intraday positions only" but nothing enforces it — the walk-forward holds up to 10 hours across sessions, and the paper account holds indefinitely. Add a 15:20 IST square-off task that closes open paper positions, and cap `forward_bars` in the backtest at the session end. Without this the product's core claim ("trades for the day") is not true of its own behaviour.

**6. Deduplicate signals.**
The same setup regenerates every 15 minutes while it persists, and each copy is stored and scored as an independent trade — so a single trend that lasts two hours can occupy 20% of the performance sample. Dedupe on `(symbol, direction, rounded entry)` within a 4-hour window at ingest in `signals.service.ts`. Half a day, and it materially changes whether the published win rate means anything.

**7. Fix the win-rate display.**
The Performance page colours win rate red below 50%, but breakeven for this system is ~31% (37% with costs) — so a genuinely profitable 45% would render as failure and teach users the wrong mental model. Colour against the computed breakeven, and show sample size and expectancy next to it. Also suppress per-symbol and per-confidence buckets with n<20; right now rows with 1–2 trades display "100%" or "0%". An afternoon, and it is the difference between an honest scoreboard and a misleading one.

**8. Drop the incomplete bar.**
Indicators are computed on `iloc[-1]`, which for intraday yfinance is a partially-formed candle from a 15–20 minute delayed feed. Drop the last bar before computing, and reject if the newest closed bar is older than two intervals. One hour, and it removes a silent source of wrong signals.

**9. Atomic cash updates.**
`executeOrder` reads, checks, then writes `cashBalance` with no transaction, so two concurrent orders can both pass the balance check and overdraw the account. Replace with a `findOneAndUpdate` using `$inc` and a `cashBalance: {$gte: cost}` predicate. An hour.

**10. Legal disclaimers and positioning.**
Before anyone outside the team uses this: a visible disclaimer that this is analysis and paper trading, not investment advice; no claims of profitability anywhere in the UI or marketing; and a decision on SEBI positioning (the [gap analysis](vision-gap-analysis.md) covers why personalised advice is the regulated part). Not code, but genuinely blocking — and cheap if handled now rather than after launch.

---

## SHOULD DO — makes the agent look good 🟡

These are what a user actually sees. All yfinance-solvable, all Phase 1.

**11. Trend line direction is never checked against its own slope.**
`trendline()` decides "up" or "down" purely from whether price is above EMA20, then draws a line through the last two swing lows without verifying they ascend — so a descending pair gets labelled an uptrend, and the chart visibly contradicts its own label. Require the slope to match the label, require at least three touches, and reject when price has already closed through the line. Half a day, and it removes an error the user can see with their own eyes.

**12. Fibonacci anchors are inverted about half the time.**
The function always returns high-then-low regardless of which came first, so on any up-swing the retracement is drawn backwards and the 38.2% and 61.8% levels swap places (50% survives, which hides the bug). Order the two points chronologically and derive direction from that. One hour.

**13. The agent's backtest tool understates losses.**
`_run_signals` never closes the position still open at the end, so the worst trade — the one that never hit its exit — is silently excluded from every win rate the agent quotes. It also has no stop loss, so a position can run −20% and count as one open trade, and it enters at the close of the very bar that generated the signal, which is a one-bar lookahead. Close out the final position at the last bar, add a stop parameter, and fill at the next bar's open. A day, and it makes the agent's headline feature trustworthy.

**14. Support/resistance is stale and too wide.**
Levels are ranked purely by touch count with no recency weighting, so a level touched five times eight weeks ago outranks one touched twice yesterday; and the ±6% radius returns levels far beyond any intraday stop. Decay touch weight by age and tighten the radius to about twice the day's expected range. Half a day — this feeds both the chart and the signal prompt.

**15. `simulate_trade` will validate a nonsensical trade.**
It has no ordering guard, so a SELL with the stop below entry produces a healthy-looking reward:risk from what is actually a guaranteed loss, and it reports full notional as capital required for a short rather than margin. Port the ordering guard already used in signal validation and net costs into the P&L. Two hours.

**16. Brief ranking leads with its weakest input, and can return five versions of one bet.**
Candidates sort lexicographically on the global-alignment score, so a 0.66-confidence signal with a thin beta story outranks a 0.95-confidence one; and with 5 banks and 4 IT names in the universe, a single NASDAQ move can surface four correlated candidates that are one position, not four. Make the ranking a weighted blend rather than lexicographic, and cap the brief at one candidate per sector. Half a day — this is the client's headline deliverable, so it is worth getting right.

**17. Account value used for sizing can be hours stale.**
`totalValue` only updates on an explicit refresh call or the next fill, and nothing calls it on a schedule — yet every position-size recommendation scales off it. Refresh marks inside `getPortfolio`, or refuse to size when the mark is older than a few minutes. Two hours.

**18. Retire or rename the bias "confidence" label.**
The pre-market bias score adds hand-picked weights and calls `>1.2` "high confidence", with no backtest showing it predicts anything. Either measure it against next-day Nifty open gaps and publish the real hit rate, or drop the word "confidence" and present it as a summary. A day if measured, an hour if renamed — and renaming is perfectly acceptable for Phase 1.

---

## DEFER TO PHASE 2 🟢

Real findings, but they need better data, a trained model, or scope we have deliberately postponed.

**Out-of-sample validation.** Every threshold was tuned on the only 58 days yfinance provides, so the measured expectancy is fully in-sample and the true number is worse. Fixing this needs deeper history — a paid feed. Until then, state the in-sample caveat wherever the number appears.

**Sample size and statistical honesty.** 108 trades from one 2.5-month regime across 25 correlated names is effectively n≈64; the 95% confidence interval spans both breakevens. Nothing to fix in code — publish the interval and stop treating the point estimate as settled.

**Beta significance.** Betas are labelled "meaningful" at correlations that are not statistically distinguishable from zero at n=25, and univariate betas are summed across correlated drivers as if independent. Needs longer history and a multivariate regression — Phase 2, alongside better data.

**Asian market staleness in the bias model.** Asia carries the highest weight but, on daily bars at 06:30, its data is one session older than the US data. Fixing properly needs intraday global quotes.

**Confluence gate is four correlated votes.** EMA/SuperTrend/MACD/RSI all read the same trend on the same series, so requiring 3-of-4 after an ADX filter selects for maximum extension rather than adding confirmation. Replacing them with genuinely orthogonal inputs (volume, relative strength vs Nifty, VWAP distance) is model work — Phase 2. *One cheap exception worth doing now: an RSI>75 / <25 veto, since the gate currently votes BUY at RSI 85.*

**Illiquid-symbol handling.** `dropna()` silently removes zero-volume bars and leaves indicators computing across gaps; there is no liquidity screen. Phase 2 with better data — mitigate now by keeping the universe to liquid large caps, which the brief already does.

**FinBERT is in live signals but not in the backtest.** The measured number therefore does not describe the live system, and NewsAPI keyword search on tickers like "ITC" returns mostly noise anyway. Needs historical news data — Phase 2.

**LLM timestamp leakage.** The backtest shows the model real dates and symbol names for periods likely inside its training data. No amount of slicing discipline closes this; it is an argument for the trained model in Phase 2.

**Accuracy itself.** Currently below breakeven once costs are counted. Phase 2 is the right place for this, via a trained classifier that can be evaluated over thousands of trades for free — see the [measurement-feasibility finding](signal-quality/01-findings.md).

---

## Suggested order

1. Items **1–10** (must-do) — roughly a week. Nothing ships before these.
2. Items **11–18** (agent polish) — roughly a week. This is what makes demos land.
3. Ship Phase 1, honestly positioned: *analysis, paper trading and a capable AI analyst — not a profitable signal service.*
4. Phase 2: paid data, trained model, accuracy, forex and other markets.

The honest Phase 1 pitch is **"an AI analyst that shows its work and manages your risk properly, with a measured and published track record"** — not "profitable trades before the open." The second claim needs Phase 2 to be true; the first is already largely built.
