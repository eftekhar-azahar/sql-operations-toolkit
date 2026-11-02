#!/usr/bin/env bash
# Build the schema, load synthetic data, create views and functions,
# run the tests, then print the analytics report.
#
# Usage:  ./run_all.sh [database]          (default database: itops_demo)
# Connection settings come from the usual PG* variables (PGHOST, PGPORT, PGUSER...).
set -euo pipefail

DB="${1:-itops_demo}"
cd "$(dirname "$0")"

createdb "$DB" 2>/dev/null || true
PSQL=(psql -X -q -v ON_ERROR_STOP=1 -d "$DB")

for f in sql/01_schema.sql sql/02_seed.sql sql/03_views.sql sql/04_functions.sql; do
    echo "-> $f"
    "${PSQL[@]}" -f "$f" 2>&1 | grep -v -e 'NOTICE' -e 'DETAIL' -e 'drop cascades' || true
done

echo "-> tests/test_toolkit.sql"
"${PSQL[@]}" -f tests/test_toolkit.sql 2>&1 | sed -n 's/.*NOTICE:  //p'

echo "-> sql/05_analytics.sql"
"${PSQL[@]}" -f sql/05_analytics.sql 2>&1 | grep -v '^psql.*NOTICE'
