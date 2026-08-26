"""Runs the option-backtest orchestrator against the real underlying trades
found in the sandbox window, for every frozen policy x fill-model
combination, using NullHistoricalOptionProvider — i.e. the actual data
situation in this environment. Writes the BLOCKED result for each
combination rather than fabricating option P&L. See OPTION_BACKTEST_REPORT.md.
"""
from __future__ import annotations

import dataclasses
import json
from pathlib import Path

import pandas as pd

from spy_options.config import FROZEN_OPTION_POLICIES
from spy_options.options.data_provider import NullHistoricalOptionProvider
from spy_options.options.fill_model import FILL_MODELS
from spy_options.options.option_backtest import BlockedResult, run_option_backtest
from spy_options.signal_engine import Trade

TRADES_CSV = "reports/trades/underlying_trades.csv"
OUT_PATH = "reports/trades/option_backtest_blocked_results.json"


def load_underlying_trades() -> list[Trade]:
    df = pd.read_csv(TRADES_CSV, parse_dates=["entry_time", "exit_time"])
    trades = []
    for _, r in df.iterrows():
        trades.append(Trade(
            side=r["side"], entry_time=r["entry_time"], entry_price=r["entry_price"],
            entry_checkpoint=r["entry_checkpoint"], exit_time=r["exit_time"],
            exit_price=r["exit_price"], exit_checkpoint=r["exit_checkpoint"],
            exit_reason=r["exit_reason"], session_date=r["session_date"],
        ))
    return trades


def main():
    trades = load_underlying_trades()
    provider = NullHistoricalOptionProvider()
    results = []
    for policy in FROZEN_OPTION_POLICIES:
        for fill_model in FILL_MODELS:
            result = run_option_backtest(trades, provider, policy=policy, fill_model=fill_model)
            assert isinstance(result, BlockedResult), (
                "expected BLOCKED given no historical option data provider is reachable in this "
                "environment; see DATA_AUDIT.md. If this assertion ever fails it means a real "
                "provider was wired in — update this script and OPTION_BACKTEST_REPORT.md accordingly."
            )
            results.append(dataclasses.asdict(result))

    Path("reports/trades").mkdir(parents=True, exist_ok=True)
    with open(OUT_PATH, "w") as f:
        json.dump({"n_underlying_trades_available": len(trades), "results": results}, f, indent=2)
    print(json.dumps(results[0], indent=2))
    print(f"... {len(results)} policy x fill-model combinations, all BLOCKED. Wrote {OUT_PATH}")


if __name__ == "__main__":
    main()
