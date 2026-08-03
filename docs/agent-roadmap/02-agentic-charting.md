# Agentic Charting — the answer to Pine Script

Custom indicators and custom chart drawings, described in plain language instead of written in code.

---

## 1. The concept

TradingView's Pine Script is powerful and widely used, but it is a programming language: to plot a custom indicator or mark up a chart your own way, you must learn its syntax, its quirks, and its execution model. Most traders never do.

**The agentic equivalent removes the language entirely.** The user describes what they want to see; the agent constructs it, renders it on the chart, and explains what it did.

```
"shade every zone where RSI stayed above 70 for more than 3 candles"
"mark every gap-up open with an arrow"
"plot a custom line: the 20-day high minus the 20-day low"
"draw a channel through the last three swing highs and lows"
"circle every candle where volume was 3x its average"
"colour the background red whenever ADX is under 20"
"put a horizontal line at today's high and label it"
```

None of these are expressible in the current product. All of them are ordinary Pine Script tasks — and all become one sentence here.

---

## 2. Why this is cheaper to build than it looks

**It reuses the strategy DSL's condition engine.** The [strategy engine](01-strategy-engine.md) already needs a validated way to express *"RSI(14) < 30 AND close > EMA(50)"* and evaluate it across every bar. Custom drawing needs exactly the same thing — the only difference is what happens at the bars that match:

| Shared | Strategy engine | Agentic charting |
|---|---|---|
| Condition tree over bars | → open/close a position | → draw a marker, shade a zone |

Build the condition evaluator once, use it for both. The two features are largely the same machine with different output stages.

**The chart engine already supports the primitives.** KLineChart ships 17 overlay shapes (price lines, segments, rays, rectangles, polygons, circles, channels, vertical/horizontal lines, Fibonacci) and exposes `registerOverlay`, `registerIndicator`, and `registerFigure` for anything custom. The rendering layer for this feature largely exists; what's missing is the language to drive it.

---

## 3. The visual specification (DSL)

Same principle as the strategy engine, and for the same security reason: **the agent emits a declarative JSON spec, never executable code** (see §5).

### Marker on matching bars
```json
{
  "type": "marker",
  "when": { "all": [
    { "series": "volume", "op": ">", "compare_to": { "series": "volume", "transform": "sma", "length": 20, "multiply": 3 } }
  ]},
  "shape": "circle",
  "anchor": "high",
  "style": { "color": "#e0ab4a", "size": 6 },
  "label": "volume spike"
}
```

### Shaded zone over matching ranges
```json
{
  "type": "zone",
  "when": { "indicator": "rsi", "params": { "length": 14 }, "op": ">", "value": 70 },
  "min_consecutive_bars": 3,
  "style": { "fill": "#f0525d", "opacity": 0.12 },
  "label": "overbought stretch"
}
```

### Custom plotted series ("custom indicator")
```json
{
  "type": "plot",
  "expression": {
    "op": "subtract",
    "left":  { "series": "high", "transform": "rolling_max", "length": 20 },
    "right": { "series": "low",  "transform": "rolling_min", "length": 20 }
  },
  "pane": "separate",
  "style": { "color": "#6c5ce7" },
  "label": "20-day range"
}
```

### Geometry from computed structure
```json
{
  "type": "channel",
  "from": "swing_highs",
  "count": 3,
  "extend": true,
  "style": { "color": "#8b8a9e", "dashed": true }
}
```

**Building blocks the spec can reference:**
- **Series:** open, high, low, close, volume, hl2, hlc3, typical price
- **Indicators:** the ~277 available in the existing library
- **Transforms:** sma, ema, rolling_max, rolling_min, stdev, rate-of-change, shift/lag
- **Operators:** `>`, `<`, `>=`, `<=`, `crosses_above`, `crosses_below`, `between`
- **Arithmetic:** add, subtract, multiply, divide (on series or constants)
- **Structure:** swing highs/lows, gaps, consolidation ranges, session boundaries
- **Combinators:** `all` (AND), `any` (OR), `not`, `min_consecutive_bars`

---

## 4. Rendering path

```
user sentence
   ↓  agent
validated JSON visual spec
   ↓  Python backend
evaluate conditions/expressions over the OHLCV frame  → exact coordinates
   ↓  API response
frontend renders via KLineChart overlays / registered indicators
```

**All geometry is computed server-side from real price data.** The agent never supplies coordinates — it supplies *intent*. This is the same discipline already used for support/resistance and trend lines, and it is what prevents the model from hallucinating price levels that don't exist.

---

## 5. Safety: declarative spec, never generated code

Worth restating explicitly, because "like Pine Script" invites the wrong implementation.

Pine Script is a real language, and the tempting shortcut is to have the LLM write code (Python, or a Pine-like dialect) and execute it. **That is remote code execution.** A prompt injection in a stock name, a news headline the agent reads, or simply a hallucinated line, and arbitrary code runs on the server with access to the database and every stored credential.

The declarative spec avoids this entirely: it contains no control flow, no imports, no function definitions — only allow-listed operation names and bounded numeric parameters, validated against a strict schema before evaluation. Everything in §3 is expressible; nothing dangerous is.

The one component needing genuine care is the **arithmetic expression evaluator** for custom plots (§3, "custom plotted series"). It must be a structured expression tree interpreted node-by-node against an allow-list — never a string passed to `eval()`, and never a string assembled into a pandas `.query()`/`.eval()` call. Additional bounds: maximum expression depth, maximum node count, and rejection of unknown operation names.

---

## 6. Beyond drawing: what the same engine unlocks

Once conditions can be evaluated and rendered, closely-related features become nearly free:

- **Custom alerts** — *"tell me when this condition happens"* is the same condition tree, evaluated on a schedule instead of drawn.
- **Custom screeners** — *"which of my watchlist stocks match this pattern right now?"* is the same tree evaluated across many symbols.
- **Strategy visualisation** — plot a strategy's entries/exits, which is the drawing engine consuming the strategy engine's output.
- **Saved visual templates** — *"apply my usual setup to this chart."*

This is why the shared condition engine matters: one well-built piece of machinery serves drawing, alerts, screening, and strategies.

---

## 7. Build order

1. **Condition/expression evaluator + schema validation** — shared foundation with the [strategy engine](01-strategy-engine.md); build once.
2. **Marker and zone rendering** — highest visual payoff for the effort ("circle every volume spike", "shade overbought stretches").
3. **Agent tool: `draw_custom(description)`** — natural language → validated spec → rendered, with a plain-English readback of what it drew so the user can confirm it understood.
4. **Custom plotted series** (custom indicators) — needs the arithmetic expression tree and a separate chart pane.
5. **Structure-derived geometry** — channels, consolidation boxes, gap markers.
6. **Persistence** — save and re-apply named visual templates.
7. **Condition reuse for alerts and screening** (§6).

---

## 8. Honest limits

- **Not every Pine Script program maps to a declarative spec.** Pine supports arbitrary loops, mutable state across bars, and custom functions. The DSL will cover the large majority of what traders actually draw, but genuinely algorithmic visualisations will fall outside it. That is a deliberate trade — expressiveness given up in exchange for not executing model-written code.
- **The agent will sometimes misread intent.** Ambiguous requests ("mark the important levels") need the readback step in §7.3 so the user sees what was understood before trusting it.
- **This is a visualisation and analysis capability, not a source of edge.** Drawing a zone does not make it predictive. Signal accuracy remains a separate, measured problem — see [../signal-quality/](../signal-quality/00-index.md).
