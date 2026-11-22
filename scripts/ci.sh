#!/usr/bin/env bash
set -Eeuo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
suffix="$(date +%s)-$$"
network="pr4-net-$suffix"
db="pr4-db-$suffix"
password=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')
network_created=false
container_created=false

cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$container_created" == true ]]; then docker rm -fv "$db" >/dev/null || status=1; fi
  if [[ "$network_created" == true ]]; then docker network rm "$network" >/dev/null || status=1; fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
docker network create "$network" >/dev/null
network_created=true
docker create --name "$db" --network "$network" \
  -e POSTGRES_USER=postgres -e POSTGRES_DB=backup_lab \
  -e POSTGRES_PASSWORD="$password" postgres:16 >/dev/null
container_created=true
docker start "$db" >/dev/null
for ((attempt=1; attempt<=60; attempt++)); do
  if docker exec "$db" pg_isready -h 127.0.0.1 -U postgres -d backup_lab >/dev/null; then break; fi
  if (( attempt == 60 )); then docker logs "$db"; exit 1; fi
  sleep 1
done

flyway() {
  FLYWAY_PASSWORD="$password" docker run --rm --network "$network" \
    --mount "type=bind,src=$repo/migrations,dst=/flyway/sql,readonly" \
    -e FLYWAY_PASSWORD -e FLYWAY_USER=postgres \
    -e "FLYWAY_URL=jdbc:postgresql://$db:5432/backup_lab" \
    redgate/flyway:11.20.0 "$@"
}
psql_lab() {
  docker exec "$db" psql -X -v ON_ERROR_STOP=1 -U postgres -d backup_lab "$@"
}

flyway -target=1 migrate
test "$(psql_lab -Atc "SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='users' AND column_name='created_at'")" = 0
flyway migrate
flyway validate
psql_lab -c 'SELECT COUNT(*) FROM users;'
psql_lab -c 'SELECT version, description, success FROM flyway_schema_history ORDER BY installed_rank;'
psql_lab -c "SELECT column_name, data_type, column_default FROM information_schema.columns WHERE table_schema='public' AND table_name='users' ORDER BY ordinal_position;"
test "$(psql_lab -Atc "SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='users' AND column_name='created_at' AND data_type='timestamp with time zone' AND column_default='now()'")" = 1
psql_lab -c "INSERT INTO users(email) VALUES ('ci@lab.example');"
docker exec -i -e PGUSER=postgres "$db" bash -s -- backup_lab public.users < "$repo/scripts/verify_backup.sh"
