# Event desk — design

**Status:** proposed, 2026-09-13
**Scope:** `ai-trader-signals` (`newsd`), the NestJS API as the Telegram webhook, and
the terminal as a secondary reader.
**Supersedes:** the "hourly news pipeline" direction in `docs/architecture/README.md` §7 steps 8–9.

## Who this is for

One user, trading **forex and gold**, resident in **UAE (UTC+4, no DST)**. He is not an
Indian equity trader; NSE/BSE coverage is not the priority the earlier news work assumed.
He wants to know **what is coming that affects his positions**, with **both sides** of each
outcome, and he wants to be able to **argue with a report that is wrong**.

## What this is not

Not a news reader. Not an alerting firehose. Not advice: the output states branches and
evidence, never "buy" or "sell" — the app's own standing line is *"Analysis, not investment
advice."* He decides the trade, elsewhere, since the product's paper engine is NSE/BSE
rupee-only and cannot execute forex at all.

## The physics that shapes it

At a macro print, price moves inside the first second and spreads widen five- to twentyfold.
An LLM round trip is 2–10s. **An agent that reasons at T+0 and then speaks is structurally
late** — it advises on a move that has already happened.

So the thinking happens *before* the event, and the machine at T+0 only recognises which
pre-computed branch fired:

- **Slow path, agentic, T−2h:** research, two branches, levels, evidence.
- **Fast path, deterministic, T+0:** capture the number, compute the surprise, match a
  branch, push. No model in the path; target under two seconds.
- **Slow path again, T+10s:** the model writes the colour paragraph, after the useful
  alert has already landed.

This is the single most important decision in the document, and it is what makes a live
desk viable on a 2 GB box with a cheap model.

## Components

### 1. Event ledger — the spine, never expired

One collection, permanent. Each row is an event with everything known about it, and it
accumulates: schedule → consensus → actual → what price did.

Sources, all free:

| source | gives | cadence |
|---|---|---|
| ForexFactory calendar (scraped) | macro schedule + **consensus/forecast** + previous | daily sweep |
| FRED release dates + series | official schedule, and the history of every print | daily |
| federalreserve.gov / ECB / BoE RSS | central bank statements, minutes, speeches | continuous |
| BLS / BEA / Census release pages | the actual number, at the moment it publishes | at T+0 only |
| CFTC Commitments of Traders | positioning — the only flow signal FX has | weekly, Fri |
| `yfinance` `Ticker.calendar` | earnings date **plus consensus EPS/revenue** | on demand per symbol |

The consensus problem — a print means nothing without the expectation — is solved free for
equities (yfinance already returns `Earnings Average/High/Low`) and by scraping for macro.
Scrape first, instrument it for breakage, and buy a calendar API only if it proves flaky.
At T−2h we do not need realtime, which is what the paid tiers charge for.

### 2. Interest profile — versioned, conversational

What he tells the agent about himself is a stored artifact, not a prompt that evaporates:
free text ("I trade gold and EURUSD, I care about dollar strength and rate expectations"),
plus derived rules, plus a **corrections log**. "Arm jobless claims from now on" edits the
profile; it is not a one-off.

### 3. Selector — floor, then judgment, then audit

Runs daily over the next few days of the ledger.

- A **deterministic floor** is always armed for his instruments (CPI, NFP, FOMC, PCE,
  ECB, BoE). The model cannot filter these away.
- Above the floor, the model decides what else to arm and at what depth, from the profile.
- **Everything it declined is logged and shown**: *"skipped 6 — jobless claims (weak for
  gold), Fed speaker (no policy content)…"*

A filter that drops silently is the failure mode to design against: noisy is recoverable,
invisible is not. The skip list is what makes a miss arguable.

### 4. Researcher — one budgeted agent run per armed event, at T−2h

Inputs, in descending order of trustworthiness:

1. **Historical reaction, computed from bars we hold** — for each past instance of this
   event, the realised move at +15m and +60m, split by surprise direction. This is a
   deterministic tool, not model output.
2. **Positioning** — COT, and GLD holdings for gold. FX has *no volume* (Deriv publishes
   none), so positioning is the only flow signal that exists here. It outranks news.
3. **Consensus and previous** — from the ledger.
4. **Previews and analyst views** — Tavily search, already wired. Labelled as opinion.
5. **Current levels** — from our own bars.

Output is two branches with numbers, and **every claim carries its provenance** — which
nine prints, which COT report, which article. That is what makes "this report is wrong"
a conversation with evidence rather than two parties guessing at what the machine meant.

Retail sentiment (Reddit, X) is colour at most, explicitly labelled. For macro it is noise,
and presenting it as signal is how you get confidently wrong.

### 5. Delivery — Telegram, with buttons

