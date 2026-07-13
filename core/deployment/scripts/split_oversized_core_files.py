#!/usr/bin/env python3
"""Разбивает файлы ядра >700 строк (code.mdc)."""
from __future__ import annotations

import sys
from pathlib import Path

_SCRIPTS_DIR = Path(__file__).resolve().parent
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

from ps1_io import read_ps1, write_ps1

ROOT = Path(__file__).resolve().parents[3]
API_CMD = ROOT / 'core' / 'api' / 'src' / 'core' / 'utils' / 'management' / 'commands'


def split_deps() -> None:
    deps_path = API_CMD / 'deps.py'
    lines = deps_path.read_text(encoding='utf-8').splitlines(keepends=True)
    (API_CMD / 'deps_scanner.py').write_text(''.join(lines[:796]), encoding='utf-8')
    cmd = (
        '"""Management command: scan Python dependencies."""\n\n'
        'from django.core.management.base import BaseCommand\n\n'
        'from .deps_scanner import *  # noqa: F403\n\n'
        + ''.join(lines[796:])
    )
    deps_path.write_text(cmd, encoding='utf-8')


def split_safe_drop() -> None:
    src = API_CMD / 'safe_drop_app.py'
    lines = src.read_text(encoding='utf-8').splitlines(keepends=True)
    imports = ''.join(lines[:18])
    class_tail = ''.join(lines[20:600])
    deletion = ''.join(lines[600:])

    analysis = (
        imports
        + '\nclass SafeDropAppAnalysisMixin:\n'
        + class_tail
    )
    (API_CMD / 'safe_drop_app_analysis.py').write_text(analysis, encoding='utf-8')

    deletion_mixin = (
        imports
        + '\nclass SafeDropAppDeletionMixin:\n'
        + deletion.replace('    def _perform_deletion', '    def _perform_deletion', 1)
    )
    (API_CMD / 'safe_drop_app_deletion.py').write_text(deletion_mixin, encoding='utf-8')

    cmd = (
        '"""Команда для безопасного удаления приложения Django."""\n\n'
        'from django.core.management.base import BaseCommand\n\n'
        'from .safe_drop_app_analysis import SafeDropAppAnalysisMixin\n'
        'from .safe_drop_app_deletion import SafeDropAppDeletionMixin\n\n\n'
        'class Command(SafeDropAppDeletionMixin, SafeDropAppAnalysisMixin, BaseCommand):\n'
        '    help = SafeDropAppAnalysisMixin.help\n'
    )
    src.write_text(cmd, encoding='utf-8')


def extract_vue_styles(vue_path: Path, scss_name: str) -> None:
    text = vue_path.read_text(encoding='utf-8')
    marker = '<style scoped lang="scss">'
    idx = text.find(marker)
    if idx == -1:
        return
    end = text.find('</style>', idx)
    if end == -1:
        return
    styles = text[idx + len(marker):end].strip()
    scss_path = vue_path.parent / scss_name
    scss_path.write_text(styles + '\n', encoding='utf-8')
    replacement = f'<style scoped lang="scss">\n@import "./{scss_name}";\n</style>'
    new_text = text[:idx] + replacement + text[end + len('</style>'):]

    global_marker = '<style lang="scss">'
    gidx = new_text.find(global_marker)
    if gidx != -1:
        gend = new_text.find('</style>', gidx)
        if gend != -1:
            global_scss = scss_name.replace('.scoped.', '.global.')
            gstyles = new_text[gidx + len(global_marker):gend].strip()
            (vue_path.parent / global_scss).write_text(gstyles + '\n', encoding='utf-8')
            greplacement = f'<style lang="scss">\n@import "./{global_scss}";\n</style>'
            new_text = new_text[:gidx] + greplacement + new_text[gend + len('</style>'):]

    vue_path.write_text(new_text, encoding='utf-8')


def split_config_manager() -> None:
    path = ROOT / 'core/api/src/core/utils/database/config_manager.py'
    lines = path.read_text(encoding='utf-8').splitlines(keepends=True)
    (path.parent / 'config_manager_loaders.py').write_text(
        '"""Django/Celery loaders for database config."""\n\n'
        + ''.join(lines[:17])
        + 'from .config_manager import (\n'
        '    BaseDatabaseConfigLoader,\n'
        '    DatabaseConnectionTester,\n'
        '    DB_ENGINES,\n'
        '    _get_cached_yaml,\n'
        ')\n\n'
        + ''.join(lines[354:]),
        encoding='utf-8',
    )
    path.write_text(''.join(lines[:354]), encoding='utf-8')


def split_nginx_ps1() -> None:
    path = ROOT / 'core/deployment/windows/lib/nginx.ps1'
    lines = read_ps1(path).splitlines(keepends=True)
    common = ''.join(lines[:120])
    write_ps1(path.parent / 'nginx_common.ps1', common)
    rest = '. "$PSScriptRoot/nginx_common.ps1"\n\n' + ''.join(lines[120:])
    write_ps1(path, rest)


