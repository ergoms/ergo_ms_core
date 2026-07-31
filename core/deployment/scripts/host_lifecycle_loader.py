"""
Загрузка modules/*/host_lifecycle.yaml для тестовых и stop-all сценариев.

Discovery через ModuleCatalog. Вне Django — только YAML.
CLI: python host_lifecycle_loader.py --root PATH --json
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict, dataclass, field
from functools import lru_cache
from pathlib import Path
from typing import Any

import yaml

_SCRIPTS_DIR = Path(__file__).resolve().parent
_DEPLOYMENT_DIR = _SCRIPTS_DIR.parent
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))

from cli_locale import t  # noqa: E402
from console_tags import format_console  # noqa: E402
from lifecycle.modules.catalog import ModuleCatalog  # noqa: E402

HOST_LIFECYCLE_FILENAME = 'host_lifecycle.yaml'


@dataclass(frozen=True)
class HostLifecycleEntry:
    module: str
    stop_commands: tuple[str, ...] = ()
    install_service_commands: tuple[str, ...] = ()
    service_units: tuple[str, ...] = ()


@dataclass
class HostLifecycleAggregate:
    stop_commands: list[str] = field(default_factory=list)
    install_service_commands: list[str] = field(default_factory=list)
    service_units: list[str] = field(default_factory=list)
    modules: list[str] = field(default_factory=list)


def _warn(message: str) -> None:
    print(format_console('warning', message), file=sys.stderr)


def _as_str_list(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        text = value.strip()
        return [text] if text else []
    if isinstance(value, (list, tuple)):
        items: list[str] = []
        for item in value:
            if not isinstance(item, str):
                continue
            text = item.strip()
            if text:
                items.append(text)
        return items
    return []


def _parse_file(path: Path, *, module_dir_name: str) -> HostLifecycleEntry | None:
    try:
        text = path.read_text(encoding='utf-8')
    except OSError as exc:
        _warn(t('yaml_read_failed', path=path, exc=exc))
        return None

    if not text.strip():
        _warn(t('yaml_file_empty', path=path))
        return None

    try:
        data = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        _warn(t('yaml_parse_error', path=path, exc=exc))
        return None

    if not isinstance(data, dict):
        _warn(t('yaml_root_must_be_object', path=path))
        return None

    module = str(data.get('module') or module_dir_name).strip() or module_dir_name
    host = data.get('host')
    if host is None:
        # Допускаем плоский формат без обёртки host:
        host = {
            'stop_commands': data.get('stop_commands'),
            'install_service_commands': data.get('install_service_commands'),
            'service_units': data.get('service_units'),
        }
    if not isinstance(host, dict):
        _warn(t('host_section_must_be_object', path=path))
        return None

    stop = tuple(_as_str_list(host.get('stop_commands')))
    install = tuple(_as_str_list(host.get('install_service_commands')))
    units = tuple(_as_str_list(host.get('service_units')))

    if not stop and not install and not units:
        _warn(t('host_section_empty', path=path))
        return None

    return HostLifecycleEntry(
        module=module,
        stop_commands=stop,
        install_service_commands=install,
        service_units=units,
    )


@lru_cache(maxsize=8)
def load_host_lifecycle_entries(project_root: str) -> tuple[HostLifecycleEntry, ...]:
    root = Path(project_root).resolve()
    catalog = ModuleCatalog.from_env(root)
    entries: list[HostLifecycleEntry] = []

    for module_dir in catalog.iter_module_dirs():
        path = module_dir / HOST_LIFECYCLE_FILENAME
        if not path.is_file():
            continue
        entry = _parse_file(path, module_dir_name=module_dir.name)
        if entry is not None:
            entries.append(entry)

    return tuple(entries)


def aggregate_host_lifecycle(project_root: Path | str) -> HostLifecycleAggregate:
    entries = load_host_lifecycle_entries(str(Path(project_root).resolve()))
    agg = HostLifecycleAggregate()
    seen_stop: set[str] = set()
    seen_install: set[str] = set()
    seen_units: set[str] = set()

    for entry in entries:
        agg.modules.append(entry.module)
        for cmd in entry.stop_commands:
            if cmd not in seen_stop:
                seen_stop.add(cmd)
                agg.stop_commands.append(cmd)
        for cmd in entry.install_service_commands:
            if cmd not in seen_install:
                seen_install.add(cmd)
                agg.install_service_commands.append(cmd)
        for unit in entry.service_units:
            if unit not in seen_units:
                seen_units.add(unit)
                agg.service_units.append(unit)

    return agg


def dump_host_lifecycle_json(project_root: Path | str) -> str:
    agg = aggregate_host_lifecycle(project_root)
    return json.dumps(asdict(agg), ensure_ascii=False)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=t('host_lifecycle_description'))
    parser.add_argument('--root', type=Path, default=None, help=t('help_root_path'))
    parser.add_argument('--json', action='store_true', help=t('help_json_stdout'))
    args = parser.parse_args(argv)

    root = args.root
    if root is None:
        # scripts → deployment → core → project
        root = _DEPLOYMENT_DIR.parent.parent
    root = root.resolve()
    if not (root / 'pyproject.toml').is_file():
        print(format_console('error', t('project_root_not_found', root=root)), file=sys.stderr)
        return 1

    if args.json:
        print(dump_host_lifecycle_json(root))
        return 0

    agg = aggregate_host_lifecycle(root)
    print(t('modules_list', items=', '.join(agg.modules) or t('modules_none')))
    print(f'stop_commands: {len(agg.stop_commands)}')
    for cmd in agg.stop_commands:
        print(f'  - {cmd}')
    print(f'install_service_commands: {len(agg.install_service_commands)}')
    for cmd in agg.install_service_commands:
        print(f'  - {cmd}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
