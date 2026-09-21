#!/usr/bin/env python3
"""
Один встроенный браузер Cursor на SSH-сессию: очередь в кэше проекта.

Без SSH хук сразу пропускает вызов и файлы очереди не трогает.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator

_DEPLOYMENT_DIR = Path(__file__).resolve().parents[1]
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))

from project_layout import cache_cursor_browser_queue_dir  # noqa: E402

_PROJECT_ROOT = _DEPLOYMENT_DIR.parent.parent

IDLE_SECONDS = 180
WAIT_SECONDS = 240
POLL_SECONDS = 0.4
ENV_FORCE = 'CURSOR_BROWSER_QUEUE'

_BROWSER_SERVERS = ('cursor-ide-browser',)


def _now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def _proc_comm(pid: int) -> str:
    path = Path(f'/proc/{pid}/comm')
    try:
        return path.read_text(encoding='utf-8').strip()
    except OSError:
        return ''


def _proc_ppid(pid: int) -> int:
    path = Path(f'/proc/{pid}/stat')
    try:
        text = path.read_text(encoding='utf-8')
        body = text.split(')', 1)[-1].strip().split()
        return int(body[1])
    except (OSError, IndexError, ValueError):
        return 0


def is_ssh_session(*, environ: dict[str, str] | None = None, pid: int | None = None) -> bool:
    env = environ if environ is not None else dict(os.environ)
    flag = (env.get(ENV_FORCE) or '').strip().lower()
    if flag in ('0', 'false', 'no', 'off'):
        return False
    if flag in ('1', 'true', 'yes', 'on'):
        return True
    if env.get('SSH_CONNECTION') or env.get('SSH_CLIENT') or env.get('SSH_TTY'):
        return True
    if os.name == 'nt':
        return False
    current = int(os.getpid() if pid is None else pid)
    seen: set[int] = set()
    while current > 1 and current not in seen:
        seen.add(current)
        comm = _proc_comm(current)
        if comm == 'sshd' or comm.startswith('sshd'):
            return True
        current = _proc_ppid(current)
    return False


def is_browser_mcp(payload: dict[str, Any]) -> bool:
    server = str(
        payload.get('mcp_server_name') or payload.get('server') or '',
    ).strip().lower()
    tool = str(payload.get('tool_name') or '').strip().lower()
    if server in _BROWSER_SERVERS or 'cursor-ide-browser' in server:
        return True
    return tool.startswith('browser_')


def owner_id(payload: dict[str, Any]) -> str:
    for key in ('conversation_id', 'session_id', 'generation_id'):
        value = str(payload.get(key) or '').strip()
        if value:
            return value
    return f'pid:{os.getpid()}'


def queue_paths(root: Path) -> tuple[Path, Path, Path]:
    folder = cache_cursor_browser_queue_dir(root)
    return folder / 'queue.json', folder / 'queue.lock', folder / 'queue.log'


def _empty_state() -> dict[str, Any]:
    return {'holder': None, 'waiters': []}


def _load_state(path: Path) -> dict[str, Any]:
    if not path.exists():
        return _empty_state()
    try:
        data = json.loads(path.read_text(encoding='utf-8'))
    except (OSError, json.JSONDecodeError):
        return _empty_state()
    if not isinstance(data, dict):
        return _empty_state()
    data.setdefault('holder', None)
    data.setdefault('waiters', [])
    if not isinstance(data['waiters'], list):
        data['waiters'] = []
    return data


def _save_state(path: Path, state: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(state, ensure_ascii=False, indent=2)
    path.write_text(text + '\n', encoding='utf-8')


def _append_log(path: Path, event: str, extra: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    row = {'ts': _now(), 'event': event, **extra}
    with path.open('a', encoding='utf-8') as handle:
        handle.write(json.dumps(row, ensure_ascii=False) + '\n')


@contextmanager
def _exclusive(lock_path: Path) -> Iterator[None]:
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    handle = open(lock_path, 'a+b')
    try:
        if os.name == 'nt':
            import msvcrt

            handle.seek(0)
            if handle.read(1) == b'':
                handle.write(b'0')
                handle.flush()
            handle.seek(0)
            msvcrt.locking(handle.fileno(), msvcrt.LK_LOCK, 1)
        else:
            import fcntl

            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        yield
    finally:
        try:
            if os.name == 'nt':
                import msvcrt

                handle.seek(0)
                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                import fcntl

                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        except OSError:
            pass
        handle.close()


def _parse_ts(value: str | None) -> float | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value).timestamp()
    except ValueError:
        return None


def _holder_stale(holder: dict[str, Any] | None, *, now: float, idle: float) -> bool:
    if not holder:
        return True
    stamp = _parse_ts(str(holder.get('heartbeat_at') or holder.get('acquired_at') or ''))
    if stamp is None:
        return True
    return (now - stamp) > idle


def _upsert_waiter(state: dict[str, Any], owner: str) -> None:
    waiters = [row for row in state['waiters'] if isinstance(row, dict)]
    found = False
    for row in waiters:
        if row.get('id') == owner:
            row['seen_at'] = _now()
            found = True
            break
    if not found:
        waiters.append({'id': owner, 'enqueued_at': _now(), 'seen_at': _now()})
    state['waiters'] = waiters


def acquire(
    root: Path,
    owner: str,
    *,
    tool: str = '',
    wait_seconds: float = WAIT_SECONDS,
    idle_seconds: float = IDLE_SECONDS,
    poll_seconds: float = POLL_SECONDS,
    now_fn=time.time,
    sleep_fn=time.sleep,
) -> dict[str, Any]:
    state_path, lock_path, log_path = queue_paths(root)
    deadline = time.monotonic() + max(0.0, wait_seconds)
    logged_wait = False
    while True:
        with _exclusive(lock_path):
            state = _load_state(state_path)
            holder = state.get('holder') if isinstance(state.get('holder'), dict) else None
            if holder and _holder_stale(holder, now=now_fn(), idle=idle_seconds):
                _append_log(log_path, 'steal', {
                    'owner': owner,
                    'from': holder.get('id'),
                    'tool': tool,
                })
                holder = None
                state['holder'] = None
            if holder is None or holder.get('id') == owner:
                granted = {
                    'id': owner,
                    'acquired_at': holder.get('acquired_at') if holder else _now(),
                    'heartbeat_at': _now(),
                    'tool': tool,
                }
                if not holder:
                    granted['acquired_at'] = _now()
                state['holder'] = granted
                state['waiters'] = [
                    row for row in state.get('waiters') or []
                    if isinstance(row, dict) and row.get('id') != owner
                ]
                _save_state(state_path, state)
                _append_log(log_path, 'acquire' if not holder else 'heartbeat', {
                    'owner': owner,
                    'tool': tool,
                    'waiters': [row.get('id') for row in state['waiters'] if isinstance(row, dict)],
                })
                return {'ok': True, 'state': state}
            _upsert_waiter(state, owner)
            _save_state(state_path, state)
            if not logged_wait:
                _append_log(log_path, 'wait', {
                    'owner': owner,
                    'holder': holder.get('id'),
                    'tool': tool,
                    'waiters': [row.get('id') for row in state['waiters'] if isinstance(row, dict)],
                })
                logged_wait = True
        if time.monotonic() >= deadline:
            with _exclusive(lock_path):
                state = _load_state(state_path)
                state['waiters'] = [
                    row for row in state.get('waiters') or []
                    if isinstance(row, dict) and row.get('id') != owner
                ]
                _save_state(state_path, state)
                _append_log(log_path, 'timeout', {
                    'owner': owner,
                    'holder': (state.get('holder') or {}).get('id') if isinstance(state.get('holder'), dict) else None,
                    'tool': tool,
                })
            return {'ok': False, 'state': state, 'error': 'timeout'}
        sleep_fn(poll_seconds)


def heartbeat(root: Path, owner: str, *, tool: str = '') -> None:
    state_path, lock_path, log_path = queue_paths(root)
    with _exclusive(lock_path):
        state = _load_state(state_path)
        holder = state.get('holder') if isinstance(state.get('holder'), dict) else None
        if holder and holder.get('id') == owner:
            holder['heartbeat_at'] = _now()
            if tool:
                holder['tool'] = tool
            state['holder'] = holder
            _save_state(state_path, state)


def release(root: Path, owner: str, *, reason: str = 'release') -> None:
    state_path, lock_path, log_path = queue_paths(root)
    with _exclusive(lock_path):
        state = _load_state(state_path)
        holder = state.get('holder') if isinstance(state.get('holder'), dict) else None
        if holder and holder.get('id') == owner:
            state['holder'] = None
            _append_log(log_path, reason, {'owner': owner})
        state['waiters'] = [
            row for row in state.get('waiters') or []
            if isinstance(row, dict) and row.get('id') != owner
        ]
        _save_state(state_path, state)


def _read_stdin() -> dict[str, Any]:
    if sys.stdin.isatty():
        return {}
    try:
        raw = sys.stdin.read()
    except OSError:
        return {}
    raw = (raw or '').strip()
    if not raw:
        return {}
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return data if isinstance(data, dict) else {}


def _print(payload: dict[str, Any]) -> int:
    print(json.dumps(payload, ensure_ascii=False))
    return 0


def _allow() -> dict[str, str]:
    return {'permission': 'allow'}


def hook_before(payload: dict[str, Any], root: Path) -> dict[str, Any]:
    if not is_browser_mcp(payload) or not is_ssh_session():
        return _allow()
    owner = owner_id(payload)
    tool = str(payload.get('tool_name') or '')
    result = acquire(root, owner, tool=tool)
    if result.get('ok'):
        return _allow()
    holder = ''
    state = result.get('state') or {}
    if isinstance(state.get('holder'), dict):
        holder = str(state['holder'].get('id') or '')
    message = (
        'Встроенный браузер по SSH занят другой сессией. '
        f'Держатель: {holder or "неизвестен"}. '
        'Повтори вызов, когда очередь освободится. '
        'Состояние: virtual_env/cache/cursor_browser_queue/queue.json'
    )
    return {
        'permission': 'deny',
        'agent_message': message,
        'user_message': 'Браузер агента ждёт очередь SSH (один сеанс одновременно).',
    }


def hook_after(payload: dict[str, Any], root: Path) -> dict[str, Any]:
    if is_browser_mcp(payload) and is_ssh_session():
        heartbeat(root, owner_id(payload), tool=str(payload.get('tool_name') or ''))
    return {}


def hook_release(payload: dict[str, Any], root: Path) -> dict[str, Any]:
    if is_ssh_session():
        release(root, owner_id(payload), reason=str(payload.get('hook_event_name') or 'release'))
    return {}


def hook_session(root: Path) -> dict[str, Any]:
    if not is_ssh_session():
        return {}
    return {
        'env': {ENV_FORCE: '1'},
        'additional_context': (
            'Эта сессия идёт по SSH: встроенный браузер Cursor общий. '
            'Хук ставит вызовы cursor-ide-browser в очередь — одновременно держит браузер одна сессия. '
            'Состояние и журнал: virtual_env/cache/cursor_browser_queue/ '
            '(queue.json и queue.log). Без SSH очередь не включается. '
            'Панель, lock и скриншот по-прежнему рвут SSH — не используй их.'
        ),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description='SSH queue for Cursor IDE browser')
    parser.add_argument('--hook-before', action='store_true')
    parser.add_argument('--hook-after', action='store_true')
    parser.add_argument('--hook-release', action='store_true')
    parser.add_argument('--hook-session', action='store_true')
    parser.add_argument('--status', action='store_true')
    parser.add_argument('--root', type=Path, default=None)
    args = parser.parse_args()
    root = args.root if args.root is not None else _PROJECT_ROOT
    payload = _read_stdin()
    if args.hook_before:
        return _print(hook_before(payload, root))
    if args.hook_after:
        return _print(hook_after(payload, root) or {})
    if args.hook_release:
        return _print(hook_release(payload, root) or {})
    if args.hook_session:
        return _print(hook_session(root))
    if args.status:
        state_path, _, _ = queue_paths(root)
        return _print(_load_state(state_path))
    parser.print_help()
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
