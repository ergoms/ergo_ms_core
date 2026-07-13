"""
Нормализация .env по .env.example (корень проекта и модули).

Сохраняет существующие значения, добавляет недостающие ключи, выравнивает порядок
и комментарии по шаблону. Используется: ergoms env-normalize
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

_DEPLOYMENT_DIR = Path(__file__).resolve().parent.parent
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))

from config_scaffold import ConfigTemplateRegistry, EnvNormalizeResult, normalize_env_file  # noqa: E402


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


def _format_result(result: EnvNormalizeResult, *, dry_run: bool) -> list[str]:
    lines: list[str] = []
    lines.append(f'=== {result.label} ===')
    lines.append(f'Файл .env: {result.env_path}')

    if result.errors:
        for error in result.errors:
            lines.append(f'Ошибка: {error}')
        return lines

    if result.created:
        action = 'будет создан' if dry_run else 'создан'
        lines.append(f'Файл {action} из .env.example.')
        return lines

    if result.unchanged:
        lines.append('Изменений не требуется.')
        return lines

    action = 'будет обновлён' if dry_run else 'обновлён'
    lines.append(f'Файл {action}.')
    if result.added_keys:
        lines.append(f'Добавлены ключи ({len(result.added_keys)}):')
        for key in result.added_keys:
            lines.append(f'  {key}')
    if result.preserved_keys:
        lines.append(f'Сохранены значения ({len(result.preserved_keys)} ключей).')
    if result.extra_keys_kept:
        lines.append(f'Лишние ключи сохранены в конце ({len(result.extra_keys_kept)}):')
        for key in result.extra_keys_kept:
            lines.append(f'  {key}')
    if result.extra_keys_dropped:
        lines.append(f'Лишние ключи будут удалены ({len(result.extra_keys_dropped)}):')
        for key in result.extra_keys_dropped:
            lines.append(f'  {key}')
    if result.backed_up:
        lines.append(f'Резервная копия: {result.env_path.name}.bak')
    return lines


def run_normalize(
    project_root: Path,
    *,
    dry_run: bool,
    drop_extra: bool,
    backup: bool,
    only: str | None,
) -> int:
    pairs = ConfigTemplateRegistry.env_check_pairs(project_root)
    if only:
        only_norm = only.replace('\\', '/')
        pairs = [
            pair for pair in pairs
            if pair.label == only
            or pair.label.replace('\\', '/') == only_norm
            or pair.env_path.as_posix().endswith(only_norm)
        ]
        if not pairs:
            print(f'Не найдена пара для --only={only!r}.')
            return 1

    if not pairs:
        print('Не найдено пар .env.example → .env для нормализации.')
        return 0

    has_errors = False
    changed = 0

    for index, pair in enumerate(pairs):
        if index:
            print()
        result = normalize_env_file(
            label=pair.label,
            example_path=pair.example_path,
            env_path=pair.env_path,
            drop_extra=drop_extra,
            dry_run=dry_run,
            backup=backup and not dry_run,
        )
        if result.errors:
            has_errors = True
        elif not result.unchanged:
            changed += 1
        print('\n'.join(_format_result(result, dry_run=dry_run)))

    print()
    prefix = 'Проверено (dry-run)' if dry_run else 'Обработано'
    print(f'{prefix} пар: {len(pairs)}. Изменено: {changed}.')
    if dry_run:
        print('Запустите без --dry-run, чтобы применить изменения.')
    return 1 if has_errors else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description='Нормализация .env по .env.example с сохранением значений',
    )
    parser.add_argument('--root', help='Корень проекта')
    parser.add_argument(
        '--dry-run',
        action='store_true',
        help='Показать изменения без записи в файлы',
    )
    parser.add_argument(
        '--drop-extra',
        action='store_true',
        help='Удалить ключи, которых нет в .env.example (по умолчанию сохраняются в конце файла)',
    )
    parser.add_argument(
        '--no-backup',
        action='store_true',
        help='Не создавать .env.bak перед записью',
    )
    parser.add_argument(
        '--only',
        metavar='PATH',
        help='Только одна пара, например modules/bi_analysis/.env или «.env (корень)»',
    )
    args = parser.parse_args(argv)

    project_root = _resolve_project_root(args.root)
    return run_normalize(
        project_root,
        dry_run=args.dry_run,
        drop_extra=args.drop_extra,
        backup=not args.no_backup,
        only=args.only,
    )


if __name__ == '__main__':
    raise SystemExit(main())
