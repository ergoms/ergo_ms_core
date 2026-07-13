"""
Вывод сообщений ergoms в консоль с корректной UTF-8 кодировкой.

PowerShell 5.1 в Windows часто некорректно печатает кириллицу; Python — как ergoms help.
Каталог _MESSAGES — единый источник повторяющихся шаблонов для shell-скриптов ядра.
Метки консоли — только на английском (см. console_tags.py).
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

_DEPLOYMENT_DIR = Path(__file__).resolve().parents[1]
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))

from console_tags import format_console  # noqa: E402

_COLORS = {
    'white': '\033[0m',
    'red': '\033[31m',
    'green': '\033[32m',
    'yellow': '\033[33m',
    'cyan': '\033[36m',
    'gray': '\033[90m',
}

_MESSAGES = {
    'unknown_command': format_console('error', 'Неизвестная команда: {name}'),
    'help_hint': 'Справка: ergoms help',
    'command_suggestions': 'Возможно, вы имели в виду: {items}',
    'command_failed': format_console('error', 'Команда завершилась с ошибкой: {name}'),
    'help_unavailable': 'Справка недоступна: не найдено виртуальное окружение.',
    'help_setup_hint': 'Выполните первичную настройку (ergoms setup или setup-full).',
    'help_doc_hint': 'Подробнее: .docs/cli.md',
    'venv_not_found': format_console('error', 'Виртуальное окружение не найдено'),
    'venv_not_found_at': format_console('error', 'Виртуальное окружение не найдено: {path}'),
    'venv_setup_hint': 'Сначала выполните ergoms python-install',
    'invalid_project_root': format_console('error', 'Некорректный корень проекта: {path} не найден'),
    'project_root_setup_hint': 'Выполните ergoms setup для инициализации всех submodule.',
    'project_structure_ok': format_console('ok', 'Структура проекта проверена'),
    'admin_required': format_console('error', 'Для команды «{name}» требуются права администратора'),
    'admin_powershell_hint': 'Запустите PowerShell от имени администратора',
    'service_name_required': format_console('error', 'Укажите имя службы'),
    'unknown_service': format_console('error', 'Неизвестная служба: {name}'),
    'logs_usage': 'Использование: ergoms logs <имя-службы> [строки]',
    'available_services': 'Доступные службы: {items}',
}


def _configure_stdio() -> None:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, 'reconfigure'):
            try:
                stream.reconfigure(encoding='utf-8', errors='replace')
            except (AttributeError, OSError, ValueError):
                pass


def _render_message(
    key: str | None,
    text: str | None,
    params: dict[str, str],
    tag: str | None,
) -> str:
    if key:
        template = _MESSAGES.get(key)
        if template is None:
            raise SystemExit(format_console('error', f'Неизвестный ключ сообщения: {key}'))
        message = template.format(**params)
    elif text is not None:
        message = text
    else:
        raise SystemExit(format_console('error', 'Укажите --key или --text'))

    if tag:
        if message.startswith('['):
            return message
        return format_console(tag, message)
    return message


def _format_line(message: str, color: str, stream) -> str:
    if getattr(stream, 'isatty', lambda: False)():
        tone = _COLORS.get(color.lower(), _COLORS['white'])
        return f'{tone}{message}{_COLORS["white"]}'
    return message


def main() -> int:
    _configure_stdio()

    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument('--stderr', action='store_true')
    parser.add_argument('--color', default='white')
    parser.add_argument('--key', default='')
    parser.add_argument('--text', default='')
    parser.add_argument('--tag', default='', choices=['ok', 'error', 'warning', 'skip', 'info', ''])
    parser.add_argument('--param', action='append', default=[])
    args, unknown = parser.parse_known_args()

    params: dict[str, str] = {}
    for item in args.param:
        if '=' not in item:
            continue
        key, value = item.split('=', 1)
        params[key] = value

    text = args.text or None
    if unknown:
        extra = ' '.join(unknown).strip()
        if extra.startswith('--'):
            extra = extra[2:].strip()
        if extra:
            text = extra if text is None else f'{text} {extra}'

    message = _render_message(args.key or None, text, params, args.tag or None)

    stream = sys.stderr if args.stderr else sys.stdout
    print(_format_line(message, args.color, stream), file=stream)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
