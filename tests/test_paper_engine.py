import datetime as dt

import pandas as pd
import pytest

from spy_options.options.contracts import ContractQuote
from spy_options.options.data_provider import DataUnavailableError, LiveOptionChainProvider
from spy_options.paper.broker import PaperBrokerAdapter
from spy_options.paper.engine import PaperTradingEngine
from spy_options.paper.journal import Journal
from spy_options.risk import DailyLossCircuitBreaker
from tests.conftest import make_flat_history, make_session_bars

START = dt.date(2024, 1, 2)
OPEN = 100.0
POLICY = {"name": "1DTE_delta055_PRIMARY", "target_dte": 1, "target_abs_delta": 0.55}


class FakeLiveChainProvider(LiveOptionChainProvider):
    """Test double: the caller sets `current_ts` before each on_bar so the
    "live" chain returned matches whatever moment the engine is evaluating."""

    def __init__(self):
        self.chain_by_ts: dict[pd.Timestamp, list[ContractQuote]] = {}
        self.current_ts: pd.Timestamp | None = None
        self.raise_unavailable = False

    def set_chain(self, ts, chain):
        self.chain_by_ts[ts] = chain

    def get_live_chain(self, underlying):
        if self.raise_unavailable:
            raise DataUnavailableError("test_forced_unavailable")
        return self.chain_by_ts.get(self.current_ts, [])


def _next_session_date(history: pd.DataFrame) -> dt.date:
    from spy_options.timeutil import trading_schedule

    last = max(pd.DatetimeIndex(history.index).tz_convert("America/New_York").date)
    sched = trading_schedule(str(last), str(last + dt.timedelta(days=10)))
    sessions = [d.date() for d in sched.index]
    return sessions[sessions.index(last) + 1]


def q(ts, option_type, strike, bid, ask, delta=0.55, expiration=None):
    return ContractQuote(
        symbol="SPY", expiration=expiration or (ts.date() + dt.timedelta(days=1)),
        option_type=option_type, strike=strike, bid=bid, ask=ask, quote_time=ts,
        underlying_price=OPEN, delta=delta,
    )


def _make_engine(tmp_path, chain_provider, circuit_breaker=None):
    journal = Journal(tmp_path / "journal.jsonl")
    broker = PaperBrokerAdapter(journal=journal)
    engine = PaperTradingEngine(
        option_chain=chain_provider, broker=broker, journal=journal, policy=POLICY,
        fill_model="optimistic", starting_equity=100_000.0, circuit_breaker=circuit_breaker,
    )
    return engine, broker, journal


def test_engine_enters_and_exits_through_full_checkpoint_cycle(tmp_path):
    warm = make_flat_history(14, START, OPEN, 0.001)
    test_day = _next_session_date(warm)
    bars_today = make_session_bars(
        test_day, OPEN, price_at={"10:00": OPEN * 1.02, "10:30": OPEN}
    )

    chain_provider = FakeLiveChainProvider()
    engine, broker, journal = _make_engine(tmp_path, chain_provider)
    engine._bars = warm  # pre-seed warm-up history directly; on_bar exercises only the test day
    engine.start_session(equity=100_000.0)

    entry_ts = pd.Timestamp(f"{test_day} 10:00", tz="America/New_York")
    exit_ts = pd.Timestamp(f"{test_day} 10:30", tz="America/New_York")
    contract_expiration = entry_ts.date() + dt.timedelta(days=1)
    chain_provider.set_chain(entry_ts, [q(entry_ts, "call", 102.0, 0.99, 1.01, expiration=contract_expiration)])
    chain_provider.set_chain(
        exit_ts, [q(exit_ts, "call", 102.0, 0.49, 0.51, expiration=contract_expiration)]
    )  # same contract, marked down, quoted fresh at exit time

    for ts, row in bars_today.iterrows():
        chain_provider.current_ts = ts
        engine.on_bar(ts, {"open": row.open, "high": row.high, "low": row.low,
                            "close": row.close, "volume": row.volume})

    assert broker.open_position is None  # closed by the 10:30 trail exit
    events = journal.read_all()
    fills = [e for e in events if e["event"] == "order_filled"]
    assert [f["side"] for f in fills] == ["buy", "sell"]
    decisions = [e for e in events if e["event"] == "checkpoint_decision"]
    actions = {d["checkpoint"]: d["action"] for d in decisions}
    assert actions["10:00"] == "enter_long"
    assert actions["10:30"] == "exit_long"


