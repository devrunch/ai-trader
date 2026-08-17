# Live Price Ticks (WebSocket) — Design

## Goal

Replace the terminal's 5-second REST quote polling with real Kite Connect
tick data for NSE/BSE, pushed over the WebSocket infrastructure that
already exists (`SignalsGateway`) instead of each browser polling
independently. NASDAQ/NYSE are unaffected — Kite doesn't cover them, so
they keep today's 5s polling exactly as-is.

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
`getQuote()` poll. This feature only changes *how `quote` gets set* for
NSE/BSE — the chart-side mechanism and the `livePrice={quote?.ltp}` prop
wiring in `page.tsx` do not change at all.

`kiteconnect`'s `KiteTicker` (used identically to the REST `KiteConnect`
class already integrated) auto-resubscribes every currently-subscribed
token on WebSocket reconnect (`ticker.py:681-687`, calls `self.resubscribe()`
from its own in-memory `subscribed_tokens`) — a transient Kite-side drop
self-heals with no code here. That in-memory state does NOT survive a
process restart, which happens on every deploy — closing that gap is part
of this design (see "Resilience" below), not an afterthought.

## Architecture

```
Kite's real WebSocket ──▶ KiteTicker (inside signals-1's FastAPI process)
                              │ on tick
                              ▼
                    Redis PUBLISH "kite:ticks" {symbol, exchange, ltp,
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

Subscription lifecycle (separate from the tick flow above):
  Browser joins "symbol:X" room (first watcher for that room)
    → NestJS: POST /internal/kite/subscribe {symbol, exchange} on signals-1
    → Python resolves symbol -> instrument_token via KiteProvider's
      existing instrument cache, ticker.subscribe([token])
  Browser leaves (last watcher leaves that room)
    → NestJS: POST /internal/kite/unsubscribe {symbol, exchange}
    → ticker.unsubscribe([token])
  Python process starts (deploy, crash+restart)
    → Python: GET /internal/broker/kite/active-symbols on the API
    → NestJS returns every symbol room currently non-empty
    → Python subscribes to all of them immediately, same resolve+
      subscribe path as above — closes the "restart loses subscriptions"
      gap the SDK's own resubscribe() cannot reach
```

Redis is new infrastructure — one container in docker-compose, `ioredis`
(NestJS) and `redis` (Python, async client) as new dependencies. Chosen
over "Python as an internal socket.io client" (the lower-infra option)
per explicit direction: Redis pub/sub is genuinely the intended pattern
for an external process feeding a Socket.IO deployment, not
over-provisioning here.

## Components

### `ai-trader-signals/app/market/kite_ticker.py` (new)

Owns the one `KiteTicker` instance for the whole process. Started from
`main.py`'s existing FastAPI lifespan hook (`@asynccontextmanager`,
already the place startup/shutdown work happens) and stopped there too.

- `on_ticks(ws, ticks)`: for each tick, resolve `instrument_token` back to
  `{symbol, exchange}` via a `token -> (symbol, exchange)` dict built
  alongside every subscribe call (Kite's tick payload carries only the
  token, never the symbol), shape it into the same quote dict
  `KiteProvider._get_quote_sync` already returns (`symbol, exchange, ltp,
  change, change_percent, volume` — `prev_close`/`open`/`high`/`low`
  carried forward from the last REST quote fetched for that symbol, since
  individual ticks don't necessarily carry full OHLC), and `redis.publish("kite:ticks", json.dumps(payload))`.
- `subscribe(symbol, exchange) -> bool`: resolves the instrument token via
  `KiteProvider`'s existing `_ensure_instruments()` cache (reused directly,
  not duplicated), calls `ticker.subscribe([token])`, records the
  `token -> (symbol, exchange)` mapping, returns whether resolution
  succeeded (a symbol Kite doesn't carry — e.g. NASDAQ, though NestJS
  should never call this for a non-NSE/BSE exchange in the first place —
  fails closed rather than raising).
- `unsubscribe(symbol, exchange)`: mirrors `subscribe`, `ticker.unsubscribe([token])`,
  drops the reverse-mapping entry.
- `resubscribe_from(active: list[tuple[str, str]])`: called once at
  startup after fetching the active-symbol list from NestJS — calls
  `subscribe()` for each pair.

`KiteTicker`'s own reconnect/resubscribe (see Background) covers a
WebSocket-level drop entirely inside this module; nothing here needs to
duplicate that.

### `ai-trader-signals/app/market/router.py` (modified)

Two new internal routes, `POST /internal/kite/subscribe` and
`POST /internal/kite/unsubscribe`, both `{symbol: str, exchange: str}` →
`{"ok": bool}`. No auth guard needed — `signals-1` is never
internet-facing (Caddy only proxies `/api/*` to NestJS; every existing
Python endpoint already relies on Docker network isolation alone, same
here).

### `ai-trader-signals/main.py` (modified)

Lifespan hook: on startup, after the existing initialization, call the
new NestJS endpoint (`GET /internal/broker/kite/active-symbols`, same
`x-internal-key` header pattern every other Python→NestJS call already
uses) and call `kite_ticker.resubscribe_from(result)`. On shutdown, stop
the ticker cleanly.

### `ai-trader-api/src/signals/signals.gateway.ts` (modified)

