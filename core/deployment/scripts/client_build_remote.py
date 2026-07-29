"""ergoms client-build-remote --module=<name>"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path


def main(argv: list[str] | None = None) -> int:
    args = list(argv if argv is not None else sys.argv[1:])
    root = Path(__file__).resolve().parents[3]
    script = root / 'core' / 'client' / 'scripts' / 'build-client-remote.js'
    node_candidates = [
        root / 'virtual_env' / 'packages' / 'nodejs' / 'node.exe',
        root / 'virtual_env' / 'packages' / 'nodejs' / 'bin' / 'node',
        Path('node'),
    ]
    node = next((p for p in node_candidates if p == Path('node') or p.is_file()), Path('node'))
    cmd = [str(node), str(script), *args]
    return subprocess.call(cmd, cwd=str(root))


if __name__ == '__main__':
    raise SystemExit(main())
