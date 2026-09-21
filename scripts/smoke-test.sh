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

if [ "$mode" = bind ]; then
  echo "--- data directory ownership"
  docker run --rm -v "$data:/data:ro" alpine:3.24 stat -c '%n %u:%g' \
    /data/postgres /data/redis /data/elasticsearch /data/storage /data/uploads
  [ -n "$(docker run --rm -v "$data:/data:ro" alpine:3.24 find /data/elasticsearch -name node.lock)" ]
  echo "elasticsearch wrote its node.lock"
fi

echo "Smoke test ($mode) passed."
