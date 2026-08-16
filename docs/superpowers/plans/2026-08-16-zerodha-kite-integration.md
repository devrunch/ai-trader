# Zerodha Kite Connect Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `yfinance` with real Zerodha Kite Connect data (quotes, historical candles, symbol search) for NSE/BSE, with automatic fallback to `yfinance` on any Kite failure, and a daily scripted token refresh.

**Architecture:** Python (`ai-trader-signals`) owns everything Kite-specific — the daily login, the live calls, the instrument-based search index — behind a new `KiteProvider` implementing the existing `MarketDataProvider` protocol. NestJS (`ai-trader-api`) owns exactly one new thing: the current `access_token`, in a new `BrokerModule` backed by MongoDB, following the same `internal/*` + `InternalKeyGuard` pattern already used for `internal/paper` and `internal/trading-context`.

**Tech Stack:** Python 3.13, `kiteconnect` (official SDK), `pyotp` (TOTP), `httpx` (already a dependency — used both for the scripted login and for internal service calls), Celery beat, NestJS, Mongoose.

**Spec:** `docs/superpowers/specs/2026-08-16-zerodha-kite-integration-design.md`

## Global Constraints

- `KiteProvider` must match `yfinance_provider.py`'s exact return shapes for `get_quote` (`symbol, exchange, ltp, change, change_percent, open, high, low, prev_close, volume`) and `get_historical_df` (DatetimeIndex, lowercase `open/high/low/close/volume` columns) and `search` (`{symbol, name, exchange}`) — callers must never know which vendor answered.
- Expected vendor errors (network, an unmapped symbol, a Kite API error) degrade to `None`/`[]`, exactly like `yfinance_provider.py`'s `_VENDOR_ERRORS` convention — never raise out of a provider method for a condition the vendor is expected to produce.
- Internal NestJS↔Python calls use the existing `x-internal-key` header + `InternalKeyGuard` pattern (already protecting `internal/paper`, `internal/trading-context`, `internal/watchlist`) — no new auth mechanism.
- No live order execution through Kite. Market data only.
- `ZERODHA_PASSWORD`/`ZERODHA_TOTP_SECRET`/`ZERODHA_API_KEY`/`ZERODHA_API_SECRET` stay in `ai-trader-api/.env` — already present there, no secrets-manager migration in scope.

---

### Task 1: NestJS — ZerodhaSession schema + service

**Files:**
- Create: `ai-trader-api/src/broker/schemas/zerodha-session.schema.ts`
- Create: `ai-trader-api/src/broker/zerodha-session.service.ts`
- Test: `ai-trader-api/src/broker/zerodha-session.service.spec.ts`

**Interfaces:**
- Produces: `ZerodhaSessionService.get(): Promise<{ accessToken: string | null, refreshedAt: Date | null }>`, `ZerodhaSessionService.set(accessToken: string): Promise<{ accessToken: string, refreshedAt: Date }>`

- [ ] **Step 1: Write the failing test**

```typescript
// ai-trader-api/src/broker/zerodha-session.service.spec.ts
import { ZerodhaSessionService } from './zerodha-session.service';

type Doc = Record<string, any>;

function fakeModel() {
  let doc: Doc | null = null;
  const lean = (value: unknown) => ({
    lean: () => Promise.resolve(value),
  });
  return {
    get current() {
      return doc;
    },
    findOne: jest.fn(() => lean(doc)),
    findOneAndUpdate: jest.fn((_filter: Doc, update: Doc, opts: Doc) => {
      doc = { ...(doc ?? {}), ...update.$set, ...(opts?.upsert ? update.$setOnInsert : {}) };
      return { lean: () => Promise.resolve(doc) };
    }),
  };
}

function setup() {
  const model = fakeModel();
  return { model, service: new ZerodhaSessionService(model as never) };
}

describe('ZerodhaSessionService', () => {
  it('returns nulls when no session has ever been stored', async () => {
    const f = setup();
    const view = await f.service.get();

    expect(view).toEqual({ accessToken: null, refreshedAt: null });
  });

  it('stores a fresh token and hands it back', async () => {
    const f = setup();
    const saved = await f.service.set('tok_123');

    expect(saved.accessToken).toBe('tok_123');
    expect(saved.refreshedAt).toBeInstanceOf(Date);

    const view = await f.service.get();
    expect(view.accessToken).toBe('tok_123');
  });

  it('a second refresh replaces the first, not adds to it', async () => {
    const f = setup();
    await f.service.set('tok_123');
    await f.service.set('tok_456');

    const view = await f.service.get();
    expect(view.accessToken).toBe('tok_456');
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ai-trader-api && npx jest src/broker/zerodha-session.service.spec.ts`
Expected: FAIL — `Cannot find module './zerodha-session.service'`

- [ ] **Step 3: Write the schema**

```typescript
// ai-trader-api/src/broker/schemas/zerodha-session.schema.ts
import { Prop, Schema, SchemaFactory } from '@nestjs/mongoose';
import { Document } from 'mongoose';

export type ZerodhaSessionDocument = ZerodhaSession & Document;

/**
 * The current Kite Connect access_token — one shared broker account, not a
 * per-user credential, so this is a singleton document (`key: 'zerodha'` is
 * fixed) rather than keyed by user.
 *
 * Refreshed daily by a scripted login in the Python signals service (Kite
 * tokens expire ~6am IST); this collection is just where the result lands so
 * every process reading market data sees the same current token without
 * each one having to log in itself.
 */
@Schema({ timestamps: false })
export class ZerodhaSession {
  @Prop({ required: true, default: 'zerodha', unique: true })
  key: string;

  @Prop({ required: true })
  accessToken: string;

  @Prop({ required: true })
  refreshedAt: Date;
}

export const ZerodhaSessionSchema = SchemaFactory.createForClass(ZerodhaSession);
```

- [ ] **Step 4: Write the service**

