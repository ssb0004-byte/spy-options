import datetime as dt

import pandas as pd

from spy_options.options.contracts import ContractQuote
from spy_options.options.data_provider import InMemoryReplayOptionProvider, NullHistoricalOptionProvider
from spy_options.options.option_backtest import BlockedResult, OptionTrade, run_option_backtest
from spy_options.signal_engine import Trade

POLICY = {"name": "1DTE_delta055_PRIMARY", "target_dte": 1, "target_abs_delta": 0.55}


def _underlying_trades():
    return [
        Trade(
            side="long", entry_time=pd.Timestamp("2026-08-20 10:00", tz="America/New_York"),
            entry_price=549.0, entry_checkpoint="10:00",
            exit_time=pd.Timestamp("2026-08-20 11:00", tz="America/New_York"),
            exit_price=551.0, exit_checkpoint="11:00", exit_reason="signal_exit",
            session_date=dt.date(2026, 8, 20),
        ),
        Trade(
            side="short", entry_time=pd.Timestamp("2026-08-20 13:00", tz="America/New_York"),
            entry_price=550.0, entry_checkpoint="13:00",
            exit_time=pd.Timestamp("2026-08-20 14:00", tz="America/New_York"),
            exit_price=548.0, exit_checkpoint="14:00", exit_reason="signal_exit",
            session_date=dt.date(2026, 8, 20),
        ),
    ]


def test_null_provider_returns_blocked_result_not_fabricated_numbers():
    result = run_option_backtest(
        _underlying_trades(), NullHistoricalOptionProvider(), policy=POLICY, fill_model="realistic"
    )
    assert isinstance(result, BlockedResult)
    assert result.reason == "no_institutional_options_data_provider_reachable"
    assert result.n_underlying_trades_attempted == 0


def _quote(expiration, option_type, strike, bid, ask, ts, delta=0.55):
    return ContractQuote(
        symbol="SPY", expiration=expiration, option_type=option_type, strike=strike,
        bid=bid, ask=ask, quote_time=ts, underlying_price=550.0, delta=delta,
    )


def test_replay_provider_produces_real_trades_with_expected_pnl_direction():
    exp = dt.date(2026, 8, 21)  # 1DTE from 2026-08-20
    t = _underlying_trades()

    # Spreads kept inside the frozen 5%-of-mid liquidity filter throughout.
    cache = {
        ("SPY", "2026-08-20T10:00"): [
            _quote(exp, "call", 549.0, 1.96, 2.04, t[0].entry_time),
        ],
        ("SPY", "2026-08-20T11:00"): [
            _quote(exp, "call", 549.0, 3.43, 3.57, t[0].exit_time),  # SPY rallied -> call worth more
        ],
        ("SPY", "2026-08-20T13:00"): [
            _quote(exp, "put", 550.0, 1.47, 1.53, t[1].entry_time),
        ],
        ("SPY", "2026-08-20T14:00"): [
            _quote(exp, "put", 550.0, 2.94, 3.06, t[1].exit_time),  # SPY fell -> put worth more
        ],
    }
    provider = InMemoryReplayOptionProvider(cache)
    result = run_option_backtest(t, provider, policy=POLICY, fill_model="optimistic", starting_equity=100_000)
    assert isinstance(result, list)
    assert len(result) == 2
    assert all(isinstance(ot, OptionTrade) for ot in result)
    assert result[0].option_type == "call"
    assert result[0].pnl > 0  # bought low, sold high, no adverse slippage at optimistic model
    assert result[1].option_type == "put"
    assert result[1].pnl > 0
    assert result[0].dte_at_entry == 1


def test_realistic_fill_model_produces_lower_pnl_than_optimistic():
    exp = dt.date(2026, 8, 21)
    t = _underlying_trades()[:1]
    cache = {
        ("SPY", "2026-08-20T10:00"): [_quote(exp, "call", 549.0, 1.96, 2.04, t[0].entry_time)],
        ("SPY", "2026-08-20T11:00"): [_quote(exp, "call", 549.0, 3.43, 3.57, t[0].exit_time)],
    }
    provider = InMemoryReplayOptionProvider(cache)
    opt = run_option_backtest(t, provider, policy=POLICY, fill_model="optimistic", starting_equity=100_000)
    real = run_option_backtest(t, provider, policy=POLICY, fill_model="realistic", starting_equity=100_000)
    cons = run_option_backtest(t, provider, policy=POLICY, fill_model="conservative", starting_equity=100_000)
    assert opt[0].pnl > real[0].pnl > cons[0].pnl


def test_missing_quote_at_exit_skips_trade_without_fabricating():
    exp = dt.date(2026, 8, 21)
    t = _underlying_trades()[:1]
    cache = {
        ("SPY", "2026-08-20T10:00"): [_quote(exp, "call", 549.0, 1.96, 2.04, t[0].entry_time)],
        # exit timestamp deliberately missing from cache
    }
    provider = InMemoryReplayOptionProvider(cache)
    result = run_option_backtest(t, provider, policy=POLICY, fill_model="realistic")
    assert isinstance(result, BlockedResult)
    assert result.reason == "no_cached_quote_for_timestamp"
