#!/usr/bin/env bash
# Entrypoint for the development container: waits for PostgreSQL, makes sure gems match
# the (bind-mounted) Gemfile, clears a stale server pid, then runs the given command.
set -euo pipefail

until pg_isready -h "${REDMINE_DB_HOST:-db}" -U "${REDMINE_DB_USERNAME:-redmine}" -q; do
  echo "waiting for postgres at ${REDMINE_DB_HOST:-db}..."
  sleep 1
done

bundle check >/dev/null 2>&1 || bundle install

rm -f tmp/pids/server.pid

exec "$@"
