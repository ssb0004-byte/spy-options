# DATA_AUDIT.md

This is the single most important document in this repository. It records,
precisely, what data was and was not available to validate the strategy in
this execution environment, so the results in `BACKTEST_REPORT.md`,
`OPTION_BACKTEST_REPORT.md`, and `RECENT_REGIME_REPORT.md` are read with
the right amount of confidence — which, for the headline multi-year and
options questions, is **very little**, and this document says so directly
rather than letting a green test suite imply otherwise.

## 1. Environment connectivity, checked directly

- General internet egress goes through a policy-enforcing proxy. Verified
  by direct probe: `query1.finance.yahoo.com`, `api.polygon.io`, and
  `www.google.com` all return **403 policy denial** on CONNECT. The proxy's
  own allowlist (`/root/.ccr/__agentproxy/status`) permits only
  `api.anthropic.com`, `registry.npmjs.org`, `pypi.org`,
  `files.pythonhosted.org`, `proxy.golang.org`, `index.crates.io`, GitHub
  API/MCP hosts, and a few cloud-internal ranges. **No market-data or
  options-data vendor host is reachable** from Python/curl in this session.
- Environment variables were inspected for API keys: no `POLYGON_*`,
  `THETADATA_*`, `ORATS_*`, `CBOE_*`, `ALPACA_*`, `IEX_*`, `TIINGO_*`, or
  similar credential is present. No institutional options-data provider is
  configured, full stop.
- The one live data source reachable in this session is the **Robinhood
  MCP connector**, callable only through the orchestrating agent's
  interactive tool-calling boundary — not from unattended Python code
  running inside this package. See §4 and `PAPER_TRADING.md` for what that
  means for autonomous paper trading.

## 2. The Robinhood connector's historical data is NOT a real multi-year
   history — verified empirically, not assumed

`get_equity_historicals(SPY, interval=minute)` was probed at several
historical dates before writing any backtest code:

| Requested date | Result |
|---|---|
| 2019-03-04 | Flat line at **766.13**, `volume=0`, `interpolated=true` for every bar |
| 2024-01-03 | Flat line at **766.20**, `volume=0`, `interpolated=true` |
| 2025-01-03 | Flat line at **766.20**, `volume=0`, `interpolated=true` |
| 2025-06-02 | Flat line at **766.21**, `volume=0`, `interpolated=true` |
| 2026-06-01 / 2026-07-01 / 2026-07-06 / 2026-07-13 | Flat line at **~766.15**, `volume=0`, `interpolated=true` |
| 2026-07-16 onward | **Real, varying OHLCV bars, `interpolated` absent, volume > 0** |
| 2026-08-25 (yesterday, last complete session at fetch time) | Real bars, high intraday variation |

