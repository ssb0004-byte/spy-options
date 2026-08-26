"""Performance metrics shared by the underlying and options backtests."""
from __future__ import annotations

import numpy as np
import pandas as pd

TRADING_DAYS_PER_YEAR = 252


def trade_pnls_to_frame(trades: list, pnl_key: str = "pnl") -> pd.DataFrame:
    return pd.DataFrame([t.to_dict() if hasattr(t, "to_dict") else t for t in trades])


def profit_factor(pnls: pd.Series) -> float:
    wins = pnls[pnls > 0].sum()
    losses = -pnls[pnls < 0].sum()
    if losses == 0:
        return float("inf") if wins > 0 else float("nan")
    return float(wins / losses)


def win_rate(pnls: pd.Series) -> float:
    if len(pnls) == 0:
        return float("nan")
    return float((pnls > 0).mean())


def payoff_ratio(pnls: pd.Series) -> float:
    wins = pnls[pnls > 0]
    losses = pnls[pnls < 0]
    if len(losses) == 0 or losses.mean() == 0:
        return float("nan")
    if len(wins) == 0:
        return 0.0
    return float(wins.mean() / abs(losses.mean()))


def expectancy(pnls: pd.Series) -> float:
    if len(pnls) == 0:
        return float("nan")
    return float(pnls.mean())


def sharpe_ratio(returns: pd.Series, periods_per_year: float, rf: float = 0.0) -> float:
    r = returns.dropna()
    if len(r) < 2 or r.std(ddof=1) == 0:
        return float("nan")
    excess = r - rf / periods_per_year
    return float(np.sqrt(periods_per_year) * excess.mean() / r.std(ddof=1))


def sortino_ratio(returns: pd.Series, periods_per_year: float, rf: float = 0.0) -> float:
    r = returns.dropna()
    downside = r[r < 0]
    if len(r) < 2 or len(downside) == 0 or downside.std(ddof=1) == 0:
        return float("nan")
    excess = r - rf / periods_per_year
    return float(np.sqrt(periods_per_year) * excess.mean() / downside.std(ddof=1))


def max_drawdown(equity_curve: pd.Series) -> float:
    if len(equity_curve) == 0:
        return float("nan")
    running_max = equity_curve.cummax()
    dd = equity_curve / running_max - 1.0
    return float(dd.min())


def cagr(equity_curve: pd.Series, periods_per_year: float) -> float:
    if len(equity_curve) < 2:
        return float("nan")
    total_return = equity_curve.iloc[-1] / equity_curve.iloc[0]
    n_periods = len(equity_curve) - 1
    years = n_periods / periods_per_year
    if years <= 0 or total_return <= 0:
        return float("nan")
    return float(total_return ** (1 / years) - 1)


def bootstrap_ci(pnls: pd.Series, stat_fn, n_boot: int = 5000, alpha: float = 0.05,
                  random_state: int = 42) -> tuple[float, float, float]:
    """Percentile bootstrap CI for a per-trade statistic (e.g. mean expectancy).

    Returns (point_estimate, lower, upper). Requires len(pnls) >= 5 to be
    meaningful; caller should treat smaller samples as indicative only.
    """
    pnls = pnls.dropna().to_numpy()
    if len(pnls) == 0:
        return float("nan"), float("nan"), float("nan")
    rng = np.random.default_rng(random_state)
    point = float(stat_fn(pd.Series(pnls)))
    if len(pnls) < 5:
        return point, float("nan"), float("nan")
    boots = np.empty(n_boot)
    n = len(pnls)
    for i in range(n_boot):
        sample = pnls[rng.integers(0, n, n)]
        boots[i] = stat_fn(pd.Series(sample))
    lo = float(np.nanpercentile(boots, 100 * alpha / 2))
    hi = float(np.nanpercentile(boots, 100 * (1 - alpha / 2)))
    return point, lo, hi


def summarize_trades(trades_df: pd.DataFrame, pnl_col: str = "pnl") -> dict:
    pnls = trades_df[pnl_col].dropna()
    wins = pnls[pnls > 0]
    losses = pnls[pnls < 0]
    return {
        "n_trades": int(len(pnls)),
        "win_rate": win_rate(pnls),
        "profit_factor": profit_factor(pnls),
        "expectancy": expectancy(pnls),
        "avg_win": float(wins.mean()) if len(wins) else float("nan"),
        "avg_loss": float(losses.mean()) if len(losses) else float("nan"),
        "payoff_ratio": payoff_ratio(pnls),
        "gross_profit": float(wins.sum()) if len(wins) else 0.0,
        "gross_loss": float(losses.sum()) if len(losses) else 0.0,
        "net_pnl": float(pnls.sum()),
    }
