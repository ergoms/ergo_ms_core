"""
Классификация процессов ERGO MS на хосте для ergoms resource-usage.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator

import psutil

_DEPLOYMENT_DIR = Path(__file__).resolve().parent.parent
PROJECT_ROOT = _DEPLOYMENT_DIR.parent.parent
API_DIR = PROJECT_ROOT / 'core' / 'api'

CPU_SAMPLE_INTERVAL = 0.1
_MAX_PARENT_DEPTH = 64
_CANDIDATE_PROCESS_NAMES = frozenset(
    name.lower()
    for name in (
        'python.exe',
        'python',
        'node.exe',
        'node',
        'redis-server.exe',
        'redis-server',
        'nginx.exe',
        'nginx',
    )
)


@dataclass(frozen=True)
class ProcessSample:
    role: str
    pid: int
    name: str
    memory_mb: float
    cpu_percent: float


def normalize_path_text(path: Path | str) -> str:
    text = str(Path(path).resolve()).replace('\\', '/')
    if os.name == 'nt':
        return text.lower()
    return text


def normalize_cmdline_text(cmdline: list[str]) -> str:
    text = ' '.join(str(part) for part in cmdline if part).replace('\\', '/')
    if os.name == 'nt':
        return text.lower()
    return text


def _in_project(text: str, root_text: str) -> bool:
    return root_text in text


def _path_under_project(path_text: str, root_text: str) -> bool:
    return path_text == root_text or path_text.startswith(f'{root_text}/')


def _process_cwd_text(proc: psutil.Process) -> str | None:
    try:
        return normalize_path_text(proc.cwd())
    except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess, OSError):
        return None


def _is_celery_cmdline(text: str) -> bool:
    lowered = text.lower()
    if 'celery' not in lowered:
        return False
    first = lowered.split()[0] if lowered.split() else ''
    return 'python' in first or first.endswith('python') or first.endswith('python.exe')


def _classify_by_cmdline(cmdline: list[str], project_root: Path) -> str | None:
    if not cmdline:
        return None

    text = normalize_cmdline_text(cmdline)
    root_text = normalize_path_text(project_root)

    project_bound = (
        _in_project(text, root_text)
        or 'virtual_env/packages/redis' in text
        or 'core/deployment/nginx' in text
    )
    if not project_bound:
        return None

    if 'start_media_api.py' in text or 'core/media_api' in text:
        return 'media-api'
    if 'start_api.py' in text:
        return 'api'
    if 'start_celery_beat.py' in text or (_is_celery_cmdline(text) and ' beat' in f' {text.lower()}'):
        return 'celery-beat'
    if 'start_celery_worker.py' in text or (_is_celery_cmdline(text) and ' worker' in f' {text.lower()}'):
        return 'celery-worker'
    if 'start_jupyter.py' in text:
        return 'jupyter'
    if 'vite' in text and ('core/client' in text or _in_project(text, root_text)):
        return 'client'
    if 'redis-server' in text and (
        'virtual_env/packages/redis' in text or _in_project(text, root_text)
    ):
        return 'redis'
    if 'nginx' in text and 'core/deployment/nginx' in text:
        return 'nginx'
    if ('runserver' in text or 'daphne' in text) and 'core/api' in text:
        return 'api'
    if (
        'modules/ollama_framework' in text
        or 'virtual_env/packages/ollama' in text
        or ('ollama' in text and _in_project(text, root_text))
    ):
        return 'ollama'

    return None


def _classify_by_cwd(cmdline: list[str], cwd_text: str | None, project_root: Path) -> str | None:
    if not cmdline or not cwd_text:
        return None

    text = normalize_cmdline_text(cmdline)
    root_text = normalize_path_text(project_root)
    api_text = normalize_path_text(API_DIR)

    if not _path_under_project(cwd_text, root_text):
        return None

    if '-m commands' in text and ' dev' in f' {text} ' and _path_under_project(cwd_text, api_text):
        return 'api'
    if '-m celery' in text and ' src' in text:
        if ' beat' in f' {text} ':
            return 'celery-beat'
        if ' worker' in f' {text} ':
            return 'celery-worker'
    if 'media_server.manage' in text:
        return 'media-api'

    return None


def _needs_cwd_classify(cmdline: list[str]) -> bool:
    if not cmdline:
        return False
    text = normalize_cmdline_text(cmdline)
    return (
        '-m commands' in text
        or '-m celery' in text
        or 'media_server.manage' in text
    )


def _read_cmdline(proc: psutil.Process, cached: list[str] | None) -> list[str]:
    if cached:
        return cached
    try:
        return proc.cmdline() or []
    except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
        return []


def classify_process(proc: psutil.Process, project_root: Path, cmdline: list[str] | None = None) -> str | None:
    cmdline = _read_cmdline(proc, cmdline)

    role = _classify_by_cmdline(cmdline, project_root)
    if role is not None:
        return role

    if not _needs_cwd_classify(cmdline):
        return None

    return _classify_by_cwd(cmdline, _process_cwd_text(proc), project_root)


def _inherit_role(pid: int, roles: dict[int, str], parents: dict[int, int]) -> str | None:
    current = pid
    depth = 0
    while current and depth < _MAX_PARENT_DEPTH:
        role = roles.get(current)
        if role is not None:
            return role
        current = parents.get(current)
        depth += 1
    return None


def _resolve_process_roles(project_root: Path) -> dict[int, str]:
    entries: list[tuple[int, int, str]] = []
    parents: dict[int, int] = {}
    roles: dict[int, str] = {}
    cmdlines: dict[int, list[str]] = {}

    for proc in psutil.process_iter(['pid', 'ppid', 'name']):
        try:
            info = proc.info
            pid = int(info['pid'])
            ppid = int(info.get('ppid') or 0)
            name = str(info.get('name') or '')
            entries.append((pid, ppid, name))
            parents[pid] = ppid
        except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
            continue

    for pid, _ppid, name in entries:
        if name.lower() not in _CANDIDATE_PROCESS_NAMES:
            continue
        try:
            cmdline = psutil.Process(pid).cmdline() or []
        except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
            continue
        cmdlines[pid] = cmdline
        role = _classify_by_cmdline(cmdline, project_root)
        if role is not None:
            roles[pid] = role

    for pid, _ppid, _name in entries:
        if pid in roles:
            continue
        cmdline = cmdlines.get(pid)
        if cmdline is None:
            continue
        if not _needs_cwd_classify(cmdline):
            continue
        try:
            role = _classify_by_cwd(cmdline, _process_cwd_text(psutil.Process(pid)), project_root)
        except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
            continue
        if role is not None:
            roles[pid] = role

    for pid, _ppid, _name in entries:
        if pid in roles:
            continue
        inherited = _inherit_role(pid, roles, parents)
        if inherited is not None:
            roles[pid] = inherited

    return roles


def iter_ergo_processes(project_root: Path | None = None) -> Iterator[ProcessSample]:
    root = (project_root or PROJECT_ROOT).resolve()
    roles = _resolve_process_roles(root)
    if not roles:
        return

    matched: list[tuple[str, psutil.Process, str]] = []
    for pid in sorted(roles):
        role = roles[pid]
        try:
            proc = psutil.Process(pid)
            matched.append((role, proc, proc.name()))
        except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
            continue

    for _, proc, _ in matched:
        try:
            proc.cpu_percent(interval=None)
        except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
            continue

    if matched:
        psutil.cpu_percent(interval=CPU_SAMPLE_INTERVAL)

    for role, proc, name in matched:
        try:
            memory_mb = round(proc.memory_info().rss / (1024 * 1024), 1)
            cpu_percent = round(proc.cpu_percent(interval=None), 1)
            yield ProcessSample(
                role=role,
                pid=int(proc.pid),
                name=name,
                memory_mb=memory_mb,
                cpu_percent=cpu_percent,
            )
        except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
            continue
