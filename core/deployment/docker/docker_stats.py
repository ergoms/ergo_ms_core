"""
Потребление RAM/CPU контейнеров Docker Compose ERGO MS.

Вызывается из docker_cli.py stats и ergoms docker-stats.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

DOCKER_DIR = Path(__file__).resolve().parent
DEPLOYMENT_DIR = DOCKER_DIR.parent
PROJECT_ROOT = DEPLOYMENT_DIR.parent.parent

if str(DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(DEPLOYMENT_DIR))
if str(DOCKER_DIR) not in sys.path:
    sys.path.insert(0, str(DOCKER_DIR))

from cli_locale import t  # noqa: E402
from console_tags import format_console  # noqa: E402
from lifecycle.docker import ops as docker_ops  # noqa: E402

_MEMORY_RE = re.compile(
    r'^([\d.]+)\s*(B|KiB|MiB|GiB|TiB|KB|MB|GB|TB)$',
    re.IGNORECASE,
)


@dataclass(frozen=True)
class ContainerStats:
    name: str
    memory_used_mib: float
    memory_limit_mib: float | None
    memory_percent: float
    cpu_percent: float
    memory_usage: str


def parse_memory_to_mib(raw: str) -> float | None:
    value = (raw or '').strip()
    if not value or value == '--':
        return None
    match = _MEMORY_RE.match(value)
    if not match:
        return None
    amount = float(match.group(1))
    unit = match.group(2).lower()
    if unit == 'b':
        return amount / (1024 * 1024)
    if unit in ('kib', 'kb'):
        return amount / 1024
    if unit in ('mib', 'mb'):
        return amount
    if unit in ('gib', 'gb'):
        return amount * 1024
    if unit in ('tib', 'tb'):
        return amount * 1024 * 1024
    return None


def parse_memory_usage_field(value: str) -> tuple[float | None, float | None, str]:
    parts = [part.strip() for part in (value or '').split('/', 1)]
    used = parse_memory_to_mib(parts[0]) if parts else None
    limit = parse_memory_to_mib(parts[1]) if len(parts) > 1 else None
    return used, limit, value.strip()


def parse_cpu_percent(value: str) -> float:
    cleaned = (value or '').strip().rstrip('%')
    try:
        return round(float(cleaned), 1)
    except ValueError:
        return 0.0


def list_container_ids(*, mode: str | None = None) -> list[str]:
    if not docker_ops.find_docker_compose():
        return []
    cmd, cwd = docker_ops.build_compose_cmd('ps', mode=mode, extra_args=['-q'])
    result = subprocess.run(cmd, cwd=str(cwd), capture_output=True, text=True, check=False)
    if result.returncode != 0:
        return []
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def collect_container_stats(*, mode: str | None = None) -> list[ContainerStats]:
    container_ids = list_container_ids(mode=mode)
    if not container_ids:
        return []

    compose_bin = docker_ops.find_docker_compose()
    if not compose_bin:
        return []

    stats_cmd = [
        'docker',
        'stats',
        '--no-stream',
        '--format',
        '{{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.CPUPerc}}',
        *container_ids,
    ]
    result = subprocess.run(stats_cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        return []

    rows: list[ContainerStats] = []
    for line in result.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split('\t')
        if len(parts) < 4:
            continue
        name, mem_usage, mem_percent_raw, cpu_percent_raw = parts[:4]
        used_mib, limit_mib, mem_usage_text = parse_memory_usage_field(mem_usage)
        rows.append(
            ContainerStats(
                name=name,
                memory_used_mib=round(used_mib or 0.0, 1),
                memory_limit_mib=round(limit_mib, 1) if limit_mib is not None else None,
                memory_percent=parse_cpu_percent(mem_percent_raw),
                cpu_percent=parse_cpu_percent(cpu_percent_raw),
                memory_usage=mem_usage_text,
            )
        )
    rows.sort(key=lambda item: item.name)
    return rows


def build_payload(rows: list[ContainerStats]) -> dict[str, object]:
    total_memory_mib = round(sum(item.memory_used_mib for item in rows), 1)
    return {
        'containers': [
            {
                'name': item.name,
                'memory_usage': item.memory_usage,
                'memory_used_mib': item.memory_used_mib,
                'memory_limit_mib': item.memory_limit_mib,
                'memory_percent': item.memory_percent,
                'cpu_percent': item.cpu_percent,
            }
            for item in rows
        ],
        'container_count': len(rows),
        'total_memory_mib': total_memory_mib,
    }


def print_table(rows: list[ContainerStats]) -> None:
    if not rows:
        print(format_console('info', t('no_ergo_containers')))
        return

    headers = (t('docker_stats_header_container'), t('docker_stats_header_memory'), 'RAM %', 'CPU %')
    table_rows = [
        (
            item.name,
            item.memory_usage,
            f'{item.memory_percent:.1f}',
            f'{item.cpu_percent:.1f}',
        )
        for item in rows
    ]
    widths = [
        max(len(headers[0]), *(len(row[0]) for row in table_rows)),
        max(len(headers[1]), *(len(row[1]) for row in table_rows)),
        max(len(headers[2]), *(len(row[2]) for row in table_rows)),
        max(len(headers[3]), *(len(row[3]) for row in table_rows)),
    ]

    def fmt_row(cols: tuple[str, str, str, str]) -> str:
        return (
            f'{cols[0]:<{widths[0]}}  '
            f'{cols[1]:<{widths[1]}}  '
            f'{cols[2]:>{widths[2]}}  '
            f'{cols[3]:>{widths[3]}}'
        )

    print(fmt_row(headers))
    print('-' * (sum(widths) + 6))
    for row in table_rows:
        print(fmt_row(row))

    total_memory_mib = round(sum(item.memory_used_mib for item in rows), 1)
    print('-' * (sum(widths) + 6))
    print(fmt_row((t('docker_stats_total', count=len(rows)), f'{total_memory_mib:.1f} MiB', '', '')))


def render_once(*, mode: str | None, as_json: bool) -> int:
    if not docker_ops.find_docker_compose():
        print(format_console('error', t('docker_not_found_dot')), file=sys.stderr)
        return 1

    rows = collect_container_stats(mode=mode)
    if as_json:
        print(json.dumps(build_payload(rows), ensure_ascii=False, indent=2))
    else:
        print_table(rows)
    return 0


def run_stats(args: argparse.Namespace) -> int:
    if args.watch:
        if args.interval <= 0:
            print(format_console('error', t('interval_must_be_positive')), file=sys.stderr)
            return 1
        try:
            while True:
                if not args.json and sys.stdout.isatty():
                    print('\033[H\033[J', end='')
                code = render_once(mode=args.mode, as_json=args.json)
                if code != 0:
                    return code
                time.sleep(args.interval)
        except KeyboardInterrupt:
            print()
            return 0

    return render_once(mode=args.mode, as_json=args.json)


def add_stats_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument('--json', action='store_true', help=t('help_json_output'))
    parser.add_argument('-w', '--watch', action='store_true', help=t('help_watch_report'))
    parser.add_argument('--interval', type=float, default=3.0, help=t('help_watch_interval'))
