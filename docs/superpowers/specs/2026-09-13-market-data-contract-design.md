# Market data contract — design

**Status:** proposed, 2026-09-13
**Scope:** `ai-trader-signals` market data layer (`app/market/`), the NestJS
passthrough, and how the terminal renders an empty chart.

## The problem

One Sunday produced three separate production failures. They look unrelated
and are not:

| Symptom | Immediate cause | Root |
|---|---|---|
| `XAUUSD` history 404s | `exchange` defaults to `NSE` at three layers; Kite cannot serve gold | A symbol's venue is guessed by callers instead of resolved |
| 1m forex charts empty all weekend | Deriv serves `[end − count×granularity, end]` and clamps `count` to 1000, so a Sunday request sees only closed market — and returns `[]` with no error | "no data" and "vendor failed" are the same value (`None`) |
| A chart 404s because a Node subprocess died | Tick-volume enrichment raised through `get_historical_df` | Enrichment can fail the request that it decorates |

Each was patched individually today. The pattern repeats per vendor because
`MarketDataProvider` is three methods returning `dict | None`,
`DataFrame | None` and `list` — it says nothing about limits, supported
intervals, sessions, volume provenance, or why a result is empty. The router
compensates by guessing, and every guess is a future incident.

Two further instances are already latent, found while writing this:

- `VENDOR_MAX_DAYS` in `app/market/intervals.py` is a single global table of
  **yfinance's** limits, applied to Kite and Deriv as well. Kite serves 400
  days of hourly bars; we clamp to 720 and let the vendor reject it. Deriv's
  real limit (1000 bars per request) is in none of it.
- `clamp_days` silently truncates. A caller asking for a year of 1m bars gets
  6 days and no indication that the answer is not what it asked for.

## Goals

1. A symbol charts correctly regardless of which vendor backs it, and the
   caller never needs to know which one did.
2. An empty chart always states *why*, in a form the UI and monitoring can
   both act on: closed market, unsupported resolution, out of retention, or
   vendor failure.
3. Vendor limits are declared data, not knowledge encoded in whichever
   provider happened to need it.
4. A new vendor is a capability declaration plus one class, and the existing
   conformance suite proves it behaves.

## Non-goals

- Changing vendors, or adding one. Deriv, Kite, yfinance and Dukascopy stay.
- A tick database or bar storage. This is a fetch path, not a warehouse.
- Backfilling history we do not have.

## The contract

### 1. SymbolInfo, resolved once

```python
@dataclass(frozen=True)
class SymbolInfo:
    symbol: str            # app-facing, e.g. "XAUUSD", "RELIANCE"
    vendor_symbol: str     # "frxXAUUSD", "NSE:RELIANCE"
    provider: str          # registry key
    asset_class: AssetClass        # EQUITY | FX | METAL | COMMODITY | INDEX
    exchange: str          # what we report back, never what a caller guessed
    session: SessionSpec   # see §4
    volume_source: VolumeSource    # EXCHANGE | TICKS | NONE
    intervals: frozenset[str]
```

`resolve(symbol, hint_exchange=None) -> SymbolInfo | None` is the only way a
request reaches a provider. `hint_exchange` is a hint: it disambiguates a
symbol listed on two venues and is otherwise ignored. `XAUUSD` + `NSE` is
then unrepresentable rather than a 404 — the resolver owns the answer.

Resolution is cached (symbols do not move venue intraday) and is the same
lookup `search` already fills in, so the terminal keeps working unchanged.

### 2. Providers declare what they can do

```python
@dataclass(frozen=True)
class ProviderCapabilities:
    intervals: frozenset[str]
    max_bars_per_request: int           # Deriv: 1000. Kite: unbounded within its day window
    max_days_by_interval: Mapping[str, int]   # per vendor, replacing the global table
    supports_ticks: bool
    volume_source: VolumeSource
    anchors_window_on_end: bool         # Deriv's semantics; see §3
```

Measured, not assumed. Today's values, with provenance:

| Provider | Intervals | Max bars/request | Window semantics | Volume |
|---|---|---|---|---|
| Deriv (FX, metals) | 1m–1d | **1000** (probed live 2026-09-13) | `[end − count×granularity, end]`, `start` ignored | none of its own — tick-derived via Dukascopy |
| Kite (NSE/BSE/MCX) | 1m–1d | per its own day limits | explicit from/to | exchange volume |
| yfinance (NASDAQ/NYSE/fallback) | 1m–1d | period/interval matrix | explicit period | exchange volume |
| Dukascopy | ticks only | per hourly file | explicit range | n/a — it *is* the volume source |

Kite's real limits (its own docs) replace the global table for Kite: 60 days
at 1m, 100 at 5m, 200 at 15m/30m, 400 at 1h, 2000 at 1d.

### 3. One result type, with a reason

```python
class BarsStatus(StrEnum):
    OK = "ok"
    NO_DATA = "no_data"                    # vendor answered, range genuinely empty
    CLOSED_MARKET = "closed_market"        # empty because the session is closed
    OUT_OF_RETENTION = "out_of_retention"  # older than this vendor keeps
    UNSUPPORTED_INTERVAL = "unsupported_interval"
    VENDOR_ERROR = "vendor_error"          # the vendor or transport failed

@dataclass(frozen=True)
class BarsResult:
    bars: list[Bar]
    status: BarsStatus
    symbol: SymbolInfo
    volume_source: VolumeSource
    reason: str | None = None     # human-readable, safe to show
    truncated_to: int | None = None   # set when the request was clamped
```

