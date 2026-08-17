# Live Price Ticks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the terminal's 5-second REST quote polling with one socket-fed live-quote path for every symbol, over the existing `SignalsGateway`, with the Kite-vs-yfinance vendor decision made entirely in Python.

**Architecture:** Python's FastAPI process holds a persistent `KiteTicker` connection for NSE/BSE and a 5s poll loop (existing `market_data_router`) for everything else; both publish to one Redis channel. NestJS's existing gateway subscribes once and re-emits to the same `symbol:*` rooms it already has. The frontend gets one new hook, used unconditionally.

**Tech Stack:** `kiteconnect.KiteTicker`, `redis` (Python async client), `ioredis` (NestJS), `socket.io-client` (frontend), Redis (new docker-compose service).

**Spec:** `docs/superpowers/specs/2026-08-16-live-price-ticks-design.md`

## Global Constraints

- Frontend and NestJS never branch on exchange — the same `subscribe_symbol`/`unsubscribe_symbol` calls and the same `'tick'` event serve every symbol. Only Python decides Kite vs yfinance.
- The `symbol:${SYMBOL}` room-naming format is unchanged — `broadcastSignal` already emits to it and must keep working unmodified. Exchange is tracked in a separate side-map, never folded into the room key.
- `signals-1` needs no new auth guard on its two new routes — it is never internet-facing, same as every existing Python endpoint.
- The NestJS→Python subscribe/unsubscribe calls are retried once on network error (`retryOnNetworkError: true`), matching `UpstreamHttpClient`'s existing convention — they're idempotent.
- No REST-polling fallback if the browser's socket disconnects — it waits to reconnect. This applies uniformly, not just to NSE/BSE.
- Comments and docstrings state the current behavior and its non-obvious reason only — no "this fixes bug X" narrative. That belongs in commit messages.
- When old code is replaced, delete it outright — never leave it commented out.

---

### Task 1: Redis in docker-compose

**Files:**
- Modify: `docker-compose.yml`

- [ ] **Step 1: Add the service**

In `docker-compose.yml`, add a new service before `signals:` (top of the `services:` block):

```yaml
  # ── Redis: live-tick pub/sub between signals and api ────────────────
  redis:
    image: redis:7-alpine
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 3s
      retries: 5
      start_period: 5s
    restart: unless-stopped
```

- [ ] **Step 2: Make signals and api wait for it**

In the `signals:` service's `depends_on:` block, add:

```yaml
    depends_on:
      redis:
        condition: service_healthy
```

(alongside whatever `depends_on` entries already exist there — check the file first, this is additive, not a replacement of the block).

In the `api:` service's `depends_on:` block, add the same `redis: condition: service_healthy` entry alongside its existing `signals: condition: service_healthy`.

- [ ] **Step 3: Verify it starts**

Run: `docker compose up -d redis`
Then: `docker compose exec redis redis-cli ping`
Expected: `PONG`

- [ ] **Step 4: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: add Redis for live-tick pub/sub between signals and api"
```

---

### Task 2: Python — `kite_ticker.py` (the Kite WebSocket wrapper)

**Files:**
- Create: `ai-trader-signals/app/market/kite_ticker.py`
- Test: `ai-trader-signals/tests/test_kite_ticker.py`

**Interfaces:**
- Produces: `KiteTickerClient` class — `subscribe(symbol: str, exchange: str) -> bool`, `unsubscribe(symbol: str, exchange: str) -> None`, constructed as `KiteTickerClient(settings, kite_provider, on_tick)` where `on_tick: Callable[[dict], None]` receives a shaped quote dict on every tick.

- [ ] **Step 1: Write the failing tests**

```python
# ai-trader-signals/tests/test_kite_ticker.py
"""
KiteTicker wrapper — owns the one persistent Kite WebSocket connection.
Nothing here knows about non-Kite exchanges; that decision lives in
live_ticks.py.
"""
from __future__ import annotations

from unittest.mock import MagicMock

from app.market.kite_ticker import KiteTickerClient


def _client(on_tick=None):
    provider = MagicMock()
    provider._instruments = {
        "NSE": {"RELIANCE": {"tradingsymbol": "RELIANCE", "instrument_token": 738561}},
        "BSE": {},
    }
    provider._ensure_instruments = MagicMock()
    ws = MagicMock()
    client = KiteTickerClient(api_key="key", access_token="tok",
                               kite_provider=provider, on_tick=on_tick or MagicMock())
    client._ticker = ws
    return client, provider, ws


def test_subscribe_resolves_the_token_and_calls_the_sdk():
    client, provider, ws = _client()

    ok = client.subscribe("RELIANCE", "NSE")

    assert ok is True
    ws.subscribe.assert_called_once_with([738561])
    provider._ensure_instruments.assert_called_once()


def test_subscribe_to_an_unresolvable_symbol_fails_closed():
    client, provider, ws = _client()

    ok = client.subscribe("NOTREAL", "NSE")

    assert ok is False
    ws.subscribe.assert_not_called()


def test_unsubscribe_resolves_the_same_token():
    client, provider, ws = _client()
    client.subscribe("RELIANCE", "NSE")

    client.unsubscribe("RELIANCE", "NSE")

    ws.unsubscribe.assert_called_once_with([738561])


def test_on_ticks_resolves_token_back_to_symbol_and_shapes_a_quote():
    seen = []
    client, provider, ws = _client(on_tick=seen.append)
    client.subscribe("RELIANCE", "NSE")

    client._on_ticks(ws, [{
        "instrument_token": 738561, "last_price": 1310.0,
        "ohlc": {"open": 1300.0, "high": 1315.0, "low": 1295.0, "close": 1300.0},
        "volume_traded": 500000,
    }])

    assert len(seen) == 1
    quote = seen[0]
    assert quote["symbol"] == "RELIANCE"
    assert quote["exchange"] == "NSE"
    assert quote["ltp"] == 1310.0
    assert quote["prev_close"] == 1300.0
    assert quote["volume"] == 500000


def test_a_tick_for_an_unknown_token_is_dropped_not_raised():
    seen = []
    client, provider, ws = _client(on_tick=seen.append)

    client._on_ticks(ws, [{"instrument_token": 999999, "last_price": 1.0,
                            "ohlc": {"open": 1, "high": 1, "low": 1, "close": 1},
                            "volume_traded": 0}])

    assert seen == []
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/Scripts/python.exe -m pytest tests/test_kite_ticker.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.market.kite_ticker'`

- [ ] **Step 3: Write the implementation**