A webhook through the existing public API (Caddy and TLS are already there; NestJS forwards
to a signals internal endpoint). Long-polling would hold a socket open inside a
memory-capped process for no benefit.

- **T−2h brief** with `[Arm] [Why?] [Wrong →] [Skip]`
- `Arm` stores the branch levels for the fast path
- `Why?` returns the evidence behind that specific claim
- `Wrong →` takes free text, stored as a correction against that event type, which later
  briefs must account for

### 6. Live matcher — phase B

Poll the agency endpoint from T−5s, capture, compute surprise, match branch, push. Four
deterministic steps, target < 2s end to end. Model output follows afterwards.

### 7. Outcome — what makes it improve

At T+60m: the actual, the realised move from our own bars, which branch fired, and how the
brief's estimate compared. Appended to the ledger row. This both sharpens component 1 and
catches the system being systematically wrong, which is otherwise unfalsifiable.

## The history problem, and why it is urgent

`DerivProvider.capabilities` declares `max_days_by_interval={"1m": 7, ...}`. **Our live
vendor keeps 1m bars for seven days.** A 60-minute reaction study across a year of CPI
prints cannot be computed from it — 1h reaches a year, but an 08:30 print sits mid-bar.

Two consequences:

1. **Capture from day one.** For every event, store the 1m window T−30m…T+120m permanently.
   In six months this is a real dataset that no vendor sells us.
2. **Bootstrap from Dukascopy.** It was removed as a *live volume* source because it
   publishes ~15 minutes late. That objection does not apply to a study of prints from last
   year, it holds years of 1m FX and metals data, and `app/market/providers/dukascopy_bridge.py`
   already exists. Rejecting it for live use and reusing it for history is consistent, not
   a reversal.

Until the captured dataset is deep enough, briefs state their own basis honestly:
*"n=9, from 1h bars"* rather than implying precision we do not have.

## Data model

```
events            event_key, title, scheduled_at, importance, markets[], symbols[],
                  consensus, previous, actual, source, provenance[]        (permanent)
event_windows     event_key, symbol, bars[]  (1m, T−30m…T+120m)            (permanent)
briefs            event_key, branches[], claims[{text, evidence_ref}],
                  armed_at, armed_levels                                    (permanent)
outcomes          event_key, actual, surprise, realised_15m, realised_60m,
                  branch_fired, brief_estimate                              (permanent)
profile           user_id, text, rules[], corrections[], version            (permanent)
articles          canonical_url, title, excerpt, published_at, source       (TTL 7d)
```

Everything except `articles` compounds in value and is small — a few thousand rows a year.
Articles are the only thing worth expiring, and 7 days is generous for something nothing
reads twice.

Storage goes through the existing internal endpoints (**pipeline-then-read**). The earlier
argument for giving `newsd` its own Mongo connection was justified by a firehose of thousands
of articles a day; this design does not build that first, so the exception is not taken.

## Cost

Daily selection 2–5k tokens. Per-event research 10–20k. At ~10 armed events a week on
DeepSeek V3.2, **under $0.25/month** — the budget debate turned out to be an artefact of the
firehose design, not this one. Scraping is free. The only candidate spend is a calendar API
if the scrape proves unreliable, and that decision waits for data.

## Phasing

1. **Ledger + scraped calendar + yfinance earnings.** Provable: tomorrow's events, with
   consensus, in his timezone.
2. **Event window capture + Dukascopy backfill.** Provable: "gold's last 9 CPI reactions" as
   a number.
3. **Selector + profile + skip log.** Provable: a daily agenda he can argue with.
4. **Researcher + Telegram brief with buttons.** Provable: the T−2h brief, armed.
5. **Outcome capture.** Provable: the brief scored against what happened.
6. **Live matcher (phase B).** Provable: sub-2s branch push.

Each step is useful alone, and steps 1–2 are useful even if every later step is abandoned.

## Risks

- **The scrape breaks silently.** Mitigated by per-source health with an item-rate baseline:
  a calendar returning 200 and no events is broken, not quiet.
- **Selection misses something that mattered.** Mitigated by the floor set and the visible
  skip log, never by trusting the model's judgement alone.
- **Branches become horoscopes.** Mitigated by grounding every magnitude in the measured
  distribution, and by the outcome record making systematic error visible.
- **He does not engage at T−2h.** The whole design rests on him seeing branches before the
  event. If arming goes unused for a few weeks, the live matcher is not worth building —
  check this before phase 6, not after.

## Open questions

1. Which instruments are armed by default beyond XAUUSD — EURUSD, GBPUSD, USDJPY, DXY?
   Arming everything dilutes the brief.
2. Do stock events (earnings for a name he asks about) deliver through the same Telegram
   brief, or stay in the terminal?
3. Is the corrections log global or per event type? Per type is more precise; global is
   simpler and he is one user.
