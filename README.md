# AI Trader

Intraday equity signal platform for the Indian market. A tool-using LLM agent reads live market data,
technical indicators and news sentiment, then proposes trades with entry, target and stop-loss — every number
sourced from a deterministic tool, never from the model's own arithmetic.

Three deployable services, each a submodule of this repo:

| Service | Stack | Role |
|---|---|---|
| [`ai-trader-signals`](https://github.com/devrunch/ai-trader-signals) | FastAPI, Python 3.12 | Signal engine, chat agent, backtester, indicator maths, live/historical market data |
| [`ai-trader-api`](https://github.com/devrunch/ai-trader-api) | NestJS, TypeScript | Auth, users, broker session, paper trading, WebSocket gateway, persistence |
| [`ai-trader-frontend`](https://github.com/devrunch/ai-trader-frontend) | Next.js 14, Tailwind | Trading terminal (KLineCharts), signal UI, chat |

```bash
git clone --recurse-submodules https://github.com/devrunch/ai-trader.git
```

MongoDB (Atlas) for storage, Redis for the Celery queue and the live-tick pub/sub bridge between
`ai-trader-signals` and `ai-trader-api`, Docker Compose for local and production, Caddy in front (TLS +
reverse proxy for both HTTP and the WebSocket gateway), a single EC2 instance for deploys.

Real market data: Zerodha Kite Connect for NSE/BSE (real-time WebSocket ticks plus quotes/history/search),
yfinance as the fallback for everything else and for any symbol Kite can't resolve.

---

## Design decisions worth reading

These are the choices that shaped the system, and the reasoning behind them.

### The agent never writes executable code

The agent can define trading strategies, chart drawings, alerts and screeners. The obvious implementation is
to let the model emit Python and run it. That is remote code execution: one prompt injection — or a single
hallucinated `import os` — reaches the server, the database, and every stored broker credential.

Instead the model emits **declarative specifications** — which known indicators to combine, and how — and a
validated condition DSL interprets them using known-safe operations. One evaluator powers all four features,
so the safety property holds everywhere by construction rather than being re-argued per feature.

### Backtests are pessimistic on purpose

A backtest is how the product tells a user whether the system works, so it is the last place to be
optimistic. Three rules:

- **Gapped stops fill at the bar open, not the stop price.** If a bar opens through your stop, that is your
  fill. Booking every stop at exactly the stop price understates losses on gaps, which are common across
  session boundaries.
- **Full round-trip costs** — brokerage, STT, exchange fees, GST, stamp duty, and realistic slippage. At
  intraday frequency, zero-cost backtests do not merely shade the result; they invert the sign of the
  expectancy.
- **Stop is checked before target within a bar.** A single OHLC bar cannot say which level was touched
  first, so the adverse one is assumed.

This logic previously existed twice — here in Python and again in the NestJS service — and the two disagreed,
the TypeScript copy filling gapped stops at the exact stop price and applying no costs. Both numbers were
shown to users. There is now one implementation.

### Risk gates fail closed

Eight pure `(ok, reason)` functions decide whether a signal is emitted at all. Every one fails closed: a risk
filter that disables itself when its input is missing is worse than no filter, because it is invisible. They
take plain data and return plain data, so the rules that actually gate a trade are unit-testable from a table
of dicts.

### Every agent turn has a spending ceiling

Three independent budgets, because turns fail in three different ways: **rounds** (a model that keeps asking
one more question never finishes), **wall clock** (a slow endpoint pins a worker long after the caller timed
out), and **tokens**. The token ceiling matters more than it looks — the tool schemas serialise to ~3,400
tokens and are resent every round, so a turn running its full round cap spends roughly 20,000 tokens before
fetching a single candle.

### Indicators go through an allow-list

Indicator selection is an explicit name → callable map, not `getattr()` on the TA library. Model-supplied
names can never reach arbitrary attributes, and the available surface stays predictable.

### One implementation of the indicator maths

The indicator code once existed in two places and drifted: the signal path used a session-anchored VWAP while
the other still used a whole-frame cumulative sum. The chat agent and the signal it was discussing reported
different VWAPs for the same chart. Every caller now goes through a single `compute()`.

---

## Analysis inputs

**27 indicators** via `pandas-ta` — RSI, Stochastic, StochRSI, MACD, Williams %R, CCI, MFI, ROC, TSI,
Ultimate Oscillator, ADX, Aroon, EMA, SMA, HMA, Bollinger, Keltner, Donchian, Supertrend, PSAR, Ichimoku,
ATR, OBV, CMF, volume and VWAP.

**12 candlestick patterns**, implemented natively. `pandas-ta` ships only three without TA-Lib, and TA-Lib is
a C dependency not worth adding to the image when the patterns traders actually use are simple OHLC
arithmetic. Definitions use explicit body/shadow ratios so results are reproducible rather than
impressionistic.

**News sentiment** via FinBERT (`ProsusAI/finbert`) over NewsAPI headlines, aggregated to a dominant label
per symbol. Sentiment is an input to a signal, not a precondition for it, so a news outage degrades to
neutral rather than killing signal generation.

**LLM reasoning** on AWS Bedrock (DeepSeek v3.2, with Mistral Large 3 and Qwen3-235B wired as alternatives)
through its OpenAI-compatible endpoint. API keys are minted from IAM credentials and refreshed an hour before
their 12-hour expiry.

---

## Agent architecture

Three phases rather than one function, each separately testable:

```
prepare   build the turn's state — transcript, toolbox, budgets
loop      alternate model calls and tool calls until an answer or a ceiling
finalise  emit closing events, return one result object
```

The model is handed a toolbox — market data, indicators, levels, the user's portfolio, risk and sizing maths,
backtests, chart drawing — and decides for itself what to look up before answering. All numbers come from
tools; the model only interprets them.

**279 tests** across indicators, patterns, the condition engine, validation gates, the backtest evaluator,
orchestration, token budgeting, and market-hours handling.

---

## Local development

Prerequisites: Docker Desktop, Git.

```bash
cp .env.example .env.local     # fill in keys — see docs/
docker compose up --build
```

| Service | URL |
|---|---|
| Frontend | http://localhost:3000 |
| API | http://localhost:8000 |
| API docs | http://localhost:8000/docs |
| Celery monitor | http://localhost:5555 |
| Mail catcher | http://localhost:8025 |

Accounts needed to run it end to end: a broker API (Dhan, Zerodha Kite Connect or Angel One SmartAPI), AWS
(Bedrock, SES, S3, Secrets Manager), HuggingFace (FinBERT), NewsAPI, and Google OAuth.

---

## Documentation

- [`docs/superpowers/specs/`](docs/superpowers/specs/) — design records for major features (Zerodha Kite
  integration, live price ticks, the in-progress intraday signal-model notes)
- [`docs/superpowers/plans/`](docs/superpowers/plans/) — the implementation plans those specs shipped through
- [`DEPLOY.md`](DEPLOY.md) — deployment

---

## Status

Pre-production. Live Zerodha Kite Connect data (NSE/BSE, real-time ticks + history + search) and a real-time
WebSocket price feed are built and deployed. Options/F&O and a trained intraday signal model are next; crypto
and other exchanges remain out of scope for now.

---

## Disclaimer

This software generates trade signals for informational purposes only. It is not investment advice. Trading
in equities carries risk of loss.
