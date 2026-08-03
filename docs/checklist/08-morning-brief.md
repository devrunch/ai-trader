# 08 — Morning Brief

**Aim:** the day's shortlist leads with its best idea, and five entries mean five
different bets.

**Status:** DONE (2026-07-26), with tests.

**Why this file matters more than its size suggests:** the brief is the client's
headline deliverable — the thing they open the app to read.

---

## What the brief is

A batch job at ~06:30 IST, after the US close and before the Indian open. It
collects overnight global cues (US indices, crude, USD/INR, Asian markets),
computes each candidate stock's historical sensitivity to those drivers, runs the
signal engine across a 25-name universe, and produces a ranked shortlist with a
short written narrative.

All numbers come from data and maths. The LLM writes only the connecting prose
and is explicitly told to invent nothing.

---

## Why it matters

### The ranking leads with its weakest input

Candidates sort **lexicographically**: first on a global-alignment score, then on
confidence. Lexicographic means the first key wins outright — the second is only
consulted on an exact tie, which floats never produce.

So the ranking is *entirely* the alignment score. A 0.66-confidence signal with a
thin beta story outranks a 0.95-confidence one, every time.

That is backwards. The alignment score is the *least* reliable input in the
system — it is built on correlations measured over ~25 days, which are not
statistically distinguishable from zero (see [10](10-phase-2-deferred.md)). The
brief is currently ranked by its noisiest signal.

### Five candidates can be one bet

The universe holds 5 banks and 4 IT companies. The alignment score derives from
overnight moves in NASDAQ, crude and USD/INR.

A single NASDAQ move gives *every* IT name a similar alignment score. They all
rise to the top together, and the user sees four apparently independent ideas
that are one position in disguise. If the read is wrong, all four lose together —
which is exactly the correlated-position problem in
[01](01-risk-limits.md), delivered by the product's own headline feature.

---

## Tasks

- [x] **Replace lexicographic sort with a weighted blend.** Something like
      `0.7 × confidence + 0.3 × alignment`, so conviction dominates and the
      global story breaks ties. Exact weights matter less than the ordering of
      importance.

- [x] **Cap at one candidate per sector.** Requires a symbol→sector map; a
      hardcoded dict over a 25-name universe is fine and honest. Note in the
      output that the cap was applied, so a user asking "why isn't INFY here?"
      has an answer.

- [x] **Say when candidates are correlated.** If the top picks share a driver,
      the narrative should say so — *"these three are the same bet on the NASDAQ
      move"* — rather than presenting them as diversification. Each candidate
      now carries a `sector` field so the data is available; the narrative
      prompt does not yet use it.

- [x] **Keep the CONFLICT flag.** When overnight drivers point against a trade's
      direction, the brief already flags it and ranks it down. Preserve that
      through any ranking change — an earlier version ranked on absolute
      magnitude and printed a SELL underneath a bullish rationale.

**Effort:** ~half a day.

---

## Files

| | |
|---|---|
| Brief generation, ranking | `ai-trader-signals/app/signals/brief.py` |
| Global cues, sensitivity | `ai-trader-signals/app/market/global_cues.py` |
| Universe | `brief.py::DEFAULT_UNIVERSE` (override via `BRIEF_UNIVERSE` env) |
| Display | `ai-trader-frontend/app/dashboard/brief/page.tsx` |
