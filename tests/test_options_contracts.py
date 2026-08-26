import datetime as dt

import pandas as pd

from spy_options.options.contracts import (
    ContractQuote,
    RejectReason,
    days_to_expiration,
    passes_liquidity_filters,
    select_contract,
)

NOW = pd.Timestamp("2026-08-20 14:00", tz="America/New_York")


def q(**kw) -> ContractQuote:
    base = dict(
        symbol="SPY", expiration=dt.date(2026, 8, 21), option_type="call", strike=550.0,
        bid=1.00, ask=1.10, quote_time=NOW, underlying_price=549.0, delta=0.55,
        volume=1000, open_interest=5000,
    )
    base.update(kw)
    return ContractQuote(**base)


def test_zero_bid_rejected():
    ok, reason = passes_liquidity_filters(q(bid=0.0))
    assert not ok and reason == RejectReason.ZERO_BID


def test_crossed_quote_rejected():
    ok, reason = passes_liquidity_filters(q(bid=1.20, ask=1.10))
    assert not ok and reason == RejectReason.CROSSED_QUOTE


def test_wide_spread_rejected_at_5pct_default():
    # mid = 1.05, spread = 0.10 -> 9.5% > 5%
    ok, reason = passes_liquidity_filters(q(bid=1.00, ask=1.10))
    assert not ok and reason == RejectReason.WIDE_SPREAD


def test_tight_spread_passes():
    # mid = 1.00, spread = 0.02 -> 2% <= 5%
    ok, reason = passes_liquidity_filters(q(bid=0.99, ask=1.01))
    assert ok and reason is None


def test_stale_quote_rejected():
    # Tight spread so the staleness check (not the spread check) is what trips.
    old = ContractQuote(**{**q(bid=0.99, ask=1.01).__dict__, "quote_time": NOW - pd.Timedelta(seconds=30)})
    ok, reason = passes_liquidity_filters(old, now=NOW, staleness_seconds=5.0)
    assert not ok and reason == RejectReason.STALE_QUOTE


def test_days_to_expiration():
    assert days_to_expiration(dt.date(2026, 8, 20), dt.date(2026, 8, 21)) == 1
    assert days_to_expiration(dt.date(2026, 8, 20), dt.date(2026, 8, 20)) == 0


def test_select_contract_picks_closest_delta_among_tight_spreads():
    candidates = [
        q(strike=545.0, delta=0.65, bid=5.00, ask=5.10),
        q(strike=550.0, delta=0.55, bid=2.00, ask=2.06),  # exact target delta
        q(strike=555.0, delta=0.45, bid=0.90, ask=0.96),
    ]
    best, rejected = select_contract(
        candidates, option_type="call", target_dte=1, target_abs_delta=0.55
    )
    assert best is not None
    assert best.strike == 550.0


def test_select_contract_tie_broken_by_tighter_spread():
    candidates = [
        q(strike=550.0, delta=0.55, bid=2.00, ask=2.10),  # 4.9% spread
        q(strike=551.0, delta=0.55, bid=2.00, ask=2.06),  # 2.9% spread, same delta distance
    ]
    best, _ = select_contract(candidates, option_type="call", target_dte=1, target_abs_delta=0.55)
    assert best.strike == 551.0


def test_select_contract_prefers_nearest_expiration_with_liquid_pool():
    near = q(expiration=dt.date(2026, 8, 21), strike=550.0, delta=0.55, bid=0.0, ask=2.10)  # illiquid: zero bid
    far = q(expiration=dt.date(2026, 8, 22), strike=550.0, delta=0.55, bid=2.00, ask=2.06)
    best, rejected = select_contract(
        [near, far], option_type="call", target_dte=1, target_abs_delta=0.55, now=NOW
    )
    assert best is far
    assert any(r["reason"] == RejectReason.ZERO_BID for r in rejected)


def test_select_contract_returns_none_when_no_liquid_candidate_at_any_expiration():
    candidates = [q(bid=0.0)]
    best, rejected = select_contract(candidates, option_type="call", target_dte=1, target_abs_delta=0.55)
    assert best is None
    assert len(rejected) >= 1


def test_select_contract_filters_wrong_option_type():
    candidates = [q(option_type="put", delta=0.55)]
    best, rejected = select_contract(candidates, option_type="call", target_dte=1, target_abs_delta=0.55)
    assert best is None
    assert any(r["reason"] == RejectReason.WRONG_TYPE for r in rejected)
