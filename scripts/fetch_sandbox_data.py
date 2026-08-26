"""Documents exactly how data_raw/spy_1min_rh_sandbox_2026-07-16_2026-08-25.parquet
was produced. This script is NOT runnable end-to-end unattended: the raw
per-chunk JSON responses were obtained by the orchestrating agent calling
the Robinhood MCP tool `get_equity_historicals` interactively (that tool is
only reachable through the agent's tool-calling boundary, not from
unattended Python in this package — see DATA_AUDIT.md and
PAPER_TRADING.md). This script reproduces the parsing/assembly step only,
given those raw JSON responses already saved to disk.

Chunking rationale: the tool returns at most ~2500 bars per call; a 5
trading-day window of 1-minute RTH bars is 5*390=1950 bars, safely under
that cap, so the July 16 - Aug 25, 2026 window was split into 7 chunks
along calendar-week boundaries.
"""
from __future__ import annotations

import glob
import json
from pathlib import Path

import pandas as pd

RAW_JSON_GLOB = (
    "/root/.claude/projects/-home-user-spy-options/"
    "ec46af1c-d1ac-5ed4-910e-4a670e958f2b/tool-results/"
    "mcp-Robinhood-get_equity_historicals-*.txt"
)
OUT_STEM = "data_raw/spy_1min_rh_sandbox_2026-07-16_2026-08-25"


def assemble() -> pd.DataFrame:
    files = sorted(glob.glob(RAW_JSON_GLOB))
    if not files:
        raise FileNotFoundError(
            "No raw Robinhood historicals JSON found. This script only "
            "reassembles already-fetched chunks; see the module docstring."
        )
    all_bars = []
    for fp in files:
        d = json.load(open(fp))
        for result in d["data"]["results"]:
            all_bars.extend(result["bars"])

    df = pd.DataFrame(all_bars)
    df["begins_at"] = pd.to_datetime(df["begins_at"], utc=True)
    df = df.drop_duplicates(subset="begins_at").sort_values("begins_at").reset_index(drop=True)

    if "interpolated" in df.columns:
        mask = df["interpolated"].fillna(False).astype(bool)
        real = df.loc[~mask].copy()
        n_dropped = int(mask.sum())
    else:
        real = df.copy()
        n_dropped = 0

    out = real.set_index("begins_at")[["open_price", "high_price", "low_price", "close_price", "volume"]].copy()
    out.columns = ["open", "high", "low", "close", "volume"]
    out = out.astype(float).sort_index()
    out.index.name = "timestamp"

    print(f"assembled {len(out)} real (non-interpolated) 1-minute bars from {len(files)} chunks; "
          f"dropped {n_dropped} interpolated/placeholder bars")
    return out


def main():
    out = assemble()
    Path("data_raw").mkdir(exist_ok=True)
    out.to_parquet(f"{OUT_STEM}.parquet")
    out.to_csv(f"{OUT_STEM}.csv")
    print(f"wrote {OUT_STEM}.parquet / .csv, shape={out.shape}, "
          f"range={out.index.min()} -> {out.index.max()}")


if __name__ == "__main__":
    main()
