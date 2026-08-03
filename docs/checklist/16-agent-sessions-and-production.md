# 16 — Agent Sessions, Orchestration and Production Hardening

**Aim:** an agent turn that is *durable, cheap, bounded and accountable* — the
session survives a reload, every accepted trade can be traced back to the
reasoning that produced it, and one turn's cost is known and capped.

**Why it matters:** today a chat turn leaves no trace. If a user takes a trade
the agent suggested and it goes wrong, there is no record of what the agent
looked at, what it said, or at what price. That is the difference between a
demo and a product. Everything else in this file is what makes that record
affordable to produce.

Opened after the event stream was built (`app/signals/agent/events.py`), which
is the foundation the rest depends on.

**Done so far — the signals service only.** The agent package was restructured
into sixteen files (largest non-data file: 179 lines, down from a 417-line
toolbox and an untested 143-line orchestrator function), and the token,
memoisation and call-cap controls landed with it. 227 tests pass, ruff and mypy
clean. Sections A, E and F, and everything outside `ai-trader-signals`, are
untouched.

---

## A. Durable sessions — the reason this file exists

Nothing about a turn currently survives the request:

| What | Lives in | Survives reload |
|---|---|---|
| Chat history | `terminal/page.tsx` React state | no |
| Agent chart overlays | KLineChart, `groupId: "ai"` | no |
| User's own drawings | KLineChart, `groupId: "draw"` | no |
| Event stream for a turn | returned in the response, dropped | no |
| Strategy runs | inside the event stream, dropped | no |

- [x] **`chat_turns` collection** — `src/chat/`, owned by Nest like every other
      collection. One document per turn, written once and never modified: no
      read-modify-write, no unbounded array, and a single turn is fetchable by
      id without loading a session. Recording is idempotent on `turnId`, and a
      failed write never costs the user their answer — the turn is already paid
      for.
- [x] **Sessions, without a second collection.** A turn carries its
      `sessionId`, assigned server-side by grouping consecutive turns on the
      same symbol within two hours. Server-side because a client-supplied
      session id would let one user append turns to another's conversation.
      `GET /api/chat/sessions/latest/:symbol` is what the terminal reloads.
- [x] **Retention decided.** No TTL: the events are the evidence behind a
      trade, and "why did I take this" is asked most often long after any
      window we would pick. Size is bounded at write instead — an event stream
      over 200 entries keeps its head and tail with an honest marker between.
- [x] **`chart_layouts` collection** — `src/chart-layouts/`. One document per
      user and symbol, replaced wholesale: a chart is small and is always read
      and written as a unit, so storing overlays individually would buy nothing
      and cost a race. Covers the user's own drawings and the agent's marks
      alike — the same data with a different `groupId`. Drawings are stored
      opaque: this service does not interpret a chart library's overlay format,
      and a second definition of it here would drift from the real one.
      Saved debounced by `lib/use-chart-layout.ts`, restored once the chart
      instance exists — restoring into a null ref draws nothing, silently.
- [x] **Strategy runs, without a second collection.** `GET /api/chat/strategies`
      reads `strategy_run` events out of the stored turns — the run, its rules
      and its trades were already recorded there, and a separate table would be
      a second thing to keep in sync. Each row carries the question that caused
      it: a row that only says "8 trades" cannot tell the user why it was run.
- [ ] **Saved strategies, as distinct from runs.** A user naming a spec and
      re-running it later is a different feature from the history of what was
      run. Needs its own collection; not started.
<!-- Retention was a duplicate of the decided item above; resolved there. -->

### The audit trail — "why did I take this trade?"

- [x] **Every turn gets a `turnId`**, minted in the signals service at turn
      start and carried on `turn_started` — so the streamed path, the buffered
      path and the stored record all name the same turn, and a client watching
      the stream knows the id before the turn ends. Time-prefixed so a lexical
      sort is chronological; random-suffixed because a turn id addresses
      another user's reasoning and a counter would leak it.
- [x] **`PlaceOrderDto` accepts an optional `decisionTurnId`**, stored and
      indexed on the order, so the reverse question — "which trades came out of
      this analysis" — is also answerable. `OrderPrefill` carries it through the
      ticket, set only when the prefill genuinely came from the agent:
      attaching it because a chat happened to be open would attribute a manual
      trade to advice that was never taken.
