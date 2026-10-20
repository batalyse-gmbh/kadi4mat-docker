#!/opt/kadi/venv/bin/python
"""Wait until Elasticsearch reports at least yellow health (run by the entrypoint before
"kadi search init", which exits on the first connection error).

Compose only orders startup by healthchecks for "docker compose up". After a reboot, the
Docker daemon restarts all containers at once, and Elasticsearch takes minutes to come up
on slow storage, so without this wait the web container crash-loops until it does.

The nodes and client options come from ELASTICSEARCH_HOSTS and ELASTICSEARCH_CONFIG in
the Kadi config file, so this script and Kadi always connect the same way.
"""

import os
import runpy
import sys
import time

from elasticsearch import ApiError
from elasticsearch import Elasticsearch
from elasticsearch import TransportError

TIMEOUT = 300
RETRY_DELAY = 5
# Server-side wait per request; the client waits a bit longer for the answer.
HEALTH_WAIT = 10


def main():
    config = runpy.run_path(os.environ["KADI_CONFIG_FILE"])
    hosts = config.get("ELASTICSEARCH_HOSTS")

    if not hosts:
        print("No ELASTICSEARCH_HOSTS configured, not waiting for Elasticsearch.")
        return

    client = Elasticsearch(hosts=hosts, **config.get("ELASTICSEARCH_CONFIG", {})).options(
        request_timeout=HEALTH_WAIT + 5, max_retries=0
    )
    start = time.monotonic()

    while True:
        try:
            health = client.cluster.health(
                wait_for_status="yellow", timeout=f"{HEALTH_WAIT}s"
            )
            print(f"Elasticsearch is up (status {health['status']}).")
            return
        except ApiError as e:
            # Still red after HEALTH_WAIT answers with HTTP 408.
            reason = f"HTTP {e.meta.status}"
        except TransportError as e:
            reason = type(e).__name__

        elapsed = time.monotonic() - start
        if elapsed >= TIMEOUT:
            sys.exit(f"Elasticsearch still not ready after {TIMEOUT}s ({reason}), giving up.")

        print(
            f"Elasticsearch not ready ({reason}), retrying in {RETRY_DELAY}s"
            f" ({elapsed:.0f}s/{TIMEOUT}s)...",
            file=sys.stderr,
        )
        time.sleep(RETRY_DELAY)


if __name__ == "__main__":
    main()
