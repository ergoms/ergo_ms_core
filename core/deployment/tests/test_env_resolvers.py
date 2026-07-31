from __future__ import annotations

import unittest

import _bootstrap  # noqa: F401

from env_resolvers import resolve_nginx_vars  # noqa: E402


class EnvResolversTests(unittest.TestCase):
    def test_resolve_nginx_vars_https_flag(self) -> None:
        resolved = resolve_nginx_vars({'NGINX_USE_HTTPS': 'true', 'NGINX_SERVER_NAME': 'localhost'})
        self.assertEqual(resolved['NGINX_LISTEN_HOST'], '127.0.0.1')
        self.assertIn('NGINX_PUBLIC_HOST', resolved)

    def test_resolve_nginx_vars_listen_port_443(self) -> None:
        resolved = resolve_nginx_vars({'NGINX_LISTEN_PORT': '443', 'NGINX_SERVER_NAME': 'app.example.com'})
        self.assertEqual(resolved['NGINX_LISTEN_HOST'], '127.0.0.1')
        self.assertEqual(resolved['NGINX_SERVER_NAME'], 'app.example.com')

    def test_resolve_nginx_vars_http_defaults(self) -> None:
        resolved = resolve_nginx_vars({'NGINX_SERVER_NAME': 'localhost'})
        self.assertEqual(resolved['NGINX_LISTEN_PORT'], '80')
        self.assertEqual(resolved['NGINX_LISTEN_HOST'], '0.0.0.0')


if __name__ == '__main__':
    unittest.main()
