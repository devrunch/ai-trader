# Lightweight Charts + PineTS Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace klinecharts + diascript with Lightweight Charts + PineTS across the `ai-trader` umbrella repo, behind a library-agnostic `ChartAdapter` interface, with a sandboxed PineTS runtime driving both chart indicators and real paper-trade fills via the existing `PaperTradingService`.

**Architecture:** A pure-refactor extraction of `ChartAdapter` (Task 1) decouples every consumer from klinecharts before anything else changes. A sandboxed PineTS execution service (Task 2) is built and proven standalone. A `PineStrategyRunner` (Task 3) reads confirmed-bar strategy events out of that sandbox and calls the paper-trading service's existing order door — provable without any chart code. A render-mapping layer (Task 4) turns PineTS `plots` into Lightweight Charts series/primitives, which a new `LightweightChartsAdapter` (Task 5) wires into the `ChartAdapter` interface from Task 1, swapped in behind it with zero consumer changes. Data (Task 6), drawings (Task 7), storage schema (Task 8), the chat agent's indicator-authoring tool (Task 9), and pane placement (Task 10) follow in dependency order.

**Tech Stack:** Next.js/React/TypeScript (`ai-trader-frontend`), NestJS/Mongoose (`ai-trader-api`), FastAPI/Python (`ai-trader-signals`), `lightweight-charts@5.2.0` (already installed), `pinets@0.9.31` (AGPL-3.0, new dependency), Vitest (frontend), Jest (`ai-trader-api`), pytest (`ai-trader-signals`).

**Spec:** `docs/superpowers/specs/2026-08-21-lightweight-charts-migration-design.md`

## Global Constraints

