"""
NGINX_HOST_POLICY — сценарии доступа по IP и неканоническому Host.

allow    — текущее поведение (IP и домен работают)
redirect — запросы по IP / alt-host редиректятся на канонический домен
deny     — запросы по IP / alt-host отклоняются (444)
"""

from __future__ import annotations

import ipaddress
import re
from pathlib import Path

POLICIES = frozenset({'allow', 'redirect', 'deny'})

def normalize_policy(value: str | None) -> str:
    normalized = (value or 'allow').strip().lower()
    return normalized if normalized in POLICIES else 'allow'


def is_ip_address(host: str) -> bool:
    candidate = host.strip()
    if not candidate:
        return False
    try:
        ipaddress.ip_address(candidate)
        return True
    except ValueError:
        return False


def is_valid_hostname(host: str) -> bool:
    candidate = host.strip()
    if not candidate or is_ip_address(candidate):
        return False
    if candidate in ('localhost', '_'):
        return False
    return bool(re.match(r'^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$', candidate))


def canonical_hostname(values: dict[str, str]) -> str:
    for key in ('NGINX_PUBLIC_HOST', 'NGINX_SERVER_NAME'):
        host = values.get(key, '').strip()
        if is_valid_hostname(host):
            return host
    return ''


def _detect_lan_ip() -> str:
    from detect_lan_ip import detect_lan_ip as detect

    return detect() or ''


def parse_alt_hosts(values: dict[str, str], canonical: str) -> list[str]:
    hosts: list[str] = []
    raw = values.get('NGINX_ALT_HOSTS', '').strip()
    if raw:
        hosts.extend(part.strip() for part in raw.split(',') if part.strip())

    detected = _detect_lan_ip()
    if detected and detected != canonical:
        hosts.append(detected)

    unique: list[str] = []
    for host in hosts:
        if host == canonical or host in unique:
            continue
        if is_ip_address(host) or host != canonical:
            unique.append(host)
    return unique


def _canonical_base_url(
    canonical: str,
    *,
    use_https: bool,
    listen_port: str,
) -> str:
    scheme = 'https' if use_https else 'http'
    port = (listen_port or '80').strip()
    if (scheme == 'http' and port == '80') or (scheme == 'https' and port == '443'):
        return f'{scheme}://{canonical}'
    return f'{scheme}://{canonical}:{port}'


def http_canonical_redirect_target(
    values: dict[str, str],
    *,
    use_https: bool,
    listen_port: str,
) -> str:
    policy = normalize_policy(values.get('NGINX_HOST_POLICY'))
    canonical = canonical_hostname(values)
    if policy in ('redirect', 'deny') and canonical:
        base = _canonical_base_url(canonical, use_https=True, listen_port='443')
        return f'{base}$request_uri'
    if use_https:
        return 'https://$host$request_uri'
    return 'http://$host$request_uri'


def render_host_policy_blocks(
    values: dict[str, str],
    *,
    listen_host: str,
    listen_port: str,
    use_https: bool,
) -> str:
    policy = normalize_policy(values.get('NGINX_HOST_POLICY'))
    if policy == 'allow':
        return ''

    canonical = canonical_hostname(values)
    if not canonical:
        return ''

    alt_hosts = parse_alt_hosts(values, canonical)
    names = ' '.join(['_', *alt_hosts]) if alt_hosts else '_'
    bind = f'{listen_host}:{listen_port}'
    lines: list[str] = [
        f'# NGINX_HOST_POLICY={policy} (canonical: {canonical})',
    ]

    if policy == 'redirect':
        target = _canonical_base_url(
            canonical,
            use_https=use_https,
            listen_port=listen_port,
        )
        lines.extend([
            'server {',
            f'    listen {bind} default_server;',
            f'    server_name {names};',
            f'    return 301 {target}$request_uri;',
            '}',
            '',
        ])
        if use_https:
            lines.extend([
                'server {',
                '    listen 443 ssl default_server;',
                '    listen [::]:443 ssl default_server;',
                f'    server_name {names};',
                f'    ssl_certificate         ${{ERGO_SSL_CERT}};',
                f'    ssl_certificate_key     ${{ERGO_SSL_KEY}};',
                f'    return 301 {target}$request_uri;',
                '}',
                '',
            ])
        return '\n'.join(lines)

    lines.extend([
        'server {',
        f'    listen {bind} default_server;',
        f'    server_name {names};',
        '    return 444;',
        '}',
        '',
    ])
    if use_https:
        lines.extend([
            'server {',
            '    listen 443 ssl default_server;',
            '    listen [::]:443 ssl default_server;',
            f'    server_name {names};',
            '    ssl_certificate         ${ERGO_SSL_CERT};',
            '    ssl_certificate_key     ${ERGO_SSL_KEY};',
            '    return 444;',
            '}',
            '',
        ])
    return '\n'.join(lines)


def compute_template_vars(
    values: dict[str, str],
    *,
    listen_host: str = '0.0.0.0',
    listen_port: str = '80',
    use_https: bool = False,
) -> dict[str, str]:
    return {
        'ERGO_HOST_POLICY_BLOCKS': render_host_policy_blocks(
            values,
            listen_host=listen_host,
            listen_port=listen_port,
            use_https=use_https,
        ),
        'ERGO_HTTP_CANONICAL_REDIRECT': http_canonical_redirect_target(
            values,
            use_https=use_https,
            listen_port=listen_port,
        ),
    }
