"""
CLI для TLS (Let's Encrypt): статус и рекомендуемые переменные после выпуска сертификата.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[3]
DEPLOYMENT_DIR = PROJECT_ROOT / 'core' / 'deployment'
DEPLOYMENT_NGINX = DEPLOYMENT_DIR / 'nginx'
sys.path.insert(0, str(DEPLOYMENT_DIR))
sys.path.insert(0, str(DEPLOYMENT_NGINX))

from env_file_loader import load_project_env  # noqa: E402
from tls_config import (  # noqa: E402
    cert_status,
    primary_domain,
    resolve_domains,
    suggest_tls_env_vars,
    validate_tls_prerequisites,
    webroot_path,
)


def cmd_validate(args: argparse.Namespace) -> int:
    values = load_project_env(args.root)
    errors = validate_tls_prerequisites(values)
    if errors:
        for item in errors:
            print(f'[ERROR] {item}', file=sys.stderr)
        return 1
    domains = resolve_domains(values)
    print(f'[OK] Домены: {", ".join(domains)}')
    print(f'[OK] Webroot: {webroot_path(values, root=args.root)}')
    print(f'[OK] Email: {values.get("ERGO_TLS_EMAIL", "").strip()}')
    return 0


def cmd_suggest_env(args: argparse.Namespace) -> int:
    values = load_project_env(args.root)
    domain = args.domain or primary_domain(values)
    if not domain:
        print('[ERROR] Домен не указан и не найден в .env / env/nginx.env', file=sys.stderr)
        return 1
    extra = resolve_domains(values)
    extra = [item for item in extra if item != domain]
    suggestions = suggest_tls_env_vars(values, domain, extra_domains=extra)

    if args.json:
        print(json.dumps(suggestions, ensure_ascii=False, indent=2))
        return 0

    print('Рекомендуемые переменные для env/nginx.env после install-tls:')
    for key, value in suggestions.items():
        current = values.get(key, '').strip()
        marker = '  ' if current == value else ' *'
        print(f'{marker}{key}={value}')
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    values = load_project_env(args.root)
    domains = resolve_domains(values)
    if args.domain:
        domains = [args.domain]
    if not domains:
        print('[WARNING] No domain configured (NGINX_PUBLIC_HOST / ERGO_TLS_DOMAINS)')
        return 1

    payload = [cert_status(domain, root=args.root) for domain in domains]
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0

    for item in payload:
        print(f"Domain: {item['domain']}")
        if not item.get('exists'):
            print('  Certificate: не найден')
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
    sub = parser.add_subparsers(dest='команда', required=True)

    validate_parser = sub.add_parser('validate', help='Check .env before install-tls')
    validate_parser.set_defaults(func=cmd_validate)

    suggest_parser = sub.add_parser('suggest-env', help='Print recommended TLS-related .env variables')
    suggest_parser.add_argument('--domain', default='')
    suggest_parser.add_argument('--json', action='store_true')
    suggest_parser.set_defaults(func=cmd_suggest_env)

    status_parser = sub.add_parser('status', help='Show certificate status')
    status_parser.add_argument('--domain', default='')
    status_parser.add_argument('--json', action='store_true')
    status_parser.set_defaults(func=cmd_status)

    args = parser.parse_args()
    return args.func(args)


if __name__ == '__main__':
    raise SystemExit(main())
