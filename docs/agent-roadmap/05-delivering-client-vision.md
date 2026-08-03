# Delivering the Client Vision — What to Add, and in What Pattern

The client's vision needs four *different* delivery patterns. Choosing the wrong one for each piece is the main way this goes wrong.

---

## 1. The key architectural insight

**The client's core product is a publication, not a conversation.**

> *"Check the best available trades for that day before the market opens and execute them as the market opens."*

That describes a user opening the app at 08:45, seeing **the answer already there**, and acting on it. Not typing a question and waiting 15 seconds for an LLM. If the day's trades require prompting, the product has failed its own mental model.

This does not diminish the agent we built — it repositions it. **The report is the headline; the agent is the drill-down.** "Why is RELIANCE on today's list?" is exactly what the agent is now good at.

Match the pattern to the need:

| User need | Wrong pattern | Right pattern |
|---|---|---|
| "What do I trade today?" (08:45) | Chat — user must ask, then wait | **Pre-computed daily report** |
| "Why this stock? What's my size?" | Static report | **Interactive agent** (built) |
| "How should I split my money?" | LLM improvising allocations | **Deterministic rules engine**, LLM explains |
| "How did I do this week?" | User must remember to ask | **Scheduled digest** |
| "Alert me if X happens" | Polling the chat | **Background monitor** |

---

## 2. Component 1 — Overnight Research Pipeline *(the missing core)*

**Pattern:** scheduled batch job. No user in the loop.
**Runs:** ~06:30 IST — after the US close (02:00 IST), well before the Indian open (09:15).

The client's specific thesis is that *the US session and overnight global events drive the Indian open*. That is a real, tradeable relationship, and **all the data needed is already available free** — verified working:

| Input | Symbol | Why it matters |
|---|---|---|
| NASDAQ / S&P / Dow | `^IXIC` `^GSPC` `^DJI` | The overnight US session the client's thesis rests on |
| Nikkei / Hang Seng | `^N225` `^HSI` | Asian markets open *before* India — the closest leading signal |
| USD/INR | `USDINR=X` | Currency pressure, FII flow proxy |
| Brent crude | `BZ=F` | Direct driver of Indian energy, paints, aviation, OMCs |
| Gold | `GC=F` | Risk-off gauge |
| India VIX / US VIX | `^INDIAVIX` `^VIX` | Fear gauges; VIX spikes justify sitting out |
| Nifty | `^NSEI` | Prior close, gap context |

**Worth adding when data allows:** GIFT Nifty (the single best predictor of the Indian open, trading nearly 24h) — not reliably on the free feed, and a strong argument for a paid data subscription later.

**Pipeline stages:**
1. **Collect global cues** — the table above.
2. **Overnight news + macro scan** — headlines since the previous Indian close; the existing FinBERT sentiment path extends naturally here (needs the news API key activated).
3. **Compute each stock's historical sensitivity** to US/global moves (a rolling beta to NASDAQ, crude, USD/INR). This is the part that turns "NASDAQ fell 1%" into "*your* stocks likely open like this" — deterministic maths, not an LLM guess.
4. **Generate candidates** across the universe, on a daily/positional timeframe rather than 15-minute.
5. **Rank and assemble** into a stored Morning Report document.

**Why batch rather than agentic:** it must be *finished* before the user looks, it's identical for every user (so compute once, not per-request), and it can afford to be slow and thorough at 06:30 in a way a chat reply cannot.

---

## 3. Component 2 — The Morning Report *(the product surface)*

**Pattern:** a stored document, rendered as a page and pushed as a notification. Ready before 09:00.

Structure, mapped to what the client described:

```
MORNING BRIEF — Friday 25 July, 07:00 IST

WHILE YOU SLEPT
  NASDAQ -0.64% · S&P +0.05% · Dow +0.46%
  Nikkei -2.73% · Hang Seng -0.98%
  Crude -3.88% · USD/INR 96.56 (-0.33%) · India VIX 14.03 (+4.1%)
  Read: mixed US, weak Asia, sharp crude fall. Modest negative bias,
        but crude weakness favours OMCs, paints and aviation.

TODAY'S BIAS
  Cautious / range-bound.  Confidence: moderate.

TOP CANDIDATES
  1  BPCL      BUY   entry 312.4  target 318.9  stop 309.1  R:R 2.0
     Crude -3.9% overnight; BPCL's 90-day beta to crude is -0.７.
  2  ...

SECTOR VIEW           AVOID TODAY
  Energy      positive    IT — NASDAQ weak, high correlation
  Banking     neutral

RISK NOTE
  India VIX up 4% — size smaller than usual.
```

