#!/usr/bin/env bash
set -Eeuo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "${1:?Usage: run_lab.sh OUTPUT_DIRECTORY}"
cd "$1"
root=$PWD
export PGHOST="$root/socket" PGPORT=55447 PGUSER=postgres PGDATABASE=backup_lab
export LC_ALL=C.UTF-8
mkdir -m 700 socket wal_archive
initdb -D source -U postgres -A trust --no-locale -E UTF8 > init.log
cat >> source/postgresql.conf <<CONF
listen_addresses = ''
port = 55447
unix_socket_directories = '$PGHOST'
timezone = 'Europe/Moscow'
shared_preload_libraries = 'pg_stat_statements'
CONF
cleanup() {
  for instance in source source-offline restored; do
    if [[ -f "$instance/postmaster.pid" ]]; then pg_ctl -D "$instance" stop -m fast || true; fi
  done
}
trap cleanup EXIT
pg_ctl -D source -l source.log start
createdb
sql() { printf '\n$ psql\n%s\n' "$1"; psql -X -v ON_ERROR_STOP=1 -c "$1"; }

psql -X -v ON_ERROR_STOP=1 -a > 01.log 2>&1 <<'SQL'
\conninfo
\l+
\set ECHO queries
CREATE TABLE test_monitor (id integer PRIMARY KEY, payload text NOT NULL);
INSERT INTO test_monitor SELECT id, md5(id::text) FROM generate_series(1, 1000) id;
\dt+ public.test_monitor
\x
SELECT id, payload FROM test_monitor WHERE id = 1;
SQL

{
sql 'CREATE EXTENSION pg_stat_statements;'
sql 'SELECT pg_stat_statements_reset();'
for id in 1 2 3 4 5; do sql "SELECT payload FROM test_monitor WHERE id = $id;"; done
sql 'SELECT sum(a.id + b.id) FROM test_monitor a CROSS JOIN test_monitor b;'
sql 'SELECT count(*) FROM test_monitor WHERE id > 500;'
sql "SELECT query, calls, round(total_exec_time::numeric, 3) AS total_ms,
round(mean_exec_time::numeric, 3) AS mean_ms FROM pg_stat_statements
WHERE query LIKE 'SELECT%test_monitor%' AND query NOT LIKE '%pg_stat_statements%'
ORDER BY total_exec_time DESC LIMIT 3;"
} > 02.log 2>&1
sql 'EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM test_monitor WHERE id > 500;' > 03.log 2>&1

{
sql 'CREATE TABLE orders(id integer PRIMARY KEY, amount integer);
CREATE TABLE order_notes(id integer PRIMARY KEY, note text);
INSERT INTO orders VALUES (1, 700), (2, 900), (3, 1200);
INSERT INTO order_notes VALUES (1, '\''initial'\'');'
echo '$ pg_dump -Fd -j 4 -t public.orders -t public.order_notes -f backup_dir backup_lab'
pg_dump -Fd -j 4 -t public.orders -t public.order_notes -f backup_dir backup_lab
ls -1 backup_dir
} > 04.log 2>&1
{
sql "DROP TABLE orders, order_notes;
INSERT INTO test_monitor VALUES (1001, 'added after dump');"
echo '$ pg_restore --exit-on-error -d backup_lab -t orders backup_dir'
pg_restore --exit-on-error -d backup_lab -t orders backup_dir
# -t does not select dependent objects such as constraints.
echo '$ pg_restore --exit-on-error -d backup_lab -L orders_constraint.list backup_dir'
pg_restore -l backup_dir | grep ' CONSTRAINT public orders orders_pkey ' > orders_constraint.list
pg_restore --exit-on-error -d backup_lab -L orders_constraint.list backup_dir
sql 'TABLE orders;'
sql "SELECT conname FROM pg_constraint WHERE conrelid = 'public.orders'::regclass;"
sql "SELECT to_regclass('public.order_notes') IS NULL AS notes_still_absent,
count(*) AS monitor_rows FROM test_monitor;"
test "$(psql -XAtc 'SELECT sum(amount) FROM orders')" = 2800
} > 05.log 2>&1

