"""Paper-trading engine: wires the (already-tested) signal engine to a live
option chain and a PaperBrokerAdapter, journaling every decision.

Design choice: rather than re-implementing entry/exit logic a second time
for "live" use (a classic source of backtest/live divergence), each
checkpoint re-runs the identical, already-unit-tested
`spy_options.signal_engine.run_signal_engine` over the bars accumulated so
far and acts on the resulting decision for *this* timestamp only. This
guarantees the paper engine can never drift from the frozen backtest logic.
"""
from __future__ import annotations

import datetime as dt

import pandas as pd

from ..config import CHECKPOINTS, FORCE_FLAT_OPTIONS_TIME
from ..options.contracts import select_contract
from ..options.data_provider import DataUnavailableError, LiveOptionChainProvider
from ..risk import DailyLossCircuitBreaker, size_position
from ..signal_engine import run_signal_engine
from ..timeutil import to_ny
from .broker import OrderIntent, PaperBrokerAdapter
from .journal import Journal

_FORCE_FLAT_TIME = dt.datetime.strptime(FORCE_FLAT_OPTIONS_TIME, "%H:%M:%S").time()

_BAR_COLUMNS = ["open", "high", "low", "close", "volume"]


class PaperTradingEngine:
    def __init__(
        self,
        option_chain: LiveOptionChainProvider,
        broker: PaperBrokerAdapter,
        journal: Journal,
        policy: dict,
        fill_model: str,
        starting_equity: float = 100_000.0,
        circuit_breaker: DailyLossCircuitBreaker | None = None,
    ):
        self.option_chain = option_chain
        self.broker = broker
        self.journal = journal
        self.policy = policy
        self.fill_model = fill_model
        self.equity = starting_equity
        self.circuit_breaker = circuit_breaker
        self._bars = pd.DataFrame(columns=_BAR_COLUMNS)
        self._bars.index.name = "timestamp"

    def start_session(self, equity: float | None = None) -> None:
        if equity is not None:
            self.equity = equity
        if self.circuit_breaker is not None:
            self.circuit_breaker.start_session(self.equity)
        self.journal.record({"event": "session_start", "equity": self.equity})

    def on_bar(self, ts: pd.Timestamp, bar: dict) -> None:
        # Normalize storage to a single tz (UTC) so repeated concats never
        # produce a mixed-offset object-dtype index.
        ts_utc = ts.tz_convert("UTC") if ts.tzinfo is not None else ts.tz_localize("UTC")
        row = pd.DataFrame([bar], index=pd.DatetimeIndex([ts_utc]))
        self._bars = pd.concat([self._bars, row]).sort_index()
        self._bars = self._bars[~self._bars.index.duplicated(keep="last")]

        hm = to_ny(ts).strftime("%H:%M")
        is_checkpoint = hm in CHECKPOINTS
        is_force_flat = to_ny(ts).time() == _FORCE_FLAT_TIME

        if not (is_checkpoint or is_force_flat):
            return

        if self.broker.kill_switch.engaged:
            self.journal.record({"event": "checkpoint_skipped", "reason": "kill_switch_engaged",
                                  "timestamp": ts})
            return

        if is_force_flat:
            if self.broker.open_contract is not None:
                self._close_position(ts, reason="forced_close_1555")
            return

        trades, decisions = run_signal_engine(self._bars, allow_immediate_reversal=False)
        if decisions.empty or decisions.iloc[-1]["timestamp"] != ts:
            return  # nothing evaluated at this exact bar (e.g. still in warm-up)

        last = decisions.iloc[-1]
        self.journal.record({"event": "checkpoint_decision", "timestamp": ts, **last.to_dict()})

        action = last["action"]
        if action in ("enter_long", "enter_short"):
            self._try_open(ts, side="call" if action == "enter_long" else "put", reason=action)
        elif action in ("exit_long", "exit_short", "reversal_close"):
            self._close_position(ts, reason=action)
        # "none" -> no-op.

    def _try_open(self, ts: pd.Timestamp, side: str, reason: str) -> None:
        if self.circuit_breaker is not None and not self.circuit_breaker.entries_allowed:
            self.journal.record({"event": "entry_skipped", "reason": "circuit_breaker_tripped",
                                  "timestamp": ts})
            return
        try:
            chain = self.option_chain.get_live_chain("SPY")
        except DataUnavailableError as e:
            self.journal.record({"event": "entry_skipped", "reason": e.reason, "detail": e.detail,
                                  "timestamp": ts})
            return

        contract, rejected = select_contract(
            chain, option_type=side, target_dte=self.policy["target_dte"],
            target_abs_delta=self.policy["target_abs_delta"], now=ts,
        )
        for r in rejected:
            self.journal.record({"event": "candidate_rejected", "timestamp": ts,
                                  "strike": r["contract"].strike, "reason": r["reason"]})
        if contract is None:
            self.journal.record({"event": "entry_skipped", "reason": "no_eligible_contract", "timestamp": ts})
            return

        sizing = size_position(self.equity, contract.midpoint)
        if sizing["n_contracts"] <= 0:
            self.journal.record({"event": "entry_skipped", "reason": "sizing_below_one_contract",
                                  "timestamp": ts})
            return

        intent = OrderIntent(
            idempotency_key=f"{ts.isoformat()}|{reason}|entry",
            side="buy", contract=contract, n_contracts=sizing["n_contracts"],
            fill_model=self.fill_model, reason=reason,
        )
        self.broker.submit_limit_order(intent, now=ts)

    def _close_position(self, ts: pd.Timestamp, reason: str) -> None:
        held = self.broker.open_contract
        if held is None:
            return
        try:
            chain = self.option_chain.get_live_chain("SPY")
        except DataUnavailableError as e:
            self.journal.record({"event": "exit_skipped", "reason": e.reason, "detail": e.detail,
                                  "timestamp": ts})
            return
        match = next(
            (c for c in chain if c.strike == held.strike and c.expiration == held.expiration
             and c.option_type == held.option_type),
            None,
        )
        if match is None:
            self.journal.record({"event": "exit_skipped", "reason": "held_contract_not_in_current_chain",
                                  "timestamp": ts})
            return
        n = self.broker.open_position.n_contracts
        intent = OrderIntent(
            idempotency_key=f"{ts.isoformat()}|{reason}|exit",
            side="sell", contract=match, n_contracts=n, fill_model=self.fill_model, reason=reason,
        )
        result = self.broker.submit_limit_order(intent, now=ts)
        if result.status == "filled" and result.realized_pnl is not None:
            self.equity += result.realized_pnl
            if self.circuit_breaker is not None:
                self.circuit_breaker.update(self.equity)
