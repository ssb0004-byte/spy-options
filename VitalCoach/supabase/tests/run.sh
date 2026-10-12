#!/usr/bin/env bash
# Runs the database tests against a throwaway local Postgres (no Supabase account needed).
# Requires PostgreSQL server binaries (initdb/pg_ctl) and Docker (for the Swift fixture step).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PGBIN="${PGBIN:-$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)}"
WORK="$(mktemp -d)"
PORT="${PGPORT_TEST:-55432}"
RUN_AS=()
if [ "$(id -u)" = "0" ]; then chown -R postgres "$WORK"; RUN_AS=(runuser -u postgres --); fi
cleanup() { "${RUN_AS[@]}" "$PGBIN/pg_ctl" -D "$WORK/data" stop -m immediate >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT
"${RUN_AS[@]}" "$PGBIN/initdb" -D "$WORK/data" -U postgres -A trust >/dev/null
"${RUN_AS[@]}" "$PGBIN/pg_ctl" -D "$WORK/data" -o "-p $PORT -k $WORK" -l "$WORK/log" start -w >/dev/null
PSQL=(psql -h "$WORK" -p "$PORT" -U postgres -v ON_ERROR_STOP=1 -q)

createdb_and_migrate() {
  "${PSQL[@]}" -d postgres -c "drop database if exists $1" -c "create database $1" 2>/dev/null
  "${PSQL[@]}" -o /dev/null -d "$1" -f "$HERE/00_supabase_shim.sql"
  for m in "$ROOT"/supabase/migrations/*.sql; do "${PSQL[@]}" -o /dev/null -d "$1" -f "$m"; done
}

echo "== Migrations + RLS/behaviour tests"
createdb_and_migrate vc_rls
"${PSQL[@]}" -o /dev/null -d vc_rls -f "$HERE/10_rls_and_behaviour_test.sql" 2>&1 | sed 's/^psql:[^ ]* NOTICE:  /  /'

echo "== Swift ⇄ Postgres schema round-trip"
FIX="$WORK/fixtures"; mkdir -p "$FIX" "$WORK/rows"; chmod 777 "$FIX" "$WORK/rows"
docker run --rm -v "$ROOT/Packages/VitalCore:/pkg" -v vitalcore-build:/pkg/.build -v "$FIX:/fixtures" \
  -e VITALCORE_FIXTURE_DIR=/fixtures -w /pkg swift:6.1-noble swift test --filter SchemaFixtureTests >/dev/null
ORDER="user_profiles user_preferences user_goals consent_records health_measurements symptom_entries pain_entries user_substances substance_regimens actual_administrations adverse_effect_reports audit_events"
i=0; : > "$WORK/fixtures.tsv"
for t in $ORDER; do i=$((i+1)); printf '%s\t%s\t%s\n' "$t" "$i" "$(sed 's/\\/\\\\/g' "$FIX/$t.json")" >> "$WORK/fixtures.tsv"; done
createdb_and_migrate vc_fix
(cd "$WORK" && "${PSQL[@]}" -o /dev/null -d vc_fix -f "$HERE/20_fixture_roundtrip.sql" 2>&1 | sed 's/^psql:[^ ]* NOTICE:  /  /')
for t in $ORDER; do
  "${PSQL[@]}" -d vc_fix -At -c "select coalesce(json_agg(t), '[]') from public.$t t" > "$WORK/rows/$t.json"
done
docker run --rm -v "$ROOT/Packages/VitalCore:/pkg" -v vitalcore-build:/pkg/.build -v "$WORK/rows:/rows" -v "$FIX:/fixtures" -e VITALCORE_FIXTURE_DIR=/fixtures \
  -e VITALCORE_SERVER_ROWS_DIR=/rows -w /pkg swift:6.1-noble swift test --filter ServerRowDecodingTests 2>&1 | grep -E "✔ Test run|✘|error" || true
echo "== Done"
