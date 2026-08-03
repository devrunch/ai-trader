# 06 — Chart Correctness

**Aim:** nothing drawn on the chart contradicts its own label. These are errors a
user can see with their own eyes.

**Status:** DONE (2026-07-26), with tests.

---

## Why it matters

These three feed both the chart the user looks at **and** the prompt the signal
LLM reasons over. A wrong level is not just cosmetic — it propagates into where
targets and stops get placed.

### Trend lines can disagree with themselves

A trend line connects successive swing points to show direction. An **uptrend
line** joins *ascending* lows; a **downtrend line** joins *descending* highs.

`trendline()` decides "up" or "down" purely from whether price is above EMA20,
then draws a line through the last two swing lows **without checking they
ascend**. So when price is above EMA20 but the recent lows are descending, it
draws a visibly falling line and labels it an uptrend.

The user sees a line going down with the word "up" on it. That is the kind of
error that costs credibility instantly.

Two further weaknesses: two points define any line, so two touches is not
evidence of anything (three is the convention), and there is no check for whether
price has already broken through — a trend line price closed below an hour ago is
not an active support line.

### Fibonacci is drawn backwards about half the time

Fibonacci retracement measures how far price has pulled back from a move. It
needs to know **which end came first** — a move up from ₹100 to ₹120 that
retraces is a different picture from a move down from ₹120 to ₹100 that bounces.

`fibonacci()` always returns high-then-low regardless of chronological order. So
on any upward swing, the retracement is anchored backwards and the **38.2% and
61.8% levels swap places**.

The 50% level is symmetric, so it lands correctly either way — which is precisely
what hides the bug. It looks approximately right and is specifically wrong.

### Support/resistance is stale and too wide

**Support** = a price where buying repeatedly stopped a fall. **Resistance** =
where selling repeatedly stopped a rise. Both are found by clustering historical
turning points and counting touches.

Two problems:

**No recency weighting.** Levels rank purely on touch count, so a level touched
five times eight weeks ago outranks one touched twice yesterday. Old levels
decay in relevance; the ranking does not know that.

**The search radius is ±6%.** For an intraday trade with a stop around 1% away,
a level 5% distant is irrelevant — the trade will have resolved long before price
gets there. The list is padded with levels that cannot matter today.

---

## Tasks

- [x] **Validate trend line slope against its label.** Require the swing points
      to actually ascend for "up" and descend for "down". Return `None` rather
      than a contradictory line.

- [x] **Require at least three touches.** Two points always define a line; three
      is evidence.

- [x] **Reject broken trend lines.** If price has already closed through the
      line, it is no longer active.

- [x] **Order Fibonacci points chronologically** and derive direction from that,
      rather than always emitting high-then-low. **~1 hour.**

- [x] **Decay support/resistance strength by age.** Weight recent touches more
      than old ones.

- [x] **Tighten the S/R radius** from ±6% to roughly 2× the day's expected range
      (ATR-derived), so returned levels are reachable within the trade's life.

- [x] **Add regression tests.** `analysis.py` is pure — these all test easily,
      and `tests/test_analysis.py` already has the pattern. The chronological
      ordering and the slope check are two-line assertions.

**Effort:** ~1.5 days.

---

## Files

| | |
|---|---|
| All three functions | `ai-trader-signals/app/signals/analysis.py` |
| Tests | `ai-trader-signals/tests/test_analysis.py` |
| Consumers | `app/signals/prompts.py` (signal prompt), `app/signals/agent/toolbox.py` (chart drawing) |