```typescript
// ai-trader-api/src/broker/zerodha-session.service.ts
import { Injectable } from '@nestjs/common';
import { InjectModel } from '@nestjs/mongoose';
import { Model } from 'mongoose';
import { ZerodhaSession, ZerodhaSessionDocument } from './schemas/zerodha-session.schema';

export interface ZerodhaSessionView {
  accessToken: string | null;
  refreshedAt: Date | null;
}

const KEY = 'zerodha';

@Injectable()
export class ZerodhaSessionService {
  constructor(
    @InjectModel(ZerodhaSession.name)
    private readonly model: Model<ZerodhaSessionDocument>,
  ) {}

  async get(): Promise<ZerodhaSessionView> {
    const doc = await this.model.findOne({ key: KEY }).lean();
    if (!doc) return { accessToken: null, refreshedAt: null };
    return { accessToken: doc.accessToken, refreshedAt: doc.refreshedAt };
  }

  async set(accessToken: string): Promise<{ accessToken: string; refreshedAt: Date }> {
    const refreshedAt = new Date();
    await this.model.findOneAndUpdate(
      { key: KEY },
      { $set: { accessToken, refreshedAt }, $setOnInsert: { key: KEY } },
      { upsert: true },
    );
    return { accessToken, refreshedAt };
  }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd ai-trader-api && npx jest src/broker/zerodha-session.service.spec.ts`
Expected: PASS — 3 tests

- [ ] **Step 6: Commit**

```bash
git add src/broker/schemas/zerodha-session.schema.ts src/broker/zerodha-session.service.ts src/broker/zerodha-session.service.spec.ts
git commit -m "feat: ZerodhaSession schema and service for the daily-refreshed access_token"
```

---

### Task 2: NestJS — BrokerController + BrokerModule wiring

**Files:**
- Create: `ai-trader-api/src/broker/broker.controller.ts`
- Create: `ai-trader-api/src/broker/broker.module.ts`
- Modify: `ai-trader-api/src/app.module.ts`

**Interfaces:**
- Consumes: `ZerodhaSessionService.get()` / `.set(accessToken)` from Task 1
- Produces: `GET /api/internal/broker/zerodha/session` → `{accessToken, refreshedAt}`; `PUT /api/internal/broker/zerodha/session` body `{accessToken: string}` → `{accessToken, refreshedAt}`

No dedicated controller test — matching the existing pattern (`ChartLayoutsController`, `PortfolioInternalController` have no controller-level spec either; only their services are unit-tested, and `InternalKeyGuard` is already exercised in production by every other `internal/*` controller). Verified manually in Step 4 below instead.

- [ ] **Step 1: Write the controller**

```typescript
// ai-trader-api/src/broker/broker.controller.ts
import { Body, Controller, Get, Put, UseGuards } from '@nestjs/common';
import { SkipThrottle } from '@nestjs/throttler';
import { InternalKeyGuard } from '../common/guards/internal-key.guard';
import { ZerodhaSessionService } from './zerodha-session.service';

/**
 * Internal, service-to-service only — the Python signals service's daily
 * refresh task writes here, and its KiteProvider reads here before every
 * Kite call. Never exposed outside the private Docker network.
 */
@SkipThrottle()
@UseGuards(InternalKeyGuard)
@Controller('internal/broker/zerodha')
export class BrokerController {
  constructor(private readonly sessions: ZerodhaSessionService) {}

  @Get('session')
  get() {
    return this.sessions.get();
  }

  @Put('session')
  set(@Body('accessToken') accessToken: string) {
    return this.sessions.set(accessToken);
  }
}
```

- [ ] **Step 2: Write the module**

```typescript
// ai-trader-api/src/broker/broker.module.ts
import { Module } from '@nestjs/common';
import { MongooseModule } from '@nestjs/mongoose';
import { BrokerController } from './broker.controller';
import { ZerodhaSessionService } from './zerodha-session.service';
import { ZerodhaSession, ZerodhaSessionSchema } from './schemas/zerodha-session.schema';

/** The current Zerodha Kite Connect access_token, refreshed daily. */
@Module({
  imports: [
    MongooseModule.forFeature([{ name: ZerodhaSession.name, schema: ZerodhaSessionSchema }]),
  ],
  providers: [ZerodhaSessionService],
  controllers: [BrokerController],
})
export class BrokerModule {}
```

- [ ] **Step 3: Register the module**

Read `ai-trader-api/src/app.module.ts` first to find the existing `ChartLayoutsModule` import (line ~17) and its place in the `imports:` array (line ~49) — add `BrokerModule` the same way, immediately after `ChartLayoutsModule`:

```typescript
import { BrokerModule } from './broker/broker.module';
```
and in the `imports:` array:
```typescript
    ChartLayoutsModule,
    BrokerModule,
```

- [ ] **Step 4: Verify manually**

Run: `cd ai-trader-api && npm run start:dev`

In another terminal:
```bash
curl -s -X PUT http://localhost:8000/api/internal/broker/zerodha/session \
  -H "Content-Type: application/json" \
  -H "x-internal-key: $(grep ^INTERNAL_API_KEY .env | cut -d= -f2)" \
  -d '{"accessToken":"test_token_123"}'
```
Expected: `{"accessToken":"test_token_123","refreshedAt":"...ISO timestamp..."}`

```bash
curl -s http://localhost:8000/api/internal/broker/zerodha/session \
  -H "x-internal-key: $(grep ^INTERNAL_API_KEY .env | cut -d= -f2)"
```
Expected: same `accessToken`/`refreshedAt` back.

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8000/api/internal/broker/zerodha/session
```
Expected: `401` (no `x-internal-key` header — guard rejects it)

- [ ] **Step 5: Commit**

```bash
git add src/broker/broker.controller.ts src/broker/broker.module.ts src/app.module.ts
git commit -m "feat: internal endpoints for the current Zerodha access_token"
```

---

### Task 3: Python — dependencies and settings

**Files:**
- Modify: `ai-trader-signals/requirements.txt`
- Modify: `ai-trader-signals/app/config.py`

**Interfaces:**
- Produces: `settings.zerodha_api_key`, `settings.zerodha_api_secret`, `settings.zerodha_user_id`, `settings.zerodha_password`, `settings.zerodha_totp_secret` (all `str`, default `""`)

- [ ] **Step 1: Add the two new dependencies**

In `ai-trader-signals/requirements.txt`, add after the `yfinance` line:

```
kiteconnect>=5.0.1
pyotp>=2.9.0
```

- [ ] **Step 2: Install them**

Run: `.venv/Scripts/python.exe -m pip install -r requirements.txt`
Expected: `kiteconnect` and `pyotp` install cleanly (both were already manually installed and proven working earlier — this just makes them a real, tracked dependency).

- [ ] **Step 3: Add the settings fields**

In `ai-trader-signals/app/config.py`, in the `Settings` class, add after the `news_api_key: str = ""` line (under the existing `# Market data` comment):