`NO_DATA` and `VENDOR_ERROR` being one value is what produced two of today's
three incidents. They are never merged again.

**Paging moves into the router.** It reads `max_bars_per_request` and
`anchors_window_on_end`, walks backwards a window at a time, and steps on
wall-clock time rather than on what came back — a closed stretch is not the
end of history. Written once, correct for every vendor; the loop currently
living inside `DerivProvider` moves up and the provider goes back to being a
single-request adapter.

### 4. Sessions make "empty" meaningful

```python
@dataclass(frozen=True)
class SessionSpec:
    timezone: str
    weekdays: frozenset[int]
    open_close: tuple[time, time] | None   # None = 24h while open (FX)
    holidays: Callable[[date], bool]
```

FX: Sunday 21:00 UTC → Friday 21:00 UTC. NSE: 09:15–15:30 IST, weekdays, plus
the holiday calendar `app/market/calendar.py` already owns. With this, an
empty range is classified rather than guessed: closed market is `200` with
`CLOSED_MARKET` and the next open time; an empty *open* session is a genuine
`NO_DATA`, which is worth alerting on.

### 5. Volume is measured or it is null

Never a fabricated `0`. Each response carries `volume_source`, each bar's
volume is `int | null`, and the terminal renders null as no bar rather than a
flat zero implying a dead market. Tick-derived volume (Deriv via Dukascopy)
is fetched only for the recent stretch worth paying for; older bars are
explicitly unmeasured.

### 6. Enrichment can never fail the request

Volume, tick counts and any later decoration run behind:

- a per-vendor **circuit breaker** (N consecutive failures ⇒ open for M
  minutes, so a broken Node bridge stops being retried on every request);
- a **time budget** — enrichment that misses it is dropped, not awaited;
- a hard rule enforced by the conformance suite: *given a working bars
  provider and an enrichment that raises, bars still return.*

### 7. API surface — both, as decided

HTTP status for the class of outcome, machine-readable status in the body,
so our own frontend reads the body while monitoring and any other client can
work from the code alone:

| Outcome | HTTP | Body |
|---|---|---|
| bars | 200 | `{bars, status: "ok", exchange, volume_source}` |
| closed market | 200 | `{bars: [], status: "closed_market", reason, next_open}` |
| genuinely empty | 200 | `{bars: [], status: "no_data", reason}` |
| unsupported interval | 400 | `{status: "unsupported_interval", supported}` |
| unknown symbol | 404 | `{status: "unknown_symbol"}` |
| vendor failed | 503 | `{status: "vendor_error", reason}` + `Retry-After` |

A closed market stops being a 404 — that alone removes the loudest false
alarm from both the UI and the logs. NestJS passes the body through
unchanged; it is not a second place where meaning gets invented.

### 8. The terminal

Three states instead of one blank chart: bars; an explanatory panel
(“Closed — FX opens Sunday 21:00 UTC”, “Provider unavailable, retrying”);
and a retry affordance for `503` only. `ApiOhlcBar.volume` becomes
`number | null`; the aggregation paths already coalesce it.

## Conformance suite

One parametrised suite, run against every provider, replacing per-provider
tests that each assert a different shape:

1. A supported interval returns bars with a UTC-sorted, deduplicated index.
2. An unsupported interval returns `UNSUPPORTED_INTERVAL`, never an exception.
3. A range beyond retention returns `OUT_OF_RETENTION`, not silent truncation.
4. A vendor error returns `VENDOR_ERROR` — never `NO_DATA`.
5. A closed-market range returns `CLOSED_MARKET` with a next-open time.
6. A raising enrichment still yields bars.
7. Declared `max_bars_per_request` is respected, and a larger span pages.
8. Volume is either absent or matches the declared `volume_source`.

Recorded vendor fixtures, no live calls. The existing live probes that
established Deriv's limits stay as an opt-in marker for re-verification.

## Sequencing

1. **Types and resolver** — `SymbolInfo`, `resolve()`, capability dataclass,
   `BarsResult`. No behaviour change; the router keeps its current path.
2. **Router owns paging and classification** — move Deriv's loop up, add
   session classification, and delete the global `VENDOR_MAX_DAYS` in favour
   of per-provider tables.
3. **Port the four providers** onto the contract; conformance suite green
   for each.
4. **API + frontend surfaces** — status codes and body, three chart states.
5. **Circuit breaker and enrichment budget.**

Each step ships independently and leaves the terminal working.

## Risks

- **The session calendar is the new single point of wrongness.** A bad
  holiday entry turns a real outage into "closed, all fine". Mitigation: the
  classifier only *labels* an already-empty result; it never suppresses bars,
  and `NO_DATA` during a session stays alert-worthy.
- **Resolver cache staleness** when a symbol is relisted. Bounded TTL, and
  `search` remains the authority that fills it.
- **Porting Kite is the risky one** — it is the only provider carrying live
  auth, an instrument dump and MCX continuous-contract conventions. It ports
  last, behind the conformance suite the other three already pass.

## Open questions

1. Does the chat agent's own market-data path (`app/signals/agent/tools/`)
   consume `BarsResult` directly, or keep receiving bare bars? Leaning
   direct — an agent that cannot tell "closed" from "broken" hallucinates the
   difference.
2. Retention discovery: hardcode per-vendor tables, or probe and cache at
   startup? Hardcode first; the probe script that produced today's Deriv
   numbers becomes the way we refresh them.
