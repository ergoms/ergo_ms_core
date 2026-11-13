"""Overlay decision.json — не переписывает celery_workers.yaml."""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from project_layout import cache_celery_balance_dir, ensure_dir

from celery_balance.constants import DECISION_FILENAME, MODE_AUTO
from celery_balance.planner import WorkerPlan
from celery_balance.settings import BalanceSettings


@dataclass(frozen=True)
class WorkerOverride:
    concurrency: int
    prefetch_multiplier: int | None
    autoscale_min: int | None
    autoscale_max: int | None


def decision_path(project_root: Path) -> Path:
    return cache_celery_balance_dir(project_root) / DECISION_FILENAME


def merge_worker_limits(workers: list[WorkerPlan]) -> dict[str, Any]:
    """Общие поля overlay из планов воркеров: их читает воркер без своего плана."""
    queue_limits: dict[str, int] = {}
    queue_classes: dict[str, str] = {}
    pause_queues: list[str] = []
    reserve_light = 0
    non_light_caps: list[int] = []
    for item in workers:
        pause_queues.extend(item.pause_queues)
        reserve_light = max(reserve_light, int(item.reserve_light or 0))
        if item.non_light_cap > 0:
            non_light_caps.append(int(item.non_light_cap))
        for queue_name, limit in item.queue_limits.items():
            prev = queue_limits.get(queue_name)
            queue_limits[queue_name] = limit if prev is None else min(prev, limit)
        for queue_name, task_class in item.queue_classes.items():
            queue_classes[str(queue_name)] = str(task_class)
    return {
        'queue_limits': queue_limits,
        'queue_classes': queue_classes,
        'reserve_light': reserve_light,
        'non_light_cap': min(non_light_caps) if non_light_caps else 0,
        'pause_queues': sorted(set(pause_queues)),
    }


def decision_drifted(
    project_root: Path,
    workers: list[WorkerPlan],
    allowed_queues: list[str] | None,
) -> bool:
    """Лимиты, паузы или разрешённые очереди разошлись с decision.json.

    Файл — запасной план при сбое Redis. Если писать его только при смене
    concurrency, воркер после сбоя получит лимиты недельной давности.
    """
    data = load_decision(project_root)
    if not data:
        return True
    merged = merge_worker_limits(workers)
    for key in ('queue_limits', 'pause_queues', 'non_light_cap'):
        if data.get(key) != merged[key]:
            return True
    if allowed_queues is not None and data.get('allowed_queues') != list(allowed_queues):
        return True
    return False


def write_decision(
    project_root: Path,
    *,
    settings: BalanceSettings,
    budget: dict[str, Any],
    queues: dict[str, Any],
    forecast: dict[str, Any],
    workers: list[WorkerPlan],
    yaml_workers: dict[str, Any],
    allowed_queues: list[str] | None = None,
    node_id: str | None = None,
) -> Path:
    path = decision_path(project_root)
    ensure_dir(path.parent)
    merged = merge_worker_limits(workers)
    payload = {
        'version': 1,
        'generated_at': datetime.now(timezone.utc).isoformat(),
        'mode': settings.mode,
        'budget': budget,
        'queues': queues,
        'forecast': forecast,
        'yaml': yaml_workers,
        'plans': {item.name: item.to_dict() for item in workers},
        **merged,
    }
    if node_id:
        payload['node_id'] = node_id
    if allowed_queues is not None:
        payload['allowed_queues'] = list(allowed_queues)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    return path


def load_decision(project_root: Path) -> dict[str, Any] | None:
    path = decision_path(project_root)
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text(encoding='utf-8'))
    except (OSError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def _override_from_raw(raw: Any) -> WorkerOverride | None:
    if not isinstance(raw, dict):
        return None
    try:
        concurrency = int(raw.get('concurrency'))
    except (TypeError, ValueError):
        return None
    if concurrency < 1:
        return None
    prefetch = raw.get('prefetch_multiplier')
    try:
        prefetch_i = int(prefetch) if prefetch is not None else None
    except (TypeError, ValueError):
        prefetch_i = None
    try:
        a_min = int(raw['autoscale_min']) if raw.get('autoscale_min') is not None else None
        a_max = int(raw['autoscale_max']) if raw.get('autoscale_max') is not None else None
    except (TypeError, ValueError):
        a_min, a_max = None, None
    return WorkerOverride(
        concurrency=concurrency,
        prefetch_multiplier=prefetch_i,
        autoscale_min=a_min,
        autoscale_max=a_max,
    )


def _plans_override(plans: Any, worker_name: str | None) -> WorkerOverride | None:
    if not isinstance(plans, dict):
        return None
    key = worker_name or 'all'
    raw = plans.get(key)
    if not isinstance(raw, dict) and worker_name is None and len(plans) == 1:
        raw = next(iter(plans.values()), None)
    return _override_from_raw(raw)


def _agent_redis_override(project_root: Path) -> WorkerOverride | None:
    """В контейнере агента нет своего decision.json. Размер пула лежит в Redis под ключом cluster."""
    try:
        from celery_balance.cluster import connect, load_plan
        from celery_balance.constants import CLUSTER_ON, ROLE_AGENT
        from celery_balance.settings import load_settings
    except ImportError:
        return None
    settings = load_settings(project_root)
    if settings.cluster != CLUSTER_ON or settings.cluster_role != ROLE_AGENT:
        return None
    client = connect(project_root)
    if client is None:
        return None
    plan = load_plan(client, settings.node_id)
    if not isinstance(plan, dict):
        return None
    plans = plan.get('plans')
    if not isinstance(plans, dict):
        return None
    raw = plans.get('cluster')
    if not isinstance(raw, dict) and len(plans) == 1:
        raw = next(iter(plans.values()), None)
    return _override_from_raw(raw)


def worker_override(
    project_root: Path,
    worker_name: str | None,
    *,
    mode: str | None = None,
) -> WorkerOverride | None:
    if mode is not None and mode != MODE_AUTO:
        return None
    remote = _agent_redis_override(project_root)
    if remote is not None:
        return remote
    data = load_decision(project_root)
    if not data:
        return None
    return _plans_override(data.get('plans'), worker_name)


def queue_pool_ceiling(project_root: Path, queues: list[str], floor: int | None = None) -> int | None:
    """Пул threads-воркера модуля: сумма max_parallel его очередей, не ниже floor.

    План общего воркера `all` урезан потолком VRAM и сюда не подходит. Лишний поток
    ничего не стоит: живое число задач очереди режет семафор по плану балансировщика.
    """
    from celery_balance.footprint_loader import load_footprints, resolve_footprint
    from celery_balance.settings import load_settings

    settings = load_settings(project_root)
    if settings.mode != MODE_AUTO or not queues:
        return floor
    catalog = load_footprints(str(project_root))
    ceiling = sum(max(1, resolve_footprint(name, catalog).max_parallel) for name in queues)
    if settings.max_concurrency:
        ceiling = min(ceiling, settings.max_concurrency)
    return max(ceiling, floor or 0) or None
