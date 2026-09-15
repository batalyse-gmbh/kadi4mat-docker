# Kadi4Mat configuration. This is a Python file, values are read from the container
# environment (see .env.example). Any other option from
# https://kadi.readthedocs.io/en/stable/installation/configuration.html can be added here.
import os
from urllib.parse import quote_plus


def _env(name, default=None, required=False):
    value = os.environ.get(name, default)

    if required and not value:
        raise RuntimeError(f"Environment variable '{name}' must be set.")

    return value


def _env_bool(name, default=False):
    return _env(name, str(default)).strip().lower() in {"1", "true", "yes", "on"}


AUTH_PROVIDERS = [
    {
        "type": "local",
        "allow_registration": _env_bool("KADI_ALLOW_REGISTRATION", False),
        "email_confirmation_required": _env_bool(
            "KADI_EMAIL_CONFIRMATION_REQUIRED", False
        ),
    }
]

SERVER_NAME = _env("KADI_SERVER_NAME", required=True)
SECRET_KEY = _env("KADI_SECRET_KEY", required=True)

SQLALCHEMY_DATABASE_URI = "postgresql://{user}:{password}@{host}:{port}/{db}?sslmode={sslmode}".format(
    user=quote_plus(_env("POSTGRES_USER", "kadi")),
    password=quote_plus(_env("POSTGRES_PASSWORD", required=True)),
    host=_env("POSTGRES_HOST", "postgres"),
    port=_env("POSTGRES_PORT", "5432"),
    db=_env("POSTGRES_DB", "kadi"),
    sslmode=_env("POSTGRES_SSLMODE", "prefer"),
)

# Kadi always sits behind exactly one HTTP reverse proxy (yours or the bundled Caddy), so
# take the client IP from the last X-Forwarded-For entry that proxy appended. Rate limiting
# and session protection rely on it. Consequently, port 8000 must not be publicly reachable.
PROXY_FIX_HEADERS = {"x_for": 1, "x_proto": 1}

# The official Apache setup lets the web server resolve "X-Sendfile". A generic reverse
# proxy cannot, so uWSGI streams files itself (see uwsgi.ini). This keeps Kadi's response
# headers (Content-Disposition, Content-Type, CSP, nosniff) intact.
USE_X_SENDFILE = False

STORAGE_PATH = "/opt/kadi/storage"
MISC_UPLOADS_PATH = "/opt/kadi/uploads"

CELERY_BROKER_URL = _env("KADI_REDIS_URL", "redis://redis:6379/0")
RATELIMIT_STORAGE_URI = _env("KADI_REDIS_URL", "redis://redis:6379/0")
ELASTICSEARCH_HOSTS = [_env("KADI_ELASTICSEARCH_HOST", "http://elasticsearch:9200")]

SMTP_HOST = _env("KADI_SMTP_HOST", "localhost")
SMTP_PORT = int(_env("KADI_SMTP_PORT", "25"))
SMTP_USERNAME = _env("KADI_SMTP_USERNAME", "")
SMTP_PASSWORD = _env("KADI_SMTP_PASSWORD", "")
SMTP_USE_TLS = _env_bool("KADI_SMTP_USE_TLS", True)
MAIL_NO_REPLY = _env("KADI_MAIL_NO_REPLY", f"no-reply@{SERVER_NAME}")
