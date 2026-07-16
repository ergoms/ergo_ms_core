"""Оркестратор pipeline развёртывания."""

from __future__ import annotations

from pathlib import Path
from typing import Any, Literal

from lifecycle.context import DeploymentContext
from lifecycle.pipeline import DeploymentPipeline
from lifecycle.recipes import RECIPE_REGISTRY, RecipeSpec
from lifecycle.steps.docker_steps import (
    ClearSetupMarkerStep,
    ComposeArtifactsStep,
    DockerBootstrapInfraStep,
    DockerBuildStep,
    DockerMarkSetupStep,
    DockerModulesIgnoreStep,
    DockerStopBeforeBootstrapStep,
    DockerUpAppServicesStep,
    GenerateWorkersComposeStep,
    MigrateStep,
    NpmInstallStep,
    PythonInstallStep,
    WarmupCachesStep,
)


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

            print(format_console('error', f'Неизвестный рецепт: {name}'), file=sys.stderr)
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

    def docker_init(
        self,
        *,
        docker_mode: str | None = None,
        extra_services: list[str] | None = None,
        build_extra_args: list[str] | None = None,
    ) -> int:
        options: dict[str, Any] = {}
        if build_extra_args:
            options['build_extra_args'] = list(build_extra_args)
        spec = RECIPE_REGISTRY['docker-init']
        steps = list(spec.steps)
        if build_extra_args:
            steps = [
                s if not isinstance(s, DockerBuildStep) else DockerBuildStep(skip_if_present=True, extra_args=build_extra_args)
                for s in steps
            ]
        ctx = DeploymentContext.create(
            self._project_root,
            runtime='docker',
            docker_mode=docker_mode,
            target='compose',
        )
        if extra_services:
            ctx.extra_services = list(extra_services)
        return DeploymentPipeline(steps).run(ctx)

    def docker_bootstrap_and_up(
        self,
        *,
        docker_mode: str | None = None,
        extra_services: list[str] | None = None,
    ) -> int:
        return self.run_recipe(
            'docker-bootstrap',
            runtime='docker',
            docker_mode=docker_mode,
            extra_services=extra_services,
        )

    def docker_migrate(self, *, docker_mode: str | None = None) -> int:
        return self.run_recipe('docker-migrate', runtime='docker', docker_mode=docker_mode)

    def docker_install_deps(self, *, docker_mode: str | None = None) -> int:
        return self.run_recipe('docker-install-deps', runtime='docker', docker_mode=docker_mode)

    def docker_install_npm(self, *, docker_mode: str | None = None) -> int:
        return self.run_recipe('docker-install-npm', runtime='docker', docker_mode=docker_mode)

    def prepare_docker_build_context(self, *, docker_mode: str | None = None) -> int:
        return self.run_recipe('docker-prepare-build', runtime='docker', docker_mode=docker_mode)

    def host_install_deps(self) -> int:
        return self.run_recipe('install-deps', runtime='host')

    def host_setup_full(self, *, recreate_venv: bool = False) -> int:
        return self.run_recipe(
            'setup-full',
            runtime='host',
            options={'recreate_venv': recreate_venv},
        )
