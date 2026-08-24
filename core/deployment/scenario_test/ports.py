"""Выбор свободных loopback-портов для изолированного сценария."""

from __future__ import annotations

from docker_runtime import host_tcp_port_available

# Не пересекаемся с хостовыми 80, 8000, 8001, 8002, 5433, 6379.
API_CANDIDATES = tuple(range(18000, 18011))
NGINX_CANDIDATES = tuple(range(18080, 18090))
JUPYTER_CANDIDATES = tuple(range(18002, 18010))
POSTGRES_CANDIDATES = tuple(range(15432, 15441))
REDIS_CANDIDATES = tuple(range(16379, 16389))
MEDIA_CANDIDATES = tuple(range(18103, 18112))
MODULE_CANDIDATES = tuple(range(18200, 18210))


def pick_free_port(candidates: tuple[int, ...], *, used: set[int] | None = None) -> int | None:
    taken = used if used is not None else set()
    for port in candidates:
        if port in taken:
            continue
        if host_tcp_port_available(port):
            return port
    return None


def pick_scenario_ports() -> dict[str, int] | None:
    used: set[int] = set()

    def take(candidates: tuple[int, ...]) -> int | None:
        port = pick_free_port(candidates, used=used)
        if port is not None:
            used.add(port)
        return port

    api = take(API_CANDIDATES)
    nginx = take(NGINX_CANDIDATES)
    jupyter = take(JUPYTER_CANDIDATES)
    postgres = take(POSTGRES_CANDIDATES)
    redis = take(REDIS_CANDIDATES)
    media = take(MEDIA_CANDIDATES)
    module = take(MODULE_CANDIDATES)
    if None in (api, nginx, jupyter, postgres, redis, media, module):
        return None
    return {
        'api': int(api),
        'nginx': int(nginx),
        'jupyter': int(jupyter),
        'postgres': int(postgres),
        'redis': int(redis),
        'media': int(media),
        'module': int(module),
    }