```python
    # Zerodha Kite Connect — real NSE/BSE market data. ZERODHA_USER_ID/PASSWORD/
    # TOTP_SECRET are only used by the daily scripted login (see
    # app/market/providers/kite_auth.py); ZERODHA_API_KEY/SECRET are also
    # needed for the official generate_session() token exchange.
    zerodha_api_key: str = ""
    zerodha_api_secret: str = ""
    zerodha_user_id: str = ""
    zerodha_password: str = ""
    zerodha_totp_secret: str = ""
```

- [ ] **Step 4: Verify it loads**

Run: `.venv/Scripts/python.exe -c "from app.config import get_settings; s = get_settings(); print(s.zerodha_api_key, s.zerodha_user_id)"`
Expected: prints the two values (empty strings unless `ZERODHA_API_KEY`/`ZERODHA_USER_ID` are set in this service's own environment — they currently only live in `ai-trader-api/.env`, which is fine; Task 4's tests inject `Settings` directly rather than relying on env vars)

- [ ] **Step 5: Commit**

```bash
git add requirements.txt app/config.py
git commit -m "feat: add kiteconnect/pyotp dependencies and Zerodha settings"
```

---

### Task 4: Python — kite_auth.py (the daily login)

**Files:**
- Create: `ai-trader-signals/app/market/providers/kite_auth.py`
- Test: `ai-trader-signals/tests/test_kite_auth.py`

**Interfaces:**
- Produces: `refresh_session(settings: Settings) -> KiteSession` (dataclass with `access_token: str`, `nse_instruments: list[dict]`, `bse_instruments: list[dict]`); raises `KiteAuthError` on any failure.
- Produces (for testing/reuse): `_extract_request_token(history: list, final_response) -> str | None` — pure function, no network.

- [ ] **Step 1: Write the failing test for the pure, testable part**

```python
# ai-trader-signals/tests/test_kite_auth.py
"""
kite_auth — the daily scripted login.

The login itself (password + TOTP against Kite's unofficial endpoints, then
the official generate_session() exchange) was proven live end-to-end before
this was written — see the design spec. What's unit-testable without a real
network call is the one fragile parsing step: pulling request_token out of
whatever redirect chain Kite's connect/finish response actually is.
"""
from __future__ import annotations

from types import SimpleNamespace

from app.market.providers.kite_auth import _extract_request_token


def _response(url: str, location: str | None = None) -> SimpleNamespace:
    headers = {"Location": location} if location else {}
    return SimpleNamespace(url=url, headers=headers)


def test_finds_the_token_in_a_redirect_location_header():
    history = [_response("https://kite.zerodha.com/connect/login")]
    final = _response(
        "https://kite.zerodha.com/connect/finish",
        location="http://localhost:8000/api/broker/zerodha/callback?status=success&request_token=ABC123&action=login",
    )
    assert _extract_request_token(history, final) == "ABC123"


def test_finds_the_token_in_the_final_url_itself():
    """If httpx already followed the redirect, the token is in `.url`, not a
    `Location` header on the last response."""
    history = []
    final = _response(
        "http://localhost:8000/api/broker/zerodha/callback?request_token=XYZ789&status=success"
    )
    assert _extract_request_token(history, final) == "XYZ789"


def test_stops_at_the_first_ampersand():
    final = _response(
        "http://localhost:8000/callback?other=1&request_token=TOK&status=success"
    )
    assert _extract_request_token([], final) == "TOK"


def test_returns_none_when_no_token_is_anywhere_in_the_chain():
    """The real failure mode this guards: connect/finish returned an error
    (e.g. "the user is not enabled for the app") instead of a redirect."""
    final = _response("https://kite.zerodha.com/connect/finish?api_key=x&sess_id=y")
    assert _extract_request_token([], final) is None
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/Scripts/python.exe -m pytest tests/test_kite_auth.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.market.providers.kite_auth'`

- [ ] **Step 3: Write the implementation**

```python
# ai-trader-signals/app/market/providers/kite_auth.py
"""
The daily Kite Connect login.

Kite Connect's access_token expires roughly every 24 hours (~6am IST), and
the standard flow expects a human to log in through a browser and click
"Authorize" once for a new app. That one-time authorize click is a real,
one-time manual step — already done for this app + account — but everything
after it can be scripted: a password + TOTP login against Kite's own
(unofficial, undocumented) /api/login and /api/twofa endpoints produces a
logged-in session, which the *official* generate_session() call then
exchanges for a real access_token.

Using the unofficial endpoints to script what's meant to be an interactive
browser login is against Kite's terms of service in spirit. That's a known,
accepted trade-off — it's what lets the token refresh happen at 6am unattended
instead of requiring someone to click through a browser before every trading
day.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Any

import httpx
import pyotp
from kiteconnect import KiteConnect

from app.config import Settings

logger = logging.getLogger(__name__)

_LOGIN_URL = "https://kite.zerodha.com/api/login"
_TWOFA_URL = "https://kite.zerodha.com/api/twofa"
_CONNECT_LOGIN_URL = "https://kite.zerodha.com/connect/login"


class KiteAuthError(Exception):
    """The daily login failed. Callers should NOT crash the process over
    this — a stale token in NestJS just means every NSE/BSE call falls
    through to yfinance until the next successful refresh."""


@dataclass
class KiteSession:
    access_token: str
    nse_instruments: list[dict[str, Any]]
    bse_instruments: list[dict[str, Any]]


def _extract_request_token(history: list, final_response: Any) -> str | None:
    """Walk a redirect chain (oldest first) plus the final response, looking
    for request_token= in a Location header or in the final URL itself —
    httpx may or may not have already followed the redirect depending on how
    it was called, so both are checked."""
    for resp in [*history, final_response]:
        loc = resp.headers.get("Location") or str(resp.url)
        if "request_token=" in loc:
            return loc.split("request_token=")[1].split("&")[0]
    return None


def refresh_session(settings: Settings) -> KiteSession:
    """Password + TOTP login, official token exchange, fresh NSE+BSE
    instrument dumps. Raises KiteAuthError on any failure — see the module
    docstring for why that's the right thing to raise rather than degrade."""
    try:
        with httpx.Client(timeout=15) as client:
            login = client.post(_LOGIN_URL, data={
                "user_id": settings.zerodha_user_id,
                "password": settings.zerodha_password,
            })
            login.raise_for_status()
            request_id = login.json()["data"]["request_id"]

            totp_code = pyotp.TOTP(settings.zerodha_totp_secret).now()
            twofa = client.post(_TWOFA_URL, data={
                "user_id": settings.zerodha_user_id,
                "request_id": request_id,
                "twofa_value": totp_code,
                "twofa_type": "totp",
            })
            twofa.raise_for_status()

            final = client.get(
                _CONNECT_LOGIN_URL,
                params={"api_key": settings.zerodha_api_key, "v": 3},
                follow_redirects=True,
            )
            request_token = _extract_request_token(final.history, final)
            if not request_token:
                raise KiteAuthError(
                    f"No request_token in Kite's response. Final URL: {final.url}"
                )
    except httpx.HTTPError as e:
        raise KiteAuthError(f"Login request failed: {e}") from e

    kite = KiteConnect(api_key=settings.zerodha_api_key)
    try:
        result = kite.generate_session(request_token, api_secret=settings.zerodha_api_secret)
        access_token = result["access_token"]
        kite.set_access_token(access_token)
        nse = kite.instruments("NSE")
        bse = kite.instruments("BSE")
    except Exception as e:
        raise KiteAuthError(f"Token exchange or instrument fetch failed: {e}") from e

    logger.info("Zerodha session refreshed — user %s", result.get("user_name"))
    return KiteSession(access_token=access_token, nse_instruments=nse, bse_instruments=bse)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `.venv/Scripts/python.exe -m pytest tests/test_kite_auth.py -v`
Expected: PASS — 4 tests

- [ ] **Step 5: Run ruff and mypy**

Run: `.venv/Scripts/python.exe -m ruff check app/market/providers/kite_auth.py tests/test_kite_auth.py`
Expected: clean

Run: `.venv/Scripts/python.exe -m mypy app/market/providers/kite_auth.py`
Expected: clean

- [ ] **Step 6: Commit**

```bash
git add app/market/providers/kite_auth.py tests/test_kite_auth.py
git commit -m "feat: scripted daily Kite Connect login, proven live end-to-end"
```

---

### Task 5: Python — kite_provider.py (the real provider)

**Files:**
- Create: `ai-trader-signals/app/market/providers/kite_provider.py`
- Test: `ai-trader-signals/tests/test_kite_provider.py`

**Interfaces:**
- Consumes: `Settings` (Task 3's `zerodha_*` fields, plus existing `api_service_url`/`internal_api_key`)
- Produces: `KiteProvider` implementing `MarketDataProvider` (`get_quote`, `get_historical_df`, `search`) — same return shapes as `YFinanceProvider`.

- [ ] **Step 1: Write the failing tests**

```python
# ai-trader-signals/tests/test_kite_provider.py
"""
KiteProvider — real NSE/BSE data, same shape as YFinanceProvider so the
router and every caller stay unaware which vendor answered.

Mocks the KiteConnect client the same way test_symbol_search.py mocks
yf.Search — nothing here touches the network. The NestJS call for the
current access_token is mocked too, at the httpx level.
"""
from __future__ import annotations

