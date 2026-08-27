"""Хосты, которые не должны уходить в HTTP_PROXY (мост и внутренний LAN)."""

from __future__ import annotations

from collections.abc import Mapping
from urllib.parse import urlparse

_LOOPBACK = ('localhost', '127.0.0.1', '::1')


def _add(host: str, out: list[str], seen: set[str]) -> None:
    item = (host or '').strip().strip('[]')
    if not item or item == '*' or item in ('0.0.0.0', '::'):
        return
    key = item.lower()
    if key in seen:
        return
    seen.add(key)
    out.append(item)


def host_from_url_or_addr(raw: str) -> str:
    text = (raw or '').strip()
    if not text:
        return ''
    if '://' in text:
        return (urlparse(text).hostname or '').strip()
    if text.count(':') == 1 and not text.startswith('['):
        return text.split(':', 1)[0].strip()
    return text


def collect_no_proxy_hosts(values: Mapping[str, str]) -> list[str]:
    """loopback + NO_PROXY из env + хосты моста / nginx / ALLOWED_HOSTS."""
    out: list[str] = []
    seen: set[str] = set()
    for item in _LOOPBACK:
        _add(item, out, seen)
    for key in ('NO_PROXY', 'no_proxy'):
        for part in (values.get(key) or '').split(','):
            _add(part.strip(), out, seen)
    _add(host_from_url_or_addr(values.get('BRIDGE_CORE_URL', '')), out, seen)
    _add(host_from_url_or_addr(values.get('NGINX_API_UPSTREAM', '')), out, seen)
    _add(host_from_url_or_addr(values.get('NGINX_CLIENT_UPSTREAM', '')), out, seen)
    _add(host_from_url_or_addr(values.get('NGINX_CLIENT_REMOTES_UPSTREAM', '')), out, seen)
    _add(host_from_url_or_addr(values.get('NGINX_MEDIA_UPSTREAM', '')), out, seen)
    for part in (values.get('BRIDGE_SERVICE_URLS') or '').split(','):
        if '=' not in part:
            continue
        _add(host_from_url_or_addr(part.split('=', 1)[1]), out, seen)
    for part in (values.get('API_ALLOWED_HOSTS') or '').split(','):
        _add(part.strip(), out, seen)
    return out


def collect_no_proxy_csv(values: Mapping[str, str]) -> str:
    return ','.join(collect_no_proxy_hosts(values))


def collect_no_proxy_csv_for_root(root) -> str:
    from pathlib import Path

    from env_file_loader import load_project_env

    return collect_no_proxy_csv(load_project_env(Path(root)))


if __name__ == '__main__':
    import sys

    print(collect_no_proxy_csv_for_root(sys.argv[1] if len(sys.argv) > 1 else '.'))
