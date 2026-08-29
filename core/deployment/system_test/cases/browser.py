"""Playwright: логин и ключевые экраны ядра."""

from __future__ import annotations

import json
import os
import subprocess

from project_layout import cache_playwright_dir, ensure_dir, npm_root_dir

from ..environment import IsolatedEnvironment, venv_python
from ..report import CaseResult
from .base import SystemCase


class BrowserCoreCase(SystemCase):
    name = 'browser_core'
    domain = 'browser'

    def run(self, env: IsolatedEnvironment) -> CaseResult:
        npm_root = npm_root_dir(env.workspace)
        config = env.workspace / 'core' / 'client' / 'e2e' / 'playwright.config.js'
        if not config.is_file():
            return CaseResult(self.name, self.domain, 'skip', 'нет playwright.config.js')
        creds = _provision_password(env)
        if creds is None:
            return CaseResult(self.name, self.domain, 'skip', 'не удалось создать пользователя')
        start_client = getattr(env, 'start_client', None)
        if callable(start_client):
            start_client()
        browsers = ensure_dir(cache_playwright_dir(env.workspace))
        run_env = os.environ.copy()
        run_env['ERGO_E2E_BASE_URL'] = env.client_base()
        run_env['ERGO_E2E_USER'] = creds['username']
        run_env['ERGO_E2E_PASSWORD'] = creds['password']
        run_env['PLAYWRIGHT_BROWSERS_PATH'] = str(browsers)
        subprocess.run(
            ['npx', 'playwright', 'install', 'chromium'],
            cwd=str(npm_root),
            capture_output=True,
            text=True,
            encoding='utf-8',
            errors='replace',
            check=False,
            timeout=600,
            env=run_env,
        )
        result = subprocess.run(
            ['npx', 'playwright', 'test', '-c', str(config)],
            cwd=str(npm_root),
            capture_output=True,
            text=True,
            encoding='utf-8',
            errors='replace',
            check=False,
            timeout=1800,
            env=run_env,
        )
        if result.returncode != 0:
            tail = ((result.stderr or '') + '\n' + (result.stdout or ''))[-1500:]
            lowered = tail.lower()
            if 'playwright' in lowered and ('not found' in lowered or 'не найден' in lowered):
                return CaseResult(self.name, self.domain, 'skip', 'Playwright не установлен')
            return CaseResult(self.name, self.domain, 'fail', tail)
        return CaseResult(self.name, self.domain, 'ok', 'login/home/user')


def _provision_password(env: IsolatedEnvironment) -> dict[str, str] | None:
    root = env.tree_root if env.tree_root.is_dir() else env.workspace
    python = venv_python(root)
    if not python.is_file():
        return None
    out = env.run_dir / 'e2e-user.json'
    try:
        from loadtest.provision import provision_users

        payload = provision_users(root, count=1, out_path=out)
        user = (payload.get('users') or [None])[0]
    except Exception:
        return _provision_via_subprocess(root, python, out)
    if not isinstance(user, dict):
        return None
    password = user.get('password')
    username = user.get('username')
    if not password or not username:
        return None
    return {'username': str(username), 'password': str(password)}


def _provision_via_subprocess(
    root,
    python,
    out,
) -> dict[str, str] | None:
    code = (
        'import json,sys; from pathlib import Path; '
        'sys.path.insert(0, str(Path(r"{root}") / "core" / "deployment")); '
        'from loadtest.provision import provision_users; '
        'payload = provision_users(Path(r"{root}"), count=1, out_path=Path(r"{out}")); '
        'print(json.dumps(payload["users"][0]))'
    ).format(root=str(root), out=str(out))
    result = subprocess.run(
        [str(python), '-c', code],
        cwd=str(root / 'core' / 'api'),
        capture_output=True,
        text=True,
        encoding='utf-8',
        errors='replace',
        check=False,
        timeout=180,
    )
    if result.returncode != 0:
        return None
    try:
        user = json.loads(result.stdout.strip().splitlines()[-1])
    except (json.JSONDecodeError, IndexError):
        return None
    password = user.get('password')
    username = user.get('username')
    if not password or not username:
        return None
    return {'username': str(username), 'password': str(password)}
