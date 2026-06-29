"""
Let's Encrypt / TLS: пути сертификатов, обновление .env, статус.
"""

from __future__ import annotations

import re
from datetime import datetime, timezone
from pathlib import Path

from host_policy import is_ip_address, is_valid_hostname

LE_LIVE_DIR = Path('/etc/letsencrypt/live')
DEFAULT_WEBROOT = '/var/www/certbot'


def resolve_domains(values: dict[str, str]) -> list[str]:
    raw = values.get('ERGO_TLS_DOMAINS', '').strip()
    if raw:
        domains = [part.strip() for part in raw.split(',') if part.strip()]
    else:
        primary = values.get('NGINX_PUBLIC_HOST', '').strip() or values.get(
            'NGINX_SERVER_NAME', '',
        ).strip()
        domains = [primary] if primary else []

    result: list[str] = []
    for domain in domains:
        if is_valid_hostname(domain) and domain not in result:
            result.append(domain)
    return result


def primary_domain(values: dict[str, str]) -> str:
    domains = resolve_domains(values)
    return domains[0] if domains else ''


def cert_paths(domain: str) -> tuple[str, str]:
    base = LE_LIVE_DIR / domain
    return str(base / 'fullchain.pem'), str(base / 'privkey.pem')


def cert_exists(domain: str) -> bool:
    fullchain, privkey = cert_paths(domain)
    return Path(fullchain).is_file() and Path(privkey).is_file()


def _read_env(path: Path) -> dict[str, str]:
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


def _set_env_var(content: str, key: str, value: str) -> str:
    pattern = re.compile(rf'^{re.escape(key)}=.*$', re.MULTILINE)
    line = f'{key}={value}'
    if pattern.search(content):
        return pattern.sub(line, content, count=1)
    if content and not content.endswith('\n'):
        content += '\n'
    return content + line + '\n'


def _append_csv_value(existing: str, item: str) -> str:
    parts = [part.strip() for part in existing.split(',') if part.strip()]
    if item not in parts:
        parts.append(item)
    return ','.join(parts)


def apply_tls_env(
    env_path: Path,
    domain: str,
    *,
    extra_domains: list[str] | None = None,
) -> list[str]:
    if not is_valid_hostname(domain):
        raise ValueError(f'Invalid domain: {domain}')

    domains = [domain]
    for item in extra_domains or []:
        if is_valid_hostname(item) and item not in domains:
            domains.append(item)

    fullchain, privkey = cert_paths(domain)
    if not Path(fullchain).is_file() or not Path(privkey).is_file():
        raise FileNotFoundError(
            f'Certificate not found for {domain}. Run ergoms install-tls first.',
        )

    content = env_path.read_text(encoding='utf-8') if env_path.is_file() else ''
    values = _read_env(env_path)
    changed_keys: list[str] = []

    updates = {
        'NGINX_ENABLED': 'true',
        'NGINX_USE_HTTPS': 'true',
        'NGINX_LISTEN_PORT': '443',
        'NGINX_LISTEN_HOST': values.get('NGINX_LISTEN_HOST', '').strip() or '0.0.0.0',
        'NGINX_PUBLIC_HOST': domain,
        'NGINX_SERVER_NAME': domain,
        'ERGO_SSL_CERT': fullchain,
        'ERGO_SSL_KEY': privkey,
        'FRONTEND_BASE_URL': f'https://{domain}',
        'VITE_USE_RELATIVE_API': 'true',
        'API_HOST': values.get('API_HOST', '').strip() or '127.0.0.1',
        'MEDIA_API_HOST': domain,
        'MEDIA_API_PORT': '443',
        'MEDIA_API_PROTOCOL': 'https',
        'MEDIA_API_BIND_HOST': values.get('MEDIA_API_BIND_HOST', '').strip() or '127.0.0.1',
        'MEDIA_API_BIND_PORT': values.get('MEDIA_API_BIND_PORT', '').strip() or '8003',
        'SECURE_SSL_REDIRECT': 'false',
        'MEDIA_API_SECURE_SSL_REDIRECT': 'false',
    }

    if len(domains) > 1:
        updates['ERGO_TLS_DOMAINS'] = ','.join(domains)

    for key, value in updates.items():
        if values.get(key, '') != value:
            content = _set_env_var(content, key, value)
            changed_keys.append(key)

    allowed = _append_csv_value(values.get('API_ALLOWED_HOSTS', ''), domain)
    for item in domains[1:]:
        allowed = _append_csv_value(allowed, item)
    if values.get('API_ALLOWED_HOSTS', '') != allowed:
        content = _set_env_var(content, 'API_ALLOWED_HOSTS', allowed)
        changed_keys.append('API_ALLOWED_HOSTS')

    media_allowed = _append_csv_value(values.get('MEDIA_API_ALLOWED_HOSTS', ''), domain)
    for item in domains[1:]:
        media_allowed = _append_csv_value(media_allowed, item)
    if values.get('MEDIA_API_ALLOWED_HOSTS', '') != media_allowed:
        content = _set_env_var(content, 'MEDIA_API_ALLOWED_HOSTS', media_allowed)
        changed_keys.append('MEDIA_API_ALLOWED_HOSTS')

    origin = f'https://{domain}'
    cors = _append_csv_value(values.get('CORS_ALLOWED_ORIGINS', ''), origin)
    if values.get('CORS_ALLOWED_ORIGINS', '') != cors:
        content = _set_env_var(content, 'CORS_ALLOWED_ORIGINS', cors)
        changed_keys.append('CORS_ALLOWED_ORIGINS')

    env_path.write_text(content, encoding='utf-8')
    return changed_keys


def read_cert_expiry(cert_path: str) -> datetime | None:
    path = Path(cert_path)
    if not path.is_file():
        return None
    try:
        import subprocess

        result = subprocess.run(
            ['openssl', 'x509', '-enddate', '-noout', '-in', str(path)],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            return None
        match = re.search(r'notAfter=(.+)', result.stdout.strip())
        if not match:
            return None
        return datetime.strptime(
            match.group(1).strip(),
            '%b %d %H:%M:%S %Y %GMT',
        ).replace(tzinfo=timezone.utc)
    except (OSError, ValueError):
        return None


def cert_status(domain: str) -> dict[str, str | int | bool]:
    fullchain, privkey = cert_paths(domain)
    exists = Path(fullchain).is_file() and Path(privkey).is_file()
    result: dict[str, str | int | bool] = {
        'domain': domain,
        'exists': exists,
        'fullchain': fullchain,
        'privkey': privkey,
    }
    if not exists:
        return result

    expiry = read_cert_expiry(fullchain)
    if expiry:
        days_left = (expiry - datetime.now(timezone.utc)).days
        result['expires_at'] = expiry.isoformat()
        result['days_left'] = days_left
    return result


def validate_tls_prerequisites(values: dict[str, str]) -> list[str]:
    errors: list[str] = []
    domains = resolve_domains(values)
    if not domains:
        errors.append('Set NGINX_PUBLIC_HOST or ERGO_TLS_DOMAINS to a valid domain name.')
        return errors

    for domain in domains:
        if is_ip_address(domain):
            errors.append(f'TLS requires a domain name, not an IP: {domain}')

    email = values.get('ERGO_TLS_EMAIL', '').strip()
    if not email or '@' not in email:
        errors.append('Set ERGO_TLS_EMAIL in .env (Let\'s Encrypt notifications).')
    return errors


def webroot_path(values: dict[str, str]) -> str:
    return values.get('ERGO_TLS_WEBROOT', '').strip() or DEFAULT_WEBROOT
