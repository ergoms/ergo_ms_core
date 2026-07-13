"""
Режим технических работ: флаг-файл для nginx, API и Media API.

ergoms maintenance-on | maintenance-off | maintenance-status
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

_DEPLOYMENT_DIR = Path(__file__).resolve().parent.parent
PROJECT_ROOT = _DEPLOYMENT_DIR.parent.parent

MAINTENANCE_FLAG_NAME = 'maintenance.flag'
MAINTENANCE_HTML_REL = Path('core') / 'deployment' / 'nginx' / 'maintenance' / 'index.html'
MAINTENANCE_DETAIL = 'Система временно недоступна. Мы проводим обновление и скоро вернёмся.'
# Синхронизировать с core/client/src/js/maintenanceConfig.js
MAINTENANCE_POLL_INTERVAL_MS = 3000
MAINTENANCE_JSON_REL_PATHS = (
    Path('core') / 'client' / 'public' / 'maintenance.json',
    Path('core') / 'client' / 'dist' / 'maintenance.json',
)


def resolve_root(explicit: str | None) -> Path:
    if explicit:
        root = Path(explicit).resolve()
        if not root.is_dir():
            raise SystemExit(f'[ERROR] Каталог проекта не найден: {root}')
        return root
    if (PROJECT_ROOT / 'pyproject.toml').is_file():
        return PROJECT_ROOT
    raise SystemExit('[ERROR] Не удалось определить корень проекта; укажите --root')


def flag_path(root: Path) -> Path:
    return root / MAINTENANCE_FLAG_NAME


def html_path(root: Path) -> Path:
    return root / MAINTENANCE_HTML_REL


def json_paths(root: Path) -> list[Path]:
    return [root / rel for rel in MAINTENANCE_JSON_REL_PATHS]


def maintenance_json_payload(*, enabled: bool) -> dict[str, object]:
    payload: dict[str, object] = {
        'maintenance': enabled,
        'pollIntervalMs': MAINTENANCE_POLL_INTERVAL_MS,
    }
    if enabled:
        payload['detail'] = MAINTENANCE_DETAIL
    return payload


def write_maintenance_json(root: Path, *, enabled: bool) -> list[Path]:
    content = json.dumps(maintenance_json_payload(enabled=enabled), ensure_ascii=False, indent=2) + '\n'
    written: list[Path] = []
    for path in json_paths(root):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding='utf-8')
        written.append(path)
    return written


def cmd_on(root: Path) -> int:
    flag = flag_path(root)
    page = html_path(root)
    if not page.is_file():
        print(f'[WARNING] Страница заглушки не найдена: {page}', file=sys.stderr)
        print('[WARNING] Nginx может вернуть 503 без HTML.', file=sys.stderr)
    flag.touch()
    json_written = write_maintenance_json(root, enabled=True)
    print('[OK] Режим технических работ включён')
    print(f'     Флаг: {flag}')
    for path in json_written:
        print(f'     JSON: {path}')
    print('     Выключить: ergoms maintenance-off')
    return 0


def cmd_off(root: Path) -> int:
    flag = flag_path(root)
    if flag.is_file():
        flag.unlink()
        print('[OK] Режим технических работ выключён')
    else:
        print('[OK] Режим технических работ уже выключен')
    json_written = write_maintenance_json(root, enabled=False)
    print(f'     Флаг: {flag}')
    for path in json_written:
        print(f'     JSON: {path}')
    return 0


def cmd_status(root: Path) -> int:
    flag = flag_path(root)
    page = html_path(root)
    if flag.is_file():
        mtime = datetime.fromtimestamp(flag.stat().st_mtime, tz=timezone.utc).astimezone()
        print('Статус: ON (заглушка для пользователей)')
        print(f'Флаг:   {flag}')
        print(f'С:      {mtime:%Y-%m-%d %H:%M:%S %Z}')
    else:
        print('Статус: OFF (сайт доступен)')
        print(f'Флаг:   {flag} (отсутствует)')
    page_state = 'есть' if page.is_file() else 'нет'
    print(f'HTML:   {page} ({page_state})')
    for path in json_paths(root):
        state = 'есть' if path.is_file() else 'нет'
        print(f'JSON:   {path} ({state})')
    return 0


def main() -> int:
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
    if hasattr(sys.stderr, 'reconfigure'):
        sys.stderr.reconfigure(encoding='utf-8')

    parser = argparse.ArgumentParser(description='Режим технических работ (флаг maintenance.flag)')
    parser.add_argument('action', choices=('on', 'off', 'status'))
    parser.add_argument('--root', default=None, help='Корень проекта ERGO MS')
    args = parser.parse_args()
    root = resolve_root(args.root)

    if args.action == 'on':
        return cmd_on(root)
    if args.action == 'off':
        return cmd_off(root)
    return cmd_status(root)


if __name__ == '__main__':
    raise SystemExit(main())
