"""Создание конфигурационных файлов проекта и модулей из example-шаблонов."""

from .models import ConfigTemplate, ConfigTemplateRegistry, ScaffoldAction, ScaffoldResult
from .scaffolder import ConfigScaffolder, format_scaffold_result
from .strategies import CopyStrategy, FullCopyStrategy, HeadLinesCopyStrategy

__all__ = [
    'ConfigScaffolder',
    'ConfigTemplate',
    'ConfigTemplateRegistry',
    'CopyStrategy',
    'FullCopyStrategy',
    'HeadLinesCopyStrategy',
    'ScaffoldAction',
    'ScaffoldResult',
    'format_scaffold_result',
]
