"""Market-data streaming interface for the paper engine.

See spy_options.options.data_provider for the analogous option-chain
interfaces. As with that module, the only implementation of a live feed
possible from *inside this sandboxed session* is via the interactive
Robinhood MCP tool boundary the orchestrating agent calls directly — not
from unattended Python code in this package. `ReplayMarketDataProvider` is
what the deterministic tests (and any dry-run) use; a real deployment wires
a concrete subclass backed by an authenticated, network-connected feed.
"""
from __future__ import annotations

import abc

import pandas as pd


class MarketDataProvider(abc.ABC):
    @abc.abstractmethod
    def next_bar(self) -> tuple[pd.Timestamp, dict] | None:
        """Return (timestamp, {open,high,low,close,volume}) for the next
        completed 1-minute RTH bar, or None when no further bar is
        currently available."""
        raise NotImplementedError


class ReplayMarketDataProvider(MarketDataProvider):
    """Deterministic, in-memory replay of a pre-loaded bars DataFrame."""

    def __init__(self, bars: pd.DataFrame):
        self._bars = bars
        self._i = 0

    def next_bar(self):
        if self._i >= len(self._bars):
            return None
        ts = self._bars.index[self._i]
        row = self._bars.iloc[self._i]
        self._i += 1
        return ts, {"open": float(row.open), "high": float(row.high),
                    "low": float(row.low), "close": float(row.close),
                    "volume": float(row.volume)}


class UnwiredLiveMarketDataProvider(MarketDataProvider):
    def next_bar(self):
        raise RuntimeError(
            "No authenticated, network-connected market-data client is "
            "wired into this paper-trading engine instance. See "
            "PAPER_TRADING.md for the integration point."
        )
