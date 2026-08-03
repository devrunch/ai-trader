# UX Flows — Delivering the Client Vision

Screen-level design for the pre-market brief, onboarding/profiling, allocation, and the weekly review. Companion to [05-delivering-client-vision.md](05-delivering-client-vision.md).

---

## 1. Information architecture — keep three tabs

The dashboard currently has **Terminal · Portfolio · Signals**. The temptation is to bolt on a fourth tab for the Morning Brief. Don't.

**The Brief *is* the signals product, properly presented.** The current Signals tab (live feed + performance + news) is raw material that the Brief curates. Folding one into the other keeps the navigation at three and avoids two competing "here are trade ideas" surfaces.

```
BEFORE                          AFTER
  Terminal                        Brief        ← daily brief + live signals + performance
  Portfolio                       Terminal     ← unchanged workspace
  Signals                         Portfolio    ← + allocation view
```

### Time-aware landing

The client's mental model is *"open the app before the market, get the day's answer."* But at 11:30 the same user wants the chart, not yesterday's brief. So the landing tab follows the clock:

| Time (IST) | Lands on | Reason |
|---|---|---|
| Before 09:15 | **Brief** | Pre-market — the day's plan is the whole point |
| 09:15 – 15:30 | **Terminal** | Market open — you're working |
| After 15:30 | **Brief** | Recap and tomorrow's prep |

If the user manually switches tabs, remember that choice for the rest of the session — smart defaults should never fight the user.

---

## 2. Flow A — The morning routine *(the core loop)*

```
07:00  Notification: "Morning brief ready — 4 candidates, cautious bias"
   │
08:45  Opens app ──> lands on BRIEF
   │
   ├─ reads "While you slept"          (global cues, 10 seconds)
   ├─ reads today's bias                (one line + confidence)
   ├─ scans candidate cards             (4 ranked ideas)
   │
   ├─ taps a candidate ──> DRILL-DOWN PANEL
   │      ├─ mini chart with entry/target/stop marked
   │      ├─ "Why this?" — the computed rationale
   │      ├─ [Ask the AI] ──> opens Terminal chat, pre-loaded with this symbol
   │      └─ [Size it]  ──> position sizing at the user's risk %
   │
   └─ [Add to today's plan]  ──> saved list, ready at open
   │
09:15  Market opens ──> app nudges to Terminal
       Today's plan sits in the right-hand panel, one tap to place each order
```

**Design rules:**
- The brief must be **readable in under 60 seconds**. Everything deeper is one tap away, never in the way.
- **No AI latency on this screen.** It was computed at 06:30. Nothing here waits on a model.
- Candidates are **capped at 5**. A list of 20 "opportunities" is noise pretending to be value.

### Brief screen

```
┌──────────────────────────────────────────────────────────────┐
│  MORNING BRIEF              Fri 25 Jul · 07:00 IST           │
├──────────────────────────────────────────────────────────────┤
│  WHILE YOU SLEPT                                             │
│   NASDAQ -0.64%   S&P +0.05%   Dow +0.46%                    │
│   Nikkei -2.73%   HangSeng -0.98%                            │
│   Crude -3.88%    USD/INR 96.56   India VIX 14.03 ▲4.1%      │
│                                                              │
│   Mixed US, weak Asia, sharp crude fall. Modest negative     │
│   bias — but crude weakness favours OMCs and paints.         │
├──────────────────────────────────────────────────────────────┤
│  TODAY'S BIAS      CAUTIOUS ／ RANGE-BOUND    confidence ●●○  │
│  Risk note: VIX +4% — size smaller than usual.               │
├──────────────────────────────────────────────────────────────┤
│  CANDIDATES (4)                                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ 1  BPCL          BUY        R:R 2.0                    │  │
│  │    entry 312.40   target 318.90   stop 309.10          │  │
│  │    Crude -3.9% overnight; BPCL 90-day beta to crude    │  │
│  │    is -0.7 — among the most crude-sensitive names.     │  │
│  │    [ Why this? ]  [ Size it ]  [ Add to plan ]         │  │
│  └────────────────────────────────────────────────────────┘  │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ 2  ...                                                 │  │
├──────────────────────────────────────────────────────────────┤
│  SECTOR VIEW                    AVOID TODAY                  │
│   Energy    ▲ positive           IT — NASDAQ weak, high      │
│   Banking   ● neutral                 correlation            │
├──────────────────────────────────────────────────────────────┤
│  Our last 30 calls: 31% hit target · +0.1% avg  [details]    │
└──────────────────────────────────────────────────────────────┘
```

That last row is deliberate. **Publishing our own hit rate on the same screen as the recommendations** is unusual, keeps the product honest, and is far better than a user discovering the real number themselves.

---

## 3. Flow B — Onboarding & profiling *(first run)*

The USP depends on knowing the user. But a wall of financial questions at signup will kill activation, so it's split: enough to be useful immediately, the rest deferred.

