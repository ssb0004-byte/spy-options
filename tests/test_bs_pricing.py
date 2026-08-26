import pytest

from spy_options.options.bs_pricing import BSInputs, bs_delta, bs_price, implied_vol_from_price


def test_call_put_parity_approx():
    import math

    x = BSInputs(spot=550, strike=550, t_years=1 / 365, rate=0.04, dividend_yield=0.013, iv=0.14)
    c = bs_price(x, "call")
    p = bs_price(x, "put")
    # Put-call parity: C - P = S*exp(-qT) - K*exp(-rT)
    lhs = c - p
    expected = x.spot * math.exp(-x.dividend_yield * x.t_years) - x.strike * math.exp(-x.rate * x.t_years)
    assert lhs == pytest.approx(expected, abs=1e-8)


def test_atm_call_delta_near_half():
    x = BSInputs(spot=550, strike=550, t_years=1 / 365, rate=0.04, dividend_yield=0.013, iv=0.14)
    d = bs_delta(x, "call")
    assert 0.45 < d < 0.55


def test_deep_itm_call_delta_near_one():
    x = BSInputs(spot=600, strike=500, t_years=1 / 365, rate=0.04, dividend_yield=0.013, iv=0.14)
    assert bs_delta(x, "call") > 0.95


def test_deep_otm_put_delta_near_zero():
    x = BSInputs(spot=600, strike=500, t_years=1 / 365, rate=0.04, dividend_yield=0.013, iv=0.14)
    d = bs_delta(x, "put")
    assert -0.05 <= d <= 0.0


def test_target_delta_055_call_is_slightly_itm():
    # For a short-dated call, delta 0.55 should correspond to a strike
    # slightly below spot (in-the-money), not above.
    x_atm = BSInputs(spot=550, strike=550, t_years=1 / 365, rate=0.04, dividend_yield=0.013, iv=0.14)
    x_itm = BSInputs(spot=550, strike=548, t_years=1 / 365, rate=0.04, dividend_yield=0.013, iv=0.14)
    assert bs_delta(x_itm, "call") > bs_delta(x_atm, "call")


def test_implied_vol_roundtrip():
    x = BSInputs(spot=550, strike=552, t_years=1 / 365, rate=0.04, dividend_yield=0.013, iv=0.16)
    price = bs_price(x, "call")
    recovered_iv = implied_vol_from_price(price, x, "call")
    assert recovered_iv == pytest.approx(0.16, abs=1e-4)