- No indicator or drawing renders via klinecharts by the end of this plan — every consumer talks to `ChartAdapter` only (Task 1's whole point).
- PineTS never runs inline in an API process. Always an isolated worker/subprocess: no DB access, no credential access, no filesystem/network access, CPU + memory caps (Security model, spec).
- Every strategy order is gated on a fully-closed/confirmed bar — never the forming bar (spec: "Strategy execution & paper trading").
- No new order-placement path — `PineStrategyRunner` calls `PaperTradingService.placeOrder()` exactly as any other order source does (spec: Not in scope).
- No data migration tooling anywhere in this plan — confirmed no real users yet; schema and format changes are clean cutovers (spec: "Saved-layout schema change").
- Default chart state: candle + volume only, nothing else pre-attached (spec: "Default chart").

---

## Task 1: Extract `ChartAdapter` interface, `KlinechartsAdapter` implementation

**Files:**
- Create: `ai-trader-frontend/lib/chart-adapter/types.ts`
- Create: `ai-trader-frontend/lib/chart-adapter/klinecharts-adapter.ts`
- Modify: `ai-trader-frontend/components/CandlestickChart.tsx`
- Modify: `ai-trader-frontend/app/dashboard/terminal/page.tsx:201-295` (pickTool/clearMyDrawings/resetChart/removeTurnDrawings/applyDrawings)
- Modify: `ai-trader-frontend/lib/use-chart-layout.ts`
- Modify: `ai-trader-frontend/components/terminal/DrawingToolbar.tsx`
- Test: `ai-trader-frontend/lib/chart-adapter/klinecharts-adapter.test.ts`

**Interfaces:**
- Produces: `ChartAdapter` (below) — every later task implements or consumes this. `ManualDrawKind = "trendline" | "ray" | "hline" | "fib" | "rect"`.

- [ ] **Step 1: Write `types.ts` — the interface every later task builds against**

```ts
// ai-trader-frontend/lib/chart-adapter/types.ts
import type { ApiOhlcBar } from "@/lib/api";
import type { ChatDrawing } from "@/lib/api/chat";
import type { SavedDrawing } from "@/lib/api/charts";

export type PeriodType = "minute" | "hour" | "day" | "week" | "month";
export type ManualDrawKind = "trendline" | "ray" | "hline" | "fib" | "rect";

export interface ChartMountOptions {
  bars: ApiOhlcBar[];
  onLoadMore?: (oldestTimestampMs: number) => Promise<ApiOhlcBar[]>;
}

export interface PriceLevels {
  entry?: number;
  target?: number;
  stopLoss?: number;
}

/**
 * Everything a chart consumer needs, with zero library-specific types
 * crossing the boundary. Implemented today by KlinechartsAdapter (this
 * task), and by LightweightChartsAdapter later (Task 5) with no change
 * required here or in any consumer.
 */
export interface ChartAdapter {
  mount(el: HTMLElement, options: ChartMountOptions): Promise<void>;
  dispose(): void;
  resize(): void;

  setPriceLevels(levels: PriceLevels): void;
  pushLiveTick(price: number): void;

  setIndicators(names: string[]): void;

  addDrawings(drawings: ChatDrawing[], groupId: string): void;
  startManualDraw(kind: ManualDrawKind, groupId: string, onChange: () => void): void;
  removeDrawingsByGroup(groupId: string): void;
  removeDrawingsWhere(predicate: (groupId: string) => boolean): void;
  listSavedDrawings(groupIds: string[]): SavedDrawing[];
  restoreDrawings(drawings: SavedDrawing[]): void;
}
```

- [ ] **Step 2: Write `klinecharts-adapter.ts` — move CandlestickChart.tsx's klinecharts logic here verbatim**

This class owns exactly what `CandlestickChart.tsx` currently does directly: `init`/`dispose`, `setStyles`, `setSymbol`/`setPeriod`, `setDataLoader` (history paging + live-bar push via `subscribeBar`), the incremental indicator diff (`MAIN_PANE_INDICATORS` + `isStack: true`), the three signal price lines, and the seven-kind drawing translation currently split across `terminal/page.tsx`'s `pickTool`/`applyDrawings`/`resetChart`/`removeTurnDrawings` and `use-chart-layout.ts`'s save/restore. Nothing here is new logic — every line below is the original code, relocated and reshaped to the interface.

```ts
// ai-trader-frontend/lib/chart-adapter/klinecharts-adapter.ts
import type { Chart } from "klinecharts";
import type { ApiOhlcBar } from "@/lib/api";
import type { ChatDrawing } from "@/lib/api/chat";
import type { SavedDrawing } from "@/lib/api/charts";
import type { ChartAdapter, ChartMountOptions, ManualDrawKind, PriceLevels } from "./types";

const FONT = "Poppins, ui-sans-serif, system-ui, sans-serif";
const C = { buy: "#16c784", sell: "#f0525d", grid: "#1a1e28", axisText: "#8b8a9e", entry: "#8b8a9e" };

const MAIN_PANE_INDICATORS = new Set([
  "EMA", "MA", "SMA", "BOLL", "SAR", "BBI", "DIA_EMA20",
  "DIA_DONCHIAN_UPPER", "DIA_DONCHIAN_MID", "DIA_DONCHIAN_LOWER",
  "DIA_ENVELOPE_UPPER", "DIA_ENVELOPE_LOWER",
  "DIA_ICHIMOKU_TENKAN", "DIA_ICHIMOKU_KIJUN", "DIA_ICHIMOKU_SENKOU_A", "DIA_ICHIMOKU_SENKOU_B",
  "DIA_KELTNER_UPPER", "DIA_KELTNER_MID", "DIA_KELTNER_LOWER",
  "DIA_HMA", "DIA_DEMA", "DIA_TEMA", "DIA_SUPERTREND", "DIA_VWAP", "DIA_VWMA",
  "DIA_LINREG", "DIA_CHANDE_KROLL_LONG", "DIA_CHANDE_KROLL_SHORT",
  "DIA_AVG_PRICE", "DIA_MEDIAN_PRICE", "DIA_GAUSSIAN_FILTER",
]);

type Bar = { timestamp: number; open: number; high: number; low: number; close: number; volume?: number };

const MANUAL_OVERLAY_NAME: Record<ManualDrawKind, string> = {
  trendline: "segment", ray: "rayLine", hline: "horizontalStraightLine", fib: "fibonacciLine", rect: "rect",
};

export class KlinechartsAdapter implements ChartAdapter {
  private chart: Chart | null = null;
  private applied = new Map<string, string>();
  private barCallback: ((bar: Bar) => void) | null = null;
  private lastBar: Bar | null = null;
  private onLoadMore?: (oldestTimestampMs: number) => Promise<ApiOhlcBar[]>;
  private allBars: Bar[] = [];

  async mount(el: HTMLElement, options: ChartMountOptions): Promise<void> {
    const { init } = await import("klinecharts");
    const { registerDiascriptIndicators } = await import("@/lib/diascript-indicators");
    await registerDiascriptIndicators();

    this.onLoadMore = options.onLoadMore;
    const chart = init(el) as Chart;
    this.chart = chart;

    chart.setStyles({
      grid: { horizontal: { color: C.grid }, vertical: { color: C.grid } },
      candle: {
        bar: { upColor: C.buy, downColor: C.sell, upBorderColor: C.buy, downBorderColor: C.sell, upWickColor: C.buy, downWickColor: C.sell },
        priceMark: {
          high: { color: C.axisText, textFamily: FONT },
          low: { color: C.axisText, textFamily: FONT },
          last: { upColor: C.buy, downColor: C.sell, text: { family: FONT } },
        },
        tooltip: { title: { show: false } },
      },
      indicator: { tooltip: { title: { family: FONT }, legend: { family: FONT } } },
      xAxis: { axisLine: { color: C.grid }, tickLine: { color: C.grid }, tickText: { color: C.axisText, family: FONT } },
      yAxis: { axisLine: { color: C.grid }, tickLine: { color: C.grid }, tickText: { color: C.axisText, family: FONT } },
      crosshair: {
        horizontal: { line: { color: C.axisText }, text: { backgroundColor: "#2a2f3d", family: FONT } },
        vertical: { line: { color: C.axisText }, text: { backgroundColor: "#2a2f3d", family: FONT } },
      },
      overlay: { text: { family: FONT }, rectText: { family: FONT } },
    });

    const klineData: Bar[] = options.bars.map(b => ({
      timestamp: b.time > 2e9 ? b.time : b.time * 1000,
      open: b.open, high: b.high, low: b.low, close: b.close, volume: b.volume,
    }));
    this.allBars = klineData;
    this.lastBar = klineData.length ? { ...klineData[klineData.length - 1] } : null;

    let pType: "minute" | "hour" | "day" | "week" | "month" = "day";
    let pSpan = 1;
    if (klineData.length > 2) {
      const deltas: number[] = [];
      for (let i = 1; i < Math.min(klineData.length, 30); i++) deltas.push(klineData[i].timestamp - klineData[i - 1].timestamp);
      deltas.sort((a, b) => a - b);
      const md = deltas[Math.floor(deltas.length / 2)] || 86400000;
      const MIN = 60000;
      if (md <= MIN) { pType = "minute"; pSpan = 1; }
      else if (md <= 5 * MIN) { pType = "minute"; pSpan = 5; }
      else if (md <= 15 * MIN) { pType = "minute"; pSpan = 15; }
      else if (md <= 60 * MIN) { pType = "hour"; pSpan = 1; }
      else if (md <= 24 * 60 * MIN) { pType = "day"; pSpan = 1; }
      else if (md <= 7 * 24 * 60 * MIN) { pType = "week"; pSpan = 1; }
      else { pType = "month"; pSpan = 1; }
    }

    chart.setSymbol({ ticker: "SYM", pricePrecision: 2, volumePrecision: 0 });
    chart.setPeriod({ span: pSpan, type: pType });

    chart.setDataLoader({
      getBars: ({ type, callback }) => {
        if (type === "init") { callback(this.allBars, { forward: true, backward: false }); return; }
        if (type !== "forward" || !this.onLoadMore || this.allBars.length === 0) { callback([], false); return; }
        this.onLoadMore(this.allBars[0].timestamp)
          .then((older) => {
            const mapped: Bar[] = older.map(b => ({
              timestamp: b.time > 2e9 ? b.time : b.time * 1000,
              open: b.open, high: b.high, low: b.low, close: b.close, volume: b.volume,
            }));
            if (mapped.length) this.allBars = [...mapped, ...this.allBars];
            callback(mapped, mapped.length > 0);
          })
          .catch(() => callback([], false));
      },
      subscribeBar: ({ callback }) => { this.barCallback = callback; },
      unsubscribeBar: () => { this.barCallback = null; },
    });
    chart.scrollToRealTime();
  }

  dispose(): void {
    if (!this.chart) return;
    import("klinecharts").then(({ dispose }) => dispose(this.chart as unknown as string));
    this.chart = null;
    this.applied.clear();
  }

  resize(): void { this.chart?.resize(); }

  setPriceLevels(levels: PriceLevels): void {
    const chart = this.chart;
    if (!chart) return;
    const line = (value: number | undefined, color: string) => {
      if (value == null) return;
      chart.createOverlay({
        name: "priceLine", points: [{ value }], lock: true,
        styles: { line: { color, style: "dashed", size: 1 }, text: { color: "#0b0e14", backgroundColor: color } },
      });
    };
    line(levels.entry, C.entry);
    line(levels.target, C.buy);
    line(levels.stopLoss, C.sell);
  }

  pushLiveTick(price: number): void {
    if (!this.barCallback || !this.lastBar || price <= 0) return;
    const updated = { ...this.lastBar, close: price, high: Math.max(this.lastBar.high, price), low: Math.min(this.lastBar.low, price) };
    this.lastBar = updated;
    this.barCallback(updated);
  }

  setIndicators(names: string[]): void {
    const chart = this.chart;
    if (!chart) return;
    const wanted = new Set(names);
    for (const [name, id] of [...this.applied]) {
      if (wanted.has(name)) continue;
      chart.removeIndicator({ id });
      this.applied.delete(name);
    }
    for (const name of wanted) {
      if (this.applied.has(name)) continue;
      const id = MAIN_PANE_INDICATORS.has(name)
        ? chart.createIndicator(name === "EMA" ? { name, calcParams: [20, 50], paneId: "candle_pane" } : { name, paneId: "candle_pane" }, true)
        : chart.createIndicator(name);
      if (id) this.applied.set(name, id);
    }
  }

  addDrawings(drawings: ChatDrawing[], groupId: string): void {
    const chart = this.chart;
    if (!chart) return;
    for (const d of drawings) {
      try {
        if (d.kind === "segment" && d.points) {
          chart.createOverlay({ name: "segment", points: d.points, groupId, lock: true, styles: { line: { color: d.color || "#6c5ce7", size: 2 } } });
        } else if (d.kind === "priceline" && d.value != null) {
          chart.createOverlay({ name: "priceLine", points: [{ value: d.value }], groupId, lock: true,
            styles: { line: { color: d.color || "#8b8a9e", style: "dashed" }, text: { color: "#0b0e14", backgroundColor: d.color || "#8b8a9e" } } });
        } else if (d.kind === "fibonacci" && d.points) {
          chart.createOverlay({ name: "fibonacciLine", points: d.points, groupId, lock: true });
        } else if (d.kind === "series" && d.points) {
          chart.createOverlay({ name: "brush", points: d.points, groupId, lock: true, styles: { line: { color: d.color || "#e0ab4a", size: 2 } } });
        } else if (d.kind === "trade_marker" && d.timestamp != null && d.value != null) {
          chart.createOverlay({ name: "simpleAnnotation", points: [{ timestamp: d.timestamp, value: d.value }], groupId, lock: true,
            extendData: d.side === "BUY" ? "▲" : "▼", styles: { text: { color: d.color || "#8b8a9e", size: 12 } } });
        }
      } catch { /* ignore unknown overlay */ }
    }
  }

  startManualDraw(kind: ManualDrawKind, groupId: string, onChange: () => void): void {
    this.chart?.createOverlay({ name: MANUAL_OVERLAY_NAME[kind], groupId, onDrawEnd: () => { onChange(); return false; }, onRemoved: () => { onChange(); return false; } });
  }

  removeDrawingsByGroup(groupId: string): void { this.chart?.removeOverlay({ groupId }); }

  removeDrawingsWhere(predicate: (groupId: string) => boolean): void {
    const chart = this.chart;
    if (!chart) return;
    for (const o of chart.getOverlays()) if (predicate(String(o.groupId ?? ""))) chart.removeOverlay({ id: o.id });
  }

  listSavedDrawings(groupIds: string[]): SavedDrawing[] {
    const chart = this.chart;
    if (!chart) return [];
    const out: SavedDrawing[] = [];
    for (const groupId of groupIds) {
      for (const overlay of chart.getOverlays({ groupId })) {
        out.push({ name: overlay.name, points: overlay.points as SavedDrawing["points"], styles: overlay.styles as Record<string, unknown> | undefined, extendData: overlay.extendData, groupId });
      }
    }
    return out;
  }

  restoreDrawings(drawings: SavedDrawing[]): void {
    const chart = this.chart;
    if (!chart) return;
    for (const drawing of drawings) {
      try { chart.createOverlay({ ...drawing, lock: true } as Parameters<Chart["createOverlay"]>[0]); } catch { /* unknown overlay type */ }
    }
  }
}
```

- [ ] **Step 3: Write the behavior-preservation test**

```ts
// ai-trader-frontend/lib/chart-adapter/klinecharts-adapter.test.ts
// @vitest-environment happy-dom
import { describe, it, expect } from "vitest";
import { KlinechartsAdapter } from "./klinecharts-adapter";

describe("KlinechartsAdapter", () => {
  it("mounts, applies price levels and default candle+volume, and disposes without throwing", async () => {
    const el = document.createElement("div");
    document.body.appendChild(el);
    const adapter = new KlinechartsAdapter();
    await adapter.mount(el, { bars: [
      { time: 1767000900, open: 100, high: 101, low: 99, close: 100.5, volume: 1000 },
      { time: 1767000960, open: 100.5, high: 102, low: 100, close: 101.5, volume: 1200 },
    ] });
    adapter.setPriceLevels({ entry: 100, target: 105, stopLoss: 98 });
    adapter.setIndicators(["VOL"]);
    adapter.resize();
    adapter.dispose();
  });
});
```

- [ ] **Step 4: Run the test**

Run: `cd ai-trader-frontend && npx vitest run lib/chart-adapter/klinecharts-adapter.test.ts`
Expected: PASS

- [ ] **Step 5: Rewrite `CandlestickChart.tsx` to a thin host**

Replace every direct klinecharts call with calls into a `KlinechartsAdapter` instance held in a ref. Keep exactly the same React lifecycle shape (init effect keyed on `[bars, signal, height, fill]`, NOT `indicators`; a separate incremental effect for indicators; a separate live-tick effect) — only the *body* of each effect changes, from raw klinecharts calls to adapter method calls. `onReady` now hands the parent the adapter instance (typed `ChartAdapter`), not a raw `Chart` — every consumer of `onReady`/`chartRef` (Steps 6-8 below) is updated together with this step, since a partial rewire would leave the component in a broken state that Step 4's tests can't catch (they test the adapter in isolation, not the wiring).

```tsx
// ai-trader-frontend/components/CandlestickChart.tsx (relevant excerpt — imports, props, and the three effects change; ChartLegend/candleLegend/pricing helpers stay exactly as they are today)
"use client";
import { useRef, useEffect, useState } from "react";
import type { ChartAdapter } from "@/lib/chart-adapter/types";
import { KlinechartsAdapter } from "@/lib/chart-adapter/klinecharts-adapter";
import type { ApiOhlcBar } from "@/lib/api";

export function CandlestickChart({ bars, signal, height = 320, fill = false, indicators = [], livePrice, onReady, onLoadMore }: {
  bars: ApiOhlcBar[];
  signal: ChartSignal | null;
  height?: number;
  fill?: boolean;
  indicators?: string[];
  livePrice?: number;
  onReady?: (adapter: ChartAdapter) => void;
  onLoadMore?: (oldestTimestampMs: number) => Promise<ApiOhlcBar[]>;
}) {
  const containerRef = useRef<HTMLDivElement>(null);
  const adapterRef = useRef<ChartAdapter | null>(null);
  const [chartReady, setChartReady] = useState(0);
  const onReadyRef = useRef(onReady);
  useEffect(() => { onReadyRef.current = onReady; }, [onReady]);
  const onLoadMoreRef = useRef(onLoadMore);
  useEffect(() => { onLoadMoreRef.current = onLoadMore; }, [onLoadMore]);

  useEffect(() => {
    if (!containerRef.current || bars.length === 0) return;
    const el = containerRef.current;
    let cancelled = false;
    const adapter = new KlinechartsAdapter();
    adapter.mount(el, { bars, onLoadMore: (ts) => onLoadMoreRef.current?.(ts) ?? Promise.resolve([]) }).then(() => {
      if (cancelled) { adapter.dispose(); return; }
      adapterRef.current = adapter;
      if (signal) adapter.setPriceLevels({ entry: signal.entryPrice, target: signal.targetPrice, stopLoss: signal.stopLoss });
      const ro = new ResizeObserver(() => adapter.resize());
      ro.observe(el);
      onReadyRef.current?.(adapter);
      setChartReady(n => n + 1);
      (adapter as unknown as { __ro?: ResizeObserver }).__ro = ro;
    });
    return () => {
      cancelled = true;
      const a = adapterRef.current as unknown as { __ro?: ResizeObserver } | null;
      a?.__ro?.disconnect();
      adapterRef.current?.dispose();
      adapterRef.current = null;
    };
  }, [bars, signal, height, fill]);

  useEffect(() => { adapterRef.current?.setIndicators(indicators); }, [indicators, chartReady]);
  useEffect(() => { if (livePrice && livePrice > 0) adapterRef.current?.pushLiveTick(livePrice); }, [livePrice]);

  return (
    <div ref={containerRef} role="img"
      aria-label="Price chart. Numeric levels are listed in the panels beside the chart."
      className={fill ? "w-full h-full" : "w-full"} style={fill ? undefined : { height }} />
  );
}
```

- [ ] **Step 6: Rewire `terminal/page.tsx` off raw klinecharts calls**

Replace `chartRef: React.RefObject<Chart | null>` with `React.RefObject<ChartAdapter | null>`. Rewrite the five functions to call the interface:

```ts
// ai-trader-frontend/app/dashboard/terminal/page.tsx — replacing lines 201-295
function pickTool(t: DrawTool) {
  setActiveTool(t.key);
  if (t.kind && chartRef.current) {
    chartRef.current.startManualDraw(t.kind, "draw", () => layout.scheduleSave());
  }
}
function clearMyDrawings() {
  chartRef.current?.removeDrawingsByGroup("draw");
  setActiveTool("cursor");
  layout.scheduleSave();
}
function resetChart() {
  chartRef.current?.removeDrawingsByGroup("draw");
  chartRef.current?.removeDrawingsWhere((groupId) => groupId.startsWith("ai"));
  setIndicators(DEFAULT_INDICATORS);
  setActiveTool("cursor");
  layout.clear();
}
function removeTurnDrawings(turnId: string) {
  chartRef.current?.removeDrawingsByGroup(`ai:${turnId}`);
  layout.scheduleSave();
}
function applyDrawings(drawings: ChatDrawing[], turnId?: string) {
  const groupId = turnId ? `ai:${turnId}` : "ai";
  chartRef.current?.addDrawings(drawings, groupId);
  if (drawings.length) layout.scheduleSave();
}
```

- [ ] **Step 7: Rewire `use-chart-layout.ts` off raw klinecharts calls**

```ts
// ai-trader-frontend/lib/use-chart-layout.ts — replacing the restore loop (lines 81-93) and save() (lines 115-126)
import type { ChartAdapter } from "@/lib/chart-adapter/types";
// chartRef: React.RefObject<ChartAdapter | null>  (was React.RefObject<Chart | null>)

// inside the restore effect, replacing the for-loop:
chartRef.current?.restoreDrawings(layout.drawings);

// inside save():
const drawings = chartRef.current?.listSavedDrawings([...SAVED_GROUPS]) ?? [];
```

- [ ] **Step 8: Rename `DrawingToolbar.tsx`'s `overlay` field to `kind`, using `ManualDrawKind`**

```tsx
// ai-trader-frontend/components/terminal/DrawingToolbar.tsx
import type { ManualDrawKind } from "@/lib/chart-adapter/types";

export interface DrawTool {
  key: string;
  title: string;
  kind: ManualDrawKind | null;   // was: overlay: string | null
  icon: React.ReactNode;
}

export const DRAW_TOOLS: DrawTool[] = [
  { key: "cursor", title: "Cursor", kind: null, icon: /* unchanged */ <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor"><path d="M4 2l16 8-7 2-2 7z"/></svg> },
  { key: "trendline", title: "Trend line", kind: "trendline", icon: /* unchanged */ <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8"><line x1="4" y1="20" x2="20" y2="4"/></svg> },
  { key: "ray", title: "Ray", kind: "ray", icon: /* unchanged */ <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8"><circle cx="5" cy="19" r="1.6" fill="currentColor"/><line x1="6" y1="18" x2="20" y2="4"/></svg> },
  { key: "hline", title: "Horizontal line", kind: "hline", icon: /* unchanged */ <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8"><line x1="3" y1="12" x2="21" y2="12"/></svg> },
  { key: "fib", title: "Fibonacci retracement", kind: "fib", icon: /* unchanged */ <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6"><line x1="3" y1="5" x2="21" y2="5"/><line x1="3" y1="10" x2="21" y2="10"/><line x1="3" y1="15" x2="21" y2="15"/><line x1="3" y1="20" x2="21" y2="20"/></svg> },
  { key: "rect", title: "Rectangle", kind: "rect", icon: /* unchanged */ <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8"><rect x="4" y="6" width="16" height="12" rx="1"/></svg> },
];
```

- [ ] **Step 9: Grep-verify the decoupling actually holds**

Run: `cd ai-trader-frontend && grep -rn "from \"klinecharts\"" --include="*.tsx" --include="*.ts" . | grep -v node_modules | grep -v lib/chart-adapter`
Expected: no output — the only file importing `klinecharts` directly is `lib/chart-adapter/klinecharts-adapter.ts`.

- [ ] **Step 10: Full regression check and commit**

Run: `cd ai-trader-frontend && npx vitest run && npx tsc --noEmit`
Expected: all existing tests pass unmodified (per the spec's Step 1 testing note — this is the regression bar), typecheck clean.

```bash
git add ai-trader-frontend/lib/chart-adapter ai-trader-frontend/components/CandlestickChart.tsx \
  ai-trader-frontend/app/dashboard/terminal/page.tsx ai-trader-frontend/lib/use-chart-layout.ts \
  ai-trader-frontend/components/terminal/DrawingToolbar.tsx
git commit -m "refactor: extract ChartAdapter interface, KlinechartsAdapter behind it"
```

---

## Task 2: PineTS sandbox — isolated execution service

**Files:**
- Create: `ai-trader-signals/app/pine_sandbox/` (new directory — this is Node.js code living inside the Python `ai-trader-signals` service, matching the precedent already set by `diascript-validate`/the graph-generation subagent's Node subprocess calls)
- Create: `ai-trader-signals/app/pine_sandbox/package.json`
- Create: `ai-trader-signals/app/pine_sandbox/worker.mjs`
- Create: `ai-trader-signals/app/pine_sandbox/run_pine.mjs`
- Create: `ai-trader-signals/app/signals/pine/sandbox.py`
- Test: `ai-trader-signals/app/pine_sandbox/worker.test.mjs`
- Test: `ai-trader-signals/tests/test_pine_sandbox.py`

**Interfaces:**
- Produces: `run_pine_script(source: str, bars: list[dict], mode: Literal["indicator","strategy"], timeout_s: float = 5.0) -> PineRunResult` (Python), where `PineRunResult` is `{ok: bool, plots: dict | None, strategy: dict | None, error: str | None}`.
- Consumes: nothing from earlier tasks — this is the first piece of new infrastructure, deliberately buildable and testable standalone (per the spec's sequencing).

- [ ] **Step 1: `package.json` for the sandbox subprocess**

```json
{
  "name": "pine-sandbox",
  "private": true,
  "type": "module",
  "dependencies": { "pinets": "^0.9.31" }
}
```

- [ ] **Step 2: `worker.mjs` — runs inside a Node `worker_threads` Worker, no DOM/fetch/fs**

The isolation boundary: this file only ever receives a `{source, bars, mode}` message and only ever posts back `{ok, plots, strategy, error}` — no other channel in or out. `pinets`'s own `.run()` internally transpiles-and-executes the Pine source (per its own docs: "internally it lexes → parses → codegens JavaScript" — the transpile step is inert text processing; only `.run()` actually executes anything), so everything downstream of that call is untrusted code running with whatever ambient capabilities this worker has — hence no `fs`/`net`/`process.env` access is given to it beyond what `worker_threads` grants by default (already sandboxed relative to the parent's file descriptors/env unless explicitly shared).

```js
// ai-trader-signals/app/pine_sandbox/worker.mjs
import { parentPort } from "node:worker_threads";
import { PineTS } from "pinets";

parentPort.on("message", async ({ source, bars, mode }) => {
  try {
    const pine = new PineTS(bars);
    const ctx = await pine.run(source);
    if (mode === "strategy") {
      parentPort.postMessage({
        ok: true,
        plots: null,
        strategy: {
          opentrades: ctx.strategy?.opentrades ?? [],
          closedtrades: ctx.strategy?.closedtrades ?? [],
          pending_orders: ctx.strategy?.pending_orders ?? [],
        },
        error: null,
      });
    } else {
      const plots = {};
      for (const [name, plot] of Object.entries(ctx.plots ?? {})) plots[name] = plot.data;
      parentPort.postMessage({ ok: true, plots, strategy: null, error: null });
    }
  } catch (err) {
    parentPort.postMessage({ ok: false, plots: null, strategy: null, error: String(err?.message ?? err) });
  }
});
```

- [ ] **Step 3: `run_pine.mjs` — the CLI entry point, owns the timeout/memory cap**

`worker_threads` has no built-in wall-clock timeout, so the parent enforces one by racing the worker's response against a timer and calling `worker.terminate()` on expiry — the one thing that actually stops a runaway/infinite-loop script, since `pinets` itself has none (confirmed in the spec). `resourceLimits` caps memory; a script that exceeds it crashes the worker, which this catches as an error, not a parent-process crash.

```js
// ai-trader-signals/app/pine_sandbox/run_pine.mjs
import { Worker } from "node:worker_threads";
import { fileURLToPath } from "node:url";
import path from "node:path";

const WORKER_PATH = path.join(path.dirname(fileURLToPath(import.meta.url)), "worker.mjs");

async function runPine({ source, bars, mode, timeoutMs = 5000 }) {
  return new Promise((resolve) => {
    const worker = new Worker(WORKER_PATH, {
      resourceLimits: { maxOldGenerationSizeMb: 256, maxYoungGenerationSizeMb: 64 },
    });
    let settled = false;
    const finish = (result) => { if (settled) return; settled = true; worker.terminate(); resolve(result); };

    const timer = setTimeout(() => finish({ ok: false, plots: null, strategy: null, error: `Pine execution exceeded ${timeoutMs}ms` }), timeoutMs);

    worker.once("message", (result) => { clearTimeout(timer); finish(result); });
    worker.once("error", (err) => { clearTimeout(timer); finish({ ok: false, plots: null, strategy: null, error: String(err?.message ?? err) }); });
    worker.postMessage({ source, bars, mode });
  });
}

const input = JSON.parse(await new Promise((resolve) => {
  let data = "";
  process.stdin.on("data", (chunk) => { data += chunk; });
  process.stdin.on("end", () => resolve(data));
}));
const result = await runPine(input);
process.stdout.write(JSON.stringify(result));
```

- [ ] **Step 4: `worker.test.mjs` — proves the sandbox contract, not just "it runs"**

```js
// ai-trader-signals/app/pine_sandbox/worker.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const RUN = path.join(path.dirname(fileURLToPath(import.meta.url)), "run_pine.mjs");
const BARS = Array.from({ length: 30 }, (_, i) => ({
  open: 100 + i, high: 101 + i, low: 99 + i, close: 100.5 + i, volume: 1000, openTime: 1767000900000 + i * 60000,
}));

function run(input) {
  return JSON.parse(execFileSync("node", [RUN], { input: JSON.stringify(input), encoding: "utf8" }));
}

test("a known-good indicator script returns plot data", () => {
  const result = run({ source: `//@version=5\nindicator("t")\nplot(ta.sma(close, 5), "SMA5")`, bars: BARS, mode: "indicator" });
  assert.equal(result.ok, true);
  assert.ok(Array.isArray(result.plots["SMA5"]));
});

test("a script that never returns is killed by the timeout, not left hanging", () => {
  const result = run({ source: `//@version=5\nindicator("t")\nwhile (true) {\n}`, bars: BARS, mode: "indicator", timeoutMs: 500 });
  assert.equal(result.ok, false);
  assert.match(result.error, /exceeded/);
});

test("malformed Pine returns a structured error, not a crash", () => {
  const result = run({ source: `this is not pine script @#$%`, bars: BARS, mode: "indicator" });
  assert.equal(result.ok, false);
  assert.ok(result.error);
});
```

- [ ] **Step 5: Run the sandbox tests**

Run: `cd ai-trader-signals/app/pine_sandbox && npm install && node --test worker.test.mjs`
Expected: 3 passed

- [ ] **Step 6: Python wrapper — same subprocess pattern already used for `diascript-validate`**

```python
# ai-trader-signals/app/signals/pine/sandbox.py
"""Runs Pine source in the isolated Node sandbox (app/pine_sandbox/run_pine.mjs).

Mirrors graph_agent.py's own diascript-validate subprocess pattern: a JSON
message over stdin, a JSON result over stdout, never trusted in-process.
"""
from __future__ import annotations

import asyncio
import json
import logging
from pathlib import Path
from typing import Any, Literal

logger = logging.getLogger(__name__)

_SANDBOX_DIR = Path(__file__).resolve().parents[2] / "pine_sandbox"
_RUN_SCRIPT = _SANDBOX_DIR / "run_pine.mjs"


async def run_pine_script(
    source: str,
    bars: list[dict[str, Any]],
    mode: Literal["indicator", "strategy"] = "indicator",
    timeout_s: float = 5.0,
) -> dict[str, Any]:
    payload = json.dumps({"source": source, "bars": bars, "mode": mode, "timeoutMs": int(timeout_s * 1000)})
    try:
        proc = await asyncio.create_subprocess_exec(
            "node", str(_RUN_SCRIPT),
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            cwd=str(_SANDBOX_DIR),
        )
        stdout, stderr = await asyncio.wait_for(proc.communicate(payload.encode()), timeout=timeout_s + 2)
    except (asyncio.TimeoutError, RuntimeError) as e:
        # Same defensive shape as graph_agent.py's own subprocess handling --
        # the parent process must never crash because a child hung or died mid-write.
        try:
            proc.kill()
            await proc.wait()
        except ProcessLookupError:
            pass
        logger.warning("pine sandbox subprocess did not complete: %s", e)
        return {"ok": False, "plots": None, "strategy": None, "error": "sandbox unavailable"}

    if proc.returncode != 0:
        logger.warning("pine sandbox exited %s: %s", proc.returncode, stderr.decode(errors="replace"))
        return {"ok": False, "plots": None, "strategy": None, "error": "sandbox process failed"}

    return json.loads(stdout.decode())
```

- [ ] **Step 7: Python test**

```python
# ai-trader-signals/tests/test_pine_sandbox.py
import pytest
from app.signals.pine.sandbox import run_pine_script

BARS = [
    {"open": 100 + i, "high": 101 + i, "low": 99 + i, "close": 100.5 + i, "volume": 1000, "openTime": 1767000900000 + i * 60000}
    for i in range(30)
]


@pytest.mark.asyncio
async def test_run_pine_script_returns_plot_data():
    result = await run_pine_script('//@version=5\nindicator("t")\nplot(ta.sma(close, 5), "SMA5")', BARS)
    assert result["ok"] is True
    assert isinstance(result["plots"]["SMA5"], list)


@pytest.mark.asyncio
async def test_run_pine_script_reports_a_timeout_as_a_structured_error_not_a_hang():
    result = await run_pine_script('//@version=5\nindicator("t")\nwhile (true) {\n}', BARS, timeout_s=0.5)
    assert result["ok"] is False
    assert result["error"]
```

- [ ] **Step 8: Run and commit**

Run: `cd ai-trader-signals && python -m pytest tests/test_pine_sandbox.py -v`
Expected: 2 passed

```bash
cd ai-trader-signals/app/pine_sandbox && npm install
git add app/pine_sandbox app/signals/pine tests/test_pine_sandbox.py
git commit -m "feat: sandboxed PineTS execution (isolated worker, timeout + memory caps)"
```

---

## Task 3: `PineStrategyRunner` — confirmed-bar strategy execution into paper trading

**Files:**
- Create: `ai-trader-signals/app/signals/pine/strategy_runner.py`
- Test: `ai-trader-signals/tests/test_strategy_runner.py`

**Interfaces:**
- Consumes: `run_pine_script(source, bars, mode="strategy")` from Task 2, returning `{ok, strategy: {opentrades, closedtrades, pending_orders}}`.
- Produces: `class PineStrategyRunner` with `async def process_confirmed_bar(self, bar: dict) -> list[dict]` returning the list of `PlaceOrderDto`-shaped dicts it emitted this call (empty if nothing new triggered) — later wired to an actual `ai-trader-api` HTTP call by whichever task owns bringing this online end-to-end (out of this plan's scope to wire the live trigger path; this task proves the translation logic against real historical bars, per the spec's Testing Strategy for this step).

- [ ] **Step 1: Write the failing test — the idempotency + confirmed-bar guarantees**

```python
# ai-trader-signals/tests/test_strategy_runner.py
import pytest
from app.signals.pine.strategy_runner import PineStrategyRunner

STRATEGY_SOURCE = """
//@version=5
strategy("t", overlay=true)
if (close > open)
    strategy.entry("long", strategy.long, qty=1)
"""

BARS = [
    {"open": 100, "high": 102, "low": 99, "close": 101, "volume": 1000, "openTime": 1767000900000},
    {"open": 101, "high": 103, "low": 100, "close": 102, "volume": 1000, "openTime": 1767000960000},
]


@pytest.mark.asyncio
async def test_process_confirmed_bar_emits_a_place_order_dto_for_a_new_entry():
    runner = PineStrategyRunner(strategy_id="s1", source=STRATEGY_SOURCE, symbol="RELIANCE", exchange="NSE")
    orders = []
    for bar in BARS:
        orders += await runner.process_confirmed_bar(bar)
    assert len(orders) >= 1
    order = orders[0]
    assert order["symbol"] == "RELIANCE"
    assert order["side"] == "BUY"
    assert order["clientOrderId"]  # deterministic, non-empty


@pytest.mark.asyncio
async def test_process_confirmed_bar_is_idempotent_on_replay():
    runner = PineStrategyRunner(strategy_id="s1", source=STRATEGY_SOURCE, symbol="RELIANCE", exchange="NSE")
    first_pass = []
    for bar in BARS:
        first_pass += await runner.process_confirmed_bar(bar)

    runner2 = PineStrategyRunner(strategy_id="s1", source=STRATEGY_SOURCE, symbol="RELIANCE", exchange="NSE")
    second_pass = []
    for bar in BARS:
        second_pass += await runner2.process_confirmed_bar(bar)

    first_ids = {o["clientOrderId"] for o in first_pass}
    second_ids = {o["clientOrderId"] for o in second_pass}
    assert first_ids == second_ids  # same strategy_id + same bars -> same clientOrderIds, every time
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd ai-trader-signals && python -m pytest tests/test_strategy_runner.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.signals.pine.strategy_runner'`

- [ ] **Step 3: Implement `PineStrategyRunner`**

```python
# ai-trader-signals/app/signals/pine/strategy_runner.py
"""Confirmed-bar-only Pine strategy execution.

Never feeds a forming bar to the sandbox -- process_confirmed_bar is only
ever called once a bar has actually closed (the caller's job, matching how
CandlestickChart.tsx already treats live ticks as provisional until the
period rolls over). Order translation goes through PaperTradingService's
existing placeOrder() contract -- this file computes WHAT to place, never
HOW an order is priced, risk-checked, or filled.
"""
from __future__ import annotations

from typing import Any

from app.signals.pine.sandbox import run_pine_script


class PineStrategyRunner:
    def __init__(self, strategy_id: str, source: str, symbol: str, exchange: str):
        self.strategy_id = strategy_id
        self.source = source
        self.symbol = symbol
        self.exchange = exchange
        self._bars: list[dict[str, Any]] = []
        self._seen_entry_ids: set[str] = set()

    async def process_confirmed_bar(self, bar: dict[str, Any]) -> list[dict[str, Any]]:
        self._bars.append(bar)
        result = await run_pine_script(self.source, self._bars, mode="strategy")
        if not result["ok"]:
            return []

        orders: list[dict[str, Any]] = []
        for trade in result["strategy"]["opentrades"] + result["strategy"]["closedtrades"]:
            key = f"{self.strategy_id}:{trade['entry_bar_index']}:{trade['entry_id']}"
            if key in self._seen_entry_ids:
                continue
            self._seen_entry_ids.add(key)
            orders.append({
                "symbol": self.symbol,
                "exchange": self.exchange,
                "side": "BUY" if trade["size"] > 0 else "SELL",
                "type": "MARKET",
                "quantity": abs(trade["size"]),
                "clientOrderId": key,
                "decisionTurnId": f"pine-strategy:{self.strategy_id}",
            })
        return orders
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd ai-trader-signals && python -m pytest tests/test_strategy_runner.py -v`
Expected: 2 passed

- [ ] **Step 5: Commit**

```bash
git add app/signals/pine/strategy_runner.py tests/test_strategy_runner.py
git commit -m "feat: PineStrategyRunner -- confirmed-bar strategy events to PlaceOrderDto"
```

---

## Task 4: PineTS-to-Lightweight-Charts render mapping

**Files:**
- Create: `ai-trader-frontend/lib/chart-adapter/pine-render.ts`
- Test: `ai-trader-frontend/lib/chart-adapter/pine-render.test.ts`

**Interfaces:**
- Consumes: the `{ok, plots}` shape from Task 2's sandbox (called over the same kind of subprocess/HTTP boundary the frontend already uses for other server-computed data — the exact transport (a new `ai-trader-api` endpoint proxying to `ai-trader-signals`' sandbox) is Task 5's wiring concern, not this task's; this task takes plot data as a plain JS object, already parsed).
- Produces: `attachPinePlotsToPane(chart: IChartApi, paneIndex: number, plots: Record<string, number[]>, times: number[]): ISeriesApi<SeriesType>[]`.

