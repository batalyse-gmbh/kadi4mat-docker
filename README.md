# Kadi4Mat in Docker

There is no official Docker deployment for Kadi4Mat. The official docs only describe running
PostgreSQL/Redis/Elasticsearch as containers *for development*. This stack follows the
[manual production installation](https://kadi.readthedocs.io/en/stable/installation/production/manual.html),
with each systemd service turned into a container, but is meant to sit behind your own
HTTPS reverse proxy (Caddy, Traefik, nginx, ...) instead of Apache.

| Service         | Replaces (official setup)                                          |
| --------------- | ------------------------------------------------------------------ |
| `kadi`          | `kadi-uwsgi` + Apache's static file serving. Runs `kadi db init` and `kadi search init` on every start, which also applies migrations after upgrades |
| `celery`        | `kadi-celery`                                                      |
| `celerybeat`    | `kadi-celerybeat`                                                  |
| `redis`         | Redis 7                                                            |
| `elasticsearch` | Elasticsearch 8, single node                                       |
| `postgres`      | PostgreSQL 17, **optional** (profile `postgres`)                   |
| `caddy`         | Apache as TLS proxy, **optional** (profile `caddy`)                |

## Setup

```sh
cp .env.example .env   # see the comments in the file
docker compose up -d --build --wait
docker compose exec kadi kadi users create      # prints an initial password
docker compose exec kadi kadi users sysadmin 1
```

## Reverse proxy

Kadi serves plain HTTP on port 8000. Your proxy must terminate TLS: Kadi's production
config uses secure cookies, so login does not work over plain HTTP. `KADI_SERVER_NAME` must
be the public hostname exactly (with port, if not 443), or every route returns 404.

**Caddy on the host** (`KADI_HTTP_BIND=127.0.0.1:8000`, the default):

```caddyfile
kadi4mat.example.edu {
	reverse_proxy 127.0.0.1:8000
}
```

**Caddy as a container**: set `COMPOSE_FILE=docker-compose.yml:compose.proxy-network.yml` and
`PROXY_NETWORK=<caddy's network>` in `.env`, then use `reverse_proxy kadi4mat-kadi:8000`.
The `127.0.0.1:8000` port binding is harmless in that case.

**No proxy on the host**: add `caddy` to `COMPOSE_PROFILES`. It uses ports 80/443 and gets a
Let's Encrypt certificate for `KADI_SERVER_NAME` automatically.

Kadi trusts the last `X-Forwarded-For` entry (one proxy hop), so **never expose port 8000
publicly**. Direct clients could spoof their IP to bypass rate limiting. If there is a
second proxy in front of yours (e.g. Cloudflare), configure `trusted_proxies` in Caddy.

## Existing PostgreSQL server

Remove `postgres` from `COMPOSE_PROFILES` and set `POSTGRES_HOST`/`POSTGRES_PORT` (use
`host.docker.internal` for a server on the Docker host; it must listen on the Docker bridge
interface and allow it in `pg_hba.conf`). PostgreSQL >= 13 is required. Create the role and
database once; Kadi creates the tables itself on first start:

```sql
CREATE ROLE kadi LOGIN PASSWORD '...';
CREATE DATABASE kadi OWNER kadi ENCODING 'UTF8' TEMPLATE template0;
```

If the server is unreachable, `kadi` retries for about 2.5 minutes before exiting.

## Differences from the official Apache setup

- **File downloads are streamed by uWSGI**, not handed to the web server via `X-Sendfile`
  (a generic proxy cannot do that). Downloads run on offload threads, so they do not block
  workers. The trade-off: **no HTTP range requests**, since Kadi only enables them when the
  web server handles files. Interrupted downloads restart from the beginning, and
  multi-connection download managers fall back to a single stream.
- Static files and favicons are served by uWSGI (with one-year cache headers on `/static`).

## Notes

- **Email does not work by default.** `localhost` inside a container is the container itself,
  so set `KADI_SMTP_*` to a real mail server, or password resets and notifications are lost.
- Elasticsearch needs `vm.max_map_count >= 262144` on the Docker host.
- If you swap the `storage`/`uploads` volumes for bind mounts, the host directories must be
  owned by uid/gid 10001 (the `kadi` user in the image).
- Other [configuration options](https://kadi.readthedocs.io/en/stable/installation/configuration.html)
  go into `config/kadi.py`, then run `docker compose up -d --build`.
- Upgrade: change `KADI_VERSION` in `.env`, then run `docker compose up -d --build`.
- Backups: the database, plus the `storage` and `uploads` volumes. Search indices can be
  rebuilt with `kadi search reindex`.
