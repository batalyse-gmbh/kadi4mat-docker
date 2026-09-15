#!/bin/sh
# Validates docker-compose.yml together with every supported profile/override combination:
#   1. "docker compose config -q" must succeed.
#   2. No service may reference the same Docker network twice (e.g. once through the x-kadi
#      anchor and once through an override). "config" accepts that, but Compose then drops
#      one entry's settings or fails when recreating containers.
#   3. With compose.bind-mounts.yml, no service may still use a named volume.
# Runs in a temporary copy of the repository, so an existing .env is never touched.
set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -R "$repo/." "$work"
rm -f "$work/.env"
cd "$work"

base_env() {
  sed -e "s|^KADI_SERVER_NAME=.*|KADI_SERVER_NAME=kadi.ci.invalid|" \
    -e "s|^KADI_SECRET_KEY=.*|KADI_SECRET_KEY=0123456789abcdef0123456789abcdef|" \
    -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=ci-password|" \
    .env.example
}

failures=0

# check <name> <expect: ok|fail> <extra .env lines...>
check() {
  name=$1 expect=$2
  shift 2
  { base_env; for line in "$@"; do echo "$line"; done; } > .env

  result=ok
  if ! json=$(docker compose config --format json 2>config.err); then
    result=fail
    reason=$(cat config.err)
  else
    # Resolve each service's network keys to real network names and look for repeats.
    dupes=$(printf '%s' "$json" | jq -r '
      .networks as $nets
      | .services | to_entries[]
      | .key as $svc
      | [(.value.networks // {}) | keys[] | ($nets[.].name // .)]
      | group_by(.)[] | select(length > 1)
      | "\($svc) is attached to network \(.[0]) \(length) times"')
    if [ -n "$dupes" ]; then
      result=fail
      reason=$dupes
    fi

    case " $* " in
      *compose.bind-mounts.yml*)
        named=$(printf '%s' "$json" | jq -r '
          .services | to_entries[]
          | .key as $svc
          | (.value.volumes // [])[]
          | select(.type == "volume")
          | "\($svc) still uses named volume \(.source)"')
        if [ -n "$named" ]; then
          result=fail
          reason=$named
        fi
        ;;
    esac
  fi

  if [ "$result" = "$expect" ]; then
    echo "PASS  $name (expected $expect)"
  else
    echo "FAIL  $name (expected $expect, got $result)"
    [ "$result" = fail ] && printf '%s\n' "$reason" | sed 's/^/      /'
    failures=$((failures + 1))
  fi
}

check "default" ok "COMPOSE_PROFILES="
check "postgres" ok "COMPOSE_PROFILES=postgres"
check "caddy" ok "COMPOSE_PROFILES=caddy"
check "postgres+caddy" ok "COMPOSE_PROFILES=postgres,caddy"
check "bind-mounts" ok "COMPOSE_PROFILES=postgres,caddy" \
  "COMPOSE_FILE=docker-compose.yml:compose.bind-mounts.yml" "KADI_DATA_DIR=/data/kadi"
check "bind-mounts without KADI_DATA_DIR" fail "COMPOSE_PROFILES=postgres" \
  "COMPOSE_FILE=docker-compose.yml:compose.bind-mounts.yml"
check "external-network" ok "COMPOSE_PROFILES=" \
  "COMPOSE_FILE=docker-compose.yml:compose.external-network.yml" "EXTERNAL_NETWORK=proxy"
check "external-network without EXTERNAL_NETWORK" fail "COMPOSE_PROFILES=" \
  "COMPOSE_FILE=docker-compose.yml:compose.external-network.yml"
check "db-network" ok "COMPOSE_PROFILES=" \
  "COMPOSE_FILE=docker-compose.yml:compose.db-network.yml" "DB_NETWORK=postgres"
check "external-network+db-network" ok "COMPOSE_PROFILES=" \
  "COMPOSE_FILE=docker-compose.yml:compose.external-network.yml:compose.db-network.yml" \
  "EXTERNAL_NETWORK=proxy" "DB_NETWORK=postgres"
check "external-network+db-network on the same network" fail "COMPOSE_PROFILES=" \
  "COMPOSE_FILE=docker-compose.yml:compose.external-network.yml:compose.db-network.yml" \
  "EXTERNAL_NETWORK=shared" "DB_NETWORK=shared"
check "everything" ok "COMPOSE_PROFILES=postgres,caddy" \
  "COMPOSE_FILE=docker-compose.yml:compose.bind-mounts.yml:compose.external-network.yml:compose.db-network.yml" \
  "KADI_DATA_DIR=/data/kadi" "EXTERNAL_NETWORK=proxy" "DB_NETWORK=postgres"

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed."
  exit 1
fi
echo "All compose checks passed."