Every number here is computed. The LLM writes the *narrative*, never the figures.

---

## 4. Component 3 — The agent as the drill-down layer *(reuses what's built)*

The agent stays, and becomes more useful because the report gives it something to talk about. Add four tools:

| New tool | Enables |
|---|---|
| `get_morning_report()` | "Why is BPCL on today's list?" · "Summarise this morning's brief" |
| `get_global_cues()` | "What's driving the market today?" |
| `get_user_profile()` | Advice tuned to the user's stated risk appetite |
| `explain_allocation()` | "Why am I 60% equity?" |

This is the natural division of labour: **the pipeline decides, the agent explains.**

---

## 5. Component 4 — Profile & Allocation engine *(the stated USP)*

**Pattern: a deterministic rules engine. Explicitly *not* an LLM deciding allocations.**

This matters. If the same user profile can produce different allocations on different days because a model sampled differently, the product is not defensible — not to a user, not to a regulator, not to itself. Allocation must be reproducible and auditable.

**Flow:**
1. **Questionnaire** — age, income, savings, monthly investable surplus, time horizon, drawdown tolerance, existing commitments, goals.
2. **Risk score** — a transparent weighted model. The user can see why they scored what they scored.
3. **Allocation model** — score maps to a band (conservative → aggressive), each band mapping to target weights across asset classes. Standard practice, and defensible precisely because it is boring.
4. **LLM explains** — turns the allocation into plain language, answers "why so little in equity?", and flags when the user's goals and risk tolerance conflict.

**Scope honestly, by data availability:**

| Asset class | Feasibility |
|---|---|
| Indian equity | ✅ Have it |
| US equity | ✅ Data available free |
| Gold | ✅ Via `GC=F` / gold ETFs |
| Crypto | ✅ Data widely available free |
| Forex | ⚠️ Data yes; as an *investment* class for retail, questionable |
| Mutual funds | ⚠️ Needs an AMFI NAV feed — available, but new integration |
| Real estate | ❌ No meaningful price feed; at best REITs as a proxy |

Recommend building **equity + US equity + gold + crypto + REIT-proxy** and being explicit that direct real estate is out of scope, rather than faking it.

---

## 6. Component 5 — Weekly digest

**Pattern:** scheduled job → email/notification. Reuses the report renderer.
Contents: portfolio performance, signal accuracy for the week (honest numbers), what the pipeline got right and wrong, allocation drift vs target.

Publishing our own hit rate weekly is unusual and builds real trust — and we already have the measurement framework to do it.

---

## 7. Build order

1. **Global cues collector + Morning Report skeleton** — highest visible payoff, all data verified available. Turns the product into what the client described.
2. **Sensitivity/beta engine** — makes the US→India link genuine analysis rather than assertion.
3. **Daily-timeframe signal generation** — current logic is 15-minute; pre-market calls need daily/positional framing.
4. **Report page + morning notification.**
5. **Agent report tools** (§4) — small, high leverage.
6. **Profile questionnaire + risk score + allocation engine** (§5) — the USP; largest new surface.
7. **Weekly digest.**

Items 1–5 make the *signals* product match the vision. Item 6 is the *advisory* product and is effectively a second product sharing a login.

---

## 8. Two things to keep honest

- **Signal accuracy still sits near breakeven** ([findings](../signal-quality/01-findings.md)). A morning report presented as "today's profitable trades" would overstate what we can currently demonstrate. Frame it as analysis and candidates, keep publishing real hit rates, and fix expectancy in parallel.
- **A pre-market report implies overnight data quality.** Free delayed feeds are adequate for direction and context; if the product's headline promise becomes the morning brief, a paid feed (including GIFT Nifty) becomes a real requirement rather than a nice-to-have.
