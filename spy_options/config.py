"""Central configuration and the hard live-trading guard.

LIVE_TRADING_ENABLED must default to False and can only become True via an
explicit environment variable set outside of this codebase. No code path in
this package is permitted to flip it programmatically. See
spy_options.paper.broker.PaperBrokerAdapter for enforcement.
"""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from zoneinfo import ZoneInfo

NY_TZ = ZoneInfo("America/New_York")

SESSION_OPEN = "09:30:00"
SESSION_CLOSE = "16:00:00"
FORCE_FLAT_OPTIONS_TIME = "15:55:00"  # options implementation flattens early

CHECKPOINTS = (
    "10:00", "10:30", "11:00", "11:30", "12:00", "12:30",
    "13:00", "13:30", "14:00", "14:30", "15:00", "15:30",
)

SIGMA_LOOKBACK_SESSIONS = 14

# --- Risk management (STRATEGY_SPEC.md §12) ---------------------------------
MAX_PREMIUM_PCT_OF_EQUITY = 0.005      # 0.50% of equity per new trade
DAILY_LOSS_CIRCUIT_BREAKER_PCT = 0.015  # 1.50% of equity, optional overlay
MAX_CONCURRENT_POSITIONS = 1

# --- Liquidity filters (STRATEGY_SPEC.md §10) -------------------------------
MAX_SPREAD_PCT_OF_MID = 0.05
STALE_QUOTE_SECONDS_LIVE = 5.0

# --- Fill model adverse-execution fractions of half-spread (STRATEGY_SPEC.md §11)
FILL_MODEL_ADVERSE_FRACTION = {
    "optimistic": 0.00,
    "realistic": 0.25,
    "conservative": 0.50,
}

# --- Commissions / fees (documented assumption, see DATA_AUDIT.md) ---------
COMMISSION_PER_CONTRACT = 0.65   # typical retail options commission
REG_FEES_PER_CONTRACT = 0.05     # OCC/ORF/TAF approximation, documented estimate

# --- Frozen option-selection policies (STRATEGY_SPEC.md §9) ----------------
FROZEN_OPTION_POLICIES = (
    {"name": "1DTE_delta055_PRIMARY", "target_dte": 1, "target_abs_delta": 0.55},
    {"name": "0DTE_delta055", "target_dte": 0, "target_abs_delta": 0.55},
    {"name": "1DTE_delta065", "target_dte": 1, "target_abs_delta": 0.65},
    {"name": "2DTE_delta055", "target_dte": 2, "target_abs_delta": 0.55},
)
PRIMARY_POLICY_NAME = "1DTE_delta055_PRIMARY"


def _env_true(name: str) -> bool:
    return os.environ.get(name, "").strip().lower() in {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class LiveTradingGuard:
    """Hard configuration guard. Defaults to disabled, always.

    The application must refuse live execution regardless of any other
    configuration until this is deliberately overridden by an operator via
    the LIVE_TRADING_ENABLED environment variable AND the explicit
    confirmation phrase, both required. There is intentionally no
    programmatic setter.
    """

    enabled: bool = field(default=False)

    @staticmethod
    def from_environment() -> "LiveTradingGuard":
        env_flag = _env_true("LIVE_TRADING_ENABLED")
        confirm_phrase = os.environ.get("LIVE_TRADING_CONFIRM", "")
        enabled = env_flag and confirm_phrase == "I_UNDERSTAND_THIS_SENDS_REAL_ORDERS"
        return LiveTradingGuard(enabled=enabled)


LIVE_TRADING_GUARD = LiveTradingGuard.from_environment()