- Constructor takes an `ioredis` client, subscribes to `"kite:ticks"` once
  at module init, and on each message parses the JSON and calls
  `this.server.to(\`symbol:${payload.symbol}\`).emit('tick', payload)` —
  the same `to(room).emit(...)` shape `broadcastSignal`/`emitOrderUpdate`
  already use, just a new event name (`'tick'`, distinct from `'signal'`)
  so the frontend can listen for price ticks separately from trading
  alerts.
- `handleSubscribeSymbol`/`handleUnsubscribeSymbol` (already exist,
  `signals.gateway.ts:89-105`) gain a side effect: after `client.join`/
  `client.leave`, check whether that room's member count just went
  1 -> nonzero or nonzero -> 0 (`this.server.sockets.adapter.rooms.get(room)?.size`)
  and, only on that transition, call the new internal Python endpoint.
  Every watcher after the first (or before the last) is a no-op here —
  Kite only needs one subscribe per symbol regardless of how many
  browsers are watching it. The room name itself (`symbol:${SYMBOL}`)
  does not change — `broadcastSignal` already emits to that exact format
  and must keep working unmodified. The same symbol can legitimately be
  listed on both NSE and BSE (confirmed earlier this session — RELIANCE
  is one example), so the room alone can't carry exchange; a small
  in-memory `Map<string, string>` (`symbol -> exchange`), populated from
  `handleSubscribeSymbol`'s existing `data` payload (the client already
  sends exchange when subscribing — `page.tsx`'s call site is updated to
  include it), is the one new piece of state, used only to answer the
  active-symbols endpoint below.
- New route `GET /internal/broker/kite/active-symbols` (mirrors the
  existing `internal/broker/zerodha/*` naming), guarded by the existing
  `InternalKeyGuard` — filters `adapter.rooms` for keys matching
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
  auth wiring). On `connect` (fires on both the initial connection and every
  reconnect — this is the fix for the "fresh connection starts in zero
  rooms" gap) emits `subscribe_symbol` for whatever symbol/exchange is
  current at that moment, via a ref (matching the `onReadyRef` pattern
  already used in `CandlestickChart.tsx`) so a stale closure can't emit an
  outdated symbol. On `symbol`/`exchange` prop change, emits
  `unsubscribe_symbol` for the previous pair and `subscribe_symbol` for the
  new one. Listens for `'tick'` events matching the current symbol/exchange
  and returns the latest one.
- `page.tsx`'s existing 5s-poll `useEffect` (`page.tsx:323-332`) gains a
  branch: for `activeExchange in ("NSE", "BSE")`, `useLiveQuote` supplies
  `quote` instead of the poll (the `setInterval` simply doesn't start);
  for any other exchange, today's polling is completely unchanged. Per
  explicit direction: no REST-polling fallback if the NSE/BSE socket
  disconnects — it waits to reconnect, same as `socket.io-client`'s
  default auto-reconnect already provides.

## Resilience

Three failure modes, three independent answers — see "Background" and
component sections above for where each lives:

1. **Kite's WebSocket drops.** `KiteTicker`'s own `resubscribe()` on
   reconnect. No code here.
2. **`signals-1` process restarts** (deploy, crash). The startup call to
   `GET /internal/broker/kite/active-symbols` + `resubscribe_from(...)`.
   Without this, every deploy would silently stop live ticks for anyone
   already watching a symbol until they switched away and back.
3. **The NestJS→Python subscribe/unsubscribe POST fails transiently.**
   Retried once, matching `UpstreamHttpClient`'s existing convention
   (`upstream-http.client.ts:60-84`) — explicitly passing
   `retryOnNetworkError: true` since these two calls are idempotent
   (subscribing an already-subscribed token, or unsubscribing an
   already-unsubscribed one, is a safe no-op on Kite's side), unlike a
   generic POST such as placing an order.
4. **The browser's socket disconnects.** Re-subscribes on every `connect`
   event (covers reconnects, not just the first connection). No REST
   fallback while disconnected, per explicit direction.

## Non-goals

- No changes to NASDAQ/NYSE quote handling — untouched, still 5s REST
  polling, Kite doesn't cover those exchanges.
- No changes to the `'signal'` event, `broadcastSignal`, or anything
  under `user:*` rooms (orders, positions) — the `symbol:*` room-naming
  format is untouched; exchange is tracked in a new side-map instead of
  changing the room key, specifically so `broadcastSignal`'s existing
  `symbol:${SYMBOL}` emit target keeps working unmodified.
- Not attempting full OHLC-per-tick fidelity — Kite's tick payload doesn't
  necessarily carry a fresh `open`/`high`/`low` on every tick; those three
  fields in the published Redis message carry forward from the day's
  values already known, only `ltp`/`change`/`change_percent`/`volume`
  update per tick. This matches what the chart actually consumes
  (`livePrice` alone drives the update effect) — no functional gap.

## Testing

- `kite_ticker.py`: unit tests against a mocked `KiteTicker` instance —
  `subscribe`/`unsubscribe` correctly resolve tokens via a stubbed
  instrument cache and call the right SDK methods; `on_ticks` correctly
  shapes and publishes to a mocked Redis client; an unresolvable symbol
  fails closed (returns `False`, does not raise).
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
