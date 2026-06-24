"""
Создание конфигурационных файлов из example-шаблонов.

Используется setup-full (Windows/Linux, в т.ч. Ctrl+Shift+B) до создания venv.
Зависимости: только stdlib.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

_DEPLOYMENT_DIR = Path(__file__).resolve().parent.parent
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))

from config_scaffold import ConfigScaffolder, ScaffoldAction, format_scaffold_result


def _resolve_project_root(explicit: str | None) -> Path:
    if explicit:
        root = Path(explicit).resolve()
        if not root.is_dir():
            raise SystemExit(f'[ERROR] Project root does not exist: {root}')
        return root

    candidate = _DEPLOYMENT_DIR.parent.parent
    if (candidate / 'pyproject.toml').is_file():
        return candidate

    raise SystemExit('[ERROR] Cannot detect project root; pass --root')


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description='Scaffold config files from examples')
    parser.add_argument('--root', help='Project root directory')
    args = parser.parse_args(argv)

    project_root = _resolve_project_root(args.root)
    results = ConfigScaffolder(project_root).run()

    has_failure = False
    for result in results:
        print(format_scaffold_result(result))
        if result.action is ScaffoldAction.FAILED:
            has_failure = True

    return 1 if has_failure else 0


if __name__ == '__main__':
    raise SystemExit(main())
