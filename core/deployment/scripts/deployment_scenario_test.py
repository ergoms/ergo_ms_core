"""
Isolated deployment scenario runner.

Does not write host .env, docker/.compose.env, or OS services.
Compose project: ergo_ms_scenario. Logs: virtual_env/cache/tmp/scenario-test/<stamp>/.
"""

from __future__ import annotations

import os
import re
import secrets
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import IO, Sequence

import yaml

_SCRIPTS_DIR = Path(__file__).resolve().parent
_DEPLOYMENT_DIR = _SCRIPTS_DIR.parent
_DOCKER_DIR = _DEPLOYMENT_DIR / 'docker'
_NGINX_DIR = _DEPLOYMENT_DIR / 'nginx'
_PROJECT_ROOT = _DEPLOYMENT_DIR.parent.parent

for _path in (_DEPLOYMENT_DIR, _DOCKER_DIR, _NGINX_DIR):
    _text = str(_path)
    if _text not in sys.path:
        sys.path.insert(0, _text)

from cli_locale import t  # noqa: E402
from console_tags import configure_stdio_utf8, format_console  # noqa: E402
from project_layout import cache_dir, ensure_dir  # noqa: E402
from scenario_test.live_checks import run_live_http_checks  # noqa: E402
from scenario_test.live_stack import (  # noqa: E402
    all_container_names,
    app_run_commands,
    container_ip,
    container_names,
    container_running,
    exec_command,
    infra_run_commands,
    migrate_command,
)
from scenario_test.ports import pick_scenario_ports  # noqa: E402
from scenario_test.stack import (  # noqa: E402
    COMPOSE_PROJECT,
    NGINX_IMAGE,
    PYTHON_IMAGE,
    REDIS_IMAGE,
    RUNTIME_ENV_NAME,
    posix,
    write_compose_file,
    write_databases_yaml,
    write_modules_compose,
    write_nginx_conf,
    write_runtime_env,
)


class RunLog:
    def __init__(self, path: Path, compose_log: Path) -> None:
        self.path = path
        self.compose_log = compose_log
        self._fh: IO[str] = path.open('a', encoding='utf-8')

    def write(self, line: str) -> None:
        stamp = datetime.now(timezone.utc).strftime('%H:%M:%S')
        text = f'{stamp} {line}'
        self._fh.write(text + '\n')
        self._fh.flush()
        print(text, flush=True)

    def close(self) -> None:
        self._fh.close()


_ACTIVE_PROJECT = COMPOSE_PROJECT

_SECRET_LINE = re.compile(
    r'(?im)^(.*(?:API_SECRET_KEY|API_JWT_SIGNING_KEY|MEDIA_API_INTERNAL_KEY|'
    r'MEILI_MASTER_KEY|API_JUPYTER_TOKEN).*)(=|: ).+$'
)


def _redact(text: str) -> str:
    return _SECRET_LINE.sub(r'\1\2***', text)


def _kill_process_tree(pid: int) -> None:
    if sys.platform == 'win32':
        subprocess.run(
            ['taskkill', '/F', '/T', '/PID', str(pid)],
            capture_output=True,
            text=True,
            check=False,
        )
        return
    try:
        os.killpg(pid, 9)
    except OSError:
        try:
            os.kill(pid, 9)
        except OSError:
            pass


def _docker() -> list[str] | None:
    if not shutil.which('docker'):
        return None
    probe = subprocess.run(
        ['docker', 'compose', 'version'],
        capture_output=True,
        text=True,
        check=False,
    )
    if probe.returncode != 0:
        return None
    return ['docker', 'compose']


def _image_exists(name: str) -> bool:
    result = subprocess.run(
        ['docker', 'image', 'inspect', name],
        capture_output=True,
        text=True,
        check=False,
    )
    return result.returncode == 0


def _docker_can_start(log: RunLog) -> bool:
    """Проверка, что движок Docker реально стартует контейнер, а не только create."""
    cmd = [
        'docker',
        'run',
        '--rm',
        '--name',
        f'{COMPOSE_PROJECT}_probe_{os.getpid()}',
        '--entrypoint',
        'redis-server',
        REDIS_IMAGE,
        '--version',
    ]
    try:
        code = _run(cmd, log=log, timeout=45, quiet=True)
    except subprocess.TimeoutExpired:
        log.write(format_console('warning', t('scenario_test_docker_start_hung')))
        return False
    if code != 0:
        log.write(format_console('warning', t('scenario_test_docker_start_hung')))
        return False
    return True


