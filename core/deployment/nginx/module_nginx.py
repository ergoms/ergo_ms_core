"""
Фрагменты nginx для MODULE_RUNTIME=microservice (per-module upstream + location).
"""

from __future__ import annotations

import re
from typing import Mapping
from urllib.parse import urlparse


def parse_csv(raw: str = '') -> list[str]:
    return [m.strip() for m in (raw or '').split(',') if m.strip()]


def parse_service_urls(raw: str = '') -> dict[str, str]:
    result: dict[str, str] = {}
    for part in (raw or '').split(','):
        part = part.strip()
        if not part or '=' not in part:
            continue
        name, url = part.split('=', 1)
        name = name.strip()
        url = url.strip()
        if name and url:
            result[name] = url
    return result


def _runtime_is_microservice(values: Mapping[str, str]) -> bool:
    value = (values.get('MODULE_RUNTIME') or 'monolith').strip().lower()
    return value in ('microservice', 'split')


def _microservice_module_names(values: Mapping[str, str]) -> list[str]:
    raw = values.get('MICROSERVICE_MODULES', '')
    return parse_csv(raw)


def _env_module_host_port(
    values: Mapping[str, str],
    module_name: str,
) -> tuple[str, int] | None:
    """``<NAME>_HOST`` / ``<NAME>_PORT`` или из BRIDGE_SERVICE_URLS."""
    key = module_name.upper().replace('-', '_')
    host = (values.get(f'{key}_HOST') or '').strip()
    port_raw = (values.get(f'{key}_PORT') or '').strip()
    if host and port_raw:
        try:
            return host, int(port_raw)
        except ValueError:
            pass

    urls = parse_service_urls(values.get('BRIDGE_SERVICE_URLS', ''))
    url = urls.get(module_name)
    if not url:
        return None
    parsed = urlparse(url if '://' in url else f'http://{url}')
    if not parsed.hostname:
        return None
    port = parsed.port or (443 if parsed.scheme == 'https' else 80)
    return parsed.hostname, int(port)


def _upstream_safe_name(module_name: str) -> str:
    return re.sub(r'[^a-zA-Z0-9_]', '_', module_name)


_MODULE_UNAVAILABLE_LOCATION = """    location @module_unavailable {
        default_type application/json;
        add_header X-Ergo-Module-Unavailable 1 always;
        return 503 '{"detail":"module_unavailable"}';
    }
"""


def render_module_upstreams_host(values: Mapping[str, str]) -> str:
    """Блок upstream для host nginx (127.0.0.1:port)."""
    if not _runtime_is_microservice(values):
        return ''
    modules = _microservice_module_names(values)
    if not modules:
        return ''

    lines: list[str] = []
    for name in modules:
        resolved = _env_module_host_port(values, name)
        if resolved is None:
            host, port = '127.0.0.1', 8100 + (sum(ord(c) for c in name) % 500)
        else:
            host, port = resolved
        safe = _upstream_safe_name(name)
        lines.append(f'upstream ergo_module_{safe} {{')
        lines.append(f'    server {host}:{port} max_fails=3 fail_timeout=10s;')
        lines.append('}')
        lines.append('')
    return '\n'.join(lines)


def render_module_locations_host(values: Mapping[str, str]) -> str:
    """location /api/<module>/ → upstream (перед общим /api/)."""
    if not _runtime_is_microservice(values):
        return ''
    modules = _microservice_module_names(values)
    if not modules:
        return ''

    blocks: list[str] = []
    for name in modules:
        safe = _upstream_safe_name(name)
        resolved = _env_module_host_port(values, name)
        # Host процесса модуля (IP из BRIDGE_SERVICE_URLS), не публичный $host:
        # соседний Django иначе отвечает 400 (ALLOWED_HOSTS).
        upstream_host = resolved[0] if resolved else '127.0.0.1'
        blocks.append(
            f"""    location /api/{name}/ {{
        if ($maintenance = 1) {{ return 503; }}
        limit_req zone=ergo_api burst=50 nodelay;
        limit_req_status 429;
        limit_conn ergo_conn 50;
        limit_conn_status 429;
        proxy_pass http://ergo_module_{safe};
        proxy_intercept_errors on;
        error_page 502 503 504 =503 @module_unavailable;
        proxy_set_header Host {upstream_host};
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Request-ID $request_id;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }}
"""
        )
    return '\n'.join(blocks) + '\n' + _MODULE_UNAVAILABLE_LOCATION


def render_module_upstreams_docker(values: Mapping[str, str]) -> str:
    """Upstream на compose-сервис с именем модуля."""
    if not _runtime_is_microservice(values):
        return ''
    modules = _microservice_module_names(values)
    if not modules:
        return ''

    lines: list[str] = []
    for name in modules:
        safe = _upstream_safe_name(name)
        service = name
        key = name.upper().replace('-', '_')
        port_raw = (values.get(f'{key}_PORT') or '').strip()
        if port_raw:
            port = port_raw
        else:
            port = str(8100 + (sum(ord(c) for c in name) % 500))
        lines.append(f'upstream ergo_module_{safe} {{')
        lines.append(f'    server {service}:{port} max_fails=3 fail_timeout=10s;')
        lines.append('    keepalive 8;')
        lines.append('}')
        lines.append('')
    return '\n'.join(lines)


def render_module_locations_docker(values: Mapping[str, str]) -> str:
    if not _runtime_is_microservice(values):
        return ''
    modules = _microservice_module_names(values)
    if not modules:
        return ''

    blocks: list[str] = []
    for name in modules:
        safe = _upstream_safe_name(name)
        blocks.append(
            f"""    location /api/{name}/ {{
        limit_req zone=ergo_api burst=50 nodelay;
        limit_req_status 429;
        limit_conn ergo_conn 50;
        limit_conn_status 429;
        proxy_pass http://ergo_module_{safe};
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Request-ID $request_id;
        proxy_intercept_errors on;
        error_page 502 503 504 =503 @module_unavailable;
    }}
"""
        )
    return '\n'.join(blocks) + '\n' + _MODULE_UNAVAILABLE_LOCATION
