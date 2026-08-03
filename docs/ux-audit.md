# UX / product audit — ai-trader-frontend

**Scope:** every file under `ai-trader-frontend/app/`, `components/`, `lib/`, plus `middleware.ts`, `next.config.ts`, `globals.css`. Backends read where behaviour needed confirming.
**Method:** static read + `npx tsc --noEmit` (clean) + `npm run build` (passes) + `npx eslint` (19 errors, 1 warning). No dev server, no browser.
**Date:** 2026-07-26

---

## Executive summary

The visual craft here is genuinely above average for a project this size — one deliberate dark identity, disciplined colour tokens, no rounded-corner mush, copy that mostly reads like a person wrote it. The problem is not how it looks. The problem is that **the app is more confident than the system underneath it**, and in three places it tells the user something that is not true.

Three patterns account for most of the damage:

1. **Every failure is disguised as an empty state.** Nine separate `.catch(() => …)` handlers swallow errors and hand back an empty array, `null`, or `0`. The user is never told a request failed. They are told they have no account, no signals, no brief, and a ₹0 balance.
2. **Where errors *do* surface, they surface as HTTP status strings.** `lib/api.ts:9` throws `"400 Bad Request"` and three components render that string verbatim. Meanwhile the NestJS API is returning genuinely useful messages ("Insufficient balance. Required ₹9,000, available ₹500") in a response body the frontend never reads.
3. **The honest-reporting work stopped at the Brief page.** The Brief carries a real, well-written disclaimer. The Signals table — a full-page grid of BUY/SELL calls with entry, target and stop in rupees — carries none, isn't in the nav, and colours win rate red below 50% when this system's breakeven is ~34.6%.

**Verdict: not shippable to a paying user as-is.** Not because it is unfinished — most of it is finished — but because of a small number of specific claims and silences that a paying user will catch. Fix the five below and it becomes defensible.

### Top 5 to fix first

| # | Fix | Why |
|---|---|---|
| 1 | **Double-submit on order confirm** — `components/OrderTicket.tsx:177` has no `disabled` and no in-flight state; two clicks place two orders. | The backend's atomic cash guard stops an *overdraft*, not a duplicate — two clicks with enough cash both execute, and the user owns 2× what they confirmed. |
| 2 | **The order ticket says "Limit" and places a market order.** `OrderTicket.tsx:58` never sends `type`, so `paper-trading.service.ts:177` defaults to `MARKET` and the limit-reachability check is skipped. The success toast then reports the *limit* price, not the fill. | The user confirms "Price ₹2,847", fills at whatever the market is, and is told they got ₹2,847. In a product about trading discipline this is the worst possible lie. |
| 3 | **Read the error body.** `lib/api.ts:9` discards the response JSON and throws `"${status} ${statusText}"`, which is rendered raw at `OrderTicket.tsx:203`, `terminal/page.tsx:550` and `terminal/page.tsx:482`. | "400 Bad Request" instead of "Insufficient balance. Required ₹9,000, available ₹500". The good message already exists; the frontend throws it away. |
| 4 | **Disclaimer + breakeven-aware colouring on the Signals surface.** `signals/page.tsx` has no disclaimer anywhere; `:260` and `:288` colour win rate red below 50%. | It is the densest money-attached surface in the app and it teaches users a standard (50%) that would make a genuinely profitable system look broken. |
| 5 | **Delete the fake "Verified" badge and the two dead toggles** — `profile/page.tsx:100` (hardcoded), `:112`, `:123` (local state only). There is no email verification in the backend at all (`auth/schemas/user.schema.ts` has no such field). | A fintech product asserting a security fact it has not established. The 2FA toggle that says "Enabled" and forgets on refresh is worse than no 2FA toggle. |

---

## 1. Developer leakage

**CRITICAL — HTTP status codes rendered as user-facing error text**
`lib/api.ts:9` — `throw new Error(\`${res.status} ${res.statusText}\`)`. Rendered at:
- `components/OrderTicket.tsx:63` → `:203`, inside the "Order failed" toast
- `app/dashboard/terminal/page.tsx:281` → `:550`, inside the AI Signal panel
- `app/dashboard/terminal/page.tsx:301` → `:482`, as a red bar under the toolbar

**What the user sees:** a red toast reading "Order failed / 400 Bad Request". Or, when the signals service is down, "503 Service Unavailable" in the analysis panel. The upstream layer even composes strings like `"Signals service unavailable (upstream 503)"` (`ai-trader-api/src/common/http/upstream-http.client.ts:79`) and `"Signals service unreachable: fetch failed"` (`:86`) — internal service names, on screen, in a consumer product.
**Why it matters:** it is the single loudest "this is a prototype" signal a user can receive, and it destroys the actually-useful message. `paper-trading.service.ts` produces `"Insufficient balance. Required ₹9000.00, available ₹500.00"` and `"Limit not reached: RELIANCE is at ₹2851, limit is ₹2847"` — both discarded.
**Fix:** in `req()`, `await res.json().catch(() => null)` before throwing, and throw a typed error carrying `{status, message}`. Render `message` when present; map 401/403/5xx to written sentences otherwise. The login page already does exactly this (`login/page.tsx:27-28`) — copy that pattern into `lib/api.ts`.

**HIGH — internal env var and service architecture shown to the user**
`app/dashboard/signals/page.tsx:359` — empty news state reads: *"No articles right now. Live news needs a NEWS_API_KEY configured on the signals service."*
**What the user sees:** a configuration instruction addressed to someone else, naming an environment variable and an internal microservice.
**Why it matters:** it tells a paying user the product is misconfigured and that there is a "signals service" they were never meant to know about.
**Fix:** "No headlines right now." Log the config problem server-side.

**HIGH — raw internal field names as UI labels**
`app/dashboard/terminal/page.tsx:588-591` and `app/dashboard/signals/page.tsx:222-225` render `Object.entries(indicators)` with the raw key uppercased.
The payload is `dict(indicators)` straight from the computation (`ai-trader-signals/app/signals/service.py:266`), keyed `rsi`, `macd`, `macd_hist`, `macd_signal`, `ema20`, `ema50`, `ema200`, `adx`, `supertrend_dir`, `vwap`, `atr`, `ltp` (`app/signals/types.py:29-40`).
**What the user sees:** `SUPERTREND_DIR 1.00`, `MACD_HIST -0.42`, `LTP 2847.30`, `ATR 14.20`. `supertrend_dir` is a ±1 flag rendered to two decimal places.
**Why it matters:** "SUPERTREND_DIR 1.00" is not an indicator readout, it's a variable dump. The landing page promises "Reasoning, not just a signal … not a black-box score" (`app/page.tsx:342`) and then shows the user a black box with the lid half off.
**Fix:** a label map (`supertrend_dir → "SuperTrend"` with value `"bullish" / "bearish"`; `macd_hist → "MACD histogram"`; drop `ltp` and `atr` from the readout entirely). Whitelist, don't enumerate.

