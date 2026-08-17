# Live Price Ticks (WebSocket) — Design

## Goal

Replace the terminal's 5-second REST quote polling with a single
socket-fed live-quote path for every symbol, over the WebSocket
infrastructure that already exists (`SignalsGateway`) instead of each
browser polling independently. Real Kite tick data for NSE/BSE; for
everything else (NASDAQ/NYSE — Kite doesn't cover them), the same 5s
yfinance poll that runs today, just relocated server-side and republished
through the same socket path, so the frontend never branches on exchange.

## Background

`ai-trader-api/src/signals/signals.gateway.ts` is a working, authenticated
Socket.IO gateway already wired into real event flows (order fills,
position updates, signal broadcasts) — JWT-verified on connect (reads the
`access_token` cookie, same as every HTTP route), with an existing
symbol-room subscription mechanism (`subscribe_symbol`/`unsubscribe_symbol`
→ `symbol:${SYMBOL}` rooms) that has never had a frontend consumer
(`socket.io-client` is not currently a frontend dependency). This feature
is the first thing to actually connect to it from the browser.

`CandlestickChart.tsx` already has the live-tick update mechanism this
needs: a `livePrice` prop drives a `useEffect` (`CandlestickChart.tsx:342-355`)
that updates the forming candle in place via the KLineChart `subscribeBar`
callback. Today `page.tsx` feeds it from `quote?.ltp`, itself from a 5s
`getQuote()` poll. This feature only changes *how `quote` gets set* — the
chart-side mechanism and the `livePrice={quote?.ltp}` prop wiring in
`page.tsx` do not change at all.

`MarketDataRouter` already picks a vendor by exchange for quotes,
historical data, and search (`_provider_for(exchange)` in
`app/market/providers/registry.py`) — Kite for NSE/BSE, yfinance
otherwise. This design applies that same, already-established pattern to
live ticks instead of introducing a second, frontend-side branch: the
vendor decision stays where every other vendor decision in this codebase
already lives, and both the gateway and the browser stay exchange-agnostic.

`kiteconnect`'s `KiteTicker` (used identically to the REST `KiteConnect`
class already integrated) auto-resubscribes every currently-subscribed
token on WebSocket reconnect (`ticker.py:681-687`, calls `self.resubscribe()`
from its own in-memory `subscribed_tokens`) — a transient Kite-side drop
self-heals with no code here. That in-memory state does NOT survive a
process restart, which happens on every deploy — closing that gap is part
of this design (see "Resilience" below), not an afterthought.

## Architecture

```
                     ┌─ NSE/BSE ──▶ KiteTicker (Kite's real WebSocket)
symbol subscribed ───┤
                     └─ anything else ──▶ a 5s poll loop calling the
                                          existing market_data_router
                                          .get_quote() (yfinance) — same
                                          cadence as today, just moved
                                          server-side

Either path ──▶ Redis PUBLISH "market:ticks" {symbol, exchange, ltp,
                                               change, change_percent,
                                               volume, timestamp}
                              │
                              ▼
         NestJS SignalsGateway: one ioredis SUBSCRIBE, on message
                    ──▶ server.to(`symbol:${symbol}`).emit('tick', payload)
                              │
                              ▼
              Browser: socket.io-client, joined `symbol:${activeSymbol}`
                    ──▶ setQuote(tickPayload) ──▶ livePrice prop (unchanged)

Subscription lifecycle (same for every exchange — Python decides the
vendor internally, NestJS never branches on it):
  Browser joins "symbol:X" room (first watcher for that room)
    → NestJS: POST /internal/market/subscribe {symbol, exchange} on signals-1
    → Python: NSE/BSE resolves the instrument token via KiteProvider's
      existing instrument cache and calls ticker.subscribe([token]);
      anything else starts that symbol's poll loop
  Browser leaves (last watcher leaves that room)
    → NestJS: POST /internal/market/unsubscribe {symbol, exchange}
    → ticker.unsubscribe([token]), or stops the poll loop
  Python process starts (deploy, crash+restart)
    → Python: GET /internal/market/active-symbols on the API
    → NestJS returns every symbol room currently non-empty
    → Python re-subscribes/re-starts every one of them immediately, same
      per-exchange path as above — closes the "restart loses live feeds"
      gap KiteTicker's own resubscribe() can't reach, and restarts any
      in-progress poll loops too
```

