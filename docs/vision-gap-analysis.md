# Vision vs. Build — Gap Analysis

Comparing the client's stated product vision ([client-expects.md](client-expects.md)) against what actually exists today.

**Summary: the built product is a strong intraday trading terminal. The stated vision is a pre-market, multi-asset, personalised investment advisor. These overlap by roughly a third.** The differences are not polish items — several are different product shapes. Better to surface that now than after more build.

---

## 1. The client's core mental model

Quoting the vision doc directly, because the specific wording matters:

> *"To check the best available trades for that day **before the market opens** and execute them as the market opens and get profitable return for the day."*

> *"Provide the best results of the trades **before the Indian market opens** and the analysis of **NASDAQ and other major markets**… The analysis can be based on US stock market as it's opened when Indian market is closed."*

> *"USP of the product — **The diversification of funds** and suggesting trade (Signals) for equity market via AI **before the market opens**."*

Three things repeat throughout: **pre-market timing**, **global markets driving Indian signals**, and **multi-asset fund diversification with client profiling**.

---

## 2. Where we stand

| Client expectation | Status | Reality |
|---|---|---|
| Signals ready **before market open** | ❌ **Not built** | The screener runs `*/15` minutes, **09:00–15:59 IST** — i.e. *during* the session. Market opens 09:15. This is an intraday product, not a pre-market one. |
| **NASDAQ / global market** analysis driving Indian calls | ❌ **Not built** | No US-market pipeline, no overnight analysis, no linkage from US close → Indian open. The data layer *can* fetch US symbols, but nothing analyses them. |
| **Geopolitical / world-event** analysis | ⚠️ **Partial** | News sentiment (FinBERT) exists per-symbol, but requires a news API key that isn't active. No geopolitical or macro-event reasoning. |
| **Multi-asset**: equity, forex, mutual funds, real estate, crypto | ❌ **Equity only** | NSE/BSE equities only. No forex, MF, real estate or crypto. |
| **Client profiling** — income, savings, risk appetite, target returns | ❌ **Not built** | Nothing captures any of this. No questionnaire, no risk profile, no suitability model. |
| **Fund diversification** recommendations | ❌ **Not built** | Described in the vision as *the* USP. Does not exist in any form. |
| **Long-term investment** suggestions | ❌ **Intraday only** | All signal logic, stops and targets are intraday-scoped. |
| **Cross-border investment** | ❌ **Not built** | — |
| **Weekly performance emails** | ❌ **Not built** | No notification or email infrastructure. |
| Buy/sell/hold signals for Indian equity | ✅ **Built** | Working, though accuracy sits near breakeven (see below). |
| Charting / analysis terminal | ✅ **Built, strong** | Not requested in the vision doc, but genuinely valuable. |
| AI chat analyst (16 tools, portfolio-aware) | ✅ **Built, strong** | Beyond the stated scope. |
| Paper trading | ✅ **Built** | Not in the vision doc; useful for demonstrating without risk. |

---

## 3. The three gaps that matter most

### Gap 1 — Timing: intraday vs. pre-market
The client's mental model is *"decide before open, execute at open."* We built *"watch the market live and react."* Those are different products with different architectures: a pre-market product needs an overnight batch job that analyses the previous US session and overnight news, then publishes a ranked list of the day's candidates before 09:15.

**The good news:** this is the most fixable of the three. The signal engine, indicators and backtesting all exist — it primarily needs a rescheduled job that runs pre-open, plus daily-timeframe logic instead of 15-minute logic.

### Gap 2 — The USP does not exist
The vision names **fund diversification and client profiling** as the differentiator against competitors — not the signals themselves. That whole side of the product (risk questionnaire, suitability model, asset-allocation recommendations across equity/forex/MF/real-estate/crypto) has zero implementation. It is also a materially different discipline from signal generation, and in India, personalised investment advice runs into SEBI Registered Investment Adviser regulation — worth checking before building, not after.

### Gap 3 — The promise vs. measured performance
The vision states the aim as *"get profitable return for the day"* and *"stabilize the investment and bring the profit with the lowest possibility of loss."* Our own walk-forward testing puts current signal accuracy at **29.6% win rate against a 31.3% breakeven — slightly negative expectancy** ([signal-quality findings](signal-quality/01-findings.md)).

The engineering here is sound and the gap is small, but the product cannot honestly market "profitable returns" at this accuracy. This needs to be either solved (trained model, better data) or the messaging adjusted. Marketing a losing signal as profitable would be both an ethical and a regulatory problem.

---

## 4. What was built that the vision didn't ask for

Worth stating plainly, because it isn't waste — it's just unbudgeted scope:

- A professional charting terminal (TradingView-style, drawing tools, 26 indicators)
- An agentic AI analyst that can read the user's portfolio, size positions by risk, screen a watchlist, detect patterns and draw on charts
- A paper-trading engine
- A signal accuracy measurement framework

These make the product demonstrably real and are the strongest assets for a demo. They just don't advance the *stated* USP.

---

## 5. Recommendation

**Ask the client to confirm which product they want next**, because the honest answer is that these are near-independent tracks:

1. **Pre-market pivot** — reschedule the screener to run overnight/pre-open, add US-market and overnight-news analysis, shift to daily-timeframe signals. Directly serves the core mental model. Moderate effort, mostly reuses existing machinery.
2. **Diversification & profiling** — risk questionnaire, client profile, multi-asset allocation. This is the stated USP and is a *new product surface*, not an extension of the terminal. Also needs a regulatory check (SEBI RIA).
3. **Signal quality** — get expectancy positive before making performance claims. Blocking for any marketing that promises returns.
4. **Continue the terminal/agent track** — the strongest demo material, but not what the vision doc asks for.

My recommendation, if forced to pick an order: **(3) then (1) then (2)** — fix the accuracy that everything else's credibility rests on, then move the signals to pre-market where the client's mental model lives, then decide whether the diversification product is a genuine build or a phase-2 story. Track (4) continues as the demo surface regardless.

**The thing to avoid** is building more of (4) on the assumption it satisfies the vision. It doesn't, and the gap will only get more expensive to close.