```python
# ai-trader-signals/app/market/kite_ticker.py
"""
The one persistent Kite Connect WebSocket connection for this process —
real-time ticks for NSE/BSE. Everything non-Kite lives in live_ticks.py,
which is the only thing that imports this module.

KiteTicker resubscribes every currently-subscribed token on its own
whenever the underlying WebSocket reconnects (its _on_open calls
self.resubscribe() from its own in-memory state) — nothing here
duplicates that. That in-memory state does not survive this whole
process restarting; live_ticks.py's resubscribe_from() is what covers
that case, by calling subscribe() again for whatever was active.
"""
from __future__ import annotations

import logging
from typing import Any, Callable

from kiteconnect import KiteTicker

logger = logging.getLogger(__name__)


def _quote_from_tick(symbol: str, exchange: str, tick: dict[str, Any]) -> dict[str, Any]:
    ohlc = tick.get("ohlc") or {}
    ltp = float(tick["last_price"])
    prev_close = float(ohlc.get("close", ltp))
    change = ltp - prev_close
    change_pct = (change / prev_close * 100) if prev_close else 0.0
    return {
        "symbol": symbol,
        "exchange": exchange,
        "ltp": round(ltp, 4),
        "change": round(change, 4),
        "change_percent": round(change_pct, 4),
        "open": ohlc.get("open"),
        "high": ohlc.get("high"),
        "low": ohlc.get("low"),
        "prev_close": round(prev_close, 4),
        "volume": tick.get("volume_traded"),
    }


class KiteTickerClient:
    def __init__(self, api_key: str, access_token: str, kite_provider,
                 on_tick: Callable[[dict[str, Any]], None]):
        self._provider = kite_provider
        self._on_tick = on_tick
        self._token_map: dict[int, tuple[str, str]] = {}
        self._ticker = KiteTicker(api_key, access_token)
        self._ticker.on_ticks = self._on_ticks

    def connect(self) -> None:
        self._ticker.connect(threaded=True)

    def close(self) -> None:
        self._ticker.close()

    def _resolve(self, symbol: str, exchange: str) -> int | None:
        self._provider._ensure_instruments()
        row = self._provider._instruments.get(exchange.upper(), {}).get(symbol.upper())
        return row["instrument_token"] if row else None

    def subscribe(self, symbol: str, exchange: str) -> bool:
        token = self._resolve(symbol, exchange)
        if token is None:
            logger.warning("Kite ticker: no instrument token for %s/%s", symbol, exchange)
            return False
        self._token_map[token] = (symbol.upper(), exchange.upper())
        self._ticker.subscribe([token])
        return True

    def unsubscribe(self, symbol: str, exchange: str) -> None:
        token = self._resolve(symbol, exchange)
        if token is None:
            return
        self._token_map.pop(token, None)
        self._ticker.unsubscribe([token])

    def _on_ticks(self, ws, ticks: list[dict[str, Any]]) -> None:
        for tick in ticks:
            pair = self._token_map.get(tick.get("instrument_token"))
            if pair is None:
                continue
            symbol, exchange = pair
            self._on_tick(_quote_from_tick(symbol, exchange, tick))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `.venv/Scripts/python.exe -m pytest tests/test_kite_ticker.py -v`
Expected: PASS — 5 tests

- [ ] **Step 5: Run ruff and mypy**

Run: `.venv/Scripts/python.exe -m ruff check app/market/kite_ticker.py tests/test_kite_ticker.py`
Run: `.venv/Scripts/python.exe -m mypy app/market/kite_ticker.py`
Expected: both clean

- [ ] **Step 6: Commit**

```bash
git add app/market/kite_ticker.py tests/test_kite_ticker.py
git commit -m "feat: KiteTickerClient — the persistent Kite WebSocket connection"
```

---

### Task 3: Python — `live_ticks.py` (the exchange dispatcher)

**Files:**
- Create: `ai-trader-signals/app/market/live_ticks.py`
- Test: `ai-trader-signals/tests/test_live_ticks.py`

**Interfaces:**
- Consumes: `KiteTickerClient` from Task 2 (`subscribe`, `unsubscribe`, `connect`, `close`)
- Produces: `LiveTicks` class — `subscribe(symbol, exchange) -> None` (async), `unsubscribe(symbol, exchange) -> None` (async), `resubscribe_from(active: list[tuple[str, str]]) -> None` (async), `publish(payload: dict) -> None` (async), `close() -> None` (async). Constructed as `LiveTicks(kite_ticker, redis_client, get_quote_fn, poll_interval_seconds=5)`.

- [ ] **Step 1: Write the failing tests**

```python
# ai-trader-signals/tests/test_live_ticks.py
"""
live_ticks — the exchange router for live price updates. NSE/BSE route to
the Kite ticker; everything else gets a polled loop over the same
market-data path every other quote call already uses. Both publish to the
same Redis channel in the same shape, so nothing downstream needs to know
which one answered.
"""
from __future__ import annotations

import asyncio
import json
from unittest.mock import AsyncMock, MagicMock

import pytest

from app.market.live_ticks import LiveTicks


def _live_ticks(get_quote=None):
    kite_ticker = MagicMock()
    kite_ticker.subscribe = MagicMock(return_value=True)
    kite_ticker.unsubscribe = MagicMock()
    redis_client = AsyncMock()
    quote_fn = get_quote or AsyncMock(return_value={"symbol": "AAPL", "exchange": "NASDAQ", "ltp": 230.0})
    live = LiveTicks(kite_ticker, redis_client, quote_fn, poll_interval_seconds=0.01)
    return live, kite_ticker, redis_client, quote_fn


@pytest.mark.asyncio
async def test_nse_bse_routes_to_the_kite_ticker():
    live, kite_ticker, redis_client, _ = _live_ticks()

    await live.subscribe("RELIANCE", "NSE")

    kite_ticker.subscribe.assert_called_once_with("RELIANCE", "NSE")


@pytest.mark.asyncio
async def test_other_exchanges_start_a_poll_loop_not_the_kite_ticker():
    live, kite_ticker, redis_client, quote_fn = _live_ticks()

    await live.subscribe("AAPL", "NASDAQ")
    await asyncio.sleep(0.03)
    await live.unsubscribe("AAPL", "NASDAQ")

    kite_ticker.subscribe.assert_not_called()
    assert quote_fn.await_count >= 1
    published = json.loads(redis_client.publish.call_args_list[0].args[1])
    assert published["symbol"] == "AAPL"


