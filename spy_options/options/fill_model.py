"""Fill models: never assume midpoint-only execution (STRATEGY_SPEC.md §11)."""
from __future__ import annotations

from dataclasses import dataclass

from ..config import FILL_MODEL_ADVERSE_FRACTION
from ..risk import commission_and_fees
from .contracts import ContractQuote

FILL_MODELS = ("optimistic", "realistic", "conservative")


@dataclass(frozen=True)
class Fill:
    model: str
    side: str          # "buy" | "sell"
    fill_price: float  # per-share option price (multiply by 100 * n_contracts for $)
    n_contracts: int
    commission: float

    @property
    def notional(self) -> float:
        return self.fill_price * 100.0 * self.n_contracts

    @property
    def total_cost(self) -> float:
        """Signed cash flow: positive = cash out (buy), negative = cash in (sell)."""
        base = self.notional if self.side == "buy" else -self.notional
        return base + self.commission


def adverse_fill_price(q: ContractQuote, side: str, model: str) -> float:
    """side: 'buy' (opening a long call/put) or 'sell' (closing it).

    Adverse execution moves the fill AWAY from the trader's favor by a
    fraction of the half-spread, applied identically on entry and exit —
    buying is pushed toward the ask, selling is pushed toward the bid.
    """
    if model not in FILL_MODEL_ADVERSE_FRACTION:
        raise ValueError(f"unknown fill model: {model}")
    frac = FILL_MODEL_ADVERSE_FRACTION[model]
    half_spread = q.spread_abs / 2.0
    mid = q.midpoint
    if side == "buy":
        return mid + frac * half_spread
    elif side == "sell":
        return mid - frac * half_spread
    raise ValueError("side must be 'buy' or 'sell'")


def simulate_fill(q: ContractQuote, side: str, model: str, n_contracts: int) -> Fill:
    price = adverse_fill_price(q, side, model)
    commission = commission_and_fees(n_contracts)
    return Fill(model=model, side=side, fill_price=price, n_contracts=n_contracts, commission=commission)
