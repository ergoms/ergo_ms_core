"""Скачивание и распаковка archive-пакетов в virtual_env/packages/."""

from __future__ import annotations

import os
import shutil
import sys
import tarfile
import tempfile
import time
import urllib.request
import zipfile
from pathlib import Path

_PACKAGES_PKG_DIR = Path(__file__).resolve().parent
_DEPLOYMENT_DIR = _PACKAGES_PKG_DIR.parent
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))

from console_tags import format_console  # noqa: E402
from project_layout import (  # noqa: E402
    cache_downloads_dir,
    cache_tmp_dir,
    ensure_dir,
    package_dir,
)

from .models import PackageSpec, PlatformArchive  # noqa: E402

DOWNLOAD_CHUNK_SIZE = 8 * 1024 * 1024
PROGRESS_UPDATE_INTERVAL_SEC = 0.5
DOWNLOAD_USER_AGENT = 'ergoms/1.0 (package installer)'
DOWNLOAD_TIMEOUT_SEC = 300
MIN_ARCHIVE_BYTES = 1024


class ArchiveInstallError(Exception):
    """Ошибка archive-установки."""


def _archive_filename(url: str, archive_type: str) -> str:
    name = url.rstrip('/').split('/')[-1]
    if name and '.' in name:
        return name
    ext = {
        'zip': '.zip',
        'tar.gz': '.tar.gz',
        'tgz': '.tgz',
        'tar.xz': '.tar.xz',
    }.get(archive_type, '.bin')
    return f'package{ext}'


def _write_progress(downloaded: int, total_size: int, speed_bps: float) -> None:
    downloaded_mb = downloaded / (1024 * 1024)
    speed_mbps = speed_bps / (1024 * 1024)
    if total_size > 0:
        total_mb = total_size / (1024 * 1024)
        percent = downloaded / total_size * 100
        message = (
            f'\rЗагрузка: {downloaded_mb:.1f}/{total_mb:.1f} МБ '
            f'({percent:.0f}%) {speed_mbps:.1f} МБ/с'
        )
    else:
        message = f'\rЗагрузка: {downloaded_mb:.1f} МБ {speed_mbps:.1f} МБ/с'
    sys.stdout.write(message)
    sys.stdout.flush()


def download_url(url: str, destination: Path) -> None:
    """Скачать url в destination с прогрессом."""
    ensure_dir(destination.parent)
    request = urllib.request.Request(url, headers={'User-Agent': DOWNLOAD_USER_AGENT})
    started = time.monotonic()
    last_print = started
    downloaded = 0
    with urllib.request.urlopen(request, timeout=DOWNLOAD_TIMEOUT_SEC) as response:
        total_size = int(response.headers.get('Content-Length') or 0)
        with open(destination, 'wb') as out:
            while True:
                chunk = response.read(DOWNLOAD_CHUNK_SIZE)
                if not chunk:
                    break
                out.write(chunk)
                downloaded += len(chunk)
                now = time.monotonic()
                if now - last_print >= PROGRESS_UPDATE_INTERVAL_SEC:
                    elapsed = max(now - started, 1e-6)
                    _write_progress(downloaded, total_size, downloaded / elapsed)
                    last_print = now
    if downloaded:
        sys.stdout.write('\n')
        sys.stdout.flush()
    if destination.stat().st_size < MIN_ARCHIVE_BYTES:
        raise ArchiveInstallError(f'Слишком маленький архив: {destination}')


def _extract_zip(archive_path: Path, destination: Path) -> None:
    with zipfile.ZipFile(archive_path, 'r') as zf:
        zf.extractall(destination)


def _extract_tar(archive_path: Path, destination: Path, mode: str) -> None:
    with tarfile.open(archive_path, mode) as tf:
        tf.extractall(destination)


def extract_archive(archive_path: Path, destination: Path, archive_type: str) -> None:
    ensure_dir(destination)
    kind = archive_type.lower().strip()
    if kind == 'zip':
        _extract_zip(archive_path, destination)
    elif kind in ('tar.gz', 'tgz'):
        _extract_tar(archive_path, destination, 'r:gz')
    elif kind == 'tar.xz':
        _extract_tar(archive_path, destination, 'r:xz')
    else:
        raise ArchiveInstallError(f'Неподдерживаемый тип архива: {archive_type}')


