import pytest

from spy_options.risk import DailyLossCircuitBreaker, commission_and_fees, size_position


def test_size_position_caps_at_half_percent_of_equity():
    out = size_position(equity=100_000, option_price_per_contract=2.00)  # $200/contract
    # budget = 100_000 * 0.005 = 500 -> floor(500/200) = 2 contracts
    assert out["n_contracts"] == 2
    assert out["premium_used"] == pytest.approx(400.0)
    assert out["premium_budget"] == pytest.approx(500.0)


def test_size_position_zero_when_single_contract_exceeds_budget():
    out = size_position(equity=10_000, option_price_per_contract=10.00)  # $1000/contract, budget=$50
    assert out["n_contracts"] == 0
    assert out["premium_used"] == 0.0


def test_size_position_commission_scales_with_contracts():
    out = size_position(equity=1_000_000, option_price_per_contract=1.00)
    assert out["commission"] == pytest.approx(commission_and_fees(out["n_contracts"]))


def test_circuit_breaker_trips_at_threshold_and_blocks_entries():
    cb = DailyLossCircuitBreaker(threshold_pct=0.015)
    cb.start_session(equity=100_000)
    assert cb.entries_allowed
    cb.update(current_equity=99_000)  # -1.0%, under threshold
    assert cb.entries_allowed
    cb.update(current_equity=98_400)  # -1.6%, breached
    assert not cb.entries_allowed


def test_circuit_breaker_resets_each_session():
    cb = DailyLossCircuitBreaker(threshold_pct=0.015)
    cb.start_session(equity=100_000)
    cb.update(current_equity=98_000)
    assert not cb.entries_allowed
    cb.start_session(equity=98_000)  # new session
    assert cb.entries_allowed


def test_circuit_breaker_never_creates_a_signal_only_gates_sizing():
    # This is a structural/documentation test: the breaker exposes only a
    # boolean gate, no method that could construct or emit a trade signal.
    cb = DailyLossCircuitBreaker()
    public_methods = {m for m in dir(cb) if not m.startswith("_")}
    assert public_methods.issubset({"start_session", "update", "entries_allowed", "threshold_pct"})