- [x] **Trade detail shows the reasoning.** The Orders table has a **Why**
      column linking to `/dashboard/strategies/<turnId>`, which renders
      `TurnRecord`: what was asked, what the agent looked at with timings, what
      it concluded, and why the turn stopped if it was cut short. Rendered from
      the recorded events, never from a re-run — a re-run would produce a
      different answer on different prices and quietly rewrite history.
- [x] **Orders without a `decisionTurnId` say "Manual"** rather than leaving a
      blank cell, which reads as a panel that failed to load.
- [x] **The affordance that sets the link.** A simulated trade in the chat gets
      "Take this to the order ticket", which carries the turn id into
      `OrderPrefill` and from there onto the order. This is the *only* producer
      of `decisionTurnId`: pressing it is the user saying they acted on this
      analysis.

---

## B. Orchestration — the loop is one function doing seven jobs

`app/signals/agent/orchestrator.py::run_chat` currently does: prompt assembly,
history trimming, budget enforcement, the LLM loop, tool dispatch, the
fallback summarise call, event emission, and result assembly. It has no seam
for persistence, no token accounting, and no way to resume.

- [x] **Split into named phases.** `TurnState` (`agent/turn.py`) threaded
      through `prepare -> loop -> finalise` in `agent/orchestrator.py`. The
      turn had **no tests at all** before this; it now has 20.
- [x] **A `Budget` object** (`agent/budget.py`) holding rounds, wall clock
      **and tokens**, with one `exhausted()` reason. The wrap-up call is
      deliberately not charged against the round budget — it is the turn's
      conclusion, not more research.
- [x] **A `ToolRunner`** (`agent/runner.py`) owning dispatch, timing, error
      policy, recording, per-turn call caps and result memoisation.
      `AgentToolbox` is now 67 lines of composition.
- [x] **A `TurnStore` seam** (`agent/store.py`). `finalise()` hands every turn
      to it, after the closing events, so what is stored is the whole turn. The
      default keeps nothing — NestJS owns every collection in the product, and a
      second writer would mean two systems owning one document. What the seam
      buys is that a new caller (a Celery task, a scheduled brief) *inherits*
      persistence instead of having to remember it. A failing store is logged
      loudly and never costs the user their answer: the turn is complete and
      already paid for by then.

### God files to split (measured)

| File | Lines | Holds |
|---|---|---|
| `ai-trader-api/src/portfolio/paper-trading.service.ts` | 811 | orders, fills, positions, P&L, risk gates, portfolio lifecycle |
| `ai-trader-frontend/app/dashboard/terminal/page.tsx` | 766 | chart, drawing tools, watchlist, chat, order ticket, indicators, polling |
| `ai-trader-frontend/app/page.tsx` | 559 | whole marketing page |
| `ai-trader-frontend/lib/api.ts` | 524 | every endpoint and every type |
| `ai-trader-signals/app/signals/agent/toolbox.py` | 417 | 17 tools in one class |

- [x] **`ChatPanel` lifted out of `terminal/page.tsx`** (766 -> 663 lines), with
      `ChatMessage` and `AgentProgress` beside it and the streaming client in
      `lib/chat-stream.ts`. It now owns three things the page has no reason to
      know about: a streamed turn, the live progress feed, and restoring the
      last conversation.
- [x] **`SignalPanel` and `PositionsPanel` extracted** from `terminal/page.tsx`
      (663 -> 598). The signal panel earns its own file: its four states —
      running, failed, nothing found, and a signal — were four nested ternaries
      mid-page, and collapsing any two shows the user the wrong thing.
- [x] **`DrawingToolbar` and `IndicatorMenu` extracted** (766 -> 551 lines
      across the whole effort). The indicator menu owns its own open state and
      dismissal, because how a dropdown closes is a fact about the dropdown, not
      about the terminal — the page had been running one shared click-outside
      handler for two unrelated menus. The tool and indicator catalogs moved
      with their components: both describe what KLineChart can draw, which is
      the component's subject and not the page's.

      What is left inline is the top toolbar (symbol search, price, period) and
      the chart column. Both are genuinely coupled to the page's state — pulling
      them out would mean threading a dozen props to move markup, which is
      motion rather than progress. Left deliberately.
