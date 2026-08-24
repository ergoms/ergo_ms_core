"""Оркестрация живого хостового сценария."""

from __future__ import annotations

import subprocess
from pathlib import Path
from typing import Mapping

from cli_locale import t
from console_tags import format_console
from scenario_test.host_stack import (
    HostBinaryMissing,
    build_host_env,
    close_proc,
    require_host_binaries,
    run_django,
    spawn_python,
    start_throwaway_nginx,
    start_throwaway_postgres,
    start_throwaway_redis,
    stop_throwaway_postgres,
    write_host_artifacts,
    write_host_nginx_prefix,
)
from scenario_test.live_checks import run_live_http_checks
from scenario_test.matrix import ScenarioSpec

OK = 0
FAIL = 1
SKIP = 2


def run_host_scenario(
    *,
    project_root: Path,
    run_dir: Path,
    spec: ScenarioSpec,
    ports: Mapping[str, int],
    api_secret: str,
    jwt_secret: str,
    media_key: str,
    meili_key: str,
    jupyter_token: str,
    log,
) -> int:
    redis_proc = None
    nginx_proc = None
    api_proc = None
    media_proc = None
    jupyter_proc = None
    pg_data = run_dir / 'pgdata'
    try:
        try:
            require_host_binaries(project_root, spec)
        except HostBinaryMissing as exc:
            log.write(format_console(
                'warning',
                t('scenario_test_skip_host_bin', id=spec.id, name=exc.name),
            ))
            return SKIP
        write_host_artifacts(
            run_dir=run_dir,
            spec=spec,
            ports=ports,
            project_root=project_root,
            api_secret=api_secret,
            jwt_secret=jwt_secret,
            media_internal_key=media_key,
            meili_key=meili_key,
            jupyter_token=jupyter_token,
        )
        env = build_host_env(
            project_root=project_root,
            run_dir=run_dir,
            spec=spec,
            ports=ports,
            extra={
                'API_SECRET_KEY': api_secret,
                'API_JWT_SIGNING_KEY': jwt_secret,
                'MEDIA_API_INTERNAL_KEY': media_key,
                'API_JUPYTER_TOKEN': jupyter_token,
                'MEILI_MASTER_KEY': meili_key,
            },
        )
        if spec.use_postgres:
            log.write('host postgres start')
            start_throwaway_postgres(
                project_root,
                pg_data,
                int(ports['postgres']),
                run_dir / 'logs' / 'pg_ctl.log',
            )
            log.write('host postgres ready')
        if spec.use_redis:
            log.write('host redis start')
            redis_proc = start_throwaway_redis(
                project_root,
                run_dir,
                int(ports['redis']),
                run_dir / 'logs' / 'redis.log',
            )
        log.write('host migrate')
        migrate = run_django(
            project_root=project_root,
            env=env,
            command='migrate',
            args=('--noinput',),
            timeout=300,
        )
        if migrate.returncode != 0:
            tail = ((migrate.stdout or '') + (migrate.stderr or ''))[-2000:]
            if tail.strip():
                log.write(tail.strip())
            log.write(format_console('error', t('scenario_test_migrate_failed')))
            return FAIL
        api_proc = spawn_python(
            project_root=project_root,
            script='core/api/scripts/start_api.py',
            env=env,
            log_path=run_dir / 'logs' / 'api.log',
        )
        media_proc = spawn_python(
            project_root=project_root,
            script='core/api/scripts/start_media_api.py',
            env=env,
            log_path=run_dir / 'logs' / 'media.log',
        )
        if spec.use_jupyter:
            jupyter_proc = spawn_python(
                project_root=project_root,
                script='core/api/scripts/start_jupyter.py',
                env=env,
                log_path=run_dir / 'logs' / 'jupyter.log',
            )
        if spec.use_nginx:
            prefix = write_host_nginx_prefix(
                project_root=project_root,
                run_dir=run_dir,
                ports=ports,
            )
            nginx_proc = start_throwaway_nginx(prefix)
        ok = run_live_http_checks(
            names={},
            ports=ports,
            run_dir=run_dir,
            project_root=project_root,
            jupyter_token=jupyter_token,
            log=log,
            launch='host',
            use_nginx=spec.use_nginx,
            use_jupyter=spec.use_jupyter,
            jupyter_mode=spec.jupyter if spec.use_jupyter else 'none',
            host_env=env,
        )
        if not ok:
            log.write(format_console('error', t('scenario_test_spec_failed', id=spec.id)))
            return FAIL
        log.write(format_console('ok', t('scenario_test_spec_ok', id=spec.id)))
        return OK
    except HostBinaryMissing as exc:
        log.write(format_console(
            'warning',
            t('scenario_test_skip_host_bin', id=spec.id, name=exc.name),
        ))
        return SKIP
    except subprocess.TimeoutExpired:
        log.write(format_console('error', t('scenario_test_timeout')))
        return FAIL
    except RuntimeError as exc:
        log.write(str(exc))
        log.write(format_console('error', t('scenario_test_spec_failed', id=spec.id)))
        return FAIL
    finally:
        for proc in (jupyter_proc, nginx_proc, api_proc, media_proc, redis_proc):
            close_proc(proc)
        if spec.use_postgres:
            stop_throwaway_postgres(project_root, pg_data)
