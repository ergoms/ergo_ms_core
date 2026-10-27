#!/usr/bin/env python3
"""Быстрые проверки ergoms ci и строгий ночной прогон ergoms ci-nightly."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time
from pathlib import Path

_SCRIPTS_DIR = Path(__file__).resolve().parent
_DEPLOYMENT_DIR = _SCRIPTS_DIR.parent
_PROJECT_ROOT = _DEPLOYMENT_DIR.parent.parent

for _path in (_DEPLOYMENT_DIR, _SCRIPTS_DIR):
    _path_str = str(_path)
    if _path_str not in sys.path:
        sys.path.insert(0, _path_str)

from cli_locale import t  # noqa: E402
from console_tags import configure_stdio_utf8, format_console  # noqa: E402
from project_layout import (  # noqa: E402
    nodejs_exe,
    npm_exe,
    npm_root_dir,
    prepend_client_cli_path,
)

FAST_STEP_LABELS = (
    'poetry.lock',
    'package-lock.json',
    'core-rules-check',
    'system-test unit',
    'lint:check',
    'client-tests',
)

_NIGHTLY = (
    ('scenarios', ('--spec', 'host_sqlite_direct')),
    ('scenarios', ('--spec', 'docker_direct')),
    ('security', ()),
    ('browser', ()),
)


def _nightly_label(suite: str, extra: tuple[str, ...]) -> str:
    spec = ''
    if '--spec' in extra:
        spec = extra[extra.index('--spec') + 1]
    if spec:
        return f'system-test {suite} {spec}'
    return f'system-test {suite}'


def nightly_step_labels() -> tuple[str, ...]:
    return tuple(_nightly_label(suite, extra) for suite, extra in _NIGHTLY)


def _line_buffer_stdio() -> None:
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, 'reconfigure', None)
        if reconfigure is None:
            continue
        try:
            reconfigure(line_buffering=True)
        except (OSError, ValueError):
            continue


def _emit(level: str, message: str, *, error: bool = False) -> None:
    stream = sys.stderr if error else sys.stdout
    print(format_console(level, message), file=stream, flush=True)


def _child_env(env: dict[str, str] | None) -> dict[str, str]:
    child = os.environ.copy() if env is None else dict(env)
    child['PYTHONUNBUFFERED'] = '1'
    return child


def _run(
    label: str,
    argv: list[str],
    *,
    cwd: Path,
    index: int,
    total: int,
    env: dict[str, str] | None = None,
) -> int:
    print(flush=True)
    _emit('info', t('ci_step_start', index=index, total=total, label=label))
    started = time.monotonic()
    code = subprocess.call(argv, cwd=str(cwd), env=_child_env(env))
    seconds = int(time.monotonic() - started)
    if code != 0:
        _emit(
            'error',
            t('ci_step_failed', label=label, code=code, seconds=seconds),
            error=True,
        )
        return code
    _emit('ok', t('ci_step_ok', label=label, seconds=seconds))
    return 0


def _node_binary(root: Path) -> Path | None:
    portable = nodejs_exe(root)
    if portable.is_file():
        return portable
    return None


def _npm_binary(root: Path) -> str | None:
    portable = npm_exe(root)
    if portable.is_file():
        return str(portable)
    return None


def _fast_steps(root: Path) -> int:
    py = sys.executable
    scripts = root / 'core' / 'deployment' / 'scripts'
    node = _node_binary(root)
    npm = _npm_binary(root)
    if node is None or npm is None:
        _emit('error', t('ci_node_missing'), error=True)
        return 1

    total = len(FAST_STEP_LABELS)
    _emit('info', t('ci_run_start', count=total))
    lint_env = prepend_client_cli_path(os.environ.copy(), root)
    commands: dict[str, tuple[list[str], Path, dict[str, str] | None]] = {
        'poetry.lock': ([py, str(scripts / 'validate_poetry_lock.py')], root, None),
        'package-lock.json': ([str(node), str(scripts / 'validate_npm_lock.js')], root, None),
        'core-rules-check': ([py, str(scripts / 'validate_core_rules.py')], root, None),
        'system-test unit': (
            [py, str(scripts / 'run_system_test.py'), '--suite', 'unit'],
            root,
            None,
        ),
        'lint:check': (
            [npm, 'run', 'lint:check', '-w', '@ergo-ms/core-client'],
            npm_root_dir(root),
            lint_env,
        ),
    }
    for index, label in enumerate(FAST_STEP_LABELS, start=1):
        if label == 'client-tests':
            return _client_tests(root, node, scripts, index=index, total=total)
        argv, cwd, env = commands[label]
        code = _run(label, argv, cwd=cwd, index=index, total=total, env=env)
        if code != 0:
            return code
    return 0


def client_test_files(root: Path, disabled: frozenset[str] | None = None) -> list[Path]:
    """Тесты клиента модулей, которые не выключены в DISABLED_MODULES."""
    if disabled is None:
        from lifecycle.modules.catalog import ModuleCatalog

        disabled = ModuleCatalog.from_project_env(root).disabled
    tests = sorted(root.glob('modules/*/client/tests/**/*.test.mjs'))
    if not disabled:
        return tests
    kept: list[Path] = []
    root_resolved = root.resolve()
    for path in tests:
        try:
            parts = path.resolve().relative_to(root_resolved).parts
        except ValueError:
            kept.append(path)
            continue
        if len(parts) >= 2 and parts[0] == 'modules' and parts[1] in disabled:
            continue
        kept.append(path)
    return kept


def _client_tests(root: Path, node: Path, scripts: Path, *, index: int, total: int) -> int:
    print(flush=True)
    _emit('info', t('ci_step_start', index=index, total=total, label='client-tests'))
    tests = client_test_files(root)
    if not tests:
        _emit(
            'skip',
            t('ci_step_skipped', label='client-tests', detail=t('ci_client_tests_none')),
        )
        return 0
    loader = (scripts / 'resolve_workspace_modules.mjs').as_uri()
    started = time.monotonic()
    code = subprocess.call(
        [str(node), '--import', loader, '--test', *[str(path) for path in tests]],
        cwd=str(root),
        env=_child_env(None),
    )
    seconds = int(time.monotonic() - started)
    if code != 0:
        _emit(
            'error',
            t('ci_step_failed', label='client-tests', code=code, seconds=seconds),
            error=True,
        )
        return code
    _emit('ok', t('ci_step_ok', label='client-tests', seconds=seconds))
    return 0


def _nightly(root: Path) -> int:
    labels = nightly_step_labels()
    total = len(labels)
    script = root / 'core' / 'deployment' / 'scripts' / 'run_system_test.py'
    for index, ((suite, extra), label) in enumerate(zip(_NIGHTLY, labels, strict=True), start=1):
        code = _run(
            label,
            [sys.executable, str(script), '--suite', suite, '--strict', *extra],
            cwd=root,
            index=index,
            total=total,
        )
        if code != 0:
            return code
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description='Fast ERGO MS checks')
    parser.add_argument('--nightly', action='store_true')
    args = parser.parse_args(argv)
    configure_stdio_utf8()
    _line_buffer_stdio()
    code = _fast_steps(_PROJECT_ROOT)
    if code != 0:
        return code
    if args.nightly:
        print(format_console('ok', t('ci_finished')), flush=True)
        print(flush=True)
        print(
            format_console('info', t('ci_nightly_start', count=len(nightly_step_labels()))),
            flush=True,
        )
        code = _nightly(_PROJECT_ROOT)
        if code != 0:
            return code
        print(format_console('ok', t('ci_nightly_finished')), flush=True)
        return 0
    print(format_console('ok', t('ci_finished')), flush=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
