"""
Shared nginx status / reload / test for host lifecycle.

Install и NSSM/systemd остаются в shell-адаптерах; здесь — portable nginx CLI.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

from lifecycle.services.backends import _bootstrap  # noqa: F401

from console_tags import format_console  # noqa: E402
from nginx_foreground import _configure_stdio_utf8, is_nginx_running  # noqa: E402

NGINX_WINDOWS_SERVICE = 'ergo_ms_nginx'
NGINX_LINUX_SERVICE = 'ergo_ms_nginx.service'
NGINX_CONF_NAME = 'ergo_ms'


def _nginx_paths(root: Path) -> tuple[Path, Path, Path]:
    nginx_dir = root / 'virtual_env' / 'packages' / 'nginx'
    if os.name == 'nt':
        exe = nginx_dir / 'nginx.exe'
    else:
        exe = nginx_dir / 'sbin' / 'nginx'
    main_conf = nginx_dir / 'conf' / 'nginx.conf'
    return nginx_dir, exe, main_conf


def _nginx_installed(root: Path) -> bool:
    _nginx_dir, exe, main_conf = _nginx_paths(root)
    return exe.is_file() and main_conf.is_file()


def _is_nginx_service_active() -> bool:
    if os.name == 'nt':
        result = subprocess.run(
            ['sc', 'query', NGINX_WINDOWS_SERVICE],
            capture_output=True,
            text=True,
            encoding='utf-8',
            errors='replace',
            check=False,
        )
        if result.returncode != 0:
            return False
        return 'RUNNING' in (result.stdout or '').upper()

    if not shutil_which('systemctl'):
        return False
    active = subprocess.run(
        ['systemctl', 'is-active', '--quiet', NGINX_LINUX_SERVICE],
        check=False,
    )
    return active.returncode == 0


def shutil_which(name: str) -> str | None:
    from shutil import which
    return which(name)


def _main_conf_arg(main_conf: Path) -> str:
    return str(main_conf).replace('\\', '/') if os.name == 'nt' else str(main_conf)


def cmd_test(root: Path) -> int:
    if not _nginx_installed(root):
        print(format_console('error', 'Nginx не установлен'), file=sys.stderr)
        return 1

    nginx_dir, exe, main_conf = _nginx_paths(root)
    main_conf_arg = _main_conf_arg(main_conf)
    result = subprocess.run(
        [str(exe), '-t', '-c', main_conf_arg],
        cwd=str(nginx_dir),
        check=False,
    )
    return result.returncode


def cmd_reload(root: Path) -> int:
    if not _nginx_installed(root):
        print(format_console('error', 'Nginx не установлен. Выполните: ergoms install-nginx'), file=sys.stderr)
        return 1

    nginx_dir, exe, main_conf = _nginx_paths(root)
    main_conf_arg = _main_conf_arg(main_conf)

    print(format_console('info', 'Проверка конфигурации...'))
    test = subprocess.run(
        [str(exe), '-t', '-c', main_conf_arg],
        cwd=str(nginx_dir),
        check=False,
    )
    if test.returncode != 0:
        print(format_console('error', 'Проверка конфигурации завершилась с ошибкой'), file=sys.stderr)
        return test.returncode

    if os.name != 'nt' and _is_nginx_service_active():
        print(format_console('info', 'Перезагрузка службы nginx...'))
        reload_cmd = ['systemctl', 'reload', NGINX_LINUX_SERVICE]
        if hasattr(os, 'geteuid') and os.geteuid() != 0 and shutil_which('sudo'):
            reload_cmd = ['sudo', *reload_cmd]
        subprocess.run(reload_cmd, check=False)
        print(format_console('ok', 'Nginx перезагружен'))
        return 0

    print(format_console('info', 'Перезагрузка nginx...'))
    subprocess.run(
        [str(exe), '-s', 'reload', '-c', main_conf_arg],
        cwd=str(nginx_dir),
        check=False,
    )
    print(format_console('ok', 'Nginx перезагружен'))
    return 0


def cmd_status(root: Path) -> int:
    _configure_stdio_utf8()
    nginx_dir, exe, _main_conf = _nginx_paths(root)

    if not _nginx_installed(root):
        print('Nginx: не установлен')
        print(f'  Ожидаемый путь: {nginx_dir}')
        return 0

    print('')
    print('=== Статус Nginx ===')

    if _is_nginx_service_active():
        label = NGINX_WINDOWS_SERVICE if os.name == 'nt' else NGINX_LINUX_SERVICE
        print(f'  Service ({label}): Running')
    elif is_nginx_running(nginx_dir, exe):
        print('  Process: Запущен')
    else:
        print('  Process: Not running')

    site_conf = nginx_dir / 'conf' / f'{NGINX_CONF_NAME}.conf'
    if site_conf.is_file():
        print(f'  Site config: {site_conf}')
    return 0


def cmd_render(root: Path, *, template: Path, output: Path | None = None) -> int:
    from env_file_loader import load_project_env  # noqa: WPS433
    from env_resolvers import resolve_nginx_vars  # noqa: WPS433
    from render_nginx_config import render_template  # noqa: WPS433

    values = resolve_nginx_vars(load_project_env(root))
    server_name = values.get('NGINX_SERVER_NAME', 'localhost')
    listen_host = values.get('NGINX_LISTEN_HOST', '0.0.0.0')
    listen_port = values.get('NGINX_LISTEN_PORT', '80')
    use_https = str(values.get('NGINX_USE_HTTPS', 'false')).lower() in ('1', 'true', 'yes')
    ssl_cert = values.get('ERGO_SSL_CERT', '')
    ssl_key = values.get('ERGO_SSL_KEY', '')

    rendered = render_template(
        template,
        root=root,
        server_name=server_name,
        listen_host=listen_host,
        listen_port=listen_port,
        use_https=use_https,
        ssl_cert=ssl_cert,
        ssl_key=ssl_key,
    )
    if output:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(rendered, encoding='utf-8')
    else:
        sys.stdout.write(rendered)
    return 0


def main(argv: list[str] | None = None) -> int:
    _configure_stdio_utf8()
    parser = argparse.ArgumentParser(description='Nginx backend (status/reload/test/render)')
    parser.add_argument('operation', choices=('status', 'reload', 'test', 'render'))
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[5])
    parser.add_argument('--template', type=Path, default=None)
    parser.add_argument('--output', type=Path, default=None)
    args = parser.parse_args(argv)

    root = args.root.resolve()
    if args.operation == 'status':
        return cmd_status(root)
    if args.operation == 'reload':
        return cmd_reload(root)
    if args.operation == 'test':
        return cmd_test(root)
    if args.operation == 'render':
        if not args.template:
            print(format_console('error', 'Для render укажите --template'), file=sys.stderr)
            return 1
        return cmd_render(root, template=args.template, output=args.output)
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