**MEDIUM — Mongo ObjectId shown as user identity**
`app/dashboard/profile/page.tsx:93` — `ID: {me?.id ?? "—"}`.
**What the user sees:** `ID: 6712fa9c8e1b2d4a7c3f0b19` under their email address.
**Why it matters:** it is not an identifier the user can use for anything; it is a database primary key. If support ever needs a reference, give them a short account number.
**Fix:** remove it, or show a derived short code.

**MEDIUM — hardcoded `localhost:8000` as the production fallback**
`lib/api.ts:1`, `app/dashboard/layout.tsx:8`, `app/dashboard/profile/page.tsx:6`, `app/login/page.tsx:6`, `app/register/page.tsx:6` — all `process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000"`.
**What the user experiences:** if the env var is missing from a production build, every request goes to the user's own machine, fails silently (see §2), and the app renders as a fully-loaded but completely empty product. No error anywhere.
**Why it matters:** a silent fallback converts a deploy misconfiguration into "the product has no data", which is much harder to diagnose and looks identical to a working-but-empty account.
**Fix:** fail loudly — `const BASE = process.env.NEXT_PUBLIC_API_URL; if (!BASE) throw new Error(...)` at module scope, or default to same-origin `/api`. Also: five copies of the same constant; `lib/api.ts` should export it.

**LOW — no secrets reachable from client code (verified)**
`.env.local` contains only `NEXT_PUBLIC_API_URL`. Grep for `NEXT_PUBLIC` returns those five lines and nothing else. No key material in client code. **This is done correctly.**

**LOW — `@anthropic-ai/sdk` is a frontend dependency and is never imported**
`package.json:12`. Grep across `app/`, `components/`, `lib/` returns zero references. `lightweight-charts` (`package.json:17`) is likewise unused — `klinecharts` is the real one.
**Why it matters:** an LLM SDK in a client bundle's dependency tree implies a key was once used there, and invites someone to use one again. Remove both.

**LOW — create-next-app leftovers still shipped**
- `app/favicon.ico` is 25,931 bytes — byte-for-byte the default Next.js favicon. **The browser tab shows the Next.js logo.**
- `public/next.svg`, `vercel.svg`, `globe.svg`, `window.svg`, `file.svg` — all default, none referenced anywhere.
- `README.md` is the unedited create-next-app template ("bootstrapped with create-next-app", links to Vercel font docs).
- `app/api/` is an empty directory.
**Fix:** a favicon is a one-hour job and it is the first thing a user sees.

**LOW — no `TODO`/`FIXME`/`console.*`/`alert()`/`debugger` anywhere in shipped paths (verified).** Clean.

---

## 2. Error and empty states

The dominant defect in this codebase. **Every data-fetching component treats failure as emptiness.** Below, "loading / failed / empty" means: are those three states distinguishable to the user?

**CRITICAL — a server error tells the user their account does not exist**
`lib/api.ts:218-220` — `getPaperPortfolio()` wraps everything in `try/catch` and returns `null` on any failure. `app/dashboard/portfolio/page.tsx:104-107` renders `null` as:
> *"No paper account yet. Place your first trade →"*

**What the user experiences:** their portfolio is down. They see a confident statement that they have no account, with a call to action to start over. If they have positions, they will assume they lost them.
**Why it matters:** this is the worst-outcome variant of the pattern. It is not "we couldn't load this" — it is an affirmative false claim about the user's money.
**Fix:** `getPaperPortfolio` must distinguish "404 / empty list" from "request failed" and the page must render three branches. Do not reuse the empty copy for the error branch.

**CRITICAL — cash balance falls back to ₹0 on failure**
`lib/api.ts:304-311` — `getPaperCashBalance()` catches and returns `0`. `OrderTicket.tsx:139` renders `Balance ₹0`.
**What the user experiences:** they open the order ticket, see a balance of ₹0, and conclude they are out of money.
**Fix:** return `null` on failure (the component already handles `null` as `"—"` at `:139`) and show a retry.

**HIGH — the default landing page explains a server error as a schedule**
`app/dashboard/brief/page.tsx:133-137` — `.catch(() => setBrief(null))`; `:151-163` renders:
> *"No brief yet — The morning brief is generated automatically at 06:30 IST on trading days, after the US close and before the Indian market opens."*

**What the user experiences:** the Brief is where `/dashboard` sends them outside market hours (`app/dashboard/page.tsx:30`), i.e. most of the day. On any API failure they get a calm, specific, wrong explanation.
**Fix:** separate the `null` (no brief published) branch from the `catch` (request failed) branch.

**HIGH — the quote failure renders the stock at ₹0.00**
`app/dashboard/terminal/page.tsx:215` — `.catch(() => {})`, and `:316-318` — `const ltp = quote?.ltp ?? 0`.
**What the user experiences:** the terminal header shows **`RELIANCE NSE ₹0.00 +0.00 (0.00%)`** in green. Not a skeleton, not a dash — a price of zero, styled exactly like a real one. That same `ltp` is passed into `OrderTicket` (`:609`), so the ticket header also shows ₹0.00 and the "Req" total computes off it.
**Why it matters:** a price is the single most trusted number on the screen. Rendering a fetch failure as a number is worse than rendering nothing.
**Fix:** `ltp === null` → `—` with a "price unavailable" affordance; disable the order ticket.

**HIGH — signals list: failure and empty are the same screen, and it polls silently**
`app/dashboard/signals/page.tsx:72` — `.catch(() => {})` inside a 30-second `setInterval` (`:74`).
**What the user experiences:** "No signals yet. The screener runs every 15 min during market hours…" whether the screener genuinely produced nothing or the API is returning 500 every 30 seconds forever. No indication either way.
**Fix:** track `error` state; show "Couldn't load signals — retry" and stop the poll after N consecutive failures.

**MEDIUM — watchlist removal fails silently by design**
`app/dashboard/terminal/page.tsx:307-314` — `catch { /* best-effort — leave it in the list if the delete failed */ }`.
**What the user experiences:** they click the × on a watchlist row, it doesn't disappear, and nothing explains why. They click again. Nothing.
**Fix:** it already has a `watchlistError` bar at `:482` — use it.

**MEDIUM — portfolio reset failure is completely silent**
`app/dashboard/portfolio/page.tsx:39` — `catch { /* ignore */ }`, then `:41` closes the confirm UI regardless.
**What the user experiences:** they click "Yes, reset", the confirmation collapses, and the page shows exactly the same numbers. Did it work? Did it half-work? No signal at all.
**Fix:** keep the confirmation open and show the failure.

**MEDIUM — market status failures leave the header showing "—" forever**
`app/dashboard/layout.tsx:28-29` — two `.catch(() => {})`, one on mount and one per 60s interval.
**What the user experiences:** NIFTY and SENSEX read "—" indefinitely with no explanation, and the OPEN/CLOSED chip disappears entirely (`:99` renders only `if (mkt)`), so the user loses the only market-session indicator in the product with no idea why.

**MEDIUM — watchlist quote failures silently drop rows' prices**
`app/dashboard/terminal/page.tsx:203-208` — `Promise.allSettled`, rejected entries just omitted from the map, and `:370` renders the price block only `if (sq)`. Some watchlist rows have prices, some don't, no reason given. (The `allSettled` choice is right; the silent omission is not.)

