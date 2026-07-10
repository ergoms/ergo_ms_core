"""Создание конфигурационных файлов проекта и модулей из example-шаблонов."""

from .env_compare import EnvCompareResult, compare_env_files, parse_env_example_lines, parse_env_keys
from .env_normalize import EnvNormalizeResult, normalize_env_file
from .models import ConfigTemplate, ConfigTemplateRegistry, EnvFilePair, ScaffoldAction, ScaffoldResult
from .scaffolder import ConfigScaffolder, format_scaffold_result
from .strategies import CopyStrategy, FullCopyStrategy, HeadLinesCopyStrategy

__all__ = [
    'ConfigScaffolder',
    'ConfigTemplate',
    'ConfigTemplateRegistry',
    'CopyStrategy',
    'EnvCompareResult',
    'EnvNormalizeResult',
    'EnvFilePair',
    'FullCopyStrategy',
    'HeadLinesCopyStrategy',
    'ScaffoldAction',
    'ScaffoldResult',
    'compare_env_files',
    'format_scaffold_result',
    'normalize_env_file',
    'parse_env_example_lines',
    'parse_env_keys',
]
