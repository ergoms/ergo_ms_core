"""Кластерный план Celery: доли очередей, placement, стек Swarm."""

from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import yaml

import _bootstrap  # noqa: F401

from celery_balance.cluster_plan import (  # noqa: E402
    NodeView,
    apply_cluster_share,
    plan_cluster,
)
from celery_balance.constants import CLASS_HEAVY, PLACEMENT_ANY, PLACEMENT_GPU, PLACEMENT_PRIMARY  # noqa: E402
from celery_balance.footprint_loader import (  # noqa: E402
    FootprintCatalog,
    TaskFootprint,
    _parse_task,
)
from celery_balance.planner import WorkerPlan  # noqa: E402
from celery_balance.settings import load_settings  # noqa: E402
from generate_swarm_stack import render_stack  # noqa: E402


def _node(node_id: str, *, primary: bool, ram: float = 8000, cpu: float = 8, gpu: bool = False, vram: float = 0) -> NodeView:
    devices = ((0, vram),) if gpu else ()
    return NodeView(
        node_id=node_id,
        primary=primary,
        celery_ram_budget_mb=ram,
        celery_cpu_budget=cpu,
        cpu_count=cpu,
        gpu_available=gpu,
        vram_free_mb=vram,
        utilization_pct=0,
        devices=devices,
    )


def _spec(queue: str, **kwargs) -> TaskFootprint:
    values = dict(
        queue=queue,
        pattern='',
        task_class=CLASS_HEAVY,
        ram_mb=512,
        cpu_units=1,
        gpu_required=False,
        vram_mb=0,
        max_parallel=4,
        cpu_fallback=True,
        module='sample',
        placement=PLACEMENT_ANY,
    )
    values.update(kwargs)
    return TaskFootprint(**values)


def _catalog(*specs: TaskFootprint) -> FootprintCatalog:
    return FootprintCatalog(tasks=specs, by_queue={item.queue: item for item in specs})


def _settings():
    from celery_balance.settings import BalanceSettings

    return BalanceSettings(
        mode='auto',
        os_reserve_ram_mb=0,
        reserve_cpu=0,
        min_concurrency=1,
        max_concurrency=None,
        gpu_enabled=True,
        gpu_util_cap=80,
        watch_interval_sec=30,
        hysteresis_ratio=0.2,
        cluster='on',
        cluster_role='manager',
        node_id='primary',
        node_ttl_sec=90,
    )


