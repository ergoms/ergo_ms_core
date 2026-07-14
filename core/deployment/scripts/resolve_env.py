"""
Вычисляет effective env для deployment-скриптов. Не изменяет .env.

ergoms install-nginx и install-tls используют вывод для подстановки в конфиг nginx.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

_DEPLOYMENT_DIR = Path(__file__).resolve().parent.parent
PROJECT_ROOT = _DEPLOYMENT_DIR.parent.parent
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))

from env_resolvers import read_env_file, resolve_jupyter_deployment_vars, resolve_nginx_vars  # noqa: E402


def main() -> int:
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')

    parser = argparse.ArgumentParser(description='Resolve effective env (read-only)')
    parser.add_argument('--root', type=Path, default=PROJECT_ROOT)
    parser.add_argument('--scope', choices=('nginx', 'jupyter'), default='nginx')
    parser.add_argument('--json', action='store_true', help='JSON object')
    args = parser.parse_args()

    raw = read_env_file(args.root / '.env')
    if args.scope == 'nginx':
        resolved = resolve_nginx_vars(raw)
    elif args.scope == 'jupyter':
        resolved = resolve_jupyter_deployment_vars(raw)
    else:
        resolved = {}

    if args.json:
        print(json.dumps(resolved, ensure_ascii=False))
    else:
        for key, value in resolved.items():
            print(f'{key}={value}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
