# OPTION_BACKTEST_REPORT.md

## Status: **BLOCKED BY DATA**

Per `STRATEGY_SPEC.md` §4 and the task's own explicit instruction: *"If
actual historical option quotes are unavailable, complete the underlying
strategy and infrastructure but clearly mark the options profitability
test as BLOCKED BY DATA rather than manufacturing a result."* That is
exactly what happened. No historical SPY option bid/ask quote — for any
date, any expiration, any strike — was reachable in this execution
environment. See `DATA_AUDIT.md` §4 for the full verification (what was
checked, and how it was determined to be unreachable rather than assumed).

**No option P&L number — gross or net, optimistic/realistic/conservative,
for any of the 4 frozen policies — appears anywhere in this repository.**
Every number that could plausibly look like one (a Black-Scholes price, a
synthetic quote, an approximation from the SPY move) was deliberately not
computed and not substituted, per the explicit prohibition in the task:
*"Do not approximate historical option returns using SPY percentage
changes or Black-Scholes... Do not silently substitute fabricated option
prices."*

## What was actually built and verified (infrastructure, not results)

| Component | File | Verified by |
|---|---|---|
| Frozen contract-selection policy (nearest DTE, closest \|Δ\|, spread tie-break) | `spy_options/options/contracts.py` | 9 unit tests: delta-closest selection, spread tie-break, expiration preference with liquidity fallback, zero-bid/crossed/stale/wide-spread rejection, wrong-type filtering |
| Liquidity filters (zero bid, crossed, stale, 5%-of-mid spread) | `spy_options/options/contracts.py::passes_liquidity_filters` | same 9 tests |
| Black-Scholes delta/price fallback | `spy_options/options/bs_pricing.py` | 6 unit tests: put-call parity, delta bounds/monotonicity, IV round-trip |
| Three fill models (optimistic/realistic/conservative) + commissions | `spy_options/options/fill_model.py` | 6 unit tests, including the ordering `optimistic > realistic > conservative` P&L for a buyer |
| Position sizing (0.50% of equity in premium) + commission scaling | `spy_options/risk.py` | 3 unit tests |
| Daily loss circuit breaker (1.5%, gates entries only) | `spy_options/risk.py` | 3 unit tests, incl. a structural test that it exposes no signal-generating method |
| Orchestrator: underlying trades → option trades, BLOCKED on missing data | `spy_options/options/option_backtest.py` | 4 unit tests using a deterministic in-memory replay provider (proves the pipeline is correct when data IS available) + confirmed BLOCKED against the real 2-trade sample (`scripts/run_option_backtest_demo.py`) |

`scripts/run_option_backtest_demo.py` ran all **4 frozen policies × 3 fill
models = 12 combinations** against the 2 real underlying trades found in
`BACKTEST_REPORT.md`. All 12 returned:

```json
{
  "policy_name": "1DTE_delta055_PRIMARY",
  "fill_model": "optimistic",
  "reason": "no_institutional_options_data_provider_reachable",
  "n_underlying_trades_attempted": 0
}
```
(and identically for `0DTE_delta055`, `1DTE_delta065`, `2DTE_delta055` ×
`realistic`, `conservative` — full output in
`reports/trades/option_backtest_blocked_results.json`).

## The frozen policies (unchanged from STRATEGY_SPEC.md §9, for reference)

1. **1DTE, |Δ|≈0.55 (primary)**
2. 0DTE, |Δ|≈0.55
3. 1DTE, |Δ|≈0.65
4. 2DTE, |Δ|≈0.55

No fifth policy was added after seeing the (blocked) results — there were
no results to react to.

## Liquidity filter, frozen before any option backtest ran

5% of midpoint, per `STRATEGY_SPEC.md` §10. This was fixed at spec-freeze
time (before implementation) rather than derived from measuring a real
spread distribution, because no real SPY option quote history was
reachable to measure a distribution *from*. This is a documented
deviation from the ideal process ("measure the distribution first") forced
by data availability, not a shortcut taken for convenience — if/when a
real quote feed is wired in, the spread distribution should be measured
and this filter's appropriateness re-examined *before* re-running the
backtest, and logged as a new `RESEARCH_LEDGER.md` entry either way.

## What it would take to unblock this

A real historical options-quote provider (Polygon, ThetaData, ORATS, Cboe
DataShop, or equivalent) reachable from this environment, per
`DATA_AUDIT.md` §7. `HistoricalOptionQuoteProvider` in
`spy_options/options/data_provider.py` is the integration point — a
concrete subclass implementing `get_quote_chain(underlying, as_of,
expiration)` against a real feed, and `run_option_backtest` will produce
real per-policy, per-fill-model results the moment that subclass is wired
in and used in place of `NullHistoricalOptionProvider`. No other code in
this repository needs to change.

## Advancement criteria (STRATEGY_SPEC.md §14)

Not evaluated. Cannot be evaluated. There is no options P&L to check
against `profit factor ≥ 1.20`, `Sharpe ≥ 1.0`, etc. — those criteria
require the option backtest to have produced real numbers first.
