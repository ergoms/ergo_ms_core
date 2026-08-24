"""Живой Docker-сценарий: docker run -d без compose up и без публикации портов."""

from __future__ import annotations

import subprocess
from pathlib import Path
from typing import Callable, Mapping, Sequence

from cli_locale import t
from console_tags import format_console
from scenario_test.live_checks import run_live_http_checks
from scenario_test.live_stack import (
    all_container_names,
    app_run_commands,
    container_ip,
    container_names,
    container_running,
    exec_command,
    infra_run_commands,
    migrate_command,
    module_run_command,
)
from scenario_test.matrix import ScenarioSpec, spec_env_overrides
from scenario_test.stack import (
    NGINX_IMAGE,
    RUNTIME_ENV_NAME,
    modules_with_bridge,
    posix,
    write_databases_yaml,
    write_nginx_conf,
    write_runtime_env,
)

RunCmd = Callable[..., int]

OK = 0
FAIL = 1
SKIP = 2


def docker_env_extra(
    spec: ScenarioSpec,
    *,
    ports: Mapping[str, int],
    module_name: str,
    bridge_token: str,
) -> dict[str, str]:
    extra = spec_env_overrides(spec)
    extra['REDIS_PORT'] = '6379'
    extra['ERGO_DOCKER_DB_PORT'] = '5432'
    extra['MEDIA_API_BIND_PORT'] = str(int(ports['media']))
    extra['NGINX_ENABLED'] = 'true' if spec.use_nginx else 'false'
    extra['ERGO_JUPYTER'] = spec.jupyter if spec.use_jupyter else 'none'
    if spec.module_runtime == 'microservice' and module_name:
        extra['MICROSERVICE_MODULES'] = module_name
        extra['MODULE_RUNTIME'] = 'microservice'
        extra['BRIDGE_INTERNAL_TOKEN'] = bridge_token
        extra[module_name.upper().replace('-', '_') + '_PORT'] = str(int(ports['module']))
    return extra


def _wait_exec(run_cmd: RunCmd, cmd: Sequence[str], log, *, attempts: int = 24, delay: float = 2.0) -> bool:
    import time

    last = 1
    for _ in range(max(1, attempts)):
        try:
            last = run_cmd(cmd, log=log, timeout=20, quiet=True)
        except subprocess.TimeoutExpired:
            last = 1
        if last == 0:
            return True
        time.sleep(delay)
    return last == 0


