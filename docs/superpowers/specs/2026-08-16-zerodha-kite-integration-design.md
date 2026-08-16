# Zerodha Kite Connect Integration — Design

## Goal

Replace `yfinance` with real Zerodha Kite Connect data (quotes, historical
candles, symbol search) for NSE/BSE, with automatic fallback to `yfinance` on
any Kite failure. NASDAQ/NYSE stay on `yfinance` — Kite doesn't cover them.

## Background

Kite Connect requires a fresh `access_token` roughly every 24 hours (expires
~6am IST), obtained through an OAuth-style login. A live end-to-end test today
proved the full chain works: scripted password + TOTP login against Kite's
(unofficial, undocumented) `/api/login` and `/api/twofa` endpoints, followed by
the *official* `generate_session()` exchange for a `request_token`, produced a
real `access_token` and pulled real historical RELIANCE candles. The one-time
manual "Authorize this app" browser consent step (required once per app +
account before scripted login can complete) is already done for this app
(`kt6xp4euj5nkqybm`) and account (`FHU286`).

Using the unofficial login endpoints to script what is meant to be an
interactive browser login is against Kite's terms of service in spirit. This
is a known, accepted trade-off, not an oversight — it is how the daily refresh
avoids a human clicking through a browser every morning before market open.

## Architecture

Python (`ai-trader-signals`) owns everything Kite-specific: the daily login,
the real-time calls, the instrument-based search index. NestJS
(`ai-trader-api`) owns exactly one thing: the current `access_token`, stored in
MongoDB — consistent with the existing rule that NestJS owns every collection
in the product, and with the `ZERODHA_*` env vars already stubbed there
(`.env.example`'s "Planned work" section).

```
06:00 IST daily (Celery beat, signals-worker)
  -> kite_auth.refresh_session()
       -> password+TOTP login (unofficial endpoints) -> request_token
       -> kite.generate_session(request_token, secret) -> access_token   (official SDK call)
       -> kite.instruments("NSE") + kite.instruments("BSE")              (official SDK call)
  -> PUT /api/internal/broker/zerodha/session   (x-internal-key)
       -> NestJS upserts { accessToken, refreshedAt } into Mongo

Any request for an NSE/BSE symbol (chart, chat, screener, paper trading quote)
  -> MarketDataRouter._provider_for("NSE" | "BSE")  -> KiteProvider
       -> in-process token cache (5 min TTL) miss?
            -> GET /api/internal/broker/zerodha/session  (x-internal-key)
       -> real Kite API call
       -> on ANY failure (expired token, outage, rate-limit, network)
            -> MarketDataRouter retries the same call via the existing
               YFinanceProvider fallback instance, transparently
```

## Components

### `app/market/providers/kite_auth.py` (new, ai-trader-signals)

The login flow already proven live, moved out of the throwaway test script:

```python
async def refresh_session(settings: Settings) -> KiteSession:
    """Password + TOTP login, official token exchange, fresh instrument dump.
    Raises KiteAuthError on failure — the caller (the Celery task) decides
    whether to retry; a stale token in Mongo just means every NSE/BSE call
    rides the yfinance fallback until the next successful refresh."""
```

Internally: `requests.Session()` for `/api/login` + `/api/twofa` (using
`pyotp.TOTP(settings.zerodha_totp_secret).now()`), extract `request_token` from
the `connect/finish` redirect chain exactly as validated live, then
`KiteConnect(api_key=...).generate_session(request_token, api_secret=...)` for
the actual `access_token` — the one piece of this flow that IS the officially
supported API. Also fetches `kite.instruments("NSE")` and
`kite.instruments("BSE")` (each a list of dicts with `tradingsymbol`, `name`,
`instrument_token`) for the search index and symbol→token resolution.

### `app/market/providers/kite_provider.py` (new)

`KiteProvider(MarketDataProvider)` — full implementation, matching
`yfinance_provider.py`'s exact contract shapes so the router and every caller
stay unaware which vendor answered:

- `get_quote(symbol, exchange) -> dict | None` — same keys as
  `YFinanceProvider._get_quote_sync`: `symbol, exchange, ltp, change,
  change_percent, open, high, low, prev_close, volume`. Backed by
  `kite.quote(f"{exchange}:{symbol}")`.
- `get_historical_df(symbol, exchange, interval, days) -> pd.DataFrame | None`
  — same shape as `yfinance_provider`'s: DatetimeIndex, lowercase
  `open/high/low/close/volume` columns. Backed by `kite.historical_data()`,
  resolving `symbol` to Kite's `instrument_token` via the cached instrument
  dump first.
- `search(query, limit) -> list[dict]` — `[{symbol, name, exchange}]`, same
  shape as `yfinance_provider.search`. No Kite search API exists, so this is a
  local substring/prefix match against the cached instrument dump's
  `tradingsymbol`/`name` fields, filtered to NSE + BSE.

`kiteconnect`'s SDK is synchronous, same as `yfinance`'s — every method wraps
its sync call in `loop.run_in_executor(...)`, identical to the existing
`YFinanceProvider` pattern. Errors Kite is expected to produce (network,
throttling, an unmapped symbol) degrade to `None`/`[]` via the same
`_VENDOR_ERRORS`-style tuple already used in `yfinance_provider.py`; anything
outside that set is a real bug and gets re-raised through
`logger.exception`, same as today.

The instrument dump and the current token are both cached in-process with a
short TTL (~5 min for the token, since NestJS is the source of truth and
should not be hit on every single Kite call; the instrument dump for the
process lifetime, refreshed once daily alongside the token).

### `app/worker/celery_app.py` (modified)

One new `beat_schedule` entry, same file and pattern as the existing
`morning-brief`/`run-screener-*` entries:

```python
"refresh-zerodha-session": {
    "task": "app.worker.tasks.refresh_zerodha_session",
    "schedule": crontab(minute="0", hour="6"),
},
```

06:00 IST — ahead of the 06:30 morning brief and well ahead of the 09:15 open.

### `app/worker/tasks.py` (modified)

New `refresh_zerodha_session` task: calls `kite_auth.refresh_session()`, then
`PUT`s the result to NestJS using the exact `x-internal-key` header pattern
already used in `brief.py` and elsewhere in this file. Standard Celery retry
on failure (a few attempts with backoff) — if all retries fail, it logs loudly
and does nothing else; see "Error handling" below for why that is sufficient.

### `ai-trader-api/src/broker/` (new NestJS module, fills the existing stub)

Mirrors `chart-layouts/`'s shape exactly — one schema, one service, one
controller, all small and focused:

- `schemas/zerodha-session.schema.ts` — `{ accessToken: string, refreshedAt:
  Date }`. Singleton document (one row, no per-user scoping — this is one
  shared broker account, not a per-user credential).
- `zerodha-session.service.ts` — `get()` / `set(accessToken)`, upserting the
  singleton.
- `broker.controller.ts` — `@Controller('internal/broker/zerodha')`,
  `@UseGuards(InternalKeyGuard)` (the exact guard already protecting
  `internal/paper`, `internal/trading-context`, etc.):
  - `GET session` — returns the current token for `KiteProvider` to read.
  - `PUT session` — the daily refresh task writes the fresh token here.

### `app/market/providers/registry.py` (modified)

```python
self.providers["NSE"] = self.providers["BSE"] = KiteProvider(settings)
```

Plus a fallback wrapper in `_provider_for`'s callers (`get_quote` and
`get_historical_df`): on a Kite provider raising or returning `None` for
NSE/BSE, retry the same call through `self.fallback` (the existing
`YFinanceProvider` instance) before giving up.