from unittest.mock import MagicMock, patch

import pandas as pd
import pytest

from app.config import Settings
from app.market.providers.kite_provider import KiteProvider

NSE_INSTRUMENTS = [
    {"tradingsymbol": "RELIANCE", "name": "RELIANCE INDUSTRIES", "instrument_token": 738561,
     "instrument_type": "EQ", "exchange": "NSE"},
    {"tradingsymbol": "RELIANCE-FUT", "name": "RELIANCE INDUSTRIES FUT", "instrument_token": 999,
     "instrument_type": "FUT", "exchange": "NSE"},
    {"tradingsymbol": "TCS", "name": "TATA CONSULTANCY SERVICES", "instrument_token": 2953217,
     "instrument_type": "EQ", "exchange": "NSE"},
]
BSE_INSTRUMENTS = [
    {"tradingsymbol": "RELIANCE", "name": "RELIANCE INDUSTRIES", "instrument_token": 500325,
     "instrument_type": "EQ", "exchange": "BSE"},
]


def _settings() -> Settings:
    return Settings(
        zerodha_api_key="key", zerodha_api_secret="secret",
        api_service_url="http://api.test", internal_api_key="ikey",
    )


def _provider_with_token() -> KiteProvider:
    provider = KiteProvider(_settings())
    with patch("app.market.providers.kite_provider.httpx.get") as mock_get:
        mock_get.return_value = MagicMock(
            status_code=200,
            json=lambda: {"accessToken": "tok_abc", "refreshedAt": "2026-08-16T06:00:00Z"},
        )
        mock_get.return_value.raise_for_status = lambda: None
        provider._ensure_token()
    return provider


class TestGetQuote:
    def test_maps_kite_quote_shape_to_the_shared_contract(self):
        provider = _provider_with_token()
        provider._kite.quote = MagicMock(return_value={
            "NSE:RELIANCE": {
                "last_price": 1292.9,
                "ohlc": {"open": 1279.8, "high": 1297.0, "low": 1275.3, "close": 1278.0},
                "volume": 12158451,
            }
        })

        result = provider._get_quote_sync("RELIANCE", "NSE")

        assert result["symbol"] == "RELIANCE"
        assert result["exchange"] == "NSE"
        assert result["ltp"] == 1292.9
        assert result["prev_close"] == 1278.0
        assert result["change"] == pytest.approx(14.9, abs=0.01)
        assert result["volume"] == 12158451

    def test_a_kite_exception_returns_none_not_a_raise(self):
        from kiteconnect.exceptions import KiteException

        provider = _provider_with_token()
        provider._kite.quote = MagicMock(side_effect=KiteException("rate limited"))

        assert provider._get_quote_sync("RELIANCE", "NSE") is None


class TestGetHistoricalDf:
    def test_resolves_symbol_to_instrument_token_and_shapes_the_frame(self):
        provider = _provider_with_token()
        provider._instruments = {
            "NSE": {r["tradingsymbol"]: r for r in NSE_INSTRUMENTS if r["instrument_type"] == "EQ"},
            "BSE": {r["tradingsymbol"]: r for r in BSE_INSTRUMENTS},
        }
        provider._instruments_loaded_at = provider._now()
        provider._kite.historical_data = MagicMock(return_value=[
            {"date": pd.Timestamp("2026-08-14"), "open": 1265.0, "high": 1283.4,
             "low": 1249.8, "close": 1278.0, "volume": 9817000},
            {"date": pd.Timestamp("2026-08-15"), "open": 1288.2, "high": 1288.7,
             "low": 1278.0, "close": 1280.0, "volume": 7163132},
        ])

        df = provider._get_historical_df_sync("RELIANCE", "NSE", "1d", 30)

        assert list(df.columns) == ["open", "high", "low", "close", "volume"]
        assert len(df) == 2
        called_token = provider._kite.historical_data.call_args[0][0]
        assert called_token == 738561  # RELIANCE's EQ instrument_token, not the FUT one

    def test_an_unmapped_symbol_returns_none(self):
        provider = _provider_with_token()
        provider._instruments = {"NSE": {}, "BSE": {}}
        provider._instruments_loaded_at = provider._now()

        assert provider._get_historical_df_sync("NOTREAL", "NSE", "1d", 30) is None


