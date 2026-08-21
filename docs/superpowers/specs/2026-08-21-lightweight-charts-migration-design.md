# Lightweight Charts + PineTS Migration — Design

**Status:** Revised by user, 2026-08-21, superseding the two-sub-project version of this spec. Original framing kept diascript and added PineTS alongside it for human-authored Pine import only. **New direction: diascript is retired entirely.** PineTS becomes the one indicator engine — for both user-pasted Pine and agent-generated Pine. This is one project now, not two: Lightweight Charts has no indicator math of its own (confirmed — see "Why diascript can't just be ported" below), so the chart-library swap and the indicator-engine swap are the same effort.

**Platform context stated by the user:** single-user platform for now. That is the basis for accepting agent-generated Pine execution (not just curated/human-authored) as in-scope from day one — noted explicitly here because it's a real risk trade-off, not a default, and it should be revisited before this ever becomes multi-tenant (see "Security model" below).

## Goal

Replace klinecharts (rendering) **and** diascript (indicator engine) with:
- **Lightweight Charts** (`lightweight-charts`, already installed at `5.2.0`, Apache-2.0) for rendering — candles and volume only, natively, no calc engine needed for either.
- **PineTS** for everything else — any indicator beyond candle+volume runs as real Pine Script, executed in a sandbox, attached lazily (only when actually asked for, never a pre-populated catalog).

**Not in scope (still deferred, unaffected by this revision):**
- Pine `strategy.*` order execution / paper-trading fills — still a later phase; this spec covers indicator rendering only. (Revisit: the original PineTS sub-project scoped indicators+strategy together — confirm with user whether strategy execution rides along with this effort or stays a follow-up, before Task work starts on it.)
- Any change to paper-trading logic, signal generation, or the chat agent's tool surface beyond swapping `generate_custom_indicator`'s output language.

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

replacing the current `indicators: string[]` field. This is a breaking schema change to real stored data (same category as the drawings-format migration already planned) — existing saved layouts' `indicators` arrays (just names like `["EMA", "VOL"]`) have no Pine source to migrate *to*, since those names pointed at calc engines that no longer exist. The honest migration is: **drop stored indicator names on migration, keep drawings.** A user's trend lines and saved marks carry forward; their indicator toggles reset to the new default (candle+volume) and get re-added if they want them. This needs to be said to the user plainly at migration time, not silently done — flagged as a decision to confirm, not assumed here.

## Current state (unchanged from the prior scan, still accurate)

**Core component:** `components/CandlestickChart.tsx` (424 lines), mounted at two sites (`app/dashboard/terminal/page.tsx`, `app/page.tsx`). Owns klinecharts `init()`, `setStyles()`, `setSymbol`/`setPeriod`, `setDataLoader` (pull-based history + live-bar push), three locked `priceLine` overlays for AI signal entry/target/stop, incremental `createIndicator`/`removeIndicator` (with an `isStack: true` gotcha), `ResizeObserver`, live-tick mutation.

**Drawing tools:** `ChatDrawing` (`segment`/`priceline`/`fibonacci`/`trade_marker`/`series`) and manual `DrawingToolbar` (`segment`/`rayLine`/`horizontalStraightLine`/`fibonacciLine`/`rect`) both resolve to klinecharts overlay names via `chart.createOverlay(...)`, in `applyDrawings()` (`terminal/page.tsx:255-295`) and `pickTool()` (`terminal/page.tsx:201-212`). Saved via `use-chart-layout.ts`'s `save()`/restore effect, reading/writing `chart.getOverlays({groupId})` in klinecharts' own shape.

**Live ticks:** `use-live-quote.ts`'s Socket.IO singleton → `livePrice` prop → `CandlestickChart.tsx` mutates the in-memory last bar and re-invokes the `DataLoader`'s `subscribeBar` callback.

**Paper trading markers:** confirmed absent today — unrelated to this migration.

## Risk-ranked pieces

