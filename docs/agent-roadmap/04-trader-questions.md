# What an Experienced Trader Will Ask — and How the Agent Should Respond

A specification by example. These are the questions a serious trader actually asks, the tools the agent calls to answer them, and the standard of answer we're aiming for. Doubles as a test script once each phase ships.

**Status key**
`NOW` works today · `P1` Phase 1 (tool-calling + portfolio + risk) · `P2` Phase 2 (indicators, patterns, screening) · `CE` condition engine (strategies/charting/alerts) · `SIM` simulation upgrade

---

## 1. Position sizing and risk — the questions that decide survival

**"How many shares of RELIANCE can I buy if I'm risking 1% with a stop at 1265?"** `P1`
→ Calls `get_portfolio_summary` (account equity) and `get_quote` (current price), then `position_size`.
> Your account is ₹1,00,000, so 1% is ₹1,000 of risk. RELIANCE is at 1273.50 and your stop at 1265 is 8.50 away — that's **117 shares**, costing ₹1,48,999. That exceeds your available cash, so you're capped at 78 shares by capital, which risks ₹663 (0.66%). Either accept the smaller size or widen the stop.

**"What's my total open risk right now?"** `P1`
→ `get_positions` + each position's stop → aggregate.
> Four open positions. If every stop triggered you'd lose ₹3,420 — 3.4% of the account. Two of those are banking names that would likely fall together, so the realistic worst case is worse than the arithmetic suggests.

**"Is my stop wide enough on this one?"** `P1`
→ `get_indicators` (ATR) + current stop distance.
> Your stop is 0.4× ATR from entry. Normal noise on this stock is roughly 1× ATR per bar — you'll likely be stopped out by ordinary movement rather than by being wrong. 1.5× ATR would put it at 1258.

**"Am I over-exposed to one sector?"** `P1` · **"What's my biggest position by risk, not by value?"** `P1` · **"If the market drops 2% tomorrow, what happens to my book?"** `P1`

---

## 2. Reading the current setup

**"Is this a real breakout or a fakeout?"** `P1`+`P2`
→ `get_candles` (multiple timeframes), `get_indicators` (volume, ATR), `find_levels`.
> Price cleared 1280 resistance, but on 0.7× average volume — weak confirmation. The 1h trend is still down and this is the third test of that level today. I'd treat it as suspect until volume confirms; a close above 1285 on above-average volume would change my read.

**"Do the 15-minute and 1-hour agree?"** `P1`
> No. 15m momentum is up (RSI 61, price above both EMAs), but the 1h is in a clear downtrend with price below its 50-EMA. You'd be buying a bounce inside a downtrend — viable as a scalp, poor as a swing.

**"Where's the nearest resistance above here?"** `NOW` · **"Is volume confirming this move?"** `P2` · **"Any candlestick patterns forming?"** `P2` · **"What's the ATR and how does it compare to the last month?"** `P2`

---

## 3. Regime — "should I even be trading this?"

**"Is this stock trending or chopping right now?"** `NOW`(partial) → `P2`
> ADX is 14 — below the 20 threshold that usually indicates a tradeable trend. Price has crossed its 20-EMA nine times in the last thirty bars. This is chop; trend-following setups will get sawed up here.

**"Should I be trading at all today?"** `P2`
> Nothing in your watchlist is showing ADX above 20, and NIFTY has held a 0.3% range all session. Low-conviction day — the honest answer is that sitting out is a position.

**"Is this move stock-specific or market-wide?"** `P2`

---

## 4. Validating edge — where experienced traders get sceptical

**"Does this setup actually work on this stock, historically?"** `NOW`(basic) → `CE`+`SIM`
> Tested "RSI under 30 while above the 50-EMA" on RELIANCE across 18 months: 41 trades, 34% win rate, 2.6:1 average win/loss, expectancy **+0.31% per trade** before costs, **+0.19%** after. Out-of-sample (the last 6 months, not used to build it): 31% win rate, +0.14% expectancy — weaker but still positive, which is the part that matters.

**"How many variations did you test before showing me that one?"** `CE`
This is the question that separates experienced traders from beginners, and the agent must answer it honestly and unprompted where relevant.
> Twelve. I swept RSI thresholds 25–40 and EMA lengths 20–100. Best-of-12 selection means some of that result is luck — which is why the out-of-sample number above matters more than the headline, and why I'd want forward paper results before you size up.

**"What's the max drawdown, not the return?"** `SIM`
> Peak-to-trough 14.2%, over a 6-week losing stretch with 11 consecutive losses. That's the number that decides whether you'd actually stick with it.

**"Was that backtest just lucky?"** `SIM`
> Resampled the trade sequence 5,000 times: median outcome +9.1%, 5th percentile −4.3%, 95th +23%. Maximum drawdown was between 6% and 21% in 90% of runs. The edge looks real but thin — the downside tail is live.

**"What's your track record on this stock?"** `NOW`
> Across stored signals, RELIANCE calls resolved 12 times: 4 hit target, 8 hit stop. I'd weight that lightly — 12 is a small sample, and overall signal accuracy currently sits near breakeven, which I'd rather tell you than dress up.

---

## 5. Challenging the agent — it must not get defensive

