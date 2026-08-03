# 09 — Deploy Verification

**Aim:** three things are currently correct only on paper. Verify them before
anything ships.

**Status:** 2 of 3 VERIFIED (2026-07-26). The NSE holiday list remains unverified
against an authoritative source — that one needs a human with the circular.

---

## Why it matters

Each of these fails **silently**. Nothing crashes, no error appears in a log, and
the feature simply does not work — which is the worst category of deployment bug
because there is no signal that anything is wrong.

---

## End-to-end run, 2026-07-27

The whole stack built and ran (5 services healthy), and every collection and
route added for the agent work was exercised against live services rather than
fakes. It found one bug that no unit test could have:

**`upstreamBody.on is not a function`** — the SSE proxy was dead on arrival.
`fetch` returns a **web** `ReadableStream`, which has no `.on()`; the client
cast it to `NodeJS.ReadableStream` to satisfy the compiler. That cast
type-checked, passed 104 tests, and threw on the first real request. Every chat
message in the browser came back "The analysis ended before it finished" —
which was the recovery path working correctly on top of a broken transport.
Fixed with `Readable.fromWeb`, and pinned by a test that drives the client with
a real web stream instead of stubbing it.

A second, latent bug went with it: the disconnect hook was on `req`, and `req`
emits `close` once its body is consumed — which for a POST is immediately. It
would have aborted every healthy turn as soon as streaming began. Moved to
`res`, guarded on `writableEnded`.

Verified live:

| | |
|---|---|
| Python SSE direct | 4 model rounds, 14,299 tokens, 13.2s, `read_chart` fired |
| Nest proxy | events in order, `result` last, then `recorded` with the `turnId` |
| Turn persistence | answer and events stored, fetchable by id |
| Sessions | grouped, titled by the opening question |
| Daily budget | 6,743 tokens counted against the 400k cap |
| Chart layouts | save, **409 on a stale version**, first tab's drawing survives |
| Order idempotency | same key twice -> one order, cash debited once |

## Tasks

- [x] **Check for duplicate signals before the unique index builds.**
      *Done. `ai-trader-api/scripts/check-duplicate-signals.js` written and run
      against the live database: 80 signals, 0 duplicate groups, and the unique
      index `symbol_1_generatedAt_1_direction_1` is already present — so
      idempotency is genuinely active, not merely declared. Re-run before any
      deploy; `--fix` keeps the oldest row of each group.*

  A unique index on `(symbol, generatedAt, direction)` was added to make SQS
  redelivery idempotent — the same message arriving twice must not create two
  documents.

  Mongoose builds indexes **in the background**. If the collection already
  contains rows violating uniqueness, the build fails and **the failure is
  quiet**. The application starts normally, reports healthy, and has no
  idempotency at all.

  Before deploying, run the aggregation to find duplicate
  `(symbol, generatedAt, direction)` triples and clean them, then confirm the
  index actually exists with `db.signals.getIndexes()`.

- [ ] **Verify the NSE 2026 holiday calendar against the official source.**

  The dates in `app/market/calendar.py` were transcribed **from model knowledge,
  not fetched from nseindia.com**. A wrong or missing holiday means the screener
  runs against stale data on a day the market is shut, producing signals that
  look real.

  Cross-check against the published NSE trading-holiday circular for 2026.
  `holiday_calendar_known(year)` is surfaced by `/market/status`, so a *lapsed*
  list (2027 with no data) is visible — but a *wrong* 2026 list is not. Refresh
  annually; put a reminder somewhere that outlives this document.

- [x] **Actually build and run the Docker stack.**
      *Done. All five images build; `docker compose up -d` brings the stack up
      with signals and api both reaching `healthy` — the `/ready` dependency
      gate works. `/health`, `/ready`, `/api/health` and the frontend all
      return 200. `/market/status` returns live Nifty and Sensex values,
      confirming the index-symbol fix in a real container.*

  Nothing has been built or run in Docker since the refactor. Verified as correct
  syntax and correct key sets only:

  - `docker/signals/Dockerfile` — the `--workers 1` change plus the bounded
    thread pool installed in the FastAPI lifespan hook
  - `docker-compose.yml` — the dependency gate now waits on `/ready` rather than
    the constant `/health`
  - `deploy/fargate/signals-task.json` and `worker-task.json` — added
    `INTERNAL_API_KEY`, `HF_API_TOKEN`, `BEDROCK_API_KEY` via SSM, plus
    `API_SERVICE_URL`

  Run `docker compose up --build`, confirm all five services reach healthy, and
  hit `/ready` on the signals service — it probes market data and SQS, unlike
  `/health`, which is deliberately a constant so a blocked event loop cannot
  trigger a spurious container restart.

---

## Also worth confirming

- **`SIGNALS_POLLER_ENABLED`** must be `true` in the Docker/Fargate deployment
  and `false` for both Lambda functions. Two SQS consumers on one queue produces
  duplicate or lost signals. The gate is in place; the config values have not
  been exercised against a live queue.

- **WebSocket auth** now happens at connect time from the JWT cookie, and the
  server assigns the room. Never tested with a live socket client — no client
  exists in the repo yet. Test it when the frontend gains one.
