#!/bin/sh
set -e

case "$1" in
  web)
    # Fail fast with a readable message on missing or placeholder settings, instead of a
    # traceback inside the database retry loop below.
    python "${KADI_CONFIG_FILE}"

    if [ "${KADI_SMTP_HOST:-localhost}" = "localhost" ]; then
      echo "WARNING: KADI_SMTP_HOST is 'localhost', which is this container. Emails" \
        "(password resets, notifications) will not be delivered." >&2
    fi

    # Both commands are idempotent: they apply pending migrations / create missing
    # indices, so running them on every start also handles upgrades. The retries cover an
    # external database that is not reachable yet (the bundled one has a healthcheck).
    tries=0
    until kadi db init; do
      tries=$((tries + 1))
      if [ "$tries" -ge 30 ]; then
        echo "Database still unreachable after 30 attempts, giving up." >&2
        exit 1
      fi
      echo "Database not ready, retrying in 5s ($tries/30)..." >&2
      sleep 5
    done
    kadi search init
    export UWSGI_PROCESSES="${UWSGI_PROCESSES:-4}"
    export UWSGI_OFFLOAD_THREADS="${UWSGI_OFFLOAD_THREADS:-2}"
    exec uwsgi --ini /opt/kadi/config/uwsgi.ini
    ;;
  worker)
    exec kadi celery worker --loglevel=INFO
    ;;
  beat)
    # Schedule state is disposable; an empty pidfile avoids stale-pid failures on restart.
    # Removing the schedule on start also backs the healthcheck in docker-compose.yml.
    rm -f /tmp/celerybeat-schedule*
    exec kadi celery beat --loglevel=INFO --pidfile= -s /tmp/celerybeat-schedule
    ;;
  *)
    exec "$@"
    ;;
esac