class TestSearch:
    def test_matches_symbol_or_name_case_insensitively_eq_only(self):
        provider = _provider_with_token()
        provider._instruments = {
            "NSE": {r["tradingsymbol"]: r for r in NSE_INSTRUMENTS if r["instrument_type"] == "EQ"},
            "BSE": {r["tradingsymbol"]: r for r in BSE_INSTRUMENTS},
        }
        provider._instruments_loaded_at = provider._now()

        results = provider._search_sync("reliance", limit=8)

        symbols_and_exchanges = {(r["symbol"], r["exchange"]) for r in results}
        # Both the NSE and BSE listing show up — search is not exchange-scoped
        # by the caller, same as yfinance's search.
        assert symbols_and_exchanges == {("RELIANCE", "NSE"), ("RELIANCE", "BSE")}
        # The FUT row must never appear — instrument_type filtering excludes it.
        assert all(r["symbol"] != "RELIANCE-FUT" for r in results)

    def test_respects_the_limit(self):
        provider = _provider_with_token()
        provider._instruments = {
            "NSE": {r["tradingsymbol"]: r for r in NSE_INSTRUMENTS if r["instrument_type"] == "EQ"},
            "BSE": {},
        }
        provider._instruments_loaded_at = provider._now()

        results = provider._search_sync("a", limit=1)  # matches RELIANCE and TCS's names
        assert len(results) == 1


@pytest.mark.asyncio
async def test_async_methods_wrap_the_sync_ones():
    """Same executor-wrapping pattern as YFinanceProvider — Kite's SDK is
    synchronous too."""
    provider = _provider_with_token()
    provider._kite.quote = MagicMock(return_value={
        "NSE:TCS": {"last_price": 100.0, "ohlc": {"open": 99, "high": 101, "low": 98, "close": 99},
                     "volume": 1000},
    })

    result = await provider.get_quote("TCS", "NSE")
    assert result["ltp"] == 100.0
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/Scripts/python.exe -m pytest tests/test_kite_provider.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.market.providers.kite_provider'`

- [ ] **Step 3: Write the implementation**

```python
# ai-trader-signals/app/market/providers/kite_provider.py
"""
KiteProvider — real Zerodha Kite Connect data for NSE/BSE.

Same contract as YFinanceProvider (see providers/base.py): callers never know
which vendor answered. Kite's SDK is synchronous, same as yfinance's, so
every public method wraps its sync half in run_in_executor, identical to
YFinanceProvider's own pattern.

The current access_token lives in NestJS (refreshed daily by
kite_auth.refresh_session, called from a Celery beat task) — this class
fetches and caches it in-process for a few minutes rather than hitting NestJS
on every single Kite call.
"""
from __future__ import annotations

import asyncio
import logging
import time
from datetime import datetime, timedelta
from functools import partial
from typing import Any

import httpx
import pandas as pd
from kiteconnect import KiteConnect
from kiteconnect.exceptions import KiteException

from app.config import Settings
from app.market.intervals import clamp_days

logger = logging.getLogger(__name__)

# Same rationale as yfinance_provider.py's _VENDOR_ERRORS: these degrade to
# None/[], the caller's "no data" path. Anything else is a bug in our own
# code and is re-raised through logger.exception.
_VENDOR_ERRORS = (KiteException, httpx.HTTPError, KeyError, ValueError, TypeError, IndexError)

_TOKEN_TTL_SECONDS = 300
_INSTRUMENTS_TTL_SECONDS = 86400

_INTERVAL_MAP = {
    "1m": "minute", "5m": "5minute", "15m": "15minute", "1h": "60minute", "1d": "day",
}


class KiteProvider:
    def __init__(self, settings: Settings):
        self._settings = settings
        self._kite = KiteConnect(api_key=settings.zerodha_api_key)
        self._token_cached_at: float = 0.0
        self._instruments: dict[str, dict[str, dict[str, Any]]] = {}
        self._instruments_loaded_at: float = 0.0

    @staticmethod
    def _now() -> float:
        return time.monotonic()

    def _ensure_token(self) -> None:
        if self._now() - self._token_cached_at < _TOKEN_TTL_SECONDS and self._kite.access_token:
            return
        resp = httpx.get(
            f"{self._settings.api_service_url}/api/internal/broker/zerodha/session",
            headers={"x-internal-key": self._settings.internal_api_key},
            timeout=10,
        )
        resp.raise_for_status()
        token = resp.json().get("accessToken")
        if not token:
            raise httpx.HTTPError("No Zerodha access token stored yet")
        self._kite.set_access_token(token)
        self._token_cached_at = self._now()

    def _ensure_instruments(self) -> None:
        if self._instruments and self._now() - self._instruments_loaded_at < _INSTRUMENTS_TTL_SECONDS:
            return
        for exch in ("NSE", "BSE"):
            rows = self._kite.instruments(exch)
            self._instruments[exch] = {
                r["tradingsymbol"]: r for r in rows if r.get("instrument_type") == "EQ"
            }
        self._instruments_loaded_at = self._now()

    # ------------------------------------------------------------------
    # get_quote
    # ------------------------------------------------------------------
    async def get_quote(self, symbol: str, exchange: str) -> dict | None:
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(None, self._get_quote_sync, symbol, exchange)

    def _get_quote_sync(self, symbol: str, exchange: str) -> dict | None:
        try:
            self._ensure_token()
            key = f"{exchange.upper()}:{symbol.upper()}"
            data = self._kite.quote(key)[key]
            ltp = float(data["last_price"])
            ohlc = data["ohlc"]
            prev_close = float(ohlc["close"])
            change = ltp - prev_close
            change_pct = (change / prev_close * 100) if prev_close else 0.0
            return {
                "symbol": symbol.upper(),
                "exchange": exchange.upper(),
                "ltp": round(ltp, 4),
                "change": round(change, 4),
                "change_percent": round(change_pct, 4),
                "open": float(ohlc["open"]),
                "high": float(ohlc["high"]),
                "low": float(ohlc["low"]),
                "prev_close": round(prev_close, 4),
                "volume": data.get("volume"),
            }
        except _VENDOR_ERRORS as e:
            logger.warning("Kite quote fetch failed for %s/%s: %s", symbol, exchange, e)
            return None

    # ------------------------------------------------------------------
    # get_historical_df
    # ------------------------------------------------------------------
    async def get_historical_df(
        self, symbol: str, exchange: str, interval: str, days: int
    ) -> pd.DataFrame | None:
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(
            None, partial(self._get_historical_df_sync, symbol, exchange, interval, days)
        )

    def _get_historical_df_sync(
        self, symbol: str, exchange: str, interval: str, days: int
    ) -> pd.DataFrame | None:
        try:
            self._ensure_token()
            self._ensure_instruments()
            row = self._instruments.get(exchange.upper(), {}).get(symbol.upper())
            if row is None:
                return None

            to_date = datetime.now()
            from_date = to_date - timedelta(days=clamp_days(interval, days))
            kite_interval = _INTERVAL_MAP.get(interval, "15minute")

            candles = self._kite.historical_data(
                row["instrument_token"], from_date, to_date, kite_interval,
            )
            if not candles:
                return None

            df = pd.DataFrame(candles).set_index("date")
            df.index = pd.to_datetime(df.index).tz_localize(None)
            return df[["open", "high", "low", "close", "volume"]]
        except _VENDOR_ERRORS as e:
            logger.warning("Kite historical fetch failed for %s/%s: %s", symbol, exchange, e)
            return None

    # ------------------------------------------------------------------
    # search
    # ------------------------------------------------------------------
    async def search(self, query: str, limit: int) -> list[dict]:
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(None, self._search_sync, query, limit)

    def _search_sync(self, query: str, limit: int) -> list[dict]:
        try:
            self._ensure_instruments()
            q = query.strip().lower()
            if not q:
                return []
            results = []
            for exch in ("NSE", "BSE"):
                for symbol, row in self._instruments.get(exch, {}).items():
                    name = row.get("name") or symbol
                    if q in symbol.lower() or q in name.lower():
                        results.append({"symbol": symbol, "name": name, "exchange": exch})
                        if len(results) >= limit:
                            return results
            return results
        except _VENDOR_ERRORS as e:
            logger.warning("Kite search failed for %r: %s", query, e)
            return []
```

