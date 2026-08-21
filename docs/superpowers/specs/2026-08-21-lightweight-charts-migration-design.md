# Lightweight Charts Migration — Design

**Status:** Approved by user, 2026-08-21. First of two sub-projects split out of a single larger ask ("move off klinecharts, move off diascript onto PineTS"). This spec covers only the chart-rendering-library swap. The second sub-project — a sandboxed PineTS import path for human-authored Pine scripts, run alongside (not instead of) diascript — gets its own spec, brainstormed separately, once this one is implemented.

## Goal

Replace **klinecharts** (`^10.0.2`) with TradingView's open-source **Lightweight Charts** (`lightweight-charts`, npm `5.2.1` current as of this spec, Apache-2.0) as the rendering library across `ai-trader-frontend`, for its larger customization surface (Series Primitives API, more chart styling headroom) — decoupled from and landing before any Pine work.

**Not in scope:**
- PineTS or Pine Script support of any kind (separate spec).
- Any change to diascript's DSL, grammar, parser, or evaluator — diascript's `evaluate()`/`parse()` engine is untouched; only its *render adapter* gains a new target alongside the existing klinecharts one.
- Any change to paper-trading logic, signal generation, or the chat agent's tool surface.
- Chart features that don't exist today (e.g. live open-position markers — confirmed absent during the current-state scan; adding them is a future, separate ask, not a "port").

## Why diascript is not a blocker here

`diascript` (MIT, published under the `devrunch` npm org — the same org that owns this project) is **our own package**, not a third-party dependency: `A small, safe, chart-library-agnostic DSL for defining technical indicators as data, not code.` Its own `adapters/render/klinecharts/` directory structure already anticipates more than one chart-library target — adding `adapters/render/lightweight-charts/` alongside it is extending an established pattern, not inventing one. The "hardest piece" of this migration is real engineering work, but it is work in a repo we control end to end.

## Decoupling: a library-agnostic `ChartAdapter` interface

**Added requirement (user, 2026-08-21):** make the chart layer decoupled, so a future library change is cheap. Today every consumer — `CandlestickChart.tsx`, `terminal/page.tsx`, `use-chart-layout.ts`, `DrawingToolbar.tsx` — imports klinecharts types and calls klinecharts APIs directly. Porting straight to Lightweight Charts calls in the same places would just replace one hard-coded library with another; the *next* swap would cost the same as this one.

