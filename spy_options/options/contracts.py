"""Frozen option contract-selection policy (STRATEGY_SPEC.md §9-10)."""
from __future__ import annotations

import datetime as dt
from dataclasses import dataclass

from ..config import FROZEN_OPTION_POLICIES, MAX_SPREAD_PCT_OF_MID, PRIMARY_POLICY_NAME


@dataclass(frozen=True)
class ContractQuote:
    """One two-sided quote for one contract at one point in time."""

    symbol: str
    expiration: dt.date
    option_type: str  # "call" | "put"
    strike: float
    bid: float
    ask: float
    quote_time: object  # pandas.Timestamp, tz-aware
    underlying_price: float
    delta: float | None = None  # abs(delta) if known from listed Greeks
    volume: int | None = None
    open_interest: int | None = None

    @property
    def midpoint(self) -> float:
        return (self.bid + self.ask) / 2.0

    @property
    def spread_abs(self) -> float:
        return self.ask - self.bid

    @property
    def spread_pct_of_mid(self) -> float:
        mid = self.midpoint
        if mid <= 0:
            return float("inf")
        return self.spread_abs / mid

    @property
    def is_crossed(self) -> bool:
        return self.bid > self.ask


class RejectReason:
    ZERO_BID = "zero_bid"
    CROSSED_QUOTE = "crossed_quote"
    STALE_QUOTE = "stale_quote"
    WIDE_SPREAD = "spread_exceeds_max_pct"
    WRONG_TYPE = "wrong_option_type"


def passes_liquidity_filters(
    q: ContractQuote,
    *,
    max_spread_pct: float = MAX_SPREAD_PCT_OF_MID,
    now: object | None = None,
    staleness_seconds: float | None = None,
) -> tuple[bool, str | None]:
    if q.bid <= 0:
        return False, RejectReason.ZERO_BID
    if q.is_crossed:
        return False, RejectReason.CROSSED_QUOTE
    if q.spread_pct_of_mid > max_spread_pct:
        return False, RejectReason.WIDE_SPREAD
    if now is not None and staleness_seconds is not None:
        age = (now - q.quote_time).total_seconds() if hasattr(now - q.quote_time, "total_seconds") else None
        if age is not None and age > staleness_seconds:
            return False, RejectReason.STALE_QUOTE
    return True, None


def days_to_expiration(quote_time, expiration: dt.date) -> int:
    ref_date = quote_time.date() if hasattr(quote_time, "date") else quote_time
    return (expiration - ref_date).days


def select_contract(
    candidates: list[ContractQuote],
    *,
    option_type: str,
    target_dte: int,
    target_abs_delta: float,
    max_spread_pct: float = MAX_SPREAD_PCT_OF_MID,
    now=None,
    staleness_seconds: float | None = None,
) -> tuple[ContractQuote | None, list[dict]]:
    """Pick the frozen-policy contract: nearest to target_dte, then closest
    |delta| to target, tie-broken by tightest spread among comparable
    candidates. Returns (selected_or_None, rejected_audit_rows).

    rejected_audit_rows records every candidate considered and why it was
    or was not selected, for the paper-trading journal.
    """
    rejected: list[dict] = []
    same_type = [c for c in candidates if c.option_type == option_type]
    for c in candidates:
        if c.option_type != option_type:
            rejected.append({"contract": c, "reason": RejectReason.WRONG_TYPE})

    if not same_type:
        return None, rejected

    # Group by expiration, pick expiration(s) nearest target_dte.
    by_dte: dict[int, list[ContractQuote]] = {}
    for c in same_type:
        dte = days_to_expiration(now or c.quote_time, c.expiration)
        by_dte.setdefault(dte, []).append(c)

    ranked_dtes = sorted(by_dte.keys(), key=lambda d: abs(d - target_dte))

    for dte in ranked_dtes:
        pool = by_dte[dte]
        liquid_pool = []
        for c in pool:
            ok, reason = passes_liquidity_filters(
                c, max_spread_pct=max_spread_pct, now=now, staleness_seconds=staleness_seconds
            )
            if ok:
                liquid_pool.append(c)
            else:
                rejected.append({"contract": c, "reason": reason})
        if not liquid_pool:
            continue  # try next-nearest expiration

        def sort_key(c: ContractQuote):
            delta_for_ranking = c.delta if c.delta is not None else float("nan")
            delta_diff = abs(abs(delta_for_ranking) - target_abs_delta)
            return (delta_diff, c.spread_pct_of_mid)

        liquid_pool_with_delta = [c for c in liquid_pool if c.delta is not None]
        pool_to_rank = liquid_pool_with_delta or liquid_pool
        best = min(pool_to_rank, key=sort_key)
        for c in liquid_pool:
            if c is not best:
                rejected.append({"contract": c, "reason": "not_closest_to_target_delta_or_spread"})
        return best, rejected

    return None, rejected


def policy_by_name(name: str) -> dict:
    for p in FROZEN_OPTION_POLICIES:
        if p["name"] == name:
            return p
    raise KeyError(f"unknown frozen policy: {name}")


def primary_policy() -> dict:
    return policy_by_name(PRIMARY_POLICY_NAME)