@pytest.mark.asyncio
async def test_a_second_subscribe_to_an_already_watched_poll_symbol_is_a_noop():
    live, kite_ticker, redis_client, quote_fn = _live_ticks()

    await live.subscribe("AAPL", "NASDAQ")
    await live.subscribe("AAPL", "NASDAQ")
    await asyncio.sleep(0.03)
    tasks_running = len(live._poll_tasks)
    await live.unsubscribe("AAPL", "NASDAQ")

    assert tasks_running == 1


@pytest.mark.asyncio
async def test_unsubscribe_stops_the_poll_loop():
    live, kite_ticker, redis_client, quote_fn = _live_ticks()
    await live.subscribe("AAPL", "NASDAQ")
    await asyncio.sleep(0.03)

    await live.unsubscribe("AAPL", "NASDAQ")
    calls_at_unsubscribe = quote_fn.await_count
    await asyncio.sleep(0.03)

    assert quote_fn.await_count == calls_at_unsubscribe
    assert ("AAPL", "NASDAQ") not in live._poll_tasks


@pytest.mark.asyncio
async def test_resubscribe_from_routes_each_pair_through_the_same_logic():
    live, kite_ticker, redis_client, quote_fn = _live_ticks()

    await live.resubscribe_from([("RELIANCE", "NSE"), ("AAPL", "NASDAQ")])
    await asyncio.sleep(0.03)
    await live.unsubscribe("AAPL", "NASDAQ")

    kite_ticker.subscribe.assert_called_once_with("RELIANCE", "NSE")
    assert quote_fn.await_count >= 1


@pytest.mark.asyncio
async def test_publish_writes_to_the_market_ticks_channel():
    live, _, redis_client, _ = _live_ticks()

    await live.publish({"symbol": "RELIANCE", "exchange": "NSE", "ltp": 1310.0})

    redis_client.publish.assert_called_once()
    channel, message = redis_client.publish.call_args.args
    assert channel == "market:ticks"
    assert json.loads(message)["symbol"] == "RELIANCE"


@pytest.mark.asyncio
async def test_close_cancels_every_running_poll_task():
    live, _, _, _ = _live_ticks()
    await live.subscribe("AAPL", "NASDAQ")
    await live.subscribe("MSFT", "NASDAQ")

    await live.close()

    assert live._poll_tasks == {}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/Scripts/python.exe -m pytest tests/test_live_ticks.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.market.live_ticks'`

- [ ] **Step 3: Write the implementation**

```python
# ai-trader-signals/app/market/live_ticks.py
"""
Exchange router for live price updates — NSE/BSE go to the real Kite
ticker, everything else gets a poll loop over the same market-data path
every other quote call already uses. Mirrors
MarketDataRouter._provider_for(exchange)'s existing role for
quotes/historical/search; this is the equivalent for live ticks.
"""
from __future__ import annotations

import asyncio
import json
import logging
from typing import Any, Awaitable, Callable

logger = logging.getLogger(__name__)

_KITE_EXCHANGES = {"NSE", "BSE"}
_CHANNEL = "market:ticks"


class LiveTicks:
    def __init__(self, kite_ticker, redis_client,
                 get_quote: Callable[[str, str], Awaitable[dict[str, Any] | None]],
                 poll_interval_seconds: float = 5.0):
        self._kite = kite_ticker
        self._redis = redis_client
        self._get_quote = get_quote
        self._poll_interval = poll_interval_seconds
        self._poll_tasks: dict[tuple[str, str], asyncio.Task] = {}

    async def subscribe(self, symbol: str, exchange: str) -> None:
        key = (symbol.upper(), exchange.upper())
        if exchange.upper() in _KITE_EXCHANGES:
            self._kite.subscribe(symbol, exchange)
            return
        if key in self._poll_tasks:
            return
        self._poll_tasks[key] = asyncio.create_task(self._poll_loop(*key))

    async def unsubscribe(self, symbol: str, exchange: str) -> None:
        key = (symbol.upper(), exchange.upper())
        if exchange.upper() in _KITE_EXCHANGES:
            self._kite.unsubscribe(symbol, exchange)
            return
        task = self._poll_tasks.pop(key, None)
        if task:
            task.cancel()

    async def resubscribe_from(self, active: list[tuple[str, str]]) -> None:
        for symbol, exchange in active:
            await self.subscribe(symbol, exchange)

    async def publish(self, payload: dict[str, Any]) -> None:
        await self._redis.publish(_CHANNEL, json.dumps(payload))

    async def close(self) -> None:
        for task in self._poll_tasks.values():
            task.cancel()
        self._poll_tasks.clear()

    async def _poll_loop(self, symbol: str, exchange: str) -> None:
        # bypass_cache: this loop IS the fresh-data source now, shared by
        # every watcher of this symbol — no reason for it to serve its own
        # stale cache entry back to itself every 5s.
        try:
            while True:
                quote = await self._get_quote(symbol, exchange)
                if quote:
                    await self.publish(quote)
                await asyncio.sleep(self._poll_interval)
        except asyncio.CancelledError:
            pass
```

- [ ] **Step 4: Run test to verify it passes**

Run: `.venv/Scripts/python.exe -m pytest tests/test_live_ticks.py -v`
Expected: PASS — 7 tests

- [ ] **Step 5: Run ruff and mypy**

Run: `.venv/Scripts/python.exe -m ruff check app/market/live_ticks.py tests/test_live_ticks.py`
Run: `.venv/Scripts/python.exe -m mypy app/market/live_ticks.py`
Expected: both clean

- [ ] **Step 6: Commit**

```bash
git add app/market/live_ticks.py tests/test_live_ticks.py
git commit -m "feat: LiveTicks — routes each symbol's live updates to Kite or a poll loop"
```

---

### Task 4: Python — dependencies, settings, routes, and startup wiring

**Files:**
- Modify: `ai-trader-signals/requirements.txt`
- Modify: `ai-trader-signals/app/config.py`
- Modify: `ai-trader-signals/app/market/router.py`
- Modify: `ai-trader-signals/main.py`
- Test: `ai-trader-signals/tests/test_live_ticks_routes.py`

**Interfaces:**
- Consumes: `LiveTicks` from Task 3 (`subscribe`, `unsubscribe`)

- [ ] **Step 1: Add the Redis dependency**

In `requirements.txt`, add after the `kiteconnect`/`pyotp` lines:

```
redis>=5.0.0
```

Run: `.venv/Scripts/python.exe -m pip install -r requirements.txt`

- [ ] **Step 2: Add the setting**

In `app/config.py`'s `Settings` class, add after the `internal_api_key` line:

```python
    redis_url: str = "redis://redis:6379/0"
```

- [ ] **Step 3: Write the failing route tests**