- [x] **`toolbox.py` -> `tools/{market,account,strategy,chart}.py`** with a
      registry (`tools/__init__.py`) and a shared `ToolContext` (`tools/base.py`)
      that also memoises the frame fetch — three tools asking for the same 15m
      series used to mean three network round-trips inside one chat request.
      Largest tool module is now 151 lines.
- [x] **`paper-trading.service.ts` split** (811 -> four files, largest 248).
      Divided along failure modes: nothing in `portfolio-accounts.service.ts`
      moves money, so a bug there shows a wrong number, while a bug in
      `order-execution.service.ts` *is* a wrong number — that file is now the
      smallest of the three. `risk-limits.service.ts` holds the limits and the
      gate. All 26 tests pass with **assertions byte-identical**; only the
      wiring in `setup()` changed, and running them against the real
      collaborators rather than mocks is what makes them evidence the split was
      safe.
- [x] **`lib/api.ts` -> `lib/api/`, one module per domain** (769 lines ->
      largest 136). Re-exported from `index.ts`, so `@/lib/api` resolves the
      same and **no call site changed**. `client.ts` is now the only file that
      touches `fetch`: timeout, credentials and error mapping have one home
      rather than eighty.

---

## C. Token overload — cost per turn is currently unknown

Measured, not estimated:

- `TOOL_SCHEMAS` serialises to **9,039 chars (~2,260 tokens)** and is resent on
  **every** round. At the 6-round cap that is **~13,500 tokens of schemas in one
  turn**, before a single candle. (An earlier draft of this file said ~3,400
  tokens; that was the length of `schemas.py` on disk, which counts Python
  syntax and comments that are never sent.)
- Tool results are appended with `json.dumps(result)` and **never trimmed**.
  `get_candles` returns up to 60 bars (~1,400 tokens) and the model may call it
  several times in one turn.
- Nothing counts tokens. No turn records usage. Cost per turn is not just
  uncapped — it is unmeasured.

- [x] **Record usage per turn.** `Budget.record()` folds `resp.usage` from every
      call; the totals ride in the result as `usage` and on the
      `turn_finished` event. A provider that omits `usage` is tolerated — the
      call count still increments, so the gap is visible rather than silent.
- [x] **A token budget in `Budget`** (`chat_token_budget`, 60k), alongside
      rounds and wall clock. Blowing it takes the same wrap-up path as the
      clock.
- [x] **Oversized tool results are trimmed** (`agent/transcript.py`). Beyond
      `max_tool_result_chars` a result keeps every scalar — those are the
      findings — and long lists are cut to three items plus a count, with a
      note telling the model not to re-request them.
- [x] **`get_candles` trimmed at the source** — `MAX_CANDLES` 60 -> 30. A larger
      request is not silently cut: it returns the 30 most recent bars in full
      **plus a `range` summary of the window that was actually asked for**
      (bars, from/to, high, low, open, close, change). Returning a third of a
      window without saying so lets the model reason as though it had the lot.
- [x] **A whole-transcript ceiling** (`Transcript.max_total_tokens`, a quarter
      of the turn's token budget — the transcript is resent every round, so
      letting it reach the full budget would spend the budget on one round).
      Oldest tool results are shed first: the model has already reasoned over
      them and its later messages carry what it concluded, whereas the newest
      result is the one it is about to use. Shedding stops the moment it fits,
      and never touches the system prompt, the question, or the model's own
      turns — dropping those would change what was asked.
- [x] **Per-user daily spend cap** (`chat/chat-budget.service.ts`,
      `CHAT_DAILY_TOKEN_CAP`, default 400k tokens ≈ 15–25 turns). Enforced in
      Nest because this is about a *user* and the JWT is here; the signals
      service's budgets bound one turn, not one person's day. Summed from the
      `usage` already stored on each turn, so it needs no new bookkeeping.
      Checked **before** the turn on both the buffered and streamed routes —
      the cost is incurred upstream the moment the request is made, and a limit
      reported inside a stream is a limit the client must learn to read.
      Resets at midnight IST, not at the market open: people use the agent
      before the bell and after the close, and "come back tomorrow" should mean
      tomorrow. A failure to *read* the budget allows the turn — a Mongo hiccup
      locking everyone out of the main feature is worse than one uncounted
      turn. `GET /api/chat/budget` exposes the remainder so the UI can warn on
      approach rather than only report the wall.

