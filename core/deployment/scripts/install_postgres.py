"""
Установка portable PostgreSQL в virtual_env/packages/postgres
(Windows: EDB binaries zip; Linux: сборка из исходников latest stable).
"""

from __future__ import annotations

import argparse
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[3]
DEPLOYMENT_DIR = PROJECT_ROOT / 'core' / 'deployment'
SCRIPTS_DIR = DEPLOYMENT_DIR / 'scripts'
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))
if str(DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(DEPLOYMENT_DIR))

from console_tags import format_console  # noqa: E402
from postgres_common import (  # noqa: E402
    DEFAULT_BIND,
    DEFAULT_PORT,
    EDB_WINDOWS_URL,
    PG_FTP_SOURCE,
    _download,
    _ensure_layout,
    _exe,
    _initdb_if_needed,
    ensure_databases,
    has_system_postgresql_service,
    is_installed,
    load_db_defaults,
    ping_postgres,
    postgres_version_file,
    read_installed_version,
    resolve_latest_version,
    start_server,
    stop_server,
)


def _force_install_from_env() -> bool:
    try:
        from deployment_env import is_postgres_force_install
    except ImportError:
        return False
    return is_postgres_force_install()


def _find_edb_pgsql_root(extract_dir: Path) -> Path:
    for candidate in (extract_dir / 'pgsql', extract_dir):
        if (candidate / 'bin' / _exe('postgres')).is_file():
            return candidate
    nested = list(extract_dir.rglob(_exe('postgres')))
    for postgres_path in nested:
        if postgres_path.parent.name == 'bin':
            return postgres_path.parent.parent
    raise RuntimeError(f'В архиве EDB не найден postgres: {extract_dir}')


def _copy_tree_merge(src: Path, dest: Path) -> None:
    dest.mkdir(parents=True, exist_ok=True)
    for item in src.iterdir():
        target = dest / item.name
        if item.is_dir():
            _copy_tree_merge(item, target)
        else:
            shutil.copy2(item, target)


def _install_windows(root: Path, version: str, force: bool) -> None:
    paths = _ensure_layout(root)
    installed = read_installed_version(root)
    if is_installed(root) and not force:
        if installed == version:
            print(format_console('skip', f'PostgreSQL {version} уже установлен'))
            return
        print(format_console('info', f'Обновление PostgreSQL {installed} → {version}…'))
        force = True

    if force and paths['bin'].exists():
        stop_server(root)
        for name in ('bin', 'lib', 'share', 'include', 'doc', 'pgAdmin 4', 'StackBuilder'):
            target = paths['base'] / name
            if target.is_dir():
                shutil.rmtree(target, ignore_errors=True)
        pgsql = paths['base'] / 'pgsql'
        if pgsql.is_dir():
            shutil.rmtree(pgsql, ignore_errors=True)

    cache_tmp = root / 'virtual_env' / 'cache' / 'tmp'
    cache_tmp.mkdir(parents=True, exist_ok=True)
    url = EDB_WINDOWS_URL.format(version=version)
    with tempfile.TemporaryDirectory(dir=str(cache_tmp)) as tmp:
        tmp_path = Path(tmp)
        zip_path = tmp_path / f'postgresql-{version}-windows-x64-binaries.zip'
        _download(url, zip_path)
        extract_dir = tmp_path / 'extract'
        extract_dir.mkdir()
        print('-> Распаковка архива…')
        with zipfile.ZipFile(zip_path, 'r') as archive:
            archive.extractall(extract_dir)
        source = _find_edb_pgsql_root(extract_dir)
        for name in ('bin', 'lib', 'share', 'include'):
            src = source / name
            if src.is_dir():
                _copy_tree_merge(src, paths['base'] / name)

    postgres_version_file(root).write_text(version + '\n', encoding='utf-8')
    print(format_console('ok', f'PostgreSQL {version} установлен в {paths["base"]}'))


def _linux_build_tools_hint() -> str:
    if Path('/etc/debian_version').is_file():
        return (
            'sudo apt-get install -y build-essential libreadline-dev '
            'zlib1g-dev flex bison libxml2-dev libssl-dev'
        )
    if Path('/etc/redhat-release').is_file():
        return 'sudo dnf groupinstall -y "Development Tools" && sudo dnf install -y readline-devel zlib-devel'
    return 'Установите gcc, make, readline/zlib development packages'


def _require_linux_build_tools() -> None:
    missing = [tool for tool in ('gcc', 'make') if shutil.which(tool) is None]
    if missing:
        raise RuntimeError(
            'Для сборки portable PostgreSQL нужны: '
            + ', '.join(missing)
            + f'. Установите: {_linux_build_tools_hint()}'
        )