Instead: extract a small `ChartAdapter` interface, owned in `ai-trader-frontend` (not diascript — this is app-level, one layer above diascript's own render-adapter concept, and the same pattern applied one level up). Every consumer depends on the interface only; no file outside the adapter implementation itself imports `klinecharts` or `lightweight-charts` types. A future library change becomes "write a new class implementing `ChartAdapter`," not "touch every file that ever called a chart API."

Shape (illustrative — exact signatures get pinned in the implementation plan, not here):

```ts
interface ChartAdapter {
  mount(el: HTMLElement, options: ChartMountOptions): void;
  dispose(): void;
  resize(): void;

  setSymbolMeta(meta: { ticker: string; pricePrecision: number; volumePrecision: number }): void;
  setPeriod(period: { span: number; type: PeriodType }): void;

  // History paging + live ticks behind one app-level contract, not the
  // underlying library's own DataLoader/update() shape.
  setDataSource(source: ChartDataSource): void;
  pushLiveTick(price: number): void;

  addIndicator(name: string, params?: number[]): string;     // built-ins
  attachCustomIndicator(spec: CustomIndicatorSpec): string;   // diascript-authored
  removeIndicator(id: string): void;

  // Already app-level/library-agnostic today (ChatDrawing) -- the leak is
  // that consumers translate it to library-native shapes themselves. The
  // adapter takes ChatDrawing directly and does that translation internally.
  addDrawing(drawing: ChatDrawing, groupId: string): string;
  removeDrawings(groupId: string): void;
  listDrawings(groupId: string): SavedDrawing[];

  setPriceLevels(levels: { entry?: number; target?: number; stopLoss?: number }): void;
}
```

`ChatDrawing` (`kind: segment|priceline|fibonacci|trade_marker|series`) is already a library-agnostic shape — it just isn't used as the interface boundary today. `SavedDrawing`'s "opaque, library-native payload" pattern stays (Step 5 below), but gains a `format`/`adapterId` tag alongside the opaque blob, so a *future* swap can tell which shape a stored record uses without a second full migration.

## Current state (full repo scan, 2026-08-21)

**Core component:** `components/CandlestickChart.tsx` (424 lines) is the single chart component, mounted at two sites (`app/dashboard/terminal/page.tsx`, `app/page.tsx`'s landing-page demo). Owns: klinecharts `init()`, `setStyles()` (full dark theme, custom tooltip legend, crosshair, fonts), `setSymbol`/`setPeriod`, `setDataLoader` (pull-based history + live-bar push contract), three locked `priceLine` overlays for AI signal entry/target/stop, incremental `createIndicator`/`removeIndicator` (with an `isStack: true` gotcha to avoid evicting sibling main-pane overlays), `ResizeObserver`, and the live-tick mutation path.

**Diascript render adapter:** lives 100% inside `node_modules/diascript/dist/adapters/render/klinecharts/adapter.js` — none of it in this repo. Maps diascript's six output types to klinecharts `figures`: `line`→line, `histogram`→bar, `band`→two lines, `marker`→circle, `background`→rect, `fill`→polygon (reads klinecharts-computed pixel coordinates to build a quad between adjacent bars). `barcolor` is defined by diascript but was never implemented in this adapter (throws today) — that gap carries over, not new scope.

**Drawing tools:** the chat agent's `ChatDrawing` (`segment`/`priceline`/`fibonacci`/`trade_marker`/`series`) and the manual `DrawingToolbar` (`segment`/`rayLine`/`horizontalStraightLine`/`fibonacciLine`/`rect`) both resolve to raw klinecharts overlay names via `chart.createOverlay({ name, groupId, ... })`. Saved layouts (`lib/api/charts.ts`'s `SavedDrawing`) are stored **opaquely, in klinecharts' own shape**, by explicit prior design ("Opaque to the API by design").

**Live ticks:** `use-live-quote.ts`'s Socket.IO singleton feeds `livePrice` into `CandlestickChart.tsx`, which mutates the in-memory last bar and re-invokes the callback klinecharts registered via `setDataLoader({ subscribeBar })` — no `updateData`/`appendData` call; it's entirely through the `DataLoader` contract.

**Paper trading markers:** confirmed **absent** today — `PositionsPanel.tsx` and `OrderTicket.tsx` never touch the chart. The only trade marks on the chart are backtest entry/exit annotations from the chat agent (`ChatDrawing.kind === "trade_marker"`), unrelated to live positions.

**Built-ins:** `EMA`, `MA`, `BOLL`, `SAR`, `BBI`, `VOL`, `MACD`, `RSI`, `KDJ` — all native klinecharts indicators, registered by name, no custom render logic of their own.

## Risk-ranked pieces

1. **Diascript's render adapter (highest risk).** klinecharts' `figures`/pixel-`attrs` model — especially `fill`'s per-bar-pair polygon coordinates — has no Lightweight Charts equivalent; needs LWC's Series Primitives API written from scratch.
2. **Drawing tools + the backend-persisted layout schema.** Real user data (`SavedDrawing`) is stored in a library-specific shape today; existing saved layouts need a path forward, not just new code for new drawings.
3. **Multi-pane indicator placement** (`MAIN_PANE_INDICATORS`). Mechanical remapping to LWC's `IPaneApi` (pane creation, series-to-pane assignment, stretch factors) — lower risk, but LWC's multi-pane support is newer than klinecharts' and needs verifying against the exact set of pane behaviors this app relies on (co-locating multiple overlays on the main candle pane without eviction).
4. **`DataLoader` push/pull contract.** History paging (pan-back-to-load-more) and the live-tick path both need rewriting against LWC's `series.update()` / range-change model. Mechanical, but touches the live-tick path, which is easy to silently break and hard to catch outside a real browser check.

All four now happen *behind* the `ChartAdapter` boundary above — same technical difficulty, but contained to the adapter implementation instead of spread across every consumer.

## Sequenced approach

Each step ships a working, testable state — no step leaves the app in a half-migrated condition longer than the step itself takes.

1. **Extract the `ChartAdapter` interface, klinecharts implementation behind it.** Pure refactor, zero behavior change: every direct `klinecharts` import/call moves into a `KlinechartsAdapter` class implementing the new interface; every consumer (`CandlestickChart.tsx`, `terminal/page.tsx`, `use-chart-layout.ts`, `DrawingToolbar.tsx`) is rewritten to call the interface instead. Ships the decoupling on its own, before any new library is involved — lowest-risk step, and it de-risks everything after it.
2. **Diascript LWC adapter**, built and tested in the diascript repo, independent of this frontend. New `adapters/render/lightweight-charts/`, mirroring the existing klinecharts adapter's structure. Tested against the *same* fixture and golden values `diascript-indicators.test.ts` already carries — no dependency on any frontend change. `barcolor` stays unimplemented (matches today).
3. **New `LightweightChartsAdapter`** implementing the same `ChartAdapter` interface from Step 1, using diascript's new LWC adapter internally for indicator rendering: candles + the nine native indicators + diascript indicators, at both mount sites. Because Step 1 already moved every consumer onto the interface, this step is genuinely isolated — no consumer code changes here.
4. **`ChartDataSource` implementation for LWC**: history paging and the live-tick path, against LWC's `series.update()` / range-change model, behind the `setDataSource`/`pushLiveTick` interface methods from Step 1. Gets a manual browser check specifically (live ticks are the easiest thing here to break without a test catching it).
5. **Drawing tools + saved-layout migration**: implement `addDrawing`/`removeDrawings`/`listDrawings` against LWC primitives/built-ins for the seven overlay kinds. Spans two repos: `ai-trader-frontend` (the adapter implementation, `lib/api/charts.ts`'s client shape) and `ai-trader-api` (the `chart-layouts` module — `schemas/chart-layout.schema.ts`, `chart-layouts.service.ts` — where `SavedDrawing` persists to Mongo). Keep the existing "opaque, library-native payload" philosophy rather than a permanent translation shim — store LWC's native shape going forward, tagged with a `format`/`adapterId` field (new, for forward compatibility — see Decoupling section), and run a **one-time migration** converting existing klinecharts-shaped saved layouts in the `chart-layouts` collection.
6. **Multi-pane placement**, mapped last since it's lowest-risk and easiest to verify once everything else is already rendering correctly.

## Decisions made in this spec (flagged for self-review / user check)

- **`diascript` becomes a fourth git submodule** of this umbrella repo (`.gitmodules` currently lists `ai-trader-signals`/`ai-trader-api`/`ai-trader-frontend` only; diascript is npm-installed but not checked out anywhere in this workspace). Needed so Step 2's work happens in-repo, under the same review flow as the other three services, rather than in an untracked clone. Path: `diascript`, url pattern matching the existing three (`git@github-devrunch:devrunch/diascript.git`).
- **No permanent klinecharts/LWC dual-format shim** for saved drawings — one-time data migration instead, per Step 5, run against `ai-trader-api`'s `chart-layouts` Mongo collection. This is the one step touching real stored user data; the migration script needs a dry-run/verify mode before it's run for real, and should not be scripted to run automatically as part of a deploy.
- **`ChartAdapter` interface is app-level, owned in `ai-trader-frontend`**, not diascript — diascript's own adapter concept is one layer lower (rendering diascript's *output types*, not owning the whole chart lifecycle). Keeping them separate means diascript stays chart-library-agnostic on its own terms, and this repo's adapter can call diascript's render adapter internally without diascript needing to know anything about the rest of the chart.

## Testing strategy per step

- Step 1: no functional test changes expected — this is the regression bar. Same manual behavior (indicators, drawings, live ticks, resize) before and after, verified in a real browser; if anything visibly changes, the refactor wasn't behavior-preserving.
- Step 2: unit tests in the diascript repo, golden-value parity with the existing klinecharts adapter's output for every catalog indicator (same fixture, same expected values — a render-adapter swap must not change *what* is computed, only how it's drawn).
- Step 3: existing `diascript-indicators.test.ts` and `IndicatorSearchModal.test.tsx` continue passing unmodified (neither touches klinecharts/LWC directly, per the current-state scan) — a regression there means the swap leaked into code that shouldn't have changed.
- Step 4: manual browser verification of live-tick updates and pan-back history loading, on both mount sites (terminal + landing-page demo).
- Step 5: migration script gets a dry-run mode reporting every layout it would touch before any write; manual verification that a pre-migration saved layout still renders correctly post-migration.
- Step 6: manual verification that indicators requiring their own pane (RSI, MACD, KDJ, VOL, and diascript sub-pane entries) don't land on the candle pane, and that main-pane overlays (EMA, BOLL, SAR, BBI, diascript overlay indicators) don't evict each other — the exact failure mode the current `isStack: true` gotcha protects against today.
