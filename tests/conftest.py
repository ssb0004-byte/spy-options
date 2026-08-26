"""Shared deterministic synthetic-data fixtures for the test suite."""
from __future__ import annotations

import datetime as dt

import pandas as pd
import pytest

NY = "America/New_York"


def make_session_bars(
    session_date: dt.date,
    open_price: float,
    price_at: dict[str, float] | None = None,
    volume: float = 1000.0,
    close_time: str = "16:00",
) -> pd.DataFrame:
    """Build one session of 1-minute RTH bars (09:30..close_time-1min).

    price_at maps "HH:MM" -> close price for that bar; between and after
    specified points the price is held flat from the last specified value
    (a simple, fully deterministic step function — sufficient to exercise
    checkpoint logic without needing a full tick generator). open/high/low
    are derived from consecutive closes so typical_price is well defined.
    """
    price_at = dict(price_at or {})
    start = pd.Timestamp(f"{session_date} 09:30", tz=NY)
    end = pd.Timestamp(f"{session_date} {close_time}", tz=NY)
    idx = pd.date_range(start, end, freq="1min", inclusive="left")

    closes = []
    last = open_price
    for ts in idx:
        hm = ts.strftime("%H:%M")
        if hm in price_at:
            last = price_at[hm]
        closes.append(last)

    opens = [open_price] + closes[:-1]
    highs = [max(o, c) for o, c in zip(opens, closes)]
    lows = [min(o, c) for o, c in zip(opens, closes)]

    df = pd.DataFrame(
        {"open": opens, "high": highs, "low": lows, "close": closes, "volume": volume},
        index=idx.tz_convert("UTC"),
    )
    df.index.name = "timestamp"
    return df


def make_flat_history(
    n_sessions: int,
    start_date: dt.date,
    open_price: float,
    daily_move_pct: float = 0.001,
) -> pd.DataFrame:
    """n_sessions of bars with a tiny, constant, deterministic wiggle.

    Used to build a clean 14-session sigma warm-up window with a known,
    reproducible sigma[t] at every checkpoint (== daily_move_pct at every
    checkpoint from 10:00 onward, since the price steps once at 09:31 and
    holds).
    """
    from pandas_market_calendars import get_calendar

    cal = get_calendar("NYSE")
    sched = cal.schedule(start_date=start_date, end_date=start_date + dt.timedelta(days=n_sessions * 3))
    sessions = sched.index[:n_sessions]

    frames = []
    for sd in sessions:
        d = sd.date()
        bump = open_price * daily_move_pct
        frames.append(
            make_session_bars(d, open_price, price_at={"09:31": open_price + bump})
        )
    return pd.concat(frames).sort_index()
