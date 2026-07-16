#!/usr/bin/env python3
"""
Проверка ядра ERGO MS на соответствие правилам Cursor / архитектуре.

Использование: ergoms core-rules-check

Включает:
- validate_module_isolation --scope=all --fail-on-warning (ядро + модули)
- запрет console.error в прикладном коде клиента (кроме logError.js / logger.js)
- запрет нативного <select> / b-form-select в .vue ядра
- запрет from modules. в core/api/src (дополнительный текстовый grep)
- UTF-8 BOM в .ps1 deployment с не-ASCII (Windows PowerShell 5.1)
- LF без BOM в .sh deployment (Linux shebang и source)
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

_SCRIPTS_DIR = Path(__file__).resolve().parent
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
if hasattr(sys.stderr, 'reconfigure'):
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')
os.environ.setdefault('PYTHONIOENCODING', 'utf-8')

from validate_ps1_encoding import find_ps1_encoding_violations  # noqa: E402
from validate_sh_encoding import find_sh_encoding_violations  # noqa: E402

_DEPLOYMENT_DIR = _SCRIPTS_DIR.parent
PROJECT_ROOT = _DEPLOYMENT_DIR.parent.parent
API_DIR = PROJECT_ROOT / 'core' / 'api'
CLIENT_SRC = PROJECT_ROOT / 'core' / 'client' / 'src'
CORE_API_SRC = PROJECT_ROOT / 'core' / 'api' / 'src'

CONSOLE_ERROR_ALLOWLIST = {
    CLIENT_SRC / 'js' / 'utils' / 'logError.js',
    CLIENT_SRC / 'js' / 'utils' / 'logger.js',
}

SELECT_PATTERNS = (
    re.compile(r'<\s*select\b', re.IGNORECASE),
    re.compile(r'<\s*b-form-select\b', re.IGNORECASE),
    re.compile(r'<\s*option\b', re.IGNORECASE),
)

MODULES_IMPORT_RE = re.compile(r'^\s*(from\s+modules\.|import\s+modules\.)')


def _python_executable() -> Path:
    if sys.platform == 'win32':
        candidate = PROJECT_ROOT / 'virtual_env' / 'python' / 'Scripts' / 'python.exe'
    else:
        candidate = PROJECT_ROOT / 'virtual_env' / 'python' / 'bin' / 'python'
    if candidate.is_file():
        return candidate
    return Path(sys.executable)


def run_module_isolation_check() -> list[str]:
    """Запускает Django management command validate_module_isolation."""
    errors: list[str] = []
    python = _python_executable()
    cmd = [
        str(python),
        '-m',
        'commands',
        'validate_module_isolation',
        '--scope=core',
        '--fail-on-warning',
    ]
    result = subprocess.run(
        cmd,
        cwd=str(API_DIR),
        env={**os.environ, 'PYTHONIOENCODING': 'utf-8', 'PYTHONUTF8': '1'},
        capture_output=True,
        text=True,
        encoding='utf-8',
        errors='replace',
    )
    output = (result.stdout or '') + (result.stderr or '')
    if output.strip():
        print(output.rstrip())
    if result.returncode != 0:
        errors.append('validate_module_isolation: обнаружены нарушения изоляции')
    return errors


def _iter_files(root: Path, suffix: str) -> list[Path]:
    if not root.is_dir():
        return []
    files: list[Path] = []
    for path in root.rglob(f'*{suffix}'):
        parts = set(path.parts)
        if 'node_modules' in parts or 'dist' in parts or '__pycache__' in parts:
            continue
        files.append(path)
    return files


def check_console_error() -> list[str]:
    violations: list[str] = []
    for path in _iter_files(CLIENT_SRC, '.js'):
        if path.suffix != '.js':
            continue
        if path.resolve() in {p.resolve() for p in CONSOLE_ERROR_ALLOWLIST}:
            continue
        try:
            text = path.read_text(encoding='utf-8')
        except (OSError, UnicodeDecodeError):
            continue
        for line_no, line in enumerate(text.splitlines(), start=1):
            if 'console.error(' in line:
                rel = path.relative_to(PROJECT_ROOT)
                violations.append(f'{rel}:{line_no}: console.error( — используйте logError')
    return violations


def check_native_select() -> list[str]:
    violations: list[str] = []
    for path in _iter_files(CLIENT_SRC, '.vue'):
        try:
            text = path.read_text(encoding='utf-8')
        except (OSError, UnicodeDecodeError):
            continue
        for line_no, line in enumerate(text.splitlines(), start=1):
            if any(p.search(line) for p in SELECT_PATTERNS):
                rel = path.relative_to(PROJECT_ROOT)
                violations.append(f'{rel}:{line_no}: native select — используйте SelectBox')
    return violations


def check_modules_imports_in_core() -> list[str]:
    violations: list[str] = []
    for path in _iter_files(CORE_API_SRC, '.py'):
        if 'validate_module_isolation' in path.name:
            continue
        try:
            lines = path.read_text(encoding='utf-8').splitlines()
        except (OSError, UnicodeDecodeError):
            continue
        for line_no, line in enumerate(lines, start=1):
            stripped = line.strip()
            if stripped.startswith('#'):
                continue
            if MODULES_IMPORT_RE.match(line):
                rel = path.relative_to(PROJECT_ROOT)
                violations.append(f'{rel}:{line_no}: импорт modules.* в ядре запрещён')
    return violations


def main() -> int:
    all_errors: list[str] = []

    print('=== Проверка изоляции модулей (validate_module_isolation) ===')
    all_errors.extend(run_module_isolation_check())

    print('\n=== Проверка клиента: console.error ===')
    console_violations = check_console_error()
    if console_violations:
        all_errors.extend(console_violations)
        for item in console_violations:
            print(f'[ERROR] {item}')
    else:
        print('[OK] console.error в прикладном коде не найден')

    print('\n=== Проверка клиента: native select ===')
    select_violations = check_native_select()
    if select_violations:
        all_errors.extend(select_violations)
        for item in select_violations:
            print(f'[ERROR] {item}')
    else:
        print('[OK] native select в .vue не найден')

    print('\n=== Проверка API: from modules. ===')
    import_violations = check_modules_imports_in_core()
    if import_violations:
        all_errors.extend(import_violations)
        for item in import_violations:
            print(f'[ERROR] {item}')
    else:
        print('[OK] импорты modules.* в core/api/src не найдены')

    print('\n=== Проверка deployment: UTF-8 BOM в .ps1 ===')
    ps1_violations = find_ps1_encoding_violations()
    if ps1_violations:
        for path in ps1_violations:
            rel = path.relative_to(PROJECT_ROOT)
            msg = f'{rel}: нет UTF-8 BOM (кириллица сломает PowerShell 5.1)'
            all_errors.append(msg)
            print(f'[ERROR] {msg}')
    else:
        print('[OK] все .ps1 deployment с не-ASCII имеют UTF-8 BOM')

    print('\n=== Проверка deployment: LF без BOM в .sh ===')
    sh_violations = find_sh_encoding_violations()
    if sh_violations:
        for path, issues in sh_violations:
            rel = path.relative_to(PROJECT_ROOT)
            msg = f'{rel}: {", ".join(issues)} (Linux shebang/source)'
            all_errors.append(msg)
            print(f'[ERROR] {msg}')
    else:
        print('[OK] все .sh deployment в UTF-8 LF без BOM')

    if all_errors:
        print(f'\n[ERROR] Проверка завершилась с ошибками: {len(all_errors)}')
        return 1

    print('\n[OK] Все проверки ядра пройдены')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
