"""
CLI для TLS (Let's Encrypt): статус, обновление .env после выпуска сертификата.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[3]
DEPLOYMENT_NGINX = PROJECT_ROOT / 'core' / 'deployment' / 'nginx'
sys.path.insert(0, str(DEPLOYMENT_NGINX))

from tls_config import (  # noqa: E402
    _read_env,
    apply_tls_env,
    cert_status,
    primary_domain,
    resolve_domains,
    validate_tls_prerequisites,
    webroot_path,
)


def _env_path(root: Path) -> Path:
    return root / '.env'


def cmd_validate(args: argparse.Namespace) -> int:
    values = _read_env(_env_path(args.root))
    errors = validate_tls_prerequisites(values)
    if errors:
        for item in errors:
            print(f'[ERROR] {item}', file=sys.stderr)
        return 1
    domains = resolve_domains(values)
    print(f'[OK] Domains: {", ".join(domains)}')
    print(f'[OK] Webroot: {webroot_path(values)}')
    print(f'[OK] Email: {values.get("ERGO_TLS_EMAIL", "").strip()}')
    return 0


def cmd_apply_env(args: argparse.Namespace) -> int:
    values = _read_env(_env_path(args.root))
    domain = args.domain or primary_domain(values)
    if not domain:
        print('[ERROR] Domain not specified and not found in .env', file=sys.stderr)
        return 1
    extra = resolve_domains(values)
    extra = [item for item in extra if item != domain]
    changed = apply_tls_env(_env_path(args.root), domain, extra_domains=extra)
    if changed:
        print(f'[OK] .env updated ({len(changed)} keys): {", ".join(changed)}')
    else:
        print('[OK] .env already configured for TLS')
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    values = _read_env(_env_path(args.root))
    domains = resolve_domains(values)
    if args.domain:
        domains = [args.domain]
    if not domains:
        print('[WARN] No domain configured (NGINX_PUBLIC_HOST / ERGO_TLS_DOMAINS)')
        return 1

    payload = [cert_status(domain) for domain in domains]
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0

    for item in payload:
        print(f"Domain: {item['domain']}")
        if not item.get('exists'):
            print('  Certificate: not found')
            continue
        print(f"  Fullchain: {item['fullchain']}")
        print(f"  Privkey:   {item['privkey']}")
        if 'expires_at' in item:
            print(f"  Expires:   {item['expires_at']}")
            print(f"  Days left: {item['days_left']}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description='ERGO MS TLS utilities')
    parser.add_argument('--root', type=Path, default=PROJECT_ROOT)
    sub = parser.add_subparsers(dest='command', required=True)

    validate_parser = sub.add_parser('validate', help='Check .env before install-tls')
    validate_parser.set_defaults(func=cmd_validate)

    apply_parser = sub.add_parser('apply-env', help='Write TLS paths and URLs to .env')
    apply_parser.add_argument('--domain', default='')
    apply_parser.set_defaults(func=cmd_apply_env)

    status_parser = sub.add_parser('status', help='Show certificate status')
    status_parser.add_argument('--domain', default='')
    status_parser.add_argument('--json', action='store_true')
    status_parser.set_defaults(func=cmd_status)

    args = parser.parse_args()
    return args.func(args)


if __name__ == '__main__':
    raise SystemExit(main())