def _install_linux(root: Path, version: str, force: bool) -> None:
    paths = _ensure_layout(root)
    if is_installed(root) and not force:
        installed = read_installed_version(root)
        if installed == version:
            print(format_console('skip', f'PostgreSQL {version} уже установлен'))
            return
        print(format_console('info', f'Обновление PostgreSQL {installed} → {version}…'))
        force = True

    _require_linux_build_tools()

    if force and paths['bin'].is_dir():
        stop_server(root)
        shutil.rmtree(paths['bin'], ignore_errors=True)

    cache_tmp = root / 'virtual_env' / 'cache' / 'tmp'
    cache_tmp.mkdir(parents=True, exist_ok=True)
    tarball = f'postgresql-{version}.tar.bz2'
    url = f'{PG_FTP_SOURCE}v{version}/{tarball}'
    with tempfile.TemporaryDirectory(dir=str(cache_tmp)) as tmp:
        tmp_path = Path(tmp)
        tar_path = tmp_path / tarball
        _download(url, tar_path)
        extract_dir = tmp_path / 'src'
        extract_dir.mkdir()
        with tarfile.open(tar_path, 'r:bz2') as archive:
            archive.extractall(extract_dir)
        source_dirs = list(extract_dir.glob(f'postgresql-{version}'))
        if not source_dirs:
            raise RuntimeError('Не найден каталог исходников PostgreSQL после распаковки')
        source = source_dirs[0]
        prefix = paths['base']
        jobs = str(max(1, (os.cpu_count() or 2)))
        print(f'-> Сборка PostgreSQL {version} (может занять несколько минут)…')
        configure = ['./configure', f'--prefix={prefix}', '--without-icu']
        cfg = subprocess.run([*configure, '--with-openssl'], cwd=str(source), check=False)
        if cfg.returncode != 0:
            print(format_console('warning', 'configure --with-openssl не удался; повтор без OpenSSL'))
            subprocess.run(configure, cwd=str(source), check=True)
        subprocess.run(['make', f'-j{jobs}'], cwd=str(source), check=True)
        subprocess.run(['make', 'install'], cwd=str(source), check=True)

    postgres_version_file(root).write_text(version + '\n', encoding='utf-8')
    print(format_console('ok', f'PostgreSQL {version} установлен в {paths["base"]}'))


def install_postgres(
    root: Path,
    *,
    port: int = DEFAULT_PORT,
    force: bool = False,
    platform_name: str = 'auto',
    skip_if_system: bool = True,
    start: bool = True,
    create_db: bool = True,
) -> int:
    """
    Returns:
        0 — OK / SKIP
        1 — ошибка
        2 — SKIP из‑за системной службы
    """
    if _force_install_from_env():
        skip_if_system = False

    if skip_if_system and has_system_postgresql_service():
        print(format_console('skip', 'Найдена системная служба PostgreSQL — portable не устанавливается'))
        print(format_console('info', 'Принудительно: POSTGRES_FORCE_INSTALL=true в .env или --no-skip-system'))
        return 2

    if not skip_if_system and has_system_postgresql_service():
        print(format_console(
            'warning',
            'POSTGRES_FORCE_INSTALL / --no-skip-system: установка portable при системной службе '
            '(проверьте порт 5432)',
        ))

    system = platform_name.lower()
    if system == 'auto':
        system = platform.system().lower()

    version = resolve_latest_version()
    print(format_console('info', f'Целевая версия PostgreSQL: {version}'))

    defaults = load_db_defaults(root)
    try:
        port = int(defaults.get('port') or port)
    except ValueError:
        port = DEFAULT_PORT
    user = defaults['user']
    password = defaults['password']

    try:
        if system == 'windows':
            _install_windows(root, version, force)
        elif system == 'linux':
            _install_linux(root, version, force)
        else:
            raise RuntimeError(f'Неподдерживаемая платформа для portable PostgreSQL: {system}')

        _initdb_if_needed(root, user, password, port, DEFAULT_BIND)
        if start:
            start_server(root)
        if create_db and start:
            ensure_databases(root, port=port)
    except Exception as exc:
        print(format_console('error', str(exc)), file=sys.stderr)
        return 1
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description='Install portable PostgreSQL into virtual_env/packages/postgres'
    )
    parser.add_argument('--root', type=Path, default=PROJECT_ROOT)
    parser.add_argument('--port', type=int, default=DEFAULT_PORT)
    parser.add_argument('--force', action='store_true')
    parser.add_argument('--platform', default='auto', choices=('auto', 'windows', 'linux'))
    parser.add_argument('--ping-only', action='store_true')
    parser.add_argument('--check-system-only', action='store_true')
    parser.add_argument(
        '--check-force-only',
        action='store_true',
        help='Exit 0 if POSTGRES_FORCE_INSTALL is set, else 1',
    )
    parser.add_argument('--ensure-db-only', action='store_true')
    parser.add_argument('--no-skip-system', action='store_true')
    parser.add_argument('--no-start', action='store_true')
    args = parser.parse_args()

    if args.check_system_only:
        return 0 if has_system_postgresql_service() else 1

    if args.check_force_only:
        return 0 if _force_install_from_env() else 1

    if args.ping_only:
        return 0 if ping_postgres(args.root, port=args.port) else 1

    if args.ensure_db_only:
        try:
            ensure_databases(args.root, port=args.port)
        except Exception as exc:
            print(format_console('error', str(exc)), file=sys.stderr)
            return 1
        return 0

    code = install_postgres(
        args.root,
        port=args.port,
        force=args.force,
        platform_name=args.platform,
        skip_if_system=not args.no_skip_system,
        start=not args.no_start,
        create_db=not args.no_start,
    )
    return 0 if code in (0, 2) else 1


if __name__ == '__main__':
    raise SystemExit(main())
