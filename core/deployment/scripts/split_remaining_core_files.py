#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path

_SCRIPTS_DIR = Path(__file__).resolve().parent
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

from ps1_io import read_ps1, write_ps1

ROOT = Path(__file__).resolve().parents[3]


def split_config_manager() -> None:
    path = ROOT / 'core/api/src/core/utils/database/config_manager.py'
    lines = path.read_text(encoding='utf-8').splitlines(keepends=True)
    if len(lines) <= 700:
        return
    (path.parent / 'config_manager_loaders.py').write_text(
        '"""Django/Celery loaders for database config."""\n\n'
        + ''.join(lines[:17])
        + 'from .config_manager import BaseDatabaseConfigLoader, DatabaseConnectionTester, DB_ENGINES, _get_cached_yaml\n\n'
        + ''.join(lines[354:]),
        encoding='utf-8',
    )
    path.write_text(''.join(lines[:354]), encoding='utf-8')


def split_nginx() -> None:
    ps1 = ROOT / 'core/deployment/windows/lib/nginx.ps1'
    lines = read_ps1(ps1).splitlines(keepends=True)
    if len(lines) > 700:
        write_ps1(ps1.parent / 'nginx_common.ps1', ''.join(lines[:120]))
        write_ps1(ps1, '. "$PSScriptRoot/nginx_common.ps1"\n\n' + ''.join(lines[120:]))

    sh = ROOT / 'core/deployment/linux/lib/nginx.sh'
    lines = sh.read_text(encoding='utf-8').splitlines(keepends=True)
    if len(lines) > 700:
        (sh.parent / 'nginx_common.sh').write_text(''.join(lines[:120]), encoding='utf-8')
        sh.write_text('. "$(dirname "${BASH_SOURCE[0]}")/nginx_common.sh"\n\n' + ''.join(lines[120:]), encoding='utf-8')


def split_deps_scanner() -> None:
    path = ROOT / 'core/api/src/core/utils/management/commands/deps_scanner.py'
    if not path.exists():
        return
    lines = path.read_text(encoding='utf-8').splitlines(keepends=True)
    if len(lines) <= 700:
        return
    (path.parent / 'deps_scanner_workspace.py').write_text(''.join(lines[400:]), encoding='utf-8')
    path.write_text(''.join(lines[:400]), encoding='utf-8')
    deps = ROOT / 'core/api/src/core/utils/management/commands/deps.py'
    text = deps.read_text(encoding='utf-8')
    if 'deps_scanner_workspace' not in text:
        deps.write_text(
            text.replace(
                'from .deps_scanner import *  # noqa: F403',
                'from .deps_scanner import *  # noqa: F403\nfrom .deps_scanner_workspace import *  # noqa: F403',
            ),
            encoding='utf-8',
        )


def extract_composable(vue_rel: str, composable_rel: str, fn_name: str, import_path: str) -> None:
    import re

    vue_path = ROOT / vue_rel
    text = vue_path.read_text(encoding='utf-8')
    if fn_name + '()' in text and composable_rel.split('/')[-1] in text:
        return
    start = text.index('<script setup>') + len('<script setup>')
    end = text.index('</script>')
    body = text[start:end].strip()
    import_lines = []
    code_lines = []
    for line in body.splitlines():
        if line.strip().startswith('import '):
            import_lines.append(line)
        else:
            code_lines.append(line)
    code = '\n'.join(code_lines)
    names = sorted(set(re.findall(r'(?:const|let|function)\s+(\w+)', code)))
    ret = ',\n    '.join(names)
    indented = '\n'.join(f'  {line}' if line.strip() else line for line in code.splitlines())
    js_path = ROOT / composable_rel
    js_path.parent.mkdir(parents=True, exist_ok=True)
    js_path.write_text(
        '\n'.join(import_lines)
        + f'\n\nexport function {fn_name}() {{\n{indented}\n  return {{\n    {ret},\n  }}\n}}\n',
        encoding='utf-8',
    )
    destructure = ',\n  '.join(names)
    new_script = (
        f"<script setup>\nimport {{ {fn_name} }} from '{import_path}'\n\n"
        f'const {{\n  {destructure},\n}} = {fn_name}()\n</script>'
    )
    vue_path.write_text(text[: text.index('<script setup>')] + new_script + text[end + len('</script>') :], encoding='utf-8')


def main() -> None:
    split_config_manager()
    split_nginx()
    split_deps_scanner()
    extract_composable(
        'core/client/src/core/cms/adp/admin/ImportUsers.vue',
        'core/client/src/core/cms/adp/admin/js/useImportUsers.js',
        'useImportUsers',
        './js/useImportUsers.js',
    )
    extract_composable(
        'core/client/src/core/cms/adp/settings/themeEditor/ThemeEditor.vue',
        'core/client/src/core/cms/adp/settings/themeEditor/useThemeEditor.js',
        'useThemeEditor',
        './useThemeEditor.js',
    )

    for pattern in (
        'core/api/src/core/utils/database/config_manager*.py',
        'core/deployment/windows/lib/nginx*.ps1',
        'core/deployment/linux/lib/nginx*.sh',
        'core/client/src/core/cms/adp/admin/ImportUsers.vue',
        'core/client/src/core/cms/adp/settings/themeEditor/ThemeEditor.vue',
        'core/api/src/core/utils/management/commands/deps*.py',
    ):
        for path in ROOT.glob(pattern):
            print(f'{len(path.read_text(encoding="utf-8").splitlines()):4d}  {path.relative_to(ROOT)}')


if __name__ == '__main__':
    main()
