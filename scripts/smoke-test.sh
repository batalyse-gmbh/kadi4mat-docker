#!/bin/sh
# Starts the stack from a fresh state with the bundled PostgreSQL and checks that it works.
#   scripts/smoke-test.sh named   # named volumes (default setup)
#   scripts/smoke-test.sh bind    # compose.bind-mounts.yml with a fresh KADI_DATA_DIR
#   scripts/smoke-test.sh instances  # two instances via scripts/instance.sh (smoke-test-instances.sh)
#
# Uses a temporary copy of the repository and its own compose project name, so an existing
# .env, deployment or its volumes are never touched. The kadi image is built if missing.
# Environment: SMOKE_PORT (default 18000), WAIT_TIMEOUT in seconds (default 600).
set -eu

mode=${1:-named}
if [ "$mode" = instances ]; then
  exec "$(dirname "$0")/smoke-test-instances.sh"
fi
port=${SMOKE_PORT:-18000}
project="kadi4mat-smoke-$mode"

repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
data="$work/data"
cp -R "$repo/." "$work/repo"
rm -f "$work/repo/.env"
cd "$work/repo"

compose() {
  docker compose --project-name "$project" "$@"
}

cleanup() {
  status=$?
  if [ "$status" -ne 0 ]; then
    echo "--- smoke test failed, service state and logs:"
    compose ps -a || true
    compose logs --no-color --tail 80 || true
  fi
  compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  # Data files belong to other uids, so remove them from inside a container.
  if [ -d "$data" ]; then
    docker run --rm -v "$data:/data" alpine:3.24 sh -c 'rm -rf /data/* /data/.[!.]*' || true
  fi
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT

sed -e "s|^KADI_SERVER_NAME=.*|KADI_SERVER_NAME=localhost|" \
  -e "s|^KADI_SECRET_KEY=.*|KADI_SECRET_KEY=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')|" \
  -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=smoke-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')|" \
  -e "s|^KADI_HTTP_BIND=.*|KADI_HTTP_BIND=127.0.0.1:$port|" \
  -e "s|^COMPOSE_PROFILES=.*|COMPOSE_PROFILES=postgres|" \
  -e "s|^KADI_OIDC_PROVIDER=.*|KADI_OIDC_PROVIDER=true|" \
  .env.example > .env

case "$mode" in
  named) ;;
  bind)
    mkdir -p "$data"
    {
      echo "COMPOSE_FILE=docker-compose.yml:compose.bind-mounts.yml"
      echo "KADI_DATA_DIR=$data"
    } >> .env
    ;;
  *)
    echo "usage: $0 named|bind" >&2
    exit 2
    ;;
esac

echo "--- placeholder configuration must be rejected"
image="kadi4mat:$(sed -n 's/^KADI_VERSION=//p' .env)"
# CI loads a cached image beforehand; only build when it is missing.
docker image inspect "$image" >/dev/null 2>&1 || compose build kadi >/dev/null
if output=$(docker run --rm --entrypoint python \
  -e KADI_SERVER_NAME=kadi4mat.example.edu -e KADI_SECRET_KEY=change-me \
  -e POSTGRES_PASSWORD=change-me "$image" /opt/kadi/config/kadi.py 2>&1); then
  echo "placeholder configuration was accepted" >&2
  exit 1
fi
for name in KADI_SERVER_NAME KADI_SECRET_KEY POSTGRES_PASSWORD; do
  printf '%s' "$output" | grep -q "$name" || { echo "no error for $name: $output" >&2; exit 1; }
done
echo "rejected as expected"

echo "--- plugin configuration"
# config <docker run options...>: loads config/kadi.py with valid base settings.
config() {
  docker run --rm --entrypoint python -e KADI_SERVER_NAME=kadi.ci.invalid \
    -e KADI_SECRET_KEY=0123456789abcdef0123456789abcdef -e POSTGRES_PASSWORD=ci \
    "$@" "$image" /opt/kadi/config/kadi.py 2>&1
}
config -e KADI_PLUGINS=zenodo,influxdb >/dev/null \
  || { echo "Kadi's built-in plugins were rejected" >&2; exit 1; }
if output=$(config -e KADI_PLUGINS=zenodo,no_such_plugin); then
  echo "an uninstalled plugin was accepted" >&2
  exit 1
fi
printf '%s' "$output" | grep -q "'no_such_plugin', which is not installed"
if output=$(config -e KADI_PLUGINS=collect_embed \
  -e COLLECT_EMBED_BROWSER_BASE_URL=http://collect.ci.invalid/form \
  -e COLLECT_EMBED_SERVER_BASE_URL=collect:8080 -e COLLECT_EMBED_SERVICE_SECRET=change-me); then
  echo "invalid collect_embed settings were accepted" >&2
  exit 1
fi
for error in "COLLECT_EMBED_BROWSER_BASE_URL must be an origin" \
  "COLLECT_EMBED_BROWSER_BASE_URL must use https" \
  "COLLECT_EMBED_SERVER_BASE_URL must be an absolute" "COLLECT_EMBED_SERVICE_SECRET must be"; do
  printf '%s' "$output" | grep -q "$error" || { echo "no error '$error': $output" >&2; exit 1; }
