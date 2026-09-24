#!/bin/sh
# Validates docker-compose.yml together with every supported profile/override combination:
#   1. "docker compose config -q" must succeed.
#   2. No service may reference the same Docker network twice (e.g. once through the x-kadi
#      anchor and once through an override). "config" accepts that, and how Compose then
#      resolves it depends on its version.
#   3. kadi, celery and celerybeat mount their data directories (a service-level list
#      replaces, rather than extends, the one from the x-kadi anchor), and postgres mounts
#      /var/lib/postgresql (postgres:18 refuses to start with a mount at .../data).
#   4. With compose.bind-mounts.yml, no service may still use a named volume.
#   5. With compose.embedded-beat.yml, celery runs the scheduler and celerybeat is off.
# It also checks that scripts/instance.sh gives each instance its own project name, env file
# and proxy alias.
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

    missing=$(printf '%s' "$json" | jq -r '
      {kadi: ["/opt/kadi/storage", "/opt/kadi/uploads", "/opt/kadi/oidc"],
       celery: ["/opt/kadi/storage", "/opt/kadi/uploads"],
       celerybeat: ["/opt/kadi/storage", "/opt/kadi/uploads"],
       postgres: ["/var/lib/postgresql"]}
      | to_entries[] as $want
      # compose.embedded-beat.yml switches celerybeat off and postgres is a profile; every
      # other service must exist.
      | select($json_services[$want.key] or ($want.key | IN("celerybeat", "postgres") | not))
      | $want.value[]
      | select(. as $target | [$json_services[$want.key].volumes[]?.target] | index($target) | not)
      | "\($want.key) does not mount \(.)"' --argjson json_services "$(printf '%s' "$json" | jq '.services')")
    if [ -n "$missing" ]; then
      result=fail
      reason=$missing
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

    case " $* " in
      *compose.embedded-beat.yml*)
        beat=$(printf '%s' "$json" | jq -r '
          (if .services.celerybeat then "celerybeat is still enabled" else empty end),
          (if .services.celery.command != ["worker-beat"]
           then "celery does not run worker-beat" else empty end)')
        if [ -n "$beat" ]; then
          result=fail
          reason=$beat
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
check "bind-mounts with external database" ok "COMPOSE_PROFILES=" \
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

check "embedded-beat" ok "COMPOSE_PROFILES=postgres" \
  "COMPOSE_FILE=docker-compose.yml:compose.embedded-beat.yml"
check "embedded-beat+bind-mounts+external-network" ok "COMPOSE_PROFILES=" \
  "COMPOSE_FILE=docker-compose.yml:compose.bind-mounts.yml:compose.external-network.yml:compose.embedded-beat.yml" \
  "KADI_DATA_DIR=/data/kadi" "EXTERNAL_NETWORK=proxy"

# Two instances through scripts/instance.sh: distinct projects, env files and aliases. A
# .env that must not reach them:
{ base_env; echo "EXTERNAL_NETWORK=from-dot-env"; } > .env
for instance in a b; do
  { base_env
    echo "COMPOSE_PROFILES="
    echo "COMPOSE_FILE=docker-compose.yml:compose.external-network.yml"
    echo "EXTERNAL_NETWORK=proxy"
    # Must be ignored: the script decides both.
    echo "COMPOSE_PROJECT_NAME=wrong"
    echo "KADI_ENV_FILE=.env"
  } > "instances/$instance.env"
  if ! json=$(scripts/instance.sh "$instance" config --format json 2>config.err); then
    got=$(cat config.err)
  else
    got=$(printf '%s' "$json" | jq -r --arg p "kadi4mat-$instance" '
      (if .name != $p then "project is \(.name)" else empty end),
      (if (.services.kadi.networks.external.aliases // []) | index("\($p)-kadi") | not
       then "kadi has no \($p)-kadi alias on the external network" else empty end),
      (if .services.kadi.environment.EXTERNAL_NETWORK != "proxy"
       then "kadi does not get instances/\(.name | ltrimstr("kadi4mat-")).env" else empty end)')
  fi
  if [ -z "$got" ]; then
    echo "PASS  instance $instance through scripts/instance.sh"
  else
    echo "FAIL  instance $instance through scripts/instance.sh"
    printf '%s\n' "$got" | sed 's/^/      /'
    failures=$((failures + 1))
  fi
done

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed."
  exit 1
fi
echo "All compose checks passed."