class ClusterPlanTests(unittest.TestCase):
    def test_any_queue_splits_across_two_nodes(self) -> None:
        plans = plan_cluster(
            [_node('primary', primary=True), _node('worker', primary=False)],
            all_queues=['sample_q'],
            catalog=_catalog(_spec('sample_q', max_parallel=4)),
            settings=_settings(),
            depths={},
            history={},
        )
        by_id = {item.node_id: item for item in plans}
        self.assertEqual(
            by_id['primary'].queue_limits['sample_q'] + by_id['worker'].queue_limits['sample_q'],
            4,
        )
        self.assertGreater(by_id['primary'].queue_limits['sample_q'], 0)
        self.assertGreater(by_id['worker'].queue_limits['sample_q'], 0)

    def test_missing_node_keeps_the_whole_share(self) -> None:
        plans = plan_cluster(
            [_node('primary', primary=True)],
            all_queues=['sample_q'],
            catalog=_catalog(_spec('sample_q', placement=PLACEMENT_ANY, max_parallel=4)),
            settings=_settings(),
            depths={},
            history={},
        )
        self.assertEqual(plans[0].queue_limits['sample_q'], 4)

    def test_primary_placement_stays_on_primary(self) -> None:
        plans = plan_cluster(
            [_node('primary', primary=True), _node('worker', primary=False)],
            all_queues=['sample_q'],
            catalog=_catalog(_spec('sample_q', placement=PLACEMENT_PRIMARY, max_parallel=3)),
            settings=_settings(),
            depths={},
            history={},
        )
        by_id = {item.node_id: item for item in plans}
        self.assertEqual(by_id['primary'].queue_limits['sample_q'], 3)
        self.assertNotIn('sample_q', by_id['worker'].queues)

    def test_gpu_queue_skips_node_without_card(self) -> None:
        plans = plan_cluster(
            [
                _node('primary', primary=True, gpu=False),
                _node('worker', primary=False, gpu=True, vram=8192),
            ],
            all_queues=['sample_q'],
            catalog=_catalog(_spec(
                'sample_q',
                placement=PLACEMENT_GPU,
                gpu_required=True,
                vram_mb=4096,
                cpu_fallback=False,
                max_parallel=2,
            )),
            settings=_settings(),
            depths={},
            history={},
        )
        by_id = {item.node_id: item for item in plans}
        self.assertNotIn('sample_q', by_id['primary'].queues)
        self.assertEqual(by_id['worker'].queue_limits['sample_q'], 2)

    def test_small_node_keeps_a_slot_when_ceiling_allows(self) -> None:
        from celery_balance.cluster_plan import _split

        self.assertEqual(_split(2, [100, 5]), [1, 1])

    def test_share_lowers_local_limit(self) -> None:
        from celery_balance.cluster_plan import NodePlan

        local = WorkerPlan(
            name='all',
            hostname='all',
            queues=['sample_q'],
            pool='threads',
            yaml_concurrency=8,
            concurrency=4,
            prefetch_multiplier=1,
            autoscale_min=None,
            autoscale_max=None,
            gpu_required=False,
            queue_limits={'sample_q': 4},
        )
        apply_cluster_share(
            [local],
            NodePlan(
                node_id='primary',
                primary=True,
                queues=['sample_q'],
                concurrency=1,
                prefetch_multiplier=1,
                queue_limits={'sample_q': 1},
                queue_classes={},
                pause_queues=[],
            ),
        )
        self.assertEqual(local.queue_limits['sample_q'], 1)


class PlacementParseTests(unittest.TestCase):
    def test_default_placement_is_primary(self) -> None:
        parsed = _parse_task(
            {'queue': 'sample_q'},
            module='sample',
            defaults={},
            path=Path('task_footprint.yaml'),
        )
        self.assertIsNotNone(parsed)
        assert parsed is not None
        self.assertEqual(parsed.placement, PLACEMENT_PRIMARY)

    def test_unknown_placement_falls_back(self) -> None:
        parsed = _parse_task(
            {'queue': 'sample_q', 'placement': 'both'},
            module='sample',
            defaults={},
            path=Path('task_footprint.yaml'),
        )
        assert parsed is not None
        self.assertEqual(parsed.placement, PLACEMENT_PRIMARY)


class ClusterSettingsTests(unittest.TestCase):
    def test_cluster_off_by_default(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with patch.dict(os.environ, {'CELERY_CLUSTER': '', 'ERGO_NODE_ID': 'node-a'}, clear=False):
                os.environ.pop('CELERY_CLUSTER', None)
                settings = load_settings(root)
        self.assertEqual(settings.cluster, 'off')
        self.assertFalse(settings.cluster_enabled)
        self.assertEqual(settings.node_id, 'node-a')


class SwarmStackTests(unittest.TestCase):
    def test_stack_places_workers_and_optional_gpu(self) -> None:
        text = render_stack(
            image='registry.example/ergo-worker:local',
            manager_host='10.0.0.1',
            databases_file='/tmp/databases.yaml',
            env_file='/tmp/dotenv',
            gpu=True,
        )
        data = yaml.safe_load(text)
        worker = data['services']['ergo-celery-worker']
        self.assertIn('node.labels.ergo.worker == true', worker['deploy']['placement']['constraints'])
        self.assertEqual(worker['deploy']['mode'], 'global')
        self.assertIn('NVIDIA-GPU', text)
        self.assertIn('ergo-celery-agent', data['services'])
        self.assertEqual(worker['environment']['REDIS_HOST'], '10.0.0.1')


if __name__ == '__main__':
    unittest.main()