done
# rejected <error> <COLLECT_EMBED_BROWSER_BASE_URL>: a browser URL refused with that error,
# as a message and not as a traceback.
rejected() {
  if output=$(config -e KADI_PLUGINS=collect_embed -e "COLLECT_EMBED_BROWSER_BASE_URL=$2" \
    -e COLLECT_EMBED_SERVICE_SECRET=0123456789abcdef0123456789abcdef); then
    echo "COLLECT_EMBED_BROWSER_BASE_URL='$2' was accepted" >&2
    exit 1
  fi
  if ! printf '%s' "$output" | grep -q "$1" || printf '%s' "$output" | grep -q Traceback; then
    echo "no error '$1' for '$2': $output" >&2
    exit 1
  fi
}
rejected "COLLECT_EMBED_BROWSER_BASE_URL must be set" ""
rejected "must use https" HTTP://collect.ci.invalid
rejected "is not a valid URL" "https://[::1"
rejected "must not contain a user name" https://ci:secret@collect.ci.invalid
rejected "has an invalid port" https://collect.ci.invalid:abc
rejected "has an invalid port" https://collect.ci.invalid:99999
rejected "must be an origin" "https://collect.ci.invalid?"
rejected "must be an origin" "https://collect.ci.invalid#"
rejected "is the placeholder domain" https://collect.example.edu
rejected "must not contain spaces" "https://collect.ci.invalid "
rejected "has an invalid host" "https://collect.ci.invalid;x"
rejected "has an invalid host" 'https://collect.ci.invalid\x'
# Valid settings: the only possible complaint is the plugin itself (not installed in CI),
# and the plugin gets the bare origin, without the default port. exec() keeps the settings,
# which SystemExit would discard.
output=$(docker run --rm --entrypoint python -e KADI_SERVER_NAME=kadi.ci.invalid \
  -e KADI_SECRET_KEY=0123456789abcdef0123456789abcdef -e POSTGRES_PASSWORD=ci \
  -e KADI_PLUGINS=collect_embed -e COLLECT_EMBED_BROWSER_BASE_URL=HTTPS://Collect.CI.invalid:443/ \
  -e COLLECT_EMBED_SERVER_BASE_URL= -e COLLECT_EMBED_SERVICE_SECRET=0123456789abcdef0123456789abcdef \
  "$image" -c '
settings = {}
try:
    exec(open("/opt/kadi/config/kadi.py").read(), settings)
except SystemExit as error:
    print(error)
print(settings["PLUGIN_CONFIG"]["collect_embed"]["browser_base_url"])' 2>&1)
if [ "$output" != https://collect.ci.invalid ] && { [ "$(printf '%s\n' "$output" | wc -l)" -ne 3 ] \
  || ! printf '%s\n' "$output" | sed -n 2p | grep -q "^  - KADI_PLUGINS names 'collect_embed', which is not installed" \
  || [ "$(printf '%s\n' "$output" | sed -n 3p)" != https://collect.ci.invalid ]; }; then
  echo "valid collect_embed settings were rejected: $output" >&2
  exit 1
fi
echo "plugin settings checked as expected"

echo "--- starting stack ($mode)"
compose up --detach --wait --wait-timeout "${WAIT_TIMEOUT:-600}"
compose ps

echo "--- checks"
for service in kadi celery celerybeat elasticsearch redis postgres; do
  health=$(docker inspect --format '{{.State.Health.Status}}' "$(compose ps -q "$service")")
  echo "$service: $health"
  [ "$health" = healthy ] || exit 1
done

code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: localhost' "http://127.0.0.1:$port/login")
echo "GET /login: $code"
[ "$code" = 200 ]

locked=$(compose exec -T elasticsearch curl -s 'http://localhost:9200/_nodes?filter_path=**.mlockall')
echo "elasticsearch memory lock: $locked"

compose logs kadi | grep -q "WARNING: KADI_SMTP_HOST is 'localhost'"
echo "SMTP warning logged"

echo "--- OIDC provider"
discovery=$(curl -fsS -H 'Host: localhost' -H 'X-Forwarded-Proto: https' \
  "http://127.0.0.1:$port/.well-known/openid-configuration")
echo "$discovery" | jq -e '.issuer == "https://localhost"
  and .jwks_uri == "https://localhost/oauth/jwks.json"' >/dev/null
jwks=$(curl -fsS -H 'Host: localhost' "http://127.0.0.1:$port/oauth/jwks.json")
echo "$jwks" | jq -e '.keys | length == 1 and .[0].kty == "RSA" and .[0].alg == "RS256"' >/dev/null
echo "issuer and JWKS ok: $(echo "$jwks" | jq -c '.keys[0] | {kid, kty, alg}')"
compose exec -T kadi sh -c 'stat -c "%a %u" /opt/kadi/oidc/signing-key.pem' | grep -qx "600 10001"
echo "signing key generated with mode 600"

echo "--- postgres 18 layout"
compose exec -T postgres cat /var/lib/postgresql/18/docker/PG_VERSION | grep -qx 18
mounts=$(docker inspect --format '{{range .Mounts}}{{.Destination}} {{end}}' "$(compose ps -q postgres)")
echo "postgres mounts: $mounts"
[ "$mounts" = "/var/lib/postgresql " ]

if [ "$mode" = bind ]; then
  echo "--- data directory ownership"
  docker run --rm -v "$data:/data:ro" alpine:3.24 stat -c '%n %u:%g' \
    /data/postgres /data/redis /data/elasticsearch /data/storage /data/uploads
  [ -n "$(docker run --rm -v "$data:/data:ro" alpine:3.24 find /data/elasticsearch -name node.lock)" ]
  echo "elasticsearch wrote its node.lock"
  [ -n "$(docker run --rm -v "$data:/data:ro" alpine:3.24 find /data/postgres/18/docker -name PG_VERSION)" ]
  echo "postgres wrote its data to postgres/18/docker"
fi

echo "Smoke test ($mode) passed."