def _compose_cmd(
    compose: list[str],
    run_dir: Path,
    *args: str,
) -> list[str]:
    return [
        *compose,
        '--project-name',
        _ACTIVE_PROJECT,
        '--project-directory',
        str(run_dir),
        '-f',
        str(run_dir / 'docker-compose.yml'),
        *args,
    ]


def _run(
    cmd: Sequence[str],
    *,
    log: RunLog,
    env: dict[str, str] | None = None,
    timeout: int | None = None,
    quiet: bool = False,
    discard_output: bool = False,
) -> int:
    log.write('cmd: ' + ' '.join(cmd))
    stdout_arg: object = subprocess.DEVNULL if discard_output else subprocess.PIPE
    proc = subprocess.Popen(
        list(cmd),
        stdin=subprocess.DEVNULL,
        stdout=stdout_arg,
        stderr=subprocess.STDOUT,
        env=env,
        text=True,
        encoding='utf-8',
        errors='replace',
    )
    try:
        out, _err = proc.communicate(timeout=timeout)
        code = int(proc.returncode)
    except subprocess.TimeoutExpired:
        _kill_process_tree(proc.pid)
        try:
            proc.communicate(timeout=20)
        except subprocess.TimeoutExpired:
            pass
        raise
    if out and not discard_output:
        log.compose_log.parent.mkdir(parents=True, exist_ok=True)
        with log.compose_log.open('a', encoding='utf-8', errors='replace') as fh:
            fh.write('\n--- ' + ' '.join(cmd) + ' ---\n')
            fh.write(out)
            if not out.endswith('\n'):
                fh.write('\n')
        if not quiet or code != 0:
            tail = _redact(out[-4000:].rstrip())
            if tail:
                log.write(tail)
    log.write(f'exit={code}')
    return code


def _prepare_run_dir(root: Path) -> Path:
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    run_dir = ensure_dir(cache_dir(root) / 'tmp' / 'scenario-test' / stamp)
    for name in ('logs', 'logs/docker', 'media', 'notebooks', 'jupyter', 'http', 'static_api', 'modules'):
        ensure_dir(run_dir / name)
    return run_dir


def _wait_exec(cmd: Sequence[str], log: RunLog, *, attempts: int = 24, delay: float = 2.0) -> bool:
    last = 1
    for _ in range(max(1, attempts)):
        try:
            last = _run(cmd, log=log, timeout=20, quiet=True)
        except subprocess.TimeoutExpired:
            last = 1
        if last == 0:
            return True
        time.sleep(delay)
    return last == 0


def _remove_containers(names: Sequence[str], log: RunLog) -> None:
    for name in names:
        try:
            _run(['docker', 'rm', '-f', name], log=log, timeout=20, quiet=True)
        except subprocess.TimeoutExpired:
            log.write(f'skip rm hung {name}')
        except OSError as exc:
            log.write(f'down error {name}: {exc}')


