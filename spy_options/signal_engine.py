"""Noise-Area intraday momentum signal engine (STRATEGY_SPEC.md).

All computation here is strictly causal: sigma[t] on session d only ever
reads sessions strictly before d, and a checkpoint decision at time t only
ever reads bars with timestamp <= t.
"""
from __future__ import annotations

import datetime as dt
from dataclasses import dataclass, field

import numpy as np
import pandas as pd

from .config import CHECKPOINTS, SIGMA_LOOKBACK_SESSIONS
from .timeutil import (
    session_date_of,
    to_ny,
    trading_schedule,
    valid_checkpoints_for_session,
)

REQUIRED_COLUMNS = ("open", "high", "low", "close", "volume")


class InsufficientDataError(RuntimeError):
    pass


@dataclass
class Trade:
    side: str  # "long" | "short"
    entry_time: pd.Timestamp
    entry_price: float
    entry_checkpoint: str
    exit_time: pd.Timestamp | None = None
    exit_price: float | None = None
    exit_checkpoint: str | None = None
    exit_reason: str | None = None  # signal_exit | reversal | forced_close_eod
    session_date: dt.date | None = None

    def to_dict(self) -> dict:
        d = self.__dict__.copy()
        return d


@dataclass
class Decision:
    """One evaluated checkpoint, kept for audit/journal parity with paper trading."""

    timestamp: pd.Timestamp
    session_date: dt.date
    checkpoint: str
    close: float
    vwap: float
    upper: float
    lower: float
    sigma: float
    today_open: float
    prev_close: float
    n_lookback_sessions: int
    position_before: str
    bullish_signal: bool
    bearish_signal: bool
    action: str  # none | enter_long | enter_short | exit_long | exit_short | reversal_close
    potential_reversal: bool = False
    note: str = ""


def _validate(bars: pd.DataFrame) -> None:
    missing = [c for c in REQUIRED_COLUMNS if c not in bars.columns]
    if missing:
        raise ValueError(f"bars is missing required columns: {missing}")
    if not isinstance(bars.index, pd.DatetimeIndex):
        raise ValueError("bars must be indexed by a tz-aware DatetimeIndex")
    if bars.index.tz is None:
        raise ValueError("bars.index must be tz-aware (UTC recommended)")
    if not bars.index.is_monotonic_increasing:
        raise ValueError("bars.index must be sorted ascending")


def annotate_bars(bars: pd.DataFrame) -> pd.DataFrame:
    """Add session_date, typical_price, and reset-per-session VWAP."""
    _validate(bars)
    out = bars.copy()
    out["session_date"] = [session_date_of(ts) for ts in out.index]
    out["typical_price"] = (out["high"] + out["low"] + out["close"]) / 3.0
    tpv = out["typical_price"] * out["volume"]
    grp = out.groupby("session_date", sort=False)
    cum_tpv = tpv.groupby(out["session_date"], sort=False).cumsum()
    cum_vol = out["volume"].groupby(out["session_date"], sort=False).cumsum()
    with np.errstate(invalid="ignore", divide="ignore"):
        out["vwap"] = np.where(cum_vol > 0, cum_tpv / cum_vol, np.nan)
    out["is_session_open_bar"] = out.groupby("session_date", sort=False).cumcount() == 0
    return out


def _checkpoint_time_of(cp: str) -> dt.time:
    h, m = map(int, cp.split(":"))
    return dt.time(h, m)


def _session_index(bars: pd.DataFrame) -> pd.DataFrame:
    """One row per session: date, open, close (last bar's close), open_ts."""
    rows = []
    for sd, g in bars.groupby("session_date", sort=True):
        rows.append(
            {
                "session_date": sd,
                "open": float(g["open"].iloc[0]),
                "close": float(g["close"].iloc[-1]),
            }
        )
    idx = pd.DataFrame(rows).sort_values("session_date").reset_index(drop=True)
    return idx


