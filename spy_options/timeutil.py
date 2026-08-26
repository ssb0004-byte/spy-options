"""Session calendar, timezone, and checkpoint utilities.

Uses the real NYSE calendar (pandas_market_calendars) so holidays and half
days (early 13:00 ET closes) are handled correctly rather than guessed.
"""
from __future__ import annotations

import datetime as dt
from functools import lru_cache

import pandas as pd
import pandas_market_calendars as mcal

from .config import CHECKPOINTS, NY_TZ

_NYSE = mcal.get_calendar("NYSE")


@lru_cache(maxsize=8)
def trading_schedule(start: str, end: str) -> pd.DataFrame:
    """NYSE trading schedule between start/end (inclusive), indexed by date.

    Columns market_open / market_close are tz-aware UTC timestamps; a half
    day shows an early market_close (typically 13:00 ET / 18:00 UTC).
    """
    sched = _NYSE.schedule(start_date=start, end_date=end)
    return sched


def is_half_day(session_date: dt.date, schedule: pd.DataFrame) -> bool:
    ts = pd.Timestamp(session_date)
    if ts not in schedule.index:
        return False
    close_ny = schedule.loc[ts, "market_close"].tz_convert(NY_TZ)
    return close_ny.time() < dt.time(16, 0)


def session_close_time_ny(session_date: dt.date, schedule: pd.DataFrame) -> dt.time:
    ts = pd.Timestamp(session_date)
    if ts not in schedule.index:
        return dt.time(16, 0)
    return schedule.loc[ts, "market_close"].tz_convert(NY_TZ).time()


def valid_checkpoints_for_session(session_date: dt.date, schedule: pd.DataFrame) -> list[str]:
    """Checkpoints that fall strictly before the session's close.

    On a half day (13:00 ET close) only the checkpoints up to 12:30 remain
    valid signal-evaluation times; later "checkpoints" never occur because
    the session has already ended, and are excluded rather than treated as
    a forced-flatten trigger.
    """
    close_t = session_close_time_ny(session_date, schedule)
    out = []
    for cp in CHECKPOINTS:
        h, m = map(int, cp.split(":"))
        if dt.time(h, m) < close_t:
            out.append(cp)
    return out


def to_ny(ts: pd.Timestamp) -> pd.Timestamp:
    """Localize/convert a timestamp to America/New_York, DST-safe."""
    if ts.tzinfo is None:
        return ts.tz_localize("UTC").tz_convert(NY_TZ)
    return ts.tz_convert(NY_TZ)


def session_date_of(ts: pd.Timestamp) -> dt.date:
    return to_ny(ts).date()
