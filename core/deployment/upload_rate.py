"""Единый расчёт частоты загрузок для media_api и nginx.

Формат приложения: N/minute (и second|hour|day).
Формат nginx limit_req_zone: Nr/m (или r/s).
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any, Mapping

from security.profile_defaults import merge_security_profile_defaults

_RATE_LIMIT_SNIPPET = Path(__file__).resolve().parent / 'nginx' / 'snippets' / 'rate_limit.conf'

DEFAULT_UPLOAD_RATE = '30/minute'
DEFAULT_UPLOAD_RATE_ADMIN = '120/minute'
DEFAULT_UPLOAD_BURST = 25

_MEDIA_RATE_RE = re.compile(
    r'^(\d+)\s*/\s*(second|minute|hour|day|s|m|h|d)$',
    re.IGNORECASE,
)

_UNIT_TO_NGINX = {
    'second': 's',
    's': 's',
    'minute': 'm',
    'm': 'm',
    'hour': 'h',
    'h': 'h',
    'day': 'd',
    'd': 'd',
}


def media_rate_to_nginx(rate: str) -> str:
    """'60/minute' → '60r/m'; при ошибке — из DEFAULT_UPLOAD_RATE_ADMIN."""
    match = _MEDIA_RATE_RE.match((rate or '').strip())
    if not match:
        match = _MEDIA_RATE_RE.match(DEFAULT_UPLOAD_RATE_ADMIN)
        assert match is not None
    count = int(match.group(1))
    unit = _UNIT_TO_NGINX.get(match.group(2).lower(), 'm')
    return f'{count}r/{unit}'


def resolve_upload_rates(values: Mapping[str, Any]) -> dict[str, str | int]:
    """
    Эффективные квоты после merge профиля.

    Returns:
        user_rate, admin_rate (строки media), nginx_zone_rate, burst (int).
    """
    merged = merge_security_profile_defaults(values)
    user_rate = (merged.get('MEDIA_API_UPLOAD_RATE') or DEFAULT_UPLOAD_RATE).strip()
    admin_rate = (merged.get('MEDIA_API_UPLOAD_RATE_ADMIN') or DEFAULT_UPLOAD_RATE_ADMIN).strip()
    if not _MEDIA_RATE_RE.match(user_rate):
        user_rate = DEFAULT_UPLOAD_RATE
    if not _MEDIA_RATE_RE.match(admin_rate):
        admin_rate = DEFAULT_UPLOAD_RATE_ADMIN
    burst_raw = (merged.get('MEDIA_API_UPLOAD_BURST') or '').strip()
    try:
        burst = int(burst_raw) if burst_raw else DEFAULT_UPLOAD_BURST
    except ValueError:
        burst = DEFAULT_UPLOAD_BURST
    if burst < 1:
        burst = DEFAULT_UPLOAD_BURST
    return {
        'user_rate': user_rate,
        'admin_rate': admin_rate,
        'nginx_zone_rate': media_rate_to_nginx(admin_rate),
        'burst': burst,
    }


def build_rate_limit_conf(values: Mapping[str, Any]) -> str:
    """Текст зон limit_req для http-контекста nginx (сниппет + частота admin)."""
    rates = resolve_upload_rates(values)
    zone_rate = str(rates['nginx_zone_rate'])
    text = _RATE_LIMIT_SNIPPET.read_text(encoding='utf-8')
    return text.replace('${ERGO_UPLOAD_ZONE_RATE}', zone_rate)


def upload_location_limit_lines(*, burst: int, indent: str = '        ') -> str:
    """Строки limit_req / limit_req_status / limit_conn для location /upload/."""
    return (
        f'{indent}limit_req zone=ergo_upload burst={burst} nodelay;\n'
        f'{indent}limit_req_status 429;\n'
        f'{indent}limit_conn ergo_conn 10;\n'
        f'{indent}limit_conn_status 429;\n'
    )