def compute_sigma_table(bars: pd.DataFrame) -> pd.DataFrame:
    """sigma[t] per session per checkpoint, from the previous 14 sessions only.

    Returns a DataFrame indexed by session_date, one column per checkpoint,
    plus 'n_lookback_sessions' (count of prior sessions actually available,
    capped at 14) used per row (constant across checkpoints in a row unless
    a specific prior session is missing a bar at that exact checkpoint,
    in which case that single (day, checkpoint) cell is excluded from the
    mean and the effective count for that cell is lower).
    """
    sessions = sorted(bars["session_date"].unique())
    # move[d, t] = abs(close[d,t]/open[d] - 1) for every session/checkpoint
    move = pd.DataFrame(index=sessions, columns=CHECKPOINTS, dtype=float)
    opens = {}
    for sd, g in bars.groupby("session_date", sort=True):
        o = float(g["open"].iloc[0])
        opens[sd] = o
        by_time = {to_ny(ts).strftime("%H:%M"): row.close for ts, row in g.iterrows()}
        for cp in CHECKPOINTS:
            if cp in by_time and o:
                move.loc[sd, cp] = abs(float(by_time[cp]) / o - 1.0)

    sigma = pd.DataFrame(index=sessions, columns=list(CHECKPOINTS) + ["n_lookback_sessions"], dtype=float)
    for i, sd in enumerate(sessions):
        lookback = sessions[max(0, i - SIGMA_LOOKBACK_SESSIONS) : i]
        n = len(lookback)
        sigma.loc[sd, "n_lookback_sessions"] = n
        if n == 0:
            continue
        window = move.loc[lookback]
        sigma.loc[sd, list(CHECKPOINTS)] = window.mean(axis=0, skipna=True)
    return sigma


