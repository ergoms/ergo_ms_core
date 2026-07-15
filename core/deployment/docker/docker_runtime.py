"""
Effective env и конфигурация для Docker Compose (read-only, не пишет .env / databases.yaml).

Порты — из существующих ключей .env (API_PORT, CLIENT_PORT, …).
Параметры БД — из databases.yaml; для контейнеров генерируется .compose.databases.yaml.
"""

from __future__ import annotations

import sys
from copy import deepcopy
from pathlib import Path
from typing import Any

import yaml

_DOCKER_DIR = Path(__file__).resolve().parent
_DEPLOYMENT_DIR = _DOCKER_DIR.parent
PROJECT_ROOT = _DEPLOYMENT_DIR.parent.parent

if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))

from env_resolvers import read_env_file  # noqa: E402

LOCAL_DB_HOSTS = frozenset({'localhost', '127.0.0.1', '::1', ''})
CELERY_DB_SECTIONS = ('default', 'celery', 'celery_worker', 'celery_beat')
DOCKER_DEPS_CACHE_VALUES = frozenset({'internal', 'project', 'off'})
BUILD_CACHE_OUTPUT = _DOCKER_DIR / 'docker-compose.build.generated.yml'


def _truthy(value: str | None, default: bool = False) -> bool:
    if value is None or str(value).strip() == '':
        return default
    return str(value).strip().lower() in ('1', 'true', 'yes', 'on')


def _env(raw: dict[str, str], name: str, default: str = '') -> str:
    return raw.get(name, default).strip() or default


def load_databases_config(project_root: Path | None = None) -> dict[str, Any]:
    root = project_root or PROJECT_ROOT
    path = root / 'databases.yaml'
    if not path.is_file():
        example = root / 'databases.yaml.example'
        path = example if example.is_file() else path
    if not path.is_file():
        return {}
    with open(path, encoding='utf-8') as handle:
        data = yaml.safe_load(handle) or {}
    return data.get('databases') or {}


def effective_db_host(raw_env: dict[str, str], yaml_host: str) -> str:
    mode = _env(raw_env, 'DOCKER_DATABASE', 'container').lower()
    service = _env(raw_env, 'DOCKER_SERVICE_POSTGRES', 'postgres')
    host = (yaml_host or '').strip()
    if mode == 'container' and host.lower() in LOCAL_DB_HOSTS:
        return service
    return host or 'localhost'


def build_compose_databases(project_root: Path | None, raw_env: dict[str, str]) -> dict[str, Any]:
    sections = load_databases_config(project_root)
    if not sections:
        return {}
    result = deepcopy(sections)
    for name in CELERY_DB_SECTIONS:
        section = result.get(name)
        if not isinstance(section, dict):
            continue
        section['host'] = effective_db_host(raw_env, str(section.get('host', '')))
    return result


