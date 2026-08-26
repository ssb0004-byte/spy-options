import importlib

from spy_options import config as config_module
from spy_options.config import LiveTradingGuard


def test_default_guard_is_disabled():
    guard = LiveTradingGuard()
    assert guard.enabled is False


def test_module_level_guard_defaults_disabled_without_env(monkeypatch):
    monkeypatch.delenv("LIVE_TRADING_ENABLED", raising=False)
    monkeypatch.delenv("LIVE_TRADING_CONFIRM", raising=False)
    assert LiveTradingGuard.from_environment().enabled is False


def test_flag_alone_without_confirm_phrase_is_not_enough(monkeypatch):
    monkeypatch.setenv("LIVE_TRADING_ENABLED", "true")
    monkeypatch.delenv("LIVE_TRADING_CONFIRM", raising=False)
    assert LiveTradingGuard.from_environment().enabled is False


def test_confirm_phrase_alone_without_flag_is_not_enough(monkeypatch):
    monkeypatch.delenv("LIVE_TRADING_ENABLED", raising=False)
    monkeypatch.setenv("LIVE_TRADING_CONFIRM", "I_UNDERSTAND_THIS_SENDS_REAL_ORDERS")
    assert LiveTradingGuard.from_environment().enabled is False


def test_both_flag_and_exact_confirm_phrase_enable_it(monkeypatch):
    monkeypatch.setenv("LIVE_TRADING_ENABLED", "true")
    monkeypatch.setenv("LIVE_TRADING_CONFIRM", "I_UNDERSTAND_THIS_SENDS_REAL_ORDERS")
    assert LiveTradingGuard.from_environment().enabled is True


def test_wrong_confirm_phrase_does_not_enable_it(monkeypatch):
    monkeypatch.setenv("LIVE_TRADING_ENABLED", "true")
    monkeypatch.setenv("LIVE_TRADING_CONFIRM", "yes please")
    assert LiveTradingGuard.from_environment().enabled is False


def test_import_time_guard_is_disabled_by_default():
    # Reload to make sure nothing in the test session leaked an env var into
    # the module-level singleton evaluated at import time.
    import os

    os.environ.pop("LIVE_TRADING_ENABLED", None)
    os.environ.pop("LIVE_TRADING_CONFIRM", None)
    reloaded = importlib.reload(config_module)
    assert reloaded.LIVE_TRADING_GUARD.enabled is False
