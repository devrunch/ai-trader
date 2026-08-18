# Graph-Generation Subagent — Design

**Status:** Approved by user, 2026-08-18. Implementation upgrade #3 (of the three-upgrade roadmap: Signal Models / Indicator Library / Custom Graph Agent), first sub-piece.

## Goal

Let the existing chat agent (`ai-trader-signals`) author a **custom technical indicator** on request — "plot a line that's the 20-EMA minus the 50-EMA" — by writing real diascript source, validating it server-side against diascript's own parser, and handing the validated formula to the frontend to render with the exact same `registerDiascriptIndicator`/`attachDiascriptIndicator` pipeline already proven working for the built-in `DIA_EMA20`/`DIA_RSI14` indicators.

Not in scope: broader drawing actions (those already exist via `draw_on_chart`/`plot_series`), a full second agent process, or evaluating diascript on the backend (evaluation stays client-side, in the browser, exactly as it works today).

## Architecture

```
User ──▶ analyst loop() ──▶ tool call: generate_custom_indicator(description)
                                    │
                                    ▼
                    Specialized "diascript writer" LLM call
                    (own system prompt built from docs/grammar.md's
                     reserved words + primitives; writes ONLY diascript
                     source, nothing else)
                                    │
                                    ▼
                    Node subprocess: `diascript validate` (new bin,
                    shipped inside the diascript package) — real parser,
                    not a reimplementation. Checks (a) syntax parses,
                    (b) the chosen output formula is actually wrapped
                    (line/band/marker/histogram — the only 4 the
                    klinecharts adapter supports today).
                    ── invalid ──▶ ONE retry: real parse error fed back
                                   to the writer LLM, re-generate, re-validate
                    ── still invalid ──▶ tool returns a failure result;
                                   analyst reports it honestly, no chart change
                    ── valid ──▶ proceed
                                    │
                                    ▼
                    ctx.results["custom_indicators"] = {
                      name, source, outputName, displayLabel
                    }
                                    │
                                    ▼
                    (existing turn-completion path, unchanged)
                    state.to_result() ──▶ turn.results ──▶ ChatPanel
                    reads turn.results.custom_indicators ──▶ new
                    onCustomIndicator callback ──▶ registerDiascriptIndicator
                    + attachDiascriptIndicator (dynamic-imported, same as
                    today's DIA_EMA20/DIA_RSI14 registration)
```

