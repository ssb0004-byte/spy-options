"""Black-Scholes pricing/delta, used only as a documented fallback when a
data source does not supply listed Greeks directly (STRATEGY_SPEC.md §9).

Assumptions (must be echoed into DATA_AUDIT.md / the research ledger for
every run that actually invokes this fallback):
  - European exercise approximation for a short-dated, liquid, cash-settled
    American option (standard, small documented bias for SPY).
  - Risk-free rate: a single constant per run, sourced from a 3-month T-bill
    proxy; never fit or backward-looking beyond the decision date.
  - Dividend yield: SPY trailing 12-month yield, held constant per run.
  - Volatility input: must be an as-of-the-decision-timestamp estimate
    (e.g. a trailing realized-vol window, or the data source's own current
    IV snapshot). Never a full-sample or forward-fit IV — that would leak
    future information into contract selection.
"""
from __future__ import annotations

import math
from dataclasses import dataclass

from scipy.stats import norm


@dataclass(frozen=True)
class BSInputs:
    spot: float
    strike: float
    t_years: float  # time to expiry in years, > 0
    rate: float      # continuously-compounded risk-free rate
    dividend_yield: float
    iv: float         # annualized volatility, as decimal (0.15 == 15%)


def _d1_d2(x: BSInputs) -> tuple[float, float]:
    if x.t_years <= 0 or x.iv <= 0 or x.spot <= 0 or x.strike <= 0:
        raise ValueError("t_years, iv, spot, and strike must all be > 0")
    d1 = (
        math.log(x.spot / x.strike)
        + (x.rate - x.dividend_yield + 0.5 * x.iv**2) * x.t_years
    ) / (x.iv * math.sqrt(x.t_years))
    d2 = d1 - x.iv * math.sqrt(x.t_years)
    return d1, d2


def bs_price(x: BSInputs, option_type: str) -> float:
    d1, d2 = _d1_d2(x)
    disc_q = math.exp(-x.dividend_yield * x.t_years)
    disc_r = math.exp(-x.rate * x.t_years)
    if option_type == "call":
        return x.spot * disc_q * norm.cdf(d1) - x.strike * disc_r * norm.cdf(d2)
    elif option_type == "put":
        return x.strike * disc_r * norm.cdf(-d2) - x.spot * disc_q * norm.cdf(-d1)
    raise ValueError("option_type must be 'call' or 'put'")


def bs_delta(x: BSInputs, option_type: str) -> float:
    d1, _ = _d1_d2(x)
    disc_q = math.exp(-x.dividend_yield * x.t_years)
    if option_type == "call":
        return disc_q * norm.cdf(d1)
    elif option_type == "put":
        return disc_q * (norm.cdf(d1) - 1.0)
    raise ValueError("option_type must be 'call' or 'put'")


def implied_vol_from_price(
    market_price: float, x: BSInputs, option_type: str,
    lo: float = 1e-4, hi: float = 5.0, tol: float = 1e-6, max_iter: int = 100,
) -> float:
    """Bisection search for IV given a market price (used only to back out
    IV from same-timestamp quotes when a data source gives price but not
    Greeks — never from a future or full-sample price)."""

    def price_at(iv: float) -> float:
        xi = BSInputs(x.spot, x.strike, x.t_years, x.rate, x.dividend_yield, iv)
        return bs_price(xi, option_type)

    p_lo, p_hi = price_at(lo), price_at(hi)
    if not (p_lo <= market_price <= p_hi):
        raise ValueError("market_price outside achievable BS price range for [lo, hi] vol bounds")
    for _ in range(max_iter):
        mid = (lo + hi) / 2
        p_mid = price_at(mid)
        if abs(p_mid - market_price) < tol:
            return mid
        if p_mid < market_price:
            lo = mid
        else:
            hi = mid
    return (lo + hi) / 2