**LOW — no request timeouts anywhere in the frontend**
`lib/api.ts:4` uses bare `fetch` with no `AbortSignal`. The API's chat route allows 60s upstream (`upstream-http.client.ts:13`). If the API itself hangs, the terminal's "Analyzing…" spinner (`terminal/page.tsx:474`) and "Thinking… (up to 15s)" (`:709`) spin forever with no cancel.
**Fix:** `AbortSignal.timeout()` in `req()`, plus a user-visible "taking longer than usual — cancel?" after ~20s.

---

## 3. Flow closure

**CRITICAL — the order confirm button can be clicked twice**
`components/OrderTicket.tsx:177` — `<button onClick={handleConfirm}>` with no `disabled`, and `handleConfirm` (`:56-67`) sets no in-flight state before `await placePaperOrder(...)`.
**What the user experiences:** they click "Confirm BUY". Nothing changes for as long as the round-trip takes (the modal stays exactly as it was — see §4). A user who isn't sure it registered clicks again. Two orders execute.
**Why it matters:** the backend author explicitly anticipated this — `paper-trading.service.ts:243-248` documents the atomic `$inc` guard as existing because a double-clicked buy was "trivially reachable". But that guard only prevents *spending money you don't have*. With sufficient cash, both orders fill, and the user owns double.
**Fix:** `const [placing, setPlacing] = useState(false)`; guard at the top of `handleConfirm`, `disabled={placing}` on the button, and change the label to "Placing…".

**CRITICAL — "Limit" is a lie**
`components/OrderTicket.tsx:27` defaults `priceMode` to `"Limit"`. `:58` calls `placePaperOrder({ …, limitPrice })` and **never sends `type`**. `paper-trading.service.ts:177` therefore stores `type: OrderType.MARKET`, `:184` executes immediately, and the limit-reachability check at `:220` (`if (order.type === OrderType.LIMIT …)`) never runs. The fill is `executedPrice = ltp` (`:231`).
Then `OrderTicket.tsx:190` reports the outcome as `{tab} {qty} × {symbol} @ ₹{price}` — **`price` is the limit the user typed, not `order.executedPrice` which the API returned.**
**What the user experiences:** they set a limit of ₹2,840 on a stock trading at ₹2,851, confirm a modal that says "Price ₹2,840", the order fills at ₹2,851, and a green toast tells them it filled at ₹2,840. The Orders tab later shows ₹2,851 (`portfolio/page.tsx:179` correctly prefers `executedPrice`), so the numbers contradict each other across two screens.
**Fix:** send `type: priceMode === "Limit" ? "LIMIT" : "MARKET"`, and render `res.executedPrice` in the toast. `placePaperOrder` already returns the `ApiOrder`; the return value is currently discarded.

**HIGH — the order-type selector does nothing**
`components/OrderTicket.tsx:102-107` — Delivery / Intraday / **MTF 2.86×**. `orderType` is used only in the confirm modal's summary row (`:165`) and is never sent to the API.
**What the user experiences:** they select "MTF 2.86×" — margin funding, a leverage claim — confirm an order that says "Type: MTF", and get a plain cash-settled fill. In a product about intraday trading, "Intraday" doing nothing is not a cosmetic gap.
**Fix:** remove the control until it is wired, or label it explicitly as not yet supported. Do not display a leverage multiplier the engine does not apply.

**HIGH — resetting the paper account destroys trade history without saying so**
`app/dashboard/portfolio/page.tsx:66` — the confirmation reads only *"Reset to ₹1,00,000?"*.
The backend (`paper-trading.service.ts:110-118`) `deleteMany`s **positions, orders and trades**.
**What the user experiences:** they think they are topping up cash. Every trade they have ever made — the entire record they might be evaluating themselves against — is gone, unrecoverably, with no second step.
**Fix:** name the consequence: *"Reset the paper account? This deletes all positions, orders and trade history and restores ₹1,00,000. This cannot be undone."* Consider type-to-confirm.

**HIGH — signup has no verification step, and the profile page claims otherwise**
`app/register/page.tsx:33-34` → success toast → `window.location.href = "/dashboard/terminal"` after 700ms. `ai-trader-api/src/auth/auth.service.ts:21-28` creates the user and signs a token immediately. `auth/schemas/user.schema.ts` has **no** `emailVerified` field.
Then `app/dashboard/profile/page.tsx:100` renders a hardcoded green **"Verified"** badge next to the email.
**What the user experiences:** they sign up with any string that passes `type="email"`, are never asked to confirm it, and are then told by the product that their address is verified.
**Why it matters:** an unearned trust badge in a financial product. Also means account recovery is impossible — see below.
**Fix:** either implement verification, or delete the badge. The badge is the urgent half.

**HIGH — "Forgot password?" goes nowhere**
`app/login/page.tsx:96` — `<a href="#">Forgot password?</a>`.
**What the user experiences:** they click it, the page jumps to the top, nothing happens. With no email verification and no reset flow, a forgotten password is a permanently lost account.
**Fix:** if there is no reset endpoint, remove the link rather than dangling it.

**MEDIUM — legal links are all `href="#"`**
`app/page.tsx:566` (Privacy Policy, Terms of Service, Disclaimer), `app/login/page.tsx:120`, `app/register/page.tsx:126` ("By signing in you agree to our Terms and Privacy Policy").
**What the user experiences:** they are asked to agree to documents that do not exist and cannot be read.

**MEDIUM — dead rows in Settings**
`app/dashboard/profile/page.tsx:105` ("Password — Change your password") and `:128` ("Help & support — FAQs, contact support") are plain `<div>`s inside a `Section`, styled identically to the row above them that *is* a `<Link>` (`:129`). Not clickable, not focusable, no affordance difference.
**What the user experiences:** they click "Change your password" repeatedly and nothing happens.

**MEDIUM — two toggles that forget**
`app/dashboard/profile/page.tsx:112` (Two-factor authentication) and `:123` (Signal notifications) are `useState` only — no persistence, no API call.
**What the user experiences:** they enable 2FA, the label changes to "Enabled", they refresh, it says "Disabled". Worse than absence: for the duration of that session the user believes their account is protected. Note also that "Signal notifications — Alerts for new signals on your watchlist" describes a feature that does not exist anywhere in the product.

**MEDIUM — "Open in Terminal" throws away the symbol**
`app/dashboard/signals/page.tsx:230` — `<Link href="/dashboard/terminal">` inside an expanded signal row for a specific stock.
`app/dashboard/portfolio/page.tsx:142` — the position symbol links to `/dashboard/terminal` with no query.
Both land on RELIANCE (`terminal/page.tsx:84`, the hardcoded default).
**What the user experiences:** they expand the TATAMOTORS signal, click "Open in Terminal →", and arrive at a Reliance chart. The mechanism to do this right already exists and is already used — `brief/page.tsx:140` does `?symbol=${encodeURIComponent(symbol)}` and `terminal/page.tsx:81-85` reads it.
**Fix:** three characters of query string in two places.