```python
# ai-trader-signals/tests/test_live_ticks_routes.py
from __future__ import annotations

from unittest.mock import AsyncMock

from fastapi.testclient import TestClient

import app.market.router as router_module
from main import app


def test_subscribe_route_calls_live_ticks(monkeypatch):
    live_ticks = AsyncMock()
    monkeypatch.setattr(router_module, "live_ticks", live_ticks)
    client = TestClient(app)

    resp = client.post("/market/internal/live-ticks/subscribe",
                        json={"symbol": "RELIANCE", "exchange": "NSE"})

    assert resp.status_code == 200
    assert resp.json() == {"ok": True}
    live_ticks.subscribe.assert_awaited_once_with("RELIANCE", "NSE")


def test_unsubscribe_route_calls_live_ticks(monkeypatch):
    live_ticks = AsyncMock()
    monkeypatch.setattr(router_module, "live_ticks", live_ticks)
    client = TestClient(app)

    resp = client.post("/market/internal/live-ticks/unsubscribe",
                        json={"symbol": "RELIANCE", "exchange": "NSE"})

    assert resp.status_code == 200
    live_ticks.unsubscribe.assert_awaited_once_with("RELIANCE", "NSE")
```

- [ ] **Step 4: Run test to verify it fails**

Run: `.venv/Scripts/python.exe -m pytest tests/test_live_ticks_routes.py -v`
Expected: FAIL — `AttributeError: module 'app.market.router' has no attribute 'live_ticks'`

- [ ] **Step 5: Add the routes**

In `app/market/router.py`, add the import at the top:

```python
from pydantic import BaseModel

from app.market.live_ticks import LiveTicks
```

