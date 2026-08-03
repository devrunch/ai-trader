# 14 — Trust and Claims

**Aim:** the product does not claim anything it cannot do, and does not show
anything it did not compute.

**Status:** DONE (2026-07-26). Fabricated assurances removed, disclaimers everywhere a
suggestion appears, 404 and error boundary added, per-route page titles.

**Why this file mattered:** these are the findings a paying user catches — and
once they catch one, they stop trusting the numbers too.

Source: [`docs/ux-audit.md`](../ux-audit.md) §1, §3, §5, §10. Verified
independently.

---

## Why it matters

### The profile page claims a feature that does not exist

`app/dashboard/profile/page.tsx:100` renders a hardcoded green **"Verified"**
badge next to the user's email. **There is no email verification anywhere in the
backend** — confirmed by grep. Alongside it sits a 2FA toggle that says "Enabled"
and forgets on refresh.

Two fabricated security assurances on the page users visit *specifically* to
check their security. That is worse than shipping neither.

### The landing page shows analysis that never happened

Fabricated RELIANCE and AAPL levels sit under a pulsing "ANALYZING RELIANCE ·
NSE" header — presented as live output. And the page claims US market support
three times, when no UI control can set a non-NSE exchange.

Marketing mockups are normal. Presenting a static mockup as a live analysis, in a
product whose entire pitch is *"an AI analyst that shows its work"*, is not.

### Suggestions appear with no disclaimer

The **Signals page has none at all** — a full grid of BUY/SELL calls with rupee
entry, target and stop levels, and nothing saying this is analysis and paper
trading rather than investment advice. The terminal's signal panel and the chat
results have none either.

The Brief page does this well. That pattern needs to be everywhere a suggestion
appears.

*(The win-rate colouring and n=1 buckets the audit flags here are covered in
[05 — Honest Reporting](05-honest-reporting.md); the UX audit independently
confirmed both from the frontend side.)*

### Password reset goes nowhere

"Forgot password?" is a dead link. A user who forgets their password has no route
back into the product.

---

## Tasks

- [x] **Remove the fake "Verified" badge** — or implement email verification.
      Removing is a one-line change and honest today.

- [x] **Remove or persist the 2FA toggle.** A control that forgets its own state
      is worse than no control.

- [x] **Label the landing page demo as a demo.** Keep the mockup; stop presenting
      it as live analysis.

- [x] **Remove the US market claims** until a UI control can actually set a
      non-NSE exchange.

- [x] **Add the disclaimer to every surface showing a suggestion** — Signals
      page, terminal signal panel, chat results. Reuse the Brief page's wording;
      it is already good.

- [x] **Implement or remove "Forgot password?"** A dead link on an auth screen
      reads as an abandoned product.

- [x] **The disclaimer now renders on the terminal.** It was imported there and
      never rendered, so the one page that can actually move the paper account
      carried no qualification — while the Signals page, which cannot, carried
      it. Found while splitting the page: eslint reported the import as unused.
      The order ticket is also finally told the feed is delayed; it had a
      `priceDelayed` prop and a caveat to render, and nobody was passing it.

- [x] **Trust basics done.** 404 (`app/not-found.tsx`), error boundary
      (`app/error.tsx`) and per-route titles landed earlier; the last piece was
      the favicon, still the Next.js default. Replaced with `app/icon.svg` —
      the header's own mark plus a rising line, since at 16px the letters stop
      being legible and the icon still has to say "trading tool". Square, not
      rounded: the whole UI is square-cornered, and a rounded icon in a
      square-cornered product looks borrowed.

**Effort:** ~1 day. Most items are minutes; the disclaimers and the 404/error
boundary are the bulk.

---

## Files

| | |
|---|---|
| Fake badge, 2FA toggle | `ai-trader-frontend/app/dashboard/profile/page.tsx` |
| Landing claims | `ai-trader-frontend/app/page.tsx` |
| Missing disclaimers | `app/dashboard/signals/page.tsx`, `app/dashboard/terminal/page.tsx` |
| Good pattern to copy | `app/dashboard/brief/page.tsx` |
| Metadata, 404, error boundary | `ai-trader-frontend/app/layout.tsx`, `app/not-found.tsx` (missing), `app/error.tsx` (missing) |
