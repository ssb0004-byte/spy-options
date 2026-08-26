"""Immutable, append-only decision/trade journal.

Every entry, rejection, exit, and fill in the paper-trading engine is
recorded here. The journal exposes no update or delete method — the only
operation available on an existing record is reading it back.
"""
from __future__ import annotations

import json
from pathlib import Path

import pandas as pd

from .. import STRATEGY_VERSION


def _default(o):
    if isinstance(o, (pd.Timestamp,)):
        return o.isoformat()
    return str(o)


class Journal:
    def __init__(self, path: str | Path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        if not self.path.exists():
            self.path.touch()

    def record(self, event: dict) -> dict:
        enriched = {
            "recorded_at": pd.Timestamp.now("UTC").isoformat(),
            "strategy_version": STRATEGY_VERSION,
            **event,
        }
        with open(self.path, "a") as f:
            f.write(json.dumps(enriched, default=_default) + "\n")
        return enriched

    def read_all(self) -> list[dict]:
        if not self.path.exists():
            return []
        out = []
        with open(self.path) as f:
            for line in f:
                line = line.strip()
                if line:
                    out.append(json.loads(line))
        return out
