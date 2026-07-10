"""
Установка portable Redis в virtual_env/packages/redis (Windows zip / Linux source build).
"""

from __future__ import annotations

import argparse
import os
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[3]
DEPLOYMENT_DIR = PROJECT_ROOT / 'core' / 'deployment'
TEMPLATE_PATH = DEPLOYMENT_DIR / 'redis' / 'redis.conf.template'

REDIS_LINUX_VERSION = '7.4.2'
REDIS_LINUX_TARBALL = f'redis-{REDIS_LINUX_VERSION}.tar.gz'
REDIS_LINUX_URL = f'https://download.redis.io/releases/{REDIS_LINUX_TARBALL}'
REDIS_LINUX_FALLBACK_URL = (
    f'https://codeload.github.com/redis/redis/tar.gz/refs/tags/{REDIS_LINUX_VERSION}'
)

DOWNLOAD_USER_AGENT = 'ergoms/1.0 (Redis installer)'
DOWNLOAD_TIMEOUT_SEC = 300

REDIS_WINDOWS_VERSION = '5.0.14.1'
REDIS_WINDOWS_ZIP = f'Redis-x64-{REDIS_WINDOWS_VERSION}.zip'
REDIS_WINDOWS_URL = (
    f'https://github.com/tporadowski/redis/releases/download/v{REDIS_WINDOWS_VERSION}/'
    f'{REDIS_WINDOWS_ZIP}'
)

DEFAULT_PORT = 6379
DEFAULT_BIND = '127.0.0.1'


def redis_packages_dir(root: Path) -> Path:
    return root / 'virtual_env' / 'packages' / 'redis'


def redis_server_path(root: Path) -> Path:
    base = redis_packages_dir(root)
    if platform.system().lower() == 'windows':
        candidate = base / 'redis-server.exe'
        if candidate.is_file():
            return candidate
        return base / 'bin' / 'redis-server.exe'
    return base / 'bin' / 'redis-server'


def redis_cli_path(root: Path) -> Path:
    base = redis_packages_dir(root)
    if platform.system().lower() == 'windows':
        candidate = base / 'redis-cli.exe'
        if candidate.is_file():
            return candidate
        return base / 'bin' / 'redis-cli.exe'
    return base / 'bin' / 'redis-cli'


def redis_conf_path(root: Path) -> Path:
    return redis_packages_dir(root) / 'conf' / 'redis.conf'


def is_installed(root: Path) -> bool:
    return redis_server_path(root).is_file() and redis_conf_path(root).is_file()


