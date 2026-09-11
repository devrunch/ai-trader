# Codebase Cleanup Audit

Scope: `ai-trader-frontend`, `ai-trader-api`, `ai-trader-signals`, and the umbrella repo.
Method: static tooling (`knip` on both TypeScript repos, `vulture` + `deptry` on the Python service), route-to-caller mapping across all three services, live production logs and database counts, and manual verification of every candidate before listing it. Nothing below was deleted — this is the plan.

**Size for reference:** signals ≈ 11,900 lines of Python · api ≈ 7,100 lines TS · frontend ≈ 9,300 lines in `app/` + `components/` (plus `lib/`).

**Risk key:** 🟢 safe — zero callers verified · 🟡 low — confirm one thing first · 🟠 medium — refactor, needs tests · 🔴 product decision required.

---

## Summary of the biggest wins

| # | What | Why it matters | Risk |
|---|---|---|---|
| 1 | **Pause the screener** | ~100 LLM calls every trading day, **0 signals stored in 7 days**, output only feeds the hidden Signals page | 🟢 |
| 2 | **Delete the Lambda/Fargate/Vercel deployment path** | ~450 lines + 2 deps + a config flag + dual-mode reasoning in 6+ files for a target nobody deploys to | 🟡 |
| 3 | **Remove dead routes, functions, deps** | ~15 routes, ~10 dependencies, a dozen functions with zero callers | 🟢/🟡 |
| 4 | **Consolidate duplicated plumbing in signals** | 8 hand-rolled internal-API calls, 6 copies of Redis connect/close, 3 identical wrappers | 🟠 |
| 5 | **Split `news.py` (949 lines)** | One module doing four jobs; the largest file in the backend | 🟠 |

Aggressive-but-safe total: roughly **1,000+ lines and ~10 dependencies**, without touching the hidden Signals feature. Retiring Signals outright (a product decision, see §8) would remove several thousand more.

---

## 1. Stop the running cost — dead work that executes every day

### 1.1 Screener runs every 15 minutes for a hidden feature 🟢
- **Where:** `ai-trader-signals/app/worker/celery_app.py` beat entries `run-screener-open`, `run-screener-day`, `run-screener-close` → `run_screener` in `app/worker/tasks.py`.
- **Why unnecessary:** Runs ~25 times per trading day across 6 watchlist symbols. Production logs show roughly 4 symbols per run reaching the LLM and being rejected (`HOLD is not a trade`), the rest filtered as stale or by regime. **Zero signals stored in the last 7 days** (94 all-time). Every signal it could produce is only visible on the Signals page, which is hidden.
- **Impact of removing:** ~100 fewer LLM calls per trading day, fewer broker/yfinance calls, less worker memory churn.
- **Risk:** None visible to users. Fully reversible — the task code stays; only the three schedule entries are removed.
- **Plan:** Delete the three beat entries. Leave `run_screener` and `square_off_positions` untouched (square-off is separate and still needed).

### 1.2 Market overview computes trade candidates the UI throws away 🔴
- **Where:** `app/signals/brief.py` → `generate()` runs the signal engine over a 25-symbol universe (`DEFAULT_UNIVERSE`) twice a day.
- **Why unnecessary:** Every observed run produced **0 candidates**, and the Home page's `MarketOverview` never reads candidates at all — the frontend type doesn't even include them.
- **Impact:** Removes the most expensive part of each overview run.
- **Risk:** The narrative prompt currently takes candidates as input; stripping them changes the prompt. Tied to the Signals decision (§8).
- **Plan:** Once Signals is decided, strip candidate generation and keep cues + bias + narrative.

### 1.3 Terminal fetches signals for a hidden panel on every symbol switch 🟢
- **Where:** `ai-trader-frontend/app/dashboard/terminal/page.tsx` — the effect calling `getSignalsBySymbol(activeSymbol)`.
- **Why unnecessary:** Its only consumer is the Signal tab, which is hidden. One API + database round trip per symbol change for nothing.
- **Risk:** None; restore alongside the Signal tab if it comes back.
- **Plan:** Remove the effect and the `displaySignal`/`signalLoading`/`signalError` state it feeds (or gate it behind the hidden tab).