- [ ] **Step 4: Run test to verify it passes**

Run: `.venv/Scripts/python.exe -m pytest tests/test_kite_provider.py -v`
Expected: PASS — 8 tests

- [ ] **Step 5: Run ruff and mypy**

Run: `.venv/Scripts/python.exe -m ruff check app/market/providers/kite_provider.py tests/test_kite_provider.py`
Expected: clean

Run: `.venv/Scripts/python.exe -m mypy app/market/providers/kite_provider.py`
Expected: clean (if `kiteconnect` ships no stubs, add `"kiteconnect.*"` to the same mypy override list `pyproject.toml:67` already uses for `yfinance`/`pandas_ta`/`cachetools`)

- [ ] **Step 6: Commit**

```bash
git add app/market/providers/kite_provider.py tests/test_kite_provider.py
git commit -m "feat: KiteProvider — real NSE/BSE quotes, history, and search"
```

---

### Task 6: Python — router wiring, fallback, and search merge

**Files:**
- Modify: `ai-trader-signals/app/market/providers/registry.py`
- Test: `ai-trader-signals/tests/test_market_router.py` (new — no existing router test file to extend)

**Interfaces:**
- Consumes: `KiteProvider` from Task 5
- Produces: `MarketDataRouter.providers["NSE"]` / `["BSE"]` are `KiteProvider` instances; `get_quote`/`get_historical_df` fall back to `self.fallback` on a Kite miss; `search` merges both.

- [ ] **Step 1: Write the failing tests**

