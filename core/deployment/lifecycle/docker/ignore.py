"""Генерация секции .dockerignore для отключённых модулей (Docker build context)."""

from __future__ import annotations

from pathlib import Path

from lifecycle.docker.ops import (
    DOCKERIGNORE_BEGIN,
    DOCKERIGNORE_END,
    MODULES_DOCKERIGNORE_ARTIFACT,
)
from lifecycle.modules.catalog import ModuleCatalog


def build_disabled_modules_ignore_lines(catalog: ModuleCatalog) -> list[str]:
    lines = [DOCKERIGNORE_BEGIN, '# Автогенерация: ergoms docker-init / prepare_compose_artifacts']
    for name in sorted(catalog.disabled):
        lines.append(f'modules/{name}/')
    lines.append(DOCKERIGNORE_END)
    return lines


def write_modules_dockerignore_artifact(catalog: ModuleCatalog) -> Path:
    lines = build_disabled_modules_ignore_lines(catalog)
    MODULES_DOCKERIGNORE_ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
    MODULES_DOCKERIGNORE_ARTIFACT.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    return MODULES_DOCKERIGNORE_ARTIFACT


def merge_dockerignore_section(project_root: Path, catalog: ModuleCatalog) -> None:
    """Вставляет или обновляет секцию ERGO_DISABLED_MODULES в корневом .dockerignore."""
    dockerignore = project_root / '.dockerignore'

    if not catalog.disabled:
        if MODULES_DOCKERIGNORE_ARTIFACT.is_file():
            MODULES_DOCKERIGNORE_ARTIFACT.unlink()
        if dockerignore.is_file():
            from lifecycle.docker.ops import restore_dockerignore_section

            restore_dockerignore_section(project_root)
        return

    write_modules_dockerignore_artifact(catalog)
    section_lines = build_disabled_modules_ignore_lines(catalog)

    if not dockerignore.is_file():
        dockerignore.write_text('\n'.join(section_lines) + '\n', encoding='utf-8')
        return

    existing = dockerignore.read_text(encoding='utf-8').splitlines()
    out: list[str] = []
    in_section = False
    replaced = False

    for line in existing:
        if line.strip() == DOCKERIGNORE_BEGIN:
            in_section = True
            if not replaced:
                out.extend(section_lines)
                replaced = True
            continue
        if line.strip() == DOCKERIGNORE_END:
            in_section = False
            continue
        if in_section:
            continue
        out.append(line)

    if not replaced:
        if out and out[-1].strip():
            out.append('')
        out.extend(section_lines)

    dockerignore.write_text('\n'.join(out).rstrip() + '\n', encoding='utf-8')
