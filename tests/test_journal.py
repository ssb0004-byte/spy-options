import pandas as pd

from spy_options import STRATEGY_VERSION
from spy_options.paper.journal import Journal


def test_journal_records_and_reads_back(tmp_path):
    j = Journal(tmp_path / "journal.jsonl")
    j.record({"event": "a", "x": 1})
    j.record({"event": "b", "x": 2, "ts": pd.Timestamp("2026-01-01", tz="UTC")})
    rows = j.read_all()
    assert len(rows) == 2
    assert rows[0]["event"] == "a"
    assert rows[1]["strategy_version"] == STRATEGY_VERSION
    assert "recorded_at" in rows[0]


def test_journal_is_append_only_no_mutation_api():
    public = {m for m in dir(Journal) if not m.startswith("_")}
    assert public == {"record", "read_all"}


def test_journal_survives_across_instances(tmp_path):
    path = tmp_path / "journal.jsonl"
    Journal(path).record({"event": "first"})
    j2 = Journal(path)  # new instance, same file — simulates a process restart
    rows = j2.read_all()
    assert len(rows) == 1
    assert rows[0]["event"] == "first"
