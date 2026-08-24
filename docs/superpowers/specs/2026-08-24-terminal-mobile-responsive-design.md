# Terminal Mobile/Responsive Layout — Design

## Purpose

The terminal (`ai-trader-frontend/app/dashboard/terminal/page.tsx`) currently
refuses to render below 1024px — anything narrower gets a static "The
terminal needs a wider screen" message redirecting to Signals or the
Morning Brief. The goal is a real mobile experience, modeled on how
TradingView's own mobile web/app behaves: the chart is the primary surface,
everything else (watchlist/search, indicators, drawing tools, AI chat,
paper trading, positions) is reachable through compact chrome rather than
a permanent side panel.

## Scope

One responsive layout covers the entire sub-1024px range (phones and
tablets/narrow laptops alike) — not a separate tablet-specific layout.
Desktop (≥1024px) is visually and behaviorally unchanged; this work only
adds a new path below that breakpoint.

## Current State (relevant facts)

- The desktop body is: a left icon rail (`DrawingToolbar`) + the chart
  (flex-1) + a fixed 340px right panel with 4 tabs (Signal / Trade /
  Positions / Chat), switched via `rightTab` state
  (`useState<"signal" | "trade" | "positions" | "chat">("signal")`).
- Symbol search is already a modal (not a persistent pane), recently
  redesigned with exchange filter chips, colored exchange badges, and full
  keyboard navigation. It does not yet have mobile-specific chrome.
- `OrderTicket` is "always mounted, visibility toggled by class" specifically
  so in-progress quantity/price input survives switching away from the
  Trade tab and back. `SignalPanel`, `PositionsPanel`, and `ChatPanel` are
  conditionally rendered (mount fresh each time their tab is selected) —
  cheap to recompute or intentionally reset per entry.
- None of the app's 4 existing dialogs (search, `IndicatorPickerModal`,
  `IndicatorEditorModal`, `IndicatorSettingsModal`) share a base modal
  component — each hand-rolls its own backdrop/card markup.
- All state, data fetching, and handlers for the terminal live in
  `page.tsx` itself; the "needs wider screen" block only hides UI via
  Tailwind classes — the underlying hooks/effects still run regardless of
  viewport.

## Architecture

`page.tsx` keeps every piece of state, every effect, and every handler
exactly as it exists today — nothing about data flow, symbol resolution,
indicator attachment, chat wiring, or order placement changes. Only the
final render step changes: instead of the current
`hidden lg:flex` / `lg:hidden` pair rendering (effectively) both trees at
once with CSS hiding one, a new `useIsMobile()` hook decides, and exactly
**one** layout is mounted:

```
isMobile === null → render nothing (blank shell) for that one frame
isMobile === true  → <MobileTerminalLayout {...shared} />
isMobile === false → <DesktopTerminalLayout {...shared} />
```

`useIsMobile()`: `window.matchMedia("(max-width: 1023px)")` plus a resize
listener; starts at `null` (unknown) rather than defaulting to `false`.
This is a deliberate difference from this file's existing
`?symbol=`-restore pattern (which defaults to a cheap wrong label for one
frame, then corrects): guessing "desktop" wrongly here would mount a real
chart instance and a live chat session, then immediately tear both down to
remount as mobile — real wasted work, not a cosmetic flash. Rendering
nothing for one frame while `isMobile` is unresolved avoids that.

`DesktopTerminalLayout.tsx` is today's existing JSX body, lifted out of
`page.tsx` unchanged. `MobileTerminalLayout.tsx` is new. Both receive the
same prop bag built once in `page.tsx` (symbol/exchange, quote, bars,
indicator state + handlers, watchlist state + handlers, chat/order/
positions props, drawing-tool state + handlers) — no logic duplication,
no prop-shape divergence between the two.

**Edge case, explicitly accepted**: resizing across the 1024px line
mid-session (window resize, tablet rotation) unmounts one layout and
mounts the other. The chart remounts — it redraws instantly from the
already-fetched `bars` state (no re-fetch), indicators re-attach the same
way any fresh mount already does — but pan/zoom position and any
in-progress drawing are lost. This is the same cost changing symbols
already carries today; it is not a new failure mode, just worth naming.

## Components

### `MobileTerminalLayout.tsx`

Owns the mobile-only chrome and the 5-way navigation:

- **Chart** mounts once here and stays mounted — CSS-hidden (not
  unmounted) when another bottom tab is active. Same reasoning `OrderTicket`
  already uses: losing pan/zoom/in-progress drawings every time someone
  checks Chat would be a real regression, not an acceptable reset.
- **Signal / Trade / Positions / Chat** panels keep whatever mount policy
  they already have on desktop today — mobile does not invent a new
  policy, it reuses each component's existing one (`OrderTicket`
  CSS-hidden/state-preserving, the other three conditionally rendered)
  inside a full-screen container instead of a 340px column.

### `MobileBottomTabBar.tsx`

5 tabs: Chart / Signal / Trade / Positions / Chat. Drives the same
`rightTab` state the desktop tab strip already uses (see Data Flow below
for the type extension). Icon-primary; a text label is shown only on the
currently active tab, to stay legible on ~375px-wide screens (iPhone SE
class) with 5 tabs.