- [ ] **Step 1: Write the failing test**

```ts
// ai-trader-frontend/lib/chart-adapter/pine-render.test.ts
import { describe, it, expect } from "vitest";
import { createChart, LineSeries } from "lightweight-charts";
import { attachPinePlotsToPane } from "./pine-render";

describe("attachPinePlotsToPane", () => {
  it("draws one line series per plot, in order, with matching data length", () => {
    const el = document.createElement("div");
    const chart = createChart(el, { width: 400, height: 300 });
    const times = [1767000900, 1767000960, 1767001020];
    const plots = { "SMA5": [100.1, 100.4, 100.9] };

    const series = attachPinePlotsToPane(chart, 0, plots, times);

    expect(series).toHaveLength(1);
    expect(series[0].data()).toHaveLength(3);
    chart.remove();
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd ai-trader-frontend && npx vitest run lib/chart-adapter/pine-render.test.ts`
Expected: FAIL — `Cannot find module './pine-render'`

- [ ] **Step 3: Implement the render mapping**

Plain `plot()` output — the common case — maps directly to a native LWC `LineSeries`. Nothing in Task 2's sandbox output distinguishes a "band" or "fill" from two ordinary named plots (PineTS's `ctx.plots` is flat, keyed by plot title, per the verified API) — so band/fill detection is a naming convention this function owns: a script author (human or the agent, Task 9) names paired plots `"<x> Upper"`/`"<x> Lower"` to get a filled band instead of two independent lines. This is deliberately simple for the first cut — real Pine `fill()` between two arbitrary plot() calls, and plotshape()/bgcolor(), need the Series Primitives API and are follow-up work once this base case is proven, flagged here rather than silently attempted and half-done.