---

## 2. Legacy code — a whole deployment target that isn't used

Production runs on one EC2 instance with Docker Compose and Caddy. The repo still carries a complete second deployment path (API on Lambda, signals on ECS Fargate, frontend on Vercel) plus nginx.

| File | Lines | What it was |
|---|---|---|
| `ai-trader-api/serverless.yml` | 92 | API on Lambda via Serverless Framework |
| `ai-trader-api/src/lambda.ts` | 64 | Lambda HTTP + SQS-consumer entry points |
| `deploy/deploy.sh` | 121 | Lambda + ECR/Fargate + Vercel deploy script (not the one used — root `deploy.sh` is) |
| `deploy/fargate/signals-task.json` | 47 | Fargate task definition |
| `deploy/fargate/worker-task.json` | 63 | Fargate task definition |
| `deploy/nginx.conf` | 36 | Reverse proxy — production uses Caddy (`docker-compose.prod.yml`) |

Also part of the same legacy path:
- **Dependencies:** `serverless-http`, `@types/aws-lambda` (api).
- **Config flag:** `SIGNALS_POLLER_ENABLED` in `src/config/env.validation.ts` exists only to switch the SQS poller off under Lambda. With one deployment it should simply always be on.
- **Stale reasoning in comments:** `bootstrap.ts`, `internal-key.guard.ts`, `env.validation.ts`, `signals.service.ts`, `watchlist.controller.ts`, `signals.gateway.ts`, `docker/signals/Dockerfile` (cites the Fargate task's CPU), `celery_app.py` (IAM-role SQS branch labelled "Fargate").

- **Why unnecessary:** Nothing deploys this way. It also forces every reader to reason about two runtimes that behave differently.
- **Impact:** ~420 lines of files, 2 deps, one config flag, and a layer of conditional reasoning across 8 files.
- **Risk:** 🟡 None of the four repos has a `.github/workflows` directory, so no CI can be deploying this way. The only remaining check is whether anyone runs `serverless deploy` or `deploy/deploy.sh` by hand.
- **Keep:** `deploy/setup-ec2.sh` is the EC2 bootstrap and still relevant — but it has a `YOUR_ORG` placeholder repo URL; fix it or fold it into `DEPLOY.md`.
- **Plan:** Delete the six files and two deps; remove `SIGNALS_POLLER_ENABLED` and make the poller unconditional; rewrite the affected comments to describe the one real deployment.

---

## 3. Dead code — verified zero callers

### 3.1 Frontend 🟢
| Item | Location | Evidence |
|---|---|---|
| `lib/indicators.ts` (53 lines) | whole file | No importers. Same job as `lib/indicator-labels.ts`, which is the one actually used |
| `ChartLegend` component | `components/CandlestickChart.tsx:439` | Exported, never rendered anywhere — not even in its own file |
| `chatWithAI` | `lib/api/chat.ts` | Frontend only uses the streaming chat |
| `getChatSessions`, `getChatSession` | `lib/api/chat.ts` | No callers |
| `createPaperPortfolio` | `lib/api/paper-actions.ts` | No callers — portfolios are created elsewhere (64 exist) |
| `@anthropic-ai/sdk`, `@base-ui/react` | `package.json` | Not imported anywhere |

Minor, batch with the above: `DISCLAIMER_TEXT`, `DISCLAIMER_SHORT`, `FETCH_DEBOUNCE_MS`, `ASSET_CLASSES`, `signalAge` are exported but only used inside their own files — un-export them.

### 3.2 API
| Item | Evidence | Risk |
|---|---|---|
| `NotificationsModule` (9 lines, empty) | Placeholder; the plan now lives in `docs/project-overview.md` | 🟢 |
| `scripts/check-duplicate-signals.js` (108 lines) | One-time pre-deploy index check; `deploy.sh` never runs it; no new signals are being produced | 🟡 keep if Signals is revived |
| `axios` | Not imported in `src` | 🟢 |
| `@nestjs/testing`, `supertest`, `@types/supertest`, `ts-loader` | No e2e tests exist; unit specs construct services directly | 🟢 |

**API routes with no frontend caller** 🟡 — confirm none are planned features before removing:

| Route | Note |
|---|---|
| `GET /api/brief/recent`, `GET /api/brief/:date` | Home only reads the latest |
| `GET /api/chat/budget` | Budget is enforced server-side; nothing reads this |
| `GET /api/chat/sessions`, `GET /api/chat/sessions/:id` | Clients for these are dead (above) |
| `POST /api/paper/portfolio` | Client is dead |
| `PUT /api/paper/order/:id` | Order modification — no UI. Planned? |
| `PUT /api/paper/positions/refresh` | No caller |
| `GET /api/paper/trades` | Trade history — no UI. Planned? |
| `POST /api/signals/chat` | Frontend never calls it (see note below) |

### 3.3 Signals
**Functions/classes with no callers** 🟢
| Item | Location |
|---|---|
| `get_market_news()` | `app/market/news.py` — the articles-only wrapper |
| `invalidate()`, `cache_stats()` | `app/market/providers/registry.py` |
| `LoggingTurnStore` | `app/signals/agent/store.py` |
| `STOP_REASONS` | `app/signals/agent/orchestrator.py` |

Test-only (no production caller — keep if the test is worth it, otherwise delete together): `NullTurnStore` (`store.py`), `calls_made()` (`agent/runner.py`).

**Abandoned feature** 🟡 — `PineStrategyRunner` (`app/signals/pine/strategy_runner.py`, 47 lines) plus its test (45 lines). A live strategy executor that was never wired into any runtime path. Delete both unless live strategy execution is on the roadmap.

**HTTP routes with no caller** 🟢/🟡
| Route | Note |
|---|---|
| `POST /market/quotes/batch` | Its helper `get_batch_quotes()` is used nowhere else — delete both |
| `GET /market/news` | The API now reads stored results; the pipeline calls the function in-process |
| `GET /signals/global-cues` | No caller |
| `POST /signals/backtest` | Backtests run through the chat agent's tool, in-process |
| `POST /signals/brief/generate` | Manual trigger only — keep if used for operations |

> ⚠️ **Keep `POST /signals/chat`.** The frontend doesn't use it, but `scripts/eval_agent.py` (the live agent evaluation harness) posts to it directly. Remove only the dead API hop above it, or move the harness to the streaming endpoint first.

**Dependency hygiene** 🟢 — `botocore` is imported directly (`app/config.py`, `main.py`) but only arrives via `boto3`; declare it. `deptry`'s other flags (`uvicorn`, `kombu`, `beautifulsoup4`) are false positives: server command, SQS transport extra, and the `bs4` import name respectively.

---

## 4. Duplicate logic to consolidate 🟠

| Duplication | Count | Consolidate into |
|---|---|---|
| Hand-rolled `httpx` calls with the `x-internal-key` header | 8 — `alerts_publish.py`, `news.publish`, `brief.publish`, `kite_provider.py`, `agent/context.py`, `tasks.py` ×3 | One `internal_api` client (`get`/`post`/`put`, shared timeout and error logging). `alerts_publish.py` disappears entirely |
| Redis connect → try → `aclose()` | 6 — `news.py` ×4, `drift_check.py`, `macro_events.py` | One `redis_session()` async context manager |
| `_fetch_*_safe` wrappers | 3 in `news.py` | One generic "return default on failure" helper |
| Test fakes (`_FakeRedis`, `FakeLlm`, `_response`) | `_FakeRedis` in 3 test files, `FakeLlm` in 4 | Shared fixtures in `tests/conftest.py` |
| Indicator display-name mapping | `lib/indicators.ts` vs `lib/indicator-labels.ts` | Delete the unused one (§3.1) |
| Impact-news filtering (sentiment → impact → asset class) | Home page and Signals page | A `useImpactNews()` hook |

- **Impact:** Roughly 150 lines net removed, and one place to change each behaviour (timeouts, auth header, Redis handling).
- **Risk:** Behaviour-preserving refactor — run the full signals suite (~586 tests) after each step.
- Not worth consolidating: the API's `brief` / `alerts` / `news` "internal POST + stored document" modules look alike, but that's normal NestJS shape.

---

## 5. Overly complex implementations 🟠

### 5.1 `app/market/news.py` — 949 lines, the largest backend file
It fetches from four sources, maps each source's shape, dedupes and merges, parses sentiment responses, chunks and caches impact analysis, caches results, and publishes. Split into a package with no behaviour change:
- `news/sources.py` — the four fetchers, their mappers, `_merge_sources`
- `news/sentiment.py` — FinBERT call and response parsing
- `news/impact.py` — chunked analysis and per-URL cache
- `news/pipeline.py` — `get_market_news_result` and `publish`

### 5.2 `app/dashboard/terminal/page.tsx` — 845 lines
Orchestrates chart, indicators, signals, positions and chat. Removing the hidden-signal fetch (§1.3) and extracting the indicator attach/diff logic into a `useAttachedIndicators` hook would shrink it substantially. Core page — do it with tests and a manual smoke test.

### 5.3 Signal publishing takes a detour through SQS 🔴
Signals go signals-service → SQS → API poller → MongoDB, while the three other pipelines (overview, alerts, news) POST straight to an internal API endpoint. Moving signals to the same internal POST would remove the API's SQS poller, the signals queue, and `SIGNALS_POLLER_ENABLED`. Defer until the Signals decision — no point reworking a path that may be retired.

Left alone on purpose: `lightweight-charts-adapter.ts` (727 lines) is large but cohesive.

---

## 6. Redundant queries and API calls

| Redundancy | Fix | Risk |
|---|---|---|
| Terminal re-fetches signals on every symbol switch | §1.3 | 🟢 |
| Home loads alerts twice — the page (`getAlerts(4)`) and the header bell (`getAlerts(30)`) | Lift alerts into one shared provider, like the existing market-status provider | 🟢 |
| `news.py`'s 5-minute result cache | Only served the dead `GET /market/news` route; the pipeline runs hourly. Remove with the route | 🟢 |
| Global cues fetched separately by the hourly drift check and the twice-daily overview | Drift already stores a snapshot in Redis; the overview could reuse it. Small win | 🟡 |

---

## 7. Abandoned or disconnected files

| File | Status | Action |
|---|---|---|
| `node_modules/` (umbrella root) | Empty folder, no `package.json` | Delete 🟢 |
| `CLAUDE.md` | 2 bytes — a UTF-16 byte-order mark and nothing else (why project instructions render as `��`) | Delete, or write real content 🟢 |
| `ai-trader-signals/.worktrees/` | Empty leftover from a finished worktree | Delete 🟢 |
| `deploy/` legacy files | See §2 | Delete 🟡 |
| `README.md` | Stale: describes KLineCharts, Next.js 14, a "signal platform", and crypto/non-Indian exchanges as out of scope | Rewrite, or point to `docs/project-overview.md` 🟢 |
| `docs/superpowers/plans/` (6), `specs/` (7) | Records of shipped features — not dead | Optionally move to `docs/archive/` |
| `docs/superpowers/plans/2026-08-24-terminal-mobile-responsive.md` | Untracked; the feature has shipped | Commit or delete |
| `docs/client-status-report.*` | Gitignored, dated 18 Aug, client-confidential | Leave |
| `propmts.adi.md`, `api.key.env` | Personal files (Claude Code prompts, Anthropic keys) — gitignored, not app code | Leave; consider moving outside the repo |
| `ai-trader-signals/scripts/eval_agent.py` | **Not abandoned** — deliberate live-evaluation harness | Keep |

---

## 8. Technical debt

- **Hidden Signals feature — needs a decision, not a deletion.** 🔴 The Signals page, `SignalPanel`, the screener, the SQS publishing path, the performance evaluation, the overview's candidates and the duplicate-signal script are all parked. Reviving it needs proper out-of-sample validation; retiring it removes more code than everything else in this audit combined. Until decided, keep the code (it's meant to be reversible) but stop the running cost (§1).
- **Comment debt.** A conservative search finds ~97 comment lines narrating history rather than explaining the current code ("used to", "confirmed live", "found live", "previously", "the old…"): 39 in signals, 27 in the API, 31 in the frontend. The real number is higher. This goes against the stated preference for terse comments without bug history — and a good share was added during recent work. Sweep module by module during §4 and §5: keep the one-line *why*, drop the story.
- **Undeclared dependency.** `fancy-canvas` is imported by 8 frontend files but not listed in `package.json`; it only arrives through `lightweight-charts`. Declare it so an upgrade can't silently break those imports. Same for `postcss` (used by config).
- **No CI at all.** None of the four repos has automated checks. Roughly 950 tests across the three services only run when someone runs them by hand, so nothing stops a broken commit reaching `main` or the box. A single workflow per repo running typecheck + tests on push is cheap and would make every phase of this cleanup safer.
- **Naming.** The Home page lives at `/dashboard/brief`, reads `/api/brief`, and stores into `morningbriefs`, while the product calls it "Market overview". Rename when convenient; purely cosmetic.

