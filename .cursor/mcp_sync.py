"""
Сборка .cursor/mcp.json из ядерного реестра и manifest модулей.

  ergoms mcp-list   — список всех MCP (ядро + модули)
  ergoms mcp-sync   — пересобрать mcp.json
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

_CURSOR_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = _CURSOR_DIR.parent
REGISTRY_PATH = _CURSOR_DIR / 'mcp.registry.yaml'
MCP_JSON_PATH = _CURSOR_DIR / 'mcp.json'
DATABASES_YAML = PROJECT_ROOT / 'databases.yaml'
MODULES_DIR = PROJECT_ROOT / 'modules'
LAUNCHER = '.cursor/mcp_launcher.js'


def _section_to_kebab(section: str) -> str:
    """Имя секции databases.yaml → kebab-case для ключа Cursor."""
    slug = re.sub(r'[^a-zA-Z0-9]+', '-', str(section).strip()).strip('-').lower()
    return slug or 'default'


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


def _python_entry(
    name: str,
    description: str,
    script_rel: str,
    extra_args: list[Any] | None = None,
    *,
    source: str = 'core',
) -> McpServerEntry:
    script_path = PROJECT_ROOT / script_rel
    if not script_path.is_file():
        raise SystemExit(f'[ERROR] Сервер {name}: файл не найден — {script_rel}')
    args = [LAUNCHER, script_rel.replace('\\', '/')] + list(extra_args or [])
    return McpServerEntry(
        name=name,
        description=description,
        source=source,
        script=script_rel.replace('\\', '/'),
        config={
            'command': 'node',
            'args': args,
        },
    )


def _databases_yaml_entries(item: dict[str, Any]) -> list[McpServerEntry]:
    """Разворачивает type=databases_yaml в одну запись Cursor на секцию databases.yaml."""
    script_rel = str(item.get('script', '')).strip()
    if not script_rel:
        raise SystemExit('[ERROR] type=databases_yaml: нужен script')

    prefix = str(item.get('name', 'ergo-database')).strip() or 'ergo-database'
    sections: dict[str, Any] = {}

    if DATABASES_YAML.is_file():
        try:
            data = yaml.safe_load(DATABASES_YAML.read_text(encoding='utf-8'))
        except Exception as e:
            print(f'[WARNING] Не удалось прочитать databases.yaml: {e}', file=sys.stderr)
            data = None
        if isinstance(data, dict) and isinstance(data.get('databases'), dict):
            sections = data['databases']
        else:
            print(
                '[WARNING] databases.yaml: нет словаря databases — '
                f'будет только {prefix}-default',
                file=sys.stderr,
            )
    else:
        print(
            f'[WARNING] Нет {DATABASES_YAML.name} — будет только {prefix}-default',
            file=sys.stderr,
        )

    if not sections:
        return [
            _python_entry(
                f'{prefix}-default',
                'default — секция из databases.yaml (файл отсутствует или пуст)',
                script_rel,
                ['default'],
            )
        ]

    entries: list[McpServerEntry] = []
    used_names: set[str] = set()
    for section_name, db_config in sections.items():
        kebab = _section_to_kebab(section_name)
        entry_name = f'{prefix}-{kebab}'
        if entry_name in used_names:
            raise SystemExit(
                f'[ERROR] type=databases_yaml: дублирующееся имя MCP после нормализации: {entry_name}'
            )
        used_names.add(entry_name)

        engine = 'postgresql'
        if isinstance(db_config, dict):
            engine = str(db_config.get('engine', 'postgresql')).strip().lower() or 'postgresql'

        description = f'{engine} — секция {section_name} из databases.yaml'
        entries.append(
            _python_entry(entry_name, description, script_rel, [str(section_name)])
        )
    return entries


def _registry_to_entries(item: dict[str, Any]) -> list[McpServerEntry]:
    name = str(item.get('name', '')).strip()
    if not name:
        raise SystemExit('[ERROR] В реестре сервер без name')

    description = str(item.get('description', '')).strip()
    server_type = str(item.get('type', 'python')).strip().lower()

    if server_type == 'databases_yaml':
        return _databases_yaml_entries(item)

    if server_type == 'npx':
        package = str(item.get('package', '')).strip()
        if not package:
            raise SystemExit(f'[ERROR] Сервер {name}: для type=npx нужен package')
        args = ['-y', package] + list(item.get('args') or [])
        return [
            McpServerEntry(
                name=name,
                description=description,
                source='core',
                script=f'npx {package}',
                config={
                    'command': 'npx',
                    'args': args,
                },
            )
        ]

    if server_type == 'python':
        script_rel = str(item.get('script', '')).strip()
        if not script_rel:
            raise SystemExit(f'[ERROR] Сервер {name}: для type=python нужен script')
        return [
            _python_entry(
                name,
                description,
                script_rel,
                list(item.get('extra_args') or []),
            )
        ]

    raise SystemExit(f'[ERROR] Сервер {name}: неизвестный type={server_type}')


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
        entries.extend(_registry_to_entries(item))

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
