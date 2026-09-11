# AI Trader — Project Overview

## What it is

AI Trader is a web platform that helps a trader understand what is moving the markets and decide what to do about it.

It brings three things together in one place: a professional charting terminal, a news and alerts feed that explains how each story affects specific stocks and instruments, and an AI assistant you can talk to about any chart.

All trading today is paper trading — simulated money against real market prices — so ideas and strategies can be tried out before any real capital is at stake.

---

## What we're aiming for

The end goal is a personal market advisor, not just a chart screen.

- **Know before the market opens.** Before the Indian market opens, the platform should already have read what happened overnight — US markets, Asia, oil, gold, the dollar, major world events — and turned it into a clear view of the day ahead.
- **Hear about it first.** When something that can move a market happens — an inflation report, a central bank decision, a geopolitical shock — the user should be told straight away, with a plain explanation of what it is likely to affect and in which direction. For example: US inflation comes in hot → the dollar strengthens → gold comes under pressure. Much of this is announced ahead of time, so the platform should find those events on its own and warn the user before they land.
- **Every market in one place.** Indian stocks, US stocks, forex, commodities and crypto.
- **Advice that fits the person.** Over time, recommendations should reflect the user's own capital and appetite for risk — including how to spread money across stocks, forex, mutual funds, crypto and other assets — rather than only "buy this, sell that".
- **Honest by default.** Every number comes from real data. The platform says plainly when it doesn't know something, and never shows a performance figure without the costs and risk behind it.

---

## What it does today

### Trading terminal

- TradingView-style charts with around 21 chart types — candles, Heikin Ashi, Renko, Kagi, Point & Figure, Volume Footprint and more.
- 49 built-in technical indicators, plus custom indicators written in Pine Script, including ones the AI builds on request.
- Drawing tools, with chart layouts saved per symbol.
- Markets covered: NSE, BSE, NASDAQ, NYSE, forex and metals, and MCX.
- Live streaming prices for Indian stocks and indices (through Zerodha, a licensed broker) and for forex and metals (through Deriv). US stocks run about 15 minutes behind.
- Works on phones as well as desktop.

### Paper trading

- Place orders and track positions and a portfolio with simulated money.
- Risk limits checked on every order.
- Positions are closed automatically before the Indian market shuts, so nothing is held overnight.

### AI assistant

- A chat assistant inside the terminal that can read the chart, look up market data, check the user's portfolio, search the web, run strategy backtests, and draw on the chart or add indicators to it.
- It works only from real data and never runs code of its own on the server.

### Strategies

- Backtesting of trading strategies, with realistic trading costs and deliberately cautious assumptions so the results aren't flattering.

### Home dashboard

- **Market overview** — twice every weekday, a snapshot of global markets (US, Asia, commodities, currency, volatility and India), with an overall read of the day and a short explanation of why.
- **Alerts** — an hourly check that flags any major market that has moved sharply, plus a read of crowd sentiment from Reddit discussion every two hours. Alerts appear on the home page and in a notification bell, and arrive live while the app is open.
- **Headlines with stock impact** — news gathered from four sources. Each headline is scored for sentiment and analysed for which specific stocks or instruments it is likely to move, in which direction, and why. The list can be filtered by market: NSE, BSE, NASDAQ, NYSE, forex, MCX or crypto.

### Admin

- An admin area for managing users and their usage.

---

## What's still missing

Measured against the goal, these are the main gaps.

1. **Trade signals aren't switched on.** The platform can generate buy and sell calls, but they are hidden until they can be shown to work on data they weren't tuned on. There is no proven track record yet to put in front of a user.
2. **News isn't instant.** The freshest headlines are roughly an hour old, and two of the four sources are delayed by 12 and 24 hours on their free plans.
3. **Alerts only reach the user inside the app.** There is no push notification, email or phone message — so "hear about it first" isn't met yet.
4. **Upcoming market-moving events aren't anticipated.** Much of what moves markets is announced ahead of time — economic reports, central bank decisions, speeches, company results, elections. Major US reports like inflation (CPI), producer prices (PPI) and jobs figures come out at exact, pre-announced times. PPI, for example, lands at 6pm IST — 7pm between November and early March, when US clocks go back. The platform doesn't know they're due. It does notice the market reacting — a sharp jump in volatility shows up as an alert within the hour — but it can't say *why*. The explanation only arrives once news articles about the release are published and picked up, which can take anywhere from one to several hours. It also doesn't have the market's forecast for each report, so even if it caught the number it couldn't say "this came in hotter than expected".
5. **US prices are delayed, and forex volume lags.** US stocks run about 15 minutes behind. Forex and metals prices are live, but their volume figures arrive 15–20 minutes late — spot forex has no central exchange, so its volume is an estimate built from one trading venue's activity.
6. **Crypto is news-only.** Crypto appears in news impact, but there is no crypto charting or trading.
7. **Nothing is personal yet.** No risk profile, no advice based on the user's capital, and no allocation across asset classes.
8. **Mutual funds and real estate aren't covered.** Part of the vision, not started.
9. **Real-money trading isn't connected.** Everything is simulated.
10. **News quality isn't checked directly.** Irrelevant headlines drop out only because no stock is found to be affected by them; there is no separate quality filter.
11. **It runs on a very small server.** The whole platform sits on one small machine close to its memory limit, with no test copy, a short outage on every update, and no automatic warning if a scheduled job stops running.