```
Register
   │
   ├─ STEP 1  "What are you here for?"           (1 tap)
   │      ◯ Day trading    ◯ Long-term investing    ◯ Both
   │
   ├─ STEP 2  Risk questionnaire                  (6 questions, ~60s)
   │      · age band
   │      · monthly investable surplus
   │      · time horizon
   │      · "your ₹1,00,000 falls to ₹85,000 in a month — you…"
   │      · existing investments
   │      · primary goal
   │
   ├─ STEP 3  Risk profile reveal
   │      ┌──────────────────────────────────────┐
   │      │  You are: BALANCED  (score 58/100)   │
   │      │  ●●●●●●○○○○                          │
   │      │  Why: 12-yr horizon, moderate        │
   │      │  drawdown tolerance, stable income.  │
   │      │  [ See how this was scored ]         │
   │      └──────────────────────────────────────┘
   │
   ├─ STEP 4  Proposed allocation
   │      Indian equity 45% · US equity 20% · Gold 15%
   │      Debt/cash 15%   · Crypto 5%
   │      [ Accept ]  [ Adjust ]  [ Why this mix? → AI explains ]
   │
   └─ STEP 5  Pick 5 stocks to watch  ──> lands on Brief
```

**Design rules:**
- Every step **skippable**; defaults applied and a reminder shown later. Never block a user from seeing the product.
- The risk score must be **inspectable** ("see how this was scored") — a black-box score users can't interrogate destroys trust, and reproducibility is the whole reason the engine is rules-based rather than LLM-driven.
- Step 4 is where the agent earns its place: *"why so little equity?"* answered conversationally, against a fixed allocation it did not invent.

---

## 4. Flow C — Allocation management *(inside Portfolio)*

```
Portfolio ──> [ Positions ] [ Orders ] [ Allocation ]  ← new sub-tab

┌──────────────────────────────────────────────────────────────┐
│  TARGET vs ACTUAL                       profile: BALANCED    │
│                                                              │
│  Indian equity   ████████████░░░  52%   target 45%   ▲ +7%   │
│  US equity       ████░░░░░░░░░░░  14%   target 20%   ▼ -6%   │
│  Gold            ████░░░░░░░░░░░  16%   target 15%     +1%   │
│  Debt / cash     ███░░░░░░░░░░░░  13%   target 15%     -2%   │
│  Crypto          █░░░░░░░░░░░░░░   5%   target  5%      0%   │
│                                                              │
│  Drift: 7% overweight Indian equity                          │
│  [ Rebalance suggestion ]   [ Change my profile ]            │
└──────────────────────────────────────────────────────────────┘
```

Rebalancing **suggests, never executes**. Show the specific trades that would close the drift and let the user choose. Automatic rebalancing of someone's money without an explicit instruction is exactly the kind of action that needs consent every time.

---

## 5. Flow D — Weekly review

```
Sunday 18:00 — email/notification: "Your week: +₹2,340 (+2.3%)"
        │
        └─ opens ──> WEEKLY REVIEW
              ├─ portfolio performance vs Nifty
              ├─ trades taken: 6 · won 3 · lost 3 · net +₹2,340
              ├─ OUR accuracy this week: 4 of 11 calls hit target (36%)
              ├─ behaviour note: "you held losers 2.4× longer than winners"
              ├─ allocation drift → rebalance prompt
              └─ [ Ask the AI about my week ]
```

The behaviour note is the differentiator — near-nonexistent in retail tools, and possible because we already store every trade.

---

## 6. Flow E — Drill-down: brief → agent → action

The connective tissue that makes the built agent pay off:

```
BRIEF candidate card
   └─ [ Why this? ]
        └─ opens Terminal, symbol pre-loaded, chat pre-seeded:
             "BPCL is in today's brief because crude fell 3.9%
              overnight and BPCL has a -0.7 beta to crude over
              90 days. Want me to check the levels or size it?"
           │
           ├─ user: "what's my size at 1% risk?"
           │     └─ agent calls position_size ──> "68 shares, ₹994 risk"
           │
           ├─ user: "is the setup confirmed on the 15m?"
           │     └─ agent calls get_candles + get_indicators
           │
           └─ [ Place paper order ]  ──> Trade tab, pre-filled
```

The user never re-types context. The brief hands the symbol and rationale to the agent; the agent hands a sized order to the ticket.

---

## 7. Notifications

| When | What | Why |
|---|---|---|
| 07:00 daily | "Brief ready — N candidates, {bias}" | The habit anchor the whole product depends on |
| 09:10 | "Market opens in 5 min — 2 plan items" | Only if the user saved a plan |
| Intraday | Alert triggers | Only if explicitly set |
| Sunday 18:00 | Weekly review | Reflection loop |

Cap at **one guaranteed daily notification**. A product that pings all day gets muted, and then the 07:00 brief — the one that matters — is never seen.

---

## 8. What this changes in the current build

| Area | Change |
|---|---|
| Nav | Signals tab → **Brief** (absorbs live feed, performance, news) |
| Landing | Time-aware (Brief pre/post market, Terminal during) |
| Portfolio | New **Allocation** sub-tab |
| Onboarding | New — currently users land straight in with no profile |
| Terminal | Accepts a pre-seeded symbol + chat context from the Brief |
| Notifications | New infrastructure — none exists today |

**Smallest first slice that still delivers the vision:** Brief screen (global cues + bias + candidates), the 07:00 notification, and drill-down into the existing Terminal/agent. Profiling and allocation can follow — they're the second product.
