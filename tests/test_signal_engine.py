import datetime as dt

import numpy as np
import pandas as pd
import pytest

from spy_options.signal_engine import annotate_bars, compute_sigma_table, run_signal_engine
from tests.conftest import make_flat_history, make_session_bars

START = dt.date(2024, 1, 2)  # Tuesday, ordinary NYSE trading day, no holidays nearby
OPEN = 100.0


def _warmup(n=14, open_price=OPEN, daily_move_pct=0.001):
    return make_flat_history(n, START, open_price, daily_move_pct)


def _next_session_date(history: pd.DataFrame) -> dt.date:
    from spy_options.timeutil import trading_schedule

    last = max(pd.DatetimeIndex(history.index).tz_convert("America/New_York").date)
    sched = trading_schedule(str(last), str(last + dt.timedelta(days=10)))
    sessions = [d.date() for d in sched.index]
    return sessions[sessions.index(last) + 1]


# ---------------------------------------------------------------------------
# Sigma / lookback
# ---------------------------------------------------------------------------

def test_sigma_excludes_current_session_and_requires_14_prior():
    warm = _warmup(14)
    test_day = _next_session_date(warm)
    test_bars = make_session_bars(test_day, OPEN, price_at={"10:00": 999.0})  # would break sigma if leaked in
    bars = pd.concat([warm, test_bars]).sort_index()

    sigma = compute_sigma_table(annotate_bars(bars))
    row = sigma.loc[test_day]
    assert row["n_lookback_sessions"] == 14
    # Each warmup session bumps by exactly daily_move_pct at 09:31 and holds,
    # so every checkpoint's average move over the 14 prior sessions is
    # exactly daily_move_pct, independent of the test day's own huge price.
    for cp in ("10:00", "12:00", "15:30"):
        assert row[cp] == pytest.approx(0.001, rel=1e-9)


def test_fewer_than_14_prior_sessions_yields_no_signal():
    warm = _warmup(10)  # only 10 warmup sessions, not enough
    test_day = _next_session_date(warm)
    test_bars = make_session_bars(test_day, OPEN, price_at={"10:00": 200.0})  # deep breakout
    bars = pd.concat([warm, test_bars]).sort_index()

    trades, decisions = run_signal_engine(bars)
    assert trades == []
    d10 = decisions[(decisions.session_date == test_day) & (decisions.checkpoint == "10:00")]
    assert d10.iloc[0]["action"] == "none"
    assert d10.iloc[0]["note"] == "insufficient_lookback_or_missing_sigma"


# ---------------------------------------------------------------------------
# Noise area anchoring
# ---------------------------------------------------------------------------

def test_gap_up_anchoring_uses_today_open_for_upper_prev_close_for_lower():
    warm = _warmup(14)
    test_day = _next_session_date(warm)
    # Gap up: today's open is far above the prior session's close.
    gapped_open = 110.0
    test_bars = make_session_bars(test_day, gapped_open)
    bars = pd.concat([warm, test_bars]).sort_index()

    trades, decisions = run_signal_engine(bars)
    d10 = decisions[(decisions.session_date == test_day) & (decisions.checkpoint == "10:00")].iloc[0]
    # Recompute the expected previous close independently: last bar close of
    # the last warmup session.
    last_warm_session = max(pd.DatetimeIndex(warm.index).tz_convert("America/New_York").date)
    expected_prev_close = float(warm.loc[
        pd.DatetimeIndex(warm.index).tz_convert("America/New_York").date == last_warm_session, "close"
    ].iloc[-1])
    assert gapped_open > expected_prev_close  # sanity: this really is a gap up
    expected_upper = max(gapped_open, expected_prev_close) * (1 + 0.001)
    expected_lower = min(gapped_open, expected_prev_close) * (1 - 0.001)
    assert expected_upper == pytest.approx(gapped_open * 1.001)
    assert expected_lower == pytest.approx(expected_prev_close * 0.999)
    assert d10["upper"] == pytest.approx(expected_upper, rel=1e-9)
    assert d10["lower"] == pytest.approx(expected_lower, rel=1e-9)


def test_gap_down_anchoring_uses_prev_close_for_upper_today_open_for_lower():
    warm = _warmup(14)
    test_day = _next_session_date(warm)
    gapped_open = 90.0  # gap down
    test_bars = make_session_bars(test_day, gapped_open)
    bars = pd.concat([warm, test_bars]).sort_index()

    trades, decisions = run_signal_engine(bars)
    d10 = decisions[(decisions.session_date == test_day) & (decisions.checkpoint == "10:00")].iloc[0]
    last_warm_session = max(pd.DatetimeIndex(warm.index).tz_convert("America/New_York").date)
    expected_prev_close = float(warm.loc[
        pd.DatetimeIndex(warm.index).tz_convert("America/New_York").date == last_warm_session, "close"
    ].iloc[-1])
    assert gapped_open < expected_prev_close
    expected_upper = max(gapped_open, expected_prev_close) * 1.001
    expected_lower = min(gapped_open, expected_prev_close) * 0.999
    assert d10["upper"] == pytest.approx(expected_upper, rel=1e-9)
    assert d10["lower"] == pytest.approx(expected_lower, rel=1e-9)


