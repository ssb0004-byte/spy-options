# STRATEGY_SPEC.md — Frozen Baseline Rules

**Status: FROZEN before any backtest was run or any result was viewed.**
This file is committed first, prior to touching implementation code, per the
anti-overfitting protocol in `RESEARCH_LEDGER.md`. Any change to a rule below
after results have been observed must be logged as a *new hypothesis* in the
research ledger, not a silent edit to this spec, and must not reuse the
2025–2026 window as "out-of-sample" again.

Source: Zarattini, Aziz & Barbon, *"Beat the Market: An Effective Intraday
Momentum Strategy for S&P500 ETF (SPY)"*, SSRN 4824172 ("the paper").

## 1. Universe & data

- Instrument for signal generation: **SPY** underlying only.
- Bar size: **1-minute**, regular trading hours only, `09:30:00–16:00:00
  America/New_York`.
- Premarket and after-hours bars are discarded entirely, not merged in.
- Session date is defined in `America/New_York` local time (handles DST
  transitions automatically via IANA tz database, not fixed UTC offsets).

## 2. Noise Area (sigma)

For every minute `t` of a session, and for the **previous 14 completed
trading sessions only** (current session strictly excluded — no leakage):

```
move[d, t]  = abs( SPY_close[d, t] / SPY_open[d] - 1 )
sigma[t]    = mean( move[d, t] for d in previous 14 sessions )
```

`SPY_open[d]` is the official regular-session opening print of day `d`
(the `open_price` of the `09:30` bar). `SPY_close[d, t]` is the close of the
1-minute bar at clock time `t` on day `d`.

A session only contributes to `sigma[t]` if it has a valid bar at minute `t`.
The first 14 sessions of any dataset have **no valid sigma** and must be
excluded from signal evaluation (warm-up period, not zero-filled).

## 3. Noise Area bands

```
upper[t] = max(today_open, previous_session_close) * (1 + sigma[t])
lower[t] = min(today_open, previous_session_close) * (1 - sigma[t])
```

`today_open` = today's `09:30` open print. `previous_session_close` = prior
session's official close (last regular-session bar, not an after-hours
print). This anchors gap-ups and gap-downs correctly: a gap up uses
`today_open` as the higher of the two anchors for `upper` and
`previous_session_close` as the lower anchor for `lower` (and vice versa for
gap downs) — see unit tests `test_gap_up_anchoring`, `test_gap_down_anchoring`.

## 4. VWAP

Session VWAP, reset every session, computed on typical price:

```
typical_price[t] = (high[t] + low[t] + close[t]) / 3
VWAP[t] = cumsum(typical_price * volume)[0..t] / cumsum(volume)[0..t]
```

## 5. Checkpoints

Signals are evaluated **only** at the completed 1-minute bar whose clock time
equals one of:

```
10:00 10:30 11:00 11:30 12:00 12:30 13:00 13:30
14:00 14:30 15:00 15:30
```