{
sql "CREATE TABLE users(id serial PRIMARY KEY, email text UNIQUE);"
stat -c '%a %U %n' wal_archive
cat >> source/postgresql.conf <<CONF
wal_level = replica
archive_mode = on
archive_command = 'test ! -f "$root/wal_archive/%f" && cp "%p" "$root/wal_archive/%f"'
CONF
tail -3 source/postgresql.conf
pg_ctl -D source -l source.log restart -m fast
sql 'SHOW wal_level; SHOW archive_mode;'
} > 06.log 2>&1
{
echo '$ pg_basebackup -D base_backup -Fp -Xs -P -c fast'
pg_basebackup -D base_backup -Fp -Xs -P -c fast
pg_verifybackup base_backup
du -sh base_backup
} > 07.log 2>&1

archive() {
  local filename
  sql "SELECT pg_create_restore_point('pr4_archive_checkpoint');"
  filename=$(psql -XAtc 'SELECT pg_walfile_name(pg_current_wal_insert_lsn())')
  sql 'SELECT pg_switch_wal();'
  for ((i=0;i<80;i++)); do
    if [[ -s "wal_archive/$filename" ]]; then ls -lh "wal_archive/$filename"; return; fi
    sleep .25
  done
  echo "WAL was not archived: $filename" >&2
  return 1
}
archive > 08.log 2>&1

{
echo "T1 = $(psql -XAtc 'SELECT now()')"
sql "INSERT INTO users(email) SELECT format('user%s@lab.example', id)
FROM generate_series(1, 10) id;"
target=$(psql -XAtc 'SELECT now()')
echo "recovery_target_time = '$target'"
echo "T2 = $(psql -XAtc 'SELECT now()')"
sql "UPDATE users SET email = format('corrupted-%s@lab.example', id);"
sql "SELECT count(*) AS corrupted_before_recovery FROM users
WHERE email LIKE 'corrupted-%';"
archive
pg_ctl -D source stop -m fast
mv source source-offline
echo '$ mv source source-offline'
} > 09.log 2>&1

{
echo '$ cp -a base_backup restored'
cp -a base_backup restored
touch restored/recovery.signal
cat >> restored/postgresql.conf <<CONF
restore_command = 'cp "$root/wal_archive/%f" "%p"'
recovery_target_time = '$target'
recovery_target_action = 'promote'
CONF
tail -3 restored/postgresql.conf
pg_ctl -D restored -l restored.log -o '-c archive_mode=off' start
for ((i=0;i<60;i++)); do
  [[ "$(psql -XAtc 'SELECT pg_is_in_recovery()' 2>/dev/null || true)" == f ]] && break
  sleep .25
done
grep -E 'recovery stopping|archive recovery complete' restored.log
sql "SELECT pg_is_in_recovery(), count(*) AS total,
count(*) FILTER (WHERE email LIKE 'user%@lab.example') AS important,
count(*) FILTER (WHERE email LIKE 'corrupted-%') AS corrupted FROM users;"
test "$(psql -XAtc "SELECT count(*) FROM users WHERE email LIKE 'user%@lab.example'")" = 10
test "$(psql -XAtc "SELECT count(*) FROM users WHERE email LIKE 'corrupted-%'")" = 0
} > 10.log 2>&1

{
echo '$ scripts/verify_backup.sh backup_lab public.users public.orders public.test_monitor'
"$repo/scripts/verify_backup.sh" backup_lab public.users public.orders public.test_monitor
echo '$ scripts/verify_backup.sh backup_lab public.missing_table'
if "$repo/scripts/verify_backup.sh" backup_lab public.missing_table; then
  echo 'Expected the invalid-table test to fail' >&2
  exit 1
fi
sql "SELECT count(*) AS temporary_databases FROM pg_database WHERE datname LIKE 'pr4_verify_%';"
test "$(psql -XAtc "SELECT count(*) FROM pg_database WHERE datname LIKE 'pr4_verify_%'")" = 0
} > 11.log 2>&1
