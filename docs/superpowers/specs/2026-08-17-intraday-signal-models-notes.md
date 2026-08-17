# Intraday Signal Models — Planning Notes

> **Status: DRAFT planning notes, not an approved design.** Captures a conversation, not a spec — has not gone through the brainstorming skill's clarifying-questions / approaches / sectioned-approval flow yet. Do not treat any section here as committed; revisit and formalize into a real design doc before implementation starts.

## Scope

Intraday only, first. Options come later — blocked on a real prerequisite: no options-chain data (strikes, expiries, IV history) is collected today, only equity/index spot OHLCV via Kite. An IV/volatility model cannot be trained until that pipeline exists.

## Model count and split

Don't build one model per symbol. Split along three axes instead:

- **Timeframe** — intraday (1m/5m/15m bars) needs its own model, separate from swing/daily. Microstructure noise at intraday scale is a different problem than daily trend.
- **Instrument class** — index (NIFTY/BANKNIFTY) vs single stocks. Index is driven by constituent weighting + global cues, lower vol; stocks are driven by company-specific flow. One model per class, not per symbol.
- **Options split (once the data exists)** — direction, volatility/IV, and strike/expiry selection are different problems:
  - Direction model — predicts the underlying's move. This is the one that exists today (equity/index direction).
  - IV/volatility model — separate. Matters more than direction for near-ATM premium; a correct directional call can still lose money to IV crush.
  - Strike/expiry selection — should be rule-based (fixed delta target, ATM ± N strikes), not a trained model. Not worth building ML for this.

Realistic lean count for this phase: **one direction model** (intraday, per instrument class), reusing existing feature infra. Not 5-6 separate deep models.

## Labels

Triple-barrier method, not fixed-horizon return. Label = whichever hits first: take-profit level, stop-loss level, or a time limit. Matches how the signal would actually be traded (exit on target/stop, not on a clock). Fixed-horizon labeling ("return after 15 min") gets noisy fast at intraday scale.

## Features

Reuse what already exists rather than building new pipelines:
- `pandas_ta` indicators (already a dependency in `ai-trader-signals`) — the technical feature set.
- FinBERT news sentiment score (`/market/news` route, already built) — folded in as an extra feature column, not a separate model.

## Where it runs

- **Training** — offline/batch. Fits the existing Celery pattern (`signals-beat`/`signals-worker`) as a scheduled nightly/weekly retrain job.
- **Inference** — hot-path, inside the live-tick flow (the `live_ticks.py` poll/Kite-tick path built this session). Runs on bar-close, not on every tick — features need a stable bar, not a mid-formation one. Publishes a signal the same way a tick gets published today.

## Signal pipeline

Raw model confidence isn't enough — a signal only fires when confidence crosses a threshold AND passes secondary filters:
- Volume confirmation
- Spread/liquidity check
- No-signal window at open/close (first/last N minutes — volatility spikes there aren't the same regime the model trained on)
- Max signals per day cap

**Every generated signal gets backtested.** (Open question: does this mean each live signal is checked against a historical simulation of similar setups before being surfaced, or is it a periodic/nightly backtest evaluating the model's aggregate track record? Not yet clarified — resolve before implementation.)

**Execution is human-gated.** The model/signal pipeline never auto-executes a trade — a person confirms before anything goes to paper-trading execution. This is a deliberate, stated decision, not a default.

## Pre-prod considerations (vs. MVP)

Explicitly called out as different now that this is targeting pre-prod, not MVP:
- **Walk-forward validation**, not a single train/test split — intraday data is heavily autocorrelated; a single split leaks and overstates accuracy.
- **Paper-trade the model itself** before treating its signals as real — backtest P&L isn't enough, live slippage/latency differs from backtest assumptions.
- **Confidence threshold as a tunable, monitored parameter** — needs a feedback loop (precision/recall tracked periodically, threshold adjusted), not a hardcoded constant.
- **Signal audit trail** — log features, confidence, and which filters passed/failed per signal, not just the final fire/no-fire decision. Pre-prod means someone will ask "why did it fire this" after the fact.

## Open questions (not yet resolved)

- Exact meaning/mechanics of "every signal gets backtested" (per-signal historical-analog check vs. periodic aggregate backtest).
- Whether index and per-stock direction models share any weights/architecture or are fully independent.
- Confidence threshold's actual starting value and how it's tuned initially (no live signal history yet to calibrate against).
- How the human-execution confirmation step surfaces in the UI/workflow (chat prompt? a pending-signals queue? something else?).