**"Your signal says BUY but ADX is 15. Isn't that chop?"** `P1`
> Fair challenge, and you're right that ADX 15 is below the trend threshold. This signal came through the on-demand path, which doesn't apply the regime filter that the automatic screener does. In chop I'd discount it.

**"Why should I trust your signals at all?"** `NOW`
> Honestly, on current measurement you shouldn't lean on them heavily. Walk-forward testing over 108 trades put win rate at 29.6% against a 31.3% breakeven — slightly negative expectancy. The wins are 2.2× the losses, so it's close, but "close to breakeven" isn't an edge. The analysis, risk sizing and levels are more dependable than the directional call.

**"What would make this trade wrong?"** `P1`
> A close back under 1265 invalidates the structure. Beyond that: the 1h trend is against you, and volume hasn't confirmed. If the broader index rolls over, correlated banking names in your book fall with it.

---

## 6. Their own behaviour — rare and valuable

**"Why do I keep losing money?"** `P1`(basic) → Phase 4
> Across your last 34 trades: win rate 47%, but average loss ₹840 against average win ₹390. You're right more often than you're wrong and still losing — you're cutting winners early and letting losers run. Your average holding time on losers is 3.2× that on winners.

**"Do I overtrade after a loss?"** Phase 4
> Yes — after a losing trade your next entry comes 4× faster than your usual gap, and those trades win 31% versus your 47% baseline.

**"What's my win rate by time of day?"** Phase 4 · **"Which setup type actually makes me money?"** Phase 4

---

## 7. Screening and idea generation

**"Which of my watchlist stocks are near support with rising volume?"** `P2`
> Three of fifteen: HDFCBANK (0.4% above a level tested three times), ONGC (right on its 50-EMA, volume 1.4× average), ITC (near range low but ADX 12 — chop, low conviction).

**"Anything setting up for tomorrow?"** `P2` · **"Compare RELIANCE and TCS — which has the better setup?"** `P2` · **"Show me everything oversold but still in an uptrend."** `P2`

---

## 8. Custom charting — the Pine Script replacement

**"Shade every zone where RSI stayed above 70 for more than three candles."** `CE`
> Marked 6 zones over the visible range. Four were followed by pullbacks of 1%+ within five bars.

**"Draw a channel through the last three swing highs and lows."** `CE`
**"Mark every gap-up open with an arrow."** `CE`
**"Plot the 20-day high minus the 20-day low as its own indicator."** `CE`
**"Circle every candle with 3× average volume."** `CE`
**"Add Ichimoku and Stochastic."** `P2`

---

## 9. Strategy building

**"Build me a strategy that buys dips in an uptrend."** `CE`
> Built: enter when RSI(14) drops below 35 while price holds above the 50-EMA; exit at RSI 65, with a 1.5× ATR stop and 3× ATR target. Want me to test it before you trust it?

**"Now run it on my whole watchlist."** `CE`+`SIM`
**"Paper-trade it forward for two weeks and report."** `SIM`
> Started. It'll trade a virtual ₹1,00,000 alongside your real paper account, tagged separately. Forward results can't be overfitted the way a backtest can — the data doesn't exist yet. I'd give it at least 30 trades before drawing conclusions.

**"Optimise the RSI threshold."** `CE`
> Careful — I can sweep it, but the best value found will partly reflect luck. I'll report in-sample and out-of-sample separately and tell you how many variants were tried.

---

## 10. Execution

**"Buy 20 RELIANCE at market."** Phase 3
> Confirming before I place anything: BUY 20 RELIANCE at ~1273.50, ₹25,470, which is 25% of your account. You have no stop set — at your usual 1% risk that implies a stop near 1260. Place it?

**"Alert me if it breaks 1300 on above-average volume."** Phase 3+`CE`
**"Close half my ONGC position."** Phase 3

---

## 11. Questions the agent should refuse or heavily qualify

**"Will RELIANCE go up tomorrow?"**
> I can't predict that, and anything that sounds like it can is selling you something. What I can give you: current structure, where the levels are, what the risk is on a given entry, and what similar setups have historically done.

**"Just tell me what to buy."**
> I can screen your watchlist for setups matching your criteria and size them to your risk — but the decision needs to be yours, especially given that signal accuracy currently sits near breakeven.

**"Put my whole account into this trade."**
> I'd push back. That's a single point of failure with no recovery path from a bad fill or a gap. If you want maximum size, risk-based sizing on your stop is the sane version of that.

**"Trade this automatically with real money."**
> Not supported, and not something I'd recommend enabling without a long forward paper record first. Real-money automation also needs a broker connection that isn't built yet.

---

## What this reveals about priorities

Counting what these questions need: **the vast majority are blocked on Phase 1** — portfolio awareness and risk sizing. A trader's most frequent, highest-stakes questions are about *their own position and risk*, not about chart geometry. That is the single biggest gap between the current agent and a useful one, and it reinforces the agreed build order.

The second pattern: experienced traders ask **sceptical, validation-shaped questions** ("how many variants did you test?", "what's the drawdown?", "why should I trust this?"). The agent's credibility depends on answering those with real numbers and real caveats rather than confident-sounding fluff — which is exactly why the [standing design rule](README.md) about never showing a performance number without its risk context matters.
