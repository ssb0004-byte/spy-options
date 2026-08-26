# BACKTEST_REPORT.md — SPY Underlying Signal Engine

**Read `DATA_AUDIT.md` first.** This report covers the only real data
reachable in this environment: 29 SPY trading sessions, 2026-07-16 through
2026-08-25, 1-minute RTH bars. It is **not** a replication of the
Zarattini/Aziz/Barbon published results (which need 2016–2023ish data this
environment cannot supply) and it is **not** the 2018–2022 /
2023–2024 / 2025–2026 chronological validation `STRATEGY_SPEC.md` §13
calls for. Treat everything below as an infrastructure smoke test: does
the engine compute the right thing, end to end, on real ticks? Not: does
this strategy have an edge?

## Data window

| | |
|---|---|
| Source | Robinhood MCP `get_equity_historicals`, `interval=minute`, `bounds=regular` |
| Range | 2026-07-16 09:30 ET → 2026-08-25 15:59 ET |
| Sessions | 29, all complete (390 bars each), zero missing/interpolated/zero-volume bars |
| Warm-up consumed | first 14 sessions (2026-07-16 → 2026-08-04), per §2 of `STRATEGY_SPEC.md` |
| Eligible sessions | 15 (2026-08-05 → 2026-08-25) |
| Eligible checkpoints | 15 × 12 = 180 |

## Sanity/implementation checks (this is what the sample size *can* support)

- **Leakage check**: `n_lookback_sessions` is 0..13 for the first 14
  sessions (correctly ineligible) and exactly 14 for every session from
  2026-08-05 onward — confirmed directly from `reports/trades/underlying_decisions.csv`,
  not just asserted. No session ever used same-day or future data in its
  own sigma.
- **Sigma / Noise Area magnitude**: mean sigma across the 180 eligible
  checkpoints = **0.39%**, giving an average Noise Area half-width of
  ~0.54% of spot — consistent with a low-realized-volatility summer
  regime, not a data or formula bug (cross-checked by hand against the
  `move[d,t]` definition for several checkpoints).
- **Checkpoint discipline**: exactly 12 decision rows per eligible session,
  timestamps land exactly on `10:00, 10:30, ..., 15:30` NY time — confirmed
  from the decisions CSV.

## Trades

Only **2 trades** fired in the 180 eligible opportunities (1.1% signal
rate). Full detail:

| # | Side | Entry (ET) | Entry px | Exit (ET) | Exit px | Exit reason | Return |
|---|---|---|---|---|---|---|---|
| 1 | Long | 2026-08-13 10:00 | 777.97 | 2026-08-13 11:30 | 776.15 | signal_exit | −0.234% |
| 2 | Short | 2026-08-24 10:30 | 763.03 | 2026-08-24 11:00 | 763.45 | signal_exit | −0.055% |

Both trades lost money; both exited via the normal trail-break signal
exit (not a forced close, not a reversal). Charts:
`reports/figures/trade_detail_2026-08-13.png`,
`reports/figures/trade_detail_2026-08-24.png` (price, VWAP, and both bands
plotted through the session with entry/exit marked).

## Aggregate stats (n=2 — read as a data point, not a statistic)

```
win_rate:          0.0%
profit_factor:     0.0   (no winners at all in this sample)
expectancy/trade:  -0.144%
avg_loss:          -0.144%
gross P&L:         -0.289%
long trades:        1
short trades:        1
avg holding time:   60 minutes
```

**These numbers are not evidence of anything about the strategy's edge.**
Two trades cannot distinguish skill from noise at any reasonable
confidence level; the bootstrap expectancy CI computed by
`spy_options.metrics.bootstrap_ci` correctly returns `NaN` bounds for
`n<5`, by design, rather than printing a falsely-precise interval.

## Metrics NOT computed, and why (rather than fabricated)

| Metric | Why not computed |
|---|---|
| Annualized return / vol / Sharpe / Sortino / max drawdown | Needs a real multi-month-plus equity curve; 6 weeks of data with 2 trades cannot support this |
| Calendar-year breakdown (2024/2025/2026 explicitly requested) | Only a 6-week slice of one partial year is available at all; see `DATA_AUDIT.md` for why 2024/2025 are unreachable in this environment |
| Rolling 6-month / 12-month performance | Window is 6 weeks total |
| VIX-regime breakdown | Not pulled — would not be informative at n=2 |
| Trades-per-year, exposure % | Would be a meaningless extrapolation from 2 trades over 29 sessions |

## Long vs. short

1 long, 1 short, both losers — no directional conclusion is possible or
claimed from this.

## Conclusion for this report

**UNDERLYING REPLICATION: FAIL — not because the code produced a wrong
number, but because no data source reachable in this environment can
support the actual replication `STRATEGY_SPEC.md` calls for.** The 78/78
passing unit test suite (deterministic, synthetic fixtures) is the real
evidence that the mechanics are correct; this report is the evidence that
the mechanics also run correctly against real ticks end-to-end. Neither is
evidence of a trading edge, and this report does not claim to be.