`search` changes shape slightly. Today it's one line —
`self.fallback.search(query, limit)`. It becomes: call both
`self.providers["NSE"].search(query, limit)` (Kite, covering NSE+BSE) and
`self.fallback.search(query, limit)` (yfinance, covering NASDAQ+NYSE) and
concatenate the two result lists, capped at `limit` total. If the Kite call
fails, its half is silently dropped rather than failing the whole search —
same "expected vendor errors degrade, don't propagate" rule as everywhere
else in these providers.

## Non-goals

- **No live order execution through Kite.** This is market *data* only.
  Paper trading is unchanged — it now reads better-sourced quotes, nothing
  else about it changes.
- **No secrets-manager migration.** `ZERODHA_PASSWORD`/`ZERODHA_TOTP_SECRET`
  stay in `ai-trader-api/.env` on the box, matching how every other secret in
  this app is currently handled (Mongo URI, AWS keys, JWT secret). Moving all
  of those to a proper secret store is a separate, larger initiative and out
  of scope here.

## Error handling

Two independent layers, and they compose without extra code:

1. **A single Kite call fails** (network blip, rate-limit, a bad symbol) →
   `MarketDataRouter` retries through `YFinanceProvider`. Invisible to the
   caller beyond slightly older data.
2. **The daily refresh itself fails** (Kite changes their login page, the TOTP
   secret rotates, a genuine outage) → the Mongo-stored token goes stale →
   every subsequent Kite call fails validation → layer 1 catches every one of
   them → NSE/BSE silently rides on `yfinance` for the rest of that day. No
   special-case code needed for this scenario; it falls out of layer 1 for
   free. The failed refresh is still logged loudly (not swallowed) so it gets
   noticed and fixed before the *next* day, not discovered by an outage.

## Testing

- `kite_provider.py`: unit tests against a mocked `kiteconnect.KiteConnect`
  client — response shape conformance for all three methods, instrument-dump
  based symbol resolution, search filtering + `limit`. No `yfinance_provider`
  test file exists yet to mirror, so this is the first provider-level test
  file in the repo — its shape becomes the template for one if/when
  `yfinance_provider` gets tests later.
- `registry.py` fallback: force a `KiteProvider` failure for NSE, assert the
  `YFinanceProvider` result is what comes back, and that `search` still merges
  both sources correctly.
- `kite_auth.py`: the `request_token` extraction/parsing logic is tested
  against fixture HTML/redirect-chain responses, not live network calls — the
  live login itself is inherently not unit-testable and was already verified
  manually end-to-end.
- `BrokerModule` (NestJS): `zerodha-session.service.spec.ts`, same shape as
  the existing `chart-layouts.service.spec.ts`.
