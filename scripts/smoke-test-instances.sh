#!/bin/sh
# Starts two instances through scripts/instance.sh on one proxy network, each with the
# bundled PostgreSQL, compose.embedded-beat.yml and KADI_CELERY_CONCURRENCY=1, and checks:
#   - every service is healthy, there is no celerybeat container, and each instance serves
#     its login page,
#   - on the proxy network, each instance's alias reaches that instance,
#   - the worker runs the scheduler and has one process.
#
# Uses a temporary copy of the repository, instance names smoke-a/smoke-b and its own
# network, so existing deployments are never touched. The kadi image is built if missing.
# Environment: SMOKE_PORT (default 18100; the instances use +1 and +2), WAIT_TIMEOUT in
# seconds (default 600).
set -eu

port=${SMOKE_PORT:-18100}
network=kadi4mat-smoke-proxy

repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
cp -R "$repo/." "$work/repo"
rm -f "$work/repo/.env" "$work/repo"/instances/*.env
cd "$work/repo"

cleanup() {
  status=$?
  if [ "$status" -ne 0 ]; then
    echo "--- smoke test failed, service state and logs:"
    for instance in smoke-a smoke-b; do
      scripts/instance.sh "$instance" ps -a || true
      scripts/instance.sh "$instance" logs --no-color --tail 60 || true
    done
  fi
  for instance in smoke-a smoke-b; do
    scripts/instance.sh "$instance" down --volumes --remove-orphans >/dev/null 2>&1 || true
  done
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT

random() {
  od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'
}

docker network create "$network" >/dev/null

for letter in a b; do
  bind=$((port + 1))
  [ "$letter" = b ] && bind=$((port + 2))
  sed -e "s|^KADI_SERVER_NAME=.*|KADI_SERVER_NAME=$letter.localhost|" \
    -e "s|^KADI_SECRET_KEY=.*|KADI_SECRET_KEY=$(random 32)|" \
    -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=smoke-$(random 8)|" \
    -e "s|^KADI_HTTP_BIND=.*|KADI_HTTP_BIND=127.0.0.1:$bind|" \
    -e "s|^COMPOSE_PROFILES=.*|COMPOSE_PROFILES=postgres|" \
    -e "s|^ES_JAVA_OPTS=.*|ES_JAVA_OPTS=-Xms512m -Xmx512m|" \
    -e "s|^UWSGI_PROCESSES=.*|UWSGI_PROCESSES=1|" \
    .env.example > "instances/smoke-$letter.env"
  {
    echo "COMPOSE_FILE=docker-compose.yml:compose.external-network.yml:compose.embedded-beat.yml"
    echo "EXTERNAL_NETWORK=$network"
    echo "KADI_CELERY_CONCURRENCY=1"
  } >> "instances/smoke-$letter.env"
done

image="kadi4mat:$(sed -n 's/^KADI_VERSION=//p' .env.example)"
docker image inspect "$image" >/dev/null 2>&1 || scripts/instance.sh smoke-a build kadi >/dev/null

echo "--- starting instances"
for instance in smoke-a smoke-b; do
  scripts/instance.sh "$instance" up --detach --wait --wait-timeout "${WAIT_TIMEOUT:-600}"
done

echo "--- checks"
# Kadi builds URLs from its own KADI_SERVER_NAME whatever the Host header says, so the
# issuer tells which instance answered.
issuer() {
  docker run --rm --network "$network" curlimages/curl:8.14.1 -fsS \
    -H 'X-Forwarded-Proto: https' "http://$1:8000/.well-known/openid-configuration" \
    | jq -r .issuer
}

for letter in a b; do
  instance=smoke-$letter
  for service in kadi celery elasticsearch redis postgres; do
    health=$(docker inspect --format '{{.State.Health.Status}}' \
      "$(scripts/instance.sh "$instance" ps -q "$service")")
    echo "$instance $service: $health"
    [ "$health" = healthy ]
  done
  [ -z "$(scripts/instance.sh "$instance" ps -aq celerybeat)" ] \
    || { echo "$instance has a celerybeat container" >&2; exit 1; }

  bind=$((port + 1))
  [ "$letter" = b ] && bind=$((port + 2))
  status=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $letter.localhost" "http://127.0.0.1:$bind/login")
  echo "GET $letter.localhost/login on port $bind: $status"
  [ "$status" = 200 ]

  answer=$(issuer "kadi4mat-$instance-kadi")
  echo "alias kadi4mat-$instance-kadi reaches: $answer"
  [ "$answer" = "https://$letter.localhost" ]

  processes=$(scripts/instance.sh "$instance" exec -T celery sh -c \
    'celery --broker "${KADI_REDIS_URL:-redis://redis:6379/0}" inspect stats --destination "celery@$HOSTNAME" --timeout 10 --json' \
    | tail -n 1 | jq '.[].pool["max-concurrency"]')
  echo "$instance worker processes: $processes"
  [ "$processes" = 1 ]

  scripts/instance.sh "$instance" logs celery | grep -q "beat: Starting"
  echo "$instance scheduler runs inside the worker"
done

echo "Instances smoke test passed."
