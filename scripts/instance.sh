#!/bin/sh
# Runs docker compose for one of several Kadi instances on this host:
#   scripts/instance.sh <name> <docker compose arguments...>
#   scripts/instance.sh a up -d --build --wait
#   scripts/instance.sh a exec kadi kadi users create
#
# The instance is configured in instances/<name>.env (same format as .env, see
# .env.example) and runs as compose project kadi4mat-<name>, so its containers, volumes and
# network are its own. Its containers read the same file, so settings and project can never
# belong to different instances.
set -eu

if [ $# -lt 1 ]; then
  echo "usage: $0 <name> <docker compose arguments...>" >&2
  exit 2
fi

name=$1
shift
case "$name" in
  "" | *[!a-z0-9_-]* | [!a-z0-9]*)
    echo "Instance name must be lowercase letters, digits, '-' or '_': '$name'" >&2
    exit 2
    ;;
esac

cd "$(dirname "$0")/.."
env_file="instances/$name.env"
if [ ! -f "$env_file" ]; then
  echo "$env_file does not exist; create it from .env.example." >&2
  exit 1
fi

# Exported variables take precedence over the env file, which therefore cannot point the
# containers at another file or rename the project.
export KADI_ENV_FILE="$env_file" COMPOSE_PROJECT_NAME="kadi4mat-$name"
exec docker compose --env-file "$env_file" "$@"
