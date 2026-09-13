# Terminal Mobile/Responsive Layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the terminal page usable below 1024px with a TradingView-style bottom-tab mobile layout, instead of the current hard block.

**Architecture:** `page.tsx` keeps 100% of its existing state/effects/handlers. A new `useIsMobile()` hook decides which of two presentational layouts to mount — `DesktopTerminalLayout` (today's JSX, lifted out unchanged) or `MobileTerminalLayout` (new) — never both at once. Mobile adds a bottom tab bar (Chart/Signal/Trade/Positions/Chat), a compact chart toolbar with a drawing-tools bottom sheet, and a shared `ResponsiveModal` wrapper retrofitted onto the app's 4 existing hand-rolled dialogs.

**Tech Stack:** Next.js (App Router), React, TypeScript, Tailwind CSS v4 (CSS-based config, default breakpoints: `sm`=640px, `lg`=1024px), Vitest/Jest-style component tests (matching this repo's existing `*.test.tsx` convention).

**Spec:** `docs/superpowers/specs/2026-08-24-terminal-mobile-responsive-design.md`

## Global Constraints

- Mobile layout breakpoint: `max-width: 1023px` (one layout for phones and tablets alike — no separate tablet layout).
- `ResponsiveModal`'s full-screen-vs-centered-card cutoff: `640px` (Tailwind `sm`) — independent of the 1024px layout breakpoint.
- Exactly one of `MobileTerminalLayout` / `DesktopTerminalLayout` is ever mounted — never both, never a CSS-hidden duplicate of the chart or a chat session.
- `useIsMobile()` starts at `null` (unknown) and must render nothing until resolved — never default-guess `false`.
- Inside `MobileTerminalLayout`, the chart mounts once and stays mounted (CSS-hidden, never unmounted) when a non-Chart tab is active. Every other panel (Signal/Trade/Positions/Chat) keeps whatever mount policy it already has today on desktop (`OrderTicket` CSS-hidden/state-preserving; `SignalPanel`/`PositionsPanel`/`ChatPanel` conditionally rendered) — mobile does not invent a new policy per component.
- `rightTab`'s type extends from `"signal" | "trade" | "positions" | "chat"` to `"chart" | "signal" | "trade" | "positions" | "chat"`. Desktop never renders a "chart" tab button; its behavior is otherwise unchanged.

---

## File Structure

| File | Responsibility |
|---|---|
| `lib/use-is-mobile.ts` | Create. Resolves `null \| boolean` from `matchMedia`, updates on resize. |
| `components/ResponsiveModal.tsx` | Create. Shared backdrop/sizing chrome (full-screen <640px, centered card ≥640px) for all 4 dialogs. |
| `components/terminal/IndicatorPickerModal.tsx` | Modify. Use `ResponsiveModal` instead of its own backdrop/card markup. |
| `components/terminal/IndicatorEditorModal.tsx` | Modify. Same. |
| `components/terminal/IndicatorSettingsModal.tsx` | Modify. Same. |
| `app/dashboard/terminal/DesktopTerminalLayout.tsx` | Create. Today's `page.tsx` JSX body (lines 813–1326), lifted out verbatim as a props-driven component — including its own search-modal block, retrofitted onto `ResponsiveModal` as the 4th call site. |
| `app/dashboard/terminal/page.tsx` | Modify. Keeps all state/effects/handlers; final `return` picks `DesktopTerminalLayout` or `MobileTerminalLayout` via `useIsMobile()`; `rightTab` type widens; one-shot mobile-default effect added. |
| `components/terminal/mobile/BottomSheet.tsx` | Create. Generic slide-up panel + backdrop. |
| `components/terminal/mobile/MobileBottomTabBar.tsx` | Create. 5-tab bottom nav. |
| `components/terminal/mobile/MobileChartToolbar.tsx` | Create. Symbol/price + search trigger, drawing-tools sheet trigger, Indicators trigger, period pills strip. |
| `app/dashboard/terminal/MobileTerminalLayout.tsx` | Create. Assembles chart + toolbar + tab bar + the 4 panels, per the mount-policy rules above. |

---

## Task 1: `useIsMobile` hook

**Files:**
- Create: `lib/use-is-mobile.ts`
- Test: `lib/use-is-mobile.test.ts`

**Interfaces:**
- Produces: `useIsMobile(): boolean | null` — `null` until the first client-side check runs, then tracks `window.matchMedia("(max-width: 1023px)").matches`, live-updating on viewport changes.

- [ ] **Step 1: Write the failing tests**

```typescript
// lib/use-is-mobile.test.ts
import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import { renderHook, act } from "@testing-library/react";
import { useIsMobile } from "./useIsMobile";

function mockMatchMedia(initialMatches: boolean) {
  const listeners: ((e: MediaQueryListEvent) => void)[] = [];
  const mql = {
    matches: initialMatches,
    media: "(max-width: 1023px)",
    addEventListener: (_: string, cb: (e: MediaQueryListEvent) => void) => listeners.push(cb),
    removeEventListener: (_: string, cb: (e: MediaQueryListEvent) => void) => {
      const i = listeners.indexOf(cb);
      if (i >= 0) listeners.splice(i, 1);
    },
  };
  window.matchMedia = vi.fn().mockReturnValue(mql);
  return {
    fire(matches: boolean) {
      mql.matches = matches;
      listeners.forEach((cb) => cb({ matches } as MediaQueryListEvent));
    },
    listenerCount: () => listeners.length,
  };
}

describe("useIsMobile", () => {
  afterEach(() => vi.restoreAllMocks());

  it("resolves to the real matchMedia result after mount, not a guessed default", () => {
    mockMatchMedia(true);
    const { result } = renderHook(() => useIsMobile());
    expect(result.current).toBe(true);
  });

  it("resolves to false when the viewport is wide", () => {
    mockMatchMedia(false);
    const { result } = renderHook(() => useIsMobile());
    expect(result.current).toBe(false);
  });

  it("updates live when the viewport crosses the breakpoint", () => {
    const m = mockMatchMedia(false);
    const { result } = renderHook(() => useIsMobile());
    expect(result.current).toBe(false);

    act(() => m.fire(true));
    expect(result.current).toBe(true);
  });

  it("removes its resize listener on unmount", () => {
    const m = mockMatchMedia(false);
    const { unmount } = renderHook(() => useIsMobile());
    expect(m.listenerCount()).toBe(1);
    unmount();
    expect(m.listenerCount()).toBe(0);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx vitest run lib/use-is-mobile.test.ts`
Expected: FAIL with "Cannot find module './useIsMobile'"

- [ ] **Step 3: Write the implementation**

```typescript
// lib/use-is-mobile.ts
"use client";

import { useEffect, useState } from "react";

const QUERY = "(max-width: 1023px)";

/** null until the first client-side check runs -- guessing a default here
 *  (e.g. `false`) risks mounting the desktop layout's real chart + chat
 *  session on a phone, only to tear both down a moment later once the real
 *  viewport is known. Rendering nothing for that one frame is cheaper than
 *  guessing wrong. */
export function useIsMobile(): boolean | null {
  const [isMobile, setIsMobile] = useState<boolean | null>(null);

  useEffect(() => {
    const mql = window.matchMedia(QUERY);
    setIsMobile(mql.matches);
    const onChange = (e: MediaQueryListEvent) => setIsMobile(e.matches);
    mql.addEventListener("change", onChange);
    return () => mql.removeEventListener("change", onChange);
  }, []);

  return isMobile;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run lib/use-is-mobile.test.ts`
Expected: PASS (4/4)

- [ ] **Step 5: Commit**

```bash
git add lib/use-is-mobile.ts lib/use-is-mobile.test.ts
git commit -m "feat: add useIsMobile hook for the mobile terminal layout"
```

---

## Task 2: `ResponsiveModal` + retrofit the 3 standalone dialogs

**Files:**
- Create: `components/ResponsiveModal.tsx`
- Test: `components/ResponsiveModal.test.tsx`
- Modify: `components/terminal/IndicatorPickerModal.tsx`
- Modify: `components/terminal/IndicatorEditorModal.tsx`
- Modify: `components/terminal/IndicatorSettingsModal.tsx`

**Interfaces:**
- Produces:
  ```typescript
  export function ResponsiveModal(props: {
    open: boolean;
    onClose: () => void;
    ariaLabel: string;
    /** Card width above 640px, e.g. "max-w-lg". Ignored full-screen. */
    maxWidthClass: string;
    /** Card height above 640px, e.g. "max-h-[76vh]". Ignored full-screen. */
    maxHeightClass: string;
    children: React.ReactNode;
  }): React.ReactElement | null
  ```
- Consumes: nothing new — wraps the existing backdrop/card markup already duplicated across the 3 dialogs (each currently: `fixed inset-0 z-50 flex items-start justify-center bg-black/70 backdrop-blur-sm p-4 pt-[8vh]` backdrop + `bg-card border border-border w-full {maxWidthClass} {maxHeightClass} flex flex-col` card).

- [ ] **Step 1: Write the failing test**

```typescript
// components/ResponsiveModal.test.tsx
import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { ResponsiveModal } from "./ResponsiveModal";

function mockViewport(maxWidth1023orLess: boolean) {
  // ResponsiveModal only cares about the 640px cutoff, not the 1024px
  // layout one -- named to match what it queries: "(max-width: 639px)".
  window.matchMedia = vi.fn().mockImplementation((query: string) => ({
    matches: query.includes("639px") ? maxWidth1023orLess : false,
    media: query,
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
  }));
}

describe("ResponsiveModal", () => {
  afterEach(() => vi.restoreAllMocks());

  it("renders nothing when closed", () => {
    mockViewport(false);
    const { container } = render(
      <ResponsiveModal open={false} onClose={() => {}} ariaLabel="Test" maxWidthClass="max-w-lg" maxHeightClass="max-h-[76vh]">
        <p>content</p>
      </ResponsiveModal>
    );
    expect(container).toBeEmptyDOMElement();
  });

  it("uses the centered-card chrome at desktop width", () => {
    mockViewport(false);
    render(
      <ResponsiveModal open onClose={() => {}} ariaLabel="Test" maxWidthClass="max-w-lg" maxHeightClass="max-h-[76vh]">
        <p>content</p>
      </ResponsiveModal>
    );
    const dialog = screen.getByRole("dialog");
    expect(dialog.querySelector(".max-w-lg")).toBeTruthy();
  });

  it("drops the card chrome for full-screen below 640px", () => {
    mockViewport(true);
    render(
      <ResponsiveModal open onClose={() => {}} ariaLabel="Test" maxWidthClass="max-w-lg" maxHeightClass="max-h-[76vh]">
        <p>content</p>
      </ResponsiveModal>
    );
    const dialog = screen.getByRole("dialog");
    expect(dialog.querySelector(".max-w-lg")).toBeNull();
  });

  it("calls onClose on backdrop click but not on content click", () => {
    mockViewport(false);
    const onClose = vi.fn();
    render(
      <ResponsiveModal open onClose={onClose} ariaLabel="Test" maxWidthClass="max-w-lg" maxHeightClass="max-h-[76vh]">
        <p>content</p>
      </ResponsiveModal>
    );
    fireEvent.click(screen.getByText("content"));
    expect(onClose).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("dialog"));
    expect(onClose).toHaveBeenCalledOnce();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run components/ResponsiveModal.test.tsx`
Expected: FAIL with "Cannot find module './ResponsiveModal'"

- [ ] **Step 3: Write the implementation**

```typescript
// components/ResponsiveModal.tsx
"use client";

import { useEffect, useState } from "react";

/** Shared backdrop/sizing chrome for every modal dialog in the app.
 *  Centered card ≥640px (today's existing look, unchanged); full-screen
 *  below it -- a modal on a narrow desktop window gets the same treatment
 *  a phone does, since this checks viewport width, not device type. */
export function ResponsiveModal({ open, onClose, ariaLabel, maxWidthClass, maxHeightClass, children }: {
  open: boolean;
  onClose: () => void;
  ariaLabel: string;
  maxWidthClass: string;
  maxHeightClass: string;
  children: React.ReactNode;
}) {
  // Reuses useIsMobile's matchMedia machinery at a different, independent
  // cutoff (640px, not the 1024px layout breakpoint) -- a second call with
  // its own query string, not a shared value.
  const isNarrow = useNarrowViewport();

  if (!open) return null;

  const cardClass = isNarrow
    ? "w-full h-full flex flex-col"
    : `bg-card border border-border w-full ${maxWidthClass} ${maxHeightClass} flex flex-col`;
  const backdropClass = isNarrow
    ? "fixed inset-0 z-50 flex bg-card"
    : "fixed inset-0 z-50 flex items-start justify-center bg-black/70 backdrop-blur-sm p-4 pt-[8vh]";

  return (
    <div role="dialog" aria-modal="true" aria-label={ariaLabel} className={backdropClass} onClick={onClose}>
      <div className={cardClass} onClick={(e) => e.stopPropagation()}>
        {children}
      </div>
    </div>
  );
}

function useNarrowViewport(): boolean {
  // Deliberately separate from useIsMobile: that hook answers "is this the
  // mobile TERMINAL LAYOUT" (1023px), this answers "should THIS MODAL go
  // full-screen" (639px) -- same mechanism, different, independent cutoff.
  return useMatchMedia("(max-width: 639px)");
}

function useMatchMedia(query: string): boolean {
  const [matches, setMatches] = useState(false);
  useEffect(() => {
    const mql = window.matchMedia(query);
    setMatches(mql.matches);
    const onChange = (e: MediaQueryListEvent) => setMatches(e.matches);
    mql.addEventListener("change", onChange);
    return () => mql.removeEventListener("change", onChange);
  }, [query]);
  return matches;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run components/ResponsiveModal.test.tsx`
Expected: PASS (4/4)

- [ ] **Step 5: Retrofit `IndicatorPickerModal.tsx`**

Current markup (`components/terminal/IndicatorPickerModal.tsx`, lines 38–47):

```tsx
    <div
      role="dialog" aria-modal="true" aria-labelledby="indicator-picker-title"
      className="fixed inset-0 z-50 flex items-start justify-center bg-black/70 backdrop-blur-sm p-4 pt-[8vh]"
      onClick={onClose}
    >
      <div
        className="bg-card border border-border w-full max-w-lg max-h-[76vh] flex flex-col"
        onClick={(e) => e.stopPropagation()}
      >
```

Replace with:

```tsx
    <ResponsiveModal open={open} onClose={onClose} ariaLabel="Indicators" maxWidthClass="max-w-lg" maxHeightClass="max-h-[76vh]">
```

...and its matching closing `</div></div>` (the outer two closing tags at the
end of the component's returned JSX, just before the final `);`) becomes a
single `</ResponsiveModal>`. Add `import { ResponsiveModal } from "@/components/ResponsiveModal";`
at the top, and drop the component's own `if (!open) return null;` line (`ResponsiveModal`
now owns that check) — keep everything between the old opening/closing tags
(the search input, the category list, etc.) exactly as-is.

Note the `aria-labelledby="indicator-picker-title"` on the old markup pointed
at the `<h2>` inside — `ResponsiveModal` uses a plain `aria-label` string
instead, so also delete the now-unused `id="indicator-picker-title"` from
that `<h2>`.

- [ ] **Step 6: Run this dialog's existing tests to verify nothing broke**

Run: `npx vitest run components/terminal/IndicatorPickerModal.test.tsx` (if it exists; otherwise skip — this file may not have had a dedicated test before this task)
Expected: PASS, or no such file (nothing to break)

- [ ] **Step 7: Retrofit `IndicatorEditorModal.tsx`**

Current markup (`components/terminal/IndicatorEditorModal.tsx`, lines 84–91):

```tsx
      role="dialog" aria-modal="true" aria-labelledby="indicator-editor-title"
      className="fixed inset-0 z-50 flex items-start justify-center bg-black/70 backdrop-blur-sm p-4 pt-[6vh]"
      onClick={onClose}
    >
      <div
        className="bg-card border border-border w-full max-w-2xl max-h-[88vh] flex flex-col"
        onClick={(e) => e.stopPropagation()}
      >
```

Replace the full opening two-`<div>` block (this `role="dialog"` div and its
child) with:

```tsx
    <ResponsiveModal open={open} onClose={onClose} ariaLabel="Indicator editor" maxWidthClass="max-w-2xl" maxHeightClass="max-h-[88vh]">
```

Its matching closing `</div></div>` becomes `</ResponsiveModal>`. Add
`import { ResponsiveModal } from "@/components/ResponsiveModal";`, delete the
`if (!open) return null;` line (line 43), and delete
`id="indicator-editor-title"` from the `<h2>` at line 93 (no longer
referenced by `aria-labelledby`).

- [ ] **Step 8: Retrofit `IndicatorSettingsModal.tsx`**

Current markup (`components/terminal/IndicatorSettingsModal.tsx`, lines 76–83):

```tsx
      role="dialog" aria-modal="true" aria-labelledby="indicator-settings-title"
      className="fixed inset-0 z-50 flex items-start justify-center bg-black/70 backdrop-blur-sm p-4 pt-[10vh]"
      onClick={onClose}
    >
      <div
        className="bg-card border border-border w-full max-w-sm max-h-[75vh] flex flex-col"
        onClick={(e) => e.stopPropagation()}
      >
```

Replace the full opening two-`<div>` block with:

```tsx
    <ResponsiveModal open={open} onClose={onClose} ariaLabel="Indicator settings" maxWidthClass="max-w-sm" maxHeightClass="max-h-[75vh]">
```

Its matching closing `</div></div>` becomes `</ResponsiveModal>`. Add the
same `ResponsiveModal` import, delete this file's own `if (!open) return
null;` guard, and delete `id="indicator-settings-title"` from the `<h2>` at
line 85.

- [ ] **Step 9: Run the full frontend test suite**

Run: `npm test` (or this repo's equivalent — check `package.json`'s `"test"` script)
Expected: PASS, 0 failures

- [ ] **Step 10: Manually verify in a browser**

Start the dev server (`npm run dev`), open the terminal page, open Indicators,
resize the browser window below 640px wide — the picker should go edge-to-edge
full-screen with no card border; above 640px it should look pixel-identical
to before this task. Repeat for the indicator editor and settings gear.

- [ ] **Step 11: Commit**

```bash
git add components/ResponsiveModal.tsx components/ResponsiveModal.test.tsx components/terminal/IndicatorPickerModal.tsx components/terminal/IndicatorEditorModal.tsx components/terminal/IndicatorSettingsModal.tsx
git commit -m "feat: add ResponsiveModal, retrofit the 3 standalone indicator dialogs"
```

---

## Task 3: Extract `DesktopTerminalLayout`, wire the mobile branch into `page.tsx`

This is a **pure refactor** of already-working code: no behavior changes for
desktop. The safety net is the TypeScript compiler, not hand-transcription —
`page.tsx`'s render body (everything from its `return (` at line 813 to the
end of the file) references dozens of local variables and handlers by
closure; moving that JSX into a new file turns every one of those into a
required prop, and `tsc` will refuse to compile the `<DesktopTerminalLayout>`
call site in `page.tsx` if anything is missing or mistyped. That compile
error is how you find what belongs in the props interface — do not attempt
to enumerate every prop by memory before starting.

**Files:**
- Create: `app/dashboard/terminal/DesktopTerminalLayout.tsx`
- Modify: `app/dashboard/terminal/page.tsx`

**Interfaces:**
- Consumes: `useIsMobile()` from Task 1, `ResponsiveModal` from Task 2 (for this task's own last step, retrofitting the search modal block).
- Produces: `DesktopTerminalLayoutProps` (the full prop interface this task defines — write it down in the file once derived, since Task 7 does not touch this file but should be able to read its exported prop type if useful for comparison, not because it needs to match it).

- [ ] **Step 1: Cut the JSX into a new file**

In `app/dashboard/terminal/page.tsx`, everything from `return (` (currently
line 813) to the matching closing `);` at the end of the component is the
entire render body — including the mobile-blocker `<div className="lg:hidden">`
at the top of that return and the `<div className="hidden lg:flex ...">`
wrapper around the rest. Cut that whole block.

Create `app/dashboard/terminal/DesktopTerminalLayout.tsx` starting from:

```tsx
"use client";

// (copy every import that the cut JSX actually uses -- component imports
// like OrderTicket/ChatPanel/SignalPanel/PositionsPanel/DrawingToolbar/
// IndicatorPickerModal/IndicatorEditorModal/IndicatorSettingsModal/
// ExchangeBadge, plus ResponsiveModal from Task 2, plus any type-only
// imports the JSX references -- tsc will list anything you miss as an
// "cannot find name" error once you get to Step 3)

export function DesktopTerminalLayout(props: DesktopTerminalLayoutProps) {
  const { /* destructure every prop the pasted JSX below references */ } = props;

  return (
    // paste the cut JSX here verbatim, MINUS the outer "lg:hidden" blocker
    // div and the "hidden lg:flex"/"lg:hidden" wrapper classes themselves
    // (those Tailwind escape hatches existed only because both the blocker
    // and the real layout used to render side-by-side in the same file --
    // page.tsx's new isMobile branch replaces that need entirely, so
    // DesktopTerminalLayout's own root element does not need "hidden lg:flex")
  );
}
```

Do not paste the `<div className="lg:hidden">...needs a wider screen...</div>`
block anywhere in this file — that message is now irrelevant (mobile gets a
real layout instead) and should simply not exist in either file going
forward.

- [ ] **Step 2: Define the props interface from what tsc reports missing**

Every identifier the pasted JSX reads that is not a local prop, a plain
DOM/React API, or an already-copied import is a missing prop. Build up
`DesktopTerminalLayoutProps` iteratively: run `npx tsc --noEmit` (Step 3
below explains the call site that will surface these), read each error's
identifier and its type as declared back in `page.tsx` (e.g. `activeSymbol`
is `string`, `indicators` is `AttachedIndicator[]`, `setIndicators` is
`Dispatch<SetStateAction<AttachedIndicator[]>>`, `chartRef` is
`RefObject<ChartAdapter | null>`), add it to the interface with that exact
type, destructure it in the function signature, and re-run `tsc` until the
list of errors in this file reaches zero.

- [ ] **Step 3: Wire the call site in `page.tsx`**

Where the cut JSX used to be, `page.tsx`'s component now ends with:

```tsx
  const isMobile = useIsMobile();

  if (isMobile === null) return null;

  return isMobile
    ? <MobileTerminalLayout /* props added in Task 7 -- leave this line as a
         type error for now: */ {...({} as never)} />
    : <DesktopTerminalLayout {...(/* the full prop bag, one key per prop
         defined in Step 2 above, e.g.: */ {
           activeSymbol, activeExchange, quote, ltp, change, changePct, isUp,
           bid, ask, spread, bars, barsLoading, barsError, setBarsReload,
           chartRef, chartReady, setChartReady, activeTool, pickTool,
           indicators, indicatorPickerOpen, setIndicatorPickerOpen, pickerEntries,
           volumeProfiles, setVolumeProfiles, vsaOn, setVsaOn, setIndicators,
           editorOpen, setEditorOpen, editingIndicator, setEditingIndicator,
           settingsTarget, setSettingsTarget, legendItems, hiddenIds,
           handleDeleteIndicator, handleToggleIndicatorVisible,
           handleSaveIndicatorSettings, reattachIfLive, deleteIndicator: undefined,
           period, setPeriod, rightTab, setRightTab, watchlist, watchlistLoading,
           watchlistBusy, watchlistError, activeInWatchlist, watchlistFull,
           handleAddToWatchlist, handleRemoveFromWatchlist, asking, handleAskAI,
           searchOpen, setSearchOpen, searchQuery, setSearchQuery, searchExchange,
           setSearchExchange, resultFilter, setResultFilter, symbolMatches,
           searchingSymbols, filteredMatches, visibleItems, highlightedIndex,
           setHighlightedIndex, runSearchItem, selectSymbol, q, suggestQuotes,
           displaySignal, signalError, signalLoading, askedEmpty, askError,
           onUseSignal: (side, price) => { setPrefill({ side, price }); setRightTab("trade"); },
           prefill, positions, positionsLoading, positionsError, setPositionsReload,
           applyDrawings, removeTurnDrawings, applyIndicatorChanges, applyCustomIndicators,
           setPrefill, saveConflict: layout.conflict, clearMyDrawings, resetChart,
           /* this list is a starting point derived from reading the file, not
              a guarantee -- tsc's errors at this call site are the real spec */
         })}
      />;
```

This list is intentionally a *starting point*, not a guarantee — build the
real one from `tsc`'s own errors as described in Step 2. Leave the
`MobileTerminalLayout` branch exactly as the placeholder shown (a deliberate
type error) until Task 7; do not attempt to make it compile in this task.

- [ ] **Step 4: Add the `rightTab` type widening and the one-shot mobile-default effect**

In `page.tsx`, change:

```tsx
const [rightTab, setRightTab] = useState<"signal" | "trade" | "positions" | "chat">("signal");
```

to:

```tsx
const [rightTab, setRightTab] = useState<"chart" | "signal" | "trade" | "positions" | "chat">("signal");
```

and directly below the `isMobile` line from Step 3, add:

```tsx
  // A mobile session should open on the chart, not desktop's side-panel
  // default -- but only the first time this resolves true, and only if the
  // user hasn't already touched the tab (still sitting at the untouched
  // "signal" default). Crossing the breakpoint later in the same session
  // must not yank the user off a tab they deliberately picked.
  useEffect(() => {
    if (isMobile && rightTab === "signal") setRightTab("chart");
  }, [isMobile]); // eslint-disable-line react-hooks/exhaustive-deps -- rightTab is read, not depended on: this must fire once per isMobile transition, not every rightTab change
```

- [ ] **Step 5: Retrofit the search-modal block (now inside `DesktopTerminalLayout.tsx`) onto `ResponsiveModal`**

Find the search modal's own backdrop/card pair inside the JSX you just
pasted into `DesktopTerminalLayout.tsx` (originally around `page.tsx` line
852: `role="dialog" aria-modal="true" aria-label="Search symbols"`, backdrop
class `fixed inset-0 z-50 flex items-start justify-center bg-black/70
backdrop-blur-sm p-4 pt-[8vh]`, card class `bg-card border border-border
w-full max-w-md max-h-[70vh] flex flex-col`). Apply the exact same
transformation as Task 2 Step 5: import `ResponsiveModal`, replace the two
opening `<div>`s with `<ResponsiveModal open={searchOpen} onClose={() =>
setSearchOpen(false)} ariaLabel="Search symbols" maxWidthClass="max-w-md"
maxHeightClass="max-h-[70vh]">`, replace the two closing `</div>`s with
`</ResponsiveModal>`, and remove the now-redundant
`{searchOpen && (...)}` guard's outer condition — `ResponsiveModal` already
returns `null` when `open` is false, so the JSX inside no longer needs to be
wrapped in `searchOpen && (...)`; keep the inner content (input, result
list, exchange chips) unchanged.

- [ ] **Step 6: Run tsc and the full test suite**

Run: `npx tsc --noEmit`
Expected: zero errors in `DesktopTerminalLayout.tsx` and `page.tsx` (the
`MobileTerminalLayout` line's deliberate error from Step 3 is expected and
will be resolved in Task 7 — every other file must be clean)

Run: `npm test`
Expected: PASS, 0 failures

- [ ] **Step 7: Manually verify desktop is pixel-identical**

Start the dev server, open the terminal at ≥1024px width. Every existing
behavior (chart, drawing tools, indicators, watchlist, search, signal/trade/
positions/chat tabs) must look and behave exactly as it did before this
task — this is a pure refactor, not a redesign.

- [ ] **Step 8: Commit**

```bash
git add app/dashboard/terminal/page.tsx app/dashboard/terminal/DesktopTerminalLayout.tsx
git commit -m "refactor: extract DesktopTerminalLayout, add the isMobile branch to page.tsx"
```

---

## Task 4: `BottomSheet` generic component

**Files:**
- Create: `components/terminal/mobile/BottomSheet.tsx`
- Test: `components/terminal/mobile/BottomSheet.test.tsx`

**Interfaces:**
- Produces:
  ```typescript
  export function BottomSheet(props: {
    open: boolean;
    onClose: () => void;
    ariaLabel: string;
    children: React.ReactNode;
  }): React.ReactElement | null
  ```

- [ ] **Step 1: Write the failing test**

```typescript
// components/terminal/mobile/BottomSheet.test.tsx
import { describe, expect, it, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { BottomSheet } from "./BottomSheet";

describe("BottomSheet", () => {
  it("renders nothing when closed", () => {
    const { container } = render(
      <BottomSheet open={false} onClose={() => {}} ariaLabel="Test sheet"><p>content</p></BottomSheet>
    );
    expect(container).toBeEmptyDOMElement();
  });

  it("renders its children when open", () => {
    render(<BottomSheet open onClose={() => {}} ariaLabel="Test sheet"><p>content</p></BottomSheet>);
    expect(screen.getByText("content")).toBeInTheDocument();
  });

  it("calls onClose on backdrop click but not on content click", () => {
    const onClose = vi.fn();
    render(<BottomSheet open onClose={onClose} ariaLabel="Test sheet"><p>content</p></BottomSheet>);
    fireEvent.click(screen.getByText("content"));
    expect(onClose).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("dialog"));
    expect(onClose).toHaveBeenCalledOnce();
  });

  it("calls onClose on Escape", () => {
    const onClose = vi.fn();
    render(<BottomSheet open onClose={onClose} ariaLabel="Test sheet"><p>content</p></BottomSheet>);
    fireEvent.keyDown(window, { key: "Escape" });
    expect(onClose).toHaveBeenCalledOnce();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run components/terminal/mobile/BottomSheet.test.tsx`
Expected: FAIL with "Cannot find module './BottomSheet'"

- [ ] **Step 3: Write the implementation**

```tsx
// components/terminal/mobile/BottomSheet.tsx
"use client";

import { useEffect } from "react";

export function BottomSheet({ open, onClose, ariaLabel, children }: {
  open: boolean;
  onClose: () => void;
  ariaLabel: string;
  children: React.ReactNode;
}) {
  useEffect(() => {
    if (!open) return;
    const onKeyDown = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [open, onClose]);

  if (!open) return null;

  return (
    <div
      role="dialog" aria-modal="true" aria-label={ariaLabel}
      className="fixed inset-0 z-50 flex items-end bg-black/70 backdrop-blur-sm"
      onClick={onClose}
    >
      <div
        className="w-full bg-card border-t border-border max-h-[70vh] overflow-y-auto"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="w-10 h-1 bg-border mx-auto my-2" />
        {children}
      </div>
    </div>
  );
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run components/terminal/mobile/BottomSheet.test.tsx`
Expected: PASS (4/4)

- [ ] **Step 5: Commit**

```bash
git add components/terminal/mobile/BottomSheet.tsx components/terminal/mobile/BottomSheet.test.tsx
git commit -m "feat: add generic BottomSheet component for mobile"
```

---

## Task 5: `MobileBottomTabBar`

**Files:**
- Create: `components/terminal/mobile/MobileBottomTabBar.tsx`
- Test: `components/terminal/mobile/MobileBottomTabBar.test.tsx`

**Interfaces:**
- Consumes: the widened `rightTab` type from Task 3 (`"chart" | "signal" | "trade" | "positions" | "chat"`).
- Produces:
  ```typescript
  export function MobileBottomTabBar(props: {
    active: "chart" | "signal" | "trade" | "positions" | "chat";
    onChange: (tab: "chart" | "signal" | "trade" | "positions" | "chat") => void;
  }): React.ReactElement
  ```

- [ ] **Step 1: Write the failing test**

```typescript
// components/terminal/mobile/MobileBottomTabBar.test.tsx
import { describe, expect, it, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { MobileBottomTabBar } from "./MobileBottomTabBar";

describe("MobileBottomTabBar", () => {
  it("renders all 5 tabs", () => {
    render(<MobileBottomTabBar active="chart" onChange={() => {}} />);
    for (const label of ["Chart", "Signal", "Trade", "Positions", "Chat"]) {
      expect(screen.getByRole("button", { name: label })).toBeInTheDocument();
    }
  });

  it("calls onChange with the tapped tab's key", () => {
    const onChange = vi.fn();
    render(<MobileBottomTabBar active="chart" onChange={onChange} />);
    fireEvent.click(screen.getByRole("button", { name: "Chat" }));
    expect(onChange).toHaveBeenCalledWith("chat");
  });

  it("shows a text label only on the active tab", () => {
    render(<MobileBottomTabBar active="signal" onChange={() => {}} />);
    // Active tab's own button contains visible text; inactive ones show
    // only their icon (label present for a11y but visually hidden).
    const signalButton = screen.getByRole("button", { name: "Signal" });
    expect(signalButton.querySelector("span:not(.sr-only)")).not.toBeNull();
    const chatButton = screen.getByRole("button", { name: "Chat" });
    expect(chatButton.querySelector("span:not(.sr-only)")).toBeNull();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run components/terminal/mobile/MobileBottomTabBar.test.tsx`
Expected: FAIL with "Cannot find module './MobileBottomTabBar'"

- [ ] **Step 3: Write the implementation**

```tsx
// components/terminal/mobile/MobileBottomTabBar.tsx
"use client";

type Tab = "chart" | "signal" | "trade" | "positions" | "chat";

const TABS: { key: Tab; label: string; icon: React.ReactNode }[] = [
  { key: "chart", label: "Chart", icon: <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><line x1="18" y1="20" x2="18" y2="10" /><line x1="12" y1="20" x2="12" y2="4" /><line x1="6" y1="20" x2="6" y2="14" /></svg> },
  { key: "signal", label: "Signal", icon: <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><circle cx="12" cy="12" r="3" /><path d="M12 2v3M12 19v3M4.22 4.22l2.12 2.12M17.66 17.66l2.12 2.12M2 12h3M19 12h3M4.22 19.78l2.12-2.12M17.66 6.34l2.12-2.12" /></svg> },
  { key: "trade", label: "Trade", icon: <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><path d="M3 3v18h18" /><path d="M18 9l-5 5-4-4-4 4" /></svg> },
  { key: "positions", label: "Positions", icon: <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><rect x="3" y="3" width="7" height="7" /><rect x="14" y="3" width="7" height="7" /><rect x="14" y="14" width="7" height="7" /><rect x="3" y="14" width="7" height="7" /></svg> },
  { key: "chat", label: "Chat", icon: <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" /></svg> },
];

export function MobileBottomTabBar({ active, onChange }: { active: Tab; onChange: (tab: Tab) => void }) {
  return (
    <div className="flex border-t border-border shrink-0 bg-card">
      {TABS.map((tab) => {
        const isActive = active === tab.key;
        return (
          <button
            key={tab.key}
            aria-label={tab.label}
            aria-current={isActive ? "page" : undefined}
            onClick={() => onChange(tab.key)}
            className={`flex-1 flex flex-col items-center gap-0.5 py-2 transition-colors ${isActive ? "text-link" : "text-muted-foreground"}`}
          >
            {tab.icon}
            {isActive ? (
              <span className="text-[10px] font-semibold">{tab.label}</span>
            ) : (
              <span className="sr-only">{tab.label}</span>
            )}
          </button>
        );
      })}
    </div>
  );
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run components/terminal/mobile/MobileBottomTabBar.test.tsx`
Expected: PASS (3/3)

- [ ] **Step 5: Commit**

```bash
git add components/terminal/mobile/MobileBottomTabBar.tsx components/terminal/mobile/MobileBottomTabBar.test.tsx
git commit -m "feat: add MobileBottomTabBar"
```

---

## Task 6: `MobileChartToolbar`

**Files:**
- Create: `components/terminal/mobile/MobileChartToolbar.tsx`
- Test: `components/terminal/mobile/MobileChartToolbar.test.tsx`

**Interfaces:**
- Consumes: `BottomSheet` (Task 4), `DRAW_TOOLS` and `DrawTool` from `components/terminal/DrawingToolbar.tsx` (existing, unchanged), `IndicatorPickerModal` (Task 2, already `ResponsiveModal`-wrapped), `PERIODS` from `lib/periods.ts` (existing, unchanged).
- Produces:
  ```typescript
  export function MobileChartToolbar(props: {
    symbol: string;
    exchange: string;
    currency: string;
    ltp: number | null;
    onOpenSearch: () => void;
    activeTool: string;
    onPickTool: (tool: DrawTool) => void;
    period: string;
    onPickPeriod: (label: string) => void;
    onOpenIndicators: () => void;
  }): React.ReactElement
  ```

- [ ] **Step 1: Write the failing test**

```typescript
// components/terminal/mobile/MobileChartToolbar.test.tsx
import { describe, expect, it, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { MobileChartToolbar } from "./MobileChartToolbar";

const baseProps = {
  symbol: "RELIANCE", exchange: "NSE", currency: "₹", ltp: 1310.5,
  onOpenSearch: vi.fn(), activeTool: "cursor", onPickTool: vi.fn(),
  period: "1D", onPickPeriod: vi.fn(), onOpenIndicators: vi.fn(),
};

describe("MobileChartToolbar", () => {
  it("shows the symbol and price, tapping it opens search", () => {
    const onOpenSearch = vi.fn();
    render(<MobileChartToolbar {...baseProps} onOpenSearch={onOpenSearch} />);
    expect(screen.getByText("RELIANCE")).toBeInTheDocument();
    fireEvent.click(screen.getByText("RELIANCE"));
    expect(onOpenSearch).toHaveBeenCalledOnce();
  });

  it("opens the drawing-tools sheet from the pencil icon, and picking a tool calls onPickTool", () => {
    const onPickTool = vi.fn();
    render(<MobileChartToolbar {...baseProps} onPickTool={onPickTool} />);
    fireEvent.click(screen.getByLabelText("Drawing tools"));
    fireEvent.click(screen.getByTitle("Trend line"));
    expect(onPickTool).toHaveBeenCalledWith(expect.objectContaining({ key: "trendline" }));
  });

  it("calls onOpenIndicators from the Indicators icon", () => {
    const onOpenIndicators = vi.fn();
    render(<MobileChartToolbar {...baseProps} onOpenIndicators={onOpenIndicators} />);
    fireEvent.click(screen.getByLabelText("Indicators"));
    expect(onOpenIndicators).toHaveBeenCalledOnce();
  });

  it("renders every period as a tappable pill and calls onPickPeriod", () => {
    const onPickPeriod = vi.fn();
    render(<MobileChartToolbar {...baseProps} onPickPeriod={onPickPeriod} />);
    fireEvent.click(screen.getByText("1W"));
    expect(onPickPeriod).toHaveBeenCalledWith("1W");
  });
});
```

Check `lib/periods.ts` for `PERIODS`' exact shape (label field name) before
writing the implementation below — the test above assumes a `"1W"` label
exists among `PERIODS`; adjust to whatever labels actually exist if they
differ.

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run components/terminal/mobile/MobileChartToolbar.test.tsx`
Expected: FAIL with "Cannot find module './MobileChartToolbar'"

- [ ] **Step 3: Write the implementation**

```tsx
// components/terminal/mobile/MobileChartToolbar.tsx
"use client";

import { useState } from "react";
import { BottomSheet } from "./BottomSheet";
import { DRAW_TOOLS, type DrawTool } from "@/components/terminal/DrawingToolbar";
import { PERIODS } from "@/lib/periods";

export function MobileChartToolbar({
  symbol, exchange, currency, ltp, onOpenSearch,
  activeTool, onPickTool, period, onPickPeriod, onOpenIndicators,
}: {
  symbol: string; exchange: string; currency: string; ltp: number | null;
  onOpenSearch: () => void;
  activeTool: string; onPickTool: (tool: DrawTool) => void;
  period: string; onPickPeriod: (label: string) => void;
  onOpenIndicators: () => void;
}) {
  const [drawingSheetOpen, setDrawingSheetOpen] = useState(false);

  return (
    <div className="border-b border-border shrink-0">
      <div className="flex items-center gap-2 px-2 py-1.5">
        <button onClick={onOpenSearch} className="flex items-baseline gap-1.5 min-w-0 flex-1 text-left">
          <span className="font-bold text-sm truncate">{symbol}</span>
          <span className="text-[10px] text-muted-foreground font-mono shrink-0">{exchange}</span>
          {ltp !== null && <span className="font-mono text-xs font-semibold ml-1 shrink-0">{currency}{ltp.toFixed(2)}</span>}
        </button>
        <button aria-label="Drawing tools" onClick={() => setDrawingSheetOpen(true)}
          className="w-8 h-8 flex items-center justify-center text-muted-foreground hover:text-foreground shrink-0">
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8"><line x1="4" y1="20" x2="20" y2="4" /></svg>
        </button>
        <button aria-label="Indicators" onClick={onOpenIndicators}
          className="w-8 h-8 flex items-center justify-center text-muted-foreground hover:text-foreground shrink-0">
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8"><path d="M3 3v18h18" /><path d="M18 9l-5 5-4-4-4 4" /></svg>
        </button>
      </div>

      <div className="flex gap-1 px-2 pb-1.5 overflow-x-auto no-scrollbar">
        {PERIODS.map((p) => (
          <button key={p.label} onClick={() => onPickPeriod(p.label)}
            className={`px-2 py-1 text-[11px] font-mono font-semibold shrink-0 transition-colors ${
              period === p.label ? "bg-primary/15 text-link" : "text-muted-foreground hover:bg-secondary"
            }`}>
            {p.label}
          </button>
        ))}
      </div>

      <BottomSheet open={drawingSheetOpen} onClose={() => setDrawingSheetOpen(false)} ariaLabel="Drawing tools">
        <div className="grid grid-cols-4 gap-1 p-3">
          {DRAW_TOOLS.map((t) => (
            <button
              key={t.key}
              title={t.title}
              aria-pressed={activeTool === t.key}
              onClick={() => { onPickTool(t); setDrawingSheetOpen(false); }}
              className={`flex flex-col items-center gap-1 p-3 transition-colors ${
                activeTool === t.key ? "bg-primary/15 text-link" : "text-muted-foreground hover:bg-secondary"
              }`}
            >
              {t.icon}
              <span className="text-[10px]">{t.title}</span>
            </button>
          ))}
        </div>
      </BottomSheet>
    </div>
  );
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run components/terminal/mobile/MobileChartToolbar.test.tsx`
Expected: PASS (4/4)

- [ ] **Step 5: Commit**

```bash
git add components/terminal/mobile/MobileChartToolbar.tsx components/terminal/mobile/MobileChartToolbar.test.tsx
git commit -m "feat: add MobileChartToolbar (search trigger, drawing sheet, indicators, period pills)"
```

---

## Task 7: `MobileTerminalLayout` — assemble everything, complete the `page.tsx` wiring

**Files:**
- Create: `app/dashboard/terminal/MobileTerminalLayout.tsx`
- Modify: `app/dashboard/terminal/page.tsx` (replace Task 3's deliberate placeholder with the real call)

**Interfaces:**
- Consumes: `MobileBottomTabBar` (Task 5), `MobileChartToolbar` (Task 6), the chart-mounting JSX and props already proven out in `DesktopTerminalLayout` (Task 3) — the actual `<div>` that hosts the chart adapter, plus `SignalPanel`/`OrderTicket`/`PositionsPanel`/`ChatPanel` usages, are the same components with the same props, just arranged differently.
- Produces: `MobileTerminalLayoutProps` — same shared prop bag `page.tsx` already builds for `DesktopTerminalLayout` in Task 3 (both layouts take the identical props object; this task does not invent a second one).

- [ ] **Step 1: Write the component skeleton**

```tsx
// app/dashboard/terminal/MobileTerminalLayout.tsx
"use client";

import { useState } from "react";
import { MobileBottomTabBar } from "@/components/terminal/mobile/MobileBottomTabBar";
import { MobileChartToolbar } from "@/components/terminal/mobile/MobileChartToolbar";
// (import everything DesktopTerminalLayout.tsx already imports for the chart
// mount + SignalPanel/OrderTicket/PositionsPanel/ChatPanel/IndicatorPickerModal/
// IndicatorEditorModal/IndicatorSettingsModal -- same components, same props)

export function MobileTerminalLayout(props: DesktopTerminalLayoutProps) {
  const {
    symbol: activeSymbol, exchange: activeExchange, /* ...destructure the
    same props DesktopTerminalLayout.tsx uses for: chart mount (chartRef,
    chartReady, setChartReady, bars, barsLoading, barsError), activeTool +
    pickTool, indicators + indicator handlers + indicatorPickerOpen/
    editorOpen/settingsTarget wiring, period + setPeriod, rightTab +
    setRightTab, searchOpen/setSearchOpen (for MobileChartToolbar's
    onOpenSearch), and SignalPanel/OrderTicket/PositionsPanel/ChatPanel's own
    props exactly as DesktopTerminalLayout passes them today */
  } = props;

  return (
    <div className="h-full flex flex-col">
      {/* Chart destination -- always mounted, CSS-hidden when another tab
          is active. See Task 3/DesktopTerminalLayout.tsx for the exact
          chart-mounting JSX (the div the ChartAdapter mounts into, plus
          the barsLoading/barsError/empty states) -- copy that block here
          unchanged, it does not change shape between layouts. */}
      <div className={rightTab === "chart" ? "flex-1 flex flex-col min-h-0" : "hidden"}>
        <MobileChartToolbar
          symbol={activeSymbol} exchange={activeExchange}
          currency={/* same CURRENCY[activeExchange] lookup DesktopTerminalLayout uses */ "₹"}
          ltp={props.ltp}
          onOpenSearch={() => props.setSearchOpen(true)}
          activeTool={props.activeTool} onPickTool={props.pickTool}
          period={props.period} onPickPeriod={props.setPeriod}
          onOpenIndicators={() => props.setIndicatorPickerOpen(true)}
        />
        <div className="flex-1 min-h-0 relative bg-card">
          {/* paste the exact chart-mount JSX from DesktopTerminalLayout.tsx here */}
        </div>
      </div>

      {/* Signal / Trade / Positions / Chat -- each keeps its EXISTING mount
          policy from DesktopTerminalLayout.tsx (OrderTicket CSS-hidden,
          the other three conditionally rendered), just inside a full-screen
          container instead of the 340px side column. */}
      {rightTab !== "chart" && (
        <div className="flex-1 min-h-0 overflow-y-auto p-3">
          {/* copy the exact rightTab === "signal"/"trade"/"positions"/"chat"
              blocks from DesktopTerminalLayout.tsx here, unchanged */}
        </div>
      )}

      <MobileBottomTabBar active={rightTab} onChange={setRightTab} />

      {/* Search modal, indicator picker/editor/settings -- reuse the exact
          same ResponsiveModal-wrapped JSX/components DesktopTerminalLayout.tsx
          already uses; ResponsiveModal itself already goes full-screen below
          640px, so nothing mobile-specific is needed here beyond rendering
          them. */}
    </div>
  );
}
```

This file legitimately duplicates some JSX from `DesktopTerminalLayout.tsx`
(the chart-mount block, the 4 tab-content blocks) rather than sharing it via
a further extraction — the two layouts arrange that content differently
enough (full-screen tab-per-destination vs. side-by-side-with-chart) that
forcing a shared sub-component at this level would cost more in
indirection than it saves. Keep the actual `SignalPanel`/`OrderTicket`/
`PositionsPanel`/`ChatPanel`/chart-adapter calls and their props identical
to `DesktopTerminalLayout.tsx` byte-for-byte — only the surrounding
container markup differs.

- [ ] **Step 2: Fill in every placeholder comment against the real `DesktopTerminalLayout.tsx`**

Open `DesktopTerminalLayout.tsx` (from Task 3) side-by-side and copy each
referenced block verbatim into the matching spot above. Run `npx tsc
--noEmit` after each block — the same "let the compiler tell you what's
missing" approach as Task 3 applies here too, since this file also
consumes the full shared prop bag.

- [ ] **Step 3: Complete the `page.tsx` wiring**

Replace Task 3's deliberate placeholder:

```tsx
    ? <MobileTerminalLayout /* props added in Task 7 -- leave this line as a
         type error for now: */ {...({} as never)} />
```

with:

```tsx
    ? <MobileTerminalLayout {...(/* the exact same prop object literal
         already built for DesktopTerminalLayout in Task 3 -- both layouts
         take the identical props, so this is the same variable/object,
         not a second one */)} />
```

If Task 3 built the prop bag inline per-branch, factor it into a single
`const sharedProps = {...}` above the `return`, used by both branches, so
there is exactly one place listing every prop instead of two copies that
could drift.

- [ ] **Step 4: Run tsc and the full test suite**

Run: `npx tsc --noEmit`
Expected: zero errors anywhere in `app/dashboard/terminal/`

Run: `npm test`
Expected: PASS, 0 failures

- [ ] **Step 5: Commit**

```bash
git add app/dashboard/terminal/MobileTerminalLayout.tsx app/dashboard/terminal/page.tsx
git commit -m "feat: add MobileTerminalLayout, complete the mobile terminal wiring"
```

---

## Task 8: Real mobile-viewport browser verification

Not a code task — this is the project's own stated rule that a frontend
change isn't verified until it's exercised in a real browser, and a
responsive/touch layout is exactly the kind of change type-checking and
unit tests cannot fully validate.

- [ ] **Step 1: Start the app**

Follow this repo's own `run` skill / existing dev-server instructions
(`npm run dev` from `ai-trader-frontend`, plus whatever backend services the
terminal page needs live — check for a project-specific run skill first).

- [ ] **Step 2: Drive it at a phone viewport**

Using Playwright (or this repo's existing browser-driving setup, per the
`run` skill's guidance to check for one before hand-rolling a driver), set
the viewport to a real phone size (e.g. 390×844, iPhone 12) and navigate to
`/dashboard/terminal`.

- [ ] **Step 3: Verify each behavior named in the spec**

- Chart renders full-height under the compact toolbar, above the bottom tab bar.
- Tapping Signal → Trade → back to Chart does not reset the chart's pan/zoom
  (zoom in on the chart first, switch tabs, switch back, confirm the zoom
  level held).
- Tapping the pencil icon opens the drawing-tools sheet; tapping a tool
  closes the sheet and sets it active; a touch-simulated tap-drag on the
  chart places a drawing.
- Tapping the symbol/price opens search full-screen (no centered-card
  chrome visible at this viewport width); selecting a result updates the
  chart and closes search.
- Opening the Chat tab and focusing its text input does not hide the input
  behind the on-screen keyboard or the bottom tab bar (check on an actual
  mobile browser or Chrome DevTools' device toolbar with the keyboard
  simulation, not just Playwright's headless viewport, which does not model
  a real on-screen keyboard).

- [ ] **Step 4: Fix anything that fails, re-verify, report status**

If a step fails, fix the relevant component from Tasks 1–7 and re-run this
whole verification pass — do not consider the plan complete until all of
Step 3 passes on a real mobile viewport.
