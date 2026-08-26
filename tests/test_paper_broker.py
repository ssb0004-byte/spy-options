import datetime as dt

import pandas as pd
import pytest

from spy_options.options.contracts import ContractQuote
from spy_options.paper.broker import LiveBrokerAdapter, OrderIntent, PaperBrokerAdapter
from spy_options.paper.journal import Journal

NOW = pd.Timestamp("2026-08-20 10:00", tz="America/New_York")


def make_quote(bid=0.99, ask=1.01, quote_time=NOW, strike=550.0):
    return ContractQuote(
        symbol="SPY", expiration=dt.date(2026, 8, 21), option_type="call", strike=strike,
        bid=bid, ask=ask, quote_time=quote_time, underlying_price=549.0, delta=0.55,
    )


def make_broker(tmp_path, **kw) -> PaperBrokerAdapter:
    return PaperBrokerAdapter(journal=Journal(tmp_path / "journal.jsonl"), **kw)


def test_buy_then_sell_fills_and_reports_realized_pnl(tmp_path):
    b = make_broker(tmp_path)
    entry = OrderIntent("k1", "buy", make_quote(bid=0.99, ask=1.01), 1, "optimistic")
    r1 = b.submit_limit_order(entry, now=NOW)
    assert r1.status == "filled"
    assert b.open_position is not None

    exit_q = make_quote(bid=1.49, ask=1.51, quote_time=NOW + pd.Timedelta(minutes=30))
    exit_intent = OrderIntent("k2", "sell", exit_q, 1, "optimistic")
    r2 = b.submit_limit_order(exit_intent, now=NOW + pd.Timedelta(minutes=30))
    assert r2.status == "filled"
    assert b.open_position is None
    assert r2.realized_pnl == pytest.approx((1.50 - 1.00) * 100 - 2 * (0.65 + 0.05))


def test_duplicate_idempotency_key_rejected(tmp_path):
    b = make_broker(tmp_path)
    intent = OrderIntent("dup-key", "buy", make_quote(), 1, "optimistic")
    r1 = b.submit_limit_order(intent, now=NOW)
    r2 = b.submit_limit_order(intent, now=NOW)
    assert r1.status == "filled"
    assert r2.status == "duplicate_ignored"
    # Only one fill actually happened.
    fills = [e for e in b.journal.read_all() if e["event"] == "order_filled"]
    assert len(fills) == 1


def test_stale_quote_rejected(tmp_path):
    b = make_broker(tmp_path, staleness_seconds=5.0)
    stale_quote = make_quote(quote_time=NOW - pd.Timedelta(seconds=30))
    intent = OrderIntent("k1", "buy", stale_quote, 1, "optimistic")
    r = b.submit_limit_order(intent, now=NOW)
    assert r.status == "rejected"
    assert r.reason == "stale_quote"
    assert b.open_position is None


def test_kill_switch_blocks_new_orders(tmp_path):
    b = make_broker(tmp_path)
    b.kill_switch.engage(reason="operator_stop")
    r = b.submit_limit_order(OrderIntent("k1", "buy", make_quote(), 1, "optimistic"), now=NOW)
    assert r.status == "rejected"
    assert "kill_switch_engaged" in r.reason
    assert b.open_position is None


def test_kill_switch_reset_allows_orders_again(tmp_path):
    b = make_broker(tmp_path)
    b.kill_switch.engage()
    b.kill_switch.reset()
    r = b.submit_limit_order(OrderIntent("k1", "buy", make_quote(), 1, "optimistic"), now=NOW)
    assert r.status == "filled"


def test_max_one_concurrent_position_blocks_second_buy(tmp_path):
    b = make_broker(tmp_path)
    b.submit_limit_order(OrderIntent("k1", "buy", make_quote(), 1, "optimistic"), now=NOW)
    r2 = b.submit_limit_order(OrderIntent("k2", "buy", make_quote(strike=555), 1, "optimistic"), now=NOW)
    assert r2.status == "rejected"
    assert r2.reason == "max_concurrent_positions_exceeded"


def test_restart_recovery_reconstructs_open_position(tmp_path):
    path = tmp_path / "journal.jsonl"
    b1 = PaperBrokerAdapter(journal=Journal(path))
    b1.submit_limit_order(OrderIntent("entry-1", "buy", make_quote(), 3, "optimistic"), now=NOW)
    assert b1.open_position is not None

    # Simulate a process restart: brand-new adapter, same journal file.
    b2 = PaperBrokerAdapter.from_journal(Journal(path))
    assert b2.open_position is not None
    assert b2.open_position.n_contracts == 3
    assert b2.open_contract.strike == 550.0

    # A resend of the same entry order after restart must still be rejected.
    r = b2.submit_limit_order(OrderIntent("entry-1", "buy", make_quote(), 3, "optimistic"), now=NOW)
    assert r.status == "duplicate_ignored"


def test_restart_recovery_reconstructs_flat_state_after_full_round_trip(tmp_path):
    path = tmp_path / "journal.jsonl"
    b1 = PaperBrokerAdapter(journal=Journal(path))
    b1.submit_limit_order(OrderIntent("entry-1", "buy", make_quote(), 1, "optimistic"), now=NOW)
    b1.submit_limit_order(
        OrderIntent("exit-1", "sell", make_quote(bid=1.49, ask=1.51, quote_time=NOW + pd.Timedelta(minutes=30)),
                    1, "optimistic"),
        now=NOW + pd.Timedelta(minutes=30),
    )
    assert b1.open_position is None

    b2 = PaperBrokerAdapter.from_journal(Journal(path))
    assert b2.open_position is None
    assert b2.open_contract is None


def test_live_broker_adapter_always_refuses():
    live = LiveBrokerAdapter()
    with pytest.raises(RuntimeError, match="Live trading is not implemented"):
        live.submit_limit_order(OrderIntent("k", "buy", make_quote(), 1, "optimistic"), now=NOW)
