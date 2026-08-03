# 07 — Agent Tools

**Aim:** every number the AI analyst quotes is one you could defend if the user
challenged it.

**Status:** DONE (2026-07-26), with tests.

---

## Why it matters

The agent is the product's differentiator. Its credibility rests entirely on the
tools, because of the architectural rule the codebase enforces:

> **Deterministic maths produces every number. The LLM only chooses and
> narrates.**

The model never invents a price, a size or a statistic — it calls a tool and
interprets the result. That is why the LLM integration is not the scariest part
of this codebase. But it also means **a wrong tool result becomes a confidently
stated wrong answer**, with the model's fluency lending it authority it hasn't
earned.

### The backtest tool flatters itself

`backtest_strategy` runs a rule strategy over history and reports a win rate. The
agent quotes it directly.

**Partly fixed:** a position still open at the end of the window used to be
silently dropped. Since a strategy that enters and never exits tends to be
sitting in its *worst* trade, the worst outcome was being excluded from every win
rate the agent quoted. It is now reported as `open_trade`.

**Still wrong, two ways:**

*No stop loss.* A position can run −20% and still count as a single open trade.
No real strategy behaves like that, so the reported returns describe something
nobody would trade.

*One-bar lookahead.* It enters at the **close of the very bar that generated the
signal**. In reality you cannot know a bar's close until it has closed — by which
time you can only enter at the *next* bar's open. Systematically entering at a
price you could not have got makes every backtest look better than reality. This
is the classic backtesting error and it is worth understanding once: any use of a
bar's own close to decide an entry on that same bar is lookahead.

### Position sizing can use an hours-old account value

Every sizing recommendation scales off `totalValue`. That field updates only on
an explicit refresh call or the next fill — and **nothing calls it on a
schedule**. So after a morning of price movement, sizing advice can be based on
an account value from hours ago.

The sizing tool is already careful in the right way — it refuses to guess an
account value when the fetch fails, because an earlier version defaulted to
₹1,00,000 and would have handed a ₹20,000 account 5× oversize with no warning.
A stale value is the same failure mode, just quieter.

---

## Tasks

- [x] **Add a stop-loss parameter to `analysis.backtest`.** Exit at the stop when
      hit. Default it to something sane rather than leaving it optional and
      unused.

- [x] **Fill at the next bar's open, not the signal bar's close.** Removes the
      one-bar lookahead. Expect reported returns to drop — that is the fix
      working.

- [x] **Refresh the account mark inside `getPortfolio`,** or refuse to size when
      the mark is older than a few minutes. Refusing is consistent with how the
      tool already handles a missing account value.

- [x] **Keep the caveats in tool output.** Every tool result already carries an
      honest caveat string (`"In sample only, no costs modelled..."`). Preserve
      that pattern for any new tool — it is what stops the agent overselling a
      result.

**Effort:** ~1 day.

---

## Files

| | |
|---|---|
| Strategy backtest | `ai-trader-signals/app/signals/analysis.py` (`_run_signals`, `backtest`) |
| Sizing / risk tools | `ai-trader-signals/app/signals/agent/portfolio_tools.py` |
| Account value | `ai-trader-api/src/portfolio/paper-trading.service.ts` (`getPortfolio`) |
| Tests | `ai-trader-signals/tests/test_analysis.py`, `tests/test_position_size.py` |
