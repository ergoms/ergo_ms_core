"""
Effective значения переменных окружения для deployment-скриптов (stdlib).

Не записывает .env — дублирует логику src.config.nginx_runtime / tls_runtime.
"""

from __future__ import annotations

import sys
from pathlib import Path

_DEPLOYMENT_DIR = Path(__file__).resolve().parent
_NGINX_DIR = _DEPLOYMENT_DIR / 'nginx'
if str(_NGINX_DIR) not in sys.path:
    sys.path.insert(0, str(_NGINX_DIR))

from detect_lan_ip import detect_lan_ip  # noqa: E402
from host_policy import is_valid_hostname  # noqa: E402
from tls_config import cert_exists, cert_paths, primary_domain  # noqa: E402


def read_env_file(path: Path) -> dict[str, str]:
    if not path.is_file():
        return {}

    result: dict[str, str] = {}
    for line in path.read_text(encoding='utf-8').splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith('#') or '=' not in stripped:
            continue
        key, _, raw = stripped.partition('=')
        result[key.strip()] = raw.strip().strip('"').strip("'")
    return result


def _truthy(value: str) -> bool:
    return value.strip().lower() in ('1', 'true', 'yes')


def _use_https(values: dict[str, str]) -> bool:
    if _truthy(values.get('NGINX_USE_HTTPS', '')):
        return True
    return values.get('NGINX_LISTEN_PORT', '').strip() == '443'


def resolve_nginx_vars(values: dict[str, str]) -> dict[str, str]:
    """Effective nginx/TLS-переменные для install-nginx и render_nginx_config."""
    enabled = _truthy(values.get('NGINX_ENABLED', ''))
    use_https = _use_https(values)

    public_host = values.get('NGINX_PUBLIC_HOST', '').strip()
    server_name = values.get('NGINX_SERVER_NAME', 'localhost').strip()

    if not public_host or public_host in ('localhost', '127.0.0.1'):
        if enabled and server_name in ('', 'localhost', '127.0.0.1'):
            detected = detect_lan_ip()
            public_host = detected or server_name or 'localhost'
        else:
            public_host = server_name or 'localhost'

    if public_host and server_name in ('', 'localhost', '127.0.0.1'):
        server_name = public_host

    listen_host = values.get('NGINX_LISTEN_HOST', '').strip()
    if not listen_host:
        listen_host = '127.0.0.1' if use_https else '0.0.0.0'

    listen_port = values.get('NGINX_LISTEN_PORT', '').strip() or '80'

    ssl_cert = values.get('ERGO_SSL_CERT', '').strip()
    ssl_key = values.get('ERGO_SSL_KEY', '').strip()
    if use_https and (not ssl_cert or not ssl_key):
        domain = primary_domain(values) or (
            public_host if is_valid_hostname(public_host) else ''
        )
        if domain and cert_exists(domain):
            ssl_cert, ssl_key = cert_paths(domain)

    resolved: dict[str, str] = {
        'NGINX_PUBLIC_HOST': public_host,
        'NGINX_SERVER_NAME': server_name,
        'NGINX_LISTEN_HOST': listen_host,
        'NGINX_LISTEN_PORT': listen_port,
    }
    if ssl_cert:
        resolved['ERGO_SSL_CERT'] = ssl_cert
    if ssl_key:
        resolved['ERGO_SSL_KEY'] = ssl_key
    return resolved
