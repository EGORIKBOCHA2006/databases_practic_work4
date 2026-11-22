#!/usr/bin/env bash
set -Eeuo pipefail

source_db=${1:?Usage: verify_backup.sh DATABASE [schema.table ...]}
shift
if (( $# == 0 )); then set -- public.users; fi
for table in "$@"; do
  if [[ ! "$table" =~ ^[a-z_][a-z_0-9]*\.[a-z_][a-z_0-9]*$ ]]; then
    echo "FAIL: invalid table name: $table" >&2
    exit 2
  fi
done
scratch=$(mktemp -d)
test_db="pr4_verify_${scratch##*.}"
created=false

cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$created" == true ]]; then
    if dropdb --maintenance-db="$source_db" "$test_db"; then
      echo "Removed test database $test_db"
    else
      status=1
    fi
  fi
  rm -rf -- "$scratch" || status=1
  if (( status == 0 )); then echo SUCCESS; else echo FAIL >&2; fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

count() {
  psql -XAt -v ON_ERROR_STOP=1 -d "$1" -c "SELECT count(*) FROM $2"
}

pg_dump -Fc -d "$source_db" -f "$scratch/backup.dump"
createdb --maintenance-db="$source_db" -T template0 "$test_db"
created=true
pg_restore --exit-on-error --no-owner --no-privileges -d "$test_db" "$scratch/backup.dump"

for table in "$@"; do
  original=$(count "$source_db" "$table")
  restored=$(count "$test_db" "$table")
  printf '%s: original=%s restored=%s\n' "$table" "$original" "$restored"
  [[ "$original" == "$restored" ]]
done