Add a module-level placeholder the routes call into (the real instance is assigned by `main.py`'s lifespan hook — Task 4 Step 6 below):

```python
live_ticks: LiveTicks | None = None


class _SymbolExchange(BaseModel):
    symbol: str
    exchange: str


@router.post("/internal/live-ticks/subscribe")
async def subscribe_live_ticks(body: _SymbolExchange):
    """Called by NestJS on a symbol room's first watcher. No auth guard —
    signals-1 is never internet-facing, same as every route above."""
    assert live_ticks is not None, "live_ticks not initialized"
    await live_ticks.subscribe(body.symbol, body.exchange)
    return {"ok": True}


@router.post("/internal/live-ticks/unsubscribe")
async def unsubscribe_live_ticks(body: _SymbolExchange):
    """Called by NestJS on a symbol room's last watcher leaving."""
    assert live_ticks is not None, "live_ticks not initialized"
    await live_ticks.unsubscribe(body.symbol, body.exchange)
    return {"ok": True}
```

- [ ] **Step 6: Wire startup/shutdown in `main.py`**

In `main.py`, add imports:

```python
import httpx
import redis.asyncio as redis

from app.market import router as market_router_module
from app.market.kite_ticker import KiteTickerClient
from app.market.live_ticks import LiveTicks
from app.market.providers.kite_provider import KiteProvider
from app.market.service import get_quote
```

(Note: `market_router` is already imported as `from app.market.router import router as market_router` — this new `market_router_module` import is the *module* itself, needed to set its `live_ticks` module-level variable; both imports coexist, they reference the same module by different names for different purposes.)

Modify the `lifespan` function:

```python
@asynccontextmanager
async def lifespan(app: FastAPI):
    executor = ThreadPoolExecutor(
        max_workers=EXECUTOR_MAX_WORKERS, thread_name_prefix="signals-io"
    )
    asyncio.get_running_loop().set_default_executor(executor)
    logger.info("Default executor bounded to %d threads", EXECUTOR_MAX_WORKERS)

    settings = get_settings()
    redis_client = redis.from_url(settings.redis_url)
    live_ticks = None
    if settings.zerodha_api_key and settings.zerodha_access_token:
        kite_provider = KiteProvider(settings)
        kite_ticker = KiteTickerClient(
            api_key=settings.zerodha_api_key,
            access_token=settings.zerodha_access_token,
            kite_provider=kite_provider,
            on_tick=lambda payload: asyncio.create_task(live_ticks.publish(payload)),
        )
        kite_ticker.connect()
        live_ticks = LiveTicks(kite_ticker, redis_client, get_quote)
        market_router_module.live_ticks = live_ticks

        try:
            resp = await httpx.AsyncClient().get(
                f"{settings.api_service_url}/api/internal/market/active-symbols",
                headers={"x-internal-key": settings.internal_api_key},
                timeout=10,
            )
            resp.raise_for_status()
            active = [(row["symbol"], row["exchange"]) for row in resp.json()]
            await live_ticks.resubscribe_from(active)
        except httpx.HTTPError as e:
            logger.error("Could not fetch active symbols on startup: %s", e)
    else:
        logger.warning("No Zerodha access token configured — live ticks disabled")

    try:
        yield
    finally:
        if live_ticks:
            await live_ticks.close()
            kite_ticker.close()
        await redis_client.aclose()
        executor.shutdown(wait=False, cancel_futures=True)
```

Note: `settings.zerodha_access_token` does not exist yet as a settings field — `KiteTickerClient` needs a *current* access token, the same one `KiteProvider._ensure_token()` fetches from NestJS. Add a small settings field and a one-time fetch: add `zerodha_access_token: str = ""` is wrong here since the token is dynamic, not a static env var. Replace the `if settings.zerodha_api_key and settings.zerodha_access_token:` branch's precondition and the `access_token=` argument above with a fetch through the same internal endpoint `KiteProvider._ensure_token()` already calls:

```python
    access_token = None
    if settings.zerodha_api_key:
        try:
            resp = await httpx.AsyncClient().get(
                f"{settings.api_service_url}/api/internal/broker/zerodha/session",
                headers={"x-internal-key": settings.internal_api_key},
                timeout=10,
            )
            resp.raise_for_status()
            access_token = resp.json().get("accessToken")
        except httpx.HTTPError as e:
            logger.error("Could not fetch Zerodha session on startup: %s", e)

    live_ticks = None
    if access_token:
        kite_provider = KiteProvider(settings)
        kite_ticker = KiteTickerClient(
            api_key=settings.zerodha_api_key,
            access_token=access_token,
            kite_provider=kite_provider,
            on_tick=lambda payload: asyncio.create_task(live_ticks.publish(payload)),
        )
```

(this replaces the `if settings.zerodha_api_key and settings.zerodha_access_token:` line and the `access_token=settings.zerodha_access_token,` line from the block above — the rest of the lifespan function is unchanged).

- [ ] **Step 7: Run test to verify it passes**

Run: `.venv/Scripts/python.exe -m pytest tests/test_live_ticks_routes.py -v`
Expected: PASS — 2 tests

- [ ] **Step 8: Run the full suite, ruff, mypy**

Run: `.venv/Scripts/python.exe -m pytest -q`
Run: `.venv/Scripts/python.exe -m ruff check app tests main.py`
Run: `.venv/Scripts/python.exe -m mypy app main.py`
Expected: all clean. If mypy complains about the `lambda` capturing `live_ticks` before it's assigned (a real forward-reference issue in the closure), restructure as a small local function defined after `live_ticks = LiveTicks(...)` instead of a lambda defined before it — the `on_tick` callback is only ever invoked after `kite_ticker.connect()` runs, by which point `live_ticks` exists, but the *lambda's own definition* referencing a not-yet-assigned name is what mypy/ruff will flag; move the `KiteTickerClient(...)` construction to after `live_ticks = LiveTicks(...)`, passing `on_tick=live_ticks_ref.publish_sync` — simplest fix: define `live_ticks = LiveTicks(kite_ticker=None, ...)` is awkward since `LiveTicks` doesn't need to know about `kite_ticker` beyond construction — instead, construct `live_ticks` first with a placeholder, then `kite_ticker` referencing `live_ticks.publish` directly is not what's needed either. Cleanest fix, apply directly: swap the construction order — build `LiveTicks` first without a `kite_ticker` reference (it's only used inside `subscribe`/`unsubscribe`, not at construction), then build `KiteTickerClient` referencing `live_ticks.publish` in its `on_tick`, then assign `live_ticks._kite = kite_ticker` isn't clean either since `LiveTicks.__init__` requires `kite_ticker` as a positional arg per Task 3's design. Use a mutable one-item list as a forward-reference cell instead: `live_ticks_ref: list = []`, `on_tick=lambda payload: asyncio.create_task(live_ticks_ref[0].publish(payload))`, then after `live_ticks = LiveTicks(...)`, `live_ticks_ref.append(live_ticks)`. Use this pattern in the final code instead of the plain lambda shown above.

- [ ] **Step 9: Commit**

```bash
git add requirements.txt app/config.py app/market/router.py main.py tests/test_live_ticks_routes.py
git commit -m "feat: wire live-tick subscribe/unsubscribe routes and startup resubscribe"
```

---

### Task 5: NestJS — Redis relay and room-transition subscribe/unsubscribe

**Files:**
- Modify: `ai-trader-api/package.json` (via `npm install`)
- Modify: `ai-trader-api/src/signals/signals.gateway.ts`
- Test: `ai-trader-api/src/signals/signals.gateway.spec.ts`

**Interfaces:**
- Produces: `SignalsGateway.getActiveSymbols(): {symbol: string, exchange: string}[]` — consumed by Task 6's new controller.

- [ ] **Step 1: Install ioredis**

Run: `cd ai-trader-api && npm install ioredis`

- [ ] **Step 2: Add `REDIS_URL` to env files**

In `ai-trader-api/.env` and `.env.example`, add:

```
REDIS_URL=redis://redis:6379/0
```

- [ ] **Step 3: Write the failing tests**

```typescript
// ai-trader-api/src/signals/signals.gateway.spec.ts
import { SignalsGateway } from './signals.gateway';

/*
 * The room-transition detection is the one genuinely new piece of logic
 * here: exactly one internal call on the FIRST watcher joining and the
 * LAST one leaving, none in between.
 */

function fakeSocket(id: string, data: Record<string, unknown> = {}) {
  return { id, data, join: jest.fn(), leave: jest.fn() } as any;
}

function fakeRoomsMap() {
  const rooms = new Map<string, Set<string>>();
  return {
    rooms,
    adapter: { rooms },
  };
}

describe('SignalsGateway live-tick subscriptions', () => {
  function setup() {
    const jwt = { verifyAsync: jest.fn() } as any;
    const redisClient = { subscribe: jest.fn(), on: jest.fn(), publish: jest.fn() };
    const httpClient = { request: jest.fn().mockResolvedValue(undefined) };
    const gateway = new SignalsGateway(jwt, redisClient as any, httpClient as any);
    const fakeServer = fakeRoomsMap();
    (gateway as any).server = { ...fakeServer, to: jest.fn().mockReturnThis(), emit: jest.fn(), sockets: fakeServer };
    return { gateway, httpClient, fakeServer };
  }

  it('calls internal subscribe only when the room gains its first member', () => {
    const { gateway, httpClient, fakeServer } = setup();
    fakeServer.rooms.set('symbol:RELIANCE', new Set());
    const client = fakeSocket('s1');

    gateway.handleSubscribeSymbol(client, { symbol: 'RELIANCE', exchange: 'NSE' });
    fakeServer.rooms.get('symbol:RELIANCE')!.add('s1');

    expect(httpClient.request).toHaveBeenCalledTimes(1);
    expect(httpClient.request).toHaveBeenCalledWith(
      '/market/internal/live-ticks/subscribe',
      expect.objectContaining({ method: 'POST', body: { symbol: 'RELIANCE', exchange: 'NSE' } }),
    );
  });

  it('does not call internal subscribe for the second watcher of the same room', () => {
    const { gateway, httpClient, fakeServer } = setup();
    fakeServer.rooms.set('symbol:RELIANCE', new Set(['s1']));

    gateway.handleSubscribeSymbol(fakeSocket('s2'), { symbol: 'RELIANCE', exchange: 'NSE' });
    fakeServer.rooms.get('symbol:RELIANCE')!.add('s2');

    expect(httpClient.request).not.toHaveBeenCalled();
  });

  it('calls internal unsubscribe only when the last watcher leaves', () => {
    const { gateway, httpClient, fakeServer } = setup();
    fakeServer.rooms.set('symbol:RELIANCE', new Set(['s1']));

    gateway.handleUnsubscribeSymbol(fakeSocket('s1'), { symbol: 'RELIANCE', exchange: 'NSE' });
    fakeServer.rooms.delete('symbol:RELIANCE');

    expect(httpClient.request).toHaveBeenCalledWith(
      '/market/internal/live-ticks/unsubscribe',
      expect.objectContaining({ method: 'POST', body: { symbol: 'RELIANCE', exchange: 'NSE' } }),
    );
  });

  it('does not call internal unsubscribe while other watchers remain', () => {
    const { gateway, httpClient, fakeServer } = setup();
    fakeServer.rooms.set('symbol:RELIANCE', new Set(['s1', 's2']));

    gateway.handleUnsubscribeSymbol(fakeSocket('s1'), { symbol: 'RELIANCE', exchange: 'NSE' });
    fakeServer.rooms.get('symbol:RELIANCE')!.delete('s1');

    expect(httpClient.request).not.toHaveBeenCalled();
  });

  it('getActiveSymbols returns every non-empty symbol room with its exchange', () => {
    const { gateway, fakeServer } = setup();
    fakeServer.rooms.set('symbol:RELIANCE', new Set(['s1']));
    fakeServer.rooms.set('symbol:TCS', new Set());
    fakeServer.rooms.set('user:abc123', new Set(['s1']));
    gateway.handleSubscribeSymbol(fakeSocket('s1'), { symbol: 'RELIANCE', exchange: 'NSE' });

    const active = gateway.getActiveSymbols();

    expect(active).toEqual([{ symbol: 'RELIANCE', exchange: 'NSE' }]);
  });

  it('relays a Redis market:ticks message to the matching symbol room', () => {
    const { gateway } = setup();

    (gateway as any).handleRedisMessage('market:ticks', JSON.stringify({ symbol: 'RELIANCE', ltp: 1310 }));

    expect((gateway as any).server.to).toHaveBeenCalledWith('symbol:RELIANCE');
    expect((gateway as any).server.emit).toHaveBeenCalledWith('tick', { symbol: 'RELIANCE', ltp: 1310 });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ai-trader-api && npx jest src/signals/signals.gateway.spec.ts`
Expected: FAIL — constructor signature mismatch (only takes `jwt` today, not `redisClient`/`httpClient`), `handleSubscribeSymbol`/`getActiveSymbols` don't yet accept/exist in the shapes the tests need.

- [ ] **Step 3: Modify the gateway**

Read `ai-trader-api/src/signals/signals.gateway.ts` first — the current file has `handleSubscribeSymbol`/`handleUnsubscribeSymbol` taking `@MessageBody() data: { symbol: string }` only (no `exchange`), and a constructor taking only `jwt: JwtService`. Apply these exact changes:

Replace the constructor:

```typescript
  constructor(
    private readonly jwt: JwtService,
    @Inject('REDIS_CLIENT') private readonly redis: Redis,
    private readonly upstream: UpstreamHttpClient,
  ) {
    this.symbolExchanges = new Map();
    this.redis.subscribe('market:ticks');
    this.redis.on('message', (channel, message) => this.handleRedisMessage(channel, message));
  }
```

Add the import at the top:

```typescript
import { Inject } from '@nestjs/common';
import Redis from 'ioredis';
import { UpstreamHttpClient } from '../common/http/upstream-http.client';
```

Add the new field declaration (alongside the existing `server`/`logger` fields):

```typescript
  private readonly symbolExchanges: Map<string, string>;
```

Replace `handleSubscribeSymbol` and `handleUnsubscribeSymbol`:

```typescript
  @SubscribeMessage('subscribe_symbol')
  handleSubscribeSymbol(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: { symbol: string; exchange: string },
  ) {
    const symbol = data.symbol.toUpperCase();
    const room = `symbol:${symbol}`;
    const wasEmpty = !this.server?.sockets?.adapter.rooms.get(room)?.size;
    client.join(room);
    client.emit('subscribed', { room });
    this.symbolExchanges.set(symbol, data.exchange.toUpperCase());
    if (wasEmpty) {
      this.callInternal('subscribe', symbol, data.exchange.toUpperCase());
    }
  }

  @SubscribeMessage('unsubscribe_symbol')
  handleUnsubscribeSymbol(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: { symbol: string; exchange: string },
  ) {
    const symbol = data.symbol.toUpperCase();
    const room = `symbol:${symbol}`;
    client.leave(room);
    const nowEmpty = !this.server?.sockets?.adapter.rooms.get(room)?.size;
    if (nowEmpty) {
      this.callInternal('unsubscribe', symbol, data.exchange.toUpperCase());
    }
  }

  private callInternal(action: 'subscribe' | 'unsubscribe', symbol: string, exchange: string) {
    this.upstream
      .request(`/market/internal/live-ticks/${action}`, {
        method: 'POST',
        body: { symbol, exchange },
        retryOnNetworkError: true,
      })
      .catch((e: Error) => this.logger.error(`live-ticks ${action} failed for ${symbol}: ${e.message}`));
  }

  private handleRedisMessage(channel: string, message: string) {
    if (channel !== 'market:ticks' || !this.server) return;
    const payload = JSON.parse(message);
    this.server.to(`symbol:${payload.symbol}`).emit('tick', payload);
  }

  getActiveSymbols(): { symbol: string; exchange: string }[] {
    if (!this.server) return [];
    const result: { symbol: string; exchange: string }[] = [];
    for (const [room, members] of this.server.sockets.adapter.rooms) {
      if (!room.startsWith('symbol:') || members.size === 0) continue;
      const symbol = room.slice('symbol:'.length);
      const exchange = this.symbolExchanges.get(symbol);
      if (exchange) result.push({ symbol, exchange });
    }
    return result;
  }
```

`UpstreamHttpClient` (`ai-trader-api/src/common/http/upstream-http.client.ts`) has one method, `request<T>(path, opts)` — no `.post()` convenience method exists. `path` is appended directly to `baseUrl` (`SIGNALS_SERVICE_URL`, e.g. `http://signals:8001`) with no prefix baked in, so the full path including `/market` must be given, matching Task 4's routes exactly: `/market/internal/live-ticks/subscribe`. It does NOT send an `x-internal-key` header — that's fine here since Task 4's Python routes have no auth guard by design (signals-1 is never internet-facing). `SignalsGateway` needs `UpstreamHttpClient` injected via its constructor (add it as a constructor param, `private readonly upstream: UpstreamHttpClient`) — no module wiring needed, `CommonModule` (`ai-trader-api/src/common/common.module.ts`) is `@Global()` and already provides/exports `UpstreamHttpClient`.

- [ ] **Step 4: Register the Redis client provider**

In `ai-trader-api/src/signals/signals.module.ts`, add a provider so `@Inject('REDIS_CLIENT')` resolves:

```typescript
import Redis from 'ioredis';
// ...
  providers: [
    SignalsGateway,
    SignalsService,
    SignalsUpstreamClient,
    {
      provide: 'REDIS_CLIENT',
      useFactory: () => new Redis(process.env.REDIS_URL ?? 'redis://localhost:6379/0'),
    },
  ],
```

- [ ] **Step 5: Run test to verify it passes**

Run: `npx jest src/signals/signals.gateway.spec.ts`
Expected: PASS — 6 tests

- [ ] **Step 6: Run the full suite**

Run: `npx jest`
Expected: all existing suites still pass — pay particular attention to any existing test that constructs `SignalsGateway` directly (its constructor signature changed) and fix the instantiation there to match, rather than leaving it broken.

- [ ] **Step 7: Typecheck**

Run: `npx tsc --noEmit`
Expected: clean

- [ ] **Step 8: Commit**

```bash
git add package.json package-lock.json .env.example src/signals/signals.gateway.ts src/signals/signals.module.ts src/signals/signals.gateway.spec.ts
git commit -m "feat: relay live ticks over the existing gateway, exchange-agnostic subscribe/unsubscribe"
```

---

### Task 6: NestJS — active-symbols endpoint

**Files:**
- Create: `ai-trader-api/src/signals/live-ticks-internal.controller.ts`
- Modify: `ai-trader-api/src/signals/signals.module.ts`
- Test: none — thin pass-through controller, matches the established pattern where controllers this small (`ChartLayoutsController`, `BrokerController`) rely on their service/gateway's own tests rather than a duplicate controller-level test.

**Interfaces:**
- Consumes: `SignalsGateway.getActiveSymbols()` from Task 5

- [ ] **Step 1: Write the controller**

```typescript
// ai-trader-api/src/signals/live-ticks-internal.controller.ts
import { Controller, Get, UseGuards } from '@nestjs/common';
import { SkipThrottle } from '@nestjs/throttler';
import { InternalKeyGuard } from '../common/guards/internal-key.guard';
import { SignalsGateway } from './signals.gateway';

/**
 * Internal, service-to-service only — the Python signals service calls
 * this once on startup to learn which symbols already have watchers, so a
 * process restart (every deploy) doesn't silently stop live ticks for
 * anyone already watching.
 */
@SkipThrottle()
@UseGuards(InternalKeyGuard)
@Controller('internal/market')
export class LiveTicksInternalController {
  constructor(private readonly gateway: SignalsGateway) {}

  @Get('active-symbols')
  activeSymbols() {
    return this.gateway.getActiveSymbols();
  }
}
```

- [ ] **Step 2: Register it**

In `ai-trader-api/src/signals/signals.module.ts`, add the import and register the controller:

```typescript
import { LiveTicksInternalController } from './live-ticks-internal.controller';
// ...
  controllers: [/* whatever already exists here */, LiveTicksInternalController],
```

- [ ] **Step 3: Verify manually**

Build and run the API locally (`npm run build && node dist/main.js`, same as verified earlier this session), then:

```bash
curl -s http://localhost:8000/api/internal/market/active-symbols -H "x-internal-key: $(grep ^INTERNAL_API_KEY .env | cut -d= -f2)"
```

Expected: `[]` (no active socket subscriptions with no browser connected) — a `200` with an empty array, not an error, confirms the route and guard are wired correctly.

- [ ] **Step 4: Commit**

```bash
git add src/signals/live-ticks-internal.controller.ts src/signals/signals.module.ts
git commit -m "feat: internal endpoint reporting currently-watched symbols"
```

---

### Task 7: Frontend — `useLiveQuote` hook

**Files:**
- Modify: `ai-trader-frontend/package.json` (via `npm install`)
- Create: `ai-trader-frontend/lib/use-live-quote.ts`
- Test: `ai-trader-frontend/lib/use-live-quote.test.ts`

**Interfaces:**
- Produces: `useLiveQuote(symbol: string, exchange: string): Quote | null` — a React hook. `Quote` matches the existing shape from `lib/api/market.ts`'s `getQuote` return type.

- [ ] **Step 1: Install socket.io-client**

Run: `cd ai-trader-frontend && npm install socket.io-client`

Check whether this project has a test runner already configured for hooks (look for existing `*.test.ts`/`*.test.tsx` files and their runner — Jest or Vitest) before writing Step 3's test; match whatever's already set up rather than introducing a new one. If no hook-testing precedent exists in this repo, write Step 1's test as a plain, framework-light test of the hook's *pure logic* extracted into a testable function (below) rather than a full React Testing Library render test, and note this explicitly in the commit — do not add a new testing framework as a side effect of this task.

- [ ] **Step 2: Write the hook**

```typescript
// ai-trader-frontend/lib/use-live-quote.ts
"use client";

import { useEffect, useRef, useState } from "react";
import { io, type Socket } from "socket.io-client";
import type { Quote } from "@/lib/api";

/**
 * One shared socket connection per mount, live-quote data for whatever
 * symbol/exchange is currently passed in — used unconditionally, for
 * every exchange. Which vendor actually answers is a Python-side decision
 * this hook has no reason to know about.
 */
let sharedSocket: Socket | null = null;

function getSocket(): Socket {
  if (!sharedSocket) {
    sharedSocket = io({ withCredentials: true });
  }
  return sharedSocket;
}

export function useLiveQuote(symbol: string, exchange: string): Quote | null {
  const [quote, setQuote] = useState<Quote | null>(null);
  const currentRef = useRef({ symbol, exchange });
  currentRef.current = { symbol, exchange };

  useEffect(() => {
    const socket = getSocket();

    const subscribeCurrent = () => {
      const { symbol: s, exchange: e } = currentRef.current;
      socket.emit("subscribe_symbol", { symbol: s, exchange: e });
    };

    const onTick = (payload: Quote) => {
      const { symbol: s, exchange: e } = currentRef.current;
      if (payload.symbol === s && payload.exchange === e) {
        setQuote(payload);
      }
    };

    socket.on("connect", subscribeCurrent);
    socket.on("tick", onTick);
    if (socket.connected) subscribeCurrent();

    return () => {
      socket.off("connect", subscribeCurrent);
      socket.off("tick", onTick);
      socket.emit("unsubscribe_symbol", { symbol, exchange });
    };
  }, [symbol, exchange]);

  return quote;
}
```

- [ ] **Step 3: Write the test**

```typescript
// ai-trader-frontend/lib/use-live-quote.test.ts
/**
 * The hook wraps socket.io-client directly, which needs a real DOM/EventTarget
 * environment to test via a renderer. Testing the tick-filtering logic in
 * isolation instead: a tick for a symbol/exchange other than the one
 * currently active must never be accepted, since a stale in-flight
 * unsubscribe must not leak a price update into the wrong chart.
 */
function shouldAcceptTick(
  payload: { symbol: string; exchange: string },
  current: { symbol: string; exchange: string },
): boolean {
  return payload.symbol === current.symbol && payload.exchange === current.exchange;
}

describe("live quote tick filtering", () => {
  it("accepts a tick matching the current symbol and exchange", () => {
    expect(shouldAcceptTick(
      { symbol: "RELIANCE", exchange: "NSE" },
      { symbol: "RELIANCE", exchange: "NSE" },
    )).toBe(true);
  });

  it("rejects a tick for a different symbol", () => {
    expect(shouldAcceptTick(
      { symbol: "TCS", exchange: "NSE" },
      { symbol: "RELIANCE", exchange: "NSE" },
    )).toBe(false);
  });

  it("rejects a tick for the same symbol on a different exchange", () => {
    expect(shouldAcceptTick(
      { symbol: "RELIANCE", exchange: "BSE" },
      { symbol: "RELIANCE", exchange: "NSE" },
    )).toBe(false);
  });
});
```

This test only pins the filtering predicate's logic (mirrored inline inside the hook's `onTick`, in `lib/use-live-quote.ts` — both must be kept in sync by hand since the predicate isn't extracted into its own exported function; a future task could extract `shouldAcceptTick` for real, but that's out of scope here).

- [ ] **Step 4: Run test to verify it passes**

Run whatever this repo's actual test command is (check `package.json`'s `scripts.test`; if none exists, run `npx jest lib/use-live-quote.test.ts` and note in the commit if a runner had to be configured).
Expected: PASS — 3 tests

