"""Обновляет форки: переносит ветку на исходный репозиторий и отправляет её только в форк.

Коммит слияния в пулл-реквест не попадает, потому что свои коммиты переигрываются
поверх свежей ветки источника. В исходный репозиторий команда не отправляет ничего.
Пара remotes: upstream — источник и origin — форк, либо origin — источник и fork — форк.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import uuid
from pathlib import Path


def _force_utf8_stdio() -> None:
    for name in ('stdout', 'stderr'):
        stream = getattr(sys, name)
        reconfigure = getattr(stream, 'reconfigure', None)
        if not callable(reconfigure):
            continue
        try:
            reconfigure(encoding='utf-8', errors='replace')
        except (OSError, ValueError):
            pass


_force_utf8_stdio()

_DEPLOYMENT = Path(__file__).resolve().parents[1]
if str(_DEPLOYMENT) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT))

from cli_locale import t  # noqa: E402
from console_tags import format_console  # noqa: E402

_BRANCH_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$')
_STASH_PREFIX = 'ergoms-sync-forks'
_FETCH_TIMEOUT = 180
_GIT_TIMEOUT = 120


class GitResult:
    def __init__(self, code: int, out: str, err: str) -> None:
        self.code = code
        self.out = out
        self.err = err


class ForkLayout:
    def __init__(self, source: str, fork: str) -> None:
        self.source = source
        self.fork = fork


def _root() -> Path:
    return Path(__file__).resolve().parents[3]


def _say(level: str, key: str, **params: str) -> None:
    print(format_console(level, t(key, **params)))


def _git_env() -> dict[str, str]:
    env = os.environ.copy()
    env['GIT_TERMINAL_PROMPT'] = '0'
    env['GCM_INTERACTIVE'] = 'Never'
    return env


def git(repo: Path, *args: str, timeout: int = _GIT_TIMEOUT) -> GitResult:
    try:
        completed = subprocess.run(
            ['git', '-C', str(repo), *args],
            capture_output=True,
            text=True,
            encoding='utf-8',
            errors='replace',
            env=_git_env(),
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return GitResult(124, '', 'timeout')
    return GitResult(completed.returncode, completed.stdout or '', completed.stderr or '')


def valid_branch(name: str) -> bool:
    if not _BRANCH_RE.fullmatch(name):
        return False
    if '..' in name or '@{' in name or name.endswith('/') or name.endswith('.lock'):
        return False
    return True


def normalize_remote_url(url: str) -> str:
    value = url.strip().rstrip('/')
    if value.endswith('.git'):
        value = value[:-4]
    if value.startswith('git@'):
        host_path = value[4:]
        host, _, path = host_path.partition(':')
        value = f'https://{host}/{path}'
    return value.lower()


def classify_remotes(remotes: dict[str, str]) -> ForkLayout | None:
    """Источник и форк по именам remote. В upstream команда не пушит."""
    origin = remotes.get('origin', '')
    upstream = remotes.get('upstream', '')
    fork = remotes.get('fork', '')
    if upstream and fork and normalize_remote_url(upstream) != normalize_remote_url(fork):
        return ForkLayout('upstream', 'fork')
    if upstream and origin and normalize_remote_url(upstream) != normalize_remote_url(origin):
        return ForkLayout('upstream', 'origin')
    if fork and origin and normalize_remote_url(fork) != normalize_remote_url(origin):
        return ForkLayout('origin', 'fork')
    return None


def discover_repos(root: Path) -> list[Path]:
    repos = [root] if (root / '.git').exists() else []
    for base_name in ('core', 'modules'):
        base = root / base_name
        if not base.is_dir():
            continue
        for child in sorted(base.iterdir(), key=lambda item: item.name.lower()):
            if child.is_dir() and (child / '.git').exists():
                repos.append(child)
    return repos


def repo_label(root: Path, repo: Path) -> str:
    if repo.resolve() == root.resolve():
        return '.'
    return repo.resolve().relative_to(root.resolve()).as_posix()


def _rev(repo: Path, ref: str) -> str | None:
    result = git(repo, 'rev-parse', '--verify', '--quiet', ref)
    if result.code != 0:
        return None
    sha = result.out.strip()
    return sha or None


def _is_ancestor(repo: Path, ancestor: str, descendant: str) -> bool:
    return git(repo, 'merge-base', '--is-ancestor', ancestor, descendant).code == 0


def _has_merges(repo: Path, base: str, head: str) -> bool:
    result = git(repo, 'rev-list', '--merges', f'{base}..{head}')
    return bool(result.out.strip())


def _remote_urls(repo: Path) -> dict[str, str]:
    result = git(repo, 'remote', '-v')
    urls: dict[str, str] = {}
    for line in result.out.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        name, url = parts[0], parts[1]
        urls.setdefault(name, url)
    return urls


def _current_branch(repo: Path) -> str:
    return git(repo, 'branch', '--show-current').out.strip()


def _rebase_in_progress(repo: Path) -> bool:
    result = git(repo, 'rev-parse', '--absolute-git-dir')
    if result.code != 0:
        return False
    git_dir = Path(result.out.strip())
    return (git_dir / 'rebase-merge').exists() or (git_dir / 'rebase-apply').exists()


def _abort_rebase(repo: Path) -> None:
    if _rebase_in_progress(repo):
        git(repo, 'rebase', '--abort')


def _dirty(repo: Path) -> bool:
    result = git(repo, 'status', '--porcelain', '--untracked-files=normal')
    return bool(result.out.strip())


def _stash(repo: Path) -> str | None:
    if not _dirty(repo):
        return None
    token = f'{_STASH_PREFIX}-{uuid.uuid4().hex}'
    result = git(repo, 'stash', 'push', '--include-untracked', '-m', token)
    if result.code == 0:
        return token
    combined = f'{result.out}\n{result.err}'
    if 'No local changes' in combined:
        return None
    return ''


def _stash_ref(repo: Path, token: str) -> str | None:
    result = git(repo, 'stash', 'list', '--format=%gd %s')
    for line in result.out.splitlines():
        if token in line:
            ref = line.split(' ', 1)[0]
            if ref.startswith('stash@'):
                return ref
    return None


def _stash_pop(repo: Path, token: str) -> bool:
    ref = _stash_ref(repo, token)
    if ref is None:
        return False
    return git(repo, 'stash', 'pop', ref).code == 0


def _checkout(repo: Path, branch: str) -> bool:
    # Имя уже проверено и не начинается с «-», поэтому это ветка, а не путь.
    return git(repo, 'switch', branch).code == 0


def _checkout_new(repo: Path, branch: str, start: str) -> bool:
    # --no-track не меняет branch.<name>.remote в .git/config.
    return git(repo, 'checkout', '--no-track', '-b', branch, start).code == 0


def _fetch_branch(repo: Path, remote: str, branch: str) -> str:
    """ok, missing или error."""
    result = git(
        repo,
        'fetch',
        remote,
        f'+refs/heads/{branch}:refs/remotes/{remote}/{branch}',
        timeout=_FETCH_TIMEOUT,
    )
    if result.code == 0:
        return 'ok'
    text = f'{result.out}\n{result.err}'.lower()
    if "couldn't find remote ref" in text or 'could not find remote ref' in text:
        return 'missing'
    return 'error'


def _sync_branch(
    repo: Path,
    layout: ForkLayout,
    branch: str,
    *,
    push: bool,
) -> tuple[str, str]:
    """Возвращает (status, message_key). status: updated, current, failed."""
    source_state = _fetch_branch(repo, layout.source, branch)
    if source_state == 'missing':
        return 'failed', 'sync_forks_missing_branch'
    if source_state != 'ok':
        return 'failed', 'sync_forks_fetch_source_failed'
    source_sha = _rev(repo, f'refs/remotes/{layout.source}/{branch}')
    if source_sha is None:
        return 'failed', 'sync_forks_missing_branch'

    fork_state = _fetch_branch(repo, layout.fork, branch)
    if fork_state == 'error':
        return 'failed', 'sync_forks_fetch_fork_failed'
    fork_sha = _rev(repo, f'refs/remotes/{layout.fork}/{branch}') if fork_state == 'ok' else None

    local_sha = _rev(repo, f'refs/heads/{branch}')
    if local_sha is None:
        start = f'refs/remotes/{layout.fork}/{branch}' if fork_sha else source_sha
        if not _checkout_new(repo, branch, start):
            return 'failed', 'sync_forks_checkout_failed'
        local_sha = _rev(repo, 'HEAD')
    elif not _checkout(repo, branch):
        return 'failed', 'sync_forks_checkout_failed'

    if local_sha and fork_sha and local_sha != fork_sha:
        local_under_fork = _is_ancestor(repo, local_sha, fork_sha)
        fork_under_local = _is_ancestor(repo, fork_sha, local_sha)
        if not local_under_fork and not fork_under_local:
            return 'failed', 'sync_forks_diverged'
        if local_under_fork and git(repo, 'merge', '--ff-only', fork_sha).code != 0:
            return 'failed', 'sync_forks_fork_ff_failed'

    head = _rev(repo, 'HEAD')
    if head is None or source_sha is None:
        return 'failed', 'sync_forks_missing_branch'
    pre_sha = head
    needs_rebase = (not _is_ancestor(repo, source_sha, head)) or _has_merges(repo, source_sha, head)
    if needs_rebase:
        rebase = git(repo, 'rebase', source_sha)
        if rebase.code != 0:
            _abort_rebase(repo)
            return 'failed', 'sync_forks_rebase_conflict'
        head = _rev(repo, 'HEAD')
        if head is None:
            return 'failed', 'sync_forks_rebase_conflict'
        if _has_merges(repo, source_sha, head):
            if not _dirty(repo):
                git(repo, 'reset', '--hard', pre_sha)
            return 'failed', 'sync_forks_merges_remain'

    if layout.fork == layout.source or layout.fork == 'upstream':
        return 'failed', 'sync_forks_refusing_source'

    if not push:
        if head == pre_sha and (fork_sha is None or head == fork_sha):
            return 'current', 'sync_forks_current'
        return 'updated', 'sync_forks_local_only'

    if fork_sha is not None and head == fork_sha:
        return 'current', 'sync_forks_current'
    if fork_sha is None or _is_ancestor(repo, fork_sha, head):
        pushed = git(
            repo,
            'push',
            layout.fork,
            f'HEAD:refs/heads/{branch}',
            timeout=_FETCH_TIMEOUT,
        )
    else:
        pushed = git(
            repo,
            'push',
            f'--force-with-lease=refs/heads/{branch}:{fork_sha}',
            layout.fork,
            f'HEAD:refs/heads/{branch}',
            timeout=_FETCH_TIMEOUT,
        )
    if pushed.code != 0:
        return 'failed', 'sync_forks_push_failed'
    return 'updated', 'sync_forks_pushed'


def _plan(repo: Path, layout: ForkLayout, branch: str) -> tuple[str, str]:
    source_state = _fetch_branch(repo, layout.source, branch)
    if source_state == 'missing':
        return 'failed', 'sync_forks_action_missing'
    if source_state != 'ok':
        return 'failed', 'sync_forks_fetch_source_failed'
    source_sha = _rev(repo, f'refs/remotes/{layout.source}/{branch}')
    if source_sha is None:
        return 'failed', 'sync_forks_action_missing'

    fork_state = _fetch_branch(repo, layout.fork, branch)
    if fork_state == 'error':
        return 'failed', 'sync_forks_fetch_fork_failed'
    fork_sha = _rev(repo, f'refs/remotes/{layout.fork}/{branch}') if fork_state == 'ok' else None
    local_sha = _rev(repo, f'refs/heads/{branch}')

    tip = local_sha or fork_sha
    if local_sha and fork_sha and local_sha != fork_sha:
        if not _is_ancestor(repo, local_sha, fork_sha) and not _is_ancestor(repo, fork_sha, local_sha):
            return 'failed', 'sync_forks_action_diverged'
        if _is_ancestor(repo, local_sha, fork_sha):
            tip = fork_sha
    if tip is None:
        return 'updated', 'sync_forks_action_ff'
    clean = _is_ancestor(repo, source_sha, tip) and not _has_merges(repo, source_sha, tip)
    if clean and fork_sha == tip:
        return 'current', 'sync_forks_action_current'
    if clean and (fork_sha is None or _is_ancestor(repo, fork_sha, tip)):
        if tip == source_sha and fork_sha in (None, source_sha):
            return 'current', 'sync_forks_action_current'
        return 'updated', 'sync_forks_action_ff'
    if _is_ancestor(repo, tip, source_sha) and not _has_merges(repo, source_sha, tip):
        return 'updated', 'sync_forks_action_ff'
    return 'updated', 'sync_forks_action_rebase'


def update_repo(
    root: Path,
    repo: Path,
    branch: str,
    *,
    dry_run: bool,
    push: bool,
) -> str:
    label = repo_label(root, repo)
    layout = classify_remotes(_remote_urls(repo))
    params = {'repo': label, 'branch': branch, 'remote': layout.fork if layout else ''}
    if layout is None:
        _say('skip', 'sync_forks_skip_not_fork', **params)
        return 'skipped'
    if not _current_branch(repo):
        _say('skip', 'sync_forks_skip_detached', **params)
        return 'skipped'

    if dry_run:
        status, key = _plan(repo, layout, branch)
        if not push and key == 'sync_forks_action_rebase':
            key = 'sync_forks_action_rebase_local'
        level = 'error' if status == 'failed' else 'info'
        _say(level, key, **params)
        return status

    started = _current_branch(repo)
    token = _stash(repo)
    if token == '':
        _say('error', 'sync_forks_stash_failed', **params)
        return 'failed'
    switched = False
    pop_failed = False
    clean_finish = False
    try:
        status, key = _sync_branch(repo, layout, branch, push=push)
        clean_finish = True
    except Exception:
        _abort_rebase(repo)
        raise
    finally:
        if not clean_finish and _rebase_in_progress(repo):
            _abort_rebase(repo)
        if started and _current_branch(repo) != started:
            switched = not _checkout(repo, started)
        if token and not switched:
            pop_failed = not _stash_pop(repo, token)
    level = 'error' if status == 'failed' else 'ok'
    _say(level, key, **params)
    if switched:
        _say('error', 'sync_forks_restore_failed', repo=label, branch=started)
        return 'failed'
    if token and pop_failed:
        conflict_key = 'sync_forks_stash_pop_failed' if status == 'updated' else 'sync_forks_stash_conflict'
        _say('error', conflict_key, repo=label, branch=branch)
        return 'failed'
    return status


def _parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=t('sync_forks_help'))
    parser.add_argument('--dry-run', action='store_true', help=t('sync_forks_help_dry_run'))
    parser.add_argument('--no-push', action='store_true', help=t('sync_forks_help_no_push'))
    parser.add_argument('--branch', default='dev', help=t('sync_forks_help_branch'))
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(sys.argv[1:] if argv is None else argv)
    if not valid_branch(args.branch):
        _say('error', 'sync_forks_bad_branch', branch=args.branch)
        return 2
    root = _root()
    repos = discover_repos(root)
    if not repos:
        _say('error', 'sync_forks_no_checkouts')
        return 1
    if args.dry_run:
        _say('info', 'sync_forks_start_dry', branch=args.branch)
    elif args.no_push:
        _say('info', 'sync_forks_start_local', branch=args.branch)
    else:
        _say('info', 'sync_forks_start', branch=args.branch)
    counts = {'updated': 0, 'current': 0, 'skipped': 0, 'failed': 0}
    for repo in repos:
        status = update_repo(
            root,
            repo,
            args.branch,
            dry_run=args.dry_run,
            push=not args.no_push,
        )
        counts[status if status in counts else 'failed'] += 1
    summary_key = 'sync_forks_summary_dry' if args.dry_run else 'sync_forks_summary'
    payload = {name: str(value) for name, value in counts.items()}
    payload['total'] = str(sum(counts.values()))
    _say('info', summary_key, **payload)
    return 1 if counts['failed'] else 0


if __name__ == '__main__':
    sys.exit(main())
