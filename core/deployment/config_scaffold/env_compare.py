"""Сравнение .env с .env.example (только stdlib)."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class EnvCompareResult:
    label: str
    example_path: Path
    env_path: Path
    example_exists: bool
    env_exists: bool
    missing: tuple[str, ...] = ()
    extra: tuple[str, ...] = ()
    errors: tuple[str, ...] = ()

    @property
    def has_missing(self) -> bool:
        return bool(self.missing)

    @property
    def has_errors(self) -> bool:
        return bool(self.errors)


def parse_env_keys(path: Path) -> set[str]:
    """Возвращает ключи активных строк KEY=VALUE (без комментариев)."""
    if not path.is_file():
        return set()

    keys: set[str] = set()
    for line in path.read_text(encoding='utf-8').splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            continue
        if '=' not in stripped:
            continue
        key, _ = stripped.split('=', 1)
        key = key.strip()
        if key:
            keys.add(key)
    return keys


def parse_env_example_lines(path: Path) -> dict[str, str]:
    """Возвращает {KEY: исходная строка} для активных записей в example-файле."""
    if not path.is_file():
        return {}

    lines: dict[str, str] = {}
    for line in path.read_text(encoding='utf-8').splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            continue
        if '=' not in stripped:
            continue
        key, _ = stripped.split('=', 1)
        key = key.strip()
        if key:
            lines[key] = stripped
    return lines


def compare_env_files(
    *,
    label: str,
    example_path: Path,
    env_path: Path,
) -> EnvCompareResult:
    errors: list[str] = []
    example_exists = example_path.is_file()
    env_exists = env_path.is_file()

    if not example_exists:
        errors.append(f'Файл .env.example не найден: {example_path}')
        return EnvCompareResult(
            label=label,
            example_path=example_path,
            env_path=env_path,
            example_exists=False,
            env_exists=env_exists,
            errors=tuple(errors),
        )

    if not env_exists:
        errors.append(f'Файл .env не найден: {env_path}')
        return EnvCompareResult(
            label=label,
            example_path=example_path,
            env_path=env_path,
            example_exists=True,
            env_exists=False,
            errors=tuple(errors),
        )

    example_keys = parse_env_keys(example_path)
    env_keys = parse_env_keys(env_path)
    missing = tuple(sorted(example_keys - env_keys))
    extra = tuple(sorted(env_keys - example_keys))

    return EnvCompareResult(
        label=label,
        example_path=example_path,
        env_path=env_path,
        example_exists=True,
        env_exists=True,
        missing=missing,
        extra=extra,
    )
