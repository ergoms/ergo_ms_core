"""Создание конфигурационных файлов проекта и модулей из example-шаблонов."""

from .models import ConfigTemplate, ConfigTemplateRegistry, ScaffoldAction, ScaffoldResult
from .scaffolder import ConfigScaffolder, format_scaffold_result
from .strategies import (
    CopyStrategy,
    DatabasesYamlCopyStrategy,
    FullCopyStrategy,
    HeadLinesCopyStrategy,
    NamedSectionsCopyStrategy,
)

__all__ = [
    'ConfigScaffolder',
    'ConfigTemplate',
    'ConfigTemplateRegistry',
    'CopyStrategy',
    'DatabasesYamlCopyStrategy',
    'FullCopyStrategy',
    'HeadLinesCopyStrategy',
    'NamedSectionsCopyStrategy',
    'ScaffoldAction',
    'ScaffoldResult',
    'format_scaffold_result',
]
