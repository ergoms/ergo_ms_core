"""
Сверка .env с .env.example (корень проекта и модули).

Используется: ergoms env
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

_DEPLOYMENT_DIR = Path(__file__).resolve().parent.parent
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))

from config_scaffold import (  # noqa: E402
    ConfigTemplateRegistry,
    EnvCompareResult,
    compare_env_files,
    parse_env_example_lines,
)


def _resolve_project_root(explicit: str | None) -> Path:
    if explicit:
        root = Path(explicit).resolve()
        if not root.is_dir():
            raise SystemExit(f'[ERROR] Корень проекта не существует: {root}')
        return root

    candidate = _DEPLOYMENT_DIR.parent.parent
    if (candidate / 'pyproject.toml').is_file():
        return candidate

    raise SystemExit('[ERROR] Не удалось определить корень проекта; укажите --root')


def _format_result(
    result: EnvCompareResult,
    *,
    show_example_values: bool,
) -> list[str]:
    lines: list[str] = []
    lines.append(f'=== {result.label} ===')
    lines.append(f'Файл .env: {result.env_path}')

    if result.errors:
        for error in result.errors:
            lines.append(f'Ошибка: {error}')
        return lines

    if result.missing:
        lines.append(f'Отсутствуют в .env ({len(result.missing)}):')
        example_lines = (
            parse_env_example_lines(result.example_path)
            if show_example_values
            else {}
        )
        for key in result.missing:
            if show_example_values and key in example_lines:
                lines.append(f'  {example_lines[key]}')
            else:
                lines.append(f'  {key}')
    else:
        lines.append('Отсутствующих ключей нет.')

    if result.extra:
        lines.append(f'Лишние в .env, нет в .env.example ({len(result.extra)}):')
        for key in result.extra:
            lines.append(f'  {key}')

    return lines


def run_check(
    project_root: Path,
    *,
    show_example_values: bool,
) -> int:
    pairs = ConfigTemplateRegistry.env_check_pairs(project_root)
    if not pairs:
        print('Не найдено пар .env.example → .env для проверки.')
        return 0

    total_missing = 0
    total_extra = 0
    has_errors = False
    checked = 0

    for index, pair in enumerate(pairs):
        if index:
            print()
        result = compare_env_files(
            label=pair.label,
            example_path=pair.example_path,
            env_path=pair.env_path,
        )
        if result.example_exists and result.env_exists:
            checked += 1
        if result.has_errors:
            has_errors = True
        total_missing += len(result.missing)
        total_extra += len(result.extra)
        print('\n'.join(_format_result(
            result,
            show_example_values=show_example_values,
        )))

    print()
    print(
        f'Проверено пар: {checked}. '
        f'Отсутствующих ключей: {total_missing}. '
        f'Лишних ключей: {total_extra}.'
    )
    if has_errors or total_missing or total_extra:
        print('Есть расхождения — см. выше.')
        return 1
    print('Расхождений нет.')
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description='Сверка .env с .env.example (корень проекта и модули)',
    )
    parser.add_argument('--root', help='Корень проекта')
    parser.add_argument(
        '--show-example-values',
        action='store_true',
        help='Для отсутствующих ключей вывести строку из .env.example',
    )
    parser.add_argument(
        '--strict',
        action='store_true',
        help='Код выхода 1 при расхождениях (для CI и скриптов)',
    )
    args = parser.parse_args(argv)

    project_root = _resolve_project_root(args.root)
    status = run_check(
        project_root,
        show_example_values=args.show_example_values,
    )
    if args.strict:
        return status
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
