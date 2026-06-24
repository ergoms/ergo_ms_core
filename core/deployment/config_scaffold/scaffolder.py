"""Оркестратор создания конфигурационных файлов из example-шаблонов."""

from __future__ import annotations

from pathlib import Path

from .models import ConfigTemplate, ConfigTemplateRegistry, ScaffoldAction, ScaffoldResult


class ConfigScaffolder:
    """Создаёт рабочие конфиги из example-файлов, не перезаписывая существующие."""

    def __init__(
        self,
        project_root: Path,
        templates: list[ConfigTemplate] | None = None,
    ) -> None:
        self._project_root = project_root.resolve()
        self._templates = templates or ConfigTemplateRegistry.all_templates(self._project_root)

    def run(self) -> list[ScaffoldResult]:
        return [template.execute(self._project_root) for template in self._templates]


def format_scaffold_result(result: ScaffoldResult) -> str:
    target = result.display_target

    if result.action is ScaffoldAction.CREATED:
        suffix = f' ({result.detail})' if result.detail else ''
        return f'    Created {target}{suffix}'

    if result.action is ScaffoldAction.SKIPPED_EXISTS:
        return f'    {target} already exists, skipping'

    if result.action is ScaffoldAction.SKIPPED_NO_SOURCE:
        return f'    [WARNING] Example file {result.source_rel} not found'

    return f'    [WARNING] Failed to create {target}: {result.detail}'
