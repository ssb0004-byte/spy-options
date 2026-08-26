"""Convert underlying-signal trades into option trades under a frozen
contract-selection policy, a fill model, and position sizing — or report
BLOCKED BY DATA rather than fabricating results (STRATEGY_SPEC.md §4)."""
from __future__ import annotations

from dataclasses import dataclass, field

from ..risk import size_position
from ..signal_engine import Trade as UnderlyingTrade
from .contracts import select_contract
from .data_provider import DataUnavailableError, HistoricalOptionQuoteProvider
from .fill_model import Fill, simulate_fill


@dataclass
class OptionTrade:
    underlying_trade_side: str
    option_type: str
    entry_time: object
    exit_time: object
    expiration: object
    strike: float
    entry_delta: float | None
    entry_bid: float
    entry_ask: float
    entry_fill: Fill
    exit_bid: float
    exit_ask: float
    exit_fill: Fill
    n_contracts: int
    dte_at_entry: int
    fill_model: str
    policy_name: str

    @property
    def pnl(self) -> float:
        gross = -self.entry_fill.total_cost - self.exit_fill.total_cost
        return gross

    @property
    def entry_spread_pct(self) -> float:
        mid = (self.entry_bid + self.entry_ask) / 2
        return (self.entry_ask - self.entry_bid) / mid if mid else float("nan")

    @property
    def exit_spread_pct(self) -> float:
        mid = (self.exit_bid + self.exit_ask) / 2
        return (self.exit_ask - self.exit_bid) / mid if mid else float("nan")


@dataclass
class BlockedResult:
    policy_name: str
    fill_model: str
    reason: str
    detail: str
    n_underlying_trades_attempted: int


def run_option_backtest(
    underlying_trades: list[UnderlyingTrade],
    provider: HistoricalOptionQuoteProvider,
    *,
    policy: dict,
    fill_model: str,
    starting_equity: float = 100_000.0,
) -> list[OptionTrade] | BlockedResult:
    """Returns a list[OptionTrade], or a BlockedResult the FIRST time the
    provider cannot supply a real quote — never a partial, silently-shrunk
    result presented as if it were the full sample.
    """
    equity = starting_equity
    out: list[OptionTrade] = []

    for i, ut in enumerate(underlying_trades):
        option_type = "call" if ut.side == "long" else "put"
        try:
            entry_chain = provider.get_quote_chain(underlying="SPY", as_of=ut.entry_time)
        except DataUnavailableError as e:
            return BlockedResult(
                policy_name=policy["name"], fill_model=fill_model, reason=e.reason,
                detail=e.detail, n_underlying_trades_attempted=i,
            )

        contract, _rejected = select_contract(
            entry_chain, option_type=option_type, target_dte=policy["target_dte"],
            target_abs_delta=policy["target_abs_delta"], now=ut.entry_time,
        )
        if contract is None:
            continue  # no eligible contract this trade; recorded as a skip, not a fabricated fill

        entry_quote = contract
        sizing = size_position(equity, entry_quote.midpoint)
        if sizing["n_contracts"] <= 0:
            continue
        entry_fill = simulate_fill(entry_quote, side="buy", model=fill_model, n_contracts=sizing["n_contracts"])

        try:
            exit_chain = provider.get_quote_chain(
                underlying="SPY", as_of=ut.exit_time, expiration=contract.expiration
            )
        except DataUnavailableError as e:
            return BlockedResult(
                policy_name=policy["name"], fill_model=fill_model, reason=e.reason,
                detail=e.detail, n_underlying_trades_attempted=i,
            )
        exit_quote = next(
            (c for c in exit_chain if c.strike == contract.strike and c.option_type == contract.option_type),
            None,
        )
        if exit_quote is None:
            continue
        exit_fill = simulate_fill(exit_quote, side="sell", model=fill_model, n_contracts=sizing["n_contracts"])

        ot = OptionTrade(
            underlying_trade_side=ut.side, option_type=option_type, entry_time=ut.entry_time,
            exit_time=ut.exit_time, expiration=contract.expiration, strike=contract.strike,
            entry_delta=contract.delta, entry_bid=entry_quote.bid, entry_ask=entry_quote.ask,
            entry_fill=entry_fill, exit_bid=exit_quote.bid, exit_ask=exit_quote.ask,
            exit_fill=exit_fill, n_contracts=sizing["n_contracts"],
            dte_at_entry=(contract.expiration - ut.entry_time.date()).days,
            fill_model=fill_model, policy_name=policy["name"],
        )
        out.append(ot)
        equity += ot.pnl

    return out
