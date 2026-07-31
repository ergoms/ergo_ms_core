"""Оркестратор pipeline развёртывания."""

from __future__ import annotations

from pathlib import Path
from typing import Any, Literal

from lifecycle.context import DeploymentContext
from lifecycle.pipeline import DeploymentPipeline
from lifecycle.recipes import RECIPE_REGISTRY


class DeploymentOrchestrator:
    """Фабрики pipeline для host, Docker, служб и инфра."""

    def __init__(self, project_root: Path) -> None:
        self._project_root = project_root.resolve()

    def run_recipe(
        self,
        name: str,
        *,
        runtime: Literal['host', 'docker'] | None = None,
        docker_mode: str | None = None,
        options: dict[str, Any] | None = None,
        extra_services: list[str] | None = None,
    ) -> int:
        spec = RECIPE_REGISTRY.get(name)
        if spec is None:
            from console_tags import format_console
            import sys

            from cli_locale import t

            print(format_console('error', t('unknown_recipe', name=name)), file=sys.stderr)
            return 1

        resolved_runtime: Literal['host', 'docker'] = runtime or spec.runtime  # type: ignore[assignment]
        ctx = DeploymentContext.create(
            self._project_root,
            runtime=resolved_runtime,
            docker_mode=docker_mode,
            target=spec.target,
            options=dict(options or {}),
        )
        if spec.needs_sudo:
            ctx.options['needs_sudo'] = True
        if extra_services:
            ctx.extra_services = list(extra_services)
        if ctx.options.get('compose_extra_args'):
            pass
        elif extra_services and name in ('docker-up', 'docker-init'):
            ctx.options['compose_extra_args'] = ['-d', *extra_services]

        pipeline = DeploymentPipeline(list(spec.steps))
        return pipeline.run(ctx)

    def docker_migrate(self, *, docker_mode: str | None = None) -> int:
        return self.run_recipe('docker-migrate', runtime='docker', docker_mode=docker_mode)

    def docker_install_deps(self, *, docker_mode: str | None = None) -> int:
        return self.run_recipe('docker-install-deps', runtime='docker', docker_mode=docker_mode)

    def docker_install_npm(self, *, docker_mode: str | None = None) -> int:
        return self.run_recipe('docker-install-npm', runtime='docker', docker_mode=docker_mode)
