"""Нормализация .env по структуре .env.example с сохранением значений."""

from __future__ import annotations

import shutil
from dataclasses import dataclass
from pathlib import Path

from .env_compare import _env_assignment_from_line, _env_key_from_line, parse_env_example_keys


@dataclass(frozen=True)
class EnvNormalizeResult:
    label: str
    example_path: Path
    env_path: Path
    created: bool = False
    updated: bool = False
    unchanged: bool = False
    added_keys: tuple[str, ...] = ()
    preserved_keys: tuple[str, ...] = ()
    extra_keys_kept: tuple[str, ...] = ()
    extra_keys_dropped: tuple[str, ...] = ()
    backed_up: bool = False
    errors: tuple[str, ...] = ()


def _parse_env_active_values(path: Path) -> dict[str, str]:
    """Активные KEY=VALUE из .env: ключ → значение (как в файле, после первого =)."""
    if not path.is_file():
        return {}

    values: dict[str, str] = {}
    for line in path.read_text(encoding='utf-8').splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            continue
        parsed = _env_assignment_from_line(stripped)
        if not parsed:
            continue
        key, assignment = parsed
        _, _, value = assignment.partition('=')
        values[key] = value
    return values


def _build_normalized_content(
    example_path: Path,
    env_values: dict[str, str],
    *,
    drop_extra: bool,
) -> tuple[str, set[str], set[str], set[str], set[str]]:
    """Собирает текст .env, возвращает (content, added, preserved, kept_extra, dropped_extra)."""
    example_text = example_path.read_text(encoding='utf-8')
    documented_keys = parse_env_example_keys(example_path)

    output_lines: list[str] = []
    added_keys: set[str] = set()
    preserved_keys: set[str] = set()

    for raw_line in example_text.splitlines():
        stripped = raw_line.strip()
        if not stripped:
            output_lines.append('')
            continue

        key = _env_key_from_line(stripped)
        if key is None:
            output_lines.append(raw_line)
            continue

        if key in env_values:
            preserved_keys.add(key)
            output_lines.append(f'{key}={env_values[key]}')
            continue

        parsed = _env_assignment_from_line(stripped)
        if parsed and stripped.startswith('#'):
            output_lines.append(raw_line)
            continue

        added_keys.add(key)
        if parsed:
            _, assignment = parsed
            output_lines.append(assignment)
        else:
            output_lines.append(raw_line)

    extra_keys = sorted(set(env_values) - documented_keys)
    kept_extra: set[str] = set()
    dropped_extra: set[str] = set()

    if extra_keys:
        if drop_extra:
            dropped_extra.update(extra_keys)
        else:
            kept_extra.update(extra_keys)
            output_lines.append('')
            output_lines.append('# --- не в .env.example (сохранено при нормализации) ---')
            for key in extra_keys:
                output_lines.append(f'{key}={env_values[key]}')

    content = '\n'.join(output_lines)
    if example_text.endswith('\n') or example_text.endswith('\r\n'):
        content += '\n'

    return content, added_keys, preserved_keys, kept_extra, dropped_extra


def normalize_env_file(
    *,
    label: str,
    example_path: Path,
    env_path: Path,
    drop_extra: bool = False,
    dry_run: bool = False,
    backup: bool = True,
) -> EnvNormalizeResult:
    if not example_path.is_file():
        return EnvNormalizeResult(
            label=label,
            example_path=example_path,
            env_path=env_path,
            errors=(f'Файл .env.example не найден: {example_path}',),
        )

    if not env_path.is_file():
        content = example_path.read_text(encoding='utf-8')
        if not dry_run:
            env_path.parent.mkdir(parents=True, exist_ok=True)
            env_path.write_text(content, encoding='utf-8')
        return EnvNormalizeResult(
            label=label,
            example_path=example_path,
            env_path=env_path,
            created=True,
            updated=not dry_run,
        )

    env_values = _parse_env_active_values(env_path)
    content, added, preserved, kept_extra, dropped_extra = _build_normalized_content(
        example_path,
        env_values,
        drop_extra=drop_extra,
    )

    current = env_path.read_text(encoding='utf-8')
    if current == content:
        return EnvNormalizeResult(
            label=label,
            example_path=example_path,
            env_path=env_path,
            unchanged=True,
            preserved_keys=tuple(sorted(preserved)),
            extra_keys_kept=tuple(sorted(kept_extra)),
            extra_keys_dropped=tuple(sorted(dropped_extra)),
        )

    if not dry_run:
        backed_up = False
        if backup:
            backup_path = env_path.with_name(env_path.name + '.bak')
            shutil.copy2(env_path, backup_path)
            backed_up = True
        env_path.write_text(content, encoding='utf-8')
    else:
        backed_up = False

    return EnvNormalizeResult(
        label=label,
        example_path=example_path,
        env_path=env_path,
        updated=not dry_run,
        added_keys=tuple(sorted(added)),
        preserved_keys=tuple(sorted(preserved)),
        extra_keys_kept=tuple(sorted(kept_extra)),
        extra_keys_dropped=tuple(sorted(dropped_extra)),
        backed_up=backed_up,
    )
