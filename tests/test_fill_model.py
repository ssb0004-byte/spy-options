import datetime as dt

import pandas as pd
import pytest

from spy_options.options.contracts import ContractQuote
from spy_options.options.fill_model import adverse_fill_price, simulate_fill
from spy_options.risk import commission_and_fees


def make_quote(bid=1.00, ask=1.20):
    return ContractQuote(
        symbol="SPY", expiration=dt.date(2026, 8, 21), option_type="call", strike=550.0,
        bid=bid, ask=ask, quote_time=pd.Timestamp("2026-08-20 10:00", tz="America/New_York"),
        underlying_price=549.0, delta=0.55,
    )


def test_optimistic_fills_at_midpoint():
    qte = make_quote()
    assert adverse_fill_price(qte, "buy", "optimistic") == pytest.approx(1.10)
    assert adverse_fill_price(qte, "sell", "optimistic") == pytest.approx(1.10)


def test_realistic_buy_pushed_toward_ask_by_25pct_half_spread():
    qte = make_quote(bid=1.00, ask=1.20)  # mid=1.10, half_spread=0.10
    assert adverse_fill_price(qte, "buy", "realistic") == pytest.approx(1.10 + 0.25 * 0.10)
    assert adverse_fill_price(qte, "sell", "realistic") == pytest.approx(1.10 - 0.25 * 0.10)


def test_conservative_buy_pushed_toward_ask_by_50pct_half_spread():
    qte = make_quote(bid=1.00, ask=1.20)
    assert adverse_fill_price(qte, "buy", "conservative") == pytest.approx(1.10 + 0.50 * 0.10)
    assert adverse_fill_price(qte, "sell", "conservative") == pytest.approx(1.10 - 0.50 * 0.10)


def test_conservative_worse_than_realistic_worse_than_optimistic_for_buyer():
    qte = make_quote(bid=1.00, ask=1.20)
    p_opt = adverse_fill_price(qte, "buy", "optimistic")
    p_real = adverse_fill_price(qte, "buy", "realistic")
    p_cons = adverse_fill_price(qte, "buy", "conservative")
    assert p_opt < p_real < p_cons


def test_simulate_fill_includes_commission_and_total_cost_sign():
    qte = make_quote(bid=1.00, ask=1.20)
    fill = simulate_fill(qte, side="buy", model="realistic", n_contracts=2)
    assert fill.commission == pytest.approx(commission_and_fees(2))
    assert fill.n_contracts == 2
    assert fill.total_cost > 0  # buying costs cash

    fill_sell = simulate_fill(qte, side="sell", model="realistic", n_contracts=2)
    assert fill_sell.total_cost < fill.total_cost  # selling brings cash in (net of commission)


def test_commission_zero_for_zero_contracts():
    assert commission_and_fees(0) == 0.0
