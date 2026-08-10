from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest import mock

import _bootstrap  # noqa: F401

import render_nginx_config  # noqa: E402
from lifecycle.docker.ops import render_nginx_docker_config  # noqa: E402
from render_common import (  # noqa: E402
    CORE_PROXY_MARKER,
    build_core_proxy_locations,
    build_docker_upstream_blocks,
    build_host_upstream_blocks,
    render_docker_nginx_config,
)


class NginxRenderTests(unittest.TestCase):
    def test_shared_core_proxy_locations_for_host_and_docker(self) -> None:
        host_block = build_core_proxy_locations(variant='host')
        docker_block = build_core_proxy_locations(variant='docker')
        self.assertIn(CORE_PROXY_MARKER, host_block)
        self.assertIn(CORE_PROXY_MARKER, docker_block)
        self.assertIn('proxy_pass http://ergo_media', host_block)
        self.assertIn('proxy_pass http://ergo_media', docker_block)

    def test_upstream_targets_differ_host_vs_docker(self) -> None:
        values = {
            'API_PORT': '8000',
            'MEDIA_API_BIND_PORT': '8003',
            'DOCKER_SERVICE_API': 'api',
            'DOCKER_SERVICE_MEDIA': 'media-api',
        }
        host_api, host_media = build_host_upstream_blocks(values)
        docker_api, docker_media = build_docker_upstream_blocks(values)
        self.assertIn('127.0.0.1:8000', host_api)
        self.assertIn('127.0.0.1:8003', host_media)
        self.assertIn('api:8000', docker_api)
        self.assertIn('media-api:8003', docker_media)

    def test_host_and_docker_renderers_use_shared_function(self) -> None:
        deployment_dir = Path(__file__).resolve().parents[1]
        docker_template = deployment_dir / 'docker' / 'nginx' / 'ergo_ms.docker.conf.template'
        host_template = deployment_dir / 'nginx' / 'ergo_ms_http.conf.template'
        raw_env = {
            'DOCKER_SERVICE_API': 'api',
            'DOCKER_SERVICE_MEDIA': 'media-api',
            'API_PORT': '9001',
            'MEDIA_API_BIND_PORT': '9003',
            'NGINX_LISTEN_PORT': '8080',
            'NGINX_SERVER_NAME': 'test.local',
        }

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / '.env').write_text(
                'API_PORT=9001\nMEDIA_API_BIND_PORT=9003\n',
                encoding='utf-8',
            )
            out = Path(tmp) / 'docker.conf'
            render_docker_nginx_config(raw_env, template_path=docker_template, output_path=out)
            docker_rendered = out.read_text(encoding='utf-8')

            host_rendered = render_nginx_config.render_template(
                host_template,
                root=root,
                server_name='test.local',
                listen_host='0.0.0.0',
                listen_port='8080',
                use_https=False,
            )

        self.assertIn('api:9001', docker_rendered)
        self.assertIn('127.0.0.1:9001', host_rendered)
        self.assertIn(CORE_PROXY_MARKER, docker_rendered)
        self.assertIn(CORE_PROXY_MARKER, host_rendered)

    def test_ops_wrapper_delegates_to_shared_renderer(self) -> None:
        deployment_dir = Path(__file__).resolve().parents[1]
        docker_template = deployment_dir / 'docker' / 'nginx' / 'ergo_ms.docker.conf.template'
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'ergo_ms.conf.rendered'
            with mock.patch('lifecycle.docker.ops.DOCKER_DIR', Path(tmp)):
                with mock.patch(
                    'render_common.render_docker_nginx_config',
                    wraps=render_docker_nginx_config,
                ) as mocked:
                    (Path(tmp) / 'nginx').mkdir()
                    (Path(tmp) / 'nginx' / 'ergo_ms.docker.conf.template').write_text(
                        docker_template.read_text(encoding='utf-8'),
                        encoding='utf-8',
                    )
                    render_nginx_docker_config({'API_PORT': '8000'})
                    mocked.assert_called_once()

    def test_client_max_body_size_from_upload_limits(self) -> None:
        """tasks 600 MiB + 10% margin → 660m (hard не выше tasks)."""
        deployment_dir = Path(__file__).resolve().parents[1]
        docker_template = deployment_dir / 'docker' / 'nginx' / 'ergo_ms.docker.conf.template'
        host_template = deployment_dir / 'nginx' / 'ergo_ms_http.conf.template'
        raw_env = {
            'DOCKER_SERVICE_API': 'api',
            'DOCKER_SERVICE_MEDIA': 'media-api',
            'API_PORT': '8000',
            'MEDIA_API_BIND_PORT': '8003',
            'MEDIA_UPLOAD_MAX_SIZE': '524288000',
            'MEDIA_UPLOAD_HARD_MAX_SIZE': '524288000',
            'TASKS_MAX_ATTACHMENT_SIZE_MB': '600',
            'CLIENT_VIDEO_UPLOAD_MAX_SIZE_MB': '100',
            'NGINX_UPLOAD_BODY_MARGIN_PERCENT': '10',
            'NGINX_LISTEN_PORT': '80',
            'NGINX_SERVER_NAME': 'localhost',
        }

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / '.env').write_text(
                'MEDIA_UPLOAD_MAX_SIZE=524288000\n'
                'MEDIA_UPLOAD_HARD_MAX_SIZE=524288000\n'
                'TASKS_MAX_ATTACHMENT_SIZE_MB=600\n'
                'CLIENT_VIDEO_UPLOAD_MAX_SIZE_MB=100\n',
                encoding='utf-8',
            )
            out = Path(tmp) / 'docker.conf'
            render_docker_nginx_config(raw_env, template_path=docker_template, output_path=out)
            docker_rendered = out.read_text(encoding='utf-8')
            host_rendered = render_nginx_config.render_template(
                host_template,
                root=root,
                server_name='localhost',
                listen_host='0.0.0.0',
                listen_port='80',
                use_https=False,
            )

        self.assertIn('client_max_body_size 660m;', docker_rendered)
        self.assertIn('client_max_body_size 660m;', host_rendered)
        self.assertNotIn('610m', docker_rendered)
        self.assertNotIn('610m', host_rendered)
        self.assertNotIn('${ERGO_CLIENT_MAX_BODY_SIZE}', docker_rendered)
        self.assertNotIn('${ERGO_CLIENT_MAX_BODY_SIZE}', host_rendered)

    def test_docker_nginx_parity_with_host_http(self) -> None:
        """С6: headers, rate zones/limits, /health/ deny в Docker-рендере."""
        deployment_dir = Path(__file__).resolve().parents[1]
        docker_template = deployment_dir / 'docker' / 'nginx' / 'ergo_ms.docker.conf.template'
        raw_env = {
            'DOCKER_SERVICE_API': 'api',
            'DOCKER_SERVICE_MEDIA': 'media-api',
            'API_PORT': '8000',
            'MEDIA_API_BIND_PORT': '8003',
            'NGINX_LISTEN_PORT': '80',
            'NGINX_SERVER_NAME': 'localhost',
        }
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'docker.conf'
            render_docker_nginx_config(raw_env, template_path=docker_template, output_path=out)
            rendered = out.read_text(encoding='utf-8')

        self.assertIn('server_tokens off', rendered)
        self.assertIn('limit_req_zone', rendered)
        self.assertIn('X-Frame-Options', rendered)
        self.assertIn('limit_req zone=ergo_api', rendered)
        self.assertIn('limit_req zone=ergo_upload', rendered)
        self.assertNotIn('5r/m', rendered)
        self.assertIn('rate=120r/m', rendered)
        self.assertIn('limit_req_status 429', rendered)
        self.assertIn('burst=25', rendered)
        self.assertIn('location /health/', rendered)
        health = rendered[rendered.find('location /health/'):]
        self.assertIn('deny all', health[:240])
        self.assertIn('/api/realtime/stream/', rendered)
        self.assertIn(r'location ~ ^/api/.+/stream/?$', rendered)
        self.assertIn('proxy_buffering off;', rendered)


if __name__ == '__main__':
    unittest.main()