def test_engine_force_flattens_at_1555_regardless_of_signal(tmp_path):
    warm = make_flat_history(14, START, OPEN, 0.001)
    test_day = _next_session_date(warm)
    # Enter at 15:30 (last checkpoint) and never get a normal exit signal.
    bars_today = make_session_bars(test_day, OPEN, price_at={"15:30": OPEN * 1.02})

    chain_provider = FakeLiveChainProvider()
    engine, broker, journal = _make_engine(tmp_path, chain_provider)
    engine._bars = warm
    engine.start_session(equity=100_000.0)

    entry_ts = pd.Timestamp(f"{test_day} 15:30", tz="America/New_York")
    force_ts = pd.Timestamp(f"{test_day} 15:55", tz="America/New_York")
    contract_expiration = entry_ts.date() + dt.timedelta(days=1)
    chain_provider.set_chain(entry_ts, [q(entry_ts, "call", 102.0, 0.99, 1.01, expiration=contract_expiration)])
    chain_provider.set_chain(
        force_ts, [q(force_ts, "call", 102.0, 1.09, 1.11, expiration=contract_expiration)]
    )

    for ts, row in bars_today.iterrows():
        chain_provider.current_ts = ts
        engine.on_bar(ts, {"open": row.open, "high": row.high, "low": row.low,
                            "close": row.close, "volume": row.volume})

    assert broker.open_position is None
    events = journal.read_all()
    fills = [e for e in events if e["event"] == "order_filled"]
    assert fills[-1]["side"] == "sell"
    assert fills[-1]["reason"] == "forced_close_1555"


def test_engine_restart_mid_session_does_not_duplicate_entry(tmp_path):
    warm = make_flat_history(14, START, OPEN, 0.001)
    test_day = _next_session_date(warm)
    bars_today = make_session_bars(test_day, OPEN, price_at={"10:00": OPEN * 1.02})

    chain_provider = FakeLiveChainProvider()
    journal_path = tmp_path / "journal.jsonl"
    journal = Journal(journal_path)
    broker1 = PaperBrokerAdapter(journal=journal)
    engine1 = PaperTradingEngine(option_chain=chain_provider, broker=broker1, journal=journal,
                                  policy=POLICY, fill_model="optimistic", starting_equity=100_000.0)
    engine1._bars = warm
    engine1.start_session(equity=100_000.0)

    entry_ts = pd.Timestamp(f"{test_day} 10:00", tz="America/New_York")
    chain_provider.set_chain(entry_ts, [q(entry_ts, "call", 102.0, 0.99, 1.01)])
    chain_provider.current_ts = entry_ts
    row0 = bars_today.loc[entry_ts]
    engine1.on_bar(entry_ts, {"open": row0.open, "high": row0.high, "low": row0.low,
                              "close": row0.close, "volume": row0.volume})
    assert broker1.open_position is not None

    # "Restart": brand-new broker/engine reconstructed purely from the journal.
    broker2 = PaperBrokerAdapter.from_journal(journal)
    assert broker2.open_position is not None
    engine2 = PaperTradingEngine(option_chain=chain_provider, broker=broker2, journal=journal,
                                  policy=POLICY, fill_model="optimistic", starting_equity=100_000.0)
    engine2._bars = pd.concat([warm, bars_today.loc[[entry_ts]]]).sort_index()

    # Re-deliver the exact same 10:00 bar (e.g. a feed replay after restart).
    engine2.on_bar(entry_ts, {"open": row0.open, "high": row0.high, "low": row0.low,
                              "close": row0.close, "volume": row0.volume})

    fills = [e for e in journal.read_all() if e["event"] == "order_filled"]
    buys = [f for f in fills if f["side"] == "buy"]
    assert len(buys) == 1  # no duplicate entry after restart + replay


