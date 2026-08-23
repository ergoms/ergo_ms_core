"""Выбор свободных loopback-портов для изолированного сценария."""

from __future__ import annotations

from docker_runtime import host_tcp_port_available

# Не пересекаемся с хостовыми 80, 8000, 8001, 8002, 5433, 6379.
API_CANDIDATES = tuple(range(18000, 18011))
NGINX_CANDIDATES = tuple(range(18080, 18090))
JUPYTER_CANDIDATES = tuple(range(18002, 18010))
POSTGRES_CANDIDATES = tuple(range(15432, 15441))


def pick_free_port(candidates: tuple[int, ...]) -> int | None:
    for port in candidates:
        if host_tcp_port_available(port):
            return port
    return None


def pick_scenario_ports() -> dict[str, int] | None:
    api = pick_free_port(API_CANDIDATES)
    nginx = pick_free_port(NGINX_CANDIDATES)
    jupyter = pick_free_port(JUPYTER_CANDIDATES)
    postgres = pick_free_port(POSTGRES_CANDIDATES)
    if None in (api, nginx, jupyter, postgres):
        return None
    return {
        'api': int(api),
        'nginx': int(nginx),
        'jupyter': int(jupyter),
        'postgres': int(postgres),
    }
