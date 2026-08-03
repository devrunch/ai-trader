# 12 — Error and Empty States

**Aim:** a user can always tell the difference between "loading", "nothing here",
and "something broke" — and never sees our internals.

**Status:** DONE (2026-07-27). `ApiError` surfaces the server's own message, a shared
`ErrorState` gives every failure a retry, and indicator keys have display names.

Source: [`docs/ux-audit.md`](../ux-audit.md) §1–2. Verified independently.

---

## Why it matters

### The good error message is thrown away

```ts
// lib/api.ts:9
if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
```

The response **body** — which the API takes care to write well, e.g.
*"Insufficient balance. Required ₹9,000, available ₹500"* — is discarded. Three
components then render what's left, so the user sees:

> **400 Bad Request**

The helpful message already exists on the wire. We parse it out and throw it
away.

### Failures are disguised as empty states

Nine `.catch()` handlers collapse an error into a normal-looking empty result.
The consequences aren't cosmetic:

- The API being **down** renders **"No paper account yet"** — the user is told
  their account doesn't exist. Some will try to create a second one.
- A failed cash-balance fetch falls back to **₹0**, so a funded account displays
  as empty.
- A failed quote renders the stock at **₹0.00 in green** — a fabricated price,
  coloured as a gain.
- On the signals list, a failed fetch and a genuinely quiet market are the same
  screen, and it silently re-polls.

For a product about money, showing a confidently wrong number is worse than
showing an error. The whole backend was reworked on that principle — the frontend
undoes it at the last step.

### Internals shown as UI text

Raw field names (`pnlPct`, `ltp`, `adx`, `supertrend_dir`) used as user-facing
labels, and internal service architecture surfaced in a user-visible string.
These tell the user they're looking at a dev build.

---

## Reopened and closed again — the terminal

The four error states on the terminal were being **set and never rendered**.
Found while splitting the page: eslint reported `barsError`, `signalError`,
`positionsError` and `quoteFailed` as assigned but unused. Each was a case this
file already forbids, shipped anyway:

- [x] **A failed quote rendered as `₹0.00` in green** — and that fabricated 0
      was handed to the order ticket as the market price, defeating the
      ticket's own `ltp: number | null` contract, which is documented "never
      render a fabricated 0". Price is now null when unknown, and the header
      says "price unavailable".
- [x] **A chart outage rendered as "No chart data for {symbol}"** — telling the
      user their symbol was wrong when the server was down. Now an `ErrorState`
      with a retry.
- [x] **A failed signal lookup rendered as "No analysis yet"** — "we couldn't
      check" and "there is nothing" are different answers. The panel now says
      which, in as many words.
- [x] **A failed positions fetch rendered as "No open positions"** — telling the
      user they hold nothing when we could not find out. It was
      `.catch(() => setPositions([]))`.

## Tasks

- [x] **Parse and surface the API's error message.** In `lib/api.ts:9`, read the
      response body and use its `message` when present; fall back to a generic
      human sentence, never to a status code. **This one change fixes most of
      the visible symptoms.**

- [x] **Distinguish the three states everywhere.** Every data-fetching component
      needs distinct loading / empty / error renders. "No data" must never be the
      error state.

- [x] **Never fabricate a number on failure.** No ₹0 fallbacks for balance or
      price. Render an explicit "unavailable" and let the user retry.

- [x] **Give errors a retry action.** An error state with no forward action is a
      dead end.

- [x] **Rename internal fields for display.** `pnlPct` → "Return", `ltp` →
      "Price", `adx` → "Trend strength (ADX)", `supertrend_dir` → "SuperTrend".
      Keep the indicator names — traders know them — but not the variable names.

- [x] **Remove console logging and internal architecture from shipped paths.**
      ESLint currently reports 19 errors; clear them.

**Effort:** ~1 day. The `lib/api.ts` fix is an hour and pays for most of it.

---

## Files

| | |
|---|---|
| API client | `ai-trader-frontend/lib/api.ts` |
| Swallowed catches | across `app/dashboard/**`, see `docs/ux-audit.md` §2 for each `file:line` |
