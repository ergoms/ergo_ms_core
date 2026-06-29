"""
Рендер nginx-шаблонов ERGO MS с подстановкой host policy и прочих переменных.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[3]
DEPLOYMENT_NGINX = PROJECT_ROOT / 'core' / 'deployment' / 'nginx'
sys.path.insert(0, str(DEPLOYMENT_NGINX))

from host_policy import compute_template_vars  # noqa: E402


def _read_env(path: Path) -> dict[str, str]:
    if not path.is_file():
        return {}
    result: dict[str, str] = {}
    for line in path.read_text(encoding='utf-8').splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith('#') or '=' not in stripped:
            continue
        key, _, raw = stripped.partition('=')
        result[key.strip()] = raw.strip().strip('"').strip("'")
    return result


def _truthy(value: str) -> bool:
    return value.strip().lower() in ('1', 'true', 'yes')


def _use_https(values: dict[str, str], listen_port: str) -> bool:
    if _truthy(values.get('NGINX_USE_HTTPS', '')):
        return True
    return listen_port == '443'


def render_template(
    template_path: Path,
    *,
    root: Path,
    server_name: str,
    listen_host: str,
    listen_port: str,
    use_https: bool,
    ssl_cert: str = '',
    ssl_key: str = '',
) -> str:
    values = _read_env(root / '.env')
    snippets_dir = root / 'core' / 'deployment' / 'nginx' / 'snippets'
    root_forward = str(root).replace('\\', '/')
    snippets_forward = str(snippets_dir).replace('\\', '/')

    extra = compute_template_vars(
        values,
        listen_host=listen_host,
        listen_port=listen_port,
        use_https=use_https,
    )

    content = template_path.read_text(encoding='utf-8')
    replacements = {
        '${ERGO_ROOT}': root_forward,
        '${ERGO_SERVER_NAME}': server_name,
        '${ERGO_LISTEN_HOST}': listen_host,
        '${ERGO_LISTEN_PORT}': listen_port,
        '${ERGO_NGINX_SNIPPETS}': snippets_forward,
        '${ERGO_SSL_CERT}': ssl_cert.replace('\\', '/'),
        '${ERGO_SSL_KEY}': ssl_key.replace('\\', '/'),
        '${ERGO_HOST_POLICY_BLOCKS}': extra['ERGO_HOST_POLICY_BLOCKS'],
        '${ERGO_HTTP_CANONICAL_REDIRECT}': extra['ERGO_HTTP_CANONICAL_REDIRECT'],
    }
    for needle, value in replacements.items():
        content = content.replace(needle, value)
    return content


def main() -> int:
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')

    parser = argparse.ArgumentParser()
    parser.add_argument('--template', type=Path, required=True)
    parser.add_argument('--root', type=Path, default=PROJECT_ROOT)
    parser.add_argument('--server-name', default='localhost')
    parser.add_argument('--listen-host', default='0.0.0.0')
    parser.add_argument('--listen-port', default='80')
    parser.add_argument('--use-https', choices=('true', 'false'), default='false')
    parser.add_argument('--ssl-cert', default='')
    parser.add_argument('--ssl-key', default='')
    args = parser.parse_args()

    rendered = render_template(
        args.template,
        root=args.root,
        server_name=args.server_name,
        listen_host=args.listen_host,
        listen_port=args.listen_port,
        use_https=args.use_https == 'true',
        ssl_cert=args.ssl_cert,
        ssl_key=args.ssl_key,
    )
    sys.stdout.write(rendered)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