---

## D. Over-tooling

- [x] **Stop sending 17 schemas on every round** (`agent/offers.py`). Gated on
      **facts, never on a guess at intent**: a keyword rule that hid
      `build_strategy` because the question did not say "backtest" would
      silently disable a tool the model was about to need, and the failure would
      look like the model being unhelpful. Two facts qualify — there is no
      authenticated user, so the account tools can only fail (17 -> 10 tools,
      **~700 tokens saved per round, ~4,200 per turn**); and a tool has used its
      per-turn budget, so offering it costs tokens to advertise something that
      can only be refused. Never advertises an empty list: `tool_choice="auto"`
      with no tools is not a meaningful request.
- [x] **Memoise identical `(tool, args)` within a turn** (`agent/runner.py`).
      Argument order does not defeat the cache; failures are never cached,
      because a fetch that failed once may succeed on the retry; and the cached
      copy cannot be mutated by its caller. A repeat is not a progress line but
      does stay in the transcript — "the model asked twice" is worth knowing
      when reading a turn back.
- [x] **Per-tool call caps** (`max_calls_per_tool`, 3). Hitting the cap returns
      an error that tells the model to answer or try a different tool — a
      silently dropped call teaches it nothing, so it just loops. Cached
      repeats do not burn the budget.
- [x] **`read_chart` combines `get_indicators` and `get_levels`.** They were
      asked for separately on almost every turn, and a *round* is the expensive
      unit — each one resends the whole transcript and every schema. Combined,
      not merged: both halves keep their own shape, they run concurrently, and
      one failing does not take the other with it (levels need fewer bars than
      indicators do). The old tools stay for the cases that genuinely want one.
      Costs ~150 tokens of schema to save ~2,400 plus a transcript.

---

## E. Idempotency

The signals ingest path is already idempotent (`signal.schema.ts` dedupe key +
`isDuplicateSetup`) — that is the pattern to copy. Three places are not:

- [x] **`UpstreamHttpClient` no longer retries POST by default.** GET retries;
      POST must opt in via `retryOnNetworkError`, which only `/signals/evaluate`
      does — a pure computation that publishes and stores nothing. A socket
      timeout on `POST /signals/chat` used to replay a whole LLM turn.
- [x] **`placeOrder` takes a `clientOrderId`.** Unique partial index on
      `(userId, clientOrderId)` — enforced in the database, because two
      concurrent requests can both pass an application-level check. A repeat
      returns the original order *including its fill*, so a retrying client sees
      the price it actually got rather than an order that looks unexecuted.
      The frontend mints one id per order **intent**, and keeps it across a
      retry only when the outcome is genuinely unknown (network error or
      timeout) — reusing it after a definitive rejection would return that
      rejection forever, and the user could never retry a blocked order.
- [x] **A dropped stream no longer loses a turn that was paid for.** Not
      "attach to the live tail" as originally sketched — there is no live tail,
      because the proxy deliberately aborts upstream when the client hangs up
      rather than paying for an answer nobody will read. What remained was the
      case that actually costs money: the turn *did* finish (or was recorded as
      cancelled with its partial events) and the socket died before the client
      saw it. The client now captures the `turn_id` from the first event and,
      if the stream ends without a result, asks for the stored turn before
      declaring it lost. Best-effort by design: a failed lookup surfaces as the
      original "the stream broke", not as a second error about a request the
      user never made.
- [x] **Chart layout saves carry a version**, and a stale one is rejected with
      409 rather than applied. Not last-write-wins in the end: the losing tab
      would never learn its drawings were gone, and silent data loss is the
      worst outcome available. The client stops auto-saving on conflict and says
      so, so the user can choose which version to keep.

---

## G. The live stream, end to end

