"""
Единый каталог модулей: FS + DISABLED_MODULES.

Используется в deployment lifecycle и через фасад module_registry в API.
"""

from __future__ import annotations

import os
from collections.abc import Iterator, Mapping
from pathlib import Path
from typing import FrozenSet

_SKIPPED_MODULE_DIR_NAMES = frozenset({'__pycache__'})


def parse_disabled_modules_raw(raw: str = '') -> frozenset[str]:
    return frozenset(m.strip() for m in raw.split(',') if m.strip())


class ModuleCatalog:
    """Реестр модулей на диске с учётом DISABLED_MODULES."""

    def __init__(
        self,
        project_root: Path,
        *,
        disabled: FrozenSet[str] | None = None,
        modules_dir_name: str = 'modules',
    ) -> None:
        self._project_root = project_root.resolve()
        self._modules_dir = self._project_root / modules_dir_name
        self._disabled = disabled if disabled is not None else frozenset()

    @classmethod
    def from_env(
        cls,
        project_root: Path,
        environ: Mapping[str, str] | None = None,
    ) -> ModuleCatalog:
        env = environ if environ is not None else os.environ
        raw = env.get('DISABLED_MODULES', '')
        return cls(project_root, disabled=parse_disabled_modules_raw(raw))

    @property
    def project_root(self) -> Path:
        return self._project_root

    @property
    def modules_dir(self) -> Path:
        return self._modules_dir

    @property
    def disabled(self) -> FrozenSet[str]:
        return self._disabled

    def is_disabled(self, module_name: str) -> bool:
        return module_name in self._disabled

    @staticmethod
    def is_valid_module_dir_name(name: str) -> bool:
        if not name or name.startswith('.'):
            return False
        return name not in _SKIPPED_MODULE_DIR_NAMES

    @staticmethod
    def is_populated_module_dir(path: Path) -> bool:
        """
        Есть содержимое модуля, а не пустой placeholder (неинициализированный submodule).

        Как в client ``listEnabledModuleNames``: нужен ``api/`` и/или ``client/``.
        Пустые каталоги не считаются установленными модулями и не попадают в каталоги UI.
        """
        if not path.is_dir():
            return False
        return (path / 'api').is_dir() or (path / 'client').is_dir()

    def enabled_names(self) -> list[str]:
        return self.list_module_names(include_disabled=False)

    def list_module_names(self, *, include_disabled: bool = False) -> list[str]:
        if not self._modules_dir.is_dir():
            return []

        names: list[str] = []
        for entry in self._modules_dir.iterdir():
            if not entry.is_dir() or not self.is_valid_module_dir_name(entry.name):
                continue
            if not self.is_populated_module_dir(entry):
                continue
            if not include_disabled and entry.name in self._disabled:
                continue
            names.append(entry.name)
        return sorted(names)

    def iter_module_dirs(self, *, include_disabled: bool = False) -> Iterator[Path]:
        for name in self.list_module_names(include_disabled=include_disabled):
            yield self._modules_dir / name