This mirrors the existing `chart_indicators` flow exactly (`tools/chart.py`'s `add_chart_indicator` → `ctx.results["chart_indicators"]` → `orchestrator.py`'s `_emit_outputs` → `turn.results.chart_indicators` → `ChatPanel.tsx`'s `applyResult` → `onIndicators`) — same shape, new key, new frontend callback. No new transport mechanism.

## Components

### 1. `diascript` gains a `validate` CLI

New file `src/cli/validate.ts` in the diascript repo, compiled to `dist/cli/validate.js`, wired as a `bin` entry:

```json
"bin": { "diascript-validate": "./dist/cli/validate.js" }
```

Reads diascript source from stdin, calls the real `parse()` (already exported from `src/index.ts`), and additionally checks the requested `outputName` resolves to a wrapped formula (reusing `isOutputWrapper` from `src/engine/outputs.ts`, the same check `outputTypeOf` in the klinecharts adapter already does). Prints one JSON line to stdout:

```json
{"valid": true, "outputType": "line"}
```
or
```json
{"valid": false, "error": {"message": "...", "line": 3, "col": 12}}
```

Exit code 0 always (the JSON `valid` field carries the result — a non-zero exit is reserved for a genuinely broken invocation, e.g. malformed CLI args). Takes `--output <name>` as the formula to check; reads source from stdin so no temp file is needed. This is a real, reusable, publishable entry point — not a one-off script living only in `ai-trader-signals` — matching the same "ship it in the package that owns the grammar" reasoning already applied to `registerDiascriptIndicator`.

### 2. `ai-trader-signals` gains a new tool

New file `app/signals/agent/tools/graph_agent.py`, new group in `tools/__init__.py`'s `GROUPS` dict (`"graph_agent": graph_agent.TOOLS`), following the exact pattern of `chart.py`/`strategy.py`.

```python
async def generate_custom_indicator(ctx: ToolContext, args: dict) -> Any:
    description = str(args.get("description") or "")
    if not description:
        return {"error": "A description of the indicator is required."}

    source, output_name = await _write_and_validate(description)
    if source is None:
        return {"error": output_name}  # output_name carries the final error message on failure

    display_label = str(args.get("label") or description)[:60]
    indicator_name = f"DIA_CUSTOM_{ctx.results.get('_custom_indicator_seq', 0) + 1}"
    ctx.results["_custom_indicator_seq"] = ctx.results.get("_custom_indicator_seq", 0) + 1
    ctx.results.setdefault("custom_indicators", []).append({
        "name": indicator_name, "source": source,
        "outputName": output_name, "displayLabel": display_label,
    })
    return {"created": indicator_name, "label": display_label}
```

`_write_and_validate(description)` runs the specialized LLM call, then `_validate_via_node(source, output_name)`, and on failure re-runs the LLM call exactly once with the real parse error appended to its prompt. Both helpers live in the same module — this tool is self-contained, the way `build_strategy` in `strategy.py` owns its whole backtest pipeline rather than reaching into other modules.

**Schema** (added to `schemas.py`):

```json
{
  "type": "function",
  "function": {
    "name": "generate_custom_indicator",
    "description": "Write and add a CUSTOM indicator to the chart from a plain-language description — e.g. 'the 20-EMA minus the 50-EMA' or 'RSI with a 21-period length'. Use this when the request doesn't match a built-in indicator (add_chart_indicator) or a known series (plot_series). The formula is validated before it reaches the chart; if validation fails twice, this returns an error instead of a broken indicator.",
    "parameters": {
      "type": "object",
      "properties": {
        "description": {"type": "string", "description": "Plain-language description of the indicator to build"},
        "label": {"type": "string", "description": "Short display label for the chart legend, e.g. 'EMA Spread'"}
      },
      "required": ["description"]
    }
  }
}
```

### 3. The specialized "diascript writer" LLM call

A second, narrow LLM call (same Bedrock client already used by `triage()`/`loop()`, no new SDK). Its system prompt is built once at import time from a condensed version of `docs/grammar.md` in the diascript repo (reserved words, primitive list, the output-wrapper vocabulary) plus 2-3 short worked examples (an EMA spread, an RSI-based band). Explicit instructions: output ONLY diascript source implementing exactly one wrapped formula, name the formula `result`, nothing else in the response — no prose, no markdown fences. This mirrors `triage()`'s existing pattern of a single-purpose, no-tools LLM call with a narrow contract.

On retry, the same system prompt is reused and one user-turn is appended: the invalid source it just wrote, plus the real parser error string returned by the Node subprocess. No retry-count state beyond the one bounded attempt — matching `ToolRunner`'s existing `MAX_CALLS_PER_TOOL=3` philosophy of small, fixed retry budgets rather than open-ended loops.

### 4. Node subprocess validation

```python
import asyncio, json

async def _validate_via_node(source: str, output_name: str) -> dict:
    proc = await asyncio.create_subprocess_exec(
        "diascript-validate", "--output", output_name,
        stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await asyncio.wait_for(
        proc.communicate(source.encode()), timeout=5,
    )
    if proc.returncode != 0:
        return {"valid": False, "error": {"message": stderr.decode().strip() or "validator crashed"}}
    return json.loads(stdout)
```

A 5-second timeout, matching the general principle already established elsewhere in this codebase (`ToolRunner` times every call) that nothing in the request path blocks indefinitely on an external process.

### 5. Infrastructure: Node.js in the signals Docker image

`docker/signals/Dockerfile` is `python:3.13-slim` with no Node today. This is a real, new operational dependency the design is explicit about, not a hidden add:

```dockerfile
FROM python:3.13-slim AS base
...
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential curl \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g diascript@latest
```

`npm install -g diascript` pulls the real published package (same registry install already used by the frontend, no `file:`/symlink) so `diascript-validate` is on `PATH` for every stage built from `base`.

### 6. Frontend: rendering a validated custom indicator

`ChatPanel.tsx`'s `applyResult` gains one more line, mirroring the existing `chart_indicators` read exactly:

```typescript
const custom = (turn.results as ChatResults | undefined)?.custom_indicators;
if (custom?.length) onCustomIndicator(custom);
```

New prop `onCustomIndicator: (specs: CustomIndicatorSpec[]) => void` threaded through to `terminal/page.tsx`, which calls (dynamically imported, same guard as the existing `Promise.all([import("klinecharts"), import("@/lib/diascript-indicators")])` block in `CandlestickChart.tsx`):

```typescript
for (const spec of specs) {
  registerDiascriptIndicator(spec.name, {
    source: spec.source, outputName: spec.outputName,
    adapter: noopAdapter, symbolTicker: "",
  });
  chart.createIndicator(spec.name, true); // isStack: true — same fix as DIA_EMA20/DIA_RSI14
}
```

Registered indicators persist for the session (klinecharts' `registerIndicator` is module-level and idempotent by name), so a second turn referencing the same `name` is a no-op re-register, not a duplicate.

## Error handling

- Writer LLM produces unparseable source twice → tool returns `{"error": "..."}", analyst reports the failure in plain language, chart is untouched. No partial/broken indicator ever reaches `ctx.results`.
- Node subprocess missing or crashes → treated as validation failure (fails closed, never fails open into rendering unvalidated source).
- `outputName` not actually a wrapped formula → validator catches this explicitly (same check the klinecharts adapter already does), counted as a validation failure eligible for the one retry.

## Testing

- diascript: unit tests for the `validate` CLI (valid source, syntax error, non-wrapped output name) using the same `happy-dom`-free plain-Node test style as the rest of the engine tests.
- `ai-trader-signals`: unit tests for `generate_custom_indicator` with a stubbed Node subprocess (valid-first-try, invalid-then-valid-retry, invalid-twice) and a stubbed writer LLM call — no real Bedrock call in tests, matching how `triage()`/`loop()` are already tested elsewhere in this repo.
- Frontend: no new automated test (the existing chart-indicator tests don't cover live rendering either); verified manually in-browser the same way `DIA_RSI14` was confirmed working this session.

## Out of scope for this iteration

- Editing or deleting a previously generated custom indicator by name (a fresh `generate_custom_indicator` call always adds; removal is a later, separate ask).
- Any indicator output type beyond the 4 the klinecharts adapter already supports (`line`/`band`/`marker`/`histogram`) — `barcolor`/`fill` remain unsupported, same as today.
- Persisting generated indicators across a page reload independent of chat history (today's drawings already don't persist that way either, per the "kept on the message" comment in `ChatPanel.tsx`).