- [ ] **Step 5: Typecheck and lint**

Run: `npx tsc --noEmit`
Run: `npx eslint lib/use-live-quote.ts lib/use-live-quote.test.ts`
Expected: both clean

- [ ] **Step 6: Commit**

```bash
git add package.json package-lock.json lib/use-live-quote.ts lib/use-live-quote.test.ts
git commit -m "feat: useLiveQuote — one socket path for every symbol's live price"
```

---

### Task 8: Frontend — wire into the terminal, delete the old poll

**Files:**
- Modify: `ai-trader-frontend/app/dashboard/terminal/page.tsx`

**Interfaces:**
- Consumes: `useLiveQuote` from Task 7

- [ ] **Step 1: Delete the old poll effect**

In `page.tsx`, find the effect described as "Live quote for the active symbol" (around where `getQuote(activeSymbol, activeExchange)` is called inside a `setInterval` every 5000ms, gated by `marketIsLive`). Delete the entire `useEffect` block outright — not commented out, removed. Also remove the `quote`/`setQuote`/`quoteFailed`/`setQuoteFailed` `useState` declarations this effect owned, if nothing else in the file reads them — check first with a project-wide grep for `quoteFailed` and `setQuote(` before removing, since `quoteFailed` may drive an error-state UI element elsewhere in this same file that needs a replacement, not just a deletion.

