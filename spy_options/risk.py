"""Position sizing, commissions, and the daily loss circuit breaker.

STRATEGY_SPEC.md §12: long premium only, max 0.50% of equity in premium per
new trade (100% of premium treated as capital at risk), one concurrent
position, no pyramiding/averaging, optional 1.5% daily loss breaker that
only suppresses new entries — it can never create one.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from .config import (
    COMMISSION_PER_CONTRACT,
    DAILY_LOSS_CIRCUIT_BREAKER_PCT,
    MAX_PREMIUM_PCT_OF_EQUITY,
    REG_FEES_PER_CONTRACT,
)


def commission_and_fees(n_contracts: int) -> float:
    if n_contracts <= 0:
        return 0.0
    return n_contracts * (COMMISSION_PER_CONTRACT + REG_FEES_PER_CONTRACT)


def size_position(
    equity: float,
    option_price_per_contract: float,
    contract_multiplier: float = 100.0,
    max_pct_of_equity: float = MAX_PREMIUM_PCT_OF_EQUITY,
) -> dict:
    """Compute the number of contracts for a new long-premium trade.

    Sizes strictly off the premium (full loss-of-premium risk), floor
    rounding to whole contracts, commissions layered on top (commissions do
    not eat into the 0.50% premium budget — they are counted separately as
    a cost, not as risk capital, consistent with "treat the entire premium
    as capital at risk for sizing purposes").
    """
    if equity <= 0 or option_price_per_contract <= 0:
        return {"n_contracts": 0, "premium_budget": 0.0, "premium_used": 0.0, "commission": 0.0}
    budget = equity * max_pct_of_equity
    per_contract_cost = option_price_per_contract * contract_multiplier
    n = int(budget // per_contract_cost)
    n = max(n, 0)
    premium_used = n * per_contract_cost
    return {
        "n_contracts": n,
        "premium_budget": budget,
        "premium_used": premium_used,
        "commission": commission_and_fees(n),
    }


@dataclass
class DailyLossCircuitBreaker:
    """Tracks intraday realized + open loss against equity; blocks new
    entries for the rest of the session once breached. Never generates or
    modifies a signal — only gates whether risk.size_position is allowed to
    be called for a *new* entry.
    """

    threshold_pct: float = DAILY_LOSS_CIRCUIT_BREAKER_PCT
    _session_start_equity: float | None = field(default=None, repr=False)
    _tripped: bool = field(default=False, repr=False)

    def start_session(self, equity: float) -> None:
        self._session_start_equity = equity
        self._tripped = False

    def update(self, current_equity: float) -> bool:
        """Call with mark-to-market equity (realized + open). Returns
        whether the breaker is (now) tripped."""
        if self._session_start_equity is None:
            raise RuntimeError("start_session() must be called first")
        loss_pct = (self._session_start_equity - current_equity) / self._session_start_equity
        if loss_pct >= self.threshold_pct:
            self._tripped = True
        return self._tripped

    @property
    def entries_allowed(self) -> bool:
        return not self._tripped