def _single_top_dir(extract_root: Path) -> Path | None:
    entries = [p for p in extract_root.iterdir() if p.name not in ('__MACOSX',)]
    dirs = [p for p in entries if p.is_dir()]
    files = [p for p in entries if p.is_file()]
    if len(dirs) == 1 and not files:
        return dirs[0]
    return None


def _chmod_executables(root: Path) -> None:
    if sys.platform == 'win32':
        return
    for path in root.rglob('*'):
        if path.is_file() and os.access(path, os.X_OK) is False:
            name = path.name.lower()
            if name.endswith(('.so', '.dylib')):
                continue
            # Типичные бинарники без расширения и *.sh
            if '.' not in path.name or name.endswith(('.sh',)):
                try:
                    path.chmod(path.stat().st_mode | 0o755)
                except OSError:
                    pass


def _apply_pick(extract_root: Path, dest: Path, plat: PlatformArchive) -> None:
    assert plat.pick_match
    matches = sorted(extract_root.glob(plat.pick_match))
    if not matches:
        raise ArchiveInstallError(f'Не найден файл по шаблону {plat.pick_match!r}')
    source = matches[0]
    ensure_dir(dest)
    target_name = plat.pick_as or source.name
    target = dest / target_name
    if dest.exists():
        for child in dest.iterdir():
            if child.is_dir():
                shutil.rmtree(child, ignore_errors=True)
            else:
                child.unlink(missing_ok=True)
    shutil.copy2(source, target)


def _apply_strip_or_move(extract_root: Path, dest: Path, *, strip_top_dir: bool) -> None:
    if dest.exists():
        shutil.rmtree(dest)
    source = extract_root
    if strip_top_dir:
        top = _single_top_dir(extract_root)
        if top is None:
            raise ArchiveInstallError(
                'strip_top_dir=true, но в архиве нет единственного корневого каталога'
            )
        source = top
    shutil.move(str(source), str(dest))


def install_archive_package(
    root: Path,
    spec: PackageSpec,
    plat: PlatformArchive,
    *,
    force: bool = False,
    refresh: bool = False,
) -> Path:
    """Установить archive-пакет. Возвращает путь dest."""
    dest = package_dir(root, spec.dest)
    marker_path = dest / plat.marker
    if marker_path.is_file() and not force:
        print(format_console('skip', f'{spec.name} уже установлен: {dest}'))
        return dest

    archive_name = _archive_filename(plat.url, plat.archive)
    cache_path = ensure_dir(cache_downloads_dir(root)) / f'{spec.name}-{archive_name}'
    tmp_base = ensure_dir(cache_tmp_dir(root))

    print(format_console('info', f'Установка пакета {spec.name} → {dest}'))
    try:
        use_cache = (
            cache_path.is_file()
            and cache_path.stat().st_size >= MIN_ARCHIVE_BYTES
            and not refresh
        )
        with tempfile.TemporaryDirectory(dir=str(tmp_base), prefix=f'pkg_{spec.name}_') as tmp:
            tmp_path = Path(tmp)
            archive_path = tmp_path / archive_name
            if use_cache:
                print(format_console('info', f'Используется кэш: {cache_path}'))
                shutil.copy2(cache_path, archive_path)
            else:
                print(format_console('info', f'Загрузка {plat.url}'))
                download_url(plat.url, archive_path)
                shutil.copy2(archive_path, cache_path)

            extract_root = tmp_path / 'extract'
            ensure_dir(extract_root)
            extract_archive(archive_path, extract_root, plat.archive)

            if force and dest.exists():
                shutil.rmtree(dest, ignore_errors=True)

            if plat.pick_match:
                _apply_pick(extract_root, dest, plat)
            else:
                _apply_strip_or_move(
                    extract_root,
                    dest,
                    strip_top_dir=plat.strip_top_dir,
                )

            _chmod_executables(dest)

            # Для linux ffmpeg и подобных — явный chmod на marker
            final_marker = dest / plat.marker
            if final_marker.is_file() and sys.platform != 'win32':
                try:
                    final_marker.chmod(final_marker.stat().st_mode | 0o755)
                except OSError:
                    pass

            if not final_marker.is_file():
                raise ArchiveInstallError(
                    f'После установки не найден marker: {final_marker}'
                )
    except ArchiveInstallError:
        raise
    except Exception as exc:
        raise ArchiveInstallError(str(exc)) from exc

    print(format_console('ok', f'Пакет {spec.name} установлен: {dest}'))
    return dest
