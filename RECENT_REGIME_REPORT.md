# RECENT_REGIME_REPORT.md

## The premise this report was asked to evaluate

The task states: *"Recent independent research through August 2026 has
replicated the historical strategy but also documented substantial
deterioration beginning in late 2025. Therefore the recent period must be
treated as a critical untouched validation regime."*

## What this repository can actually say about that claim

**Nothing, directly — and it says so rather than either confirming or
quietly ignoring the premise.** Per `DATA_AUDIT.md`, no real SPY intraday
history is reachable in this environment for late 2025 or the first half
of 2026. The Robinhood sandbox connector's real (non-interpolated) history
starts 2026-07-16. There is no way, from inside this environment, to
compute this strategy's actual late-2025-through-mid-2026 performance and
compare it against the referenced independent research. This report does
not attempt to paper over that with a plausible-sounding number.

## What this repository *can* say: the trailing 6-week window actually tested

The only real out-of-sample-like window available — 2026-07-16 through
2026-08-25 — is late enough to plausibly sit inside the "deterioration"
period the premise describes, *if* that premise applies to this
environment's price series at all (which is itself unverifiable here; see
`DATA_AUDIT.md` — this sandbox's price series should not be assumed to be
a faithful reproduction of real-world SPY's actual 2026 price action).
Treating it only as "whatever most-recent real data this environment
has," independent of whether it's the same market the cited research
describes:

- **Signal frequency was very low**: 2 qualifying signals in 180 eligible
  checkpoints (1.1%) across 15 sessions. Realized sigma averaged 0.39%,
  producing tight Noise Area bands (~0.54% half-width) that price rarely
  broke through with VWAP confirmation.
- **Both signals that did fire lost money** (−0.234% and −0.055% on the
  underlying, before any options overlay). That is directionally
  consistent with a deteriorating/non-working regime, but **n=2 cannot
  distinguish "genuine regime deterioration" from ordinary sampling noise**
  — a coin flipped twice landing tails twice is not evidence the coin is
  biased.
- No conclusion about win rate, profit factor, Sharpe, or drawdown is
  drawn from this window for the reasons detailed in `BACKTEST_REPORT.md`
  ("Metrics NOT computed, and why").

## Reading this alongside the cited independent research

If the cited research's "late 2025 deterioration" finding is accurate for
real-world SPY, this repository's inability to test it is a **data-access
gap in this specific sandboxed session**, not a rebuttal of that finding —
and, symmetrically, this repository's 2-trade, both-losing sample is not
independent confirmation of it either. Both readings would be
overclaiming from n=2.

## What would actually test this

Real SPY 1-minute history for 2023-01 through 2026-08 (per
`STRATEGY_SPEC.md`'s intended chronological split) from a real market-data
vendor, run once through the frozen, unmodified signal engine in this
repository, split at the pre-registered 2025-01-01 boundary — exactly the
protocol `RESEARCH_LEDGER.md` and `STRATEGY_SPEC.md` §13-14 already commit
to. The code to do this exists and is unit-tested; only the data source
is missing in this environment.

## Bottom line for this report

**2025–2026 OOS: FAIL (data-blocked, not evidence-based).** No claim of
either confirming or refuting the cited deterioration is made.
