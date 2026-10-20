#!/opt/kadi/venv/bin/python
"""Wait until Elasticsearch reports at least yellow health (run by the entrypoint before
"kadi search init", which exits on the first connection error).

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


def main():
    config = runpy.run_path(os.environ["KADI_CONFIG_FILE"])
    client = Elasticsearch(
        hosts=config["ELASTICSEARCH_HOSTS"], **config.get("ELASTICSEARCH_CONFIG", {})
    ).options(request_timeout=RETRY_DELAY * 2, max_retries=0)
    start = time.monotonic()

    while True:
        try:
            # Waits up to RETRY_DELAY on the server, then answers HTTP 408 if still red.
            health = client.cluster.health(
                wait_for_status="yellow", timeout=f"{RETRY_DELAY}s"
            )
            print(f"Elasticsearch is up (status {health['status']}).")
            return
        except ApiError as e:
            if e.meta.status in (401, 403):
                # Wrong credentials do not fix themselves; let Docker restart us now.
                sys.exit(f"Elasticsearch rejected the credentials (HTTP {e.meta.status}).")
            reason = f"HTTP {e.meta.status}"
            delay = 0 if e.meta.status == 408 else RETRY_DELAY
        except TransportError as e:
            reason = type(e).__name__
            delay = RETRY_DELAY

        elapsed = time.monotonic() - start
        if elapsed >= TIMEOUT:
            sys.exit(f"Elasticsearch still not ready after {TIMEOUT}s ({reason}), giving up.")

        print(
            f"Elasticsearch not ready ({reason}), retrying ({elapsed:.0f}s/{TIMEOUT}s)...",
            file=sys.stderr,
        )
        time.sleep(delay)


if __name__ == "__main__":
    main()
