# RESEARCH_LEDGER.md

Every variant tested against real data, in order, with what was seen before
and after. The anti-overfitting protocol (`STRATEGY_SPEC.md` §13-14)
requires this ledger so no parameter is ever silently re-tuned after
viewing results.

## Entry 1 — Baseline strategy, frozen before any result was seen

- **Date**: 2026-08-26.
- **Change**: none — this is the initial frozen rule set from
  `STRATEGY_SPEC.md`, committed (`git` commit `1cc26fd`) before any line of
  `spy_options/signal_engine.py` was written and before any bar of market
  data was fetched.
- **Params**: 14-session sigma lookback, 12 fixed checkpoints, VWAP
  confirmation required, `allow_immediate_reversal=False`, primary option
  policy 1DTE/|Δ|≈0.55, 5%-of-mid spread filter, realistic fill = mid + 25%
  half-spread.
- **Result seen before this entry was written**: none. This entry exists
  to record that the spec was frozen first.

## Entry 2 — Signal-engine implementation + deterministic unit tests

- **Date**: 2026-08-26.
- **Change**: implemented `spy_options/signal_engine.py`,
  `spy_options/timeutil.py`, and 20 (later 78 total, across all modules)
  deterministic unit tests against synthetic fixtures — no real market data
  involved. Several tests initially failed against the first implementation
  and were used to fix real bugs (a reversal-vs-trail-exit priority
  ambiguity, a force-flatten-at-15:55 timing bug, a tz-normalization bug in
  the paper engine's bar buffer) — all logged as bug fixes in `git log`,
  not as strategy-parameter changes.
- **Params**: unchanged from Entry 1.
- **Result**: 78/78 unit tests pass. This validates the *mechanics* of the
  signal engine (leakage-free sigma, correct band anchoring on gaps,
  correct checkpoint timing, correct exit priority) — it says nothing yet
  about whether the strategy is profitable, because no real price history
  had been evaluated at this point.

## Entry 3 — Data availability check (before any real-data backtest)

- **Date**: 2026-08-26.
- **Change**: none to the strategy. Probed the only two reachable data
  sources (Robinhood MCP connector; general internet egress) to determine
  what real historical data this environment can actually support. Findings
  in full in `DATA_AUDIT.md`.
- **Result**: no real 2018–2025 SPY history reachable; no real historical
  options quotes reachable at all. Real intraday history reachable only for
  2026-07-16 through 2026-08-25 (29 sessions). **This determined the scope
  of every subsequent entry — it was not a choice made to shrink the test
  until a preferred result appeared.**

## Entry 4 — Underlying backtest, real sandbox window (smoke test only)

- **Date**: 2026-08-26.
- **Change**: none to the strategy or parameters. Ran the frozen Entry-1
  rule set, unmodified, against the 29-session real window from Entry 3.
- **Result**: 15 eligible sessions (14 consumed by warm-up), 180
  checkpoint opportunities, **2 trades** (1 long, 1 short), both small
  losers (-0.23% and -0.06% on the underlying), both exited via
  `signal_exit`. Full detail in `BACKTEST_REPORT.md`.
- **Decision**: **no parameter was changed in response to this result.**
  Two trades is far too small a sample to tune anything against, and doing
  so would be exactly the overfitting this ledger exists to prevent. The
  result is reported as-is, labeled as an infrastructure smoke test, not as
  evidence of edge or lack of edge.

## Entry 5 — Options backtest, all frozen policies × fill models

- **Date**: 2026-08-26.
- **Change**: none to the strategy. Ran `run_option_backtest` for all 4
  frozen contract policies × 3 fill models (12 combinations) against the 2
  underlying trades from Entry 4, using `NullHistoricalOptionProvider`
  (the honest representation of what this environment can supply).
- **Result**: all 12 combinations returned `BlockedResult` with reason
  `no_institutional_options_data_provider_reachable`. No option P&L number
  of any kind was produced or reported for any policy.
- **Decision**: options profitability is `BLOCKED BY DATA`, not `FAIL`.
  These are different outcomes and the two are not conflated anywhere in
  this repository's reports.

## Post-hoc ideas explicitly NOT tested against the sandbox window

None were conceived after viewing Entry 4/5's results. If a future session
wants to test, e.g., a shorter sigma lookback or a wider spread filter
because the 29-session window showed only 2 signals, that is a **new
hypothesis** and must be logged here with its own entry and tested only on
data that has not yet been used to evaluate the canonical baseline — it may
NOT be retroactively tested against the same 2026-07-16..08-25 window and
reported as if it were still out-of-sample.

## What remains untested (blocked by data, not by decision)

- The full 2018–2022 / 2023–2024 / 2025–2026 chronological split.
- The published Zarattini/Aziz/Barbon replication comparison.
- The claimed late-2025 strategy deterioration — this repository can
  neither confirm nor refute it; see `RECENT_REGIME_REPORT.md`.
- All four frozen option policies' actual historical P&L.
- VIX-regime conditioning (skipped given `n=2`, not attempted and hidden).
