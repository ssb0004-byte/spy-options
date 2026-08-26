# spy-options

SPY Noise-Area intraday momentum strategy (Zarattini/Aziz/Barbon,
SSRN 4824172): signal engine, underlying backtest, options execution
layer, and a paper-trading scaffold — built, tested, and independently
audited per the frozen rules in `STRATEGY_SPEC.md`.

**Start with `DATA_AUDIT.md`.** The short version: this execution
environment has no reachable source of real multi-year SPY history or any
historical options quotes (verified, not assumed — see that document).
Historical validation and the options backtest are therefore reported as
**BLOCKED BY DATA**, not as a pass or a fail of the strategy itself. The
code, however, is complete and passes its full test suite against
deterministic synthetic fixtures, plus a smoke test against 29 sessions of
real (if recent and short) SPY data pulled from this environment's one
live connector.

## Documents

| File | What it is |
|---|---|
| `STRATEGY_SPEC.md` | The frozen rule set, committed before any code or backtest result |
| `DATA_AUDIT.md` | **Read this first.** What data was and wasn't reachable, verified empirically |
| `RESEARCH_LEDGER.md` | Every variant tested, in order, with results — anti-overfitting protocol |
| `BACKTEST_REPORT.md` | Underlying signal-engine results on the real data available (smoke test, n=2 trades) |
| `OPTION_BACKTEST_REPORT.md` | BLOCKED BY DATA — what was built and verified vs. what couldn't be run |
| `RECENT_REGIME_REPORT.md` | Direct answer to the "late-2025 deterioration" premise: unverifiable here |
| `PAPER_TRADING.md` | What the paper-trading engine does, why it's not wired to a live feed, and why it's not recommended for use yet |

## Code layout

```
spy_options/
  signal_engine.py     Noise Area, VWAP, checkpoints, entries/exits/reversal (the one place the rules live)
  timeutil.py           NYSE calendar, DST-safe tz handling, half-day-aware checkpoints
  risk.py                Position sizing, commissions, daily loss circuit breaker
  metrics.py              Sharpe/Sortino/drawdown/profit factor/bootstrap CI
  config.py                Frozen policy constants + the live-trading guard
  options/
    contracts.py            Frozen contract-selection policy + liquidity filters
    bs_pricing.py             Black-Scholes fallback delta (documented assumptions)
    fill_model.py              Optimistic/realistic/conservative fills + commissions
    data_provider.py            Historical/live quote interfaces — Null* raises rather than fabricates
    option_backtest.py           Underlying trades -> option trades, or BlockedResult
  paper/
    journal.py                    Immutable append-only decision/fill log
    broker.py                      PaperBrokerAdapter (simulated only) + LiveBrokerAdapter (always refuses)
    engine.py                       Checkpoint-driven live engine, reuses signal_engine.run_signal_engine directly
    providers.py                     Streaming interfaces + deterministic replay double
tests/                                   78 deterministic tests, synthetic fixtures only
scripts/
  fetch_sandbox_data.py                   How data_raw/*.parquet was assembled
  run_underlying_backtest.py               Produces BACKTEST_REPORT.md's numbers/figures
  run_option_backtest_demo.py               Produces OPTION_BACKTEST_REPORT.md's BLOCKED confirmation
data_raw/                                   The one real dataset available: 29 sessions, 2026-07-16..08-25
reports/
  trades/                                    CSV/JSON outputs consumed by the reports above
  figures/                                    Equity curve + per-trade price/band/VWAP charts
```

## Running it

```
python3.12 -m venv .venv && . .venv/bin/activate
pip install -e . -r requirements.txt
pytest tests/ -q                              # 78 passed
python scripts/run_underlying_backtest.py     # writes reports/trades/*, reports/figures/*
python scripts/run_option_backtest_demo.py    # confirms BLOCKED BY DATA, writes the JSON record
```
