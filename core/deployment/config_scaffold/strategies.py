"""Стратегии копирования шаблонов конфигурационных файлов."""

from __future__ import annotations

import shutil
from abc import ABC, abstractmethod
from pathlib import Path


class CopyStrategy(ABC):
    """Интерфейс стратегии копирования example -> рабочий конфиг."""

    @abstractmethod
    def copy(self, source: Path, target: Path) -> None:
        ...


class FullCopyStrategy(CopyStrategy):
    """Полное копирование файла."""

    def copy(self, source: Path, target: Path) -> None:
        shutil.copy2(source, target)


class HeadLinesCopyStrategy(CopyStrategy):
    """Копирование только первых N строк (для databases.yaml)."""

    def __init__(self, lines: int) -> None:
        self._lines = lines

    def copy(self, source: Path, target: Path) -> None:
        content = source.read_text(encoding='utf-8').splitlines()[: self._lines]
        text = '\n'.join(content)
        if text:
            text += '\n'
        target.write_text(text, encoding='utf-8')
