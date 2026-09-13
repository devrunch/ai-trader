# AI Trader — work checklist

The single list of what we're doing, in order. Claude keeps it current: when an item ships, it's ticked with the date and the commit or evidence that proves it works. Nothing is ticked on "should work".

**Status:** `[ ]` to do · `[~]` in progress · `[x]` done · `[-]` dropped (with the reason)
**Background:** [How it works](how-it-works/README.md) · [Free-tier architecture plan](architecture/README.md) · [Project overview](project-overview.md)

Each item says **why** (one line) and **done when** (how we'll know it actually works).

---

## Phase 0 — Fixes found during review
Small, low risk, worth doing first.

- [x] **F1 · Fix Bedrock API key minting** — 2026-09-13, `ai-trader-signals@c6ffdf8`
  - **Why:** `generate_bedrock_key` in `ai-trader-signals/app/config.py` signs with `Version=1` included, so AWS rejects the key. Production survives only because an explicit `BEDROCK_API_KEY` is set; if that key goes away, every AI feature fails.
  - **Done when:** a unit test covers the signing order, and a key minted from IAM credentials lists Mantle models (HTTP 200).

- [x] **F2 · Box hygiene** (no code) — 2026-09-13
  - **Why:** Docker build cache was filling a 78%-full disk, and unused OS services were costing RAM.
  - **Done when:**
    - [x] unused images and old build cache pruned, keeping recent cache so deploys stay fast — disk 78% → 52% used;
    - [x] `fwupd` (masked), `ModemManager`, `udisks2` and `multipathd` stopped and disabled — ~58 MB. `snapd` kept: the AWS SSM agent runs as a snap and is the fallback way into the box;
    - [x] ~~Elastic IP~~ already in place (`3.7.76.174`);
    - [x] CloudWatch alarms `ai-trader-cpu-surplus-charged` (surplus credits charged > 0) and `ai-trader-cpu-credit-balance-low` (balance < 50), both sending to SNS topic `ai-trader-ops-alerts` → your email. The instance is in unlimited credit mode; the balance was at its 576 maximum when they were set up.

- [x] **F3 · Delete SQS** — 2026-09-13, `ai-trader-signals@adfeb24`, `ai-trader-api@7218bde`
  - **Why:** the API polls an empty queue ~4,300 times a day, and an AWS blip on the readiness probe can break startup.
  - **Done when:**
    - the signal publisher POSTs to the API's internal endpoint;
    - Celery's broker moves from SQS to the local Redis (found during the work: Celery was also on SQS);
    - the NestJS poller and the `/ready` SQS probe are gone;
    - `kombu[sqs]` is removed (**keep `boto3`**, which F1 needs);
    - all three test suites pass.

---

## Phase 1 — AI and news quality

- [x] **A1 · Replace FinBERT with an LLM sentiment field** — 2026-09-13
  - **Why:** FinBERT misreads direction on exactly the headlines that matter ("hotter CPI" → positive). The LLM already reads every article, so the field costs ~$0.50/month. Evidence: [FinBERT test](how-it-works/README.md#5-finbert-do-we-need-it).
  - **Done when:**
    - the impact prompt returns `sentiment` per article;
    - if the call fails, sentiment shows as "unscored", same as today;
    - the HuggingFace code and `HF_API_TOKEN` are removed;
    - the Home badge still renders.
  - `app/signals/sentiment.py` (hidden signals) moves when A4 happens.

- [x] **A2 · Fallback model for news impact** — 2026-09-13
  - **Why:** a failed batch discards 8 articles. Retrying on a different model beats re-asking the same one.
  - **Done when:** on a failed chunk, the retry uses `qwen.qwen3-235b-a22b-2507`. A test covers a DeepSeek failure recovering via the fallback.
  - Evidence: [bake-off](how-it-works/README.md#7-which-model-is-best-the-bake-off-sep-2026).

- [ ] **A3 · Chat model A/B, behind a flag**
  - **Why:** first-round tool selection is a tie, so the real difference would be answer quality over several rounds, which we can't measure offline.
  - **Done when:**
    - an env flag routes a percentage of chat turns to `moonshotai.kimi-k2.5` or `zai.glm-5`;
    - the model name is recorded on each stored chat turn;
    - there's a way to compare them.
  - Keep DeepSeek V3.2 as the default until the data says otherwise.

- [ ] **A4 · Signals revival** — later
  - **Why:** hidden because there's no proven track record.
  - **Done when:** walk-forward results with costs and drawdown are published, and signals are shown only alongside that record.

---

## Phase 2 — Free-tier architecture
Order matters: each step creates the headroom the next one needs. Details: [architecture plan §8](architecture/README.md#8-migration-order).

- [x] **B1 · Take yfinance out of the news path** — 2026-09-13
  - **Why:** it drags pandas into news for one HTTP call (+65 MB, measured).
  - **Done when:** `macro_events.py` uses a direct HTTP call, and a test fails if the news entrypoint imports pandas.

- [x] **B2 · APScheduler inside `signals` for the cheap jobs** — 2026-09-13
  - **Why:** removes Celery beat, and allows second-precision event wake-ups.
  - **Done when:**
    - jobs run from APScheduler with the **Redis job store** (so a restart during 15:20 doesn't skip square-off);
    - ~~it runs alongside beat for a day with matching logs~~ — cut: beat no longer holds these six entries at all, so there is nothing to run alongside. Beat keeps only `news-analysis` until B3 moves it to `newsd`;
    - beat is deleted — **B3**, with the Celery worker.

- [x] **B3 · `newsd` process; delete the Celery worker** — 2026-09-13
  - **Why:** −283 MB for worker + beat; news gets its own failure domain.
  - **Done when:** the hourly news result keeps arriving from `newsd`, and the Celery worker is gone.

- [x] **B4 · `signals` and `newsd` as systemd units, with isolation** — 2026-09-13
  - **Why:** the news engine must be able to die without taking the terminal down.
  - **Done when:**
    - `signals`: `MemoryMin=300M`, `OOMScoreAdjust=-500`;
    - `newsd`: `MemoryMax=350M`, `MemorySwapMax=0`, `OOMScoreAdjust=500`;
    - a forced `newsd` OOM leaves the terminal serving.

- [x] **B5 · Remove Docker** — 2026-09-13
  - **Why:** −206 MB, and deploys stop being full outages.
  - **Done when:**
    - [x] the frontend is built in GitHub Actions (ARM) — now shipped as a bundle, not an image, since the box has nothing to run an image with;
    - [x] API, Caddy and Redis run as systemd units (Caddy and Redis as distro packages);
    - [x] Docker is uninstalled;
    - [x] free memory is ≈ 1 GB — **1168 MB available**, from 601 MB.

- [x] **B6 · Watchdogs, and safe deploys** — 2026-09-13
  - **Why:** nothing today notices when a scheduled job silently stops.
  - **Done when:**
    - [x] every job writes a heartbeat;
    - [x] Healthchecks.io alerts on a missed ping;
    - [x] UptimeRobot watches `/health`;
    - [x] rolls back if health fails — frontend by symlink, API and signals by checking the previous commit back out. **Deviation:** the lint and test gate lives in CI (the deploy job needs a green test job), not in `deploy.sh`; running the suites again on a 2 GB box would add minutes to every deploy and gate nothing CI has not already gated.

## CI/CD — GitHub Actions
All four repos are public, so Actions minutes are free and unlimited.

- [x] **C1 · Tests on every push and pull request** — 2026-09-13
  - **Why:** there's no CI; a broken commit is found at deploy time, on the live box.
  - **Done when:** each repo runs its checks on push and PR — signals: `ruff` + `pytest`; api: `tsc` + `eslint` + `jest`; frontend: `tsc` + `eslint` + `vitest` — and a red run is visible on the commit.

- [x] **C2 · Deploy from GitHub** — 2026-09-13
  - **Why:** deploying means SSH-ing in by hand and remembering to copy umbrella files first.
  - **Done when:** a manual "Deploy" workflow (and optionally push to main, after C1 passes) SSHes in with a dedicated deploy key, restricted on the box to running `deploy.sh`, then checks `/api/health`.

- [x] **C3 · Build the frontend in Actions** — 2026-09-13 — same as B5's first step: build Next.js off the box and rsync it, so deploys stop compiling on a 2 GB server.

---

## Phase 3 — Self-built news engine

- [ ] **N1 · RSS firehose in `newsd`**
  - **Done when:**
    - ~50 feeds are polled with conditional GET (mostly `304` replies), tiered 1–15 minutes;
    - stories are deduped and clustered before the LLM;
    - news lag drops from ~1 h to minutes.

- [ ] **N2 · Release calendar from primary sources**
  - **Done when:** a daily job lists upcoming BLS, BEA, EIA, Fed, RBI, SEC and NSE/BSE events, each traceable to a real dated source.

- [ ] **N3 · Event watcher**
  - **Done when:**
    - `DateTrigger` fires 30 s before each release and polls the source every 2 s;
    - the published number is compared with expectations (or the previous figure);
    - an explained alert goes out;
    - it's tested against a real past release, such as a PPI day.

- [ ] **N4 · Telegram alerts for users** (`@adizx_bot`)
  - **Why:** market alerts should reach users with the app closed. This is a user feature, not monitoring — ops alerts stay on email.
  - **Done when:**
    - a user links Telegram from their profile (a deep link `t.me/adizx_bot?start=<one-time code>` ties the chat to their account);
    - their chat ID is stored per user, and they can unlink;
    - alerts they opted into reach the phone with the app closed, with no duplicate sends after a restart.

- [ ] **N5 · TTL index on news documents**
  - **Done when:** per-article news expires after 30 days, keeping Atlas far below its 512 MB free cap (~2 MB today).

---

## Phase 4 — Market data contract
Spec: `docs/superpowers/specs/2026-09-13-market-data-contract-design.md`. One day produced three
incidents (gold routed to an equity exchange, a weekend read as the end of history, a dead
subprocess 404ing a chart) with one root: providers had no contract, so the router guessed.

- [x] **M1 · Types, sessions, symbol resolution** — 2026-09-13
  - **Done when:** a symbol's venue is resolved rather than guessed; each vendor declares its own limits; sessions can say whether a market was open; the conformance suite runs against every provider.

- [x] **M2 · Router classifies, and the HTTP surface says both** — 2026-09-13
  - **Done when:** `get_bars` returns a status with every answer, paging lives in one shared place, and the route carries an HTTP code *and* a machine-readable status.

- [ ] **M3 · Port the providers onto the contract**
  - **Why:** Kite and yfinance still return `None` for both "empty" and "failed", so that distinction is inferred rather than reported.
  - **Done when:** each provider returns bars-or-reason itself, and the conformance suite asserts a vendor error never surfaces as `no_data`.

- [ ] **M4 · The terminal shows the reason**
  - **Why:** the API now explains an empty chart and nothing renders it.
  - **Done when:** the chart distinguishes closed market (with next open), unlisted symbol and provider outage, and offers a retry only for the last.

- [ ] **M5 · Circuit breaker and enrichment budget**
  - **Why:** a broken Dukascopy bridge is retried on every request; enrichment that misses its budget should be dropped, not awaited.
  - **Done when:** a vendor failing N times in a row is skipped for M minutes, and no enrichment can delay or fail a bars response.

## Later — product
- [ ] Multi-currency paper account (US stocks and forex, not just NSE/BSE in rupees)
- [ ] Crypto charts
- [ ] Live US prices
- [ ] Risk-profile questionnaire, the foundation for personal advice

---

## Needs you
Things only you can do, from an AWS or third-party account.

- [x] **Elastic IP** — `3.7.76.174` is an Elastic IP already attached to the server. (F2)
- [ ] **Anthropic use-case form** in the Bedrock console — unlocks Claude Haiku 4.5. Optional.
- [ ] **AWS Sales / account maturity** for Claude Sonnet 5, Opus 5 and GPT-5.6 — optional, not self-serve.
- [ ] **Service Quotas:** raise Amazon Nova's daily token quota — optional.
- [x] **IAM:** `AmazonSNSFullAccess` attached to `ai-trader-dev`. (F2)
- [ ] **Confirm the AWS email subscription** — click "Confirm subscription" in the email from AWS Notifications, or CPU alarms won't reach you. (F2)
- [x] **Healthchecks.io and UptimeRobot** accounts, with API keys stored in the server `.env`. (B6)
- [x] **Telegram bot** `@adizx_bot` — token in the server `.env`; your chat saved as `TELEGRAM_TEST_CHAT_ID` for testing, and a test message was delivered. (N4)
- [-] **Telegram in Healthchecks.io and UptimeRobot** — dropped: monitoring alerts go to you by email; the Telegram bot is for users.
- [ ] **GitHub Actions secrets** for deploying the frontend build. (B5)

---

## Log
Newest first. One line per shipped item: date · ID · what shipped · evidence.

- 2026-09-13 · M1 + M2 · The market data layer has a contract. A symbol's venue is resolved (`app/market/symbols.py`) instead of guessed from an `exchange` that three layers defaulted to NSE; each vendor declares its own limits, replacing a single global table of *yfinance's* numbers that had been clamping Kite to windows it serves happily; sessions (`app/market/sessions.py`) make an empty range explain itself; and the backward walk Deriv needed now lives in `app/market/paging.py` for the next vendor that cannot be asked for a range. Every answer carries a status, and the route reports both an HTTP code and a machine-readable one. Caught and fixed on the way: the classifier told a nonexistent symbol that NASDAQ was closed — a resolution is authoritative only when a listing table backs it. Live, all six outcomes correct: gold 1m/5d `ok` with 5282 bars, gold asked for on NSE `ok` as FOREX, RELIANCE 1m/365d clamped to 60, `2s` → 400 `unsupported_interval`, unlisted symbol → `no_data` naming both possibilities. 683 tests. · `ai-trader-signals@HEAD`, `ai-trader-api@HEAD`
- 2026-09-13 · — · Box `.env` hygiene, and gold. The API's `.env` still carried the compose-era `redis` host, `NODE_ENV=development` and a localhost `FRONTEND_URL`, plus 16 keys the code no longer reads (every `ZERODHA_*`, `DHAN_*`, `ANGELONE_*`, `VAPID_*`, `AWS_*`, `SQS_*` — an env-key scan of the source shows it reads 13 keys in total); signals lost its `SQS_*`, `FINBERT_MODEL` and `HF_API_TOKEN` leftovers. Both files backed up on the box first. Then the 404 that exposed the real bug: `exchange` defaults to `NSE` in the frontend client, the NestJS controller *and* the FastAPI route, so anything that did not know an exchange asked for XAUUSD on the Indian equity exchange — 404 for bars, and live ticks failing closed, which is worse because the chart just never ticks. Deriv's pair table now beats the claimed exchange in both routers, and responses report the exchange they were actually served from so a saved layout cannot store the wrong one. Live: gold bars and quote 200 with `"exchange":"FOREX"` and no exchange given; RELIANCE unchanged on NSE. · `ai-trader-signals@1b53e48`, `ai-trader-signals@HEAD`
- 2026-09-13 · B5 follow-up · Two traps the cutover walked into, both now fixed in the repo rather than on the box: systemd applies `EnvironmentFile=` **after** `Environment=`, so the stale service `.env` beat the unit and the API kept dialling the compose-era `redis` hostname — the cross-service wiring now lives in `.deploy-state/public.env`, which every unit reads last; and `nest build` deletes `dist/` while tsconfig sets `incremental: true`, so a surviving `.tsbuildinfo` made the build exit 0 having emitted nothing, which is what actually took the API down. `deploy.sh` removes it before building. The health gate caught both — the deploy failed loudly instead of shipping. · `journalctl -u ai-trader-api`, `/proc/<pid>/environ`
- 2026-09-13 · B5 + B6 · **Docker is gone from the box.** API and frontend joined signals and newsd as systemd units; Caddy and Redis are distro packages; `dockerd`/`containerd` (451 MB resident at the time) were purged. The frontend is no longer an image — CI packs Next's standalone output (plus `static/` and `public/`, which it leaves outside that tree) into a release asset the box fetches with no credentials, since the deploy key is locked to a forced command and cannot receive files. Releases unpack to `frontend/releases/<sha>` behind a `current` symlink. `deploy.sh` rebuilds only what moved (venv on `requirements.txt`, Node subprojects on their lockfiles, API on its HEAD), health-gates the result, and rolls back on failure: symlink flip for the frontend, previous commit for API and signals. Caddy's existing Let's Encrypt cert was copied out of the docker volume, so nothing was re-issued. Live: memory used **1079 → 666 MB** (1168 MB available), disk **13 → 6.4 GB**, all six units active, site and `/api/health` 200, static assets 200, both schedulers' jobs re-registered in the new Redis with correct IST times. · `ai-trader@HEAD`, `ai-trader-frontend@6c67fe9`
- 2026-09-13 · B4 · `signals` and `newsd` run under systemd, not Docker (`systemd/*.service`, installed by deploy.sh). The box got Python 3.12 (containers ran 3.13) and Node 20 for the Pine sandbox; before cutting over, a second instance on :8002 against a throwaway Redis db proved `/ready` green and a Pine script returning correct SMA values through the host's Node sandbox. Isolation verified by forcing it: a drop-in made newsd allocate 600 MB, systemd reported `Result=oom-kill` at the 350 MB cap, and the terminal answered 200 throughout. Caps live: signals `MemoryMin=300M`/`OOMScoreAdjust=-500`, newsd `MemoryMax=350M`/`MemorySwapMax=0`/`OOMScoreAdjust=+500`. Redis is published on 127.0.0.1 and the API reaches signals over the docker bridge until B5 removes the bridge entirely. · `ai-trader@HEAD`, `journalctl -u ai-trader-newsd`
- 2026-09-13 · B3 · The news pipeline runs in `newsd`, its own process and its own failure domain, and Celery is gone — worker, beat, `celery_app.py`, `tasks.py` and the dependency. The news job moved to `app/worker/news_job.py` so the process imports nothing from the terminal's stack (a test fails if it does), and newsd's Redis job store uses its own keys, which is what stops the two schedulers from running each other's jobs. Live: newsd idles at **36 MB** where worker + beat cost 283 MB; a run triggered inside the container analysed 25 articles (not degraded), got `201` from `/api/internal/news`, and pinged its Healthchecks check; next scheduled run 19:00 IST. · `ai-trader-signals@db891a2`
- 2026-09-13 · B2 · The six cron jobs now run from APScheduler inside the `signals` process, on a Redis job store, in IST — Celery beat is down to `news-analysis` alone. Job bodies moved to `app/worker/jobs.py` as plain functions (the Redis store resolves jobs by import path); the Celery tasks are thin wrappers over the same functions, so both paths ping the same Healthchecks check. A scheduler that fails to start no longer takes the charts down with it. Live proof: deleted `apscheduler.jobs` in Redis, restarted only the signals container, and all 6 jobs reappeared with the right IST next-run times (square-off Mon 15:20). Also fixed: nothing configured logging in that process, so every app-level line was being dropped — including the scheduler's, and any job failure it reports. · `ai-trader-signals@220a110`, `ai-trader-signals@cde3f8e`
- 2026-09-13 · B1 · News path no longer imports pandas: Yahoo headlines come from its RSS feed (which also carries the description the impact analysis uses) instead of yfinance, `prompts` needs pandas only as a type, and the Tavily tool import in `macro_events` is lazy. A test fails if pandas returns. Verified in the deployed worker: pandas and yfinance both absent, live run 25 articles, not degraded. · `ai-trader-signals@8d4527c`
- 2026-09-13 · A2 · A malformed news batch now retries on Qwen3-235B instead of re-asking DeepSeek at temperature 0, which mostly repeats the same answer; a failed chunk discards 8 articles. · `ai-trader-signals@8d4527c`

- 2026-09-13 · C1 · CI on all three repos (free: the repos are public). signals: ruff + pytest (597); api: tsc + eslint + jest (189); frontend: tsc + eslint + vitest (185). Fixed what CI surfaced: 8 pre-existing lint errors, and a bare `pytest` that couldn't import `app`. The two media-query hooks now use `useSyncExternalStore` instead of reading matchMedia in an effect. All three runs green. · `ai-trader-signals@758b9cb`, `ai-trader-api@477b2c2`, `ai-trader-frontend@85e338a`

- 2026-09-13 · F3 · SQS removed. Signals POST to `/api/internal/signals` (401 without key, 400 on bad payload, verified live); the API's SQS poller, `@aws-sdk/client-sqs` and AWS settings removed; Celery broker moved to Redis; readiness no longer probes SQS. Live: a job sent from the beat container through Redis ran on the worker in 3 s, and Healthchecks `drift-check` went 1 → 2 pings. Tests: signals 597, api 189. · `ai-trader-signals@adfeb24`, `ai-trader-api@7218bde`

- 2026-09-13 · F2 · CPU credit alarms created and wired to SNS topic `ai-trader-ops-alerts` (email subscription pending your confirmation) · `aws cloudwatch describe-alarms`

- 2026-09-13 · F2 (partial) · Pruned 1.13 GB of unused images and 3.98 GB of build cache (3.1 GB of recent cache kept); disabled fwupd (masked), ModemManager, udisks2 and multipathd (none in use). Disk 78% → 52% used (8.8 GB free); all 7 containers healthy, `/api/health` 200 afterwards. CPU alarms blocked on SNS permission. · `df -h`, `docker system df`, `systemctl is-enabled`

- 2026-09-13 · F1 · Bedrock key signed without `Version=1` · test checks the signature against hand-computed SigV4; a key minted by the app listed 38 Mantle models (HTTP 200); `LlmClient` with no explicit key got a DeepSeek reply; full suite 583 passed · `ai-trader-signals@c6ffdf8`

- 2026-09-13 · B6 (partial) · All 6 scheduled jobs now ping their Healthchecks.io check (fail ping on error, on ok=False, on a failed publish, or on an exception); deployed. Live proof: `run_drift_check` run inside the production worker → check `drift-check` went `up`, 1 ping. · `ai-trader-signals@148bcdb`
- 2026-09-13 · B6 (partial) · Healthchecks.io: 7 checks created, one per scheduled job, with real cron schedules (Asia/Kolkata) and grace periods, all in state "new" (no alerts until the first ping). UptimeRobot: "AI Trader API health" monitor (id 803980958) added via the v3 API, alongside your homepage monitor. Not ticked: jobs don't ping yet. · API responses 200/201

- 2026-09-13 · — · Bake-off of 8 Mantle models; FinBERT vs LLM test; how-it-works and architecture docs written · `docs/how-it-works/`, `docs/architecture/`
