"""Пути артефактов ERGO MS внутри корня проекта (без записи вне ERGO_ROOT)."""

from __future__ import annotations

import sys
from pathlib import Path


def virtual_env_dir(root: Path) -> Path:
    return root / 'virtual_env'


def packages_dir(root: Path) -> Path:
    return virtual_env_dir(root) / 'packages'


def package_dir(root: Path, name: str) -> Path:
    """Каталог одного portable-пакета: virtual_env/packages/<name>."""
    return packages_dir(root) / name


def cache_dir(root: Path) -> Path:
    return virtual_env_dir(root) / 'cache'


def cache_pip_dir(root: Path) -> Path:
    return cache_dir(root) / 'pip'


def cache_poetry_dir(root: Path) -> Path:
    return cache_dir(root) / 'poetry'


def cache_npm_dir(root: Path) -> Path:
    return cache_dir(root) / 'npm'


def cache_downloads_dir(root: Path) -> Path:
    """Кэш архивов portable Python / Node.js (и подобных runtime)."""
    return cache_dir(root) / 'downloads'


def npm_root_dir(root: Path) -> Path:
    """Каталог npm workspace (package.json, lock, node_modules)."""
    return virtual_env_dir(root) / 'npm'


def npm_node_modules_dir(root: Path) -> Path:
    return npm_root_dir(root) / 'node_modules'


def cache_tmp_dir(root: Path) -> Path:
    return cache_dir(root) / 'tmp'


def nssm_dir(root: Path) -> Path:
    return packages_dir(root) / 'nssm'


def portable_python_dir(root: Path) -> Path:
    """Portable CPython (python-build-standalone) — база для project venv."""
    return packages_dir(root) / 'python'


def portable_python_exe(root: Path) -> Path:
    base = portable_python_dir(root)
    if sys.platform == 'win32':
        return base / 'python.exe'
    return base / 'bin' / 'python3'


def nodejs_dir(root: Path) -> Path:
    return packages_dir(root) / 'nodejs'


def nodejs_exe(root: Path) -> Path:
    base = nodejs_dir(root)
    if sys.platform == 'win32':
        return base / 'node.exe'
    return base / 'bin' / 'node'


def npm_exe(root: Path) -> Path:
    base = nodejs_dir(root)
    if sys.platform == 'win32':
        cmd = base / 'npm.cmd'
        if cmd.is_file():
            return cmd
        return base / 'npm'
    return base / 'bin' / 'npm'


def nodejs_bin_dir(root: Path) -> Path:
    base = nodejs_dir(root)
    if sys.platform == 'win32':
        return base
    return base / 'bin'


def jupyter_dir(root: Path) -> Path:
    return virtual_env_dir(root) / 'jupyter'


def jupyter_kernels_dir(root: Path) -> Path:
    return jupyter_dir(root) / 'kernels'


def letsencrypt_dir(root: Path) -> Path:
    return packages_dir(root) / 'letsencrypt'


def certbot_bin(root: Path) -> Path:
    return virtual_env_dir(root) / 'python' / 'bin' / 'certbot'


def certbot_webroot_dir(root: Path) -> Path:
    return packages_dir(root) / 'certbot' / 'webroot'


def wrappers_dir(root: Path) -> Path:
    return root / 'core' / 'deployment' / 'wrappers'


def systemd_units_dir(root: Path) -> Path:
    return wrappers_dir(root) / 'systemd'


def systemd_env_file(root: Path) -> Path:
    return wrappers_dir(root) / 'ergo_ms.env'


def ensure_dir(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True)
    return path


def tool_cache_environ(root: Path) -> dict[str, str]:
    """Переменные кэша pip / Poetry / npm внутри virtual_env/cache."""
    pip = str(ensure_dir(cache_pip_dir(root)))
    poetry = str(ensure_dir(cache_poetry_dir(root)))
    npm = str(ensure_dir(cache_npm_dir(root)))
    return {
        'PIP_CACHE_DIR': pip,
        'POETRY_CACHE_DIR': poetry,
        'npm_config_cache': npm,
        'NPM_CONFIG_CACHE': npm,
    }
