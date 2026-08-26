"""spy_options: SPY Noise-Area intraday momentum strategy.

Signal engine + underlying backtest + options execution layer + paper
trading scaffold, implementing the frozen rules in STRATEGY_SPEC.md.
"""

__version__ = "0.1.0"

#: Hash-like tag identifying the frozen rule set this code implements.
#: Bump this manually (and note it in RESEARCH_LEDGER.md) any time a rule in
#: STRATEGY_SPEC.md changes. Recorded on every paper-trading journal entry.
STRATEGY_VERSION = "noise-area-v1.0-frozen-2026-08-26"