---

## Before deleting anything

1. **Search for string-built references** — a route or function name can be reached through a URL built at runtime, a curl in `DEPLOY.md`, or an ops habit that static tools can't see.
2. **Check the known dependency:** `scripts/eval_agent.py` → `POST /signals/chat`.
3. **Confirm nobody deploys by hand** through `serverless.yml` or `deploy/deploy.sh` (there is no CI, so a person is the only way it could happen).
4. **Confirm product intent** for order modification, trade history and positions refresh before removing their routes.
5. **After every phase:** typecheck and run all three suites (signals ~586, api ~187, frontend ~185 tests), deploy, and smoke-test Home, Terminal (including a FOREX chart and an indicator) and Portfolio.

---

## Recommended cleanup plan

Each phase ships on its own and can be reverted on its own.

| Phase | Work | Risk | Rough size |
|---|---|---|---|
| **0 — today** | Remove the 3 screener schedule entries; remove the terminal's hidden-signal fetch | 🟢 | ~20 lines; ~100 LLM calls/day saved |
| **1 — pure deletions** | Frontend dead file, component, client functions, 2 deps, un-exports · API `NotificationsModule`, `axios`, 4 unused devDeps · signals dead functions and constants · empty `node_modules/`, `CLAUDE.md`, `.worktrees/` | 🟢 | ~250 lines, 7 deps |
| **2 — legacy deployment** | Lambda/Fargate/Vercel/nginx files, 2 deps, `SIGNALS_POLLER_ENABLED`, stale comments; fix `setup-ec2.sh` placeholder | 🟡 | ~450 lines, 2 deps |
| **3 — dead routes** | Signals: `quotes/batch` + helper, `market/news` + result cache, `global-cues`, `backtest` · API routes with no caller (after confirming intent) · `PineStrategyRunner` + test | 🟡 | ~300 lines |
| **4 — consolidation** | `internal_api` client, `redis_session()`, one safe-fetch helper, shared test fixtures, `useImpactNews()`, shared alerts provider | 🟠 | ~150 lines net |
| **5 — restructure** | Split `news.py`; extract `useAttachedIndicators`; comment sweep; declare `fancy-canvas`/`postcss`/`botocore`; rewrite README | 🟠 | readability, little net change |
| **6 — decisions** | Revive or retire Signals → then strip overview candidates and move signal publishing off SQS; optional rename | 🔴 | largest, depends on the decision |