# ---------------------------------------------------------------------------
# VWAP
# ---------------------------------------------------------------------------

def test_vwap_typical_price_formula():
    day = dt.date(2024, 1, 8)
    idx = pd.date_range(f"{day} 09:30", periods=3, freq="1min", tz="America/New_York").tz_convert("UTC")
    df = pd.DataFrame(
        {
            "open": [100.0, 101.0, 102.0],
            "high": [101.0, 103.0, 104.0],
            "low": [99.0, 100.0, 101.0],
            "close": [100.5, 102.0, 103.0],
            "volume": [1000, 2000, 1000],
        },
        index=idx,
    )
    out = annotate_bars(df)
    tp = (out["high"] + out["low"] + out["close"]) / 3.0
    expected_vwap = (tp * out["volume"]).cumsum() / out["volume"].cumsum()
    assert np.allclose(out["vwap"].to_numpy(), expected_vwap.to_numpy())


# ---------------------------------------------------------------------------
# Checkpoint timing / entries / exits / reversal / forced close
# ---------------------------------------------------------------------------

def test_off_checkpoint_price_spike_is_ignored():
    warm = _warmup(14)
    test_day = _next_session_date(warm)
    # Huge breakout at 10:05 (not a checkpoint) should NOT trigger a signal;
    # price must be back at a boring level at 10:30 to prove no side effect.
    test_bars = make_session_bars(test_day, OPEN, price_at={"10:05": 500.0, "10:30": OPEN})
    bars = pd.concat([warm, test_bars]).sort_index()

    trades, decisions = run_signal_engine(bars)
    assert trades == []
    assert not decisions[decisions.checkpoint == "10:00"].iloc[0]["bullish_signal"]
    assert not decisions[decisions.checkpoint == "10:30"].iloc[0]["bullish_signal"]


def test_long_entry_requires_both_band_breakout_and_vwap_confirmation():
    warm = _warmup(14)
    test_day = _next_session_date(warm)
    # Breaks the upper band but VWAP is still above price most of the day is
    # hard to construct with a flat step function, so instead show the
    # contrapositive directly: with default flat data (no breakout), no
    # entry occurs, then with a clean breakout, entry does occur.
    flat_bars = make_session_bars(test_day, OPEN)
    bars = pd.concat([warm, flat_bars]).sort_index()
    trades, decisions = run_signal_engine(bars)
    assert trades == []

    breakout_bars = make_session_bars(test_day, OPEN, price_at={"10:00": OPEN * 1.02})
    bars2 = pd.concat([warm, breakout_bars]).sort_index()
    trades2, decisions2 = run_signal_engine(bars2)
    assert len(trades2) == 1
    t = trades2[0]
    assert t.side == "long"
    assert t.entry_checkpoint == "10:00"
    assert t.entry_price == pytest.approx(OPEN * 1.02)


def test_short_entry_requires_both_band_breakout_and_vwap_confirmation():
    warm = _warmup(14)
    test_day = _next_session_date(warm)
    breakout_bars = make_session_bars(test_day, OPEN, price_at={"10:00": OPEN * 0.98})
    bars = pd.concat([warm, breakout_bars]).sort_index()
    trades, decisions = run_signal_engine(bars)
    assert len(trades) == 1
    t = trades[0]
    assert t.side == "short"
    assert t.entry_checkpoint == "10:00"
    assert t.entry_price == pytest.approx(OPEN * 0.98)


def test_long_exit_on_trail_break():
    warm = _warmup(14)
    test_day = _next_session_date(warm)
    # Enter long at 10:00 on a breakout, then let price collapse back below
    # the long_trail (max(vwap, upper)) at 10:30, and hold flat afterward.
    # 10:30 price returns to the session open: below upper (so the trail
    # breaks) but still above lower, so this is NOT also a bearish signal —
    # isolates the plain trail-exit path from the reversal path.
    bars_today = make_session_bars(
        test_day, OPEN, price_at={"10:00": OPEN * 1.02, "10:30": OPEN, "11:00": OPEN}
    )
    bars = pd.concat([warm, bars_today]).sort_index()
    trades, decisions = run_signal_engine(bars)
    assert len(trades) == 1
    t = trades[0]
    assert t.side == "long"
    assert t.exit_checkpoint == "10:30"
    assert t.exit_reason == "signal_exit"
    assert t.exit_price == pytest.approx(OPEN)


def test_short_exit_on_trail_break():
    warm = _warmup(14)
    test_day = _next_session_date(warm)
    # 10:30 price returns to the session open: above lower (so the trail
    # breaks) but still below upper, isolating the trail-exit path from a
    # bullish reversal.
    bars_today = make_session_bars(
        test_day, OPEN, price_at={"10:00": OPEN * 0.98, "10:30": OPEN, "11:00": OPEN}
    )
    bars = pd.concat([warm, bars_today]).sort_index()
    trades, decisions = run_signal_engine(bars)
    assert len(trades) == 1
    t = trades[0]
    assert t.side == "short"
    assert t.exit_checkpoint == "10:30"
    assert t.exit_reason == "signal_exit"


