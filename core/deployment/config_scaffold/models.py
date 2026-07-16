"""Модели результата и описания шаблона конфигурации."""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from pathlib import Path

from .strategies import CopyStrategy, FullCopyStrategy


class ScaffoldAction(str, Enum):
    CREATED = 'created'
    SKIPPED_EXISTS = 'skipped_exists'
    SKIPPED_NO_SOURCE = 'skipped_no_source'
    FAILED = 'failed'


@dataclass(frozen=True)
class ScaffoldResult:
    source_rel: str
    target_rel: str
    action: ScaffoldAction
    detail: str = ''

    @property
    def display_target(self) -> str:
        return self.target_rel.replace('\\', '/')


@dataclass(frozen=True)
class EnvFilePair:
    label: str
    example_path: Path
    env_path: Path


@dataclass(frozen=True)
class ConfigTemplate:
    source_rel: str
    target_rel: str
    strategy: CopyStrategy
    created_detail: str = ''

    def execute(self, project_root: Path) -> ScaffoldResult:
        source = project_root / self.source_rel
        target = project_root / self.target_rel
        source_display = self.source_rel.replace('\\', '/')
        target_display = self.target_rel.replace('\\', '/')

        if not source.is_file():
            return ScaffoldResult(source_display, target_display, ScaffoldAction.SKIPPED_NO_SOURCE)

        if target.exists():
            return ScaffoldResult(source_display, target_display, ScaffoldAction.SKIPPED_EXISTS)

        try:
            target.parent.mkdir(parents=True, exist_ok=True)
            self.strategy.copy(source, target)
            return ScaffoldResult(
                source_display,
                target_display,
                ScaffoldAction.CREATED,
                self.created_detail,
            )
        except OSError as exc:
            return ScaffoldResult(
                source_display,
                target_display,
                ScaffoldAction.FAILED,
                str(exc),
            )


class ConfigTemplateRegistry:
    """Реестр шаблонов: корень проекта и модульные .env."""

    @staticmethod
    def project_templates() -> list[ConfigTemplate]:
        from .strategies import HeadLinesCopyStrategy

        return [
            ConfigTemplate(
                'databases.yaml.example',
                'databases.yaml',
                HeadLinesCopyStrategy(8),
                created_detail='first 8 lines',
            ),
            ConfigTemplate(
                'celery_workers.yaml.example',
                'celery_workers.yaml',
                FullCopyStrategy(),
            ),
            ConfigTemplate(
                '.env.example',
                '.env',
                FullCopyStrategy(),
            ),
        ]

    @staticmethod
    def module_env_templates(project_root: Path) -> list[ConfigTemplate]:
        modules_dir = project_root / 'modules'
        if not modules_dir.is_dir():
            return []

        deployment = project_root / 'core' / 'deployment'
        import sys

        if str(deployment) not in sys.path:
            sys.path.insert(0, str(deployment))
        from lifecycle.modules.catalog import ModuleCatalog  # noqa: WPS433

        catalog = ModuleCatalog.from_env(project_root)

        templates: list[ConfigTemplate] = []
        for module_dir in sorted(modules_dir.iterdir()):
            if not module_dir.is_dir() or catalog.is_disabled(module_dir.name):
                continue
            source = module_dir / '.env.example'
            if not source.is_file():
                continue
            templates.append(
                ConfigTemplate(
                    source.relative_to(project_root).as_posix(),
                    (module_dir / '.env').relative_to(project_root).as_posix(),
                    FullCopyStrategy(),
                ),
            )
        return templates

    @classmethod
    def all_templates(cls, project_root: Path) -> list[ConfigTemplate]:
        return cls.project_templates() + cls.module_env_templates(project_root)

    @classmethod
    def env_check_pairs(cls, project_root: Path) -> list[EnvFilePair]:
        pairs: list[EnvFilePair] = []
        for template in cls.all_templates(project_root):
            if not template.source_rel.endswith('.env.example'):
                continue
            example_path = project_root / template.source_rel
            env_path = project_root / template.target_rel
            if template.target_rel == '.env':
                label = '.env (корень)'
            else:
                label = template.target_rel.replace('\\', '/')
            pairs.append(
                EnvFilePair(
                    label=label,
                    example_path=example_path,
                    env_path=env_path,
                ),
            )
        return pairs