def run_docker_scenario(
    *,
    project: str,
    project_root: Path,
    run_dir: Path,
    spec: ScenarioSpec,
    ports: Mapping[str, int],
    api_secret: str,
    jwt_secret: str,
    media_key: str,
    meili_key: str,
    jupyter_token: str,
    bridge_token: str,
    log,
    run_cmd: RunCmd,
    env: dict[str, str],
    remove_containers: Callable[[Sequence[str], object], None],
) -> int:
    names = container_names(project)
    extra_cleanup = [f'{project}_migrate', f'{project}_nginx_test']
    module_name = ''
    if spec.module_runtime == 'microservice':
        bridges = modules_with_bridge(project_root)
        if not bridges:
            log.write(format_console('warning', t('scenario_test_skip_no_module', id=spec.id)))
            return SKIP
        module_name = bridges[0]
    try:
        write_databases_yaml(run_dir / 'databases.yaml')
        extra = docker_env_extra(
            spec,
            ports=ports,
            module_name=module_name,
            bridge_token=bridge_token,
        )
        write_runtime_env(
            run_dir / RUNTIME_ENV_NAME,
            ports=ports,
            api_secret=api_secret,
            jwt_secret=jwt_secret,
            media_internal_key=media_key,
            meili_key=meili_key,
            jupyter_token=jupyter_token,
            extra=extra,
        )
        write_nginx_conf(
            run_dir / 'nginx.conf',
            api_port=int(ports['api']),
            nginx_port=int(ports['nginx']),
            jupyter_port=int(ports['jupyter']),
            media_port=int(ports['media']),
            module_runtime=spec.module_runtime,
            microservice_modules=module_name,
            module_port=str(int(ports['module'])) if module_name else '',
        )
        for cmd in infra_run_commands(project=project, ports=ports, meili_key=meili_key):
            try:
                code = run_cmd(cmd, log=log, env=env, timeout=60)
            except subprocess.TimeoutExpired:
                log.write(format_console('warning', t('scenario_test_docker_start_hung')))
                return SKIP
            if code != 0:
                log.write(format_console('error', t('scenario_test_up_failed')))
                return FAIL
        if not _wait_exec(run_cmd, exec_command(names['redis'], 'redis-cli', 'ping'), log):
            log.write(format_console('error', t('scenario_test_up_failed')))
            return FAIL
        if not _wait_exec(
            run_cmd,
            exec_command(names['postgres'], 'pg_isready', '-U', 'postgres', '-d', 'ergo_ms_scenario'),
            log,
        ):
            log.write(format_console('error', t('scenario_test_up_failed')))
            return FAIL
        if not _wait_exec(
            run_cmd,
            exec_command(
                names['meilisearch'],
                'wget',
                '-q',
                '-O',
                '-',
                'http://127.0.0.1:7700/health',
            ),
            log,
        ):
            log.write(format_console('error', t('scenario_test_up_failed')))
            return FAIL
        extra_hosts = {
            'redis': container_ip(names['redis']),
            'postgres': container_ip(names['postgres']),
            'meilisearch': container_ip(names['meilisearch']),
        }
        log.write(f'infra_hosts={extra_hosts}')
        if not all(extra_hosts.values()):
            log.write(format_console('error', t('scenario_test_up_failed')))
            return FAIL
        if run_cmd(
            migrate_command(
                project=project,
                project_root=project_root,
                run_dir=run_dir,
                extra_hosts=extra_hosts,
            ),
            log=log,
            env=env,
            timeout=300,
        ) != 0:
            log.write(format_console('error', t('scenario_test_migrate_failed')))
            return FAIL
        jupyter_mode = spec.jupyter if spec.use_jupyter else 'none'
        app_cmds = app_run_commands(
            project=project,
            project_root=project_root,
            run_dir=run_dir,
            jupyter_token=jupyter_token,
            extra_hosts=extra_hosts,
            api_host='127.0.0.1',
            media_host='127.0.0.1',
            include_jupyter=False,
            include_nginx=False,
            jupyter_mode=jupyter_mode,
        )
        for cmd in app_cmds:
            try:
                code = run_cmd(cmd, log=log, env=env, timeout=90)
            except subprocess.TimeoutExpired:
                log.write(format_console('warning', t('scenario_test_docker_start_hung')))
                return SKIP
            if code != 0:
                log.write(format_console('error', t('scenario_test_up_failed')))
                return FAIL
        api_ip = container_ip(names['api'])
        media_ip = container_ip(names['media'])
        if not api_ip or not media_ip:
            log.write(format_console('error', t('scenario_test_up_failed')))
            return FAIL
        extra_hosts = dict(extra_hosts)
        extra_hosts['api'] = api_ip
        extra_hosts['media-api'] = media_ip
        jupyter_ip = '127.0.0.1'
        if spec.use_jupyter:
            jupyter_cmds = app_run_commands(
                project=project,
                project_root=project_root,
                run_dir=run_dir,
                jupyter_token=jupyter_token,
                extra_hosts=extra_hosts,
                api_host=api_ip,
                media_host=media_ip,
                include_jupyter=True,
                include_nginx=False,
                jupyter_mode=jupyter_mode,
            )
            jupyter_cmd = jupyter_cmds[-1]
            try:
                code = run_cmd(jupyter_cmd, log=log, env=env, timeout=90)
            except subprocess.TimeoutExpired:
                log.write(format_console('warning', t('scenario_test_docker_start_hung')))
                return SKIP
            if code != 0:
                log.write(format_console('error', t('scenario_test_up_failed')))
                return FAIL
            jupyter_ip = container_ip(names['jupyter'])
            if not jupyter_ip:
                log.write(format_console('error', t('scenario_test_up_failed')))
                return FAIL
            extra_hosts['jupyter'] = jupyter_ip
        module_ip = ''
        if module_name:
            port = str(int(ports['module']))
            try:
                code = run_cmd(
                    module_run_command(
                        project=project,
                        project_root=project_root,
                        run_dir=run_dir,
                        extra_hosts=extra_hosts,
                        module_name=module_name,
                        module_port=port,
                    ),
                    log=log,
                    env=env,
                    timeout=90,
                )
            except subprocess.TimeoutExpired:
                log.write(format_console('warning', t('scenario_test_docker_start_hung')))
                return SKIP
            if code != 0:
                log.write(format_console('error', t('scenario_test_up_failed')))
                return FAIL
            module_ip = container_ip(names['module'])
            if not module_ip:
                log.write(format_console('error', t('scenario_test_up_failed')))
                return FAIL
            extra_hosts[module_name] = module_ip
        if spec.use_nginx:
            write_nginx_conf(
                run_dir / 'nginx.conf',
                api_port=int(ports['api']),
                nginx_port=int(ports['nginx']),
                api_upstream=api_ip,
                media_upstream=media_ip,
                jupyter_upstream=jupyter_ip,
                jupyter_port=int(ports['jupyter']),
                media_port=int(ports['media']),
                module_runtime=spec.module_runtime,
                microservice_modules=module_name,
                module_port=str(int(ports['module'])) if module_name else '',
            )
            nginx_conf = posix(run_dir / 'nginx.conf')
            try:
                run_cmd(
                    [
                        'docker',
                        'run',
                        '--rm',
                        '--name',
                        f'{project}_nginx_test',
                        '-v',
                        f'{nginx_conf}:/etc/nginx/conf.d/default.conf:ro',
                        NGINX_IMAGE,
                        'nginx',
                        '-t',
                    ],
                    log=log,
                    env=env,
                    timeout=45,
                )
            except subprocess.TimeoutExpired:
                log.write(format_console('warning', t('scenario_test_docker_start_hung')))
                return SKIP
            nginx_cmds = app_run_commands(
                project=project,
                project_root=project_root,
                run_dir=run_dir,
                jupyter_token=jupyter_token,
                extra_hosts=extra_hosts,
                api_host=api_ip,
                media_host=media_ip,
                jupyter_host=jupyter_ip,
                include_jupyter=False,
                include_nginx=True,
                jupyter_mode=jupyter_mode,
            )
            try:
                code = run_cmd(nginx_cmds[-1], log=log, env=env, timeout=90)
            except subprocess.TimeoutExpired:
                log.write(format_console('warning', t('scenario_test_docker_start_hung')))
                return SKIP
            if code != 0:
                log.write(format_console('error', t('scenario_test_up_failed')))
                return FAIL
            if not container_running(names['nginx']):
                try:
                    run_cmd(['docker', 'logs', '--tail', '80', names['nginx']], log=log, timeout=20)
                except subprocess.TimeoutExpired:
                    pass
        failed = not run_live_http_checks(
            names=names,
            ports=ports,
            run_dir=run_dir,
            project_root=project_root,
            jupyter_token=jupyter_token,
            log=log,
            launch='docker',
            use_nginx=spec.use_nginx,
            use_jupyter=spec.use_jupyter,
            jupyter_mode=jupyter_mode,
            module_name=module_name,
        )
        if run_cmd(
            exec_command(names['meilisearch'], 'wget', '-q', '-O', '-', 'http://127.0.0.1:7700/health'),
            log=log,
            env=env,
            timeout=30,
        ) != 0:
            failed = True
        if run_cmd(
            exec_command(names['redis'], 'redis-cli', 'ping'),
            log=log,
            env=env,
            timeout=20,
        ) != 0:
            failed = True
        if failed:
            log.write(format_console('error', t('scenario_test_spec_failed', id=spec.id)))
            return FAIL
        log.write(format_console('ok', t('scenario_test_spec_ok', id=spec.id)))
        return OK
    except subprocess.TimeoutExpired:
        log.write(format_console('error', t('scenario_test_timeout')))
        return FAIL
    finally:
        remove_containers([*all_container_names(project), *extra_cleanup], log)
