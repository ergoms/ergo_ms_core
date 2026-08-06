"""AST-скан ObjectPermissionMixin в core/api (С8 phase 1)."""

from __future__ import annotations

import ast
from pathlib import Path
from typing import Any

from security.catalog import Control, SecurityCatalog
from security.report import Finding

_MIXIN_NAME = 'ObjectPermissionMixin'
_OPTIONAL = frozenset({None, False, 'false', 'no', 'optional', 'none'})


def _sev(control: Control) -> str:
    return 'error' if control.violation == 'error' else 'warning'


def find_object_permission_mixin(core_api_src: Path) -> Path | None:
    """Ищет class ObjectPermissionMixin в core/api/src/core (первый hit)."""
    root = core_api_src / 'core'
    if not root.is_dir():
        return None
    for path in root.rglob('*.py'):
        if '__pycache__' in path.parts:
            continue
        try:
            source = path.read_text(encoding='utf-8')
        except OSError:
            continue
        try:
            tree = ast.parse(source, filename=str(path))
        except SyntaxError:
            continue
        for node in tree.body:
            if isinstance(node, ast.ClassDef) and node.name == _MIXIN_NAME:
                return path
    return None


def run(control: Control, catalog: SecurityCatalog, context: dict[str, Any]) -> Finding:
    level = context['level']
    requirement = control.requirement(level)
    root = Path(context['root'])
    core_api_src = root / 'core' / 'api' / 'src'

    mixin_path = find_object_permission_mixin(core_api_src)
    mixin_present = mixin_path is not None

    if requirement in _OPTIONAL:
        if mixin_present:
            rel = mixin_path.relative_to(root).as_posix() if mixin_path else ''
            return Finding(
                control_id=control.id,
                title=control.title,
                severity='ok',
                message=f'на уровне {level} не обязательны; mixin найден ({rel})',
            )
        return Finding(
            control_id=control.id,
            title=control.title,
            severity='ok',
            message=f'на уровне {level} object-level permissions не обязательны',
        )

    # hardened / maximum: required | required_auto
    if not mixin_present:
        return Finding(
            control_id=control.id,
            title=control.title,
            severity=_sev(control),
            message=(
                f'уровень {level} требует object-level permissions, '
                f'но класс {_MIXIN_NAME} не найден в core/api/src/core'
            ),
        )

    rel = mixin_path.relative_to(root).as_posix()
    # Phase 1: mixin есть, массовая миграция ViewSet ещё не сделана.
    return Finding(
        control_id=control.id,
        title=control.title,
        severity='warning',
        message=(
            f'phase 1: mixin present ({rel}), views not fully migrated; '
            f'уровень {level} требует {requirement}'
        ),
    )