1. **PineTS sandbox** (highest risk, new). Isolated worker/subprocess, resource-capped, structured-clone boundary. This is real infrastructure, not a config flag — get this wrong and "agent-generated Pine" is an open RCE path, not a bounded one.
2. **PineTS → LWC rendering.** Pine's `plot()`/`plotshape()`/`hline()`/`fill()`/`bgcolor()` surface is wider than LWC's native series types — bands, markers, background shading, and fills need LWC's Series Primitives API (`ISeriesPrimitive`, confirmed present in the installed package's types) written from scratch. No adapter exists anywhere for this yet (diascript's klinecharts adapter is not reusable — it read klinecharts-computed pixel coordinates, a different problem).
3. **Drawing tools + saved-layout migration**, including the new indicator-schema change above — real stored user data, needs a stated (not silent) migration decision.
4. **`DataLoader` → LWC's data model.** History paging + live ticks, mechanical but touches a path that's easy to silently break.
5. **Multi-pane placement.** Mechanical, lowest risk.

## Sequenced approach

1. **Extract `ChartAdapter`, klinecharts implementation behind it.** Pure refactor, zero behavior change — unchanged from the prior revision. Ships the decoupling before either the rendering-library or the indicator-engine swap touches anything.
2. **PineTS sandbox**, built and tested standalone, independent of the chart: given Pine source + OHLCV bars, returns plot data or a structured error, inside an isolated worker/subprocess with resource caps and no DB/credential/filesystem/network access. This has to work and be trusted on its own before anything downstream depends on it.
3. **PineTS-to-LWC render mapping**: the primitives for band/marker/background/fill, plus the direct cases (`plot()` → line/histogram series). Tested against known Pine scripts with known expected output (e.g. a plain EMA script), not just "it runs without throwing."
4. **New `LightweightChartsAdapter`** implementing `ChartAdapter`: candle + volume as native series (default view), `attachPineIndicator()` wired to Steps 2+3, at both mount sites.
5. **`ChartDataSource` for LWC**: history paging + live-tick path. Manual browser check specifically (same reasoning as before — easy to silently break).
6. **Drawing tools**, rebuilt against LWC primitives — same seven overlay kinds as before, this part is unaffected by the diascript/PineTS change.
7. **Saved-layout migration**: both the drawings-format change (klinecharts-shaped → LWC-native, `format`/`adapterId`-tagged) and the new `indicators: AttachedIndicator[]` schema replacing `indicators: string[]`, with the drop-and-reset decision from "Saved-layout schema change" confirmed with the user before the migration script runs for real. Spans `ai-trader-frontend` and `ai-trader-api`'s `chart-layouts` module.
8. **Chat agent tool swap**: `generate_custom_indicator` (`ai-trader-signals/app/signals/agent/tools/graph_agent.py`) stops writing diascript and starts writing Pine — same "write, validate, one retry on a real error, hand a validated result to the frontend" shape, new target language. Its existing worked-examples-in-the-prompt pattern (Gaussian filter, wavelet, SMC) needs re-authoring for Pine syntax; the underlying "never fake sophistication" rule carries over unchanged.
9. **Multi-pane placement**, last, lowest risk.

## Decisions made in this spec (flagged for user check)

- **Diascript retired**, not archived-but-kept. If this turns out wrong, its code still exists at the `devrunch/diascript` git history and this session's chat log — recoverable, but the plan should not carry dead-code maintenance for it.
- **Saved indicator names are dropped, not migrated**, on the saved-layout migration (see above) — needs explicit user confirmation before that migration script runs for real, not just an implementation-time assumption.
- **Agent-generated Pine is in scope from Task 1**, not deferred to "later once curated-only is proven safe" — per the user's explicit call, on the stated single-user-platform basis. The sandbox (Step 2) is the control, not a curated-only allowlist.
- **`strategy.*`/paper-trading execution stays out of this spec's task list** pending explicit confirmation it rides along now vs. later (see Goal section) — flagged as open, not decided.

## Testing strategy per step

- Step 1: no functional changes expected — manual regression check in a real browser.
- Step 2: unit tests against the sandbox in isolation — a known-good script returns correct plot data; a script that spins forever gets killed by the CPU cap; a script that tries to reach the filesystem/network fails closed; malformed Pine returns a structured parse error, not a crash.
- Step 3: known Pine scripts (e.g. a plain EMA, a script using `plotshape`, one using `fill`) render matching hand-computed expected output.
- Step 4: default-view manual check — only candles + volume, nothing else, on a fresh chart.
- Step 5: manual browser verification of live ticks and pan-back history loading.
- Step 6: same seven overlay kinds verified as before.
- Step 7: migration script dry-run mode; manual confirmation that a pre-migration layout's drawings survive and its indicator list resets cleanly (per the confirmed drop-and-reset decision).
- Step 8: the graph-generation subagent's own worked examples (re-authored for Pine) validate against the real PineTS sandbox before shipping — same rigor this session already applied to diascript's worked examples.
- Step 9: manual pane-placement verification, same as before.