```python
# ai-trader-signals/tests/test_market_router.py
"""
MarketDataRouter's fallback behaviour: Kite is the real NSE/BSE vendor now,
but yfinance is still there as a safety net. Anything that would otherwise
show up as "no data" instead rides the fallback provider, invisibly.
"""
from __future__ import annotations

import pandas as pd
import pytest

from app.market.providers.registry import MarketDataRouter


class _FakeProvider:
    def __init__(self, quote=None, df=None, search_results=None, raises=False):
        self._quote = quote
        self._df = df
        self._search_results = search_results or []
        self._raises = raises
        self.calls: list[str] = []

    async def get_quote(self, symbol, exchange):
        self.calls.append("get_quote")
        if self._raises:
            return None
        return self._quote

    async def get_historical_df(self, symbol, exchange, interval, days):
        self.calls.append("get_historical_df")
        if self._raises:
            return None
        return self._df

    async def search(self, query, limit):
        self.calls.append("search")
        return self._search_results[:limit]


def _router_with(kite: _FakeProvider, fallback: _FakeProvider) -> MarketDataRouter:
    router = MarketDataRouter()
    router.fallback = fallback
    router.providers["NSE"] = kite
    router.providers["BSE"] = kite
    return router


@pytest.mark.asyncio
async def test_a_kite_quote_is_used_when_it_succeeds():
    kite = _FakeProvider(quote={"symbol": "RELIANCE", "ltp": 1290})
    fallback = _FakeProvider(quote={"symbol": "RELIANCE", "ltp": 1111})
    router = _router_with(kite, fallback)

    result = await router.get_quote("RELIANCE", "NSE", bypass_cache=True)

    assert result["ltp"] == 1290
    assert "get_quote" not in fallback.calls


@pytest.mark.asyncio
async def test_falls_back_to_yfinance_when_kite_returns_none():
    kite = _FakeProvider(raises=True)
    fallback = _FakeProvider(quote={"symbol": "RELIANCE", "ltp": 1111})
    router = _router_with(kite, fallback)

    result = await router.get_quote("RELIANCE", "NSE", bypass_cache=True)

    assert result["ltp"] == 1111


@pytest.mark.asyncio
async def test_historical_data_falls_back_the_same_way():
    kite = _FakeProvider(raises=True)
    df = pd.DataFrame({"open": [1], "high": [1], "low": [1], "close": [1], "volume": [1]})
    fallback = _FakeProvider(df=df)
    router = _router_with(kite, fallback)

    result = await router.get_historical_df("RELIANCE", "NSE", "1d", 30, bypass_cache=True)

    assert result is not None
    assert len(result) == 1


@pytest.mark.asyncio
async def test_nasdaq_never_touches_kite():
    """NSE/BSE-only vendor — an exchange with no entry in `providers` should
    never even attempt the Kite path."""
    kite = _FakeProvider(quote={"symbol": "AAPL", "ltp": 999})  # would be wrong if ever used
    fallback = _FakeProvider(quote={"symbol": "AAPL", "ltp": 230})
    router = _router_with(kite, fallback)

    result = await router.get_quote("AAPL", "NASDAQ", bypass_cache=True)

    assert result["ltp"] == 230
    assert kite.calls == []


@pytest.mark.asyncio
async def test_search_merges_kite_and_yfinance_results():
    kite = _FakeProvider(search_results=[{"symbol": "RELIANCE", "name": "Reliance", "exchange": "NSE"}])
    fallback = _FakeProvider(search_results=[{"symbol": "AAPL", "name": "Apple", "exchange": "NASDAQ"}])
    router = _router_with(kite, fallback)

    results = await router.search("re", limit=8)

    symbols = {r["symbol"] for r in results}
    assert symbols == {"RELIANCE", "AAPL"}


@pytest.mark.asyncio
async def test_search_respects_the_combined_limit():
    kite = _FakeProvider(search_results=[{"symbol": f"K{i}", "name": "x", "exchange": "NSE"} for i in range(5)])
    fallback = _FakeProvider(search_results=[{"symbol": f"Y{i}", "name": "x", "exchange": "NASDAQ"} for i in range(5)])
    router = _router_with(kite, fallback)

    results = await router.search("x", limit=6)

    assert len(results) == 6
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/Scripts/python.exe -m pytest tests/test_market_router.py -v`
Expected: FAIL — quote/historical tests currently pass trivially (no fallback exists yet, so they'd fail differently); most tellingly, `test_falls_back_to_yfinance_when_kite_returns_none` and `test_historical_data_falls_back_the_same_way` FAIL because today's router has no fallback logic at all and returns `None`

- [ ] **Step 3: Modify `get_quote` and `get_historical_df` to fall back**

In `app/market/providers/registry.py`, replace the line:

```python
                result = await self._provider_for(exchange).get_quote(symbol, exchange)
```

with:

```python
                provider = self._provider_for(exchange)
                result = await provider.get_quote(symbol, exchange)
                if result is None and provider is not self.fallback:
                    result = await self.fallback.get_quote(symbol, exchange)
```

And replace:

```python
                df = await self._provider_for(exchange).get_historical_df(
                    symbol, exchange, interval, days
                )
```

with:

```python
                provider = self._provider_for(exchange)
                df = await provider.get_historical_df(symbol, exchange, interval, days)
                if (df is None or df.empty) and provider is not self.fallback:
                    df = await self.fallback.get_historical_df(symbol, exchange, interval, days)
```

- [ ] **Step 4: Modify `search` to merge Kite + fallback**

Replace the existing `search` method:

```python
    async def search(self, query: str, limit: int = 8) -> list[dict]:
        """Symbol/company search. Not exchange-routed like everything else
        here — the caller does not know the exchange yet, that is what this
        answers — so it always asks the fallback vendor directly."""
        return await self.fallback.search(query, limit)
```

with:

```python
    async def search(self, query: str, limit: int = 8) -> list[dict]:
        """Symbol/company search across every exchange this app covers.

        Kite has no free-text search of its own, so KiteProvider answers from
        its own instrument dump — NSE/BSE only, real listings. The fallback
        vendor covers NASDAQ/NYSE the same way it always has. Both are asked
        and the results concatenated, capped at the combined limit — neither
        vendor knows about the other's half.
        """
        kite = self.providers.get("NSE")
        kite_results = await kite.search(query, limit) if kite is not None else []
        fallback_results = await self.fallback.search(query, limit)
        return (kite_results + fallback_results)[:limit]
```

- [ ] **Step 5: Wire KiteProvider into the router's providers dict**

In `app/market/providers/registry.py`, add the import:

```python
from app.market.providers.kite_provider import KiteProvider
```

In `MarketDataRouter.__init__`, after `self.providers: dict[str, MarketDataProvider] = {}`, add:

```python
        kite = KiteProvider(get_settings())
        self.providers["NSE"] = kite
        self.providers["BSE"] = kite
```

This needs `from app.config import get_settings` added to the imports too.

- [ ] **Step 6: Run test to verify it passes**

Run: `.venv/Scripts/python.exe -m pytest tests/test_market_router.py -v`
Expected: PASS — 6 tests

- [ ] **Step 7: Run the full test suite, ruff, mypy**

Run: `.venv/Scripts/python.exe -m pytest -q`
Expected: all tests pass, including every existing test that constructs a `MarketDataRouter()` — check for any test asserting `router.providers == {}` on a fresh router, which would now be false; update it to assert `set(router.providers) == {"NSE", "BSE"}` instead if found.

Run: `.venv/Scripts/python.exe -m ruff check app tests`
Run: `.venv/Scripts/python.exe -m mypy app`
Expected: both clean

- [ ] **Step 8: Commit**

```bash
git add app/market/providers/registry.py tests/test_market_router.py
git commit -m "feat: wire KiteProvider into the router with yfinance fallback"
```

---

### Task 7: Python — daily refresh task

**Files:**
- Modify: `ai-trader-signals/app/worker/celery_app.py`
- Modify: `ai-trader-signals/app/worker/tasks.py`
- Test: `ai-trader-signals/tests/test_kite_refresh_task.py`

**Interfaces:**
- Consumes: `kite_auth.refresh_session(settings)` from Task 4
- Produces: `app.worker.tasks.refresh_zerodha_session()` — a Celery task, scheduled daily at 06:00 IST

- [ ] **Step 1: Write the failing test**

```python
# ai-trader-signals/tests/test_kite_refresh_task.py
"""
The daily refresh task: log in, push the fresh token to NestJS. Mirrors
square_off_positions's shape in worker/tasks.py — a thin trigger, loud on
failure, no special-case handling needed beyond that (a failed refresh just
means the router's Kite-then-yfinance fallback quietly takes over for the
rest of that day — see the design spec's "Error handling" section).
"""
from __future__ import annotations

from unittest.mock import MagicMock, patch

from app.market.providers.kite_auth import KiteAuthError, KiteSession
from app.worker.tasks import refresh_zerodha_session


def test_a_successful_login_is_pushed_to_nestjs():
    session = KiteSession(access_token="tok_abc", nse_instruments=[], bse_instruments=[])

    with patch("app.worker.tasks.kite_auth.refresh_session", return_value=session) as mock_refresh, \
         patch("app.worker.tasks.httpx.put") as mock_put:
        mock_put.return_value = MagicMock(status_code=200)
        mock_put.return_value.raise_for_status = lambda: None

        result = refresh_zerodha_session()

    mock_refresh.assert_called_once()
    put_call = mock_put.call_args
    assert put_call.kwargs["json"] == {"accessToken": "tok_abc"}
    assert result == {"ok": True}


def test_a_login_failure_is_logged_and_returned_not_raised():
    """The whole point: a failed refresh must not crash the beat worker or
    take down anything else it schedules."""
    with patch("app.worker.tasks.kite_auth.refresh_session",
               side_effect=KiteAuthError("bad TOTP")):
        result = refresh_zerodha_session()

    assert result["ok"] is False
    assert "bad TOTP" in result["error"]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/Scripts/python.exe -m pytest tests/test_kite_refresh_task.py -v`
Expected: FAIL — `ImportError: cannot import name 'refresh_zerodha_session' from 'app.worker.tasks'`

- [ ] **Step 3: Add the beat schedule entry**

In `app/worker/celery_app.py`, add the import at the top if not already present (`from celery.schedules import crontab` is already imported). In the `beat_schedule` dict, after the `"morning-brief"` entry, add:

```python
        # Kite Connect's access_token expires ~6am IST. 06:00 is ahead of the
        # 06:30 morning brief and well ahead of the 09:15 open — see the
        # design spec for why a failed refresh here is not an emergency (the
        # router falls back to yfinance for the rest of that day).
        "refresh-zerodha-session": {
            "task": "app.worker.tasks.refresh_zerodha_session",
            "schedule": crontab(minute="0", hour="6"),
        },
```

- [ ] **Step 4: Write the task**

In `app/worker/tasks.py`, add the import at the top:

```python
from app.market.providers import kite_auth
```

Add the task, after `generate_morning_brief` (or at the end of the file):

```python
@celery.task(name="app.worker.tasks.refresh_zerodha_session")
def refresh_zerodha_session():
    """Daily Kite Connect login — 06:00 IST via Celery beat.

    A thin trigger: the actual login lives in kite_auth (proven live before
    this was written), this task just runs it and pushes the result to
    NestJS, the same shape as square_off_positions's call to the internal
    paper-trading endpoint above. On failure, logged loudly and returned —
    not re-raised — because a stale token in NestJS degrades gracefully (the
    router's Kite-then-yfinance fallback picks up every call that fails
    against it) rather than needing this task itself to retry aggressively.
    """
    settings = get_settings()
    try:
        session = kite_auth.refresh_session(settings)
    except kite_auth.KiteAuthError as e:
        logger.error("Zerodha session refresh failed: %s", e)
        return {"ok": False, "error": str(e)}

    try:
        resp = httpx.put(
            f"{settings.api_service_url}/api/internal/broker/zerodha/session",
            headers={"x-internal-key": settings.internal_api_key},
            json={"accessToken": session.access_token},
            timeout=10,
        )
        resp.raise_for_status()
    except httpx.HTTPError as e:
        logger.error("Zerodha session refreshed but NestJS write failed: %s", e)
        return {"ok": False, "error": str(e)}

    logger.info("Zerodha session refreshed and stored (%d NSE, %d BSE instruments)",
                len(session.nse_instruments), len(session.bse_instruments))
    return {"ok": True}
```

`get_settings` and `logger` are already imported/defined earlier in this file (`from app.config import get_settings`, `logger = logging.getLogger(__name__)`) — verify both are present before adding the task; add the `get_settings` import if this file only currently imports it inside functions rather than at module level.

- [ ] **Step 5: Run test to verify it passes**

Run: `.venv/Scripts/python.exe -m pytest tests/test_kite_refresh_task.py -v`
Expected: PASS — 2 tests

- [ ] **Step 6: Run the full suite, ruff, mypy**

Run: `.venv/Scripts/python.exe -m pytest -q`
Run: `.venv/Scripts/python.exe -m ruff check app tests`
Run: `.venv/Scripts/python.exe -m mypy app`
Expected: all clean

- [ ] **Step 7: Commit**

```bash
git add app/worker/celery_app.py app/worker/tasks.py tests/test_kite_refresh_task.py
git commit -m "feat: daily Celery beat task to refresh the Zerodha session"
```

---

### Task 8: End-to-end verification and deploy

**Files:** none (verification only)

- [ ] **Step 1: Set the real Zerodha settings in `ai-trader-signals`'s own environment**

The signals service needs its own copies of `ZERODHA_API_KEY`/`ZERODHA_API_SECRET` (matching `ai-trader-api/.env`'s values) plus `ZERODHA_USER_ID`/`PASSWORD`/`TOTP_SECRET`, and `INTERNAL_API_KEY` matching the API's — add these to `ai-trader-signals/.env` (create it from `.env.example` if it doesn't exist locally; on the deploy box it already exists per `DEPLOY.md`).

- [ ] **Step 2: Run the refresh task manually, once, locally**

Run: `.venv/Scripts/python.exe -c "from app.worker.tasks import refresh_zerodha_session; print(refresh_zerodha_session())"`
Expected: `{'ok': True}` — requires `ai-trader-api` running locally first (`npm run start:dev` in that repo) so the `PUT` succeeds.

- [ ] **Step 3: Confirm the token landed in NestJS**

Run: `curl -s http://localhost:8000/api/internal/broker/zerodha/session -H "x-internal-key: $(grep ^INTERNAL_API_KEY ai-trader-api/.env | cut -d= -f2)"`
Expected: a real `accessToken` and a `refreshedAt` from just now.

- [ ] **Step 4: Confirm a real chart request now uses Kite**

Run: `.venv/Scripts/python.exe -c "
import asyncio
from app.market.providers.registry import market_data_router
print(asyncio.run(market_data_router.get_quote('RELIANCE', 'NSE', bypass_cache=True)))
"`
Expected: a real quote dict with today's actual `ltp`.

- [ ] **Step 5: Commit and push both repos**

```bash
cd ai-trader-signals && git push
cd ../ai-trader-api && git push
```

- [ ] **Step 6: Deploy**

```bash
ssh -i ~/.ssh/ai-trader-admin.pem ubuntu@3.6.94.53 'cd ~/ai-trader && ./deploy.sh'
```

- [ ] **Step 7: Verify live**

Same as Steps 3-4, against `https://3.6.94.53.sslip.io/api/...` instead of `localhost:8000` — confirm the deployed box's `signals-beat` container picks up the new schedule (`docker logs ai-trader-signals-beat-1` should show the new `refresh-zerodha-session` entry in its schedule dump on startup) and that a live chat turn asking about RELIANCE reflects a real, current price.