def _download_once(url: str, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    request = urllib.request.Request(
        url,
        headers={'User-Agent': DOWNLOAD_USER_AGENT},
    )
    with urllib.request.urlopen(request, timeout=DOWNLOAD_TIMEOUT_SEC) as response:
        destination.write_bytes(response.read())
    if destination.stat().st_size < 1024:
        destination.unlink(missing_ok=True)
        raise RuntimeError(f'Downloaded file is too small: {url}')


def _download_with_curl(url: str, destination: Path) -> bool:
    curl_exe = shutil.which('curl')
    if not curl_exe:
        return False
    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        result = subprocess.run(
            [
                curl_exe,
                '-L',
                '--fail',
                '--retry',
                '3',
                '--retry-delay',
                '2',
                '-A',
                DOWNLOAD_USER_AGENT,
                '-o',
                str(destination),
                url,
            ],
            capture_output=True,
            check=False,
        )
    except OSError:
        return False
    return (
        result.returncode == 0
        and destination.is_file()
        and destination.stat().st_size >= 1024
    )


def _download(url: str, destination: Path, *, fallback_urls: tuple[str, ...] = ()) -> None:
    last_error: Exception | None = None
    for candidate in (url, *fallback_urls):
        print(f'-> Downloading {candidate}')
        try:
            _download_once(candidate, destination)
            return
        except Exception as exc:
            last_error = exc
            print(f'[ergoms] Download failed ({exc}); trying next source...')
            destination.unlink(missing_ok=True)

        if _download_with_curl(candidate, destination):
            return

    raise RuntimeError(
        f'Could not download Redis archive. Last error: {last_error}'
    ) from last_error


def _ensure_layout(root: Path) -> dict[str, Path]:
    base = redis_packages_dir(root)
    paths = {
        'base': base,
        'conf': base / 'conf',
        'data': base / 'data',
        'logs': base / 'logs',
        'run': base / 'run',
        'bin': base / 'bin',
    }
    for path in paths.values():
        path.mkdir(parents=True, exist_ok=True)
    return paths


def render_redis_conf(root: Path, port: int = DEFAULT_PORT, bind: str = DEFAULT_BIND) -> Path:
    paths = _ensure_layout(root)
    template = TEMPLATE_PATH.read_text(encoding='utf-8')
    conf_path = paths['conf'] / 'redis.conf'

    if platform.system().lower() == 'windows':
        pidfile = (paths['run'] / 'redis.pid').as_posix()
        logfile = (paths['logs'] / 'redis.log').as_posix()
        data_dir = paths['data'].as_posix()
        daemonize = 'no'
    else:
        pidfile = str(paths['run'] / 'redis.pid')
        logfile = str(paths['logs'] / 'redis.log')
        data_dir = str(paths['data'])
        daemonize = 'yes'

    content = (
        template.replace('{{REDIS_BIND}}', bind)
        .replace('{{REDIS_PORT}}', str(port))
        .replace('{{REDIS_DAEMONIZE}}', daemonize)
        .replace('{{REDIS_PIDFILE}}', pidfile)
        .replace('{{REDIS_LOGFILE}}', logfile)
        .replace('{{REDIS_DATA_DIR}}', data_dir)
    )
    conf_path.write_text(content, encoding='utf-8')
    return conf_path


def _install_windows(root: Path, force: bool) -> None:
    paths = _ensure_layout(root)
    server = redis_server_path(root)
    if server.is_file() and not force:
        print('[ergoms] Redis already installed (use --force to reinstall)')
        return

    if force and paths['base'].exists():
        for name in ('redis-server.exe', 'redis-cli.exe', 'redis.windows.conf', 'redis.windows-service.conf'):
            target = paths['base'] / name
            if target.is_file():
                target.unlink()
        bin_dir = paths['base'] / 'bin'
        if bin_dir.is_dir():
            shutil.rmtree(bin_dir, ignore_errors=True)

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        zip_path = tmp_path / REDIS_WINDOWS_ZIP
        _download(REDIS_WINDOWS_URL, zip_path)
        extract_dir = tmp_path / 'extract'
        extract_dir.mkdir()
        with zipfile.ZipFile(zip_path, 'r') as archive:
            archive.extractall(extract_dir)

        source_root = extract_dir
        nested = list(extract_dir.glob('Redis-x64-*'))
        if nested:
            source_root = nested[0]

        for exe_name in ('redis-server.exe', 'redis-cli.exe'):
            src = source_root / exe_name
            if not src.is_file():
                raise RuntimeError(f'Expected {exe_name} in Windows Redis archive')
            shutil.copy2(src, paths['base'] / exe_name)

    print(f'[ergoms] Redis {REDIS_WINDOWS_VERSION} (Windows port) installed to {paths["base"]}')


def _linux_build_tools_hint() -> str:
    if Path('/etc/debian_version').is_file():
        return 'sudo apt-get install -y build-essential'
    if Path('/etc/redhat-release').is_file():
        return 'sudo dnf groupinstall -y "Development Tools"  # or: yum groupinstall'
    return 'Install gcc and make (build-essential / Development Tools)'


def _require_linux_build_tools() -> None:
    missing = []
    for tool in ('gcc', 'make'):
        if shutil.which(tool) is None:
            missing.append(tool)
    if missing:
        raise RuntimeError(
            'Linux portable Redis requires a C compiler and make. Missing: '
            + ', '.join(missing)
            + f'. Install with: {_linux_build_tools_hint()}'
        )


def _install_linux(root: Path, force: bool) -> None:
    paths = _ensure_layout(root)
    server = redis_server_path(root)
    if server.is_file() and not force:
        print('[ergoms] Redis already installed (use --force to reinstall)')
        return

    _require_linux_build_tools()

    prefix = paths['base']
    if force:
        bin_dir = prefix / 'bin'
        if bin_dir.is_dir():
            shutil.rmtree(bin_dir, ignore_errors=True)

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        tar_path = tmp_path / REDIS_LINUX_TARBALL
        _download(REDIS_LINUX_URL, tar_path, fallback_urls=(REDIS_LINUX_FALLBACK_URL,))
        extract_dir = tmp_path / 'src'
        extract_dir.mkdir()
        with tarfile.open(tar_path, 'r:gz') as archive:
            archive.extractall(extract_dir)

        source_dirs = list(extract_dir.glob(f'redis-{REDIS_LINUX_VERSION}'))
        if not source_dirs:
            source_dirs = [p for p in extract_dir.iterdir() if p.is_dir() and p.name.startswith('redis-')]
        if not source_dirs:
            raise RuntimeError('Could not find extracted Redis source directory')
        source_dir = source_dirs[0]

        print(f'-> Building Redis {REDIS_LINUX_VERSION} (this may take 1–3 minutes)...')
        subprocess.run(['make', '-C', str(source_dir), '-j', str(max(1, (os.cpu_count() or 2)))],
                       check=True)
        subprocess.run(
            ['make', '-C', str(source_dir), f'PREFIX={prefix}', 'install'],
            check=True,
        )

    print(f'[ergoms] Redis {REDIS_LINUX_VERSION} installed to {prefix}')


def install_redis(
    root: Path,
    *,
    port: int = DEFAULT_PORT,
    force: bool = False,
    platform_name: str = 'auto',
) -> None:
    system = platform_name.lower()
    if system == 'auto':
        system = platform.system().lower()

    if system == 'windows':
        _install_windows(root, force)
    elif system == 'linux':
        _install_linux(root, force)
    else:
        raise RuntimeError(f'Unsupported platform for portable Redis: {system}')

    conf = render_redis_conf(root, port=port)
    print(f'[ergoms] Redis config: {conf}')


def ping_redis(root: Path, port: int | None = None, timeout_sec: float = 5.0) -> bool:
    cli = redis_cli_path(root)
    if not cli.is_file():
        return False
    conf = redis_conf_path(root)
    bind = DEFAULT_BIND
    if port is None and conf.is_file():
        conf_text = conf.read_text(encoding='utf-8')
        match = re.search(r'^port\s+(\d+)\s*$', conf_text, re.MULTILINE)
        port = int(match.group(1)) if match else DEFAULT_PORT
        bind_match = re.search(r'^bind\s+(\S+)', conf_text, re.MULTILINE)
        if bind_match:
            bind = bind_match.group(1)
    port = port or DEFAULT_PORT

    args = [str(cli), '-h', bind, '-p', str(port), 'ping']
    try:
        result = subprocess.run(
            args,
            capture_output=True,
            text=True,
            timeout=timeout_sec,
            check=False,
        )
    except (subprocess.TimeoutExpired, OSError):
        return False
    if 'PONG' in (result.stdout or '') or 'PONG' in (result.stderr or ''):
        return True

    if conf.is_file() and platform.system().lower() != 'windows':
        try:
            result = subprocess.run(
                [str(cli), '-c', str(conf), 'ping'],
                capture_output=True,
                text=True,
                timeout=timeout_sec,
                check=False,
            )
        except (subprocess.TimeoutExpired, OSError):
            return False
        return 'PONG' in (result.stdout or '') or 'PONG' in (result.stderr or '')

    return False


def main() -> int:
    parser = argparse.ArgumentParser(description='Install portable Redis into virtual_env/packages/redis')
    parser.add_argument('--root', type=Path, default=PROJECT_ROOT)
    parser.add_argument('--port', type=int, default=DEFAULT_PORT)
    parser.add_argument('--force', action='store_true')
    parser.add_argument('--platform', default='auto', choices=('auto', 'windows', 'linux'))
    parser.add_argument('--ping-only', action='store_true', help='Only run redis-cli ping')
    args = parser.parse_args()

    if args.ping_only:
        return 0 if ping_redis(args.root) else 1

    install_redis(args.root, port=args.port, force=args.force, platform_name=args.platform)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
