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

- [ ] **A1 · Replace FinBERT with an LLM sentiment field**
  - **Why:** FinBERT misreads direction on exactly the headlines that matter ("hotter CPI" → positive). The LLM already reads every article, so the field costs ~$0.50/month. Evidence: [FinBERT test](how-it-works/README.md#5-finbert-do-we-need-it).
  - **Done when:**
    - the impact prompt returns `sentiment` per article;
    - if the call fails, sentiment shows as "unscored", same as today;
    - the HuggingFace code and `HF_API_TOKEN` are removed;
    - the Home badge still renders.
  - `app/signals/sentiment.py` (hidden signals) moves when A4 happens.

- [ ] **A2 · Fallback model for news impact**
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

- [ ] **B1 · Take yfinance out of the news path**
  - **Why:** it drags pandas into news for one HTTP call (+65 MB, measured).
  - **Done when:** `macro_events.py` uses a direct HTTP call, and a test fails if the news entrypoint imports pandas.

- [ ] **B2 · APScheduler inside `signals` for the cheap jobs**
  - **Why:** removes Celery beat, and allows second-precision event wake-ups.
  - **Done when:**
    - jobs run from APScheduler with the **Redis job store** (so a restart during 15:20 doesn't skip square-off);
    - it runs alongside beat for a day with matching logs;
    - beat is deleted.

- [ ] **B3 · `newsd` process; delete the Celery worker**
  - **Why:** −283 MB for worker + beat; news gets its own failure domain.
  - **Done when:** the hourly news result keeps arriving from `newsd`, and the Celery worker is gone.

- [ ] **B4 · `signals` and `newsd` as systemd units, with isolation**
  - **Why:** the news engine must be able to die without taking the terminal down.
  - **Done when:**
    - `signals`: `MemoryMin=300M`, `OOMScoreAdjust=-500`;
    - `newsd`: `MemoryMax=350M`, `MemorySwapMax=0`, `OOMScoreAdjust=500`;
    - a forced `newsd` OOM leaves the terminal serving.

- [ ] **B5 · Remove Docker**
  - **Why:** −206 MB, and deploys stop being full outages.
  - **Done when:**
    - the frontend builds in GitHub Actions and is rsynced to the box;
    - API, Caddy and Redis run as systemd units;
    - Docker is uninstalled;
    - free memory is ≈ 1 GB (from 601 MB).

- [ ] **B6 · Watchdogs, and safe deploys**
  - **Why:** nothing today notices when a scheduled job silently stops.
  - **Done when:**
    - every job writes a heartbeat;
    - Healthchecks.io alerts on a missed ping;
    - UptimeRobot watches `/health`;
    - `deploy.sh` lints and tests before restarting, and rolls back if `/health` fails.

## CI/CD — GitHub Actions
All four repos are public, so Actions minutes are free and unlimited.

- [ ] **C1 · Tests on every push and pull request**
  - **Why:** there's no CI; a broken commit is found at deploy time, on the live box.
  - **Done when:** each repo runs its checks on push and PR — signals: `ruff` + `pytest`; api: `tsc` + `eslint` + `jest`; frontend: `tsc` + `eslint` + `vitest` — and a red run is visible on the commit.

- [ ] **C2 · Deploy from GitHub**
  - **Why:** deploying means SSH-ing in by hand and remembering to copy umbrella files first.
  - **Done when:** a manual "Deploy" workflow (and optionally push to main, after C1 passes) SSHes in with a dedicated deploy key, restricted on the box to running `deploy.sh`, then checks `/api/health`.

- [ ] **C3 · Build the frontend in Actions** — same as B5's first step: build Next.js off the box and rsync it, so deploys stop compiling on a 2 GB server.

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

- 2026-09-13 · F3 · SQS removed. Signals POST to `/api/internal/signals` (401 without key, 400 on bad payload, verified live); the API's SQS poller, `@aws-sdk/client-sqs` and AWS settings removed; Celery broker moved to Redis; readiness no longer probes SQS. Live: a job sent from the beat container through Redis ran on the worker in 3 s, and Healthchecks `drift-check` went 1 → 2 pings. Tests: signals 597, api 189. · `ai-trader-signals@adfeb24`, `ai-trader-api@7218bde`

- 2026-09-13 · F2 · CPU credit alarms created and wired to SNS topic `ai-trader-ops-alerts` (email subscription pending your confirmation) · `aws cloudwatch describe-alarms`

- 2026-09-13 · F2 (partial) · Pruned 1.13 GB of unused images and 3.98 GB of build cache (3.1 GB of recent cache kept); disabled fwupd (masked), ModemManager, udisks2 and multipathd (none in use). Disk 78% → 52% used (8.8 GB free); all 7 containers healthy, `/api/health` 200 afterwards. CPU alarms blocked on SNS permission. · `df -h`, `docker system df`, `systemctl is-enabled`

- 2026-09-13 · F1 · Bedrock key signed without `Version=1` · test checks the signature against hand-computed SigV4; a key minted by the app listed 38 Mantle models (HTTP 200); `LlmClient` with no explicit key got a DeepSeek reply; full suite 583 passed · `ai-trader-signals@c6ffdf8`

- 2026-09-13 · B6 (partial) · All 6 scheduled jobs now ping their Healthchecks.io check (fail ping on error, on ok=False, on a failed publish, or on an exception); deployed. Live proof: `run_drift_check` run inside the production worker → check `drift-check` went `up`, 1 ping. · `ai-trader-signals@148bcdb`
- 2026-09-13 · B6 (partial) · Healthchecks.io: 7 checks created, one per scheduled job, with real cron schedules (Asia/Kolkata) and grace periods, all in state "new" (no alerts until the first ping). UptimeRobot: "AI Trader API health" monitor (id 803980958) added via the v3 API, alongside your homepage monitor. Not ticked: jobs don't ping yet. · API responses 200/201

- 2026-09-13 · — · Bake-off of 8 Mantle models; FinBERT vs LLM test; how-it-works and architecture docs written · `docs/how-it-works/`, `docs/architecture/`
