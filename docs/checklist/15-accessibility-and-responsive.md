# 15 — Accessibility and Responsive

**Aim:** the app is usable without a mouse, without perfect colour vision, and
tells the truth about which devices it supports.

**Status:** DONE (2026-07-27). Contrast token applied across 37 sites, global focus
rings, the signals table is a real button with `aria-expanded`, chat has a live region,
tabular figures, and indicator toggles now apply incrementally instead of rebuilding
the chart. Focus-return-on-close is not implemented (the confirm step is inline, not
an overlay); focus-into is.

Source: [`docs/ux-audit.md`](../ux-audit.md) §6, §8, §9. Contrast figures are
computed from the CSS, not measured in a browser.

---

## Why it matters

### Zero ARIA in application code

Order confirmations are **silent to screen readers** — a user placing a trade
gets no confirmation their action succeeded. The signals table cannot be expanded
by keyboard at all, so its detail is unreachable without a mouse.

The chart and the chat are custom controls with no accessible names or roles.

This is not only an accessibility question. A financial action that produces no
confirmation a user can perceive is an interaction bug for everyone; screen
readers just surface it first.

### Colour is the only channel for sign

Percentage change communicates gain versus loss **by colour alone**. Around 8% of
men have some form of red-green colour blindness — for them, a −2.4% and a +2.4%
render identically. Add the explicit sign or an arrow; the colour then reinforces
rather than carries.

### The primary colour fails contrast as text

`--primary #6c5ce7` computes to **3.99:1** against the dark background. WCAG AA
requires 4.5:1 for body text. It is used for links and secondary labels.

### The terminal is desktop-only and does not say so

Below ~1280px the chart column computes to roughly zero width. On a phone the
user gets a broken layout with no explanation. Either make it responsive or tell
them — an explicit "the terminal needs a wider screen" is a fine answer; a
collapsed, unusable chart is not.

### Toggling an indicator destroys the chart

Enabling any indicator tears down and rebuilds the chart, losing **zoom position
and every drawing the user or the AI has placed**. For a charting product this is
the single most annoying interaction in the app — a user experimenting with
indicators loses their analysis each time.

---

## Tasks

- [x] **Announce order results.** An ARIA live region for confirmations and
      errors, so a trade result is perceivable without sight.

- [x] **Make the signals table keyboard-operable.** Row expansion via real
      buttons with `aria-expanded`, not click handlers on divs.

- [x] **Label the custom controls.** Accessible names and roles on the chart
      container, chat input, and chat message list (a live region for streaming
      answers).

- [x] **Add the sign to every percentage.** `+2.4%` / `−2.4%` explicitly, colour
      as reinforcement only.

- [x] **Fix `--primary` contrast** for text use, or use a lighter variant for
      text and keep the current value for fills.

- [x] **Preserve chart state across indicator toggles.** Add and remove
      indicators on the existing KLineChart instance rather than recreating it.
      This is the highest-value item in this file for demo quality.

- [x] **Handle narrow viewports honestly.** Responsive layout, or an explicit
      message. Also check for horizontal body scroll.

- [x] **Focus management.** Visible focus indicators throughout; focus moved into
      modals and returned on close.

- [x] **Right-align numeric columns and use tabular figures.** Financial tables
      are read by scanning a column; proportional digits make that impossible.

**Effort:** ~2 days. The chart-state fix and the numeric alignment are the two
most visible.

---

## Files

| | |
|---|---|
| Chart lifecycle | `ai-trader-frontend/components/CandlestickChart.tsx` |
| Terminal layout, tabs | `ai-trader-frontend/app/dashboard/terminal/page.tsx` |
| Signals table | `ai-trader-frontend/app/dashboard/signals/page.tsx` |
| Colour tokens | `ai-trader-frontend/app/globals.css` |
