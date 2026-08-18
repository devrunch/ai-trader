# Indicator Library + Search Modal — Design

**Status:** Approved by user, 2026-08-18. Phase 1 of a multi-phase rollout toward TradingView-scale indicator coverage (upgrade #2 of the three-upgrade roadmap: Signal Models / Indicator Library / Custom Graph Agent — the other two, #2's original scope and #3, were completed earlier this session).

## Goal

Replace the terminal's small ~10-item indicator dropdown with a real searchable indicator picker, and expand the indicator library from ~11 entries (9 native klinecharts built-ins + 2 diascript-authored proofs of concept) to ~46, by authoring 35 new indicators as diascript formulas — computed client-side from the same bars already on the chart, rendered through the exact pipeline already proven working for `DIA_EMA20`/`DIA_RSI14`.

Not in scope for this phase: per-indicator parameter configuration (editing period/color after adding — Phase 2+), Volume Profile (a price-level histogram, structurally incompatible with every other indicator's per-bar time-series model), Advance/Decline (needs market-breadth data this app has no source for), and anything needing a second comparison instrument (Correlation Coefficient) — that needs new picker UI, not just a formula.

## Architecture

```
diascript engine (D:\adizx\diascript)
  + highestbars(x,n) / lowestbars(x,n)   — new windowed primitives
  + line(x, offset=N) / band(..., offset=N) — new optional output-wrapper arg
  + log(x)                                — new point-wise primitive
        │
        ▼
lib/diascript-indicators.ts (ai-trader-frontend)
  DIASCRIPT_CATALOG: DiascriptIndicatorDef[]   — 35 new entries, data-driven
  registerDiascriptIndicators() loops the catalog instead of naming each export
        │
        ▼
components/terminal/IndicatorMenu.tsx → IndicatorSearchModal.tsx
  INDICATOR_CATALOG (native + diascript, now with `category`) — searchable, categorized
        │
        ▼
components/CandlestickChart.tsx  — UNCHANGED
  Already treats every name in `indicators` identically regardless of source;
  a bigger catalog is just more names through the same proven attach path.
```

No backend involvement. Every new indicator computes from the same `OHLCV[]` bars the chart already has — no new API calls, no new Python code. This is a pure client-side content + UI expansion.

## Component 1: diascript engine extensions

Three additions, in `D:\adizx\diascript\src`, all reusable primitives (not one-off hacks for a specific indicator):

### `highestbars(x, n)` / `lowestbars(x, n)`

Return the bar-offset (`0` to `n-1`, `0` = most recent) of the extreme value within the trailing window of length `n` — mirrors Pine's `ta.highestbars`/`ta.lowestbars`. Implemented alongside the existing windowed-function family (`sma`/`ema`/`highest`/`lowest`/etc.) in `src/engine/windowed.ts`, added to `ARITY` (arity 2) and `RESERVED` in `src/parser.ts`. Unlocks Aroon (`aroon_up = 100 * (n - highestbars(high, n)) / n`).

### Forward-offset plotting

`line(x, offset=26)` and `band(upper, lower, offset=26)` accept an optional named `offset` argument (default `0`) that shifts the formula's values to render at `bar_index + offset` instead of the current bar. Grammar change: `argument = expression | IDENTIFIER "=" expression` already supports named args (used today for `color=`); `offset` is a new recognized key for `line`/`band` specifically. `IndicatorOutput`'s point `time`/index gains the shift before being handed to the render adapter. Unlocks Ichimoku's Senkou spans (real Ichimoku projects them 26 bars into the future).

**Real technical risk, to spike before committing in the implementation plan:** it is not yet confirmed that klinecharts' rendering surface can draw a point beyond the currently-loaded candle range — it may clip. The plan's first task for this component must include a small spike proving (or disproving) this against the real, installed `klinecharts` package before the rest of the offset-plotting work is built on top of it. If klinecharts cannot render beyond the loaded range, the fallback — already accepted as viable during design — is shipping Ichimoku without forward displacement, clearly labeled as a simplification in its label/tooltip.

### `log(x)`

Natural log, point-wise, arity 1 — added alongside `abs`/`min`/`max` in the same family, same file (`src/engine/evaluator.ts`'s point-wise math handling), same `ARITY`/`RESERVED` treatment. Needed for Fisher Transform (`0.5 * log((1+x)/(1-x))`) and the log-return variant of Historical Volatility. Trivial, low-risk — no new grammar shape, just one more reserved function name.

All three extensions get: a `RESERVED`/`ARITY` entry, an evaluator implementation, unit tests (including rejection tests for wrong arity — the existing pattern every other primitive already follows), and a mention in `docs/grammar.md`.

## Component 2: `lib/diascript-indicators.ts` — catalog restructure

Today this file hand-names two exports (`DIASCRIPT_EMA_20`, `DIASCRIPT_RSI_14`) and calls `registerDiascriptIndicator` once per name inside `registerDiascriptIndicators()`. At 35+ new entries this stops scaling. It becomes data-driven:

```typescript
export interface DiascriptIndicatorDef {
  name: string;        // e.g. "DIA_MACD_LINE" — the klinecharts-facing indicator name
  label: string;       // "MACD"
  category: IndicatorCategory;
  source: string;      // the diascript formula text (may define multiple formulas for multi-output indicators)
  outputName: string;  // which wrapped formula in `source` this entry renders
}

export type IndicatorCategory = "Trend" | "Momentum" | "Volatility" | "Volume" | "Overlays";

export const DIASCRIPT_CATALOG: DiascriptIndicatorDef[] = [
  // ~35 entries, one per rendered output (a multi-line indicator like MACD
  // contributes multiple entries sharing one `source` block, exactly matching
  // the pattern the original design spec's MACD worked example already shows)
];

export function registerDiascriptIndicators(): void {
  if (registered) return;
  registered = true;
  for (const def of DIASCRIPT_CATALOG) {
    registerDiascriptIndicator(def.name, {
      source: def.source, outputName: def.outputName,
      adapter: noopAdapter, symbolTicker: "",
    });
  }
}
```

The existing `DIA_EMA20`/`DIA_RSI14` entries migrate into this same catalog structure (no behavior change, just moved into the data-driven form).

## Component 3: `IndicatorSearchModal.tsx` — replaces `IndicatorMenu.tsx`'s dropdown

Same trigger button and badge-count as today (`IndicatorMenu`'s existing button markup is kept), but clicking it opens a modal instead of a small absolute-positioned dropdown — a ~46-item flat list no longer fits a dropdown usably.

- A search input at the top, filtering by substring match on `label` (case-insensitive), live as the user types.
- A left-rail category filter (`Overlays` / `Trend` / `Momentum` / `Volatility` / `Volume`), clicking one narrows the list; an "All" option (default) shows everything.
- Results list: each row shows the label and a checkmark/toggle state identical to today's semantics — click toggles it on/off in the `active` list, calling the same `onToggle(name)` callback `IndicatorMenu` already exposes. No new callback contract; `IndicatorSearchModal` is a drop-in replacement for `IndicatorMenu`'s body, same props (`active: string[]`, `onToggle: (name: string) => void`).
- Escape / click-outside closes it, same as today's dropdown.
- `INDICATOR_CATALOG` (the merged native + diascript list `IndicatorMenu.tsx` currently defines) gains a `category` field on every entry — including the existing 9 native ones, which need categorizing too (e.g. `EMA`/`MA`/`BOLL`/`SAR`/`BBI` → `Overlays`/`Trend`; `VOL` → `Volume`; `MACD`/`RSI`/`KDJ` → `Momentum`).

No change to `CandlestickChart.tsx`, `terminal/page.tsx`'s `indicators` state, or the apply/remove `useEffect` — all of that already works identically regardless of which catalog entry produced a name.

## Phase 1 indicator list (35 new)

**Trend (10):** Average Directional Index (+DI/-DI), Aroon, Donchian Channels, Envelopes, Ichimoku Cloud, Keltner Channels, Hull Moving Average, Double EMA, Triple EMA, SuperTrend

**Momentum (12):** Stochastic, Stochastic RSI, Awesome Oscillator, Momentum, Rate of Change, Commodity Channel Index, Williams %R, Ultimate Oscillator, TRIX, Fisher Transform, Money Flow Index, Chande Momentum Oscillator

**Volatility (5):** Average True Range, Bollinger Bands %B, Bollinger Bands Width, Standard Deviation, Historical Volatility

**Volume (8):** On Balance Volume, Accumulation/Distribution, Chaikin Money Flow, VWAP, VWMA, Volume Oscillator, Price Volume Trend, Ease of Movement

**Deferred to Phase 2** (not clean-and-common enough to justify Phase 1 effort, or need the second-instrument comparison UI not built yet): Zig Zag, Vortex Indicator, Klinger Oscillator, McGinley Dynamic, Chande Kroll Stop, the Linear Regression family (Curve/Slope/Least Squares MA), Guppy Multiple Moving Average, Correlation Coefficient (and Correlation - Log), Net Volume, Moving Average Channel, and the remainder of TradingView's ~100-item list not named above.

**Permanently out of scope, not just deferred:** Volume Profile (Fixed/Visible Range) — a price-level histogram, a fundamentally different rendering paradigm from every other indicator here (all of which are one-value-per-bar time series); would need new chart infrastructure, not a new formula. Advance/Decline — market-breadth data across a whole index/basket, which this app has no data source for at all.

## Data flow

Unchanged from today's `DIA_EMA20`/`DIA_RSI14` path: `CandlestickChart.tsx` dynamically imports `klinecharts` and `lib/diascript-indicators.ts` together, calls `registerDiascriptIndicators()` once, and the existing indicator-apply `useEffect` calls `chart.createIndicator(name, isStack)` for whatever's in the `indicators` array — klinecharts then calls back into each diascript indicator's `calc` function (already reactive, built during the graph-generation-subagent work) with its own live `dataList` on every render. No new data ever needs to reach the frontend beyond the OHLCV bars it already fetches for the candlesticks themselves.

## Error handling

Unlike the agent-authored custom-indicator feature (built earlier, validated at runtime via a subprocess because an LLM writes the formula), these 35 formulas are hand-authored, reviewed, and committed to the repo — the correctness burden is caught at development time via golden-value tests, not at runtime. No new runtime error-handling mechanism is needed beyond what `registerDiascriptIndicator`/`chart.createIndicator` already have (a malformed catalog entry would fail a test before ever merging).

## Testing

- **diascript engine:** unit tests for `highestbars`/`lowestbars` (including the arity-rejection test every other primitive has), `log`, and offset plotting (including a test proving the render adapter receives correctly-shifted point indices). A spike/test proving or disproving klinecharts' ability to render beyond the loaded range, done FIRST, before the rest of offset-plotting is built.
- **Golden-value tests:** each of the 35 new formulas computed via diascript against a fixed OHLCV fixture, compared against `ai-trader-signals`'s existing `pandas_ta`-backed computation (`app/signals/indicators.py` already computes roughly 20 of these 35 — ADX, Aroon, Stochastic, StochRSI, TSI-adjacent, Williams %R, Ultimate Oscillator, ATR, OBV, CMF, VWAP, HMA, Keltner, Donchian, SuperTrend, PSAR are all either already computed there or closely related) within a small numeric tolerance. This is a real regression check against a reference implementation that already exists and is trusted, not a new indicator trusted purely on the strength of its own formula being "in the grammar."
- For the ~15 of the 35 with no existing Python reference (Envelopes, Double/Triple EMA, Fisher Transform, Chande Momentum Oscillator, Bollinger %B/Width, Standard Deviation, VWMA, Volume Oscillator, Price Volume Trend, Ease of Movement, Accumulation/Distribution, Awesome/Accelerator Oscillator, Money Flow Index, Rate of Change): golden values computed by hand against a small, fully-worked fixture (the same rigor the existing `spec/examples/trend-regime.dia` worked example already established), or cross-checked against a well-known reference implementation's published formula (e.g. the standard textbook definition), not against this repo's own code (since none exists yet for these).
- **Frontend:** manual browser verification (dev server, real chart) that a sample of new indicators renders correctly across categories — matching the verification rigor already used for `DIA_RSI14` earlier this session. A lightweight vitest test for the search modal's filter logic (search substring match, category filter) — pure function, easily unit-tested without a real chart.

## Out of scope for this phase

- Per-indicator parameter configuration UI (Phase 2+).
- The ~65 remaining named indicators from TradingView's full list not covered by Phase 1 or explicitly named as Phase 2 above.
- Volume Profile, Advance/Decline (permanently out of scope, per above).
- Any second-instrument comparison UI (blocks Correlation Coefficient/Correlation-Log until built).
