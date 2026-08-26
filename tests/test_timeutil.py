import datetime as dt

import pandas as pd

from spy_options.timeutil import (
    is_half_day,
    session_date_of,
    to_ny,
    trading_schedule,
    valid_checkpoints_for_session,
)


def test_to_ny_handles_dst_spring_and_fall():
    # 2024-03-10 is the US spring-forward date (EST -5 -> EDT -4).
    before = pd.Timestamp("2024-03-08 14:30:00", tz="UTC")  # EST session: 09:30 ET
    after = pd.Timestamp("2024-03-11 13:30:00", tz="UTC")   # EDT session: 09:30 ET
    assert to_ny(before).strftime("%H:%M") == "09:30"
    assert to_ny(after).strftime("%H:%M") == "09:30"

    # 2024-11-03 is the US fall-back date.
    before_fb = pd.Timestamp("2024-11-01 13:30:00", tz="UTC")  # EDT: 09:30 ET
    after_fb = pd.Timestamp("2024-11-04 14:30:00", tz="UTC")   # EST: 09:30 ET
    assert to_ny(before_fb).strftime("%H:%M") == "09:30"
    assert to_ny(after_fb).strftime("%H:%M") == "09:30"


def test_session_date_of_uses_ny_calendar_date_not_utc_date():
    # 2024-01-02 20:00 ET == 2024-01-03 01:00 UTC; the session date must be
    # the NY date, not the UTC date.
    ts = pd.Timestamp("2024-01-03 01:00:00", tz="UTC")
    assert session_date_of(ts) == dt.date(2024, 1, 2)


def test_half_day_truncates_checkpoints():
    sched = trading_schedule("2023-11-20", "2023-11-30")
    thanksgiving_friday = dt.date(2023, 11, 24)
    assert is_half_day(thanksgiving_friday, sched)
    cps = valid_checkpoints_for_session(thanksgiving_friday, sched)
    assert cps == ["10:00", "10:30", "11:00", "11:30", "12:00", "12:30"]
    assert "13:00" not in cps
    assert "15:30" not in cps


def test_full_day_has_all_twelve_checkpoints():
    sched = trading_schedule("2024-01-01", "2024-01-10")
    full_day = dt.date(2024, 1, 8)
    assert not is_half_day(full_day, sched)
    cps = valid_checkpoints_for_session(full_day, sched)
    assert len(cps) == 12
    assert cps[0] == "10:00" and cps[-1] == "15:30"
