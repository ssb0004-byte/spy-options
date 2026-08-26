"""Runs the frozen signal engine over the real (non-fabricated) intraday
window available in this sandbox and writes trade/decision CSVs plus a
JSON metrics summary. See DATA_AUDIT.md for exactly what this window is
and is not (29 real sessions, July 16 - Aug 25 2026; NOT the 2018-2026
chronological validation STRATEGY_SPEC.md calls for).
"""
from __future__ import annotations

import dataclasses
import json
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd

from spy_options import metrics as M
from spy_options.signal_engine import run_signal_engine

DATA_PATH = "data_raw/spy_1min_rh_sandbox_2026-07-16_2026-08-25.parquet"
OUT_DIR = Path("reports")
TRADES_DIR = OUT_DIR / "trades"
FIG_DIR = OUT_DIR / "figures"


def main():
    TRADES_DIR.mkdir(parents=True, exist_ok=True)
    FIG_DIR.mkdir(parents=True, exist_ok=True)

    bars = pd.read_parquet(DATA_PATH)
    trades, decisions = run_signal_engine(bars)

    tdf = pd.DataFrame([dataclasses.asdict(t) for t in trades])
    side_sign = {"long": 1, "short": -1}
    if len(tdf):
        tdf["pnl_pts"] = (tdf["exit_price"] - tdf["entry_price"]) * tdf["side"].map(side_sign)
        tdf["pnl_pct"] = tdf["pnl_pts"] / tdf["entry_price"]
        tdf["holding_minutes"] = (
            pd.to_datetime(tdf["exit_time"]) - pd.to_datetime(tdf["entry_time"])
        ).dt.total_seconds() / 60.0

    tdf.to_csv(TRADES_DIR / "underlying_trades.csv", index=False)
    decisions.to_csv(TRADES_DIR / "underlying_decisions.csv", index=False)

    n_sessions = decisions["session_date"].nunique()
    n_eligible_sessions = int((decisions.groupby("session_date")["n_lookback_sessions"].max() >= 14).sum())
    valid_decisions = decisions[decisions["note"].fillna("") == ""]

    summary = {
        "data_window": {"start": str(bars.index.min()), "end": str(bars.index.max()),
                         "n_sessions_total": int(n_sessions), "n_sessions_warmup_excluded": 14,
                         "n_sessions_eligible_for_signals": n_eligible_sessions},
        "n_checkpoint_opportunities_eligible": int(len(valid_decisions)),
        "n_trades": int(len(tdf)),
    }

    if len(tdf):
        pnl_pct = tdf["pnl_pct"]
        summary["trade_stats_pct_return"] = M.summarize_trades(tdf.assign(pnl=pnl_pct), pnl_col="pnl")
        summary["long_trades"] = int((tdf["side"] == "long").sum())
        summary["short_trades"] = int((tdf["side"] == "short").sum())
        summary["avg_holding_minutes"] = float(tdf["holding_minutes"].mean())
        summary["exit_reason_counts"] = tdf["exit_reason"].value_counts().to_dict()

        point, lo, hi = M.bootstrap_ci(pnl_pct, M.expectancy)
        summary["expectancy_bootstrap_ci_95pct"] = {
            "point": point, "lo": lo, "hi": hi,
            "note": "n<5 trades: bootstrap CI is not meaningful (returned as NaN by design); see BACKTEST_REPORT.md",
        }
    else:
        summary["trade_stats_pct_return"] = None

    summary["not_computed"] = {
        "annualized_return_vol_sharpe_sortino_maxdd": "requires a multi-month+ equity curve; n_trades too small / window too short",
        "calendar_year_results": "only one partial calendar year (2026) is represented, and only a 6-week slice of it",
        "rolling_6m_12m_performance": "window is 6 weeks; no rolling window is computable",
        "vix_regime_breakdown": "VIX data was not pulled for this run — with n_trades=2 a regime breakdown would not be informative; skipped rather than fabricated",
        "monthly_and_dte_breakdowns": "not computed for options layer; see OPTION_BACKTEST_REPORT.md (BLOCKED BY DATA)",
    }

    with open(OUT_DIR / "underlying_backtest_summary.json", "w") as f:
        json.dump(summary, f, indent=2, default=str)

    # --- Equity curve (points, not $, since sizing/leverage is an options-layer concept) ---
    fig, ax = plt.subplots(figsize=(8, 4))
    if len(tdf):
        cum = (1 + tdf["pnl_pct"]).cumprod()
        ax.plot(pd.to_datetime(tdf["exit_time"]), cum, marker="o")
        ax.set_title("SPY underlying signal-engine trades — cumulative return multiple\n"
                      "(29 real sandbox sessions, 2026-07-16..2026-08-25 — NOT a multi-year backtest)")
        ax.set_ylabel("cumulative return multiple")
        ax.axhline(1.0, color="gray", lw=0.8, ls="--")
    else:
        ax.text(0.5, 0.5, "no trades", ha="center", va="center")
    fig.autofmt_xdate()
    fig.tight_layout()
    fig.savefig(FIG_DIR / "underlying_equity_curve.png", dpi=130)
    plt.close(fig)

    # --- Price with Noise Area bands + VWAP for the two trading days that fired ---
    if len(tdf):
        for _, tr in tdf.iterrows():
            sd = tr["session_date"]
            day_dec = decisions[decisions["session_date"].astype(str) == str(sd)]
            day_bars = bars[bars.index.tz_convert("America/New_York").date.astype(str) == str(sd)]
            fig, ax = plt.subplots(figsize=(9, 4))
            local_idx = day_bars.index.tz_convert("America/New_York")
            ax.plot(local_idx, day_bars["close"], color="black", lw=0.8, label="SPY close")
            ax.plot(pd.to_datetime(day_dec["timestamp"]).dt.tz_convert("America/New_York"),
                     day_dec["vwap"], color="tab:blue", lw=1.2, label="VWAP")
            ax.plot(pd.to_datetime(day_dec["timestamp"]).dt.tz_convert("America/New_York"),
                     day_dec["upper"], color="tab:green", lw=1.0, ls="--", label="upper")
            ax.plot(pd.to_datetime(day_dec["timestamp"]).dt.tz_convert("America/New_York"),
                     day_dec["lower"], color="tab:red", lw=1.0, ls="--", label="lower")
            ax.axvline(pd.to_datetime(tr["entry_time"]).tz_convert("America/New_York"), color="green", ls=":")
            ax.axvline(pd.to_datetime(tr["exit_time"]).tz_convert("America/New_York"), color="red", ls=":")
            ax.set_title(f"{sd} — {tr['side']} trade, exit_reason={tr['exit_reason']}")
            ax.legend(fontsize=8)
            fig.autofmt_xdate()
            fig.tight_layout()
            fig.savefig(FIG_DIR / f"trade_detail_{sd}.png", dpi=130)
            plt.close(fig)

    print(json.dumps(summary, indent=2, default=str))


if __name__ == "__main__":
    main()