- [x] **NestJS passes it through.** `UpstreamHttpClient.stream()` returns the
      body unread — `request()` ends in `await res.json()`, which waits for a
      complete body, exactly what a stream does not have. `ChatStreamController`
      forwards each chunk **verbatim** while parsing a copy: re-encoding a frame
      we only half-understood is how a proxy corrupts a stream that was fine.
      It keeps the JWT check and the user_id injection, aborts upstream when the
      client hangs up, and after the last event records the turn and emits a
      `recorded` event carrying the `turnId`. Its own controller, because it
      takes over the response object and cannot use the interceptors every other
      route relies on.
- [x] **SSE framing is tested separately** (`common/http/sse.ts`). The boundary
      problem is the whole job: a network chunk has nothing to do with an event
      boundary, so one may hold three events or a third of one — including a
      split that lands inside the `\n\n` separator.
- [x] **The browser consumes it** (`lib/chat-stream.ts`). Returns an abort
      function; calling it closes the socket, which cancels the turn server-side
      rather than paying for an answer nobody will see. A stream that ends
      without a result raises rather than silently showing nothing.
- [x] **The spinner is gone.** `AgentProgress` renders each step as it lands,
      ticked when it finishes and timed when it took over 400ms, inside a polite
      live region. "Thinking… (up to 15s)" was wrong twice over — the real
      budget is 55 seconds, and the user learned nothing during it.
- [x] **A reload no longer loses the conversation.** `ChatPanel` restores the
      last session for the symbol on mount, and is keyed by symbol so switching
      resets the messages, the progress feed and any in-flight turn together.

- [x] **Deployment settled: a VM, not Lambda.** Behind API Gateway + Lambda the
      response is buffered whatever the headers say and the route would degrade
      to a slow `POST /chat` — correct, but not live. Deploying to a VM keeps
      the stream a stream. Recorded here because it is now a constraint on where
      this can run, not a preference.
- [x] **The strategies tab exists** — `/dashboard/strategies`, in the main nav.
      Each run shows what was asked, the rules, and every trade with when it
      opened, when it closed and **why**: "Exit rule" versus "Stop hit" is the
      distinction a win rate hides, and a strategy whose losses are all stops
      behaves nothing like one whose losses drift out. Runs under 30 trades are
      labelled a sketch rather than a result.

---

## F. Production hygiene, still open

- [x] **The turn document holds no raw prompt and no chain-of-thought** — the
      question, the answer, the events and the usage, and nothing else. True by
      construction rather than by filtering: the transcript never leaves
      `Transcript`, `thinking` events carry no content, and the model's
      partial prose is a local fallback that is never recorded. Worth keeping
      that way: support will read these one day.
- [x] **No compression middleware on the stream route.** The Nest app installs
      none at all (`bootstrap.ts`), and the route sets
      `Cache-Control: no-cache, no-transform` alongside `X-Accel-Buffering: no`
      — the standards-track half of the same instruction.
- [x] **Backpressure on the SSE queue** (`SSE_MAX_PENDING`, 200 — well above a
      normal turn's dozen or two, so it only bites when something is wrong).
      The turn never waits on its reader: a slow client would otherwise slow
      the analysis it is watching. Progress events are shed, since each is
      superseded by the next; the `result` does not travel that path and cannot
      be lost this way.
- [x] **Heartbeat** (`SSE_HEARTBEAT_SECONDS`, 15). A comment frame, which every
      SSE client ignores, so no consumer had to change. One LLM round can take
      tens of seconds with nothing to report, and idle proxies close a silent
      connection at 30–60s — inside a turn's own budget.
- [x] **Cancellation is observable.** The stream proxy accumulates events as it
      forwards them, and if the client hangs up before a `result` arrives it
      writes the partial turn with `stopReason: 'cancelled'`. Without it the
      spend was invisible twice over — no trace for support, and no contribution
      to the daily budget, which is summed from stored turns, so abandoned turns
      would have been free. Recording is idempotent on `turnId`, so `end` and
      the socket closing can race without creating two documents. The answer
      says "Stopped before this analysis finished" rather than being empty,
      which would read as the agent having nothing to say.
