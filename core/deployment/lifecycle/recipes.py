"""Реестр рецептов pipeline."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable

from lifecycle.context import DeploymentTarget
from lifecycle.steps.base import DeploymentStep
from lifecycle.steps.common_steps import (
    ClientBuildStep,
    CollectStaticStep,
    MigrateStep,
    NpmInstallStep,
    PythonInstallStep,
    WarmupCachesStep,
)
from lifecycle.steps.compose_steps import (
    DockerComposeCommandStep,
    DockerComposeRestartStep,
    DockerComposeUpStep,
)
from lifecycle.steps.dev_steps import DevForegroundStep, DevWorkerStep
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
)
from lifecycle.steps.host_steps import (
    ConfigScaffoldStep,
    CreateVenvStep,
    GitSubmoduleUpdateStep,
    HostCliInstallStep,
    HostExecutionPolicyStep,
    PoetryInstallStep,
    UpdateModuleSubmodulesStep,
)
from lifecycle.steps.infra_steps import InfraOperationStep
from lifecycle.steps.service_steps import ServiceOperationStep


@dataclass(frozen=True)
class RecipeSpec:
    name: str
    steps: tuple[DeploymentStep, ...]
    target: DeploymentTarget = 'deployment'
    runtime: str = 'host'
    needs_sudo: bool = False
    description: str = ''


def _deploy_api_submodules() -> GitSubmoduleUpdateStep:
    return GitSubmoduleUpdateStep(paths=('core/api', 'core/media_api'))


def _deploy_client_submodules() -> GitSubmoduleUpdateStep:
    return GitSubmoduleUpdateStep(paths=('core/client',))


def _deploy_all_submodules() -> GitSubmoduleUpdateStep:
    return GitSubmoduleUpdateStep(paths=('core/api', 'core/client', 'core/media_api'))


def build_recipe_registry() -> dict[str, RecipeSpec]:
    specs: list[RecipeSpec] = [
        RecipeSpec(
            'setup-full',
            (
                HostExecutionPolicyStep(),
                GitSubmoduleUpdateStep(),
                ConfigScaffoldStep(),
                CreateVenvStep(),
                PoetryInstallStep(),
                HostCliInstallStep(),
                PythonInstallStep(),
                NpmInstallStep(),
                ClientBuildStep(),
                MigrateStep(),
                WarmupCachesStep(),
                CollectStaticStep(),
            ),
            description='Полная первичная настройка',
        ),
        RecipeSpec(
            'install-deps',
            (PythonInstallStep(), NpmInstallStep(), MigrateStep(), WarmupCachesStep()),
            description='Python + npm, миграции и прогрев кэшей',
        ),
        RecipeSpec(
            'python-install',
            (PythonInstallStep(),),
            description='Только Python-зависимости',
        ),
        RecipeSpec(
            'setup-application',
            (
                PythonInstallStep(),
                NpmInstallStep(),
                ClientBuildStep(),
                MigrateStep(),
                WarmupCachesStep(),
                CollectStaticStep(),
            ),
            description='Зависимости приложения без venv/scaffold',
        ),
        RecipeSpec(
            'deploy-api',
            (
                _deploy_api_submodules(),
                PythonInstallStep(),
                MigrateStep(),
                WarmupCachesStep(),
                CollectStaticStep(),
            ),
            description='Развёртывание API',
        ),
        RecipeSpec(
            'deploy-client',
            (_deploy_client_submodules(), NpmInstallStep(), ClientBuildStep()),
            description='Развёртывание клиента',
        ),
        RecipeSpec(
            'deploy-all',
            (
                _deploy_all_submodules(),
                PythonInstallStep(),
                NpmInstallStep(),
                MigrateStep(),
                WarmupCachesStep(),
                CollectStaticStep(),
                ClientBuildStep(),
            ),
            description='Полное развёртывание',
        ),
        RecipeSpec(
            'build-all',
            (ClientBuildStep(), CollectStaticStep()),
            description='Сборка клиента и static',
        ),
        RecipeSpec(
            'update-submodules',
            (GitSubmoduleUpdateStep(),),
            target='aux',
            description='Обновление submodule ядра',
        ),
        RecipeSpec(
            'update-module-submodules',
            (UpdateModuleSubmodulesStep(),),
            target='aux',
            description='Обновление submodule модулей',
        ),
        RecipeSpec(
            'docker-init',
            (
                ClearSetupMarkerStep(),
                DockerModulesIgnoreStep(),
                DockerBuildStep(skip_if_present=True),
                GenerateWorkersComposeStep(),
                ComposeArtifactsStep(),
                DockerStopBeforeBootstrapStep(),
                DockerBootstrapInfraStep(),
                PythonInstallStep(),
                NpmInstallStep(),
                MigrateStep(),
                WarmupCachesStep(),
                DockerMarkSetupStep(),
                DockerUpAppServicesStep(),
            ),
            target='compose',
            runtime='docker',
            description='Первичная установка Docker',
        ),
        RecipeSpec(
            'docker-bootstrap',
            (
                DockerStopBeforeBootstrapStep(),
                DockerBootstrapInfraStep(),
                PythonInstallStep(),
                NpmInstallStep(),
                MigrateStep(),
                WarmupCachesStep(),
                DockerMarkSetupStep(),
                DockerUpAppServicesStep(),
            ),
            target='compose',
            runtime='docker',
            description='Bootstrap Docker без build',
        ),
        RecipeSpec(
            'docker-migrate',
            (MigrateStep(), WarmupCachesStep()),
            target='compose',
            runtime='docker',
            description='Миграции в Docker',
        ),
        RecipeSpec(
            'docker-install-deps',
            (PythonInstallStep(),),
            target='compose',
            runtime='docker',
        ),
        RecipeSpec(
            'docker-install-npm',
            (NpmInstallStep(),),
            target='compose',
            runtime='docker',
        ),
        RecipeSpec(
            'docker-prepare-build',
            (
                DockerModulesIgnoreStep(),
                GenerateWorkersComposeStep(),
                ComposeArtifactsStep(),
            ),
            target='compose',
            runtime='docker',
        ),
        RecipeSpec(
            'docker-up',
            (DockerComposeUpStep(),),
            target='compose',
            runtime='docker',
        ),
        RecipeSpec(
            'docker-down',
            (DockerComposeCommandStep('down'),),
            target='compose',
            runtime='docker',
        ),
        RecipeSpec(
            'docker-ps',
            (DockerComposeCommandStep('ps'),),
            target='compose',
            runtime='docker',
        ),
        RecipeSpec(
            'docker-build',
            (
                DockerModulesIgnoreStep(),
                GenerateWorkersComposeStep(),
                ComposeArtifactsStep(),
                DockerBuildStep(skip_if_present=False),
            ),
            target='compose',
            runtime='docker',
        ),
        RecipeSpec(
            'docker-restart',
            (DockerComposeRestartStep(),),
            target='compose',
            runtime='docker',
        ),
        RecipeSpec(
            'docker-logs',
            (DockerComposeCommandStep('logs'),),
            target='compose',
            runtime='docker',
        ),
        RecipeSpec(
            'warmup-caches-if-needed',
            (DevForegroundStep('warmup-caches-if-needed'),),
            target='foreground',
            description='Прогрев кэшей при необходимости',
        ),
        RecipeSpec(
            'sync-logs-services',
            (DevForegroundStep('sync-logs-services'),),
            target='aux',
        ),
        RecipeSpec(
            'dev-api',
            (DevForegroundStep('dev-api'),),
            target='foreground',
        ),
        RecipeSpec(
            'dev-client',
            (DevForegroundStep('dev-client'),),
            target='foreground',
        ),
        RecipeSpec(
            'start-client',
            (DevForegroundStep('dev-client'),),
            target='foreground',
        ),
        RecipeSpec(
            'start-client-dev',
            (DevForegroundStep('dev-client-enabled'),),
            target='foreground',
        ),
        RecipeSpec(
            'start-media',
            (DevForegroundStep('dev-media'),),
            target='foreground',
        ),
        RecipeSpec(
            'start-beat',
            (DevForegroundStep('dev-beat'),),
            target='foreground',
        ),
        RecipeSpec(
            'start-jupyter',
            (DevForegroundStep('dev-jupyter'),),
            target='foreground',
        ),
        RecipeSpec(
            'start-worker',
            (DevWorkerStep(),),
            target='foreground',
        ),
    ]

    for op in ('install', 'start', 'stop', 'restart', 'status', 'uninstall'):
        for sid in ('all', 'api', 'client', 'media', 'beat', 'workers'):
            if op == 'uninstall' and sid != 'all':
                continue
            name = f'service-{op}-{sid}'
            specs.append(
                RecipeSpec(
                    name,
                    (ServiceOperationStep(op, sid),),
                    target='service',
                    description=f'Служба: {op} {sid}',
                )
            )

    for component, op in (
        ('nginx', 'install'),
        ('nginx', 'uninstall'),
        ('nginx', 'start'),
        ('nginx', 'stop'),
        ('nginx', 'restart'),
        ('nginx', 'reload'),
        ('nginx', 'status'),
        ('nginx', 'test'),
        ('redis', 'install'),
        ('redis', 'uninstall'),
        ('redis', 'start'),
        ('redis', 'stop'),
        ('redis', 'restart'),
        ('redis', 'status'),
        ('redis', 'test'),
        ('tls', 'install'),
        ('tls', 'renew'),
        ('tls', 'status'),
    ):
        name = f'{component}-{op}'
        specs.append(
            RecipeSpec(
                name,
                (InfraOperationStep(component, op),),
                target='infra',
                needs_sudo=component in ('nginx', 'redis', 'tls') and op != 'status' and op != 'test',
                description=f'Инфра {component}: {op}',
            )
        )

    registry = {spec.name: spec for spec in specs}

    aliases = {
        'install-services': 'service-install-all',
        'install-api-service': 'service-install-api',
        'install-client-service': 'service-install-client',
        'install-media-service': 'service-install-media',
        'install-beat-service': 'service-install-beat',
        'install-worker-service': 'service-install-workers',
        'start': 'service-start-all',
        'stop': 'service-stop-all',
        'restart': 'service-restart-all',
        'status': 'service-status-all',
        'uninstall-services': 'service-uninstall-all',
        'start-all-services': 'service-start-all',
        'stop-all-services': 'service-stop-all',
        'restart-all-services': 'service-restart-all',
        'status-all-services': 'service-status-all',
        'dev': 'dev-api',
        'install-nginx': 'nginx-install',
        'uninstall-nginx': 'nginx-uninstall',
        'start-nginx': 'nginx-start',
        'stop-nginx': 'nginx-stop',
        'restart-nginx': 'nginx-restart',
        'reload-nginx': 'nginx-reload',
        'status-nginx': 'nginx-status',
        'test-nginx': 'nginx-test',
        'install-redis': 'redis-install',
        'uninstall-redis': 'redis-uninstall',
        'start-redis': 'redis-start',
        'stop-redis': 'redis-stop',
        'restart-redis': 'redis-restart',
        'status-redis': 'redis-status',
        'test-redis': 'redis-test',
        'install-tls': 'tls-install',
        'renew-tls': 'tls-renew',
        'status-tls': 'tls-status',
        'update-submodules': 'update-submodules',
    }
    for alias, target in aliases.items():
        if target in registry and alias not in registry:
            registry[alias] = registry[target]

    return registry


RECIPE_REGISTRY: dict[str, RecipeSpec] = build_recipe_registry()