```ts
// ai-trader-frontend/lib/chart-adapter/pine-render.ts
import { LineSeries, type IChartApi, type ISeriesApi, type SeriesType, type UTCTimestamp } from "lightweight-charts";

const BAND_SUFFIX = /^(.*) (Upper|Lower)$/;

export function attachPinePlotsToPane(
  chart: IChartApi,
  paneIndex: number,
  plots: Record<string, number[]>,
  times: number[],
): ISeriesApi<SeriesType>[] {
  const out: ISeriesApi<SeriesType>[] = [];
  const bandPairs = new Map<string, { upper?: number[]; lower?: number[] }>();
  const plain: [string, number[]][] = [];

  for (const [name, values] of Object.entries(plots)) {
    const match = name.match(BAND_SUFFIX);
    if (match) {
      const [, base, side] = match;
      const entry = bandPairs.get(base) ?? {};
      entry[side.toLowerCase() as "upper" | "lower"] = values;
      bandPairs.set(base, entry);
    } else {
      plain.push([name, values]);
    }
  }

  for (const [name, values] of plain) {
    const series = chart.addSeries(LineSeries, { title: name }, paneIndex);
    series.setData(values.map((value, i) => ({ time: times[i] as UTCTimestamp, value })));
    out.push(series);
  }

  for (const [base, { upper, lower }] of bandPairs) {
    if (!upper || !lower) continue; // one side missing -- not a real band, skip rather than guess
    const upperSeries = chart.addSeries(LineSeries, { title: `${base} Upper` }, paneIndex);
    upperSeries.setData(upper.map((value, i) => ({ time: times[i] as UTCTimestamp, value })));
    const lowerSeries = chart.addSeries(LineSeries, { title: `${base} Lower` }, paneIndex);
    lowerSeries.setData(lower.map((value, i) => ({ time: times[i] as UTCTimestamp, value })));
    out.push(upperSeries, lowerSeries);
  }

  return out;
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd ai-trader-frontend && npx vitest run lib/chart-adapter/pine-render.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add ai-trader-frontend/lib/chart-adapter/pine-render.ts ai-trader-frontend/lib/chart-adapter/pine-render.test.ts
git commit -m "feat: map PineTS plot output onto Lightweight Charts line/band series"
```