Redis is new infrastructure — one container in docker-compose, `ioredis`
(NestJS) and `redis` (Python, async client) as new dependencies. Chosen
over "Python as an internal socket.io client" (the lower-infra option)
per explicit direction: Redis pub/sub is genuinely the intended pattern
for an external process feeding a Socket.IO deployment, not
over-provisioning here.

## Components

### `ai-trader-signals/app/market/kite_ticker.py` (new)

Owns the one `KiteTicker` instance for the whole process, and nothing
else — nothing here knows about non-Kite exchanges. Started from
`main.py`'s existing FastAPI lifespan hook (`@asynccontextmanager`,
already the place startup/shutdown work happens) and stopped there too.

- `on_ticks(ws, ticks)`: for each tick, resolve `instrument_token` back to
  `{symbol, exchange}` via a `token -> (symbol, exchange)` dict built
  alongside every subscribe call (Kite's tick payload carries only the
  token, never the symbol), shape it into the same quote dict
  `KiteProvider._get_quote_sync` already returns (`symbol, exchange, ltp,
  change, change_percent, volume` — `prev_close`/`open`/`high`/`low`
  carried forward from the last REST quote fetched for that symbol, since
  individual ticks don't necessarily carry full OHLC), and hand it to
  `live_ticks.publish(payload)` (below) rather than touching Redis
  directly.
- `subscribe(symbol, exchange) -> bool` / `unsubscribe(symbol, exchange)`:
  resolve the instrument token via `KiteProvider`'s existing
  `_ensure_instruments()` cache (reused directly, not duplicated), call
  `ticker.subscribe`/`unsubscribe`, track the reverse-mapping. Returns
  `False` rather than raising if the symbol isn't in Kite's instrument
  cache (this module is never called for a non-NSE/BSE exchange in the
  first place — see `live_ticks.py` — but fails closed regardless).

`KiteTicker`'s own reconnect/resubscribe (see Background) covers a
WebSocket-level drop entirely inside this module; nothing here needs to
duplicate that.

### `ai-trader-signals/app/market/live_ticks.py` (new)

The exchange router for live ticks — the one piece that decides which
vendor a symbol's live feed comes from, mirroring
`MarketDataRouter._provider_for(exchange)`'s existing role for
quotes/historical/search. This is the *only* module `router.py`'s new
endpoints and `main.py`'s startup hook call into; `kite_ticker.py` and the
poll loop below are both private to it.

- `subscribe(symbol, exchange)`: NSE/BSE → `kite_ticker.subscribe(...)`.
  Anything else → start an `asyncio` task for that symbol (keyed by
  `(symbol, exchange)` in a dict of running tasks, so a second subscribe
  for an already-watched symbol is a no-op) that loops every 5 seconds
  calling `market_data_router.get_quote(symbol, exchange)` and publishing
  the result — same shape, same `publish()` call, as the Kite path.
- `unsubscribe(symbol, exchange)`: NSE/BSE → `kite_ticker.unsubscribe(...)`.
  Anything else → cancels and removes that symbol's poll task.
- `publish(payload: dict)`: the one place that does
  `redis.publish("market:ticks", json.dumps(payload))` — both
  `kite_ticker.on_ticks` and the poll loop call this, so the Redis
  interaction exists in exactly one place.
- `resubscribe_from(active: list[tuple[str, str]])`: called once at
  startup after fetching the active-symbol list from NestJS — calls
  `subscribe()` for each pair, which routes each one to the right vendor
  exactly as it would for a fresh subscribe.

### `ai-trader-signals/app/market/router.py` (modified)

Two new internal routes, `POST /internal/market/subscribe` and
`POST /internal/market/unsubscribe`, both `{symbol: str, exchange: str}` →
`{"ok": bool}`, calling straight into `live_ticks.subscribe`/`unsubscribe`.
No auth guard needed — `signals-1` is never internet-facing (Caddy only
proxies `/api/*` to NestJS; every existing Python endpoint already relies
on Docker network isolation alone, same here).

### `ai-trader-signals/main.py` (modified)

Lifespan hook: on startup, after the existing initialization, call the
new NestJS endpoint (`GET /internal/market/active-symbols`, same
`x-internal-key` header pattern every other Python→NestJS call already
uses) and call `live_ticks.resubscribe_from(result)`. On shutdown, stop
the Kite ticker and cancel every running poll task.

### `ai-trader-api/src/signals/signals.gateway.ts` (modified)

- Constructor takes an `ioredis` client, subscribes to `"market:ticks"`
  once at module init, and on each message parses the JSON and calls
  `this.server.to(\`symbol:${payload.symbol}\`).emit('tick', payload)` —
  the same `to(room).emit(...)` shape `broadcastSignal`/`emitOrderUpdate`
  already use, just a new event name (`'tick'`, distinct from `'signal'`)
  so the frontend can listen for price ticks separately from trading
  alerts. This code has no idea whether a given tick came from Kite or
  from Python's poll loop, and never needs to.
- `handleSubscribeSymbol`/`handleUnsubscribeSymbol` (already exist,
  `signals.gateway.ts:89-105`) gain a side effect: after `client.join`/
  `client.leave`, check whether that room's member count just went
  1 -> nonzero or nonzero -> 0 (`this.server.sockets.adapter.rooms.get(room)?.size`)
  and, only on that transition, call the new internal Python endpoint —
  for *any* exchange, unconditionally; the vendor decision is entirely
  Python's, as designed above. Every watcher after the first (or before
  the last) is a no-op here. The room name itself (`symbol:${SYMBOL}`)
  does not change — `broadcastSignal` already emits to that exact format
  and must keep working unmodified. The same symbol can legitimately be
  listed on both NSE and BSE (confirmed earlier this session — RELIANCE
  is one example), so the room alone can't carry exchange; a small
  in-memory `Map<string, string>` (`symbol -> exchange`), populated from
  `handleSubscribeSymbol`'s existing `data` payload (the client already
  sends exchange when subscribing — `page.tsx`'s call site is updated to
  include it), is the one new piece of state, used only to answer the
  active-symbols endpoint below.
