"""
Вывод сообщений ergoms в консоль с корректной UTF-8 кодировкой.

PowerShell 5.1 в Windows часто некорректно печатает кириллицу; Python — как ergoms help.
Каталог locales/<lang>/cli_messages.yaml — единый источник шаблонов для shell-скриптов ядра.
Метки консоли — только на английском (см. console_tags.py).
Язык: ERGO_CLI_LANGUAGE → системная локаль → ru (см. cli_locale.py).
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

_DEPLOYMENT_DIR = Path(__file__).resolve().parents[1]
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))

from cli_locale import (  # noqa: E402
    ensure_project_env_loaded,
    get_message_template,
    resolve_cli_language,
    t,
)
from console_tags import format_console  # noqa: E402

_COLORS = {
    'white': '\033[0m',
    'red': '\033[31m',
    'green': '\033[32m',
    'yellow': '\033[33m',
    'cyan': '\033[36m',
    'gray': '\033[90m',
}


def _detect_project_root() -> Path | None:
    candidate = _DEPLOYMENT_DIR.parent.parent
    if (candidate / 'pyproject.toml').is_file():
        return candidate
    return None


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
        template = get_message_template(key)
        if template is None:
            raise SystemExit(t('unknown_message_key', key=key))
        message = template.format(**params) if params else template
        if tag and not message.startswith('['):
            return format_console(tag, message)
        return message
    if text is not None:
        message = text
    else:
        raise SystemExit(t('specify_key_or_text'))

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
    root = _detect_project_root()
    ensure_project_env_loaded(root)
    resolve_cli_language(project_root=root)

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