All other minutes are ignored for signal purposes (though they still feed
VWAP and, going forward, the next day's sigma calculation). Using the
*completed* bar for time `t` means no information from bar `t+1` onward is
used to decide the trade at checkpoint `t` (no look-ahead).

## 6. Entry rules

At a valid checkpoint, with a position already flat (or being replaced, see
§8 Reversal):

- **Bullish**: `close[t] > upper[t]` **and** `close[t] > VWAP[t]`. → go long.
- **Bearish**: `close[t] < lower[t]` **and** `close[t] < VWAP[t]`. → go short.
- Otherwise: remain flat, or hold the existing position unchanged.

Both the band breakout and the VWAP confirmation are required simultaneously;
neither condition alone is a signal.

## 7. Exit rules

- **Long position**: `long_trail[t] = max(VWAP[t], upper[t])`. Exit when
  `close[t] < long_trail[t]` at a valid checkpoint.
- **Short position**: `short_trail[t] = min(VWAP[t], lower[t])`. Exit when
  `close[t] > short_trail[t]` at a valid checkpoint.
- **Reversal**: if, while a position is open, the *opposite* signal
  qualifies at a checkpoint, the existing position is closed. The opposite
  entry is recorded separately as a "potential reversal" candidate — the
  canonical strategy does **not** auto-flip into the new position; whether
  immediate flipping helps or hurts is a measured, separate variant
  (`allow_immediate_reversal` flag), never silently merged into the baseline.
- **Forced close, underlying backtest**: any open position is closed at the
  last regular-session bar (16:00 print) if no other exit fired first.
- **Forced close, options implementation**: liquidate by **15:55 ET**
  (last valid checkpoint effectively becomes the 15:30 one for entries;
  15:55 is a hard flatten, not a signal-driven exit, and is evaluated off
  the underlying's 15:55 bar, not the option's own price).

## 8. Position management

- Maximum **one** concurrent directional position (long OR short), never
  both.
- No pyramiding, no averaging down/up.
- No overnight holding under any circumstance.
- No naked short option writing anywhere in this system — every options
  trade is a long call or a long put, sized as a debit.

## 9. Options execution — frozen contract-selection family

The **primary** policy, tested first and reported as the headline number:

- **1DTE, |delta| ≈ 0.55.** Bullish signal → buy call. Bearish signal → buy
  put. Expiration nearest to 1 trading day remaining; among contracts of
  that expiration, the one whose absolute delta is closest to 0.55; ties
  broken by tightest bid/ask spread; reject inadequate liquidity (§10).

Three predetermined comparators, tested identically, no others added after
seeing results:

- **0DTE, |delta| ≈ 0.55**
- **1DTE, |delta| ≈ 0.65**
- **2DTE, |delta| ≈ 0.55**

If listed Greeks are unavailable from the data source, delta is derived with
Black-Scholes (European approximation, acceptable for short-dated liquid SPY
options) using: risk-free rate = 3-month T-bill proxy held constant per
research run and documented in `DATA_AUDIT.md`; realized/implied volatility
input taken only from data available *as of* the decision timestamp (never a
forward-looking or full-sample-fit IV); dividend yield = trailing SPY yield
constant. Every assumption is logged in `DATA_AUDIT.md` alongside each run.

## 10. Liquidity filters (frozen before the out-of-sample test)

- Reject a contract with a zero bid.
- Reject a stale quote (quote timestamp older than a configured staleness
  threshold relative to the decision timestamp — default 5 seconds for
  live/paper, "same minute bar" for historical).
- Reject a crossed quote (`bid > ask`).
- Frozen initial spread filter: reject if `(ask - bid) / midpoint > 5%`.
  This threshold is a documented initial candidate, chosen from measuring
  the spread distribution first (see `DATA_AUDIT.md` / `OPTION_BACKTEST_REPORT.md`),
  and is **not** to be adjusted post hoc to improve results.

## 11. Fill models (all three required; no midpoint-only result advances)

- **Optimistic**: fill at midpoint.
- **Realistic**: fill at midpoint + 25% of the quoted half-spread, adverse
  to the trader, applied on both entry and exit.
- **Conservative**: fill at midpoint + 50% of the quoted half-spread,
  adverse to the trader, applied on both entry and exit.
- Commissions and regulatory fees are added on top of all three models.
- The strategy must remain viable (see Advancement Criteria) under the
  **realistic** model to advance; the conservative case is always reported
  alongside it, never suppressed.

## 12. Risk management

- Long premium only. Never sell naked options.
- Position sizing: **max premium deployed per new trade = 0.50% of current
  account equity.** Full premium is treated as capital at risk (no partial
  credit for theoretical recovery value).
- No margin used to scale this allocation up.
- Max concurrent directional position: one. No pyramiding. No averaging down.
- Optional daily loss circuit breaker: 1.5% of account equity intraday
  realized+open loss halts *new entries* for the remainder of that session.
  It never manufactures an entry signal; it only suppresses one. Results are
  reported both with and without the breaker.

## 13. Chronological validation split

- **2018–2022**: implementation verification / historical development.
- **2023–2024**: frozen validation and predetermined contract-policy
  comparison.
- **January 2025 – latest available 2026 data**: untouched out-of-sample
  test. No parameter or rule changes may be made after viewing this window's
  results; any post-hoc idea is logged as a new hypothesis for a *future*,
  not-yet-elapsed, out-of-sample period.

(See `DATA_AUDIT.md` for what portion of this split is actually backed by
real historical data in this environment — the split above is the intended
research design, not a claim that all of it was executed on genuine data.)

## 14. Advancement criteria (minimum evidence, not optimization targets)

The system may proceed from historical research to paper trading only if
the untouched 2025–2026 out-of-sample slice shows, under the **realistic**
fill model, net of commissions:

- positive net expectancy per trade,
- profit factor ≥ 1.20,
- Sharpe ≥ 1.0 (or clearly compelling statistical evidence at a somewhat
  lower value, argued explicitly, not asserted),
- acceptable max drawdown relative to return,
- a sample size large enough to be statistically meaningful,
- positive performance after realistic spread/slippage/commission costs,
- and no evidence that virtually all profit is concentrated in a handful of
  anomalous trades (checked via trimmed-mean / leave-top-N-out sensitivity).

Failure to meet these is a valid, reportable research outcome:
**FAIL — NO CURRENTLY VALIDATED EDGE.** This spec does not permit relaxing
any of the above after the fact to manufacture a PASS.

## 15. Explicitly excluded from the canonical strategy

RSI, MACD, stochastics, ML classifiers, candlestick pattern classifiers, and
discretionary support/resistance are not part of this strategy and must not
be added to the canonical signal engine. Any such idea is only permissible
in a separate, clearly labeled experimental branch created *after* the
canonical strategy above is frozen and independently tested — and is out of
scope for this deliverable.