- New route `GET /internal/market/active-symbols`, guarded by the
  existing `InternalKeyGuard` — filters `adapter.rooms` for keys matching
  `symbol:*` with a non-empty member set, pairs each with the exchange
  from the map above, returns `[{symbol, exchange}]`.

### `ai-trader-api/src/portfolio/order-execution.service.ts`, `.../portfolio-accounts.service.ts`

No changes — they call `gateway.emitOrderUpdate`/`emitPositionUpdate`,
unrelated to the new tick flow (those calls use `user:${userId}` rooms, a
different namespace entirely, untouched by anything above).

### `ai-trader-frontend` (new: `lib/use-live-quote.ts`; modified: `app/dashboard/terminal/page.tsx`)

- New hook `useLiveQuote(symbol, exchange)`: owns one shared
  `socket.io-client` connection (created once, not per-symbol — same-origin
  so the existing `access_token` cookie is sent automatically, no new
  auth wiring). On `connect` (fires on both the initial connection and
  every reconnect — this is the fix for the "fresh connection starts in
  zero rooms" gap) emits `subscribe_symbol` for whatever symbol/exchange
  is current at that moment, via a ref (matching the `onReadyRef` pattern
  already used in `CandlestickChart.tsx`) so a stale closure can't emit an
  outdated symbol. On `symbol`/`exchange` prop change, emits
  `unsubscribe_symbol` for the previous pair and `subscribe_symbol` for
  the new one. Listens for `'tick'` events matching the current
  symbol/exchange and returns the latest one. Used unconditionally, for
  every exchange — there is no branch here.
- `page.tsx`'s existing 5s-poll `useEffect` (`page.tsx:323-332`) and its
  `getQuote()` call for the *active symbol's live price* are deleted
  outright, replaced by `useLiveQuote`. (`getQuote` itself stays — it's
  also used for the one-off watchlist suggestion quotes, an unrelated,
  non-live call site.) Per explicit direction: no REST-polling fallback
  if the socket disconnects — it waits to reconnect, same as
  `socket.io-client`'s default auto-reconnect already provides. This is
  now true uniformly, not just for NSE/BSE.

## Resilience

Four failure modes:

1. **Kite's WebSocket drops.** `KiteTicker`'s own `resubscribe()` on
   reconnect. No code here.
2. **`signals-1` process restarts** (deploy, crash). The startup call to
   `GET /internal/market/active-symbols` + `live_ticks.resubscribe_from(...)`
   — re-subscribes Kite-backed symbols and restarts poll loops for
   everything else. Without this, every deploy would silently stop live
   updates for anyone already watching a symbol until they switched away
   and back.
3. **The NestJS→Python subscribe/unsubscribe POST fails transiently.**
   Retried once, matching `UpstreamHttpClient`'s existing convention
   (`upstream-http.client.ts:60-84`) — explicitly passing
   `retryOnNetworkError: true` since these two calls are idempotent
   (subscribing/unsubscribing an already-subscribed/unsubscribed symbol is
   a safe no-op either way), unlike a generic POST such as placing an
   order.
4. **The browser's socket disconnects.** Re-subscribes on every `connect`
   event (covers reconnects, not just the first connection). No REST
   fallback while disconnected, per explicit direction.

## Non-goals

- Not making NASDAQ/NYSE real-time — there is no faster source than
  yfinance for those exchanges, so the poll loop runs at the same ~5s
  cadence as today's frontend polling did. What changes is *where* the
  polling happens (server-side, shared across every watcher of that
  symbol, once) and *how* it reaches the browser (the same socket path as
  Kite-backed symbols) — not the update frequency itself.
- No changes to the `'signal'` event, `broadcastSignal`, or anything
  under `user:*` rooms (orders, positions) — the `symbol:*` room-naming
  format is untouched; exchange is tracked in a new side-map instead of
  changing the room key, specifically so `broadcastSignal`'s existing
  `symbol:${SYMBOL}` emit target keeps working unmodified.
- Not attempting full OHLC-per-tick fidelity — Kite's tick payload doesn't
  necessarily carry a fresh `open`/`high`/`low` on every tick; those three
  fields in the published Redis message carry forward from the day's
  values already known, only `ltp`/`change`/`change_percent`/`volume`
  update per tick (the yfinance poll path always has fresh OHLC, since
  each poll is a full quote fetch). This matches what the chart actually
  consumes (`livePrice` alone drives the update effect) — no functional
  gap either way.

## Testing

- `kite_ticker.py`: unit tests against a mocked `KiteTicker` instance —
  `subscribe`/`unsubscribe` correctly resolve tokens via a stubbed
  instrument cache and call the right SDK methods; `on_ticks` correctly
  shapes a tick and hands it to `live_ticks.publish`; an unresolvable
  symbol fails closed (returns `False`, does not raise).
- `live_ticks.py`: the actual dispatcher this feature hinges on —
  `subscribe`/`unsubscribe` route NSE/BSE to a mocked `kite_ticker` and
  anything else to starting/cancelling a poll task (assert the task
  exists/is cancelled, not that 5 real seconds pass); a second subscribe
  for an already-watched non-Kite symbol doesn't start a duplicate task;
  `resubscribe_from` routes each pair through the same per-exchange logic
  as a fresh subscribe.
- `router.py`'s two new routes: request/response shape tests, same
  pattern as existing router tests in this file.
- `SignalsGateway`: the room-transition-detection logic (1→0 and 0→1 member
  count crossing triggers exactly one internal call, every watcher in
  between is a no-op) is the one genuinely new piece of logic here worth a
  focused unit test; the Redis-subscribe-and-re-emit path can be tested
  by injecting a fake Redis client and asserting `server.to(...).emit(...)`
  is called with the right room/payload.
- `use-live-quote.ts`: hook test asserting subscribe is emitted on
  connect and on symbol change, unsubscribe on symbol change and unmount,
  and that a `'tick'` event for a *different* symbol than the current one
  is ignored (a stale room membership from an in-flight unsubscribe should
  never leak into the wrong chart).
- No test attempts to open a real connection to Kite's ticker — that part
  was proven live manually (matching how `kite_auth.py`'s login flow was
  verified live before being written), not something CI can safely
  exercise against a real broker account.