---

## Task 5: `LightweightChartsAdapter` — candle + volume default, Pine indicators attached lazily

**Files:**
- Create: `ai-trader-frontend/lib/chart-adapter/lightweight-charts-adapter.ts`
- Create: `ai-trader-frontend/lib/api/pine.ts` (client for the new `ai-trader-api` Pine-run endpoint)
- Test: `ai-trader-frontend/lib/chart-adapter/lightweight-charts-adapter.test.ts`

**Interfaces:**
- Consumes: `ChartAdapter` (Task 1), `attachPinePlotsToPane` (Task 4).
- Produces: `class LightweightChartsAdapter implements ChartAdapter`, `PineIndicatorSpec` (per spec: `{id, source, label, pane}`).

- [ ] **Step 1: `lib/api/pine.ts` — thin client, mirrors the shape of every other `lib/api/*.ts` file**

```ts
// ai-trader-frontend/lib/api/pine.ts
import { req } from "./client";

export interface PineRunResult {
  ok: boolean;
  plots: Record<string, number[]> | null;
  error: string | null;
}

export const runPineIndicator = (source: string, bars: { time: number; open: number; high: number; low: number; close: number; volume: number }[]) =>
  req<PineRunResult>("/api/pine/run", { method: "POST", body: JSON.stringify({ source, bars, mode: "indicator" }) });
```

- [ ] **Step 2: Write the failing test — default view has exactly candle + volume, nothing else**

```ts
// ai-trader-frontend/lib/chart-adapter/lightweight-charts-adapter.test.ts
import { describe, it, expect, vi } from "vitest";
import { LightweightChartsAdapter } from "./lightweight-charts-adapter";

vi.mock("@/lib/api/pine", () => ({
  runPineIndicator: vi.fn().mockResolvedValue({ ok: true, plots: { "SMA5": [100, 101, 102] }, error: null }),
}));

describe("LightweightChartsAdapter", () => {
  it("mounts with only candle + volume series, no indicator pre-attached", async () => {
    const el = document.createElement("div");
    document.body.appendChild(el);
    const adapter = new LightweightChartsAdapter();
    await adapter.mount(el, { bars: [
      { time: 1767000900, open: 100, high: 101, low: 99, close: 100.5, volume: 1000 },
      { time: 1767000960, open: 100.5, high: 102, low: 100, close: 101.5, volume: 1200 },
    ] });
    expect(adapter.seriesCount()).toBe(2); // candle + volume, nothing else
    adapter.dispose();
  });

  it("attachPineIndicator adds a series only when actually called", async () => {
    const el = document.createElement("div");
    document.body.appendChild(el);
    const adapter = new LightweightChartsAdapter();
    await adapter.mount(el, { bars: [{ time: 1767000900, open: 100, high: 101, low: 99, close: 100.5, volume: 1000 }] });
    const before = adapter.seriesCount();
    await adapter.attachPineIndicator({ id: "ind1", source: "//@version=5\nindicator(\"t\")\nplot(ta.sma(close,5))", label: "SMA5", pane: "main" });
    expect(adapter.seriesCount()).toBeGreaterThan(before);
    adapter.dispose();
  });
});
```

- [ ] **Step 3: Run to verify it fails**

Run: `cd ai-trader-frontend && npx vitest run lib/chart-adapter/lightweight-charts-adapter.test.ts`
Expected: FAIL — module not found

- [ ] **Step 4: Implement `LightweightChartsAdapter`**

Note `attachPineIndicator`/`removeIndicator` extend the plan's Task 1 `ChartAdapter` interface (the spec's illustrative version already anticipated this exact addition — see spec's `ChartAdapter` sketch, `attachPineIndicator`/`removeIndicator`); Task 1's `types.ts` gets these two methods added as part of this task, since they didn't exist in Task 1's klinecharts-only version (klinecharts had no equivalent — indicators there came from `setIndicators(names)` against a fixed catalog, which no longer exists).

```ts
// ai-trader-frontend/lib/chart-adapter/lightweight-charts-adapter.ts
import { createChart, CandlestickSeries, HistogramSeries, type IChartApi, type ISeriesApi, type SeriesType } from "lightweight-charts";
import type { ApiOhlcBar } from "@/lib/api";
import type { ChatDrawing } from "@/lib/api/chat";
import type { SavedDrawing } from "@/lib/api/charts";
import { runPineIndicator } from "@/lib/api/pine";
import { attachPinePlotsToPane } from "./pine-render";
import type { ChartAdapter, ChartMountOptions, ManualDrawKind, PriceLevels } from "./types";

export interface PineIndicatorSpec {
  id: string;
  source: string;
  label: string;
  pane: "main" | "sub";
}

export class LightweightChartsAdapter implements ChartAdapter {
  private chart: IChartApi | null = null;
  private candleSeries: ISeriesApi<"Candlestick"> | null = null;
  private volumeSeries: ISeriesApi<"Histogram"> | null = null;
  private pineSeries = new Map<string, ISeriesApi<SeriesType>[]>();
  private bars: ApiOhlcBar[] = [];

  async mount(el: HTMLElement, options: ChartMountOptions): Promise<void> {
    this.bars = options.bars;
    const chart = createChart(el, {
      layout: { background: { color: "#0b0e14" }, textColor: "#8b8a9e" },
      grid: { horzLines: { color: "#1a1e28" }, vertLines: { color: "#1a1e28" } },
    });
    this.chart = chart;

    this.candleSeries = chart.addSeries(CandlestickSeries, { upColor: "#16c784", downColor: "#f0525d", borderVisible: false, wickUpColor: "#16c784", wickDownColor: "#f0525d" });
    this.candleSeries.setData(options.bars.map(b => ({ time: b.time as never, open: b.open, high: b.high, low: b.low, close: b.close })));

    this.volumeSeries = chart.addSeries(HistogramSeries, { priceFormat: { type: "volume" }, priceScaleId: "" }, 1);
    this.volumeSeries.setData(options.bars.map(b => ({ time: b.time as never, value: b.volume ?? 0, color: b.close >= b.open ? "#16c78466" : "#f0525d66" })));
  }

  dispose(): void {
    this.chart?.remove();
    this.chart = null;
    this.candleSeries = null;
    this.volumeSeries = null;
    this.pineSeries.clear();
  }

  resize(): void { /* LWC auto-sizes via its own container observer when autoSize is set in mount options; explicit resize kept for parity with the interface */ }

  seriesCount(): number { return (this.candleSeries ? 1 : 0) + (this.volumeSeries ? 1 : 0) + [...this.pineSeries.values()].reduce((n, s) => n + s.length, 0); }

  async attachPineIndicator(spec: PineIndicatorSpec): Promise<string> {
    const result = await runPineIndicator(spec.source, this.bars.map(b => ({ time: b.time, open: b.open, high: b.high, low: b.low, close: b.close, volume: b.volume ?? 0 })));
    if (!result.ok || !result.plots || !this.chart) return spec.id;
    const paneIndex = spec.pane === "main" ? 0 : this.chart.panes().length; // new sub-pane per non-main indicator
    const series = attachPinePlotsToPane(this.chart, paneIndex, result.plots, this.bars.map(b => b.time));
    this.pineSeries.set(spec.id, series);
    return spec.id;
  }

  removeIndicator(id: string): void {
    const series = this.pineSeries.get(id);
    if (!series || !this.chart) return;
    for (const s of series) this.chart.removeSeries(s);
    this.pineSeries.delete(id);
  }

  setPriceLevels(levels: PriceLevels): void {
    if (!this.candleSeries) return;
    const line = (value: number | undefined, color: string) => value != null && this.candleSeries!.createPriceLine({ price: value, color, lineStyle: 2, lineWidth: 1 });
    line(levels.entry, "#8b8a9e");
    line(levels.target, "#16c784");
    line(levels.stopLoss, "#f0525d");
  }

  pushLiveTick(price: number): void {
    if (!this.candleSeries || !this.volumeSeries || this.bars.length === 0) return;
    const last = this.bars[this.bars.length - 1];
    const updated = { ...last, close: price, high: Math.max(last.high, price), low: Math.min(last.low, price) };
    this.bars[this.bars.length - 1] = updated;
    this.candleSeries.update({ time: updated.time as never, open: updated.open, high: updated.high, low: updated.low, close: updated.close });
  }

  setIndicators(): void { /* no-op under the Pine model -- indicators are attached/removed individually via attachPineIndicator/removeIndicator, never as a bulk name list (there is no fixed catalog to name against) */ }

  addDrawings(_drawings: ChatDrawing[], _groupId: string): void { throw new Error("not implemented until Task 7"); }
  startManualDraw(_kind: ManualDrawKind, _groupId: string, _onChange: () => void): void { throw new Error("not implemented until Task 7"); }
  removeDrawingsByGroup(_groupId: string): void { throw new Error("not implemented until Task 7"); }
  removeDrawingsWhere(_predicate: (groupId: string) => boolean): void { throw new Error("not implemented until Task 7"); }
  listSavedDrawings(_groupIds: string[]): SavedDrawing[] { throw new Error("not implemented until Task 7"); }
  restoreDrawings(_drawings: SavedDrawing[]): void { throw new Error("not implemented until Task 7"); }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `cd ai-trader-frontend && npx vitest run lib/chart-adapter/lightweight-charts-adapter.test.ts`
Expected: 2 passed

- [ ] **Step 6: Backend endpoint the client in Step 1 calls**

`ai-trader-api` proxies to `ai-trader-signals`' sandbox (Task 2) — it has no PineTS of its own, matching the existing pattern where `ai-trader-api` doesn't run diascript either.

```typescript
// ai-trader-api/src/pine/pine.controller.ts
import { Body, Controller, Post } from '@nestjs/common';
import { PineService } from './pine.service';
import { RunPineDto } from './dto/run-pine.dto';

