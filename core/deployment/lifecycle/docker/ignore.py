"""Ignore для отключённых модулей в Docker build context.

Корневой `.dockerignore` — статический (в git). Эффективный ignore при
`DISABLED_MODULES` пишется рядом с Dockerfile как `Dockerfile.*.dockerignore`
(BuildKit подхватывает его вместо корневого).
"""

from __future__ import annotations

from pathlib import Path

from lifecycle.modules.catalog import ModuleCatalog

DOCKER_DIR = Path(__file__).resolve().parent.parent.parent / 'docker'

DOCKERIGNORE_BEGIN = '# BEGIN ERGO_DISABLED_MODULES'
DOCKERIGNORE_END = '# END ERGO_DISABLED_MODULES'
MODULES_DOCKERIGNORE_ARTIFACT = DOCKER_DIR / 'modules.dockerignore.generated'

# BuildKit: при `-f …/Dockerfile.python` читается `Dockerfile.python.dockerignore`
DOCKERFILE_DOCKERIGNORE_ARTIFACTS = (
    DOCKER_DIR / 'Dockerfile.python.dockerignore',
    DOCKER_DIR / 'Dockerfile.client.dockerignore',
)

DOCKERIGNORE_ARTIFACT_PATHS = (
    MODULES_DOCKERIGNORE_ARTIFACT,
    *DOCKERFILE_DOCKERIGNORE_ARTIFACTS,
)


def build_disabled_modules_ignore_lines(catalog: ModuleCatalog) -> list[str]:
    lines = [DOCKERIGNORE_BEGIN, '# Автогенерация: ergoms docker-init / prepare_compose_artifacts']
    for name in sorted(catalog.disabled):
        lines.append(f'modules/{name}/')
    lines.append(DOCKERIGNORE_END)
    return lines


def _strip_disabled_section(lines: list[str]) -> tuple[list[str], bool]:
    out: list[str] = []
    skip = False
    changed = False
    for line in lines:
        if line.strip() == DOCKERIGNORE_BEGIN:
            skip = True
            changed = True
            continue
        if line.strip() == DOCKERIGNORE_END:
            skip = False
            continue
        if skip:
            continue
        out.append(line)
    return out, changed


def clear_dockerignore_artifacts(project_root: Path | None = None) -> None:
    """Удаляет сгенерированные dockerignore-артефакты рядом с Dockerfile."""
    _ = project_root
    for path in DOCKERIGNORE_ARTIFACT_PATHS:
        if path.is_file():
            path.unlink()

def write_modules_dockerignore_artifact(catalog: ModuleCatalog) -> Path:
    lines = build_disabled_modules_ignore_lines(catalog)
    MODULES_DOCKERIGNORE_ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
    MODULES_DOCKERIGNORE_ARTIFACT.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    return MODULES_DOCKERIGNORE_ARTIFACT


def _read_root_dockerignore_base(project_root: Path) -> list[str]:
    dockerignore = project_root / '.dockerignore'
    if not dockerignore.is_file():
        return []
    lines = dockerignore.read_text(encoding='utf-8').splitlines()
    cleaned, _ = _strip_disabled_section(lines)
    return cleaned


def sync_dockerfile_dockerignore(project_root: Path, catalog: ModuleCatalog) -> None:
    """Синхронизирует Dockerfile.*.dockerignore и фрагмент modules.dockerignore.generated.

    Корневой `.dockerignore` не перезаписывается.
    """
    if not catalog.disabled:
        clear_dockerignore_artifacts(project_root=None)
        return

    write_modules_dockerignore_artifact(catalog)
    section_lines = build_disabled_modules_ignore_lines(catalog)
    base_lines = _read_root_dockerignore_base(project_root)
    out = list(base_lines)
    if out and out[-1].strip():
        out.append('')
    out.extend(section_lines)
    content = '\n'.join(out).rstrip() + '\n'

    for path in DOCKERFILE_DOCKERIGNORE_ARTIFACTS:
        path.write_text(content, encoding='utf-8')