- [ ] **Step 2: Replace with the hook**

Add near the top of the component body, alongside the other primary state:

```typescript
const quote = useLiveQuote(activeSymbol, activeExchange);
```

Add the import:

```typescript
import { useLiveQuote } from "@/lib/use-live-quote";
```

If Step 1 found a `quoteFailed`-driven UI element with no equivalent from `useLiveQuote` (which returns `null` while no tick has arrived yet, rather than a distinct "failed" state), adapt that UI to treat `quote === null` as the same "no data yet" case `quoteFailed` used to represent — a live quote that simply hasn't ticked yet and one that failed to fetch read the same to the user (a header dash instead of a price), so this is not a behavior regression.

- [ ] **Step 3: Confirm every remaining `quote` reference still compiles**

Run: `npx tsc --noEmit`
Expected: clean. Fix any remaining reference to the deleted `setQuote`/`quoteFailed` state that Step 1's grep missed.

- [ ] **Step 4: Lint**

Run: `npx eslint app/dashboard/terminal/page.tsx`
Expected: clean (aside from the pre-existing unrelated `marketPhase` warning already present before this plan)

- [ ] **Step 5: Commit**

```bash
git add app/dashboard/terminal/page.tsx
git commit -m "feat: terminal uses the live-tick socket for every symbol, deletes the 5s poll"
```