The identical placeholder price (~$766, i.e. approximately *today's* price)
returned for 2019, 2024, and every 2025 date probed is conclusive: this is
not real historical SPY data being served for those dates — real SPY never
traded at ~$766 in 2019 (it was ~$280) or in the same conversation, 2019
and 2025 cannot share a literal identical closing print. The API is
returning a flat, zero-volume, explicitly `interpolated=true` gap-fill for
any date it has no genuine intraday history for. **This environment's
Robinhood connector is a sandboxed/simulated brokerage feed whose real
intraday history only goes back to approximately 2026-07-16** — about six
weeks before this session — everything earlier is a synthetic placeholder,
not a data-quality bug to route around.

This was checked by binary search across 2019, 2024, 2025, and June/July
2026 before any assumption was made, and the boundary was narrowed to the
week of 2026-07-13 (still flat/interpolated) vs. 2026-07-16 (real,
non-interpolated, `volume=132214` on the first bar).

**Consequence:** the chronological validation design in
`STRATEGY_SPEC.md` §13 (2018–2022 development, 2023–2024 frozen
validation, 2025–2026 out-of-sample) **cannot be executed in this
environment.** There is no 2018–2025 SPY minute history reachable here,
real or otherwise. Any 2018–2025 "backtest result" in a report produced by
this codebase would necessarily be fabricated, which the task explicitly
forbids doing silently — so it was not done.

## 3. What real data *is* available, and what was pulled

29 consecutive real trading sessions, **2026-07-16 through 2026-08-25**
(the last complete session at the time of the pull), 1-minute RTH bars,
`bounds=regular`, split-adjusted. Pulled in 7 chunks (~2500-bar cap per
call) via `get_equity_historicals`, saved verbatim to
`data_raw/spy_1min_rh_sandbox_2026-07-16_2026-08-25.{parquet,csv}` — see
`scripts/fetch_sandbox_data.py` for the exact reassembly code and
`scripts/run_underlying_backtest.py` for what consumed it.

- 390 bars every session, zero missing bars, zero interpolated bars, zero
  zero-volume bars in this window — a clean, complete intraday sample.
- 14 sessions consumed as the mandatory sigma warm-up (`STRATEGY_SPEC.md`
  §2); **15 sessions × 12 checkpoints = 180 signal-evaluation
  opportunities** were actually eligible.
- Realized sigma in this window: mean 0.39%, so Noise Area half-width
  averaged ~0.54% of spot — a calm, tight-range regime. Only **2 of 180**
  checkpoint opportunities produced a qualifying signal.

This is a real, non-fabricated, but extremely small sample. It is used in
`BACKTEST_REPORT.md` strictly as an **infrastructure / smoke-test
validation** of the signal engine end-to-end — never as a stand-in for the
multi-year replication or the 2025–2026 out-of-sample test the task calls
for, and every report says so explicitly rather than letting the numbers
speak without that context.

## 4. Options data — checked, not assumed unavailable

- `get_option_chains(SPY)` returns only **currently listed** expirations
  (2026-08-26 onward at fetch time) — there is no way to ask it for the
  chain as it stood on, say, 2024-03-15.
- `get_option_historicals` takes **instrument UUIDs for currently listed
  contracts** and returns OHLC bars (not a full historical bid/ask NBBO
  time series) — it cannot serve a contract that has since expired, which
  is what a multi-year backtest needs for nearly every trading day.
- No institutional options-data API key is configured (§1).

**Conclusion: no source of real, timestamped, two-sided historical SPY
option quotes is reachable in this environment**, for any date, let alone
across 2018–2026. `spy_options/options/data_provider.py` implements
`NullHistoricalOptionProvider`, which raises `DataUnavailableError` rather
than ever returning a plausible-looking synthetic quote, and
`option_backtest.run_option_backtest` returns a `BlockedResult` the moment
that happens instead of silently producing a partial or fabricated result.
`scripts/run_option_backtest_demo.py` runs all 4 frozen policies × 3 fill
models against the real underlying trades found in §3 and confirms all 12
combinations come back `BlockedResult(reason="no_institutional_options_data_provider_reachable")`.
See `OPTION_BACKTEST_REPORT.md`.

## 5. Black-Scholes fallback assumptions (documented per STRATEGY_SPEC.md §9)

`spy_options/options/bs_pricing.py` was built and unit-tested (put-call
parity, delta monotonicity/bounds, IV round-trip) but **was not invoked
against any real quote in this run**, because no real quote reached it —
there is nothing to compute a fallback delta *for*. If it is ever used
against real data, every run must log: the risk-free rate source and
value, the dividend-yield source and value, and the volatility input's
timestamp (must be as-of the decision time, never a forward or full-sample
fit) alongside the resulting delta, per the assumptions already documented
in that module's docstring.

## 6. VIX

VIX data was not pulled for this run. With `n_trades=2` in the only real
window available, a VIX-regime breakdown would not be informative — it was
skipped rather than computed and presented as if it meant something.

## 7. What would remove these blockers

- A licensed historical options-quote feed (Polygon, ThetaData, ORATS,
  Cboe DataShop, or equivalent) with an API key placed in the environment
  and that host allow-listed on the egress proxy, for `OPTION_BACKTEST_REPORT.md`.
- A source of genuine 2018–2025 SPY 1-minute bars (the same vendors above,
  or a market-data vendor like IEX/Tiingo/Polygon's stocks product) for the
  chronological validation `STRATEGY_SPEC.md` §13 actually calls for.
- Until then, this repository's honest status is: infrastructure complete
  and tested, historical validation and options validation **BLOCKED BY
  DATA** in this specific execution environment — not a strategy that
  failed evidence, and not one that passed it either.
