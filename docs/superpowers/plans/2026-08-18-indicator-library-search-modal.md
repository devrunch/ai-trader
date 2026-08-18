# Indicator Library + Search Modal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the terminal's small indicator dropdown with a searchable modal, and expand the indicator library from ~11 to ~46 entries by authoring 35 new indicators as diascript formulas, computed client-side, rendered through the existing proven pipeline.

**Architecture:** diascript's engine gains 3 small primitives (`highestbars`/`lowestbars`, `log`, forward-offset plotting). `lib/diascript-indicators.ts` becomes a data-driven catalog instead of hand-named exports. A new `IndicatorSearchModal.tsx` replaces `IndicatorMenu.tsx`'s dropdown body, same props, same trigger. No backend changes — every new indicator computes from the OHLCV bars already on the chart.

**Tech Stack:** TypeScript (diascript engine + primitives), React/Next.js (search modal), klinecharts (render target), Vitest (all testing).

**Spec:** `docs/superpowers/specs/2026-08-18-indicator-library-search-modal-design.md` (this umbrella repo)

## Global Constraints

- Every new diascript primitive (`highestbars`, `lowestbars`, `log`) gets a `RESERVED` entry and an `ARITY` entry in `src/parser.ts`, an evaluator implementation, and an arity-rejection test — matching the exact pattern every existing primitive (`sma`, `abs`, etc.) already follows.
- Every new indicator formula MUST ship with a golden-value test comparing it to a named ground truth (a real `pandas_ta` call already in `ai-trader-signals/app/signals/indicators.py` for indicators that have one, or a precise hand-computed fixture for those that don't) within numeric tolerance — a formula with no such test is not done, regardless of how confident it looks.
- diascript primitives available for every formula in this plan: series refs (`open`/`high`/`low`/`close`/`volume`), windowed (`sma`/`ema`/`wma`/`stdev`/`highest`/`lowest`/`sum`, plus this plan's new `highestbars`/`lowestbars`), point-wise math (`+ - * /`, `abs`, `min`, `max`, this plan's new `log`), comparisons/logic (`> < >= <= == !=`, `and`/`or`/`not` — **comparisons produce a 0/1 series usable directly in further arithmetic**, e.g. `(close > ref(close,1)) - (close < ref(close,1))` is a valid `-1/0/1` sign expression), `ref(x,n)`/`prev(n)`, `held(condition, value)`, `true_range()`/`typical_price()`/`rsi(x,n)`. No loops, no user-defined functions, no ternary keyword — a conditional VALUE (not just a conditional gate) is built via the blending idiom `cond*a + (1-cond)*b`.
- diascript's real repo is `D:\adizx\diascript`; the frontend depends on it via the real published npm package (never `file:`/symlink) — after engine changes, publish a new version and bump `ai-trader-frontend`'s `package.json` to it, exactly as done for prior diascript work this session.
- New indicator names in the frontend catalog are prefixed `DIA_` (matching `DIA_EMA20`/`DIA_RSI14`'s existing convention) — e.g. `DIA_ADX`, `DIA_STOCH_K`.
- Category taxonomy (used by both the modal's filter and every catalog entry, native and diascript alike): `"Overlays" | "Trend" | "Momentum" | "Volatility" | "Volume"`.

---

## File Structure

**`diascript` repo (`D:\adizx\diascript`):**
- Modify: `src/parser.ts` — add `highestbars`, `lowestbars`, `log` to `RESERVED`/`ARITY`; add `offset` as a recognized named-arg key for `line`/`band`
- Modify: `src/engine/windowed.ts` — add `highestbars`/`lowestbars` implementations
- Modify: `src/engine/evaluator.ts` — add `log` to point-wise math handling; apply `offset` shift to output points
- Modify: `src/engine/outputs.ts` — thread `offset` through `line`/`band` wrapper handling
- Modify: `src/adapters/render/klinecharts/adapter.ts` — confirm/adjust for offset-shifted points once Task 1's spike result is known
- Create: `src/engine/windowed.test.ts` additions, `src/engine/evaluator.test.ts` additions, `src/engine/outputs.test.ts` additions (test files already exist — add cases, don't create new files)

**`ai-trader-frontend` repo:**
- Modify: `lib/diascript-indicators.ts` — restructure into `DIASCRIPT_CATALOG` (data-driven), migrate existing 2 entries, add 35 new
- Create: `lib/diascript-indicators.test.ts` — golden-value tests for every new formula
- Modify: `components/terminal/IndicatorMenu.tsx` — `INDICATOR_CATALOG` gains `category` on every entry (native + diascript)
- Create: `components/terminal/IndicatorSearchModal.tsx` — the new search/filter modal, replacing the dropdown body
- Create: `components/terminal/IndicatorSearchModal.test.tsx` — filter-logic unit tests
- Modify: `package.json` — bump `diascript` to the new published version

---

## Task 1: Spike — can klinecharts render a forward-shifted point?

**Files:** none created/modified — this is a throwaway investigation, its own todo, not a code deliverable.

**Interfaces:** none (informs Task 4's scope).

- [ ] **Step 1: Write a throwaway probe script**

In a scratch file (not committed), using the real installed `klinecharts` package (already a dependency of `ai-trader-frontend`), attempt to call `chart.createIndicator` with a `calc` function that returns a data point whose `time` value is LATER than the last real candle's `time` — e.g. take a small fixture of 30 candles, and in `calc`, return one extra point at `time = lastCandleTime + 26 * barIntervalMs`.

```typescript
// scratch probe — not part of the plan's file structure, delete after
import { init, registerIndicator } from "klinecharts";
// ... construct a minimal chart with 30 fixture candles, register a test
// indicator whose calc() appends one point 26 bars past the last real
// candle's time, and visually/programmatically check whether klinecharts
// draws it or clips it (e.g. query `chart.getIndicators()` output shape,
// or render into headless-Chrome and screenshot, matching the verification
// style already used earlier this session for the custom-indicator feature).
```

- [ ] **Step 2: Run the probe, observe the real result**

Expected: either the point renders (proving forward-offset plotting is buildable as designed), or it's silently clipped/dropped (proving the fallback is needed).

- [ ] **Step 3: Record the finding**

Write one sentence to the ledger (if using subagent-driven-development) or report directly: "klinecharts CAN/CANNOT render points beyond the loaded candle range." This determines Task 4's actual scope — read it before starting Task 4.

- [ ] **Step 4: Delete the scratch probe**

It was throwaway, per the brainstorming skill's spike convention. Nothing from this task is committed.

---

## Task 2: diascript — `highestbars`/`lowestbars` primitives

**Files:**
- Modify: `D:\adizx\diascript\src\parser.ts`
- Modify: `D:\adizx\diascript\src\engine\windowed.ts`
- Test: `D:\adizx\diascript\src\engine\windowed.test.ts`

**Interfaces:**
- Consumes: nothing from other tasks in this plan.
- Produces: `highestbars(x: number[], n: number): number` and `lowestbars(x: number[], n: number): number` — both return the bar-offset (`0` = most recent bar, up to `n-1`) of the extreme value within the trailing window of length `n`, exported from `windowed.ts` alongside the existing `sma`/`ema`/`highest`/`lowest`/etc. functions, with the SAME signature shape those already use (read `src/engine/windowed.ts`'s current exports first to match the exact parameter order/types before writing the new ones — don't guess the shape).

- [ ] **Step 1: Write the failing tests**

```typescript
// src/engine/windowed.test.ts (add to existing file)
import { highestbars, lowestbars } from "./windowed"; // adjust the import to match this file's existing import style

describe("highestbars", () => {
  it("returns 0 when the most recent bar is the highest", () => {
    const series = [1, 2, 3, 10, 3, 2, 1];
    expect(highestbars(series, series.length - 1, 3)).toBe(0); // last 3 values: [3,2,1] descending from index 4 — index 4 (value 3) is highest, 0 bars back from index 6... 
  });
});
```

Before finalizing this test, READ `src/engine/windowed.ts`'s current exported functions (e.g. `highest`) to see their EXACT parameter signature (likely `(series: number[], index: number, length: number) => number`, matching how the evaluator calls windowed functions per-bar — confirm this by reading `src/engine/evaluator.ts`'s existing calls to `highest`/`lowest`). Write `highestbars`/`lowestbars` tests using that SAME exact signature, not the illustrative one above. Add at least these cases: most-recent-bar-is-extreme (returns 0), oldest-bar-in-window-is-extreme (returns `n-1`), a tie (document and test whichever tie-breaking rule matches `highest`/`lowest`'s own tie behavior, for consistency), and insufficient history (fewer than `n` bars available — match `highest`/`lowest`'s own existing insufficient-history behavior, likely `NaN`).

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /d/adizx/diascript && npx vitest run src/engine/windowed.test.ts`
Expected: FAIL — `highestbars is not a function` (or similar).

- [ ] **Step 3: Implement**

Read `windowed.ts`'s existing `highest`/`lowest` implementations first and write `highestbars`/`lowestbars` as siblings using the identical iteration/bounds-checking style (don't introduce a different pattern for these two functions than the file already uses for everything else).

- [ ] **Step 4: Register in the grammar**

In `src/parser.ts`, add `"highestbars"`, `"lowestbars"` to `RESERVED` (alongside `sma`/`ema`/etc.) and to `ARITY` with value `2` (same arity as `highest`/`lowest`, since they take the same `(series, length)` shape).

- [ ] **Step 5: Wire into the evaluator**

Read how `src/engine/evaluator.ts` dispatches calls to `highest`/`lowest` today (likely a `switch`/dictionary keyed on function name) and add `highestbars`/`lowestbars` as siblings in the exact same dispatch mechanism.

- [ ] **Step 6: Add a parser-level rejection test**

```typescript
// src/parser.test.ts (add to existing file)
it("rejects highestbars with the wrong number of arguments", () => {
  expect(() => parse("x = highestbars(close)")).toThrow(); // only 1 arg, arity is 2
});
```

- [ ] **Step 7: Run full test suite**

Run: `cd /d/adizx/diascript && npm test`
Expected: all tests pass (83 existing + new ones).

- [ ] **Step 8: Commit**

```bash
cd /d/adizx/diascript
git add src/parser.ts src/engine/windowed.ts src/engine/windowed.test.ts src/parser.test.ts
git commit -m "feat: add highestbars/lowestbars primitives"
```

---

## Task 3: diascript — `log`/`sqrt` primitives

**Files:**
- Modify: `D:\adizx\diascript\src\parser.ts`
- Modify: `D:\adizx\diascript\src\engine\evaluator.ts`
- Test: wherever this repo's existing point-wise math tests live (read `src/engine/evaluator.test.ts` first — `abs`/`min`/`max` almost certainly already have tests there; add `log`/`sqrt`'s tests alongside them, in the same file, same style)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `log(x)` — natural log, point-wise, arity 1. `sqrt(x)` — square root, point-wise, arity 1. Both usable anywhere `abs(x)` is usable today. (`sqrt` is needed by Task 9's Historical Volatility formula, for a precise `sqrt(252)` annualization factor rather than a hardcoded approximation.)

- [ ] **Step 1: Write the failing tests**

Read how `abs`/`min`/`max` are tested in this repo first (find the exact file and pattern — likely in `src/engine/evaluator.test.ts` or a dedicated point-wise-math test section) and add `log`/`sqrt` tests in the same style:

```typescript
it("computes natural log point-wise", () => {
  const result = evaluateFormulaSeries(parse("x = log(close)"), fixture, ctx)["x"];
  expect(result[someIndex]).toBeCloseTo(Math.log(fixture[someIndex].close), 6);
});

it("computes square root point-wise", () => {
  const result = evaluateFormulaSeries(parse("x = sqrt(close)"), fixture, ctx)["x"];
  expect(result[someIndex]).toBeCloseTo(Math.sqrt(fixture[someIndex].close), 6);
});
```

Adjust to match this repo's REAL test helper names/signatures (`evaluateFormulaSeries`, fixture shape, `ctx` construction) — read a neighboring existing point-wise-math test and copy its exact setup, don't invent new helper usage.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /d/adizx/diascript && npx vitest run src/engine/evaluator.test.ts`
Expected: FAIL.

- [ ] **Step 3: Implement**

Find where `abs`/`min`/`max` are dispatched in `src/engine/evaluator.ts` and add `log`/`sqrt` as siblings, calling `Math.log`/`Math.sqrt` on the single argument.

- [ ] **Step 4: Register in the grammar**

`src/parser.ts`: add `"log"`, `"sqrt"` to `RESERVED` and `ARITY` (value `1` each, same as `abs`).

- [ ] **Step 5: Run full test suite**

Run: `cd /d/adizx/diascript && npm test`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
cd /d/adizx/diascript
git add src/parser.ts src/engine/evaluator.ts src/engine/evaluator.test.ts
git commit -m "feat: add log and sqrt primitives"
```

---

## Task 4: diascript — forward-offset plotting for `line`/`band`

**Files:**
- Modify: `D:\adizx\diascript\src\parser.ts`
- Modify: `D:\adizx\diascript\src\engine\outputs.ts`
- Modify: `D:\adizx\diascript\src\adapters\render\klinecharts\adapter.ts` (only if Task 1's spike found klinecharts CAN render beyond the loaded range)
- Test: `src/engine/outputs.test.ts`, `src/adapters/render/klinecharts/adapter.test.ts`

**Interfaces:**
- Consumes: Task 1's spike finding (read it before starting — it determines this task's actual scope, see Step 0 below).
- Produces: `line(x, offset=N)` / `band(upper, lower, offset=N)` — `IndicatorOutput`'s points carry a shifted index/time when `offset` is non-zero.

- [ ] **Step 0: Read Task 1's spike finding first**

If the spike found klinecharts CANNOT render beyond the loaded candle range: this task's scope reduces to grammar-only — `offset` still parses as a valid named arg (so formulas using it don't fail to parse), but the evaluator clamps/no-ops it (documents in a code comment why, referencing the spike), and Ichimoku (Task 7) ships without real forward displacement, per the already-accepted fallback. Skip Step 4 below in that case. If the spike found it CAN render beyond range, do the full task as written.

- [ ] **Step 1: Write the failing test**

```typescript
// src/engine/outputs.test.ts (add to existing file)
it("shifts line() output points forward when offset is given", () => {
  const result = buildOutput(/* a parsed line(x, offset=2) formula */, fixture, ctx);
  // Confirm the returned IndicatorOutput's points array's `time`/index values
  // are each 2 bars later than an equivalent offset=0 call's points would be —
  // read buildOutput's real current signature and IndicatorOutput's real
  // point shape first (src/engine/types.ts) before writing this assertion,
  // don't guess the field names.
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /d/adizx/diascript && npx vitest run src/engine/outputs.test.ts`

- [ ] **Step 3: Grammar change**

`src/parser.ts`: `line`/`band`'s argument parsing already handles named args (`color=` for `band`/`marker`/etc. — read the existing named-arg handling for `color` first and mirror it exactly). Add `offset` as a recognized named-arg key for `line` and `band` specifically, defaulting to `0` when omitted.

- [ ] **Step 4: Evaluator/output change (skip if Step 0 found klinecharts can't render offset)**

In `src/engine/outputs.ts`, after computing a `line`/`band` formula's normal per-bar values, shift each point's `time`/bar-index by `offset` before returning it as part of `IndicatorOutput`. Read the exact current point-construction code first — don't restructure beyond adding the shift.

- [ ] **Step 5: Render adapter check**

If Task 1's spike proved klinecharts can render shifted points, confirm `src/adapters/render/klinecharts/adapter.ts`'s existing `calcResultFor` (or equivalent) passes the shifted `time` through unchanged to klinecharts' own data shape — it almost certainly already does, since it just maps `IndicatorOutput` points to klinecharts' point format, but verify with a test rather than assuming.

- [ ] **Step 6: Run full test suite**

Run: `cd /d/adizx/diascript && npm test`

- [ ] **Step 7: Commit**

```bash
cd /d/adizx/diascript
git add src/parser.ts src/engine/outputs.ts src/engine/outputs.test.ts src/adapters/render/klinecharts/adapter.ts src/adapters/render/klinecharts/adapter.test.ts
git commit -m "feat: add offset= support to line/band outputs"
```

---

## Task 5: Publish diascript and bump the frontend dependency

**Files:**
- Modify: `D:\adizx\diascript\package.json` (version bump)
- Modify: `d:\adizx\ai-trader\ai-trader-frontend\package.json` (dependency bump)

**Interfaces:**
- Consumes: Tasks 2-4's engine changes.
- Produces: a new published `diascript` version that `ai-trader-frontend` depends on.

- [ ] **Step 1: Bump version, build, test**

```bash
cd /d/adizx/diascript
npm test && npm run build
```

Edit `package.json`: bump `"version"` to the next patch (check the current published version first via `npm view diascript version` — this session has already published through `0.0.7`, so this is very likely `0.0.8`, but verify rather than assume).

- [ ] **Step 2: Commit and publish**

```bash
cd /d/adizx/diascript
git add package.json
git commit -m "chore: bump version for highestbars/lowestbars, log, offset plotting"
```

Run: `npm publish`. If this prompts for an OTP, report `BLOCKED` — publishing needs a one-time code only the human partner can supply. Do not guess.

- [ ] **Step 3: Bump the frontend's dependency**

```bash
cd d:/adizx/ai-trader/ai-trader-frontend
```
Edit `package.json`'s `"diascript"` line to the new version (e.g. `"^0.0.8"` — note that under semver's caret-on-`0.0.x` rule this resolves to EXACTLY that version, which is correct/intentional, matching this session's established pattern).

```bash
npm install
npx vitest run
```
Expected: install succeeds, existing 3 tests still pass.

- [ ] **Step 4: Commit**

```bash
cd d:/adizx/ai-trader/ai-trader-frontend
git add package.json package-lock.json
git commit -m "chore: bump diascript for highestbars/lowestbars, log, offset plotting"
```

---

## Task 6: Frontend — catalog restructure

**Files:**
- Modify: `d:\adizx\ai-trader\ai-trader-frontend\lib\diascript-indicators.ts`
- Create: `d:\adizx\ai-trader\ai-trader-frontend\lib\diascript-indicators.test.ts`

**Interfaces:**
- Consumes: Task 5's published diascript version.
- Produces: `DIASCRIPT_CATALOG: DiascriptIndicatorDef[]`, `IndicatorCategory` type, `registerDiascriptIndicators()` (same public name/behavior as today, now data-driven) — Tasks 7-10 append entries to `DIASCRIPT_CATALOG`; Task 11 reads `DiascriptIndicatorDef`'s `category` field.

- [ ] **Step 1: Write the failing test**

```typescript
// lib/diascript-indicators.test.ts
import { describe, it, expect } from "vitest";
import { DIASCRIPT_CATALOG } from "./diascript-indicators";

describe("DIASCRIPT_CATALOG", () => {
  it("has no duplicate indicator names", () => {
    const names = DIASCRIPT_CATALOG.map(d => d.name);
    expect(new Set(names).size).toBe(names.length);
  });

  it("every entry has a non-empty source and a matching outputName", () => {
    for (const def of DIASCRIPT_CATALOG) {
      expect(def.source.length).toBeGreaterThan(0);
      expect(def.source).toContain(def.outputName);
    }
  });

  it("still includes the original two proof-of-concept indicators", () => {
    const names = DIASCRIPT_CATALOG.map(d => d.name);
    expect(names).toContain("DIA_EMA20");
    expect(names).toContain("DIA_RSI14");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd d:/adizx/ai-trader/ai-trader-frontend && npx vitest run lib/diascript-indicators.test.ts`
Expected: FAIL — `DIASCRIPT_CATALOG` not exported yet.

- [ ] **Step 3: Read the current file, then restructure**

Read the CURRENT `lib/diascript-indicators.ts` in full first (it has `noopAdapter` exported, `DIASCRIPT_EMA_20`/`DIASCRIPT_RSI_14` constants, and `registerDiascriptIndicators()`). Restructure to:

```typescript
import { InMemoryDataAdapter } from "diascript";
import { registerDiascriptIndicator } from "diascript/klinecharts";

export const noopAdapter = new InMemoryDataAdapter();

export type IndicatorCategory = "Overlays" | "Trend" | "Momentum" | "Volatility" | "Volume";

export interface DiascriptIndicatorDef {
  name: string;
  label: string;
  category: IndicatorCategory;
  source: string;
  outputName: string;
}

export const DIASCRIPT_CATALOG: DiascriptIndicatorDef[] = [
  {
    name: "DIA_EMA20", label: "EMA 20 (diascript)", category: "Overlays",
    source: "ema_line = line(ema(close, 20))", outputName: "ema_line",
  },
  {
    name: "DIA_RSI14", label: "RSI 14 (diascript)", category: "Momentum",
    source: "rsi_line = line(rsi(close, 14))", outputName: "rsi_line",
  },
  // Tasks 7-10 append their entries here.
];

let registered = false;
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

- [ ] **Step 4: Run test to verify it passes**

Run: `cd d:/adizx/ai-trader/ai-trader-frontend && npx vitest run lib/diascript-indicators.test.ts`
Expected: PASS (3 tests).

- [ ] **Step 5: Confirm `CandlestickChart.tsx` still works unchanged**

Read `components/CandlestickChart.tsx`'s `registerDiascriptIndicators()` call site — it should need ZERO changes, since the function's name/behavior contract is unchanged, only its internals. Run `npx tsc --noEmit` to confirm no type errors anywhere that imports `DIASCRIPT_EMA_20`/`DIASCRIPT_RSI_14` directly (if anything did import those old named constants directly rather than through the catalog, that's now a compile error to fix — grep for `DIASCRIPT_EMA_20` and `DIASCRIPT_RSI_14` across the repo first).

- [ ] **Step 6: Run full test suite**

Run: `npx vitest run` — expect all existing + 3 new tests to pass.

- [ ] **Step 7: Commit**

```bash
cd d:/adizx/ai-trader/ai-trader-frontend
git add lib/diascript-indicators.ts lib/diascript-indicators.test.ts
git commit -m "refactor: restructure diascript indicators into a data-driven catalog"
```

---

## Task 7: Indicator batch — Trend (10)

**Files:**
- Modify: `d:\adizx\ai-trader\ai-trader-frontend\lib\diascript-indicators.ts` (append to `DIASCRIPT_CATALOG`)
- Modify: `d:\adizx\ai-trader\ai-trader-frontend\lib\diascript-indicators.test.ts` (append golden-value tests)

**Interfaces:**
- Consumes: `DiascriptIndicatorDef`, `DIASCRIPT_CATALOG` (Task 6).
- Produces: 10 new catalog entries (some indicators need multiple entries for multiple output lines — see below), each covered by a golden-value test.

For every formula below, write it as diascript source, add ONE `DiascriptIndicatorDef` per rendered output line (multi-line indicators get multiple entries sharing conceptually the same computation, matching the MACD pattern the design spec shows — each entry's `source` can repeat the shared intermediate formulas, since each is a fully independent `registerDiascriptIndicator` call), and add a golden-value test comparing against the named ground truth.

- [ ] **Step 1: Average Directional Index (ADX, +DI, -DI)** — 3 catalog entries (`DIA_ADX`, `DIA_DI_PLUS`, `DIA_DI_MINUS`), category `"Trend"`.

Ground truth: `ai-trader-signals/app/signals/indicators.py`'s `adx()` — `ta.adx(df["high"], df["low"], df["close"], length=14)`, reading `ADX_14`/`DMP_14`/`DMN_14`.

Standard Wilder ADX definition (derive the diascript formula from this, using `prev()` for the Wilder-smoothing recursion the same way `rsi()`'s own built-in already does):
```
+DM = current high - previous high, if positive AND greater than (previous low - current low), else 0
-DM = previous low - current low, if positive AND greater than (current high - previous high), else 0
Smoothed +DM, -DM, and TR use Wilder's smoothing: smoothed = prev(1)*(13/14) + raw/14 (length 14)
+DI = 100 * smoothed(+DM) / smoothed(TR)
-DI = 100 * smoothed(-DM) / smoothed(TR)
DX = 100 * abs(+DI - -DI) / (+DI + -DI)
ADX = Wilder-smoothed DX over 14 periods (same smoothing pattern)
```
Use the 0/1-blending idiom (`Global Constraints`) for the "if positive AND greater than the other" conditions — e.g. `plus_dm_raw = max(high - ref(high,1), 0) * ((high - ref(high,1)) > (ref(low,1) - low))`.

- [ ] **Step 2: Aroon (Up, Down)** — 2 catalog entries (`DIA_AROON_UP`, `DIA_AROON_DOWN`), category `"Trend"`.

Ground truth: `indicators.py`'s `aroon()` — `ta.aroon(df["high"], df["low"])` (pandas_ta default length 14), reading `AROONU_14`/`AROOND_14`.

```
aroon_up   = 100 * (14 - highestbars(high, 14)) / 14
aroon_down = 100 * (14 - lowestbars(low, 14)) / 14
```
(Uses Task 2's new primitives directly — this is the indicator that motivated adding them.)

- [ ] **Step 3: Donchian Channels (Upper, Mid, Lower)** — 3 catalog entries, category `"Trend"`.

Ground truth: `indicators.py`'s `donchian()` — `ta.donchian(df["high"], df["low"])` (pandas_ta default lower/upper length 20).

```
dc_upper = highest(high, 20)
dc_lower = lowest(low, 20)
dc_mid   = (dc_upper + dc_lower) / 2
```

- [ ] **Step 4: Envelopes (Upper, Lower)** — 2 catalog entries, category `"Trend"`. No pandas_ta reference in this repo — use the standard definition, golden-test against a hand-computed fixture.

```
basis = sma(close, 20)
env_upper = basis * 1.025   # 2.5% envelope, a common default
env_lower = basis * 0.975
```

- [ ] **Step 5: Ichimoku Cloud (Tenkan, Kijun, Senkou A, Senkou B)** — 4 catalog entries, category `"Trend"`.

Ground truth: `indicators.py`'s `ichimoku()` — `ta.ichimoku(df["high"], df["low"], df["close"])`, reading `ITS_9`/`IKS_26`/`ISA_9`/`ISB_26`.

```
tenkan   = (highest(high, 9) + lowest(low, 9)) / 2
kijun    = (highest(high, 26) + lowest(low, 26)) / 2
senkou_a = line((tenkan + kijun) / 2, offset=26)   # forward-shifted — depends on Task 1/4's finding
senkou_b = line((highest(high, 52) + lowest(low, 52)) / 2, offset=26)
```
If Task 1's spike found klinecharts cannot render offset points: ship `senkou_a`/`senkou_b` WITHOUT the `offset=26` argument (plain `line(...)`), and set each entry's `label` to include "(no forward shift)" so this is visible to the user, not silently wrong.

- [ ] **Step 6: Keltner Channels (Upper, Mid, Lower)** — 3 catalog entries, category `"Trend"`.

Ground truth: `indicators.py`'s `keltner()` — `ta.kc(df["high"], df["low"], df["close"])` (pandas_ta default length 20, scalar 2).

```
kc_mid   = ema(close, 20)
kc_range = ema(true_range(), 20)
kc_upper = kc_mid + 2 * kc_range
kc_lower = kc_mid - 2 * kc_range
```

- [ ] **Step 7: Hull Moving Average** — 1 catalog entry, category `"Trend"`.

Ground truth: `indicators.py`'s `hma()` — `ta.hma(df["close"], length=20)`.

Standard HMA definition:
```
wma_half = wma(close, 10)      # length/2 = 10
wma_full = wma(close, 20)
raw_hma  = 2 * wma_half - wma_full
hma      = wma(raw_hma, 4)      # sqrt(20) rounded ~ 4
```

- [ ] **Step 8: Double EMA (DEMA)** — 1 catalog entry, category `"Trend"`. No pandas_ta reference — hand-computed fixture.

```
ema1 = ema(close, 20)
ema2 = ema(ema1, 20)
dema = 2 * ema1 - ema2
```

- [ ] **Step 9: Triple EMA (TEMA)** — 1 catalog entry, category `"Trend"`. No pandas_ta reference — hand-computed fixture.

```
ema1 = ema(close, 20)
ema2 = ema(ema1, 20)
ema3 = ema(ema2, 20)
tema = 3*ema1 - 3*ema2 + ema3
```

- [ ] **Step 10: SuperTrend (direction line)** — 1 catalog entry, category `"Trend"`.

Ground truth: `indicators.py`'s `supertrend()` — `ta.supertrend(df["high"], df["low"], df["close"], length=10, multiplier=3)`.

```
atr_st = ema(true_range(), 10)
basic_upper = (high + low) / 2 + 3 * atr_st
basic_lower = (high + low) / 2 - 3 * atr_st
# Final bands use the recursive "only move toward price" rule — use prev()
# and the 0/1-blending idiom: final_upper "ratchets down" toward price and
# only widens when price closes back above it (and mirror for final_lower).
# Derive this using prev(1) self-reference plus blending, following the same
# recursive pattern true_range()/rsi() already establish in this grammar.
```
This is the most involved formula in this batch — take care, and lean on the golden-value test (compare the resulting trend-direction sign, not exact band values, against `SUPERTd_10_3.0` from the real `ta.supertrend` call) to catch mistakes.

- [ ] **Step 11: Write all 10+ catalog entries and their golden-value tests**

For EACH indicator above: add its `DiascriptIndicatorDef` entries to `DIASCRIPT_CATALOG` in `lib/diascript-indicators.ts`, and add a test in `lib/diascript-indicators.test.ts` that evaluates the formula against a fixed OHLCV fixture and compares to the named ground truth (compute the ground truth once, either by running the real Python `ta.*` call on the SAME fixture data and hardcoding the expected numbers as comments showing how they were derived, or — preferred, since it keeps the test self-documenting and repo-local — writing the fixture small enough to hand-verify a few key values). Use a shared fixture across this file (define it once, reuse across all indicator tests in this task and Tasks 8-10).

- [ ] **Step 12: Run the full test suite**

Run: `cd d:/adizx/ai-trader/ai-trader-frontend && npx vitest run`
Expected: all pass, including every new golden-value test.

- [ ] **Step 13: Commit**

```bash
cd d:/adizx/ai-trader/ai-trader-frontend
git add lib/diascript-indicators.ts lib/diascript-indicators.test.ts
git commit -m "feat: add Trend category indicators (ADX, Aroon, Donchian, Envelopes, Ichimoku, Keltner, HMA, DEMA, TEMA, SuperTrend)"
```

---

## Task 8: Indicator batch — Momentum (12)

**Files:** same two files as Task 7.

**Interfaces:** same as Task 7 (appends to the same catalog/test file).

- [ ] **Step 1: Stochastic (%K, %D)** — 2 entries, category `"Momentum"`. Ground truth: `indicators.py`'s `stoch()` — `ta.stoch(df["high"], df["low"], df["close"])` (pandas_ta default: k=14, d=3, smooth_k=3).
```
raw_k = 100 * (close - lowest(low, 14)) / (highest(high, 14) - lowest(low, 14))
stoch_k = sma(raw_k, 3)
stoch_d = sma(stoch_k, 3)
```

- [ ] **Step 2: Stochastic RSI (%K, %D)** — 2 entries. Ground truth: `stochrsi()` — `ta.stochrsi(df["close"])` (pandas_ta default: length=14, rsi_length=14, k=3, d=3).
```
rsi_val = rsi(close, 14)
raw_k = 100 * (rsi_val - lowest(rsi_val, 14)) / (highest(rsi_val, 14) - lowest(rsi_val, 14))
stochrsi_k = sma(raw_k, 3)
stochrsi_d = sma(stochrsi_k, 3)
```

- [ ] **Step 3: Awesome Oscillator** — 1 entry. No pandas_ta reference — hand-computed fixture.
```
hl2 = (high + low) / 2
ao = sma(hl2, 5) - sma(hl2, 34)
```

- [ ] **Step 4: Momentum** — 1 entry. No pandas_ta reference — hand-computed fixture.
```
momentum = close - ref(close, 10)
```

- [ ] **Step 5: Rate of Change** — 1 entry. Ground truth: `roc()` — `ta.roc(df["close"])` (pandas_ta default length 10).
```
roc = 100 * (close - ref(close, 10)) / ref(close, 10)
```

- [ ] **Step 6: Commodity Channel Index** — 1 entry. Ground truth: `cci()` — `ta.cci(df["high"], df["low"], df["close"])` (pandas_ta default length 20 — note this differs from many public CCI references' length-20 constant `0.015`, use pandas_ta's own default to match the ground truth exactly).
```
tp = typical_price()
tp_sma = sma(tp, 20)
mean_dev = sum(abs(tp - tp_sma), 20) / 20
cci = (tp - tp_sma) / (0.015 * mean_dev)
```

- [ ] **Step 7: Williams %R** — 1 entry. Ground truth: `willr()` — `ta.willr(df["high"], df["low"], df["close"])` (pandas_ta default length 14).
```
willr = -100 * (highest(high, 14) - close) / (highest(high, 14) - lowest(low, 14))
```

- [ ] **Step 8: Ultimate Oscillator** — 1 entry. Ground truth: `uo()` — `ta.uo(df["high"], df["low"], df["close"])` (pandas_ta default periods 7/14/28, weights 4/2/1).
```
tl = min(low, ref(close, 1))
bp = close - tl
tr_uo = true_range()
avg7  = sum(bp, 7)  / sum(tr_uo, 7)
avg14 = sum(bp, 14) / sum(tr_uo, 14)
avg28 = sum(bp, 28) / sum(tr_uo, 28)
uo = 100 * (4*avg7 + 2*avg14 + avg28) / 7
```

- [ ] **Step 9: TRIX** — 1 entry. No pandas_ta reference — hand-computed fixture.
```
ema1 = ema(close, 15)
ema2 = ema(ema1, 15)
ema3 = ema(ema2, 15)
trix = 100 * (ema3 - ref(ema3, 1)) / ref(ema3, 1)
```

- [ ] **Step 10: Fisher Transform** — 1 entry (or 2, if including the signal/trigger line — check the design spec's scope, this plan covers the main Fisher line only). No pandas_ta reference — hand-computed fixture, uses Task 3's new `log` primitive.
```
hl2 = (high + low) / 2
highest_hl2 = highest(hl2, 9)
lowest_hl2  = lowest(hl2, 9)
raw = 2 * ((hl2 - lowest_hl2) / (highest_hl2 - lowest_hl2) - 0.5)
raw_clamped = min(max(raw, -0.999), 0.999)   # log((1+x)/(1-x)) blows up at +/-1
fisher = 0.5 * log((1 + raw_clamped) / (1 - raw_clamped))
```

- [ ] **Step 11: Money Flow Index** — 1 entry. Ground truth: `mfi()` — `ta.mfi(df["high"], df["low"], df["close"], df["volume"])` (pandas_ta default length 14).
```
tp = typical_price()
money_flow = tp * volume
positive_flow_raw = money_flow * (tp > ref(tp, 1))
negative_flow_raw = money_flow * (tp < ref(tp, 1))
positive_sum = sum(positive_flow_raw, 14)
negative_sum = sum(negative_flow_raw, 14)
money_ratio = positive_sum / negative_sum
mfi = 100 - 100 / (1 + money_ratio)
```

- [ ] **Step 12: Chande Momentum Oscillator** — 1 entry. No pandas_ta reference — hand-computed fixture.
```
change = close - ref(close, 1)
gain = max(change, 0)
loss = max(-change, 0)
sum_gain = sum(gain, 9)
sum_loss = sum(loss, 9)
cmo = 100 * (sum_gain - sum_loss) / (sum_gain + sum_loss)
```

- [ ] **Step 13: Write all catalog entries + golden-value tests, run full suite, commit**

Same process as Task 7's Steps 11-13.

```bash
cd d:/adizx/ai-trader/ai-trader-frontend
git add lib/diascript-indicators.ts lib/diascript-indicators.test.ts
git commit -m "feat: add Momentum category indicators (Stochastic, StochRSI, Awesome Osc, Momentum, ROC, CCI, Williams %R, Ultimate Osc, TRIX, Fisher Transform, MFI, CMO)"
```

---

## Task 9: Indicator batch — Volatility (5)

**Files:** same two files as Task 7.

**Interfaces:** same as Task 7.

- [ ] **Step 1: Average True Range** — 1 entry, category `"Volatility"`. Ground truth: `atr()` — `ta.atr(df["high"], df["low"], df["close"], length=14)`.
```
atr = ema(true_range(), 14)
```

- [ ] **Step 2: Bollinger Bands %B** — 1 entry. Ground truth: `bbands()`'s `bb_pct` output (already computed in `indicators.py`, pandas_ta default length 20, std 2).
```
basis = sma(close, 20)
dev = stdev(close, 20)
upper = basis + 2*dev
lower = basis - 2*dev
bb_pct = (close - lower) / (upper - lower)
```

- [ ] **Step 3: Bollinger Bands Width** — 1 entry. No dedicated pandas_ta reference in this repo (derivable from the same `bbands()` call, but not currently exposed) — hand-computed fixture, same underlying bands as Step 2.
```
bb_width = (upper - lower) / basis
```

- [ ] **Step 4: Standard Deviation** — 1 entry. Trivial — `stdev` is already a diascript primitive, this is a direct wrap, no derivation risk.
```
stdev_line = stdev(close, 20)
```

- [ ] **Step 5: Historical Volatility** — 1 entry. No pandas_ta reference — hand-computed fixture, uses Task 3's `log`/`sqrt`.
```
log_return = log(close / ref(close, 1))
hv = 100 * stdev(log_return, 20) * sqrt(252)   # annualized, as a percent — 252 = trading days/year for daily bars
```

- [ ] **Step 6: Write catalog entries + golden-value tests, run full suite, commit**

```bash
cd d:/adizx/ai-trader/ai-trader-frontend
git add lib/diascript-indicators.ts lib/diascript-indicators.test.ts
git commit -m "feat: add Volatility category indicators (ATR, Bollinger %B, Bollinger Width, Standard Deviation, Historical Volatility)"
```

---

## Task 10: Indicator batch — Volume (8)

**Files:** same two files as Task 7.

**Interfaces:** same as Task 7.

- [ ] **Step 1: On Balance Volume** — 1 entry, category `"Volume"`. Ground truth: `obv()` — `ta.obv(df["close"], df["volume"])`.
```
sign = (close > ref(close, 1)) - (close < ref(close, 1))
obv = prev(1) + sign * volume
```

- [ ] **Step 2: Accumulation/Distribution** — 1 entry. No pandas_ta reference — hand-computed fixture.
```
mfm = ((close - low) - (high - close)) / (high - low)
mfv = mfm * volume
ad = prev(1) + mfv
```

- [ ] **Step 3: Chaikin Money Flow** — 1 entry. Ground truth: `cmf()` — `ta.cmf(df["high"], df["low"], df["close"], df["volume"])` (pandas_ta default length 20).
```
mfm = ((close - low) - (high - close)) / (high - low)
mfv = mfm * volume
cmf = sum(mfv, 20) / sum(volume, 20)
```

- [ ] **Step 4: VWAP** — 1 entry. Ground truth: `vwap()` — session-anchored, per the comment in `indicators.py`: "Intraday VWAP MUST reset each session." Use the `session.is_open()` context primitive to detect a session boundary.
```
tp = typical_price()
pv = tp * volume
session_start = session.is_open() and (not ref(session.is_open(), 1))
cum_pv = session_start * pv + (1 - session_start) * (prev(1) + pv)
cum_vol = session_start * volume + (1 - session_start) * (prev(1) + volume)
vwap = cum_pv / cum_vol
```
Note: `cum_pv`/`cum_vol` each need their OWN `prev(1)` self-reference — write them as two separate named formulas (not inlined into one), since `prev()` refers to "this formula's own" prior value, and `vwap` itself has no `prev()` recursion (it's a simple ratio of the other two).

- [ ] **Step 5: VWMA (Volume Weighted Moving Average)** — 1 entry. No pandas_ta reference — hand-computed fixture.
```
vwma = sum(close * volume, 20) / sum(volume, 20)
```

- [ ] **Step 6: Volume Oscillator** — 1 entry. No pandas_ta reference — hand-computed fixture.
```
vol_osc = 100 * (sma(volume, 5) - sma(volume, 20)) / sma(volume, 20)
```

- [ ] **Step 7: Price Volume Trend** — 1 entry. No pandas_ta reference — hand-computed fixture.
```
pct_change = (close - ref(close, 1)) / ref(close, 1)
pvt = prev(1) + pct_change * volume
```

- [ ] **Step 8: Ease of Movement** — 1 entry. No pandas_ta reference — hand-computed fixture.
```
distance = (high + low) / 2 - (ref(high, 1) + ref(low, 1)) / 2
box_ratio = (volume / 100000000) / (high - low)
raw_emv = distance / box_ratio
emv = sma(raw_emv, 14)
```

- [ ] **Step 9: Write catalog entries + golden-value tests, run full suite, commit**

```bash
cd d:/adizx/ai-trader/ai-trader-frontend
git add lib/diascript-indicators.ts lib/diascript-indicators.test.ts
git commit -m "feat: add Volume category indicators (OBV, A/D, CMF, VWAP, VWMA, Volume Oscillator, PVT, Ease of Movement)"
```

---

## Task 11: `IndicatorMenu.tsx` — categorize the existing native entries

**Files:**
- Modify: `d:\adizx\ai-trader\ai-trader-frontend\components\terminal\IndicatorMenu.tsx`

**Interfaces:**
- Consumes: `IndicatorCategory` type (Task 6), `DIASCRIPT_CATALOG` (Tasks 6-10).
- Produces: `INDICATOR_CATALOG` with a `category` field on every entry (native + diascript), for Task 12's modal to filter against.

- [ ] **Step 1: Add `category` to every existing native entry**

```typescript
import { DIASCRIPT_CATALOG, type IndicatorCategory } from "@/lib/diascript-indicators";

export const INDICATOR_CATALOG: {
  name: string;
  label: string;
  group: "Overlays" | "Oscillators";   // KEEP — still used by CandlestickChart.tsx's MAIN_PANE_INDICATORS-adjacent pane logic if anything reads `group`; verify this by grepping for `.group` usage before removing it
  category: IndicatorCategory;
}[] = [
  { name: "EMA",  label: "EMA (20, 50)",       group: "Overlays",    category: "Overlays" },
  { name: "MA",   label: "Moving Average",     group: "Overlays",    category: "Overlays" },
  { name: "BOLL", label: "Bollinger Bands",    group: "Overlays",    category: "Volatility" },
  { name: "SAR",  label: "Parabolic SAR",      group: "Overlays",    category: "Trend" },
  { name: "BBI",  label: "BBI",                group: "Overlays",    category: "Trend" },
  { name: "VOL",  label: "Volume",             group: "Oscillators", category: "Volume" },
  { name: "MACD", label: "MACD",               group: "Oscillators", category: "Momentum" },
  { name: "RSI",  label: "RSI (14)",           group: "Oscillators", category: "Momentum" },
  { name: "KDJ",  label: "Stochastic (KDJ)",   group: "Oscillators", category: "Momentum" },
  ...DIASCRIPT_CATALOG.map(d => ({
    name: d.name, label: d.label,
    group: (d.category === "Volume" || d.category === "Momentum" || d.category === "Volatility") ? "Oscillators" as const : "Overlays" as const,
    category: d.category,
  })),
];
```

Read the CURRENT file first — grep the whole frontend repo for `INDICATOR_CATALOG` and `.group` usage before finalizing this, to confirm nothing else depends on the exact shape being changed here (in particular whether `group` is read anywhere besides this file's own render code — if it's genuinely unused elsewhere, it's reasonable to drop `group` entirely in favor of deriving the Overlays/Oscillators pane split directly from `category`, but only do that if you've confirmed it's safe, not by assumption).

- [ ] **Step 2: Run existing tests + type-check**

Run: `cd d:/adizx/ai-trader/ai-trader-frontend && npx tsc --noEmit && npx vitest run`

- [ ] **Step 3: Commit**

```bash
cd d:/adizx/ai-trader/ai-trader-frontend
git add components/terminal/IndicatorMenu.tsx
git commit -m "feat: add category to every indicator catalog entry"
```

---

## Task 12: `IndicatorSearchModal.tsx` — the search UI

**Files:**
- Create: `d:\adizx\ai-trader\ai-trader-frontend\components\terminal\IndicatorSearchModal.tsx`
- Create: `d:\adizx\ai-trader\ai-trader-frontend\components\terminal\IndicatorSearchModal.test.tsx`
- Modify: wherever `IndicatorMenu` is currently rendered (grep the repo for `<IndicatorMenu` to find the real call site — likely `terminal/page.tsx`) to render `IndicatorSearchModal` instead, with the SAME props.

**Interfaces:**
- Consumes: `INDICATOR_CATALOG` (Task 11), same `active`/`onToggle` prop contract `IndicatorMenu` already has.
- Produces: a drop-in replacement — same props, same trigger button/badge, modal instead of dropdown body.

- [ ] **Step 1: Write the failing filter-logic test**

```typescript
// components/terminal/IndicatorSearchModal.test.tsx
import { describe, it, expect } from "vitest";
import { filterCatalog } from "./IndicatorSearchModal";
import { INDICATOR_CATALOG } from "./IndicatorMenu";

describe("filterCatalog", () => {
  it("matches by case-insensitive substring on label", () => {
    const result = filterCatalog(INDICATOR_CATALOG, "rsi", "All");
    expect(result.some(i => i.name === "RSI")).toBe(true);
    expect(result.every(i => i.label.toLowerCase().includes("rsi"))).toBe(true);
  });

  it("narrows by category when one is selected", () => {
    const result = filterCatalog(INDICATOR_CATALOG, "", "Volume");
    expect(result.every(i => i.category === "Volume")).toBe(true);
  });

  it("shows everything when search is empty and category is All", () => {
    expect(filterCatalog(INDICATOR_CATALOG, "", "All").length).toBe(INDICATOR_CATALOG.length);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd d:/adizx/ai-trader/ai-trader-frontend && npx vitest run components/terminal/IndicatorSearchModal.test.tsx`
Expected: FAIL — module doesn't exist yet.

- [ ] **Step 3: Read `IndicatorMenu.tsx`'s current click-outside/Escape/rendering logic first**

Before writing the new component, read the FULL current `IndicatorMenu.tsx` (its click-outside handler, Escape handler, and JSX structure) — the new modal keeps the same open/close mechanics (Escape, click-outside) and the same trigger button/badge markup, just swaps the dropdown body for a modal body.

- [ ] **Step 4: Implement**

```typescript
"use client";

import { useEffect, useRef, useState } from "react";
import { INDICATOR_CATALOG } from "./IndicatorMenu";
import type { IndicatorCategory } from "@/lib/diascript-indicators"; // IndicatorCategory is defined and exported here (Task 6), not re-exported from IndicatorMenu.tsx

export function filterCatalog(
  catalog: typeof INDICATOR_CATALOG,
  search: string,
  category: IndicatorCategory | "All",
) {
  const q = search.trim().toLowerCase();
  return catalog.filter((i) =>
    (category === "All" || i.category === category) &&
    (q === "" || i.label.toLowerCase().includes(q))
  );
}

export interface IndicatorSearchModalProps {
  active: string[];
  onToggle: (name: string) => void;
}

const CATEGORIES: (IndicatorCategory | "All")[] = ["All", "Overlays", "Trend", "Momentum", "Volatility", "Volume"];

export function IndicatorSearchModal({ active, onToggle }: IndicatorSearchModalProps) {
  const [open, setOpen] = useState(false);
  const [search, setSearch] = useState("");
  const [category, setCategory] = useState<IndicatorCategory | "All">("All");
  const wrapRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(false); };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [open]);

  const results = filterCatalog(INDICATOR_CATALOG, search, category);

  return (
    <div ref={wrapRef}>
      {/* Keep IndicatorMenu's existing trigger button markup here, wired to setOpen(true) */}
      {open && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50" onClick={() => setOpen(false)}>
          <div className="bg-card border border-border w-[480px] max-h-[70vh] flex flex-col" onClick={(e) => e.stopPropagation()}>
            <input
              autoFocus
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder="Search indicators..."
              className="px-3 py-2 border-b border-border text-sm bg-transparent outline-none"
            />
            <div className="flex flex-1 overflow-hidden">
              <div className="w-32 border-r border-border overflow-y-auto">
                {CATEGORIES.map((c) => (
                  <button
                    key={c}
                    onClick={() => setCategory(c)}
                    className={`w-full text-left px-3 py-1.5 text-xs ${category === c ? "bg-secondary text-foreground" : "text-muted-foreground"}`}
                  >
                    {c}
                  </button>
                ))}
              </div>
              <div className="flex-1 overflow-y-auto">
                {results.map((ind) => {
                  const on = active.includes(ind.name);
                  return (
                    <button
                      key={ind.name}
                      onClick={() => onToggle(ind.name)}
                      role="menuitemcheckbox"
                      aria-checked={on}
                      className="w-full flex items-center justify-between px-3 py-1.5 text-sm hover:bg-secondary"
                    >
                      <span className={on ? "text-foreground" : "text-muted-foreground"}>{ind.label}</span>
                      {on && <span aria-hidden="true">✓</span>}
                    </button>
                  );
                })}
                {results.length === 0 && (
                  <div className="px-3 py-4 text-sm text-muted-foreground text-center">No indicators match.</div>
                )}
              </div>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
```

Adapt styling to match this repo's real existing conventions (read `IndicatorMenu.tsx`'s exact classNames again and mirror the color tokens/spacing scale used there — the snippet above is illustrative structure, not a pixel-exact final version).

- [ ] **Step 5: Run test to verify it passes**

Run: `cd d:/adizx/ai-trader/ai-trader-frontend && npx vitest run components/terminal/IndicatorSearchModal.test.tsx`
Expected: PASS (3 tests).

- [ ] **Step 6: Swap the render call site**

Find where `<IndicatorMenu ... />` is rendered (grep for it) and change it to `<IndicatorSearchModal ... />` with the identical `active`/`onToggle` props — no other changes needed at the call site, since the prop contract is unchanged.

- [ ] **Step 7: Manual verification**

Start the dev server, open the terminal, click the indicators button, confirm: the modal opens, search filters live, category filter narrows results, clicking a row toggles it on the chart (reuse the same manual-verification rigor as prior frontend work this session — real browser, not just "should work").

- [ ] **Step 8: Run full test suite**

Run: `npx vitest run && npx tsc --noEmit`

- [ ] **Step 9: Commit**

```bash
cd d:/adizx/ai-trader/ai-trader-frontend
git add components/terminal/IndicatorSearchModal.tsx components/terminal/IndicatorSearchModal.test.tsx
git commit -m "feat: add searchable indicator modal, replacing the small dropdown"
```

(`IndicatorMenu.tsx` itself is left in place — `INDICATOR_CATALOG` still lives there and is imported by the new modal. Only its dropdown-rendering JSX is no longer the active UI; leave the file as-is rather than deleting code that's still the source of truth for the catalog data, unless a later cleanup task explicitly separates the catalog data from the old dropdown component.)

---

## Task 13: End-to-end smoke check

**Files:** none — verification only.

- [ ] **Step 1: Run every repo's full test suite**

```bash
cd /d/adizx/diascript && npm test
cd d:/adizx/ai-trader/ai-trader-signals && pytest -q
cd d:/adizx/ai-trader/ai-trader-frontend && npx vitest run && npx tsc --noEmit
```
Expected: all green.

- [ ] **Step 2: Manual verification in browser**

Start the frontend dev server, open the terminal, use the new search modal to add at least one indicator from each of the 4 new categories (Trend, Momentum, Volatility, Volume) plus one that needed the new engine primitives (Aroon), confirm each renders correctly, and confirm toggling multiple at once doesn't evict earlier ones (the `isStack` regression this session already fixed once).

- [ ] **Step 3: Report done**

No further steps — hand off per the executing skill's normal end-of-plan step.
