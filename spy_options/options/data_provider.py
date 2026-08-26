"""Historical and live option-quote provider interfaces.

This module intentionally does NOT fabricate option prices from SPY percent
moves or from a Black-Scholes surface fit after the fact. If no real
timestamped bid/ask history is reachable, `NullHistoricalOptionProvider`
raises `DataUnavailableError` and the orchestrator in option_backtest.py
must surface that as a BLOCKED result rather than manufacturing a number.
See DATA_AUDIT.md for exactly what was and was not reachable in this run.
"""
from __future__ import annotations

import abc
import datetime as dt

from .contracts import ContractQuote


class DataUnavailableError(RuntimeError):
    """Raised when a real, timestamped, two-sided option quote is not
    obtainable for the requested (underlying, as_of, expiration) — never
    caught-and-faked by a caller."""

    def __init__(self, reason: str, detail: str = ""):
        self.reason = reason
        self.detail = detail
        super().__init__(f"{reason}: {detail}" if detail else reason)


class HistoricalOptionQuoteProvider(abc.ABC):
    """Interface for a source of timestamped historical option quotes.

    A real implementation (Polygon, ThetaData, ORATS, Cboe DataShop, or an
    equivalent institutional feed) must return actual observed bid/ask
    (and ideally trade + Greeks) as of `as_of` — never an interpolation,
    never a same-day-forward-fill, never a value derived from a later
    timestamp.
    """

    @abc.abstractmethod
    def get_quote_chain(
        self, underlying: str, as_of: dt.datetime, expiration: dt.date | None = None
    ) -> list[ContractQuote]:
        raise NotImplementedError


class NullHistoricalOptionProvider(HistoricalOptionQuoteProvider):
    """The only historical option data source verified reachable in this
    execution environment is none: no institutional options-data API key
    is present in the environment, and general internet egress is
    restricted to pypi.org/npm/github/anthropic domains (see
    DATA_AUDIT.md). The one live connector available (Robinhood MCP)
    exposes only the CURRENT option chain and OHLC bars for CURRENTLY
    LISTED instruments — it does not serve historical bid/ask time series
    for contracts from prior years, so it cannot support a 2018-2026
    options backtest either. This class documents that fact by raising
    rather than ever returning a plausible-looking synthetic quote.
    """

    def __init__(self, reason: str = "no_institutional_options_data_provider_reachable"):
        self._reason = reason

    def get_quote_chain(self, underlying, as_of, expiration=None):
        raise DataUnavailableError(
            self._reason,
            detail=(
                f"requested {underlying} option chain as of {as_of} "
                f"(expiration={expiration}); no historical option quote "
                "source is configured or reachable in this environment. "
                "See DATA_AUDIT.md."
            ),
        )


class InMemoryReplayOptionProvider(HistoricalOptionQuoteProvider):
    """Deterministic provider backed by a preloaded quote cache. Used by
    unit tests, and usable in live paper trading if fed by a real snapshot
    cache populated from an authenticated broker session.

    cache maps (underlying, as_of.isoformat(timespec='minutes')) ->
    list[ContractQuote].
    """

    def __init__(self, cache: dict[tuple[str, str], list[ContractQuote]]):
        self._cache = cache

    @staticmethod
    def _key_ts(as_of) -> str:
        ts = as_of
        if getattr(ts, "tzinfo", None) is not None:
            ts = ts.tz_convert("America/New_York")
        return ts.strftime("%Y-%m-%dT%H:%M")

    def get_quote_chain(self, underlying, as_of, expiration=None):
        key = (underlying, self._key_ts(as_of))
        if key not in self._cache:
            raise DataUnavailableError(
                "no_cached_quote_for_timestamp",
                detail=f"no preloaded quotes for {key}",
            )
        chain = self._cache[key]
        if expiration is not None:
            chain = [c for c in chain if c.expiration == expiration]
        return chain


class LiveOptionChainProvider(abc.ABC):
    """Interface for the paper-trading engine's live chain lookups. A real
    implementation wires an authenticated, network-connected broker/data
    client. This sandboxed session can reach live SPY option data only
    through the interactive Robinhood MCP tool boundary (a human-in-the-loop
    tool call from the orchestrating agent), not from unattended Python
    code running inside this package — so autonomous 24/7 paper trading
    requires deploying this package where such a client is available. See
    PAPER_TRADING.md.
    """

    @abc.abstractmethod
    def get_live_chain(self, underlying: str) -> list[ContractQuote]:
        raise NotImplementedError


class UnwiredLiveOptionChainProvider(LiveOptionChainProvider):
    def get_live_chain(self, underlying: str) -> list[ContractQuote]:
        raise DataUnavailableError(
            "live_option_chain_provider_not_wired",
            detail=(
                "No authenticated, network-connected broker/data client is "
                "wired into this paper-trading engine instance. Provide a "
                "concrete LiveOptionChainProvider (see PAPER_TRADING.md) "
                "before running the live loop."
            ),
        )
