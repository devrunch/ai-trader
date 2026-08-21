# Lightweight Charts + PineTS Migration — Design

**Status:** Revised by user, 2026-08-21, superseding the two-sub-project version of this spec. Original framing kept diascript and added PineTS alongside it for human-authored Pine import only. **New direction: diascript is retired entirely.** PineTS becomes the one indicator engine — for both user-pasted Pine and agent-generated Pine. This is one project now, not two: Lightweight Charts has no indicator math of its own (confirmed — see "Why diascript can't just be ported" below), so the chart-library swap and the indicator-engine swap are the same effort.

**Platform context stated by the user:** single-user platform for now. That is the basis for accepting agent-generated Pine execution (not just curated/human-authored) as in-scope from day one — noted explicitly here because it's a real risk trade-off, not a default, and it should be revisited before this ever becomes multi-tenant (see "Security model" below).

## Goal

Replace klinecharts (rendering) **and** diascript (indicator engine) with:
- **Lightweight Charts** (`lightweight-charts`, already installed at `5.2.0`, Apache-2.0) for rendering — candles and volume only, natively, no calc engine needed for either.
- **PineTS** for everything else — any indicator beyond candle+volume runs as real Pine Script, executed in a sandbox, attached lazily (only when actually asked for, never a pre-populated catalog).

**In scope, confirmed by user:** Pine `strategy.*` order execution driving real paper-trade fills — not deferred. Design below in "Strategy execution & paper trading."

**Not in scope:**
- Any change to `PaperTradingService`'s own order-placement/risk/execution logic (`ai-trader-api/src/portfolio/`) — Pine strategies call into it exactly as any other order source does, through its existing `placeOrder()` contract. No new order-placement path, no bypass of its risk guards.
- Live/real-money order execution — paper trading only, matching everything else in this product today.

## Why diascript can't just be ported (confirmed, not assumed)