def test_engine_skips_all_checkpoints_once_kill_switch_engaged(tmp_path):
    warm = make_flat_history(14, START, OPEN, 0.001)
    test_day = _next_session_date(warm)
    bars_today = make_session_bars(test_day, OPEN, price_at={"10:00": OPEN * 1.02})

    chain_provider = FakeLiveChainProvider()
    engine, broker, journal = _make_engine(tmp_path, chain_provider)
    engine._bars = warm
    broker.kill_switch.engage(reason="test_stop")

    entry_ts = pd.Timestamp(f"{test_day} 10:00", tz="America/New_York")
    chain_provider.set_chain(entry_ts, [q(entry_ts, "call", 102.0, 0.99, 1.01)])
    chain_provider.current_ts = entry_ts
    row0 = bars_today.loc[entry_ts]
    engine.on_bar(entry_ts, {"open": row0.open, "high": row0.high, "low": row0.low,
                             "close": row0.close, "volume": row0.volume})

    assert broker.open_position is None
    events = journal.read_all()
    assert any(e["event"] == "checkpoint_skipped" and e["reason"] == "kill_switch_engaged" for e in events)
    assert not any(e["event"] == "order_filled" for e in events)


def test_engine_respects_daily_circuit_breaker_for_new_entries(tmp_path):
    warm = make_flat_history(14, START, OPEN, 0.001)
    test_day = _next_session_date(warm)
    bars_today = make_session_bars(test_day, OPEN, price_at={"10:00": OPEN * 1.02})

    chain_provider = FakeLiveChainProvider()
    breaker = DailyLossCircuitBreaker(threshold_pct=0.015)
    engine, broker, journal = _make_engine(tmp_path, chain_provider, circuit_breaker=breaker)
    engine._bars = warm
    engine.start_session(equity=100_000.0)
    breaker.update(current_equity=98_000.0)  # simulate an already-tripped day
    assert not breaker.entries_allowed

    entry_ts = pd.Timestamp(f"{test_day} 10:00", tz="America/New_York")
    chain_provider.set_chain(entry_ts, [q(entry_ts, "call", 102.0, 0.99, 1.01)])
    chain_provider.current_ts = entry_ts
    row0 = bars_today.loc[entry_ts]
    engine.on_bar(entry_ts, {"open": row0.open, "high": row0.high, "low": row0.low,
                             "close": row0.close, "volume": row0.volume})

    assert broker.open_position is None
    events = journal.read_all()
    assert any(e["event"] == "entry_skipped" and e["reason"] == "circuit_breaker_tripped" for e in events)


def test_engine_handles_unavailable_live_chain_without_crashing(tmp_path):
    warm = make_flat_history(14, START, OPEN, 0.001)
    test_day = _next_session_date(warm)
    bars_today = make_session_bars(test_day, OPEN, price_at={"10:00": OPEN * 1.02})

    chain_provider = FakeLiveChainProvider()
    chain_provider.raise_unavailable = True
    engine, broker, journal = _make_engine(tmp_path, chain_provider)
    engine._bars = warm
    engine.start_session(equity=100_000.0)

    entry_ts = pd.Timestamp(f"{test_day} 10:00", tz="America/New_York")
    row0 = bars_today.loc[entry_ts]
    engine.on_bar(entry_ts, {"open": row0.open, "high": row0.high, "low": row0.low,
                             "close": row0.close, "volume": row0.volume})
    assert broker.open_position is None
    events = journal.read_all()
    assert any(e["event"] == "entry_skipped" and e["reason"] == "test_forced_unavailable" for e in events)