---

## Suggestions

### Faster news

- **Alpaca News API** — genuinely live news (sourced from Benzinga), pushed the moment it's published, and free with a paper-trading account. The best single fit for "hear about it first".
- A paid plan on **NewsAPI** or **newsdata.io** removes their 24-hour and 12-hour delays.

### Alerts that reach the user

- **Telegram bot** — free, instant, and widely used by traders. The quickest way to get alerts onto a phone.
- **Web push notifications** — work even when the browser tab is closed.
- **Email** (for example Amazon SES) for a daily summary.

### A self-running market watcher

Rather than working from a fixed list of reports, the platform should find out for itself what's coming, decide what matters, and plan for it.

1. **Find what's coming.** Every day, read official calendars, central bank and government announcements, company results schedules and the news itself, and pick out anything with a date and time attached — a US inflation report, a Fed chair's speech, an OPEC meeting, an election, a court ruling, a company's earnings, a tariff deadline. Nothing has to be listed in advance: if it has been announced anywhere reliable, the watcher should find it.
2. **Decide what matters.** For each event, judge whether it could move the markets the user cares about — which ones, and how strongly — and set the rest aside. A US inflation report matters to gold, the dollar and US stocks; a public holiday in one small market usually doesn't.
3. **Plan ahead.** For every event that matters, prepare before it happens:
   - when to start watching, and where the result will appear first;
   - what the market is expecting;
   - what each likely outcome would mean — for example, *if US producer prices come in above forecast, yields and the dollar rise and gold falls; if below, the reverse*.

   The user gets a heads-up beforehand: what's due, when, and what it could move.
4. **Watch it land.** Wake up shortly before the event and keep checking the source until the result is out.
5. **Explain and alert.** The moment it lands, match the result against the plan, write a plain explanation of the likely impact, and send it straight to the user.
6. **Check and learn.** Over the following hour, see how the markets actually moved. Keep a record of which kinds of events really moved which markets, and by how much, so the watcher gets steadily better at judging what's important — and stops raising alarms over things that never matter.
7. **Catch the surprises too.** Not everything is announced. When a market moves sharply and no planned event explains it, the watcher should go and find out why — search the news, identify the cause — and tell the user, instead of only reporting that something moved.

An alert might read:

> **US producer prices rose more than expected.** When producers' costs rise, those costs tend to reach consumer prices next, which puts pressure on the Federal Reserve to keep interest rates high or raise them. Likely effects: US bond yields and the dollar up; gold down; US stocks, especially tech, under pressure. Watch: XAUUSD, NASDAQ, USD/INR.

**Keeping it honest and affordable**

- **Every planned event must trace back to a real, dated source.** The watcher should never expect something it can't point to.
- **It reads widely once or twice a day, not continuously,** and only wakes around events that matter, so the AI cost stays small.
- **Market forecasts still need a source.** For economic reports, forecasts come from calendar services such as **Trading Economics**, **Finnhub** or **Financial Modeling Prep** (check which include forecasts on the plan you pick). Without one, the watcher can still compare against the previous figure.
- **Genuinely unannounced shocks can't be predicted** — only caught fast and explained, which is what step 7 is for.
- **It needs a way to reach the user instantly outside the app** — see *Alerts that reach the user* above.

### Live US prices and crypto

- **Alpaca** or **Polygon.io** for real-time US stock prices.
- **CoinGecko** or **Binance** public data for crypto prices and charts.

### Trade signals

- Before switching signals on, test them on data they weren't tuned on (walk-forward testing) and publish the results with costs and drawdown included. Show signals only with that track record alongside them.

### Server and reliability

- Move to a larger server — 4 GB of memory instead of 2 GB. This removes the memory pressure outright.
- If staying on the current size, fold the job scheduler into the background worker to free roughly 160 MB.
- **Healthchecks.io** (free tier) to get a warning the moment a scheduled job — news, alerts, the market overview, the broker login — stops running.
- **Sentry** (free tier) to catch errors in the app as they happen.
- A separate test copy of the platform, so updates can be checked before users see them.

### Toward personal advice

- A short risk-profile questionnaire at sign-up — capital, goals and appetite for risk — as the foundation for personalised recommendations later.
