"""Shared path bootstrap for lifecycle service backends."""

from __future__ import annotations

import sys
from pathlib import Path

_DEPLOYMENT_DIR = Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = _DEPLOYMENT_DIR / 'scripts'
for path in (_DEPLOYMENT_DIR, _SCRIPTS_DIR):
    path_str = str(path)
    if path_str not in sys.path:
        sys.path.insert(0, path_str)