def split_nginx_sh() -> None:
    path = ROOT / 'core/deployment/linux/lib/nginx.sh'
    lines = path.read_text(encoding='utf-8').splitlines(keepends=True)
    common = ''.join(lines[:120])
    (path.parent / 'nginx_common.sh').write_text(common, encoding='utf-8')
    rest = '. "$(dirname "${BASH_SOURCE[0]}")/nginx_common.sh"\n\n' + ''.join(lines[120:])
    path.write_text(rest, encoding='utf-8')


def split_deps_scanner() -> None:
    path = API_CMD / 'deps_scanner.py'
    if not path.exists():
        return
    lines = path.read_text(encoding='utf-8').splitlines(keepends=True)
    if len(lines) <= 700:
        return
    mid = 400
    (API_CMD / 'deps_scanner_workspace.py').write_text(''.join(lines[mid:]), encoding='utf-8')
    path.write_text(''.join(lines[:mid]), encoding='utf-8')
    deps_cmd = API_CMD / 'deps.py'
    text = deps_cmd.read_text(encoding='utf-8')
    if 'deps_scanner_workspace' not in text:
        deps_cmd.write_text(
            text.replace(
                'from .deps_scanner import *  # noqa: F403',
                'from .deps_scanner import *  # noqa: F403\nfrom .deps_scanner_workspace import *  # noqa: F403',
            ),
            encoding='utf-8',
        )


def extract_composable(vue_rel: str, composable_rel: str, fn_name: str) -> None:
    import re

    vue_path = ROOT / vue_rel
    text = vue_path.read_text(encoding='utf-8')
    start = text.index('<script setup>') + len('<script setup>')
    end = text.index('</script>')
    body = text[start:end].strip()
    import_lines = []
    code_lines = []
    for line in body.splitlines():
        stripped = line.strip()
        if stripped.startswith('import ') or stripped.startswith('export '):
            import_lines.append(line)
        else:
            code_lines.append(line)
    code = '\n'.join(code_lines)
    names = sorted(set(re.findall(r'(?:const|let|function)\s+(\w+)', code)))
    ret = ',\n    '.join(names)
    indented = '\n'.join(f'  {line}' if line.strip() else line for line in code.splitlines())
    js_path = ROOT / composable_rel
    js_path.parent.mkdir(parents=True, exist_ok=True)
    import_suffix = composable_rel.replace('\\', '/').split('admin/')[-1]
    if 'themeEditor' in composable_rel:
        import_path = './useThemeEditor.js'
    else:
        import_path = './js/useImportUsers.js'
    js_path.write_text(
        '\n'.join(import_lines)
        + f'\n\nexport function {fn_name}() {{\n{indented}\n  return {{\n    {ret},\n  }}\n}}\n',
        encoding='utf-8',
    )
    new_script = (
        f'<script setup>\nimport {{ {fn_name} }} from \'{import_path}\'\n\n'
        f'const {{\n  {ret.replace(", ", ",\n  ")},\n}} = {fn_name}()\n</script>'
    )
    vue_path.write_text(text[: text.index('<script setup>')] + new_script + text[end + len('</script>') :], encoding='utf-8')


def main() -> None:
    split_deps()
    split_deps_scanner()
    split_safe_drop()
    split_config_manager()
    split_nginx_ps1()
    split_nginx_sh()

    client = ROOT / 'core' / 'client' / 'src'
    extract_vue_styles(client / 'components' / 'SelectBox.vue', 'SelectBox.scoped.scss')
    extract_vue_styles(client / 'components' / 'menu' / 'MenuList.vue', 'MenuList.scoped.scss')
    extract_vue_styles(
        client / 'core/cms/adp/admin/InvitationsComponents/InvitationBulkModal.vue',
        'InvitationBulkModal.scoped.scss',
    )

    extract_composable(
        'core/client/src/core/cms/adp/admin/ImportUsers.vue',
        'core/client/src/core/cms/adp/admin/js/useImportUsers.js',
        'useImportUsers',
    )
    extract_composable(
        'core/client/src/core/cms/adp/settings/themeEditor/ThemeEditor.vue',
        'core/client/src/core/cms/adp/settings/themeEditor/useThemeEditor.js',
        'useThemeEditor',
    )

    for path in [
        API_CMD / 'deps.py',
        API_CMD / 'deps_scanner.py',
        API_CMD / 'safe_drop_app.py',
        API_CMD / 'safe_drop_app_analysis.py',
        API_CMD / 'safe_drop_app_deletion.py',
        client / 'components' / 'SelectBox.vue',
        client / 'components' / 'menu' / 'MenuList.vue',
    ]:
        if path.exists():
            count = len(path.read_text(encoding='utf-8').splitlines())
            print(f'{count:4d}  {path.relative_to(ROOT)}')


if __name__ == '__main__':
    main()
