"""
Сборка .cursor/mcp.json из ядерного реестра и manifest модулей.

  ergoms mcp-list   — список всех MCP (ядро + модули)
  ergoms mcp-sync   — пересобрать mcp.json
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

_CURSOR_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = _CURSOR_DIR.parent
REGISTRY_PATH = _CURSOR_DIR / 'mcp.registry.yaml'
MCP_JSON_PATH = _CURSOR_DIR / 'mcp.json'
MODULES_DIR = PROJECT_ROOT / 'modules'
LAUNCHER = '.cursor/mcp_launcher.js'


@dataclass
class McpServerEntry:
    name: str
    description: str
    source: str
    script: str
    config: dict[str, Any]


def _load_registry() -> list[dict[str, Any]]:
    if not REGISTRY_PATH.is_file():
        raise SystemExit(f'[ERROR] Не найден реестр: {REGISTRY_PATH}')
    data = yaml.safe_load(REGISTRY_PATH.read_text(encoding='utf-8'))
    if not isinstance(data, dict):
        raise SystemExit('[ERROR] Некорректный формат mcp.registry.yaml')
    servers = data.get('servers')
    if not isinstance(servers, list):
        raise SystemExit('[ERROR] В mcp.registry.yaml ожидается список servers')
    return servers


def _discover_module_manifests() -> list[dict[str, Any]]:
    if not MODULES_DIR.is_dir():
        return []

    discovered: list[dict[str, Any]] = []
    for module_dir in sorted(MODULES_DIR.iterdir()):
        if not module_dir.is_dir() or module_dir.name.startswith('.'):
            continue
        manifest_path = module_dir / 'mcp' / 'manifest.yaml'
        if not manifest_path.is_file():
            continue
        data = yaml.safe_load(manifest_path.read_text(encoding='utf-8'))
        if not isinstance(data, dict):
            continue
        server = data.get('server')
        if not isinstance(server, dict):
            print(f'[WARNING] Пропуск {manifest_path}: нет блока server', file=sys.stderr)
            continue
        script_rel = str(server.get('script', '')).strip()
        if not script_rel:
            print(f'[WARNING] Пропуск {manifest_path}: не задан server.script', file=sys.stderr)
            continue
        script_path = module_dir / script_rel
        if not script_path.is_file():
            print(
                f'[WARNING] Пропуск {manifest_path}: файл не найден — {script_path.relative_to(PROJECT_ROOT)}',
                file=sys.stderr,
            )
            continue
        discovered.append({
            'module': data.get('module') or module_dir.name,
            'name': server.get('name', ''),
            'description': server.get('description', ''),
            'script': str(script_path.relative_to(PROJECT_ROOT)).replace('\\', '/'),
            'extra_args': server.get('extra_args') or [],
        })
    return discovered


def _registry_to_entry(item: dict[str, Any]) -> McpServerEntry:
    name = str(item.get('name', '')).strip()
    if not name:
        raise SystemExit('[ERROR] В реестре сервер без name')

    description = str(item.get('description', '')).strip()
    server_type = str(item.get('type', 'python')).strip().lower()

    if server_type == 'npx':
        package = str(item.get('package', '')).strip()
        if not package:
            raise SystemExit(f'[ERROR] Сервер {name}: для type=npx нужен package')
        args = ['-y', package] + list(item.get('args') or [])
        config = {
            'command': 'npx',
            'args': args,
        }
        script = f'npx {package}'
    elif server_type == 'python':
        script_rel = str(item.get('script', '')).strip()
        if not script_rel:
            raise SystemExit(f'[ERROR] Сервер {name}: для type=python нужен script')
        script_path = PROJECT_ROOT / script_rel
        if not script_path.is_file():
            raise SystemExit(f'[ERROR] Сервер {name}: файл не найден — {script_rel}')
        extra_args = list(item.get('extra_args') or [])
        config = {
            'command': 'node',
            'args': [LAUNCHER, script_rel.replace('\\', '/')] + extra_args,
        }
        script = script_rel.replace('\\', '/')
    else:
        raise SystemExit(f'[ERROR] Сервер {name}: неизвестный type={server_type}')

    return McpServerEntry(
        name=name,
        description=description,
        source='core',
        script=script,
        config=config,
    )


def _module_to_entry(item: dict[str, Any]) -> McpServerEntry:
    name = str(item.get('name', '')).strip()
    if not name:
        raise SystemExit('[ERROR] В manifest модуля не задан server.name')

    module = str(item.get('module', '')).strip()
    script = str(item.get('script', '')).replace('\\', '/')
    extra_args = list(item.get('extra_args') or [])

    return McpServerEntry(
        name=name,
        description=str(item.get('description', '')).strip(),
        source=f'module:{module}' if module else 'module',
        script=script,
        config={
            'command': 'node',
            'args': [LAUNCHER, script] + extra_args,
        },
    )


def collect_entries() -> list[McpServerEntry]:
    entries: list[McpServerEntry] = []

    for item in _load_registry():
        entries.append(_registry_to_entry(item))

    for item in _discover_module_manifests():
        entries.append(_module_to_entry(item))

    names = [e.name for e in entries]
    duplicates = {n for n in names if names.count(n) > 1}
    if duplicates:
        raise SystemExit(f'[ERROR] Дублирующиеся имена MCP: {", ".join(sorted(duplicates))}')

    return entries


def build_mcp_json(entries: list[McpServerEntry]) -> dict[str, Any]:
    servers: dict[str, Any] = {}
    for entry in sorted(entries, key=lambda e: e.name):
        servers[entry.name] = entry.config
    return {'mcpServers': servers}


def cmd_list() -> int:
    entries = collect_entries()
    if not entries:
        print('[INFO] MCP-серверы не найдены')
        return 0

    print(f'{"Name":<36} {"Source":<24} Script / package')
    print('-' * 90)
    for entry in entries:
        print(f'{entry.name:<36} {entry.source:<24} {entry.script}')
    print(f'\n[INFO] Total: {len(entries)}. Enable in Cursor: Settings -> Tools & MCP')
    return 0


def cmd_sync() -> int:
    entries = collect_entries()
    payload = build_mcp_json(entries)
    MCP_JSON_PATH.write_text(
        json.dumps(payload, ensure_ascii=False, indent=4) + '\n',
        encoding='utf-8',
    )
    print(f'[OK] Written {MCP_JSON_PATH.relative_to(PROJECT_ROOT)} ({len(entries)} servers)')
    print('[INFO] Reload MCP in Cursor: Settings -> Tools & MCP -> Reload')
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description='Сборка MCP-конфигурации Cursor')
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('list', help='Список всех MCP-серверов')
    sub.add_parser('sync', help='Пересобрать .cursor/mcp.json')
    args = parser.parse_args()

    if args.command == 'list':
        return cmd_list()
    if args.command == 'sync':
        return cmd_sync()
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
