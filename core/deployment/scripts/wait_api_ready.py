"""Ожидание GET /api/system/ready/ перед запуском клиента или nginx."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[3]
SCRIPT = PROJECT_ROOT / 'core' / 'api' / 'scripts' / 'warmup_api_runtime.py'


def wait_for_api_ready() -> int:
    return subprocess.call([sys.executable, str(SCRIPT)], cwd=str(PROJECT_ROOT))


def main() -> int:
    return wait_for_api_ready()


if __name__ == '__main__':
    raise SystemExit(main())