**MEDIUM — the Signals page is not reachable from the navigation**
`app/dashboard/layout.tsx:10-14` — `TABS` is Brief / Terminal / Portfolio. `/dashboard/signals` exists, is statically built, holds the signals table, the Performance/track-record tab and News, and can only be reached from: an empty-state link (`signals` isn't shown when it has content), or "See our track record →" on the Brief (`brief/page.tsx:235`).
**What the user experiences:** once they navigate there, no nav tab is highlighted, so they have no idea where they are or how to get back. The track record is effectively hidden — which is exactly backwards for a product whose credibility depends on publishing it.

**MEDIUM — the symbol search does not search**
`app/dashboard/terminal/page.tsx:322-324` — `matches` filters the **watchlist**, nothing else. There is no symbol lookup endpoint call anywhere. `:360` tells a new user *"Watchlist empty — search & add a symbol."*
**What the user experiences:** a brand-new user reads an instruction to search, types "TATAMOTORS", and gets "Watchlist empty — search & add a symbol" again, plus a `Load "TATAMOTORS" anyway →` escape hatch (`:386`) whose wording implies it's a bad idea. It is in fact the only way the feature works.
Additionally: **the search input has no Enter handler** (`:342-349` has `onChange` and `onFocus` only). Typing a symbol and pressing Enter does nothing.
**Fix:** at minimum, rewrite the copy to describe what actually happens ("Type a symbol and press Enter to load it") and wire `onKeyDown`.

**LOW — chat suggestion chips don't send**
`app/dashboard/terminal/page.tsx:659` — `onClick={() => { setChatInput(s); }}`. Clicking "Draw the trend line" fills the box; the user must then find and click send. A one-word change (`sendChat` after set) closes it.

**Chat failure behaviour (traced):** `sendChat` `catch` (`:181-182`) appends an assistant bubble reading "Something went wrong — please try again." That is the right shape — a failure that stays in the conversation rather than a toast. Two gaps: (a) the user's own message stays in history and will be replayed as context on the next call, so the agent sees a question it never answered; (b) a 60s upstream timeout and a 400 validation error produce identical text. The "up to 15s" copy at `:709` and `:547` is also wrong — the upstream budget is 60s (`upstream-http.client.ts:13`).

---

## 4. Notifications and feedback

**HIGH — there is no notification system; there are four improvisations**
1. Bottom-right toast card, hand-rolled three times with near-identical markup: `login/page.tsx:124-134`, `register/page.tsx:130-140`, `OrderTicket.tsx:183-206`.
2. Inline red bar under the toolbar: `terminal/page.tsx:481-483`.
3. Inline text inside a panel: `terminal/page.tsx:550`.
4. A chat bubble: `terminal/page.tsx:182`.
5. Nothing at all: portfolio reset (`portfolio/page.tsx:39`), watchlist delete (`terminal/page.tsx:311`).

**Why it matters:** the user has to learn five places to look for whether something worked, and two of the most consequential actions use the "nothing at all" mechanism.
**Fix:** one toast/inline primitive with `role="status"` / `aria-live="polite"`, used everywhere.

**HIGH — order confirmation has no sub-100ms feedback**
`OrderTicket.tsx:177` — clicking Confirm produces **zero** visual change until the network round-trip resolves. The modal sits there, the button doesn't depress or spin, nothing.
**Why it matters:** this is the direct cause of the double-submit above. The feedback gap and the duplicate-order bug are the same bug.

**MEDIUM — the success toast auto-dismisses and takes its call-to-action with it**
`OrderTicket.tsx:61` — `setTimeout(… setStep("form") …, 2800)`. The toast at `:183-193` contains the only "View in Portfolio →" link. It vanishes after 2.8 seconds. There is no history of past confirmations.
**What the user experiences:** they place an order, glance at the chart, look back, and the confirmation is gone. Did it go through? The only way to check is to navigate to Portfolio manually.
**Fix:** don't auto-dismiss confirmations that carry an action, or make the dismissal manual.

**MEDIUM — optimistic watchlist update is never rolled back**
`terminal/page.tsx:299` appends the returned item — that one is fine (server-confirmed). But `:310` removes optimistically and `:311-313` deliberately does not restore on failure, leaving the UI and server disagreeing until reload.

**CRITICAL (honesty) — the app never tells the user the data is delayed or stale**
The provider is documented as *"free, delayed (~15-20 min)"* (`ai-trader-signals/app/market/providers/yfinance_provider.py:2`). Nothing in the UI says so — not the terminal header (`terminal/page.tsx:396-403`), not the index strip (`layout.tsx:83-106`), not the order ticket (`OrderTicket.tsx:76`), not positions LTP (`portfolio/page.tsx:147`).
Worse, the terminal **polls the quote every 5 seconds** (`terminal/page.tsx:217`) and feeds it into the live-candle updater (`CandlestickChart.tsx:173-185`), so a 15-minute-old price visibly ticks. The design actively simulates real-time.
**What the user experiences:** a number that updates every few seconds, drawn onto a live candle, which is a quarter of an hour old. If they act on it against a real broker screen, they are trading a different market.
**Fix:** a persistent "Prices delayed ~15 min" label next to the LTP, and stop polling when the market is closed.

**HIGH — the backend computes staleness and the frontend discards it**
`ai-trader-signals/app/market/router.py:95-98` returns a `degraded` flag with the comment: *"A null ltp above means the quote did not arrive, not that the index is at zero. Without this the frontend cannot tell a stale panel from a flat market."* It also returns `is_holiday`, `is_square_off`, `next_open`, `is_trading_day`, `holiday_calendar_known`.
`lib/api.ts:237-242` — `ApiMarketStatus` declares **only** `nse_open`, `timestamp`, `nifty50`, `sensex`. Every one of those fields is dropped.
**What the user experiences:** on a trading holiday, the header says "CLOSED" and shows Friday's Nifty close with no date and no "reopens Tuesday". During the square-off window, nothing indicates it. When the quote leg fails, the panel shows "—" identically to any other failure.
**Fix:** the data is already on the wire. Widen the type and render it.

**MEDIUM — market status is hidden on small screens**
`app/dashboard/layout.tsx:83` — `hidden md:flex` wraps *both* the index quotes and the OPEN/CLOSED chip. Below 768px the user has no session indicator at all.

---

## 5. Financial-product honesty

Weighted heaviest, as instructed. The Brief page gets this right; almost nothing else does.

**CRITICAL — no disclaimer on the Signals page**
`app/dashboard/signals/page.tsx` — 390 lines rendering a full-width table of BUY/SELL calls with entry, target, stop and R:R in rupees (`:186-237`), a Performance tab with win rates, and news. **Zero disclaimer text anywhere in the file.**
By contrast: `brief/page.tsx:231` renders a well-written server-supplied disclaimer; `portfolio/page.tsx:196` has "Simulated paper trading — no real money involved."; `app/page.tsx:580` has a footer line.
**What the user experiences:** the densest concentration of money-attached suggestions in the product carries no qualification at all.
**Fix:** the same disclaimer, in the same place, on every surface that shows a suggestion.

**CRITICAL — no disclaimer on the terminal's Signal panel or chat results**
`terminal/page.tsx:562-602` shows direction, "% confidence", entry/target/stop and a "Use this signal → BUY" button that pre-fills an order (`:598`). No qualification.
`terminal/page.tsx:694-701` renders a trade simulation with "Profit at target +₹X" and "Loss at stop ₹Y". No qualification.
**Why it matters:** the terminal is where the money button is. It is the one surface where the disclaimer is load-bearing.

**CRITICAL — win rate is coloured against 50%, not against this system's breakeven**
`app/dashboard/signals/page.tsx:260` — `c: perf.summary.winRate >= 50 ? "var(--buy)" : "var(--sell)"`
`app/dashboard/signals/page.tsx:288` — same rule per bucket.
This system's breakeven is ~34.6% (`docs/checklist/05-honest-reporting.md:30`), because the win/loss ratio is asymmetric.
**What the user experiences:** a 42% win rate — comfortably profitable for this system — renders in the same red as a catastrophic 12%. The UI teaches the user that anything under half is failure, which is the single most common misunderstanding in retail trading, and the product is actively reinforcing it.
**Fix:** compute breakeven from the observed avg-win / avg-loss ratio, colour against that, and put the number on screen: *"41% win rate · breakeven for this system is 35%"*. Expectancy per trade next to it would be better than either.

**CRITICAL — n=1 samples rendered as confident percentages**
`ai-trader-api/src/signals/eval.ts:78-90` — `bucketBy` computes `winRate = Math.round(wins / items.length * 100)` with **no minimum sample size**.
`signals/page.tsx:284-289` renders every returned bucket: `{b.key}` · `{b.trades} trades` · `{b.winRate}%` in green or red.
**What the user experiences:** a "By symbol" row reading **"TATAMOTORS · 1 trades · 0%"** in red. Or "100%" in green off two trades. The percentage is styled identically to one computed from 200 trades. (Also: `1 trades` — no pluralisation, `signals/page.tsx:287`.)
**Fix:** suppress buckets below n≈20, or render them as raw counts ("1W · 0L") with no percentage. A percentage implies a rate; one observation is not a rate.

**HIGH — the chat backtest reports a win rate with no sample floor and drops the honesty field**
`terminal/page.tsx:682-683` renders `Trades {num_trades}` and `Win rate {win_rate}%` from an ad-hoc strategy backtest. `ai-trader-signals/app/signals/analysis.py:189` computes it over however many trades occurred — potentially one.
More pointedly: `analysis.py:176-187` deliberately computes and returns `open_trade`, with the comment *"A position still open at the end of the window is NOT a completed trade and is excluded from the win rate — but it must be reported, not silently dropped. A strategy that enters and never exits would otherwise show a flattering win rate…"*.
`lib/api.ts:125-132` — `ChatStrategyResult` **does not declare `open_trade`**, and `terminal/page.tsx:675-692` never renders it.
**What the user experiences:** exactly the flattering win rate the backend author wrote code to prevent. The honesty measure exists and the UI throws it away.

**HIGH — stored signals are shown with no age**
`terminal/page.tsx:58-69` — `DisplaySignal` carries direction, confidence, entry, target, stop, reasoning, indicators. `fromApiSignal` **drops `generatedAt` and `createdAt`**, which the API does return (`lib/api.ts:25-26`).
`getSignalsBySymbol` (`terminal/page.tsx:237-238`) takes `sigs[0]` regardless of date. The panel is labelled "on-demand" (`:541`).
**What the user experiences:** they open a symbol and see an entry/target/stop, presented identically to one generated seconds ago, that may be three weeks old and computed from a price level that no longer exists. Then "Use this signal → BUY" pre-fills an order at that stale entry price (`:598`).
**Why it matters:** trade levels have a shelf life measured in hours. The Brief page understands this — its disclaimer says levels "must be revalidated after the open". The terminal shows no date at all.
**Fix:** show "generated 3 days ago" and visually degrade or refuse anything older than the current session.

**HIGH — the landing page presents fabricated analysis as live**
`app/page.tsx:65-114` — `DEMO_STOCKS`, four entries with specific rupee/dollar levels: RELIANCE entry ₹2,847 / target ₹2,910 / stop ₹2,800, 78% confidence; AAPL $325.80; TCS ₹4,222; INFY ₹1,892. The code comment calls them "clearly illustrative" — **the UI never does.**
`app/page.tsx:121-125` frames them with a pulsing "live" dot and the text **`ANALYZING RELIANCE · NSE`**.
`:344` claims "RSI, MACD, EMA cross, SuperTrend, ADX, VWAP — computed live from actual price history, not estimated."
**What the user experiences:** a first-time visitor sees what reads unmistakably as a live analysis of a real, named, currently-tradeable stock, with specific price levels, an animated "analyzing" state, and a confidence figure. The only disclaimer is a 12px footer line 500 pixels below the fold.
**Fix:** label the panel "Example" / "Illustrative". This is a one-word fix and it is the difference between a demo and a misrepresentation.

**HIGH — the landing page claims US market support the product does not ship**
`app/page.tsx:353` — "NASDAQ · AAPL, MSFT, TSLA"; `:345` — "Search any NSE, BSE, or US stock"; `:361` FAQ — "NSE and BSE for Indian equities, plus US stocks"; `:435` — "NSE, BSE & US stocks" with a green tick; and an entire AAPL/NASDAQ demo card.
In the actual app: `terminal/page.tsx:287-292` — `selectSymbol(sym, exchange = "NSE")`. Every call site passes NSE or a watchlist entry (which was itself added as NSE at `:298`). **There is no control anywhere in the UI that sets a non-NSE exchange.** The chat endpoint hard-rejects anything else: `ai-trader-api/src/signals/signals.controller.ts:10` — `EXCHANGES = new Set(['NSE', 'BSE'])`, `:53` throws on the rest.
**What the user experiences:** they sign up on the strength of the AAPL demo and discover there is no way to look at a US stock.
**Fix:** remove the claims, or ship the exchange selector.

**MEDIUM — "confidence" implies a calibration that is never evidenced**
Rendered as a bare percentage at `terminal/page.tsx:566`, `signals/page.tsx:208`, `brief/page.tsx:72`, `CandlestickChart.tsx:209`, and used as a filter threshold (`signals/page.tsx:165` — "High ≥75%"). It is an LLM's self-reported number. The only calibration evidence in the product is the Performance page's "By confidence" bucket — which is on a page not in the nav, and subject to the n=1 problem above.
`ai-trader-signals/app/signals/prompts.py:121` instructs the agent to say *"Overall signal accuracy currently sits near breakeven"* if asked — the chat is more honest than the UI.
**Fix:** either label it as a model self-assessment, or put the observed hit rate for that confidence band directly next to it.

**MEDIUM — losses and gains are formatted differently**
`portfolio/page.tsx:149` and `terminal/page.tsx:635` — `{up ? "+" : ""}₹{p.unrealisedPnl.toLocaleString("en-IN")}`.
A gain renders **`+₹1,234`**. A loss renders **`₹-1,234`** — the minus sign lands *inside*, after the currency symbol. Different glyph order, different visual weight, only for losses.
**Fix:** `${pnl < 0 ? "−" : "+"}₹${Math.abs(pnl).toLocaleString("en-IN")}`.

**HIGH — percentage change communicates its sign by colour alone**
`terminal/page.tsx:401` — `({Math.abs(changePct).toFixed(2)}%)`
`OrderTicket.tsx:76` — `({changePct >= 0 ? "+" : ""}{Math.abs(changePct).toFixed(2)}%)`
**What the user experiences:** a stock down 2% renders as **`-56.30 (2.00%)`** — the absolute change is negative, the percentage is positive, and only the red colour reconciles them. On the order ticket it's worse: the `+` is conditional but `Math.abs` is not, so a decline shows a bare `(2.00%)`.
**Why it matters:** this is the textbook colour-only failure (WCAG 1.4.1), and here it is also just wrong: two numbers describing the same move disagree about its direction.
**Fix:** drop `Math.abs`.

**MEDIUM — raw unformatted floats in price fields**
`terminal/page.tsx:570-572` — `₹${displaySignal.entryPrice}` (no `toFixed`, no locale)
`brief/page.tsx:89` — `₹{x.v}` (entry/target/stop)
`CandlestickChart.tsx:199-201` — `Entry ₹{signal.entryPrice}`
Everywhere else the app uses `.toLocaleString("en-IN")` or `.toFixed(2)`.
**What the user experiences:** `₹2847.35` next to `₹2,847.35` on adjacent screens, and any float artefact from the model or the ATR arithmetic prints in full.

---

## 6. Interaction and state

**HIGH — switching right-panel tabs destroys the half-filled order form**
`terminal/page.tsx:608-610` — `{rightTab === "trade" && <OrderTicket … />}`. The component unmounts on tab switch, so `qty`, `price`, `orderType`, `priceMode` and `tab` (BUY/SELL) all reset.
**What the user experiences:** they enter 50 shares at ₹2,845, click "Positions" to check exposure, click back to "Trade", and the form is empty with the price re-seeded from the current LTP (`:38-43`).
**Fix:** render all four panels and toggle with `hidden`, or lift the ticket state.

**HIGH — toggling any indicator destroys the chart, the zoom, and every drawing**
`CandlestickChart.tsx:170` — the init effect's dependency array includes `indicators`, `signal`, `bars`, `height`, `fill`. Any change re-runs `init()` / `dispose()`.
**What the user experiences:** they zoom into an area, draw three trend lines, then toggle RSI on — the chart blanks, rebuilds at the default zoom, and their drawings are gone.
**Worse, in chat:** `terminal/page.tsx:169` calls `applyDrawings(res.drawings)`, then `:173-178` calls `setIndicators(...)` if the agent asked to toggle indicators. The setState re-inits the chart and **wipes the drawings the agent just made in the same response.** The user asks "draw the trend line and show me RSI" and gets RSI and no trend line.
**Fix:** split the effect — init once on mount, and handle `indicators` / `signal` via `createIndicator` / `removeIndicator` / `removeOverlay` in separate effects.

**MEDIUM — modal has no focus management, no Escape, no focus trap**
`OrderTicket.tsx:155-181` — a `fixed inset-0` overlay with no `role="dialog"`, no `aria-modal`, no autofocus on Cancel/Confirm, no Escape handler, no focus return, and no `inert`/scroll-lock on the background.
**What the user experiences:** keyboard users must tab through the entire page behind the modal to reach Confirm; Escape does nothing; after closing, focus is lost to `<body>`.
Grep confirms `onKeyDown` appears exactly once in the whole app (`terminal/page.tsx:720`, the chat Enter key) and `autoFocus`/`tabIndex`/`Escape` appear zero times.

**MEDIUM — no focus management on route change**
Every page transition is a `<Link>` or `router.push` with no focus reset and no skip link. `app/dashboard/page.tsx` redirects via `router.replace` in an effect, so a screen-reader user lands on a spinner and is then silently moved.

**MEDIUM — dropdowns close on `click` but not on Escape or blur**
`terminal/page.tsx:244-251` and `layout.tsx:33-39` — `document.addEventListener("click", …)` only. The search dropdown, indicator menu and avatar menu cannot be dismissed from the keyboard.

**MEDIUM — layout shift: three of four surfaces have no skeleton**
Only `portfolio/page.tsx:89-94` uses a real skeleton (`animate-pulse` at the correct height). Everywhere else a centred spinner or a text line occupies a different box than the content that replaces it: `terminal/page.tsx:505-508` (chart), `signals/page.tsx:179-180`, `:249-250`, `:355-356`, `brief/page.tsx:143-149` (whole-page spinner replaced by a dense multi-section layout).

**LOW — the chat panel forces a scrollbar even when empty**
`terminal/page.tsx:648` — `min-h-[calc(100vh-9rem)]` inside a container that is already `flex-1 overflow-y-auto` (`:531`). The chat column is always taller than its scroller.

**LOW — signal polling never pauses**
`signals/page.tsx:74` polls every 30s and `terminal/page.tsx:217` every 5s, regardless of tab visibility or market session. On a slow or metered connection this is constant background traffic for data that changes twice an hour.

**19 ESLint errors, mostly one rule.** `react-hooks/set-state-in-effect` fires 11 times (`terminal/page.tsx:193,202,214,223,233,256`; `signals/page.tsx:80,89`; `portfolio/page.tsx:31`; `page.tsx:221`; `OrderTicket.tsx:47`) and `react-hooks/refs` once (`CandlestickChart.tsx:47` — ref mutated during render). These are cascading-render warnings, not crashes, but `OrderTicket.tsx:45-50` is the one that matters: the prefill effect writes three pieces of state on a prop it doesn't compare, so re-applying the *same* signal silently resets quantity to "1". `tsc --noEmit` and `next build` both pass cleanly.

---

## 7. Visual and content craft

**Numeric alignment is largely correct** — financial columns use `text-right` in both header and cell (`signals/page.tsx:175-176` / `:210-214`, `portfolio/page.tsx:134` / `:145-150`) and `font-mono` resolves to Geist Mono, which is fixed-width, so digits do align. Only `brief/page.tsx:37` uses an explicit `tabular-nums`. I'd add it to the `font-mono` utility for safety, but this is not currently broken.

**MEDIUM — inconsistent date and time formatting across pages**
- `signals/page.tsx:33-35` — today's signals show `HH:MM`, older ones show `9 Feb`. Neither is labelled, so "14:30" and "9 Feb" appear in the same column with no indication which is which.
- `signals/page.tsx:39-46` — news uses relative "3h ago".
- `brief/page.tsx:177` — `{brief.date}` raw from the API (`YYYY-MM-DD`, `ai-trader-signals/app/signals/brief.py:114`) rendered as-is: **"2026-07-26 · generated 06:31 IST"**. ISO dates in a consumer UI.
- The Orders table (`portfolio/page.tsx:169-190`) shows **no date at all**, though `createdAt` is on the type (`lib/api.ts:199`).

**MEDIUM — typography: 9px and 9.5px text used for real content**
`text-[9px]` and `text-[9.5px]` appear at `signals/page.tsx:202,317,319,370`, `terminal/page.tsx:413,575`, `portfolio/page.tsx:118,176,181`, `brief/page.tsx:75,88`, `profile/page.tsx:90,91,100`. These carry order status, outcome labels, and the Entry/Target/Stop captions — not decoration.

**MEDIUM — amber `#e0ab4a` is hardcoded outside the token system**
`signals/page.tsx:206,213`, `portfolio/page.tsx:183-184`, `profile/page.tsx:91`. `globals.css:54-92` defines no amber token, and `portfolio/page.tsx:183` even references a non-existent `var(--amber, #e0ab4a)` with a fallback. It carries meaning (medium confidence, R:R, PENDING status) but lives outside the palette the file's own comment (`globals.css:48-53`) says is deliberate.

**LOW — straight quotes amid curly ones**
`app/page.tsx:454` (`don't`), `:468` (`"Ask AI"`), `signals/page.tsx:330` (`"no data"`) render straight, while `terminal/page.tsx:388,559` correctly use `&ldquo;`/`&rdquo;`. Flagged by `react/no-unescaped-entities`.

**LOW — "1 trades"**
`signals/page.tsx:287` — `{b.trades} trades`, unpluralised.

**Microcopy is a strength, not a finding.** `brief/page.tsx:216-217` ("Sitting out is a position — no trade is better than a forced one"), `signals/page.tsx:246` ("did the target or the stop hit first?"), `signals/page.tsx:330` (the conservative-fill note) are written by someone who understands the domain and respects the reader. No lorem, no filler, no machine-generated padding anywhere in the app.

---

## 8. Accessibility

**HIGH (WCAG 1.4.3 fail, confirmed by calculation) — the primary colour fails contrast as text**
`--primary: #6c5ce7` on `--background: #0b0e14` = **3.99:1**. On `--card: #12151c` = **3.76:1**. AA requires 4.5:1 for text under 18.66px.
Every one of these uses it as text: active nav/tab labels (`signals/page.tsx:122`, `terminal/page.tsx:525`, `portfolio/page.tsx:115`), every inline link (`signals/page.tsx:184,253`, `portfolio/page.tsx:106,129`, `OrderTicket.tsx:191`), "Show indicator readout" (`terminal/page.tsx:583`), "Why this?" (`brief/page.tsx:113`), "See our track record" (`brief/page.tsx:236`), the `Load "X" anyway` action (`terminal/page.tsx:387`) — all at 11–14px.
**Fix:** lighten to roughly `#8b7cf0` for text use (keeps ≥4.5:1) while retaining `#6c5ce7` for fills, where it is fine (`#0b0e14` on `#6c5ce7` = 4.86:1, `#ffffff` on it = 4.86:1).
*Checked and passing:* `--muted-foreground #8b8a9e` on background = 5.68:1, on `--secondary` = 4.88:1. `--buy #16c784` = 8.8:1, `--sell #f0525d` = 5.6:1. Those are fine.

**HIGH (WCAG 2.1.1 fail) — the signals table cannot be operated by keyboard**
`signals/page.tsx:192-196` — the expandable row is a `<div onClick={…}>` with no `tabIndex`, no `role="button"`, no key handler.
**What the user experiences:** a keyboard user cannot read any signal's reasoning or indicators. The content is unreachable.
`portfolio/page.tsx:140` (position rows) has the same structure but is non-interactive, so it's only a semantics issue there.

**HIGH — zero ARIA in application code**
Grep for `aria-`, `role=`, `alt=` across `app/` and the two real components returns **nothing** outside the untouched shadcn `components/ui/*` files.
Consequences:
- The chart (`CandlestickChart.tsx:187`) is a bare `<div>` that KLineChart fills with canvas. A screen reader gets nothing — no name, no role, no textual summary of price/indicators.
- The chat (`terminal/page.tsx:647-731`) is a `<div>` list with no `role="log"` / `aria-live`, so streamed assistant replies are never announced.
- The three toasts (`login:124`, `register:130`, `OrderTicket:183`) have no `role="status"`, so **order confirmations and failures are silent to screen readers.**
- Icon-only buttons carry `title` but no `aria-label`: the six drawing tools (`terminal/page.tsx:491`), Clear drawings (`:497`), watchlist remove (`:378`), chat send (`:725`), the avatar menu (`layout.tsx:110`).
- The dropdown menus have no `aria-expanded` / `aria-haspopup` / `role="menu"`.
- The tab strips (`terminal:523`, `signals:120`, `portfolio:113`) are `<button>` rows with no `role="tablist"` / `aria-selected` / `aria-controls`.
- The `Toggle` (`profile/page.tsx:44-49`) is a `<button>` with no text, no `role="switch"`, no `aria-checked` — an unlabelled empty control.

**MEDIUM — no financial data uses table semantics**
Grep: **no `<table>`, `<th>` or `<td>` anywhere in the codebase.** Every financial table is a CSS grid of divs (`signals/page.tsx:173`/`194`/`297`/`305`, `portfolio/page.tsx:133`/`140`/`166`/`170`). A screen reader reads eight unrelated values per row with no column association — "RELIANCE NSE BUY 78% 2847 2910 2800 2.5 14:30" as flat text.
**Fix:** real `<table>` markup. The grid CSS survives `display: grid` on `<table>`/`<tr>`.

**MEDIUM — focus indicators removed from every input and never replaced**
`focus:outline-none` at `login:90,101`, `register:91,99,107`, `OrderTicket:122,133`, `terminal:348,723`, substituted with a 1px border-colour change from `#232733` to `#6c5ce7`. `focus-visible` appears **zero times** in application code.
Buttons keep the UA default ring (usable in Chrome), so the app is inconsistently indicated: form fields have a weak custom indicator, buttons have a browser one, and nothing has a designed one.

**Keyboard operability of the terminal, end to end:** search cannot be submitted (no Enter handler, `:342`); drawing tools are focusable buttons but the canvas they draw on is not; period buttons work; the indicator menu opens but can't be closed by keyboard; the right-panel tabs work; the chat input works (Enter sends, `:720`); the order modal can be reached but not escaped. **Net: partially operable, with the chart itself entirely mouse-only.**

---

## 9. Responsive and cross-device

**HIGH — the terminal is desktop-only and does not say so**
`terminal/page.tsx:486-521` — a three-column flex row with **no breakpoint at any width**: a `w-11` (44px) tool rail, a `flex-1 min-w-0` chart, and a `w-[340px] shrink-0` right panel. Add the dashboard's `px-4` (32px) and 416px is consumed before the chart gets a pixel.
**What the user experiences on a 390px phone:** the chart column computes to roughly **zero width**. `CandlestickChart` still mounts and KLineChart initialises into a 0px container, so the user sees the tool rail, a black sliver, and a 340px panel — the product's central surface, rendered as nothing. At 768px the chart gets ~310px, narrower than the sidebar next to it. No message, no redirect, no "best on desktop" notice.
**Fix:** below `lg`, stack — chart full-width on top, panel below as a drawer, tool rail collapsed to a menu. Or gate it with an honest interstitial.

**MEDIUM — the toolbar silently drops controls instead of relocating them**
`terminal/page.tsx:441` — the entire period selector (1D…All) is `hidden lg:flex`. `:412,459,466` hide the Indicators/Watchlist button labels below `sm`. Below 1024px the user cannot change the chart timeframe **at all** — the control does not move, it disappears.

**No horizontal body scroll (verified).** `app/dashboard/layout.tsx:52` sets `h-screen … overflow-hidden` and `:141` repeats `overflow-hidden`. Content is clipped rather than scrolled — which is why the terminal crushes instead of overflowing. The landing page (`page.tsx:370`) is properly responsive with real `sm:`/`lg:` breakpoints throughout.

**LOW — the signals table has no small-screen treatment**
`signals/page.tsx:173,194` — a fixed 8-column grid (`grid-cols-[1.6fr_70px_90px_1fr_1fr_1fr_60px_60px]`) with no responsive variant inside an `overflow-hidden` card. Below ~900px the columns compress until the rupee figures wrap or clip. Same for the 6-column performance grid (`:297,305`) and the 5-column portfolio tables (`portfolio/page.tsx:133,166`).

---

## 10. Trust and polish

| Item | State | Detail |
|---|---|---|
| Favicon | **Default Next.js logo** | `app/favicon.ico`, 25,931 bytes — the unmodified create-next-app icon |
| Page title | **One title for the entire app** | `app/layout.tsx:24` is the only `metadata`. Every dashboard page is `"use client"`, and so is `app/dashboard/layout.tsx:1` — so **no route in the dashboard subtree can export `metadata` at all**. The Portfolio tab reads "AITrader — AI Trading Signals for NSE & BSE". With three tabs open they are indistinguishable. |
| Meta description | Present, good | `app/layout.tsx:25-26` — accurate and includes the paper-trading framing |
| Open Graph / Twitter | **Absent** | No `openGraph`, no `twitter`, no `opengraph-image`. A shared link renders as a bare URL with no image and no card. |
| 404 page | **Next.js default** | No `app/not-found.tsx`. Build output confirms `/_not-found` is the framework default — white background, black Inter text, in a product that is otherwise entirely dark. |
| 500 / error boundary | **Absent** | No `error.tsx` or `global-error.tsx` anywhere. Any render throw in a client page (all of them are client pages) blanks the route with the framework's default. Given the number of unguarded `.toFixed()` / `.toLocaleString()` calls on API-supplied values, this is reachable. |
| `robots.txt` / `sitemap` | Absent | Marketing concern, low priority |
| Middleware | Deprecated convention | `next build` warns: *"The 'middleware' file convention is deprecated. Please use 'proxy' instead."* Works today; will break on upgrade. |

---

## What is genuinely done well

Specific, not padding.

- **The Brief page is the model the rest of the app should follow.** `brief/page.tsx:212-219` — the empty state ("No candidates cleared the filters today … Sitting out is a position — no trade is better than a forced one") explains *why* nothing is there and reframes it as a valid outcome. `:74-78` and `:98` surface a `CONFLICTING SIGNAL` badge and colour conflict reasons in red — the page argues against its own suggestions. `:233-238` puts a "See our track record →" link directly under the disclaimer with a code comment saying the user "should never have to discover the real number elsewhere." That is a designer with a conscience.
- **The colour system is deliberate and documented.** `globals.css:48-53` reserves green/red exclusively for market direction and keeps the indigo brand accent out of that semantic space. The codebase honours it — I found no instance of `--buy`/`--sell` used decoratively.
- **`Promise.allSettled` for the watchlist quotes** (`terminal/page.tsx:203`) — one failing symbol doesn't blank the others. The right instinct, applied in the right place.
- **The signals/performance page explains its own methodology unprompted.** `signals/page.tsx:246` and `:330` — the conservative-fill rule (stop assumed first when a bar spans both) and the 58-day intraday history limit, both stated in plain language without being asked. Most products bury that.
- **KLineChart is loaded via dynamic import specifically to survive SSR** (`CandlestickChart.tsx:60-62`), with a comment explaining why. The bar-period inference from timestamp spacing (`:104-121`) is a thoughtful detail — axis labels are correct across every timeframe without configuration.
- **The paper-trading backend is more careful than the frontend consuming it.** The atomic `$inc` cash guard against races, the explicit compensating writes, the limit-reachability check, and the refusal to fill limits at the limit price are all correct and all commented with the failure they prevent. Several of the frontend findings above are the UI failing to use work that already exists.
- **`tsc --noEmit` is clean and `next build` passes with no warnings** beyond the middleware deprecation.
- **No secrets are reachable from client code.** Verified by exhaustive `NEXT_PUBLIC` grep.
- **Microcopy throughout reads as human.** No lorem, no placeholder, no machine-generated filler anywhere in the application.

---

## What I could not verify

- **Anything requiring a running app.** No dev server, no browser, no screenshots. Every rendering claim above is derived from reading the code. Where I say "the user sees ₹0.00" I am reading `quote?.ltp ?? 0` at `terminal/page.tsx:316` and the `toFixed(2)` at `:399` — I have not observed it.
- **Contrast ratios are computed, not measured.** I calculated relative luminance from the hex tokens in `globals.css:54-92` per WCAG 2.1. The 3.99:1 figure for `--primary` on `--background` I am confident in. Antialiasing and the `backdrop-blur` on the sticky nav (`page.tsx:373`) could shift effective contrast slightly in either direction.
- **The exact terminal breakpoint where the chart becomes unusable.** I computed 44 + 340 + 32 = 416px of fixed width against a `flex-1 min-w-0` chart, so the chart's width is (viewport − 416). Whether KLineChart renders degraded or throws below some threshold, I did not test.
- **Whether the Signals empty state is the common case.** I could not query the database. If signals are usually present, the "failure looks like empty" finding is less frequently hit — but no less wrong.
- **The real-world frequency of the double-submit.** It depends on network latency and user behaviour. The code path is unambiguous (`OrderTicket.tsx:177`, no guard, no in-flight state); the incidence rate is not something I can establish statically.
- **`react-hooks/set-state-in-effect` runtime impact.** ESLint flags 11 instances. I traced `OrderTicket.tsx:45-50` specifically and believe it causes the quantity reset described above; the other ten I judged as performance-class, not correctness-class, without confirming.
- **Whether the KLineChart canvas exposes any accessibility surface of its own.** I read the wrapper (`CandlestickChart.tsx`), not the library internals. My claim is that *the application* adds no name, role or text alternative — which is confirmed.
- **Screen-reader behaviour.** Inferred entirely from markup semantics and the total absence of ARIA. Not tested with NVDA, JAWS or VoiceOver.
- **The Google OAuth flow** (`login/page.tsx:40-42`, `register/page.tsx:41-43`) — a full-page redirect to `${API_URL}/api/auth/google`. I did not trace the NestJS strategy's callback, its error handling, or where a user lands if they cancel at Google's consent screen.