def write_compose_databases(path: Path, databases: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {'databases': databases}
    path.write_text(
        yaml.safe_dump(payload, allow_unicode=True, default_flow_style=False, sort_keys=False),
        encoding='utf-8',
    )


def effective_docker_deps_cache(raw_env: dict[str, str]) -> str:
    mode = _env(raw_env, 'DOCKER_DEPS_CACHE', 'internal').lower()
    return mode if mode in DOCKER_DEPS_CACHE_VALUES else 'internal'


def effective_docker_build_policy(raw_env: dict[str, str]) -> str:
    policy = _env(raw_env, 'DOCKER_BUILD_POLICY', 'if-missing').lower()
    return policy if policy in ('if-missing', 'always') else 'if-missing'


def effective_docker_npm_install(raw_env: dict[str, str]) -> str:
    mode = _env(raw_env, 'DOCKER_NPM_INSTALL', 'smart').lower()
    return mode if mode in ('smart', 'always') else 'smart'


def resolve_celery_cache_bind(project_root: Path, raw_env: dict[str, str]) -> str:
    mode = _env(raw_env, 'DOCKER_VOLUME_CELERY_CACHE', 'named').lower()
    if mode == 'bind':
        cache_path = (project_root / 'virtual_env' / 'cache').resolve()
        cache_path.mkdir(parents=True, exist_ok=True)
        return str(cache_path).replace('\\', '/')
    return 'celery_cache'


def resolve_docker_cache_dir(project_root: Path) -> str:
    cache_dir = (project_root / 'virtual_env' / 'docker-cache').resolve()
    cache_dir.mkdir(parents=True, exist_ok=True)
    return str(cache_dir).replace('\\', '/')


def build_compose_build_cache_content(cache_dir: str) -> str:
    """Фрагмент compose для project-кэша BuildKit (local cache)."""
    api_cache = f'{cache_dir}/build-api'
    return f"""# Автогенерация: prepare_compose_artifacts (DOCKER_DEPS_CACHE=project)
services:
  api:
    build:
      cache_from:
        - type=local,src={api_cache}
      cache_to:
        - type=local,dest={api_cache},mode=max
"""


def write_compose_build_cache(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding='utf-8')


def remove_compose_build_cache(path: Path | None = None) -> None:
    target = path or BUILD_CACHE_OUTPUT
    if target.is_file():
        target.unlink()


def build_compose_env_overrides(raw_env: dict[str, str]) -> dict[str, str]:
    """Runtime-overrides для .compose.env (не дублирует порты — они уже в .env)."""
    overrides: dict[str, str] = {
        'DOCKER_ENABLED': 'true',
        'REDIS_ENABLED': 'true',
        'REDIS_HOST': _env(raw_env, 'DOCKER_SERVICE_REDIS', 'redis'),
    }

    service_api = _env(raw_env, 'DOCKER_SERVICE_API', 'api')
    service_media = _env(raw_env, 'DOCKER_SERVICE_MEDIA', 'media-api')

    overrides['API_HOST'] = '0.0.0.0'
    overrides['MEDIA_API_BIND_HOST'] = '0.0.0.0'
    overrides['CLIENT_HOST'] = '0.0.0.0'

    if _truthy(raw_env.get('DOCKER_PROFILE_NGINX')):
        overrides['NGINX_ENABLED'] = 'true'
        overrides['CLIENT_USE_RELATIVE_API'] = 'true'

    mode = _env(raw_env, 'DOCKER_MODE', 'dev').lower()
    if mode == 'prod':
        overrides.setdefault('API_DEPLOY_TYPE', 'production')
        overrides.setdefault('CLIENT_DEPLOY_TYPE', 'production')
        overrides.setdefault('MEDIA_API_DEPLOY_TYPE', 'production')
    else:
        overrides.setdefault('API_DEPLOY_TYPE', 'development')
        overrides.setdefault('CLIENT_DEPLOY_TYPE', 'development')
        overrides.setdefault('MEDIA_API_DEPLOY_TYPE', 'development')

    # Для healthcheck / wait — явный хост БД
    default_db = load_databases_config().get('default') or {}
    overrides['ERGO_DOCKER_DB_HOST'] = effective_db_host(raw_env, str(default_db.get('host', '')))
    overrides['ERGO_DOCKER_DB_PORT'] = str(default_db.get('port', 5432))
    overrides['ERGO_DOCKER_SERVICE_API'] = service_api
    overrides['ERGO_DOCKER_SERVICE_MEDIA'] = service_media

    media_volume = _env(raw_env, 'DOCKER_VOLUME_MEDIA', 'bind').lower()
    overrides.setdefault('MEDIA_STORAGE_PATH', '/app/media')

    overrides.setdefault('DOCKER_BUILD_CACHE', 'true' if _truthy(raw_env.get('DOCKER_BUILD_CACHE'), default=True) else 'false')
    deps_cache = effective_docker_deps_cache(raw_env)
    if not _truthy(raw_env.get('DOCKER_BUILD_CACHE'), default=True):
        deps_cache = 'off'
    overrides.setdefault('DOCKER_DEPS_CACHE', deps_cache)
    overrides.setdefault('DOCKER_BUILD_POLICY', effective_docker_build_policy(raw_env))
    overrides.setdefault('DOCKER_NPM_INSTALL', effective_docker_npm_install(raw_env))
    overrides.setdefault('ERGO_DOCKER_LOG_DIR', '/app/logs/docker')
    overrides.setdefault('ERGO_DOCKER_SETUP_MARKER', '/app/logs/.ergo-docker-setup-ok')

    return overrides


def merge_env_files(project_root: Path, raw_env: dict[str, str]) -> dict[str, str]:
    merged = dict(raw_env)
    merged.update(build_compose_env_overrides(raw_env))
    return merged


def write_compose_env(path: Path, values: dict[str, str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [f'{key}={value}' for key, value in sorted(values.items())]
    path.write_text('\n'.join(lines) + '\n', encoding='utf-8')


def docker_mode(raw_env: dict[str, str]) -> str:
    mode = _env(raw_env, 'DOCKER_MODE', 'dev').lower()
    return mode if mode in ('dev', 'prod') else 'dev'


def compose_profiles(raw_env: dict[str, str]) -> list[str]:
    profiles: list[str] = []
    if _truthy(raw_env.get('DOCKER_PROFILE_NGINX')):
        profiles.append('nginx')
    if _truthy(raw_env.get('DOCKER_PROFILE_JUPYTER')):
        profiles.append('jupyter')
    db_mode = _env(raw_env, 'DOCKER_DATABASE', 'container').lower()
    profile_postgres = raw_env.get('DOCKER_PROFILE_POSTGRES', '')
    if db_mode == 'container' and _truthy(profile_postgres, default=True):
        profiles.append('postgres')
    return profiles


def postgres_container_env(raw_env: dict[str, str]) -> dict[str, str]:
    default_db = load_databases_config().get('default') or {}
    return {
        'POSTGRES_USER': str(default_db.get('user', 'postgres')),
        'POSTGRES_PASSWORD': str(default_db.get('password', 'admin')),
        'POSTGRES_DB': str(default_db.get('name', 'ergo_ms')),
        'POSTGRES_PUBLISH_PORT': postgres_publish_port(raw_env),
    }


def postgres_publish_port(raw_env: dict[str, str]) -> str:
    default_db = load_databases_config().get('default') or {}
    return str(default_db.get('port', 5432))


def generate_celery_init_sql(project_root: Path | None = None) -> str:
    """SQL для init postgres: дополнительные БД Celery из databases.yaml."""
    sections = load_databases_config(project_root)
    lines: list[str] = []
    seen: set[tuple[str, str]] = set()
    for name in ('celery', 'celery_worker', 'celery_beat'):
        section = sections.get(name)
        if not isinstance(section, dict):
            continue
        db_name = str(section.get('name', '')).strip()
        db_user = str(section.get('user', '')).strip()
        db_pass = str(section.get('password', '')).strip()
        if not db_name or not db_user or not db_pass:
            continue
        key = (db_user, db_name)
        if key in seen:
            continue
        seen.add(key)
        lines.append(f"DO $$ BEGIN CREATE USER {db_user} WITH PASSWORD '{db_pass}'; EXCEPTION WHEN duplicate_object THEN NULL; END $$;")
        lines.append(
            f"DO $$ BEGIN CREATE DATABASE {db_name} OWNER {db_user}; EXCEPTION WHEN duplicate_database THEN NULL; END $$;"
        )
        lines.append(f'GRANT ALL PRIVILEGES ON DATABASE {db_name} TO {db_user};')
    return '\n'.join(lines) + ('\n' if lines else '')


def write_celery_init_sql(path: Path, project_root: Path | None = None) -> None:
    content = generate_celery_init_sql(project_root)
    if not content.strip():
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding='utf-8')


def resolve_volume_binds(project_root: Path, raw_env: dict[str, str]) -> dict[str, str]:
    logs_mode = _env(raw_env, 'DOCKER_VOLUME_LOGS', 'bind').lower()
    media_mode = _env(raw_env, 'DOCKER_VOLUME_MEDIA', 'bind').lower()
    binds: dict[str, str] = {
        'ERGO_PROJECT_ROOT': str(project_root.resolve()).replace('\\', '/'),
        'ERGO_CELERY_CACHE_BIND': resolve_celery_cache_bind(project_root, raw_env),
    }
    if logs_mode == 'bind':
        logs_dir = (project_root / 'logs').resolve()
        logs_dir.mkdir(parents=True, exist_ok=True)
        (logs_dir / 'docker').mkdir(parents=True, exist_ok=True)
        binds['ERGO_LOGS_BIND'] = str(logs_dir).replace('\\', '/')
    else:
        binds['ERGO_LOGS_BIND'] = 'ergo_logs'
    if media_mode == 'bind':
        binds['ERGO_MEDIA_BIND'] = str((project_root / 'media').resolve()).replace('\\', '/')
    else:
        binds['ERGO_MEDIA_BIND'] = 'ergo_media'
    return binds


def prepare_compose_artifacts(project_root: Path | None = None) -> dict[str, Path]:
    root = (project_root or PROJECT_ROOT).resolve()
    raw = read_env_file(root / '.env')
    compose_env_path = _DOCKER_DIR / '.compose.env'
    compose_db_path = _DOCKER_DIR / '.compose.databases.yaml'

    merged = merge_env_files(root, raw)
    merged.update(postgres_container_env(raw))
    binds = resolve_volume_binds(root, raw)
    merged.update(binds)
    write_compose_env(compose_env_path, merged)

    databases = build_compose_databases(root, raw)
    if databases:
        write_compose_databases(compose_db_path, databases)

    celery_sql = _DOCKER_DIR / 'init' / 'postgres' / '02-celery-databases.sql'
    write_celery_init_sql(celery_sql, root)

    if effective_docker_deps_cache(raw) == 'project':
        cache_dir = resolve_docker_cache_dir(root)
        write_compose_build_cache(
            BUILD_CACHE_OUTPUT,
            build_compose_build_cache_content(cache_dir),
        )
    else:
        remove_compose_build_cache(BUILD_CACHE_OUTPUT)

    return {
        'compose_env': compose_env_path,
        'compose_databases': compose_db_path,
        'celery_init_sql': celery_sql,
        'compose_build_cache': BUILD_CACHE_OUTPUT if BUILD_CACHE_OUTPUT.is_file() else None,
    }
