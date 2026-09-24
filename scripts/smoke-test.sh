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
# Valid settings: the only possible complaint is the plugin itself (not installed in CI).
output=$(config -e KADI_PLUGINS=collect_embed \
  -e COLLECT_EMBED_BROWSER_BASE_URL=https://collect.ci.invalid/ -e COLLECT_EMBED_SERVER_BASE_URL= \
  -e COLLECT_EMBED_SERVICE_SECRET=0123456789abcdef0123456789abcdef) || true
if printf '%s\n' "$output" | grep '^  - ' | grep -v "'collect_embed', which is not installed"; then
  echo "valid collect_embed settings were rejected" >&2
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

echo "--- kadi-provision"
kadi_exec() {
  compose exec -T kadi "$@"
}
api() {
  curl -s -o /dev/null -w '%{http_code}' -H 'Host: localhost' -H 'X-Forwarded-Proto: https' "$@"
}
owner=$(kadi_exec kadi users create -d Owner -u ci-owner -e owner@example.org -y \
  | sed -n 's/^User with ID \([0-9]*\) created.*/\1/p')
echo y | kadi_exec kadi users sysadmin "$owner" >/dev/null
kadi_exec kadi users create -d Service -u ci-service -e service@example.org -y >/dev/null
redirect=https://collect.ci.invalid/API/auth/oidc/callback

# refused <message> <command...>: the command must fail with that message.
refused() {
  message=$1
  shift
  if output=$("$@" 2>&1); then
    echo "accepted: $*" >&2
    exit 1
  fi
  printf '%s' "$output" | grep -q "$message" || { echo "no '$message': $output" >&2; exit 1; }
}
refused "OIDC provider is disabled" kadi_exec env KADI_OIDC_PROVIDER=false \
  kadi-provision oidc-client --owner ci-owner --name CI --redirect-uri "$redirect"
output=$(kadi_exec kadi-provision oidc-client --owner ci-owner --name CI --redirect-uri "$redirect")
client_id=$(printf '%s' "$output" | sed -n 's/^OIDC_CLIENT_ID=//p')
client_secret=$(printf '%s' "$output" | sed -n 's/^OIDC_CLIENT_SECRET=//p')
[ -n "$client_id" ] && [ -n "$client_secret" ]
# The printed secret authenticates the client: a made-up code then fails as invalid_grant.
token_error() {
  curl -s -H 'Host: localhost' -H 'X-Forwarded-Proto: https' "http://127.0.0.1:$port/oauth/token" \
    -d grant_type=authorization_code -d code=made-up -d "redirect_uri=$redirect" \
    -d "client_id=$client_id" -d "client_secret=$1" | jq -r .error
}
[ "$(token_error "$client_secret")" = invalid_grant ]
[ "$(token_error wrong-secret)" = invalid_client ]
output=$(kadi_exec kadi-provision oidc-client --owner ci-owner --name CI --redirect-uri "$redirect")
[ "$output" = "OIDC_CLIENT_ID=$client_id" ]
echo "OIDC client registered once, secret accepted by /oauth/token"

refused "is a sysadmin" \
  kadi_exec kadi-provision token --user ci-owner --name collect --scope record.read
output=$(kadi_exec kadi-provision token --user ci-service --name collect \
  --scope "record.read record.update")
pat=$(printf '%s' "$output" | sed -n 's/^KADI_SERVICE_TOKEN=//p')
[ "$(api -H "Authorization: Bearer $pat" "http://127.0.0.1:$port/api/v1/records")" = 200 ]
[ "$(api -H "Authorization: Bearer $pat" "http://127.0.0.1:$port/api/v1/collections")" = 401 ]
[ -z "$(kadi_exec kadi-provision token --user ci-service --name collect \
  --scope "record.update record.read")" ]
refused "has the scopes" \
  kadi_exec kadi-provision token --user ci-service --name collect --scope record.read
echo "token created once with exactly record.read and record.update"

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
