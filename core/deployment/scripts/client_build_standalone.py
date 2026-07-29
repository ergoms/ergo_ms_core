"""ergoms client-build-standalone --module=<name>"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path


def main(argv: list[str] | None = None) -> int:
    args = list(argv if argv is not None else sys.argv[1:])
    root = Path(__file__).resolve().parents[3]
    script = root / 'core' / 'client' / 'scripts' / 'build-client-standalone.js'
    # Standalone: пустые module globs при импорте shell
    env = os.environ.copy()
    env.setdefault('CLIENT_MODULARITY', 'standalone')
    node_candidates = [
        root / 'virtual_env' / 'packages' / 'nodejs' / 'node.exe',
        root / 'virtual_env' / 'packages' / 'nodejs' / 'bin' / 'node',
        Path('node'),
    ]
    node = next((p for p in node_candidates if p == Path('node') or p.is_file()), Path('node'))
    # Сначала globs под standalone
    gen = root / 'core' / 'client' / 'scripts' / 'generate-module-globs.js'
    rc = subprocess.call([str(node), str(gen)], cwd=str(root), env=env)
    if rc != 0:
        return rc
    cmd = [str(node), str(script), *args]
    return subprocess.call(cmd, cwd=str(root), env=env)


if __name__ == '__main__':
    raise SystemExit(main())