---

### Task 9: End-to-end verification and deploy

**Files:** none — verification only

- [ ] **Step 1: Bring the full local stack up**

```bash
docker compose up -d --build
```

Expected: `redis`, `signals`, `signals-worker`, `signals-beat`, `api`, `frontend` all report healthy (`docker compose ps`).

- [ ] **Step 2: Confirm Python's ticker started**

```bash
docker compose logs signals | grep -i "zerodha\|live tick\|ticker"
```

Expected: either a successful connect log, or (if `ai-trader-signals/.env` doesn't have a currently-fresh Zerodha token locally) the "No Zerodha access token configured" warning from Task 4's lifespan code — not a crash. If it crashed, the lifespan hook's error handling has a real gap to fix before proceeding.

- [ ] **Step 3: Confirm the active-symbols endpoint responds**

```bash
curl -s http://localhost:8000/api/internal/market/active-symbols -H "x-internal-key: $(grep ^INTERNAL_API_KEY ai-trader-api/.env | cut -d= -f2)"
```

Expected: `[]` (nothing subscribed yet, no browser connected).

- [ ] **Step 4: Open the terminal in a real browser, watch for ticks**

Log in, open the terminal on an NSE symbol during a live trading window (or note in the report if run outside market hours, where no real ticks will arrive regardless of correctness — verify the *subscription* succeeded via Step 5 below even if no tick data follows). Open the browser's Network tab, confirm a `socket.io` WebSocket connection is established and a `subscribe_symbol` frame was sent.

- [ ] **Step 5: Confirm the subscription reached Python**

```bash
curl -s http://localhost:8000/api/internal/market/active-symbols -H "x-internal-key: $(grep ^INTERNAL_API_KEY ai-trader-api/.env | cut -d= -f2)"
```

Expected: now shows the symbol just opened in the browser, e.g. `[{"symbol":"RELIANCE","exchange":"NSE"}]`.

- [ ] **Step 6: Commit and push all three repos**

```bash
cd ai-trader-signals && git push
cd ../ai-trader-api && git push
cd ../ai-trader-frontend && git push
cd .. && git push  # docker-compose.yml lives in the umbrella repo
```

- [ ] **Step 7: Deploy**

```bash
ssh -i ~/.ssh/ai-trader-admin.pem ubuntu@<box-ip> 'cd ~/ai-trader && ./deploy.sh'
```

- [ ] **Step 8: Verify live**

Repeat Steps 3-5 against the live domain instead of localhost. Additionally confirm `ai-trader-api/.env` and `ai-trader-signals/.env` on the box both have `REDIS_URL` set (they won't by default — `.env` files aren't tracked in git, per `DEPLOY.md`) before this deploy will actually work; add it via the same `scp`-the-real-`.env`-file approach used earlier this session for the Zerodha credentials if it's missing.