Checked directly against the installed package (`node_modules/lightweight-charts/dist/typings.d.ts`, `5.2.0`): zero references to RSI, MACD, moving averages, Bollinger, or stochastic anywhere in its API surface, and its README doesn't mention indicator math either. Lightweight Charts is rendering-only — `chart.addSeries(LineSeries | HistogramSeries | CandlestickSeries | ..., options, paneIndex?)` draws whatever series data it's handed; it computes nothing. klinecharts, by contrast, ships `EMA`/`MA`/`BOLL`/`SAR`/`BBI`/`VOL`/`MACD`/`RSI`/`KDJ` as internal calc functions — that's what diascript's klinecharts adapter (and klinecharts' own "native" indicators) rode on top of. None of that math exists in Lightweight Charts. Something has to compute it. That something is now PineTS, not a ported diascript.

Given that, keeping diascript around for anything client-side stops making sense: it would be a second indicator language sitting next to Pine for no reason once Pine is doing all the math anyway. Retiring it is the more consistent design here, not a loss — but it is real: this session shipped 88 diascript indicators with golden-value tests and a graph-generation subagent that authors diascript formulas on demand (`ai-trader-signals/app/signals/agent/tools/graph_agent.py`). All of that becomes dead code under this direction. Naming that plainly rather than burying it in a task list.

## Default chart: candle + volume only

No pre-loaded EMA, no default indicator set at all. `CandlestickSeries` and `HistogramSeries` (LWC's own volume-series convention: a histogram series with per-bar `color` for up/down) are both native LWC series types — zero Pine involvement needed for the default view. Anything beyond that is added only when the user (or the chat agent, on the user's behalf) actually asks for it — no upfront catalog to maintain or keep in sync.

## Security model

Two Pine sources are in scope, both executing:
1. **User-pasted Pine** — the user supplies Pine text directly (e.g. copied from TradingView), asks for it on their chart.
2. **Agent-generated Pine** — the chat agent writes new Pine source in response to a request ("add a Gaussian filter"), the same shape `generate_custom_indicator` used to fill with diascript, now filled with Pine instead.

Both are **executable code reaching the server**, which is exactly what [[project_agent_standing_design_rules]]'s rule 1 exists to guard against ("An LLM writing code the server runs is remote code execution — one prompt injection compromises the database and stored credentials"). This spec does not relitigate that rule — the user has explicitly accepted the risk, scoped to a single-user platform, with the mitigation already agreed two turns ago: **PineTS never runs inline in the API process.** It runs in an isolated worker/subprocess: no DB access, no credential access, no filesystem/network access, CPU and memory caps, only OHLCV arrays in and plot-data arrays out across a structured-clone boundary. That sandbox is not optional scope here — it's what makes "agent-generated Pine executes" a bounded risk instead of an open one, single-user platform or not.

**Explicit flag for later:** if this platform ever becomes multi-tenant, agent-generated (and possibly user-pasted) Pine execution needs re-review — a compromised or malicious script's blast radius changes completely once other users' data is reachable from the same backend, even behind a sandbox. Not blocking now; should not be forgotten later.

## License: `pinets` is AGPL-3.0-only

Verified directly (`npm view pinets license`, 2026-08-21): the real PineTS package (LuxAlgo, `npm i pinets`) is AGPL-3.0-only — not MIT/Apache like the rest of this stack. AGPL's network-use clause is specifically written to close the "SaaS loophole" plain GPL has: running modified AGPL code as a network service that users interact with remotely can trigger the same source-disclosure obligation as literally distributing it, even without ever handing anyone a copy of the code itself.

**User's call, recorded:** proceed, on the basis that this is genuinely personal/single-operator use — no other party is ever granted access to the running service, not merely "not distributed" in isolation (that framing alone doesn't fully address AGPL's network clause, which exists to cover exactly that case). Ties to the same single-user-platform basis already used for the security-model call above. **Same trigger to revisit:** the moment this platform has a second real user, this needs an actual legal read, not an assumption — not blocking implementation now, but not something to forget either. A wrapper package (`@backtest-kit/pinets`, MIT) exists but its actual relationship to the real AGPL engine is unverified and not relied on here.

## Decoupling: the `ChartAdapter` interface (unchanged from the prior revision)

Still the right call, independent of the diascript/PineTS swap. Every consumer (`CandlestickChart.tsx`, `terminal/page.tsx`, `use-chart-layout.ts`, `DrawingToolbar.tsx`) depends on one interface, never on `lightweight-charts` types directly. A future rendering-library change stays "write a new class implementing `ChartAdapter`."

```ts
export interface ChartAdapter {
  mount(el: HTMLElement, options: ChartMountOptions): Promise<void>;
  dispose(): void;
  resize(): void;

  setPriceLevels(levels: PriceLevels): void;
  pushLiveTick(price: number): void;

  // No more "indicator name from a fixed catalog" — every non-default
  // indicator is Pine source + a chosen output, attached lazily.
  attachPineIndicator(spec: PineIndicatorSpec): string;   // returns an instance id
  removeIndicator(id: string): void;

  addDrawings(drawings: ChatDrawing[], groupId: string): void;
  startManualDraw(kind: ManualDrawKind, groupId: string, onChange: () => void): void;
  removeDrawingsByGroup(groupId: string): void;
  removeDrawingsWhere(predicate: (groupId: string) => boolean): void;
  listSavedDrawings(groupIds: string[]): SavedDrawing[];
  restoreDrawings(drawings: SavedDrawing[]): void;
}

export interface PineIndicatorSpec {
  id: string;            // stable id for this attached instance (persists across saves)
  source: string;        // the actual Pine script text
  label: string;         // what to show the user (script title, or agent-given name)
  pane: "main" | "sub";
}
```

`ChatDrawing` stays as-is (already library-agnostic). `SavedDrawing`/`ChartLayout.indicators` do **not** stay as-is — see "Saved-layout schema change" below, a direct consequence of dropping the fixed catalog.

## Saved-layout schema change (new — a consequence of dropping the catalog, not present in the prior revision)

Today (`ai-trader-api`'s `chart-layouts` module, `schemas/chart-layout.schema.ts:39-40`): `indicators: string[]` — just names, because a name was enough to look up a klinecharts-native or diascript-catalog indicator. Under this direction there is no catalog to look a name up in — an "indicator" is now a Pine script's actual source text plus metadata. The stored shape has to become something like:

```ts
// ai-trader-api: schemas/chart-layout.schema.ts
interface AttachedIndicator {
  id: string;
  source: string;   // Pine source, stored verbatim — this IS the indicator
  label: string;
  pane: 'main' | 'sub';
}
```

replacing the current `indicators: string[]` field. **Confirmed by user: no real users on the platform yet, so this is a clean schema cutover, not a data migration** — no dry-run script, no preserve-old-data path needed for either the indicator-schema change or the klinecharts→LWC drawings-format change from the prior revision. Any `chart-layouts` documents in the dev database from this session's own testing get dropped, not converted.

## PineTS's real API (verified against its docs, 2026-08-21 — not assumed)

```ts
new PineTS(source: IProvider | OhlcvBar[], tickerId?, timeframe?, limit?, sDate?, eDate?);
// OhlcvBar: { open, high, low, close, volume, openTime } — ms epoch, NOT diascript's seconds convention
await pineTS.run(source: string, n?: number): Promise<Context>;
// Context: { result, data, plots, alerts, warnings, idx, marketData, strategy, ... }
// context.strategy: { opentrades: Trade[], closedtrades: Trade[], pending_orders: Order[] }
```

Two facts that directly shape the strategy design below:
- **No built-in timeout, CPU cap, or sandboxing of any kind** — confirmed absent from the docs. Everything in "Security model" above (isolated worker/subprocess, resource caps) is entirely on us to build; PineTS provides none of it.
- **Orders already fill on the next bar's open, by construction** — "you place an order on bar N — it goes onto `pending_orders`; on bar N+1's open, the engine processes it." For a backtest over historical bars, this alone prevents same-bar repainting, since every bar in that array is already fully known. The place this still needs an explicit guard is **live** trading: the runner must only feed PineTS a new bar once it has actually closed (a new confirmed candle exists), never re-run against a still-forming bar just because a live tick moved its price — matching how the chart's own live-tick path already treats the forming candle as provisional (`CandlestickChart.tsx`'s `pushLiveTick`, mutated in place, never a new bar until the period rolls over). `barstate.isconfirmed` inside the Pine script is Pine's own way of expressing this; the runner's job is to not even present an unconfirmed bar as if it were final.

## Strategy execution & paper trading (new)

Existing infrastructure, confirmed by reading it directly (`ai-trader-api/src/portfolio/paper-trading.service.ts`): `PaperTradingService.placeOrder(userId, dto: PlaceOrderDto)` already takes `{ symbol, exchange, side, type, quantity, limitPrice?, stopLoss?, clientOrderId?, decisionTurnId? }`, is idempotent on `clientOrderId` (a repeat with the same key returns the original order, never a second position — checked before the write, the unique index makes it safe under a race), runs `RiskLimitsService`'s guard on BUY orders, and executes market orders immediately via `OrderExecutionService`. This is the one and only door a Pine strategy's orders go through — no new order-placement path gets built.

**The design:** a new `PineStrategyRunner` (home: `ai-trader-signals`, since that's where the existing Celery-scheduled paper-trading square-off already lives, per `paper-trading.service.ts`'s own square-off doc comment) that:
1. Runs a Pine strategy script through the same sandboxed PineTS execution as indicators (Step 2 below), but reads `strategy.entry`/`strategy.exit`/`strategy.close` calls out of the execution as an event stream instead of (or alongside) plot data.
2. **Gates every order on `barstate.isconfirmed`.** This is the non-negotiable rule from Pine strategy semantics: acting on the forming (unconfirmed) bar lets a strategy "discover" edges that repaint into profitability on replay and never hold up live. The runner reads `barstate.isconfirmed` explicitly per bar and only emits an order when it's `true`.
3. Reads newly-filled entries out of `context.strategy.opentrades`/`closedtrades` after each `run()` (fields confirmed from PineTS's own docs: `entry_id`, `entry_price`, `entry_bar_index`, `entry_time`, `size` signed by direction, `exit_*` once closed) and translates each into a `PlaceOrderDto` — `clientOrderId` built deterministically from `(strategy instance id, entry_bar_index, entry_id)`, so a re-run of the same historical range (backtest replay, or a crash-and-resume) is idempotent by construction, using the guarantee `placeOrder` already provides rather than building a second one.
4. `decisionTurnId` carries which Pine strategy (and which chat turn, if agent-generated) produced the order — same field the chat agent's other order-placing paths already populate, so a paper trade's origin is traceable the same way everywhere.

No new risk-limit logic, no new execution logic, no new position math — all of that stays exactly as `RiskLimitsService`/`OrderExecutionService` already do it. The only new code is: read confirmed-bar strategy events out of the sandbox, and call the door that already exists.

## Current state (unchanged from the prior scan, still accurate)

**Core component:** `components/CandlestickChart.tsx` (424 lines), mounted at two sites (`app/dashboard/terminal/page.tsx`, `app/page.tsx`). Owns klinecharts `init()`, `setStyles()`, `setSymbol`/`setPeriod`, `setDataLoader` (pull-based history + live-bar push), three locked `priceLine` overlays for AI signal entry/target/stop, incremental `createIndicator`/`removeIndicator` (with an `isStack: true` gotcha), `ResizeObserver`, live-tick mutation.

**Drawing tools:** `ChatDrawing` (`segment`/`priceline`/`fibonacci`/`trade_marker`/`series`) and manual `DrawingToolbar` (`segment`/`rayLine`/`horizontalStraightLine`/`fibonacciLine`/`rect`) both resolve to klinecharts overlay names via `chart.createOverlay(...)`, in `applyDrawings()` (`terminal/page.tsx:255-295`) and `pickTool()` (`terminal/page.tsx:201-212`). Saved via `use-chart-layout.ts`'s `save()`/restore effect, reading/writing `chart.getOverlays({groupId})` in klinecharts' own shape.

**Live ticks:** `use-live-quote.ts`'s Socket.IO singleton → `livePrice` prop → `CandlestickChart.tsx` mutates the in-memory last bar and re-invokes the `DataLoader`'s `subscribeBar` callback.

**Paper trading markers:** confirmed absent today — unrelated to this migration.

## Risk-ranked pieces

1. **PineTS sandbox** (highest risk). Isolated worker/subprocess, resource-capped, structured-clone boundary. This is real infrastructure, not a config flag — get this wrong and "agent-generated Pine" is an open RCE path, not a bounded one.
2. **Strategy execution's confirmed-bar rule.** Getting `barstate.isconfirmed` gating wrong doesn't crash anything visibly — it silently produces a strategy that backtests brilliantly and never works live, which is worse than a crash because it isn't caught by testing that only checks "did an order get placed."
3. **PineTS → LWC rendering.** Pine's `plot()`/`plotshape()`/`hline()`/`fill()`/`bgcolor()` surface is wider than LWC's native series types — bands, markers, background shading, and fills need LWC's Series Primitives API (`ISeriesPrimitive`, confirmed present in the installed package's types) written from scratch. No adapter exists anywhere for this yet.
4. **Drawing tools + saved-layout schema cutover** — simplified since there's no real data to migrate (see above), but still real code spanning two repos.
5. **`DataLoader` → LWC's data model.** History paging + live ticks, mechanical but touches a path that's easy to silently break.
6. **Multi-pane placement.** Mechanical, lowest risk.

## Sequenced approach

1. **Extract `ChartAdapter`, klinecharts implementation behind it.** Pure refactor, zero behavior change. Ships the decoupling before either the rendering-library or the indicator-engine swap touches anything.
2. **PineTS sandbox**, built and tested standalone, independent of the chart: given Pine source + OHLCV bars, returns plot data (for indicator scripts) or a strategy-event stream (for strategy scripts) or a structured error — inside an isolated worker/subprocess with resource caps and no DB/credential/filesystem/network access. Has to work and be trusted on its own before anything downstream depends on it.
3. **`PineStrategyRunner`**: confirmed-bar-only event reading from Step 2's sandbox, translated into `PaperTradingService.placeOrder()` calls with deterministic `clientOrderId`s. Built and tested against the existing paper-trading service directly — this step needs zero chart/rendering work to be fully testable.
4. **PineTS-to-LWC render mapping**: the primitives for band/marker/background/fill, plus the direct cases (`plot()` → line/histogram series). Tested against known Pine scripts with known expected output.
5. **New `LightweightChartsAdapter`** implementing `ChartAdapter`: candle + volume as native series (default view), `attachPineIndicator()` wired to Steps 2+4, at both mount sites.
6. **`ChartDataSource` for LWC**: history paging + live-tick path. Manual browser check specifically.
7. **Drawing tools**, rebuilt against LWC primitives — same seven overlay kinds as before.
8. **Saved-layout schema cutover**: drawings format (klinecharts-shaped → LWC-native, `format`/`adapterId`-tagged) and `indicators: AttachedIndicator[]` replacing `indicators: string[]`. Clean cutover per the confirmed no-real-data decision — no migration script. Spans `ai-trader-frontend` and `ai-trader-api`'s `chart-layouts` module.
9. **Chat agent tool swap**: `generate_custom_indicator` (`ai-trader-signals/app/signals/agent/tools/graph_agent.py`) stops writing diascript and starts writing Pine. Same "write, validate, one retry on a real error, hand a validated result to the frontend" shape, new target language. Its worked-examples-in-the-prompt pattern (Gaussian filter, wavelet, SMC) needs re-authoring for Pine syntax; "never fake sophistication" carries over unchanged.
10. **Multi-pane placement**, last, lowest risk.

## Decisions made in this spec (flagged for user check)

- **Diascript retired**, not archived-but-kept. Recoverable from the `devrunch/diascript` git history and this session's chat log if this turns out wrong, but the plan carries no dead-code maintenance for it.
- **No data migration for saved chart layouts** — confirmed no real users yet; both the drawings-format and indicator-schema changes are clean cutovers, no dry-run/preserve-old-data tooling built.
- **Agent-generated Pine is in scope from the start**, not deferred to "curated-only, proven safe first." Per the user's explicit call, on the stated single-user-platform basis. The sandbox (Step 2) is the control, not a curated allowlist — see "Explicit flag for later" above for the multi-tenant caveat.
- **Strategy/paper-trading execution is in scope now**, confirmed by user — not a follow-up phase. Built entirely on top of the existing `PaperTradingService.placeOrder()` contract, no new order-placement path.

## Testing strategy per step

- Step 1: no functional changes expected — manual regression check in a real browser.
- Step 2: unit tests against the sandbox in isolation — a known-good script returns correct plot data; a script that spins forever gets killed by the CPU cap; a script that tries to reach the filesystem/network fails closed; malformed Pine returns a structured parse error, not a crash.
- Step 3: a strategy script run against a fixed historical bar sequence produces the exact expected sequence of `placeOrder()` calls, none of them on an unconfirmed bar; re-running the identical range produces zero new orders (idempotency via `clientOrderId`), verified against `PaperTradingService` directly, no mocking.
- Step 4: known Pine scripts (a plain EMA, one using `plotshape`, one using `fill`) render matching hand-computed expected output.
- Step 5: default-view manual check — only candles + volume, nothing else, on a fresh chart.
- Step 6: manual browser verification of live ticks and pan-back history loading.
- Step 7: same seven overlay kinds verified as before.
- Step 8: manual confirmation of a working save/restore round-trip on the new schema (nothing to migrate, but the new shape itself needs a real save-then-reload check).
- Step 9: the graph-generation subagent's own worked examples (re-authored for Pine) validate against the real PineTS sandbox before shipping — same rigor this session already applied to diascript's worked examples.
- Step 10: manual pane-placement verification, same as before.
