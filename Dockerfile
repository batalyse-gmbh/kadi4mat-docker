# syntax=docker/dockerfile:1
#
# Kadi4Mat container image (uWSGI, Celery worker, Celery beat, CLI), modelled on the
# official manual production installation:
# https://kadi.readthedocs.io/en/stable/installation/production/manual.html

ARG PYTHON_VERSION=3.13
ARG KADI_VERSION=1.12.0

###############################################################################
FROM python:${PYTHON_VERSION}-slim-trixie AS builder

ARG KADI_VERSION

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential libpq-dev libpcre2-dev \
    && rm -rf /var/lib/apt/lists/*

RUN python -m venv /opt/kadi/venv \
    && /opt/kadi/venv/bin/pip install --no-cache-dir --upgrade pip \
    && /opt/kadi/venv/bin/pip install --no-cache-dir "kadi==${KADI_VERSION}"

###############################################################################
FROM python:${PYTHON_VERSION}-slim-trixie

ARG KADI_VERSION
LABEL org.opencontainers.image.title="Kadi4Mat" \
      org.opencontainers.image.version="${KADI_VERSION}"

# media-types provides /etc/mime.types, which uWSGI needs for static file content types.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libmagic1 libpq5 libpcre2-8-0 libxml2 media-types \
    && rm -rf /var/lib/apt/lists/*

# Fixed IDs so that volume ownership stays stable across rebuilds.
RUN groupadd --system --gid 10001 kadi \
    && useradd --system --uid 10001 --gid kadi --home-dir /opt/kadi --shell /bin/bash kadi

COPY --from=builder /opt/kadi/venv /opt/kadi/venv
COPY config/ /opt/kadi/config/
COPY --chmod=755 docker/entrypoint.sh /usr/local/bin/kadi-entrypoint
COPY --chmod=755 docker/oidc-keys.py /usr/local/bin/kadi-oidc-keys

# Pre-create the data directories so fresh named volumes inherit this ownership, and
# expose the package's static files under a stable path for uwsgi.ini.
RUN chown -R root:kadi /opt/kadi/config \
    && chmod 750 /opt/kadi/config \
    && chmod 640 /opt/kadi/config/* \
    && mkdir -p /opt/kadi/storage /opt/kadi/uploads /opt/kadi/oidc \
    && chown -R kadi:kadi /opt/kadi/storage /opt/kadi/uploads /opt/kadi/oidc \
    && chmod 750 /opt/kadi/storage /opt/kadi/uploads \
    && chmod 700 /opt/kadi/oidc \
    && ln -s "$(/opt/kadi/venv/bin/python -c 'import kadi, os; print(os.path.join(os.path.dirname(kadi.__file__), "static"))')" /opt/kadi/static

ENV PATH="/opt/kadi/venv/bin:${PATH}" \
    VIRTUAL_ENV=/opt/kadi/venv \
    KADI_CONFIG_FILE=/opt/kadi/config/kadi.py \
    PYTHONUNBUFFERED=1

WORKDIR /opt/kadi
USER 10001:10001
EXPOSE 8000

ENTRYPOINT ["kadi-entrypoint"]
CMD ["web"]
