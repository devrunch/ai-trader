# Remaining Work — Index

One file per topic. Each file states the **aim**, **why it matters**, and the
**tasks**.

Source: a trader's audit of the system, triaged against Phase 1 scope. The
code-quality audit that ran alongside it is closed — all 34 of its findings were
fixed.

---

Two audits fed this: a **trader's audit** of whether the system is safe and
honest (files 01–10), and a **UX audit** of the frontend (files 11–15).

## Blocking — nothing goes in front of a user without these

| # | Topic | Aim |
|---|---|---|
| [11](11-order-flow.md) | **Order flow** | **An order does what the ticket said, exactly once** |
| [01](01-risk-limits.md) | Risk limits | Stop one bad session from wiping the account |
| [02](02-tradability.md) | Tradability | Only produce output a user can actually act on |
| [03](03-market-hours.md) | Market hours | Only run when the market is open; don't hold overnight |
| [04](04-signal-integrity.md) | Signal integrity | Each signal is one real trade on finished data |
| [05](05-honest-reporting.md) | Honest reporting | The scoreboard teaches the right thing |
| [12](12-error-and-empty-states.md) | Error and empty states | Never show a confidently wrong number |
| [14](14-trust-and-claims.md) | Trust and claims | Claim nothing the product cannot do |

Start with **11**. It is the only item where the UI actively misreports what it
did with the user's money.

## Should do — this is what a demo actually shows

| # | Topic | Aim |
|---|---|---|
| [06](06-chart-correctness.md) | Chart correctness | Drawings don't contradict their own labels |
| [07](07-agent-tools.md) | Agent tools | The analyst's numbers are trustworthy |
| [08](08-morning-brief.md) | Morning brief | The headline deliverable ranks sensibly |
| [13](13-stale-data.md) | Stale data | The user knows how old the number is |
| [15](15-accessibility-and-responsive.md) | Accessibility and responsive | Usable without a mouse or perfect colour vision |

## Before deploying

| # | Topic | Aim |
|---|---|---|
| [09](09-deploy-verification.md) | Deploy verification | Three things verified only on paper |

## Agent — sessions and production hardening

| # | Topic | Aim |
|---|---|---|
| [16](16-agent-sessions-and-production.md) | Agent sessions | A turn that is durable, cheap, bounded and accountable |

Opened after the agent event stream was built. Covers durable chat/chart/strategy
state, the trade-to-reasoning audit trail, orchestration structure, token cost,
over-tooling and idempotency.

## Later

| # | Topic | Aim |
|---|---|---|
| [10](10-phase-2-deferred.md) | Phase 2 | What needs better data or a trained model |

Raw audit output, with every `file:line`: [`../ux-audit.md`](../ux-audit.md).

---

## The overall aim

**Phase 1: an AI analyst that shows its work and manages your risk properly,
with a measured and published track record.**

Not "profitable signals." That claim needs Phase 2 — paid data, a trained model,
and enough trades to prove it.

Everything in files 01–05 exists because the system currently makes a claim it
cannot support, or produces something a user cannot use, or reports a number
that misleads. Those are honesty bugs, and they are cheaper to fix than to
explain later.