### `MobileChartToolbar.tsx`

Sits above the chart, inside the Chart tab's content area:

- Symbol + live price (tap → opens search, full-screen on mobile).
- A pencil icon → opens the drawing-tools `BottomSheet` (same tool set as
  `DrawingToolbar`'s rail, reflowed into a grid).
- An Indicators icon → opens the existing `IndicatorPickerModal` (now
  routed through `ResponsiveModal`, see below).
- Period pills (`PERIODS`), as a persistent horizontally-scrollable strip
  — used constantly, so it is not hidden behind a tap, matching
  TradingView's own mobile chart header.

### `BottomSheet.tsx`

Generic slide-up panel + backdrop (open/close, backdrop-click-to-close,
Escape-to-close). Used by the drawing-tools sheet; written generically
enough for any future mobile sheet need.

### `ResponsiveModal.tsx` (extraction, in scope)

None of the 4 existing dialogs (search, `IndicatorPickerModal`,
`IndicatorEditorModal`, `IndicatorSettingsModal`) share a base component
today. All 4 need the identical rule — full-screen below 640px, centered
card above it — so this extracts that responsive chrome into one shared
wrapper rather than writing it 4 times. In scope because there are 4
concrete current call sites needing the exact same behavior, not a
hypothetical future one. Each dialog keeps its own content/body; only the
backdrop/sizing/positioning chrome moves into `ResponsiveModal`.

## Data Flow

`rightTab`'s type extends from
`"signal" | "trade" | "positions" | "chat"` to
`"chart" | "signal" | "trade" | "positions" | "chat"` — still one state
variable in `page.tsx`, shared by both layouts. Desktop's tab strip never
renders a "chart" button (the chart is always visible there), so desktop
behavior is unchanged.

On first resolving to mobile, if `rightTab` is still at its original
default (`"signal"` — meaning the user hasn't touched it yet this
session), a one-shot effect flips it to `"chart"`, so a mobile session
opens on the chart rather than desktop's side-panel default. Same
"one-shot correction after mount" shape as the existing `?symbol=` restore
effect, applied to viewport instead of URL state.

## Error Handling / Edge Cases

- **Breakpoint crossing mid-session**: covered under Architecture above —
  accepted remount cost, not a new failure mode.
- **On-screen keyboard covering the bottom tab bar** while typing in Chat
  or `OrderTicket`'s fields: standard mobile-web concern, cannot be fully
  verified by unit tests — needs a real device/browser check (see
  Testing).
- **Very small screens** (~375px, iPhone SE class): handled by
  `MobileBottomTabBar`'s icon-primary/single-active-label design (see
  Components above), not a separate layout.
- **Full-screen search modal state** (which exchange filter chip is
  selected, current query) persisting across open/close: already today's
  behavior for the desktop search modal (neither resets on close); mobile
  inherits this unchanged, no new decision needed.

## Testing

- `SignalPanel`, `OrderTicket`, `PositionsPanel`, `ChatPanel` are reused
  unchanged — their existing test suites stand as-is.
- New unit tests:
  - `useIsMobile` — mocked `matchMedia`, null→boolean resolution, resize
    listener updates the value, cleans up on unmount.
  - `MobileBottomTabBar` — each tab click calls `setRightTab` with the
    right value; active-tab styling/label reflects `rightTab`.
  - `MobileChartToolbar` — each icon opens the right sheet/modal; period
    pill clicks call the existing period setter.
  - `BottomSheet` — open/close, backdrop click, Escape.
  - `ResponsiveModal` — full-screen chrome applied under a mocked narrow
    viewport, centered-card chrome above it; existing dialog-specific
    tests (e.g. `IndicatorPickerModal`'s own tests) keep passing once
    routed through it.
- **Required beyond unit tests**: an actual mobile-viewport browser pass
  before this is considered done — chart renders full-height, switching
  bottom tabs does not lose chart zoom/pan, a drawing tool can be placed
  via a touch-simulated tap, full-screen search selecting a symbol updates
  the chart, and the chat input is not obscured by the on-screen keyboard.
  This matches the project's existing rule that a frontend change isn't
  verified until it's exercised in a real browser — type-checking and
  unit tests verify code correctness, not feature correctness, especially
  for a responsive/touch layout.

## Global Constraints (for the implementation plan)

- Breakpoint: `max-width: 1023px` (matches the existing `lg:` Tailwind
  cutoff already used by the current block message) is "mobile" for this
  work; ≥1024px is unchanged "desktop".
- Exactly one of `MobileTerminalLayout` / `DesktopTerminalLayout` is
  mounted at any time — never both, never CSS-hidden duplicates of
  expensive children (chart, chat session).
- Chart mount policy inside `MobileTerminalLayout`: always mounted,
  CSS-hidden when not on the Chart tab (never unmounted on tab switch).
- Every other panel (Signal/Trade/Positions/Chat) keeps its existing
  desktop mount policy verbatim when reused inside
  `MobileTerminalLayout`.
- `ResponsiveModal`'s full-screen/centered-card cutoff: 640px (Tailwind
  `sm`), independent of the 1024px layout breakpoint above — a modal can
  be full-screen on a narrow desktop window too, same as it would be on a
  phone.