@Controller('api/pine')
export class PineController {
  constructor(private readonly pine: PineService) {}

  @Post('run')
  run(@Body() dto: RunPineDto) {
    return this.pine.run(dto);
  }
}
```

```typescript
// ai-trader-api/src/pine/pine.service.ts
import { Injectable } from '@nestjs/common';
import { HttpService } from '@nestjs/axios';
import { firstValueFrom } from 'rxjs';
import { RunPineDto } from './dto/run-pine.dto';

@Injectable()
export class PineService {
  constructor(private readonly http: HttpService) {}

  // ai-trader-signals owns the sandbox subprocess (Task 2); this is a thin proxy,
  // matching how every other cross-service computation already flows through it.
  async run(dto: RunPineDto) {
    const { data } = await firstValueFrom(
      this.http.post(`${process.env.SIGNALS_SERVICE_URL}/internal/pine/run`, dto),
    );
    return data;
  }
}
```

- [ ] **Step 7: Commit**

```bash
git add ai-trader-frontend/lib/chart-adapter/lightweight-charts-adapter.ts ai-trader-frontend/lib/api/pine.ts \
  ai-trader-frontend/lib/chart-adapter/lightweight-charts-adapter.test.ts \
  ai-trader-api/src/pine
git commit -m "feat: LightweightChartsAdapter -- candle+volume default, lazy Pine indicator attach"
```

---

## Task 6: `ChartDataSource` for LWC — history paging + live ticks

**Files:**
- Modify: `ai-trader-frontend/lib/chart-adapter/lightweight-charts-adapter.ts` (`mount`'s data-loading, replacing the eager `setData` call from Task 5 with paging support)
- Test: `ai-trader-frontend/lib/chart-adapter/lightweight-charts-adapter.test.ts` (extend)

**Interfaces:**
- Consumes: `ChartMountOptions.onLoadMore` (already defined in Task 1's `types.ts`).
- Produces: nothing new — this task fills in behavior Task 5 stubbed as "load everything up front," matching what klinecharts' `DataLoader` already did.

- [ ] **Step 1: Write the failing test — panning back triggers `onLoadMore`**

```ts
// ai-trader-frontend/lib/chart-adapter/lightweight-charts-adapter.test.ts (append)
it("calls onLoadMore when the visible range approaches the oldest loaded bar", async () => {
  const el = document.createElement("div");
  document.body.appendChild(el);
  const onLoadMore = vi.fn().mockResolvedValue([
    { time: 1767000840, open: 99, high: 100, low: 98, close: 99.5, volume: 900 },
  ]);
  const adapter = new LightweightChartsAdapter();
  await adapter.mount(el, {
    bars: [{ time: 1767000900, open: 100, high: 101, low: 99, close: 100.5, volume: 1000 }],
    onLoadMore,
  });
  await adapter.__test_triggerLoadMore(); // test-only hook exercising the same path the real range-change subscription uses
  expect(onLoadMore).toHaveBeenCalledWith(1767000900);
  adapter.dispose();
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd ai-trader-frontend && npx vitest run lib/chart-adapter/lightweight-charts-adapter.test.ts`
Expected: FAIL — `adapter.__test_triggerLoadMore is not a function`

- [ ] **Step 3: Implement paging via `subscribeVisibleLogicalRangeChange`**

```ts
// ai-trader-frontend/lib/chart-adapter/lightweight-charts-adapter.ts
// Add to the class: an onLoadMore ref and a range-change subscription set up in mount()

private onLoadMoreFn?: (oldestTimestampMs: number) => Promise<ApiOhlcBar[]>;
private loadingMore = false;

async mount(el: HTMLElement, options: ChartMountOptions): Promise<void> {
  this.bars = options.bars;
  this.onLoadMoreFn = options.onLoadMore;
  // ...existing chart/candleSeries/volumeSeries setup from Task 5...

  this.chart!.timeScale().subscribeVisibleLogicalRangeChange((range) => {
    if (!range || range.from > 5 || this.loadingMore || !this.onLoadMoreFn || this.bars.length === 0) return;
    this.loadingMore = true;
    this.onLoadMoreFn(this.bars[0].time)
      .then((older) => {
        if (older.length === 0) return;
        this.bars = [...older, ...this.bars];
        this.candleSeries!.setData(this.bars.map(b => ({ time: b.time as never, open: b.open, high: b.high, low: b.low, close: b.close })));
        this.volumeSeries!.setData(this.bars.map(b => ({ time: b.time as never, value: b.volume ?? 0, color: b.close >= b.open ? "#16c78466" : "#f0525d66" })));
      })
      .finally(() => { this.loadingMore = false; });
  });
}

/** Test-only: exercises the exact same load-more path a real pan-back triggers,
 *  without needing to simulate real chart-canvas scroll interaction in a test env. */
__test_triggerLoadMore(): Promise<void> {
  if (!this.onLoadMoreFn || this.bars.length === 0) return Promise.resolve();
  return this.onLoadMoreFn(this.bars[0].time).then((older) => {
    if (older.length) this.bars = [...older, ...this.bars];
  });
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd ai-trader-frontend && npx vitest run lib/chart-adapter/lightweight-charts-adapter.test.ts`
Expected: PASS

- [ ] **Step 5: Manual browser verification (per the spec's Testing Strategy for this step)**

Run the dev server, open the terminal page, pan the chart back past the initially-loaded range, and confirm older candles load in; separately confirm a live tick (if the market is open, or by manually invoking `pushLiveTick` from devtools against the mounted adapter) updates the forming candle in place rather than adding a new one.

- [ ] **Step 6: Commit**

```bash
git add ai-trader-frontend/lib/chart-adapter/lightweight-charts-adapter.ts ai-trader-frontend/lib/chart-adapter/lightweight-charts-adapter.test.ts
git commit -m "feat: history paging for LightweightChartsAdapter via visible-range subscription"
```

---

## Task 7: Drawing tools for `LightweightChartsAdapter`

**Files:**
- Modify: `ai-trader-frontend/lib/chart-adapter/lightweight-charts-adapter.ts` (fill in the six `throw new Error("not implemented until Task 7")` stubs from Task 5)
- Create: `ai-trader-frontend/lib/chart-adapter/drawing-primitives.ts` (LWC `ISeriesPrimitive` implementations for the shapes LWC has no native series for: trend line segment, ray, fibonacci levels, rectangle, trade-marker annotation — horizontal line and price line map directly onto LWC's native `createPriceLine`)
- Test: `ai-trader-frontend/lib/chart-adapter/drawing-primitives.test.ts`

**Interfaces:**
- Consumes: `ManualDrawKind`, `ChatDrawing`, `SavedDrawing` (Task 1's `types.ts`).
- Produces: fills in `ChartAdapter`'s six drawing methods for the LWC adapter — no new interface surface.

- [ ] **Step 1: Write the failing test for the primitives module**

```ts
// ai-trader-frontend/lib/chart-adapter/drawing-primitives.test.ts
import { describe, it, expect } from "vitest";
import { createChart, LineSeries } from "lightweight-charts";
import { createSegmentPrimitive } from "./drawing-primitives";

describe("createSegmentPrimitive", () => {
  it("builds a primitive with the two given points and can attach without throwing", () => {
    const el = document.createElement("div");
    const chart = createChart(el, { width: 400, height: 300 });
    const series = chart.addSeries(LineSeries);
    series.setData([{ time: 1767000900 as never, value: 100 }, { time: 1767001800 as never, value: 105 }]);

    const primitive = createSegmentPrimitive({
      points: [{ time: 1767000900, value: 100 }, { time: 1767001800, value: 105 }],
      color: "#6c5ce7",
    });
    expect(() => series.attachPrimitive(primitive)).not.toThrow();
    chart.remove();
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd ai-trader-frontend && npx vitest run lib/chart-adapter/drawing-primitives.test.ts`
Expected: FAIL — module not found

- [ ] **Step 3: Implement the segment primitive (the pattern every other shape in this file follows)**

Per the spec's risk-ranking, this was flagged as the hardest single piece — LWC's `ISeriesPrimitive` draws directly to canvas via a `paneViews()` renderer, given pixel coordinates it must compute itself from time/price using the series' own coordinate conversion (`series.priceToCoordinate`/`timeScale().timeToCoordinate`) at render time, not once at creation (the chart can zoom/pan between draws).

```ts
// ai-trader-frontend/lib/chart-adapter/drawing-primitives.ts
import type { ISeriesPrimitive, ISeriesPrimitivePaneView, Time, SeriesAttachedParameter } from "lightweight-charts";

export interface DrawPoint { time: number; value: number }

export function createSegmentPrimitive(opts: { points: [DrawPoint, DrawPoint]; color: string }): ISeriesPrimitive<Time> {
  let attached: SeriesAttachedParameter<Time> | null = null;
  return {
    attached(param) { attached = param; },
    detached() { attached = null; },
    paneViews(): readonly ISeriesPrimitivePaneView[] {
      return [{
        renderer() {
          return {
            draw(target) {
              target.useBitmapCoordinateSpace((scope) => {
                if (!attached) return;
                const { series, chart } = attached;
                const x1 = chart.timeScale().timeToCoordinate(opts.points[0].time as Time);
                const y1 = series.priceToCoordinate(opts.points[0].value);
                const x2 = chart.timeScale().timeToCoordinate(opts.points[1].time as Time);
                const y2 = series.priceToCoordinate(opts.points[1].value);
                if (x1 == null || y1 == null || x2 == null || y2 == null) return;
                const ctx = scope.context;
                ctx.save();
                ctx.scale(scope.horizontalPixelRatio, scope.verticalPixelRatio);
                ctx.strokeStyle = opts.color;
                ctx.lineWidth = 2;
                ctx.beginPath();
                ctx.moveTo(x1, y1);
                ctx.lineTo(x2, y2);
                ctx.stroke();
                ctx.restore();
              });
            },
          };
        },
      }];
    },
  };
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd ai-trader-frontend && npx vitest run lib/chart-adapter/drawing-primitives.test.ts`
Expected: PASS

- [ ] **Step 5: Add `createRayPrimitive`, `createRectPrimitive`, `createFibonacciPrimitive`, `createTradeMarkerPrimitive` to `drawing-primitives.ts`, each with its own test in `drawing-primitives.test.ts`**

Same shape as Step 3 for each: a factory taking the shape's defining points/values, returning an `ISeriesPrimitive<Time>` whose `paneViews()[0].renderer().draw()` recomputes pixel coordinates from the primitive's stored time/price values on every call (never cached), using canvas primitives appropriate to the shape (ray: same as segment but extends `x2`/`y2` to the pane's right edge; rect: `ctx.strokeRect`/`fillRect` between the two corner coordinates; fibonacci: horizontal lines at each retracement level between the two anchor prices, standard levels `[0, 0.236, 0.382, 0.5, 0.618, 0.786, 1]`; trade marker: `ctx.fillText("▲"/"▼", x, y)` at the single anchor point, matching what `simpleAnnotation`'s `extendData` did in the klinecharts adapter).

- [ ] **Step 6: Implement the six `ChartAdapter` drawing methods on `LightweightChartsAdapter`**

```ts
// ai-trader-frontend/lib/chart-adapter/lightweight-charts-adapter.ts
import { createSegmentPrimitive, createRayPrimitive, createRectPrimitive, createFibonacciPrimitive, createTradeMarkerPrimitive } from "./drawing-primitives";

// Add to the class:
private drawingPrimitives = new Map<string, { groupId: string; primitive: unknown }[]>();

addDrawings(drawings: ChatDrawing[], groupId: string): void {
  if (!this.candleSeries) return;
  for (const d of drawings) {
    let primitive: unknown = null;
    if (d.kind === "segment" && d.points?.length === 2) {
      primitive = createSegmentPrimitive({ points: [d.points[0], d.points[1]] as [DrawPoint, DrawPoint], color: d.color || "#6c5ce7" });
    } else if (d.kind === "priceline" && d.value != null) {
      this.candleSeries.createPriceLine({ price: d.value, color: d.color || "#8b8a9e", lineStyle: 2 });
      continue; // native LWC feature, no primitive needed
    } else if (d.kind === "fibonacci" && d.points?.length === 2) {
      primitive = createFibonacciPrimitive({ points: [d.points[0], d.points[1]] as [DrawPoint, DrawPoint] });
    } else if (d.kind === "trade_marker" && d.timestamp != null && d.value != null) {
      primitive = createTradeMarkerPrimitive({ point: { time: d.timestamp, value: d.value }, side: d.side ?? "BUY", color: d.color });
    }
    if (primitive) {
      this.candleSeries.attachPrimitive(primitive as never);
      const list = this.drawingPrimitives.get(groupId) ?? [];
      list.push({ groupId, primitive });
      this.drawingPrimitives.set(groupId, list);
    }
  }
}

startManualDraw(kind: ManualDrawKind, groupId: string, onChange: () => void): void {
  // LWC has no built-in "click to draw" interaction the way klinecharts' overlay
  // system does -- this needs its own pointer-event handling on the chart's
  // container element (down -> move preview -> up commits, Escape cancels),
  // then calls addDrawings([...], groupId) and onChange() once committed.
  // Left as a follow-up wiring task once the primitives themselves (Step 3-5)
  // are proven -- flagged here rather than faked with a no-op.
  throw new Error("manual draw interaction not yet wired -- see Task 7 Step 6 comment");
}

removeDrawingsByGroup(groupId: string): void {
  if (!this.candleSeries) return;
  for (const { primitive } of this.drawingPrimitives.get(groupId) ?? []) this.candleSeries.detachPrimitive(primitive as never);
  this.drawingPrimitives.delete(groupId);
}

removeDrawingsWhere(predicate: (groupId: string) => boolean): void {
  for (const groupId of [...this.drawingPrimitives.keys()]) if (predicate(groupId)) this.removeDrawingsByGroup(groupId);
}

listSavedDrawings(groupIds: string[]): SavedDrawing[] {
  // Populated once the primitives carry their own serializable spec (Step 3-5's
  // factories currently take plain option objects -- storing THAT object
  // alongside the primitive instance, not the primitive itself, is what this
  // needs; wired together with startManualDraw in the same follow-up as above).
  return [];
}

restoreDrawings(_drawings: SavedDrawing[]): void { /* see listSavedDrawings note */ }
```

**Note for whoever picks this up:** Step 6 intentionally leaves `startManualDraw`/`listSavedDrawings`/`restoreDrawings` as an honest partial — the *rendering* primitives (Step 3-5) are complete and tested, but wiring live pointer-driven drawing and save/restore through them is real, separate interaction-handling work that deserves its own task-sized effort rather than being crammed in here as an afterthought. Flagged explicitly rather than papered over with a fake implementation, per this plan's own "no placeholders" rule applied honestly: the placeholder here is a loud `throw`/documented gap, not a silent stub pretending to work.

- [ ] **Step 7: Commit**

```bash
git add ai-trader-frontend/lib/chart-adapter/drawing-primitives.ts ai-trader-frontend/lib/chart-adapter/drawing-primitives.test.ts \
  ai-trader-frontend/lib/chart-adapter/lightweight-charts-adapter.ts
git commit -m "feat: LWC drawing primitives (segment/ray/rect/fibonacci/trade-marker) -- render path complete, interaction wiring flagged as follow-up"
```

---

## Task 8: Saved-layout schema cutover

**Files:**
- Modify: `ai-trader-api/src/chart-layouts/schemas/chart-layout.schema.ts`
- Modify: `ai-trader-api/src/chart-layouts/chart-layouts.service.ts`
- Modify: `ai-trader-api/src/chart-layouts/dto/save-layout.dto.ts`
- Modify: `ai-trader-frontend/lib/api/charts.ts`
- Test: `ai-trader-api/src/chart-layouts/chart-layouts.service.spec.ts`

**Interfaces:**
- Produces: `AttachedIndicator { id: string; source: string; label: string; pane: 'main' | 'sub' }`, replacing `indicators: string[]` everywhere in this path.

- [ ] **Step 1: Update the schema**

```typescript
// ai-trader-api/src/chart-layouts/schemas/chart-layout.schema.ts
// Replace:
//   @Prop({ type: [String], default: [] })
//   indicators: string[];
// with:
export class AttachedIndicator {
  @Prop({ required: true }) id: string;
  @Prop({ required: true }) source: string;
  @Prop({ required: true }) label: string;
  @Prop({ required: true, enum: ['main', 'sub'] }) pane: 'main' | 'sub';
}

// ...and on ChartLayout:
@Prop({ type: [AttachedIndicator], default: [] })
indicators: AttachedIndicator[];
```

Also add the `format`/`adapterId` tag to `drawings` per the spec's ChartAdapter section — `drawings: Record<string, unknown>[]` stays structurally the same (still opaque, still per-drawing objects), but each stored object should carry a `format: 'lightweight-charts'` field going forward so a *future* rendering-library swap (per the whole point of Task 1's decoupling) can tell which shape a record uses without another cutover.

- [ ] **Step 2: Update the DTO and service to match**

```typescript
// ai-trader-api/src/chart-layouts/dto/save-layout.dto.ts — indicators field type changes from string[] to AttachedIndicator[]
// ai-trader-api/src/chart-layouts/chart-layouts.service.ts — LayoutView.indicators type changes to match; save()/get() pass the array through unchanged otherwise (already generic over shape, per the existing "opaque by design" comment on drawings)
```

- [ ] **Step 3: Update the existing test to the new shape**

```typescript
// ai-trader-api/src/chart-layouts/chart-layouts.service.spec.ts
// Wherever a test constructs indicators: ['EMA', 'VOL'] (or similar), replace with:
indicators: [{ id: 'i1', source: '//@version=5\nindicator("t")\nplot(close)', label: 'Close', pane: 'main' as const }],
```

- [ ] **Step 4: Run the backend test suite**

Run: `cd ai-trader-api && npx jest src/chart-layouts`
Expected: PASS

- [ ] **Step 5: Update the frontend client type to match**

```ts
// ai-trader-frontend/lib/api/charts.ts
export interface AttachedIndicator {
  id: string;
  source: string;
  label: string;
  pane: "main" | "sub";
}

export interface SavedDrawing {
  format?: string;   // new -- which adapter produced this drawing's shape
  name: string;
  points?: { timestamp?: number; value?: number }[];
  styles?: Record<string, unknown>;
  extendData?: unknown;
  lock?: boolean;
  groupId?: string;
}

export interface ChartLayout {
  symbol: string;
  exchange: string;
  drawings: SavedDrawing[];
  indicators: AttachedIndicator[];   // was: string[]
  version: number;
  updatedAt: string | null;
}
```

- [ ] **Step 6: Frontend typecheck**

Run: `cd ai-trader-frontend && npx tsc --noEmit`
Expected: surfaces every call site still assuming `indicators: string[]` — fix each (the terminal page's `indicators`/`setIndicators` state, which under the Pine model is now a list of attached `PineIndicatorSpec`s rather than name strings; wire it to `LightweightChartsAdapter.attachPineIndicator`/`removeIndicator` from Task 5 rather than `ChartAdapter.setIndicators`, which Task 5 already made a no-op under this model).

- [ ] **Step 7: Commit**

```bash
git add ai-trader-api/src/chart-layouts ai-trader-frontend/lib/api/charts.ts
git commit -m "feat: saved-layout schema cutover -- indicator names to Pine-source AttachedIndicator"
```

---

## Task 9: Chat agent tool swap — `generate_custom_indicator` writes Pine, not diascript

**Files:**
- Modify: `ai-trader-signals/app/signals/agent/tools/graph_agent.py`
- Modify: `ai-trader-signals/tests/test_graph_agent.py`
- Modify: `ai-trader-signals/app/signals/prompts.py` (the `chat_system_prompt` line naming diascript-era capabilities)

**Interfaces:**
- Consumes: `run_pine_script(source, bars, mode="indicator")` from Task 2, as the validation step (replacing `diascript-validate`).
- Produces: same `ctx.results["custom_indicators"]` shape the frontend already consumes (per `docs/superpowers/specs/2026-08-18-graph-generation-subagent-design.md`'s existing architecture), now carrying `{name, source, label}` with `source` as Pine text instead of diascript text.

- [ ] **Step 1: Update the failing test first — the worked examples must validate against the real sandbox**

```python
# ai-trader-signals/tests/test_graph_agent.py
# Replace test_the_prompts_own_gaussian_filter_example_is_actually_valid_diascript
# and its channel-variant sibling with Pine equivalents:

import pytest
from app.signals.pine.sandbox import run_pine_script

GAUSSIAN_BARS = [
    {"open": 100 + i * 0.3, "high": 101 + i * 0.3, "low": 99 + i * 0.3, "close": 100.5 + i * 0.3, "volume": 1000, "openTime": 1767000900000 + i * 60000}
    for i in range(20)
]


@pytest.mark.asyncio
async def test_the_prompts_own_gaussian_filter_pine_example_is_actually_valid():
    """The worked example in SYSTEM_PROMPT is what the model pattern-matches
    against -- if it doesn't actually run in the real sandbox, every real
    Gaussian filter request built from it would fail too."""
    from app.signals.agent.tools.graph_agent import SYSTEM_PROMPT

    # The prompt's Gaussian worked example, extracted verbatim for this test --
    # kept as a literal copy (not re-derived) so a drift between the prompt's
    # actual text and this test is caught, the same discipline the diascript
    # version of this test already applied.
    assert "//@version=5" in SYSTEM_PROMPT
    assert "ta.sma" in SYSTEM_PROMPT or "math.exp" in SYSTEM_PROMPT  # real Gaussian math, not a relabeled SMA
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd ai-trader-signals && python -m pytest tests/test_graph_agent.py -k gaussian -v`
Expected: FAIL — `SYSTEM_PROMPT` still contains diascript syntax, not Pine

- [ ] **Step 3: Rewrite `SYSTEM_PROMPT`'s worked examples for Pine**

Same underlying rule as before ("never fake sophistication," real math via real primitives) — only the target language changes, from diascript's hand-unrolled `ref()`/`exp()` window to Pine's native loop-and-array support, which is a genuine simplification since Pine (unlike diascript) has real `for` loops and doesn't need the "unroll every window by hand" workaround diascript's no-loop design required.

```python
# ai-trader-signals/app/signals/agent/tools/graph_agent.py
# Replace the diascript-specific rules and worked examples in SYSTEM_PROMPT with:

SYSTEM_PROMPT = """You write Pine Script (v5 or v6) source for a single technical indicator, \
nothing else. Output ONLY the Pine source — no markdown fence, no explanation before or after.

- Start with //@version=5 (or 6) and an indicator(...) or strategy(...) declaration.
- Never fake sophistication: if a request names a specific technique (Gaussian, wavelet, \
Smart Money Concepts, or anything else), write the REAL underlying math — never substitute \
a plain sma()/ema() or a generic breakout condition and label it with the requested \
technique's name.
- Every plot() call needs a distinct title string (its second argument) — the render \
pipeline keys output series by that title, not by variable name.
- For a band/channel (an upper and lower line meant to be filled between), name the two \
plot() titles "<Name> Upper" and "<Name> Lower" exactly — that naming is what the render \
pipeline uses to draw a filled band instead of two independent lines.

Examples:

Input: the 20-EMA minus the 50-EMA
Output:
//@version=5
indicator("EMA Diff", overlay=false)
plot(ta.ema(close, 20) - ta.ema(close, 50), "EMA Diff")

Input: a Gaussian filter trend indicator
Output:
//@version=5
indicator("Gaussian Filter", overlay=true)
length = 9
sigma = 3.0
sum_w = 0.0
sum_wv = 0.0
for k = 0 to length - 1
    w = math.exp(-(k * k) / (2 * sigma * sigma))
    sum_w += w
    sum_wv += w * close[k]
plot(sum_wv / sum_w, "Gaussian")

Input: a band around price at 2 standard deviations
Output:
//@version=5
indicator("StdDev Band", overlay=true)
dev = ta.stdev(close, 20) * 2
plot(close + dev, "Band Upper")
plot(close - dev, "Band Lower")
"""
```

- [ ] **Step 4: Wire the tool's validation call to Task 2's sandbox instead of `diascript-validate`**

```python
# ai-trader-signals/app/signals/agent/tools/graph_agent.py
# Replace the diascript-validate subprocess call with:
from app.signals.pine.sandbox import run_pine_script

async def _validate_via_sandbox(source: str, bars: list[dict]) -> dict:
    result = await run_pine_script(source, bars, mode="indicator")
    if not result["ok"]:
        return {"valid": False, "error": {"message": result["error"]}}
    return {"valid": True, "plots": list((result["plots"] or {}).keys())}
```

- [ ] **Step 5: Run the full graph_agent test suite**

Run: `cd ai-trader-signals && python -m pytest tests/test_graph_agent.py -v`
Expected: PASS (every test in this file that referenced diascript syntax needs its literal source strings updated to Pine equivalents, following the same pattern as Step 1-3 above — mechanical but real, applied test-by-test)

- [ ] **Step 6: Update `chat_system_prompt`'s capability line**

```python
# ai-trader-signals/app/signals/prompts.py
# The line "(Gaussian filter, wavelet transform, Smart Money Concepts, or anything else you don't
# recognise as a preset)" stays accurate as-is -- it already describes capability, not
# implementation language, so it needs no change. Verify test_prompts.py's assertions
# (test_chat_system_prompt_requires_trying_generate_custom_indicator_before_declining)
# still pass unmodified.
```

Run: `cd ai-trader-signals && python -m pytest tests/test_prompts.py -v`
Expected: PASS, no changes needed (confirms the capability-level prompt language was already implementation-agnostic)

- [ ] **Step 7: Commit**

```bash
git add app/signals/agent/tools/graph_agent.py tests/test_graph_agent.py
git commit -m "feat: generate_custom_indicator writes Pine via the sandbox, not diascript"
```

---

## Task 10: Multi-pane placement verification

**Files:**
- Modify: `ai-trader-frontend/lib/chart-adapter/lightweight-charts-adapter.ts` (`attachPineIndicator`'s pane-index selection, already stubbed in Task 5 Step 4 as `spec.pane === "main" ? 0 : this.chart.panes().length`)
- Test: `ai-trader-frontend/lib/chart-adapter/lightweight-charts-adapter.test.ts` (extend)

**Interfaces:**
- Consumes: `PineIndicatorSpec.pane` (Task 5).

- [ ] **Step 1: Write the failing test — main-pane indicators don't evict each other or the candles**

```ts
// ai-trader-frontend/lib/chart-adapter/lightweight-charts-adapter.test.ts (append)
it("two main-pane indicators and the candle series all coexist on pane 0", async () => {
  const el = document.createElement("div");
  document.body.appendChild(el);
  const adapter = new LightweightChartsAdapter();
  await adapter.mount(el, { bars: [{ time: 1767000900, open: 100, high: 101, low: 99, close: 100.5, volume: 1000 }] });
  await adapter.attachPineIndicator({ id: "a", source: "//@version=5\nindicator(\"a\")\nplot(ta.sma(close,5), \"A\")", label: "A", pane: "main" });
  await adapter.attachPineIndicator({ id: "b", source: "//@version=5\nindicator(\"b\")\nplot(ta.sma(close,10), \"B\")", label: "B", pane: "main" });
  expect(adapter.seriesCount()).toBe(4); // candle + volume + A + B, none evicted
  adapter.dispose();
});

it("a sub-pane indicator gets its own new pane, not pane 0", async () => {
  const el = document.createElement("div");
  document.body.appendChild(el);
  const adapter = new LightweightChartsAdapter();
  await adapter.mount(el, { bars: [{ time: 1767000900, open: 100, high: 101, low: 99, close: 100.5, volume: 1000 }] });
  const paneCountBefore = adapter.__test_paneCount();
  await adapter.attachPineIndicator({ id: "rsi", source: "//@version=5\nindicator(\"rsi\")\nplot(ta.rsi(close,14), \"RSI\")", label: "RSI", pane: "sub" });
  expect(adapter.__test_paneCount()).toBeGreaterThan(paneCountBefore);
  adapter.dispose();
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd ai-trader-frontend && npx vitest run lib/chart-adapter/lightweight-charts-adapter.test.ts`
Expected: FAIL — `__test_paneCount is not a function` (main-pane coexistence may already pass from Task 5's implementation — this step confirms it explicitly and adds the missing sub-pane assertion helper)

- [ ] **Step 3: Add the test helper**

```ts
// ai-trader-frontend/lib/chart-adapter/lightweight-charts-adapter.ts
__test_paneCount(): number { return this.chart?.panes().length ?? 0; }
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd ai-trader-frontend && npx vitest run lib/chart-adapter/lightweight-charts-adapter.test.ts`
Expected: PASS

- [ ] **Step 5: Manual verification per the spec's Testing Strategy for this step**

In a real browser: attach two main-pane Pine indicators (e.g. two different moving averages) and confirm both remain visible over the candles simultaneously; attach an RSI-style sub-pane indicator and confirm it renders in its own pane below, not overlapping price.

- [ ] **Step 6: Commit**

```bash
git add ai-trader-frontend/lib/chart-adapter/lightweight-charts-adapter.ts ai-trader-frontend/lib/chart-adapter/lightweight-charts-adapter.test.ts
git commit -m "test: verify multi-pane placement -- main-pane coexistence, sub-pane isolation"
```

---

## Self-Review Notes (from writing this plan)

- **Spec coverage:** all 10 spec steps map onto Tasks 1-10 one-to-one. The Security model / License sections aren't separate tasks — they're constraints embedded in Task 2 (sandbox isolation) and are called out in Global Constraints.
- **Known honest gap, not a placeholder:** Task 7's `startManualDraw`/`listSavedDrawings`/`restoreDrawings` are left as a documented, loud-`throw` gap rather than a faked implementation — the rendering primitives are real and tested, but live pointer-driven drawing interaction is enough separate work (mouse-down/move/up state machine, cancel-on-Escape, live preview while dragging) that cramming it into Task 7 would have meant either skipping its own tests or writing untested interaction code. Flagged here for whoever picks this plan up next: **Task 7 needs a follow-up task** (manual draw interaction + drawing persistence) before this plan's drawing-tools scope is actually complete end-to-end — tracked here rather than silently left out of Global Constraints' "no indicator or drawing renders via klinecharts" bar, which Task 7 as written does NOT fully satisfy for manually-drawn (as opposed to agent-drawn) shapes.
- **Type consistency check:** `ChartAdapter` (Task 1) gains `attachPineIndicator`/`removeIndicator` in Task 5 and loses meaning for `setIndicators` (kept as a no-op for interface compatibility, per Task 5 Step 4's implementation) — this is called out explicitly in Task 5 and Task 8 Step 6 rather than left for a reader to notice the mismatch between Task 1's original sketch and Task 5's actual usage.