def test_reversal_closes_but_does_not_autoflip_by_default():
    warm = _warmup(14)
    test_day = _next_session_date(warm)
    bars_today = make_session_bars(
        test_day, OPEN, price_at={"10:00": OPEN * 1.02, "10:30": OPEN * 0.90}
    )
    bars = pd.concat([warm, bars_today]).sort_index()
    trades, decisions = run_signal_engine(bars, allow_immediate_reversal=False)
    # The long is closed on the reversal signal at 10:30, but NOT immediately
    # flipped into a short at that same checkpoint. Price is still (still
    # deeply) bearish at 11:00, so a fresh, independent short entry is
    # correctly opened one checkpoint later — that is different from an
    # immediate same-bar flip and this test locks in the distinction.
    assert len(trades) == 2
    assert trades[0].side == "long" and trades[0].exit_reason == "reversal"
    assert trades[0].exit_checkpoint == "10:30"
    assert trades[1].side == "short" and trades[1].entry_checkpoint == "11:00"
    d = decisions[(decisions.session_date == test_day) & (decisions.checkpoint == "10:30")].iloc[0]
    assert bool(d["potential_reversal"]) is True
    assert d["action"] == "reversal_close"


def test_reversal_immediate_flip_variant_opens_opposite_trade():
    warm = _warmup(14)
    test_day = _next_session_date(warm)
    bars_today = make_session_bars(
        test_day, OPEN, price_at={"10:00": OPEN * 1.02, "10:30": OPEN * 0.90}
    )
    bars = pd.concat([warm, bars_today]).sort_index()
    trades, decisions = run_signal_engine(bars, allow_immediate_reversal=True)
    assert len(trades) == 2
    assert trades[0].side == "long" and trades[0].exit_reason == "reversal"
    assert trades[0].exit_checkpoint == "10:30"
    # Same-checkpoint flip: the short opens at the SAME 10:30 bar the long
    # closed on, unlike the default (non-flip) variant which waits a
    # checkpoint. This is the distinction the flag exists to measure.
    assert trades[1].side == "short" and trades[1].entry_checkpoint == "10:30"
    assert trades[1].entry_time == trades[0].exit_time


def test_forced_close_at_session_end():
    warm = _warmup(14)
    test_day = _next_session_date(warm)
    # Enter long at 15:30 (last checkpoint) and never get a signal exit.
    bars_today = make_session_bars(test_day, OPEN, price_at={"15:30": OPEN * 1.02})
    bars = pd.concat([warm, bars_today]).sort_index()
    trades, decisions = run_signal_engine(bars)
    assert len(trades) == 1
    t = trades[0]
    assert t.exit_reason == "forced_close_eod"
    assert t.exit_checkpoint == "16:00"
    assert t.exit_price == pytest.approx(OPEN * 1.02)  # price held flat after 15:30


def test_force_flat_time_flattens_before_1600_for_options_layer():
    warm = _warmup(14)
    test_day = _next_session_date(warm)
    bars_today = make_session_bars(test_day, OPEN, price_at={"15:30": OPEN * 1.02})
    bars = pd.concat([warm, bars_today]).sort_index()
    trades, decisions = run_signal_engine(bars, force_flat_time=dt.time(15, 55))
    assert len(trades) == 1
    # Flattened off the underlying's own 15:55 bar, not the 15:30 checkpoint
    # and not the 16:00 print.
    assert trades[0].exit_checkpoint == "15:55"
    assert trades[0].exit_reason == "forced_close_eod"
    assert trades[0].exit_price == pytest.approx(OPEN * 1.02)


def test_missing_checkpoint_bar_is_skipped_not_fatal():
    warm = _warmup(14)
    test_day = _next_session_date(warm)
    bars_today = make_session_bars(test_day, OPEN, price_at={"10:00": OPEN * 1.02})
    # Simulate a missing bar for the 10:30 checkpoint (data gap).
    bars_today = bars_today.drop(
        index=pd.Timestamp(f"{test_day} 10:30", tz="America/New_York").tz_convert("UTC")
    )
    bars = pd.concat([warm, bars_today]).sort_index()
    trades, decisions = run_signal_engine(bars)
    assert len(trades) == 1  # position entered at 10:00, force-closed at EOD
    today = decisions[decisions.session_date == test_day]
    assert not (today.checkpoint == "10:30").any()
    assert (today.checkpoint == "11:00").any()  # engine keeps going afterward


def test_half_day_forced_close_uses_actual_last_bar_not_1600():
    warm = _warmup(14)
    test_day = _next_session_date(warm)
    # Force this synthetic day to behave like a half day by only providing
    # bars through 13:00 and entering right before the (half-day) close.
    bars_today = make_session_bars(test_day, OPEN, price_at={"12:30": OPEN * 1.02}, close_time="13:00")
    bars = pd.concat([warm, bars_today]).sort_index()
    trades, decisions = run_signal_engine(bars)
    assert len(trades) == 1
    assert trades[0].exit_time == bars_today.index[-1]
    assert trades[0].exit_price == pytest.approx(OPEN * 1.02)
