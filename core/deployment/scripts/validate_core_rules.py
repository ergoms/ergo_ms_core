#!/usr/bin/env python3
"""
Проверка ядра ERGO MS на соответствие правилам Cursor / архитектуре.

Использование: ergoms core-rules-check

Включает:
- validate_module_isolation --scope=core --fail-on-warning (ядро)
- validate_module_isolation --scope=all (отчёт по modules/, без падения CI)
- запрет hardcoded имён модулей в runtime-коде ядра
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
CORE_CLIENT = PROJECT_ROOT / 'core' / 'client'
CORE_API_SRC = PROJECT_ROOT / 'core' / 'api' / 'src'
MODULES_DIR = PROJECT_ROOT / 'modules'

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

HARDCODED_MODULE_ALLOWLIST_SUFFIXES = (
    'validate_core_rules.py',
    'validate_module_isolation.py',
    'module_deps.py',
    'sharedGlobs.generated.js',
)

HARDCODED_MODULE_ALLOWLIST_REL = {
    'core/api/commands/base.py',
    'core/client/vite.config.js',
    'core/client/src/modules/core/ModuleLoader.js',
    'core/client/src/integrations/layoutPluginRegistry.js',
    'core/deployment/lifecycle/modules/module_source.py',
}

HARDCODED_MODULE_LINE_ALLOWLIST = (
    re.compile(r'modules/\*'),
    re.compile(r'modules/\$\{'),
    re.compile(r'@/modules/'),
    re.compile(r'\.\./.*modules/\*'),
    re.compile(r'modules\.'),
    re.compile(r'module_source\s*='),
    re.compile(r'MODULE_SOURCE\s*='),
    re.compile(r"\.get\('workers'"),
    re.compile(r'__pycache__'),
    re.compile(r"'tasks':\s*logging"),
)

CLIENT_MODULE_LITERAL_ALLOWLIST = (
    'core/client/src/modules/core/ModuleLoader.js',
    'core/client/src/modules/core/sharedGlobs.generated.js',
)

CLIENT_CROSS_MODULE_IMPORT_RE = re.compile(
    r"""(?:^|\s)(?:import\s*\(|(?:import|from)\s+)['"]@/modules/([a-z][a-z0-9_-]*)/"""
)


def _python_executable() -> Path:
    if sys.platform == 'win32':
        candidate = PROJECT_ROOT / 'virtual_env' / 'python' / 'Scripts' / 'python.exe'
    else:
        candidate = PROJECT_ROOT / 'virtual_env' / 'python' / 'bin' / 'python'
    if candidate.is_file():
        return candidate
    return Path(sys.executable)


def run_module_isolation_check(*, scope: str, fail_on_error: bool) -> list[str]:
    """Запускает Django management command validate_module_isolation."""
    errors: list[str] = []
    python = _python_executable()
    cmd = [
        str(python),
        '-m',
        'commands',
        'validate_module_isolation',
        f'--scope={scope}',
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
    if result.returncode != 0 and fail_on_error:
        errors.append(f'validate_module_isolation --scope={scope}: обнаружены нарушения изоляции')
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


def _relative_posix(path: Path) -> str:
    return path.relative_to(PROJECT_ROOT).as_posix()


def _is_hardcoded_module_allowlisted(path: Path) -> bool:
    rel = _relative_posix(path)
    if rel in HARDCODED_MODULE_ALLOWLIST_REL:
        return True
    if any(part == 'migrations' for part in path.parts):
        return True
    return path.name in HARDCODED_MODULE_ALLOWLIST_SUFFIXES


def load_installed_module_names() -> list[str]:
    if not MODULES_DIR.is_dir():
        return []
    names = []
    for entry in MODULES_DIR.iterdir():
        if not entry.is_dir():
            continue
        if entry.name.startswith('.') or entry.name == '__pycache__':
            continue
        if not re.fullmatch(r'[a-z][a-z0-9_]*', entry.name):
            continue
        names.append(entry.name)
    return sorted(names)


def check_hardcoded_module_names() -> list[str]:
    module_names = load_installed_module_names()
    if not module_names:
        return []

    literal_pattern = re.compile(
        r"(['\"])(" + "|".join(re.escape(name) for name in module_names) + r")\1"
    )
    scan_roots = [CORE_API_SRC, CLIENT_SRC, CORE_CLIENT / 'vite.config.js']
    violations: list[str] = []
    seen: set[str] = set()

    for root in scan_roots:
        if root.is_file():
            candidates = [root]
        else:
            candidates = []
            for suffix in ('.py', '.js', '.vue', '.scss', '.ts'):
                candidates.extend(_iter_files(root, suffix))

        for path in candidates:
            rel = _relative_posix(path)
            if rel in seen:
                continue
            seen.add(rel)
            if _is_hardcoded_module_allowlisted(path):
                continue
            try:
                lines = path.read_text(encoding='utf-8').splitlines()
            except (OSError, UnicodeDecodeError):
                continue
            for line_no, line in enumerate(lines, start=1):
                stripped = line.strip()
                if not stripped or stripped.startswith('#') or stripped.startswith('//'):
                    continue
                if any(pattern.search(line) for pattern in HARDCODED_MODULE_LINE_ALLOWLIST):
                    continue
                match = literal_pattern.search(line)
                if match:
                    violations.append(
                        f'{rel}:{line_no}: hardcoded module name «{match.group(2)}» — '
                        'используйте ModuleBridge или hook discovery'
                    )
    return violations


def _owner_module_from_client_path(path: Path) -> str | None:
    parts = path.parts
    try:
        idx = parts.index('modules')
        return parts[idx + 1]
    except (ValueError, IndexError):
        return None


def check_client_cross_module_imports() -> list[str]:
    """Запрет import из @/modules/<чужой модуль>/ в client коде модулей."""
    violations: list[str] = []
    if not MODULES_DIR.is_dir():
        return violations

    for mod_dir in MODULES_DIR.iterdir():
        client_root = mod_dir / 'client'
        if not client_root.is_dir():
            continue
        owner = mod_dir.name
        candidates: list[Path] = []
        for suffix in ('.js', '.vue', '.ts'):
            candidates.extend(_iter_files(client_root, suffix))

        for path in candidates:
            rel = _relative_posix(path)
            try:
                lines = path.read_text(encoding='utf-8').splitlines()
            except (OSError, UnicodeDecodeError):
                continue
            for line_no, line in enumerate(lines, start=1):
                stripped = line.strip()
                if not stripped or stripped.startswith('//') or stripped.startswith('*'):
                    continue
                for match in CLIENT_CROSS_MODULE_IMPORT_RE.finditer(line):
                    target = match.group(1)
                    if target == owner:
                        continue
                    violations.append(
                        f'{rel}:{line_no}: import из @/modules/{target}/ — '
                        'используйте ModuleBridge или @/integrations/* из ядра'
                    )
    return violations


def check_client_hardcoded_module_paths() -> list[str]:
    """Запрет захардкоженных URL-путей модулей в ядре клиента.

    Ядро не должно знать маршруты установленных модулей: такие связи
    регистрируются модулем через ModuleBridge (session.scope_entry_routes,
    session_scope.module_context, layout.plugin_registry).
    """
    module_names = load_installed_module_names()
    if not module_names:
        return []

    path_pattern = re.compile(
        r"""['"`]/(""" + "|".join(re.escape(name) for name in module_names) + r""")(?=/|['"`])"""
    )
    violations: list[str] = []
    for suffix in ('.js', '.vue', '.ts'):
        for path in _iter_files(CLIENT_SRC, suffix):
            rel = _relative_posix(path)
            if rel in CLIENT_MODULE_LITERAL_ALLOWLIST:
                continue
            try:
                lines = path.read_text(encoding='utf-8').splitlines()
            except (OSError, UnicodeDecodeError):
                continue
            for line_no, line in enumerate(lines, start=1):
                stripped = line.strip()
                if not stripped or stripped.startswith('//') or stripped.startswith('*'):
                    continue
                match = path_pattern.search(line)
                if match:
                    violations.append(
                        f'{rel}:{line_no}: hardcoded маршрут модуля «/{match.group(1)}» — '
                        'регистрируйте через ModuleBridge (session.org_entry_routes и т.п.)'
                    )
    return violations


def check_client_module_literal_registry() -> list[str]:
    module_names = load_installed_module_names()
    if not module_names:
        return []

    pattern = re.compile(
        r"names\.add\(\s*(['\"])(" + "|".join(re.escape(name) for name in module_names) + r")\1\s*\)"
    )
    violations: list[str] = []
    for path in _iter_files(CLIENT_SRC, '.js'):
        rel = _relative_posix(path)
        if rel in CLIENT_MODULE_LITERAL_ALLOWLIST:
            continue
        if 'layoutPluginRegistry' in rel or 'ModuleLoader' in rel:
            continue
        try:
            lines = path.read_text(encoding='utf-8').splitlines()
        except (OSError, UnicodeDecodeError):
            continue
        for line_no, line in enumerate(lines, start=1):
            match = pattern.search(line)
            if match:
                violations.append(
                    f'{rel}:{line_no}: names.add("{match.group(2)}") — '
                    'регистрируйте модуль через layout.plugin_registry'
                )
    return violations


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

    print('=== Проверка изоляции ядра (validate_module_isolation --scope=core) ===')
    all_errors.extend(run_module_isolation_check(scope='core', fail_on_error=True))

    print('\n=== Отчёт изоляции modules/ (validate_module_isolation --scope=all) ===')
    run_module_isolation_check(scope='all', fail_on_error=False)

    print('\n=== Проверка ядра: hardcoded имена модулей ===')
    hardcoded_violations = check_hardcoded_module_names()
    if hardcoded_violations:
        all_errors.extend(hardcoded_violations)
        for item in hardcoded_violations:
            print(f'[ERROR] {item}')
    else:
        print('[OK] hardcoded имена модулей в runtime-коде ядра не найдены')

    print('\n=== Проверка клиента: hardcoded маршруты модулей ===')
    module_path_violations = check_client_hardcoded_module_paths()
    if module_path_violations:
        all_errors.extend(module_path_violations)
        for item in module_path_violations:
            print(f'[ERROR] {item}')
    else:
        print('[OK] hardcoded маршруты модулей в ядре клиента не найдены')

    print('\n=== Проверка клиента: names.add(module) ===')
    registry_violations = check_client_module_literal_registry()
    if registry_violations:
        all_errors.extend(registry_violations)
        for item in registry_violations:
            print(f'[ERROR] {item}')
    else:
        print('[OK] hardcoded names.add(module) не найдены')

    print('\n=== Проверка клиента: cross-module imports (отчёт) ===')
    cross_module_violations = check_client_cross_module_imports()
    if cross_module_violations:
        for item in cross_module_violations:
            print(f'[WARNING] {item}')
        print(
            f'[INFO] Найдено cross-module imports: {len(cross_module_violations)} '
            '(пока WARNING; целевое состояние — только ModuleBridge)'
        )
    else:
        print('[OK] cross-module imports в modules/*/client не найдены')

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
