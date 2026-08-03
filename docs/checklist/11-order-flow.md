# 11 — Order Flow

**Aim:** an order does what the ticket said it would do, exactly once.

**Status:** DONE (2026-07-26). Limit orders are sent as LIMIT, the toast reports the fill,
and the confirm button cannot be double-clicked.

**Why this file mattered most:** a user could lose money-equivalent state
through a UI that misreported what it did.

Source: [`docs/ux-audit.md`](../ux-audit.md) §3. Every finding below was verified
independently against the code.

---

## Why it matters

### "Limit" is a lie

The order ticket has a Market/Limit toggle. When the user selects **Limit**, the
frontend sends `limitPrice` but **never sends `type`**
(`components/OrderTicket.tsx:58`). The API defaults it:

```ts
type: dto.type ?? OrderType.MARKET      // paper-trading.service.ts:177
```

So the LIMIT branch at `:221` — the one that checks whether the price was
actually reached — never runs. **The user asks for a limit order and gets a
market order**, filled immediately at whatever the market is doing.

Then the success toast reports `@ ₹{price}` (`OrderTicket.tsx:190`) — the limit
price the user typed, not the price they filled at. The Orders tab shows the real
fill. Two screens in the same app state different prices for the same trade.

A limit order exists precisely so you *don't* fill at a bad price. Silently
converting it to a market order removes the only protection the user asked for,
and then hides the evidence.

### The confirm button can be clicked twice

`handleConfirm` (`OrderTicket.tsx:56`) has no in-flight state, the button carries
no `disabled` (`:177`), and nothing changes visually until the round-trip
resolves — so a user on a slow connection has every reason to click again.

The backend's atomic `$inc` guard (`paper-trading.service.ts:243`) prevents
*overdraft*, not *duplication*. With cash available, both clicks fill. The user
wanted one position and has two.

---

## Tasks

- [x] **Send the order type.** Pass `type: priceMode === "Limit" ? "LIMIT" : "MARKET"`
      from `OrderTicket.tsx:58`. One line. Verify the LIMIT branch then rejects
      an unreachable limit with the existing message.

- [x] **Report the fill price, not the requested price.** The success toast must
      read the executed price off the API response.

- [x] **Guard against double submit.** In-flight state, `disabled` on the button,
      and a spinner or label change within 100ms of the click.

- [x] **Make the order-type selector do something visible.** Right now
      (`ux-audit.md` §3) switching it changes no other field and has no effect —
      even once wired, a Limit order should make the price field authoritative
      and show that the order may not fill immediately.

- [x] **Confirm destructive resets.** Resetting the paper account destroys trade
      history. Currently it happens without saying so. Require explicit
      confirmation naming what is lost.

- [x] **Preserve the half-filled order form when switching right-panel tabs.**
      Currently the state is destroyed (`ux-audit.md` §6) — a user who checks the
      chart mid-order loses their entry.

**Effort:** ~half a day for the first three, which are the ones that matter.

---

## Files

| | |
|---|---|
| Order ticket | `ai-trader-frontend/components/OrderTicket.tsx` |
| API client | `ai-trader-frontend/lib/api.ts` |
| Order execution | `ai-trader-api/src/portfolio/paper-trading.service.ts` |
| DTO | `ai-trader-api/src/portfolio/dto/place-order.dto.ts` |