def run_signal_engine(
    bars_utc: pd.DataFrame,
    *,
    allow_immediate_reversal: bool = False,
    require_full_lookback: bool = True,
    force_flat_time: dt.time | None = None,
) -> tuple[list[Trade], pd.DataFrame]:
    """Run the frozen Noise-Area signal engine over 1-minute RTH bars.

    Parameters
    ----------
    bars_utc: DataFrame indexed by tz-aware timestamps (any tz; converted to
        America/New_York internally), columns open/high/low/close/volume,
        already filtered to regular trading hours.
    allow_immediate_reversal: canonical strategy is False (a reversal only
        closes the existing position; it does not open the opposite one on
        the same checkpoint). Set True only to measure the separate,
        explicitly-labeled variant.
    require_full_lookback: if True (default, canonical), a session is only
        eligible for signal evaluation once a full 14-session lookback is
        available (warm-up period excluded). If False, partial-lookback
        sessions are evaluated anyway (used only for missing-bar unit tests).
    force_flat_time: if given, any open position still open at this NY local
        time on its session is force-closed (used by the options layer to
        flatten at 15:55 ET instead of the underlying's 16:00 print).

    Returns
    -------
    (trades, decisions) where trades is a list[Trade] and decisions is a
    DataFrame audit log of every checkpoint evaluation.
    """
    bars = annotate_bars(bars_utc)
    sigma = compute_sigma_table(bars)
    sess_idx = _session_index(bars).set_index("session_date")

    start = min(bars["session_date"])
    end = max(bars["session_date"])
    schedule = trading_schedule(str(start), str(end))

    sessions = sorted(bars["session_date"].unique())
    trades: list[Trade] = []
    decisions: list[Decision] = []

    position: str | None = None  # None | "long" | "short"
    open_trade: Trade | None = None
    prev_session_close: float | None = None

    for si, sd in enumerate(sessions):
        g = bars[bars["session_date"] == sd]
        today_open = float(g["open"].iloc[0])
        n_lookback = int(sigma.loc[sd, "n_lookback_sessions"]) if sd in sigma.index else 0
        eligible = (not require_full_lookback) or (n_lookback >= SIGMA_LOOKBACK_SESSIONS)

        # Any position must never carry overnight: if still open from a
        # prior session (should not happen given end-of-session forcing
        # below, but guarded defensively), force-close at this session's
        # open before any new decision.
        if open_trade is not None:
            raise RuntimeError(
                "position carried into a new session — overnight holding is forbidden; "
                "this indicates a bug in end-of-session forced close"
            )

        checkpoints_today = valid_checkpoints_for_session(sd, schedule)
        by_time = {to_ny(ts).strftime("%H:%M"): (ts, row) for ts, row in g.iterrows()}

        for cp in checkpoints_today:
            if cp not in by_time:
                # Missing bar at this checkpoint: no decision can be made.
                continue
            ts, row = by_time[cp]
            close = float(row["close"])
            vwap = float(row["vwap"])

            if not eligible or sd not in sigma.index or pd.isna(sigma.loc[sd, cp]):
                decisions.append(
                    Decision(
                        timestamp=ts, session_date=sd, checkpoint=cp, close=close, vwap=vwap,
                        upper=float("nan"), lower=float("nan"), sigma=float("nan"),
                        today_open=today_open, prev_close=prev_session_close or float("nan"),
                        n_lookback_sessions=n_lookback, position_before=position or "flat",
                        bullish_signal=False, bearish_signal=False, action="none",
                        note="insufficient_lookback_or_missing_sigma",
                    )
                )
                continue

            s = float(sigma.loc[sd, cp])
            pc = prev_session_close if prev_session_close is not None else today_open
            upper = max(today_open, pc) * (1 + s)
            lower = min(today_open, pc) * (1 - s)

            bullish = (close > upper) and (close > vwap)
            bearish = (close < lower) and (close < vwap)

            action = "none"
            potential_reversal = False
            position_before = position or "flat"

            if position is None:
                if bullish:
                    open_trade = Trade(side="long", entry_time=ts, entry_price=close,
                                        entry_checkpoint=cp, session_date=sd)
                    position = "long"
                    action = "enter_long"
                elif bearish:
                    open_trade = Trade(side="short", entry_time=ts, entry_price=close,
                                        entry_checkpoint=cp, session_date=sd)
                    position = "short"
                    action = "enter_short"
            elif position == "long":
                long_trail = max(vwap, upper)
                opposite = bearish
                if opposite:
                    potential_reversal = True
                    open_trade.exit_time = ts
                    open_trade.exit_price = close
                    open_trade.exit_checkpoint = cp
                    open_trade.exit_reason = "reversal"
                    trades.append(open_trade)
                    open_trade = None
                    position = None
                    action = "reversal_close"
                    if allow_immediate_reversal:
                        open_trade = Trade(side="short", entry_time=ts, entry_price=close,
                                            entry_checkpoint=cp, session_date=sd)
                        position = "short"
                        action = "reversal_close_and_enter_short"
                elif close < long_trail:
                    open_trade.exit_time = ts
                    open_trade.exit_price = close
                    open_trade.exit_checkpoint = cp
                    open_trade.exit_reason = "signal_exit"
                    trades.append(open_trade)
                    open_trade = None
                    position = None
                    action = "exit_long"
            elif position == "short":
                short_trail = min(vwap, lower)
                opposite = bullish
                if opposite:
                    potential_reversal = True
                    open_trade.exit_time = ts
                    open_trade.exit_price = close
                    open_trade.exit_checkpoint = cp
                    open_trade.exit_reason = "reversal"
                    trades.append(open_trade)
                    open_trade = None
                    position = None
                    action = "reversal_close"
                    if allow_immediate_reversal:
                        open_trade = Trade(side="long", entry_time=ts, entry_price=close,
                                            entry_checkpoint=cp, session_date=sd)
                        position = "long"
                        action = "reversal_close_and_enter_long"
                elif close > short_trail:
                    open_trade.exit_time = ts
                    open_trade.exit_price = close
                    open_trade.exit_checkpoint = cp
                    open_trade.exit_reason = "signal_exit"
                    trades.append(open_trade)
                    open_trade = None
                    position = None
                    action = "exit_short"

            decisions.append(
                Decision(
                    timestamp=ts, session_date=sd, checkpoint=cp, close=close, vwap=vwap,
                    upper=upper, lower=lower, sigma=s, today_open=today_open,
                    prev_close=pc, n_lookback_sessions=n_lookback,
                    position_before=position_before, bullish_signal=bullish,
                    bearish_signal=bearish, action=action,
                    potential_reversal=potential_reversal,
                )
            )

        # Optional early forced-flatten (options implementation: liquidate by
        # 15:55 ET off the underlying's own bar at that clock time, not off
        # a checkpoint — there is no 15:55 checkpoint in CHECKPOINTS).
        if force_flat_time is not None and open_trade is not None:
            ff_str = force_flat_time.strftime("%H:%M")
            match = [(ts, row) for ts, row in g.iterrows() if to_ny(ts).strftime("%H:%M") == ff_str]
            if match:
                ts, row = match[0]
                open_trade.exit_time = ts
                open_trade.exit_price = float(row["close"])
                open_trade.exit_checkpoint = ff_str
                open_trade.exit_reason = "forced_close_eod"
                trades.append(open_trade)
                open_trade = None
                position = None
            # else: no bar at that exact minute (e.g. a half day ending
            # before 15:55) — falls through to the end-of-session close below.

        # End-of-session forced close (16:00 print, or the session's actual
        # last bar on a half day) if still open.
        if open_trade is not None:
            last_ts = g.index[-1]
            last_close = float(g["close"].iloc[-1])
            open_trade.exit_time = last_ts
            open_trade.exit_price = last_close
            open_trade.exit_checkpoint = "16:00"
            open_trade.exit_reason = "forced_close_eod"
            trades.append(open_trade)
            open_trade = None
            position = None

        prev_session_close = float(g["close"].iloc[-1])

    decisions_df = pd.DataFrame([d.__dict__ for d in decisions])
    return trades, decisions_df
