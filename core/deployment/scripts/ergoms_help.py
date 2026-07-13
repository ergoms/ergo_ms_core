"""
Справка ergoms: ядро, модули, отдельный модуль.

  ergoms help
  ergoms help modules
  ergoms help module <имя>
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Any

import yaml

_DEPLOYMENT_DIR = Path(__file__).resolve().parent.parent
_MANIFEST_PATH = _DEPLOYMENT_DIR / 'help.manifest.yaml'

_CONF_LINE = re.compile(r'^([a-zA-Z0-9_-]+)=(.+)$')

_BUILTIN_COMMANDS = frozenset({
    'help', 'install', 'install-services', 'install-api-service', 'install-client-service',
    'install-worker-service', 'install-beat-service', 'install-media-service',
    'start', 'stop', 'restart', 'status', 'uninstall-services',
    'install-cli', 'uninstall-cli', 'logs', 'setup-full', 'clean',
    'update-submodules', 'update-module-submodules',
    'install-nginx', 'install-nginx-service', 'uninstall-nginx',
    'start-nginx', 'stop-nginx', 'restart-nginx', 'reload-nginx',
    'status-nginx', 'test-nginx',
    'install-redis', 'install-redis-service', 'uninstall-redis',
    'start-redis', 'stop-redis', 'restart-redis', 'status-redis', 'test-redis',
    'install-tls', 'renew-tls', 'status-tls',
    'deploy-api', 'deploy-client', 'deploy-api-dev', 'deploy-client-dev', 'deploy-all',
})

_PLATFORM_LABELS = {
    'windows': 'Windows',
    'linux': 'Linux',
}


def _resolve_project_root(explicit: str | None) -> Path:
    if explicit:
        root = Path(explicit).resolve()
        if not root.is_dir():
            raise SystemExit(f'[ERROR] Корень проекта не найден: {root}')
        return root

    candidate = _DEPLOYMENT_DIR.parent.parent
    if (candidate / 'pyproject.toml').is_file():
        return candidate

    raise SystemExit('[ERROR] Не удалось определить корень проекта; укажите --root')


def _parse_conf_commands(path: Path) -> dict[str, str]:
    if not path.is_file():
        return {}

    commands: dict[str, str] = {}
    for raw_line in path.read_text(encoding='utf-8').splitlines():
        line = raw_line.strip()
        if not line or line.startswith('#') or line.startswith('='):
            continue
        match = _CONF_LINE.match(line)
        if match:
            commands[match.group(1).strip()] = match.group(2).strip()
    return commands


def _load_manifest() -> dict[str, Any]:
    if not _MANIFEST_PATH.is_file():
        raise SystemExit(f'[ERROR] Не найден файл {_MANIFEST_PATH}')
    data = yaml.safe_load(_MANIFEST_PATH.read_text(encoding='utf-8'))
    if not isinstance(data, dict):
        raise SystemExit('[ERROR] Некорректный формат help.manifest.yaml')
    return data


def _discover_module_confs(root: Path) -> dict[str, dict[str, str]]:
    modules: dict[str, dict[str, str]] = {}
    modules_dir = root / 'modules'
    if not modules_dir.is_dir():
        return modules

    for module_dir in sorted(modules_dir.iterdir()):
        if not module_dir.is_dir():
            continue
        conf_path = module_dir / 'ergoms.conf'
        if conf_path.is_file():
            commands = _parse_conf_commands(conf_path)
            if commands:
                modules[module_dir.name] = commands
    return modules


def _load_module_help_yaml(module_dir: Path) -> dict[str, Any] | None:
    help_path = module_dir / 'ergoms.help.yaml'
    if not help_path.is_file():
        return None
    data = yaml.safe_load(help_path.read_text(encoding='utf-8'))
    return data if isinstance(data, dict) else None


def _warn(message: str) -> None:
    print(message, file=sys.stderr)


def _command_exists(name: str, conf_commands: dict[str, str]) -> bool:
    return name in conf_commands or name in _BUILTIN_COMMANDS


def _command_invoke(name: str, item: dict[str, Any] | None = None) -> str:
    if item and item.get('invoke'):
        return str(item['invoke']).strip()
    return f'ergoms {name}'


def _format_command_line(
    name: str,
    summary: str,
    *,
    invoke: str | None = None,
    width: int = 42,
) -> str:
    label = invoke or f'ergoms {name}'
    padded = label.ljust(width)
    return f'  {padded} {summary}'


def _render_section_commands(
    section: dict[str, Any],
    conf_commands: dict[str, str],
    *,
    validate: bool,
) -> list[str]:
    lines: list[str] = []
    title = section.get('title')
    if title:
        lines.append(str(title))

    note = section.get('note')
    if note:
        lines.append(f'  {note}')

    for item in section.get('commands') or []:
        if isinstance(item, str):
            name, summary, entry = item, '', None
        else:
            name = item.get('name', '')
            summary = item.get('summary', '')
            entry = item
        if validate and name and not _command_exists(name, conf_commands):
            _warn(f'[WARNING] Команда «{name}» есть в help.manifest.yaml, но отсутствует в commands.conf и не встроена')
        if name:
            lines.append(_format_command_line(
                name,
                summary,
                invoke=_command_invoke(name, entry),
            ))

    for static_line in section.get('static_lines') or []:
        lines.append(f'  {static_line}')

    return lines


def render_core(root: Path, platform: str) -> str:
    manifest = _load_manifest()
    conf_commands = _parse_conf_commands(root / 'core' / 'deployment' / 'commands.conf')
    platform_label = _PLATFORM_LABELS.get(platform, platform)

    out: list[str] = [
        f'Справка ergoms ({platform_label})',
        '=' * (18 + len(platform_label)),
        '',
    ]

    for section in manifest.get('sections') or []:
        block = _render_section_commands(section, conf_commands, validate=True)
        if block:
            out.extend(block)
            out.append('')

    for section in (manifest.get('platform_sections') or {}).get(platform) or []:
        block = _render_section_commands(section, conf_commands, validate=True)
        if block:
            out.extend(block)
            out.append('')

    scenarios = manifest.get('scenarios') or []
    if scenarios:
        out.append('Типовые сценарии')
        for scenario in scenarios:
            out.append(f'  {scenario.get("title", "")}')
            for line in scenario.get('lines') or []:
                out.append(f'    {line}')
        out.append('')

    footer = manifest.get('footer') or {}
    doc = footer.get('doc')
    config = footer.get('config')
    if doc:
        out.append(f'Подробнее: {doc}')
    if config:
        out.append(f'Конфигурация команд: {config}')

    return '\n'.join(out).rstrip() + '\n'


def render_modules(root: Path) -> str:
    module_confs = _discover_module_confs(root)
    if not module_confs:
        return 'Модули с ergoms-командами не найдены.\n'

    out = [
        'Модули с командами ergoms',
        '=========================',
        '',
    ]

    for module_name, conf_commands in module_confs.items():
        module_dir = root / 'modules' / module_name
        help_data = _load_module_help_yaml(module_dir)
        count = len(conf_commands)

        if help_data:
            title = help_data.get('title') or module_name
            summary = help_data.get('summary') or ''
            label = f'{title} — {count} команд'
            if summary and summary not in label:
                label = f'{title} — {count} команд ({summary})'
            out.append(_format_command_line(module_name, label))
        else:
            out.append(_format_command_line(
                module_name,
                f'{count} команд (справка не оформлена: добавьте ergoms.help.yaml)',
            ))

    out.extend([
        '',
        'Подробнее: ergoms help module <имя>',
    ])
    return '\n'.join(out) + '\n'


def render_module(root: Path, module_name: str) -> str:
    module_confs = _discover_module_confs(root)
    if module_name not in module_confs:
        names = ', '.join(sorted(module_confs)) or '(нет модулей)'
        raise SystemExit(
            f'[ERROR] Модуль не найден: {module_name}\n'
            f'Доступные модули: {names}\n'
            f'Выполните: ergoms help modules',
        )

    module_dir = root / 'modules' / module_name
    conf_commands = module_confs[module_name]
    help_data = _load_module_help_yaml(module_dir) or {}

    if help_data.get('module') and help_data['module'] != module_name:
        _warn(
            f'[WARNING] module в ergoms.help.yaml ({help_data["module"]}) '
            f'не совпадает с каталогом ({module_name})',
        )

    title = help_data.get('title') or module_name
    summary = help_data.get('summary') or ''

    out = [
        f'Справка: {module_name}',
        f'{title}',
        '',
    ]
    if summary:
        out.append(summary)
        out.append('')

    help_commands = help_data.get('commands') or {}
    if not isinstance(help_commands, dict):
        help_commands = {}

    for cmd_name in sorted(conf_commands):
        cmd_summary = ''
        entry = help_commands.get(cmd_name)
        if isinstance(entry, dict):
            cmd_summary = entry.get('summary') or ''
        elif isinstance(entry, str):
            cmd_summary = entry
        elif entry is not None:
            cmd_summary = str(entry)

        if not cmd_summary:
            cmd_summary = '(описание не задано в ergoms.help.yaml)'
            _warn(f'[WARNING] Нет summary для команды «{cmd_name}» в modules/{module_name}/ergoms.help.yaml')

        full_name = f'{module_name}:{cmd_name}'
        out.append(_format_command_line(
            cmd_name,
            cmd_summary,
            invoke=f'ergoms {full_name}',
        ))
        out.append('')

    for key in sorted(help_commands):
        if key not in conf_commands:
            _warn(f'[WARNING] В ergoms.help.yaml есть «{key}», но нет в ergoms.conf')

    notes = help_data.get('notes') or []
    if notes:
        out.append('Примечания')
        for note in notes:
            out.append(f'  - {note}')
        out.append('')

    if not help_data:
        out.append(
            'Добавьте modules/{}/ergoms.help.yaml с описаниями команд.'.format(module_name),
        )

    return '\n'.join(out).rstrip() + '\n'


def resolve_help_subargs(help_subargs: list[str]) -> tuple[str, str | None]:
    if not help_subargs:
        return 'core', None
    if len(help_subargs) == 1 and help_subargs[0] == 'modules':
        return 'modules', None
    if len(help_subargs) >= 2 and help_subargs[0] == 'module':
        return 'module', help_subargs[1]
    if len(help_subargs) == 1 and help_subargs[0] == 'module':
        raise SystemExit(
            '[ERROR] Укажите модуль: ergoms help module <имя>\n'
            'Список модулей: ergoms help modules',
        )
    raise SystemExit(
        f'[ERROR] Неизвестный аргумент help: {" ".join(help_subargs)}\n'
        '  ergoms help | ergoms help modules | ergoms help module <имя>',
    )


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description='Справка ergoms')
    parser.add_argument('--root', help='Корень проекта ERGO MS')
    parser.add_argument(
        '--platform',
        choices=('windows', 'linux'),
        default='windows' if sys.platform == 'win32' else 'linux',
    )
    parser.add_argument(
        'help_subargs',
        nargs='*',
        help='modules | module <имя>',
    )
    return parser


def _configure_stdout_utf8() -> None:
    if hasattr(sys.stdout, 'reconfigure'):
        try:
            sys.stdout.reconfigure(encoding='utf-8', errors='replace')
        except (AttributeError, OSError, ValueError):
            pass
    if hasattr(sys.stderr, 'reconfigure'):
        try:
            sys.stderr.reconfigure(encoding='utf-8', errors='replace')
        except (AttributeError, OSError, ValueError):
            pass


def main() -> int:
    _configure_stdout_utf8()
    parser = _build_parser()
    args = parser.parse_args()
    root = _resolve_project_root(args.root)
    mode, module_name = resolve_help_subargs(args.help_subargs)

    if mode == 'core':
        sys.stdout.write(render_core(root, args.platform))
        return 0

    if mode == 'modules':
        sys.stdout.write(render_modules(root))
        return 0

    if mode == 'module':
        assert module_name is not None
        sys.stdout.write(render_module(root, module_name))
        return 0

    raise SystemExit(f'[ERROR] Неизвестный режим: {mode}')


if __name__ == '__main__':
    raise SystemExit(main())
