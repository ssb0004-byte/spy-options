# PAPER_TRADING.md

## Status: infrastructure built and unit-tested; **not activated as a
recommendation**, because the Phase-5 advancement criteria were never met

`STRATEGY_SPEC.md` §14 and the task instructions are explicit: paper
trading is a downstream step gated on the untouched out-of-sample period
passing a minimum evidence bar. Per `RECENT_REGIME_REPORT.md` and
`OPTION_BACKTEST_REPORT.md`, that gate was never reached — not because the
strategy failed it, but because no data source in this environment could
run the test at all. Building the paper-trading engine anyway (rather than
stopping at "blocked") was a deliberate choice to deliver the
infrastructure and its required test coverage per the task's Tests
section; it is not a signal that paper trading is recommended right now.
**Recommendation: do not run this against a live account or even live
paper capital until `OPTION_BACKTEST_REPORT.md` and `RECENT_REGIME_REPORT.md`
can be re-run with a real data feed and pass the Phase-5 criteria.**

## What exists

| Component | File |
|---|---|
| Immutable append-only decision/fill journal | `spy_options/paper/journal.py` |
| Simulated broker: fills, duplicate-order prevention, stale-quote rejection, kill switch, max-one-position | `spy_options/paper/broker.py` (`PaperBrokerAdapter`) |
| Live-trading refusal stub | `spy_options/paper/broker.py` (`LiveBrokerAdapter`) — every call raises unconditionally |
| Hard configuration guard | `spy_options/config.py` (`LIVE_TRADING_GUARD`, requires both `LIVE_TRADING_ENABLED=true` **and** an exact confirmation phrase; defaults fully off) |
| Checkpoint-driven engine reusing the exact tested signal engine | `spy_options/paper/engine.py` (`PaperTradingEngine`) |
| Market-data / option-chain streaming interfaces + deterministic replay doubles | `spy_options/paper/providers.py`, `spy_options/options/data_provider.py` |

25 dedicated unit tests (of the suite's 78 total) cover: journaling and its append-only surface,
buy→sell fill and realized P&L, duplicate idempotency-key rejection, stale
quote rejection, kill-switch engage/reset, max-one-concurrent-position,
restart/recovery from the journal alone (mid-position and fully flat),
live-adapter unconditional refusal, the config guard's four
flag/confirm-phrase combinations, and full engine-level integration
(enter→exit cycle, 15:55 forced flatten, restart-without-duplicate-entry,
kill-switch-blocks-all-checkpoints, circuit-breaker-blocks-entries,
graceful handling of an unavailable live chain). All pass — see the full
suite result in the final status.

## Why the engine re-runs the signal engine instead of re-implementing it

`PaperTradingEngine.on_bar` appends each new bar and, at every checkpoint
(and at 15:55), re-runs the identical `spy_options.signal_engine.run_signal_engine`
used by the backtest over the accumulated buffer, and acts only on the
decision for *that* timestamp. This means the paper engine can never drift
from the frozen, tested backtest logic — there is exactly one
implementation of the strategy rules in this repository, not two that
could silently diverge.

## What is genuinely unwired, and why

Two abstract interfaces — `LiveOptionChainProvider` (live option chain)
and `MarketDataProvider` (live 1-minute bars) — have only `Unwired*`
stub implementations that raise `DataUnavailableError`/`RuntimeError`
explaining why. This is not an oversight: **this sandboxed session can
reach live SPY market and option data only through the Robinhood MCP tool
boundary, which is only callable by the orchestrating agent interactively
turn-by-turn, not by unattended Python code running continuously inside
this package.** A real deployment (a machine or container running this
package with its own authenticated, network-connected broker/data client —
Robinhood's own API, or another broker's) supplies concrete subclasses of
those two interfaces; `PaperTradingEngine` and `PaperBrokerAdapter` do not
need to change.

## The live-trading guard, concretely

Two independent layers, both required to fail closed:

1. `spy_options.config.LiveTradingGuard` — a frozen dataclass, `enabled`
   defaults to `False`. `LiveTradingGuard.from_environment()` only
   returns `enabled=True` if **both** `LIVE_TRADING_ENABLED=true` **and**
   `LIVE_TRADING_CONFIRM=I_UNDERSTAND_THIS_SENDS_REAL_ORDERS` are set —
   the flag alone is not enough, and the wrong confirmation string is
   silently treated as `False` (never a crash that could be caught and
   ignored).
2. `spy_options.paper.broker.LiveBrokerAdapter` — the only class in this
   codebase that even shapes a "live order" call — **does not consult the
   guard at all**. It refuses unconditionally, every time. There is no
   code path anywhere in this repository that sends an order to a real
   brokerage endpoint. Enabling that is explicitly out of scope for this
   deliverable and would require a deliberate future implementation, not a
   configuration flip.

## Required journal fields (STRATEGY_SPEC.md Phase 6)

Every checkpoint decision and every order event already records: the
signal engine's own decision row (close, VWAP, upper, lower, sigma,
today_open, prev_close, n_lookback_sessions, action, potential_reversal),
and every order event records the idempotency key, side, timestamp,
selected contract (strike/expiration/type/delta), bid/ask, fill price,
commission, realized P&L (on exits), and rejection reason for anything
that did NOT trade (candidate rejected, entry skipped, kill switch,
circuit breaker). `spy_options.STRATEGY_VERSION` is stamped on every single
record by `Journal.record`.

## Next steps to actually run this live-paper

1. Implement a concrete `LiveOptionChainProvider` and `MarketDataProvider`
   against a real, network-connected, authenticated feed (see
   `DATA_AUDIT.md` §7 for the same feed that would unblock the historical
   options backtest — a single good vendor relationship unblocks both).
2. Re-run `BACKTEST_REPORT.md`/`OPTION_BACKTEST_REPORT.md`/`RECENT_REGIME_REPORT.md`
   against real multi-year history and confirm the Phase-5 advancement
   criteria in `STRATEGY_SPEC.md` §14 are actually met.
3. Only then wire the two providers into a deployment, run
   `PaperTradingEngine` against simulated (never live-money) fills for an
   extended dry run, and review the journal before ever considering
   flipping the live guard — which, per the design above, additionally
   requires writing and reviewing a real `LiveBrokerAdapter` implementation
   that does not exist today.