def main() -> int:
    global _ACTIVE_PROJECT
    configure_stdio_utf8()
    root = _PROJECT_ROOT.resolve()
    run_dir = _prepare_run_dir(root)
    log = RunLog(run_dir / 'run.log', run_dir / 'compose.log')
    failed = False
    compose_bin = _docker()
    try:
        log.write(format_console('info', t('scenario_test_run_dir', path=str(run_dir))))
        if compose_bin is None:
            log.write(format_console('warning', t('scenario_test_no_docker')))
            return 0
        if not _image_exists(PYTHON_IMAGE):
            log.write(format_console('warning', t('scenario_test_no_python_image', image=PYTHON_IMAGE)))
            return 0

        _ACTIVE_PROJECT = f'{COMPOSE_PROJECT}_{run_dir.name.lower()}'
        log.write(f'compose_project={_ACTIVE_PROJECT}')

        ports = pick_scenario_ports()
        if ports is None:
            log.write(format_console('warning', t('scenario_test_ports_busy')))
            return 0
        log.write(f'ports={ports}')

        meili_key = secrets.token_hex(16)
        jupyter_token = secrets.token_hex(16)
        api_secret = secrets.token_hex(32)
        jwt_secret = secrets.token_hex(32)
        media_key = secrets.token_hex(32)
        while media_key == api_secret:
            media_key = secrets.token_hex(32)
        write_databases_yaml(run_dir / 'databases.yaml')
        write_nginx_conf(
            run_dir / 'nginx.conf',
            api_port=ports['api'],
            nginx_port=ports['nginx'],
            jupyter_port=ports['jupyter'],
        )
        write_runtime_env(
            run_dir / RUNTIME_ENV_NAME,
            ports=ports,
            api_secret=api_secret,
            jwt_secret=jwt_secret,
            media_internal_key=media_key,
            meili_key=meili_key,
            jupyter_token=jupyter_token,
        )
        write_compose_file(
            run_dir / 'docker-compose.yml',
            project_root=root,
            run_dir=run_dir,
            ports=ports,
            meili_key=meili_key,
            jupyter_token=jupyter_token,
            project_name=_ACTIVE_PROJECT,
        )
        module_count = write_modules_compose(run_dir / 'modules.generated.yml', root)
        log.write(f'module_compose_services={module_count}')
        try:
            modules_data = yaml.safe_load(
                (run_dir / 'modules.generated.yml').read_text(encoding='utf-8')
            )
            services = list((modules_data or {}).get('services') or {})
            log.write(f'modules_yaml_ok services={services}')
        except yaml.YAMLError as exc:
            log.write(format_console('warning', t('scenario_test_modules_config_failed')))
            log.write(str(exc))

        env = os.environ.copy()
        config_cmd = _compose_cmd(compose_bin, run_dir, 'config')
        if _run(config_cmd, log=log, env=env, timeout=60, quiet=True) != 0:
            log.write(format_console('error', t('scenario_test_compose_config_failed')))
            return 1
        log.write('compose config ok')

        if not _docker_can_start(log):
            return 0

        names = container_names(_ACTIVE_PROJECT)

        for cmd in infra_run_commands(project=_ACTIVE_PROJECT, ports=ports, meili_key=meili_key):
            try:
                code = _run(cmd, log=log, env=env, timeout=60)
            except subprocess.TimeoutExpired:
                log.write(format_console('warning', t('scenario_test_docker_start_hung')))
                return 0
            if code != 0:
                log.write(format_console('error', t('scenario_test_up_failed')))
                failed = True
                return 1

        if not _wait_exec(exec_command(names['redis'], 'redis-cli', 'ping'), log):
            log.write(format_console('error', t('scenario_test_up_failed')))
            failed = True
            return 1
        if not _wait_exec(
            exec_command(names['postgres'], 'pg_isready', '-U', 'postgres', '-d', 'ergo_ms_scenario'),
            log,
        ):
            log.write(format_console('error', t('scenario_test_up_failed')))
            failed = True
            return 1
        if not _wait_exec(
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
            failed = True
            return 1

        extra_hosts = {
            'redis': container_ip(names['redis']),
            'postgres': container_ip(names['postgres']),
            'meilisearch': container_ip(names['meilisearch']),
        }
        log.write(f'infra_hosts={extra_hosts}')
        if not all(extra_hosts.values()):
            log.write(format_console('error', t('scenario_test_up_failed')))
            failed = True
            return 1

        if _run(
            migrate_command(
                project=_ACTIVE_PROJECT,
                project_root=root,
                run_dir=run_dir,
                extra_hosts=extra_hosts,
            ),
            log=log,
            env=env,
            timeout=300,
        ) != 0:
            log.write(format_console('error', t('scenario_test_migrate_failed')))
            failed = True
            return 1

        app_cmds = app_run_commands(
            project=_ACTIVE_PROJECT,
            project_root=root,
            run_dir=run_dir,
            jupyter_token=jupyter_token,
            extra_hosts=extra_hosts,
            api_host='127.0.0.1',
            media_host='127.0.0.1',
        )
        for cmd in app_cmds[:2]:
            try:
                code = _run(cmd, log=log, env=env, timeout=90)
            except subprocess.TimeoutExpired:
                log.write(format_console('warning', t('scenario_test_docker_start_hung')))
                return 0
            if code != 0:
                log.write(format_console('error', t('scenario_test_up_failed')))
                failed = True
                return 1
        api_ip = container_ip(names['api'])
        media_ip = container_ip(names['media'])
        if not api_ip or not media_ip:
            log.write(format_console('error', t('scenario_test_up_failed')))
            failed = True
            return 1
        extra_hosts = dict(extra_hosts)
        extra_hosts['api'] = api_ip
        extra_hosts['media-api'] = media_ip
        app_cmds = app_run_commands(
            project=_ACTIVE_PROJECT,
            project_root=root,
            run_dir=run_dir,
            jupyter_token=jupyter_token,
            extra_hosts=extra_hosts,
            api_host=api_ip,
            media_host=media_ip,
        )
        try:
            code = _run(app_cmds[2], log=log, env=env, timeout=90)
        except subprocess.TimeoutExpired:
            log.write(format_console('warning', t('scenario_test_docker_start_hung')))
            return 0
        if code != 0:
            log.write(format_console('error', t('scenario_test_up_failed')))
            failed = True
            return 1
        jupyter_ip = container_ip(names['jupyter'])
        if not jupyter_ip:
            log.write(format_console('error', t('scenario_test_up_failed')))
            failed = True
            return 1
        extra_hosts['jupyter'] = jupyter_ip
        write_nginx_conf(
            run_dir / 'nginx.conf',
            api_port=ports['api'],
            nginx_port=ports['nginx'],
            api_upstream=api_ip,
            media_upstream=media_ip,
            jupyter_upstream=jupyter_ip,
            jupyter_port=ports['jupyter'],
        )
        app_cmds = app_run_commands(
            project=_ACTIVE_PROJECT,
            project_root=root,
            run_dir=run_dir,
            jupyter_token=jupyter_token,
            extra_hosts=extra_hosts,
            api_host=api_ip,
            media_host=media_ip,
            jupyter_host=jupyter_ip,
        )
        nginx_cmd = app_cmds[3]
        nginx_conf = posix(run_dir / 'nginx.conf')
        try:
            _run(
                [
                    'docker',
                    'run',
                    '--rm',
                    '--name',
                    f'{_ACTIVE_PROJECT}_nginx_test',
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
            return 0
        try:
            code = _run(nginx_cmd, log=log, env=env, timeout=90)
        except subprocess.TimeoutExpired:
            log.write(format_console('warning', t('scenario_test_docker_start_hung')))
            return 0
        if code != 0:
            log.write(format_console('error', t('scenario_test_up_failed')))
            failed = True
            return 1
        if not container_running(names['nginx']):
            try:
                _run(['docker', 'logs', '--tail', '80', names['nginx']], log=log, timeout=20)
            except subprocess.TimeoutExpired:
                pass

        if not run_live_http_checks(
            names=names,
            ports=ports,
            run_dir=run_dir,
            project_root=root,
            jupyter_token=jupyter_token,
            log=log,
        ):
            failed = True

        if _run(
            exec_command(names['meilisearch'], 'wget', '-q', '-O', '-', 'http://127.0.0.1:7700/health'),
            log=log,
            env=env,
            timeout=30,
        ) != 0:
            failed = True

        if _run(
            exec_command(names['redis'], 'redis-cli', 'ping'),
            log=log,
            env=env,
            timeout=20,
        ) != 0:
            failed = True

        if failed:
            log.write(format_console('error', t('scenario_test_failed', path=str(run_dir))))
            return 1
        log.write(format_console('ok', t('scenario_test_ok', path=str(run_dir))))
        return 0
    except subprocess.TimeoutExpired:
        log.write(format_console('error', t('scenario_test_timeout')))
        return 1
    finally:
        _remove_containers(
            [*all_container_names(_ACTIVE_PROJECT), f'{_ACTIVE_PROJECT}_migrate', f'{_ACTIVE_PROJECT}_nginx_test'],
            log,
        )
        log.close()


if __name__ == '__main__':
    raise SystemExit(main())
