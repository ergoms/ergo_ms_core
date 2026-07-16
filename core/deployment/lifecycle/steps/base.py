"""Базовый шаг pipeline развёртывания."""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass

from lifecycle.context import DeploymentContext


@dataclass(frozen=True)
class StepResult:
    exit_code: int = 0
    message: str = ''

    @property
    def ok(self) -> bool:
        return self.exit_code == 0


class DeploymentStep(ABC):
    """Один шаг развёртывания; расширение — наследник + регистрация в pipeline."""

    @property
    @abstractmethod
    def name(self) -> str:
        """Краткое имя шага для логов."""

    def should_run(self, ctx: DeploymentContext) -> bool:
        return True

    @abstractmethod
    def run(self, ctx: DeploymentContext) -> StepResult:
        pass
