"""Paper broker adapter: simulates fills only. Never sends a live order.

LiveBrokerAdapter exists solely to document and enforce the refusal — it is
not wired to any real brokerage API in this codebase, and its
submit_limit_order unconditionally raises regardless of
spy_options.config.LIVE_TRADING_GUARD. Implementing real order submission
is explicitly out of scope and must never happen as a side effect of any
configuration change made outside a deliberate future code change.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from ..config import STALE_QUOTE_SECONDS_LIVE
from ..options.contracts import ContractQuote, passes_liquidity_filters
from ..options.fill_model import Fill, simulate_fill
from .journal import Journal


@dataclass
class OrderIntent:
    idempotency_key: str
    side: str  # "buy" | "sell"
    contract: ContractQuote
    n_contracts: int
    fill_model: str
    reason: str = ""


@dataclass
class OrderResult:
    status: str  # "filled" | "rejected" | "duplicate_ignored"
    idempotency_key: str
    reason: str | None = None
    fill: Fill | None = None
    realized_pnl: float | None = None


class KillSwitch:
    """A manually-latched safety stop. Once engaged, no new orders are
    accepted until explicitly reset by an operator; it never resets itself."""

    def __init__(self):
        self._engaged = False
        self._reason = ""

    def engage(self, reason: str = "") -> None:
        self._engaged = True
        self._reason = reason

    def reset(self) -> None:
        self._engaged = False
        self._reason = ""

    @property
    def engaged(self) -> bool:
        return self._engaged

    @property
    def reason(self) -> str:
        return self._reason


class PaperBrokerAdapter:
    """Simulated broker: fills are computed by the fill model, never sent
    anywhere. Enforces: one concurrent position, duplicate-order rejection
    via idempotency key, stale-quote rejection, and a kill switch."""

    def __init__(
        self,
        journal: Journal,
        kill_switch: KillSwitch | None = None,
        staleness_seconds: float = STALE_QUOTE_SECONDS_LIVE,
    ):
        self.journal = journal
        self.kill_switch = kill_switch or KillSwitch()
        self.staleness_seconds = staleness_seconds
        self._seen_idempotency_keys: set[str] = set()
        self._open_fill: Fill | None = None
        self._open_contract: ContractQuote | None = None

    @property
    def open_position(self) -> Fill | None:
        return self._open_fill

    @property
    def open_contract(self) -> ContractQuote | None:
        return self._open_contract

    def submit_limit_order(self, intent: OrderIntent, now) -> OrderResult:
        if intent.idempotency_key in self._seen_idempotency_keys:
            result = OrderResult(status="duplicate_ignored", idempotency_key=intent.idempotency_key,
                                  reason="duplicate_idempotency_key")
            self.journal.record({"event": "order_duplicate_ignored", "idempotency_key": intent.idempotency_key,
                                  "side": intent.side, "timestamp": now})
            return result

        if self.kill_switch.engaged:
            result = OrderResult(status="rejected", idempotency_key=intent.idempotency_key,
                                  reason=f"kill_switch_engaged:{self.kill_switch.reason}")
            self.journal.record({"event": "order_rejected", "reason": result.reason,
                                  "idempotency_key": intent.idempotency_key, "timestamp": now})
            return result

        if intent.side == "buy" and self._open_fill is not None:
            result = OrderResult(status="rejected", idempotency_key=intent.idempotency_key,
                                  reason="max_concurrent_positions_exceeded")
            self.journal.record({"event": "order_rejected", "reason": result.reason,
                                  "idempotency_key": intent.idempotency_key, "timestamp": now})
            return result

        ok, reason = passes_liquidity_filters(
            intent.contract, now=now, staleness_seconds=self.staleness_seconds
        )
        if not ok:
            result = OrderResult(status="rejected", idempotency_key=intent.idempotency_key, reason=reason)
            self.journal.record({"event": "order_rejected", "reason": reason,
                                  "idempotency_key": intent.idempotency_key, "timestamp": now,
                                  "bid": intent.contract.bid, "ask": intent.contract.ask})
            return result

        fill = simulate_fill(intent.contract, side=intent.side, model=intent.fill_model,
                              n_contracts=intent.n_contracts)
        self._seen_idempotency_keys.add(intent.idempotency_key)

        realized_pnl = None
        if intent.side == "buy":
            self._open_fill = fill
            self._open_contract = intent.contract
        else:
            if self._open_fill is not None:
                realized_pnl = -self._open_fill.total_cost - fill.total_cost
            self._open_fill = None
            self._open_contract = None

        result = OrderResult(status="filled", idempotency_key=intent.idempotency_key, fill=fill,
                              realized_pnl=realized_pnl)

        self.journal.record({
            "event": "order_filled", "idempotency_key": intent.idempotency_key, "side": intent.side,
            "timestamp": now, "reason": intent.reason, "fill_price": fill.fill_price,
            "n_contracts": fill.n_contracts, "commission": fill.commission,
            "strike": intent.contract.strike, "expiration": intent.contract.expiration,
            "option_type": intent.contract.option_type, "bid": intent.contract.bid,
            "ask": intent.contract.ask, "delta": intent.contract.delta,
            "realized_pnl": realized_pnl,
        })
        return result

    @classmethod
    def from_journal(cls, journal: Journal, **kwargs) -> "PaperBrokerAdapter":
        """Reconstruct broker state (open position, seen idempotency keys)
        purely by replaying the immutable journal — restart/recovery."""
        adapter = cls(journal=journal, **kwargs)
        for event in journal.read_all():
            if event.get("event") == "order_filled":
                adapter._seen_idempotency_keys.add(event["idempotency_key"])
                if event["side"] == "buy":
                    adapter._open_fill = Fill(
                        model="recovered", side="buy", fill_price=event["fill_price"],
                        n_contracts=event["n_contracts"], commission=event["commission"],
                    )
                    adapter._open_contract = ContractQuote(
                        symbol="SPY", expiration=event["expiration"], option_type=event["option_type"],
                        strike=event["strike"], bid=event["bid"], ask=event["ask"],
                        quote_time=event["timestamp"], underlying_price=float("nan"), delta=event.get("delta"),
                    )
                else:
                    adapter._open_fill = None
                    adapter._open_contract = None
            elif event.get("event") in ("order_rejected", "order_duplicate_ignored"):
                # Rejections/duplicates never change position or idempotency
                # state beyond what a prior fill already established, but a
                # duplicate-ignored key must still be treated as seen so a
                # replayed resend after restart is rejected identically.
                if event.get("idempotency_key"):
                    adapter._seen_idempotency_keys.add(event["idempotency_key"])
        return adapter


class LiveBrokerAdapter:
    """Deliberately unimplemented. Exists only so the interface shape is
    visible; every call refuses, unconditionally, regardless of
    spy_options.config.LIVE_TRADING_GUARD. There is no code path in this
    package that sends a real order."""

    def submit_limit_order(self, intent: OrderIntent, now):
        raise RuntimeError(
            "Live trading is not implemented in this codebase. Only "
            "PaperBrokerAdapter (simulated fills) exists. This refusal is "
            "unconditional and does not consult LIVE_TRADING_GUARD."
        )
