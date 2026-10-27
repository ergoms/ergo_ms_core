"""Показ ergoms help: короткая команда в колонке, длинный вызов на своей строке."""

from __future__ import annotations

import unittest
from pathlib import Path

import _bootstrap  # noqa: F401

from ergoms_help import render_core, render_overview, render_section, resolve_help_subargs  # noqa: E402

_ROOT = Path(__file__).resolve().parents[3]
_COLUMN = 45
_REMOVED = (
    'deployment-test',
    'test_system',
    'test-system',
    'start-all-services',
    'stop-all-services',
    'restart-all-services',
    'status-all-services',
)
_SYSTEM_TEST_INVOKE = (
    'ergoms system-test [--suite unit|install|commands|scenarios|security|performance|browser|os-services|all] '
    '[--launch docker|host|os-services] [--spec host_sqlite_direct] [--strict]'
)


class ErgomsHelpLayoutTests(unittest.TestCase):
    def test_help_layout_across_languages(self) -> None:
        for language in ('ru', 'en', 'fr'):
            with self.subTest(language=language):
                lines = render_core(_ROOT, 'windows', language).splitlines()
                text = '\n'.join(lines)
                for name in _REMOVED:
                    self.assertNotIn(name, text)

                short = next(line for line in lines if 'ergoms start-api-service' in line)
                self.assertTrue(short.startswith('  ergoms start-api-service'))
                self.assertEqual(short[_COLUMN - 1], ' ')
                self.assertNotEqual(short[_COLUMN], ' ')

                index = next(i for i, line in enumerate(lines) if line == f'  {_SYSTEM_TEST_INVOKE}')
                summary = lines[index + 1]
                self.assertTrue(summary.startswith(' ' * _COLUMN))
                self.assertNotEqual(summary[_COLUMN], ' ')

    def test_overview_lists_sections_without_commands(self) -> None:
        for language in ('ru', 'en', 'fr'):
            with self.subTest(language=language):
                text = render_overview(_ROOT, 'windows', language)
                lines = text.splitlines()
                self.assertLess(len(lines), 50)
                self.assertIn('  services', text)
                self.assertIn('  dev ', text)
                self.assertNotIn('builtin_services', text)
                self.assertNotIn('service_aliases', text)
                self.assertIn('ergoms help all', text)
                self.assertNotIn('ergoms start-api-service', text)

    def test_section_help_shows_only_that_section(self) -> None:
        services = render_section(_ROOT, 'windows', 'services', 'ru')
        self.assertEqual(services, render_section(_ROOT, 'windows', 'builtin_services', 'ru'))
        self.assertIn('ergoms start ', services)
        self.assertNotIn('ergoms system-test', services)
        self.assertNotIn('ergoms docker-up', services)

        development = render_section(_ROOT, 'windows', 'dev', 'ru')
        self.assertEqual(development, render_section(_ROOT, 'windows', 'development', 'ru'))
        self.assertIn('ergoms start-all', development)

        separate = render_section(_ROOT, 'windows', 'os-services', 'ru')
        self.assertIn('ergoms start-api-service', separate)
        self.assertNotIn('ergoms system-test', separate)

    def test_unknown_section_is_rejected(self) -> None:
        with self.assertRaises(SystemExit):
            render_section(_ROOT, 'windows', 'no-such-section', 'ru')

    def test_help_args_resolve_overview_all_and_section(self) -> None:
        self.assertEqual(resolve_help_subargs([]), ('overview', None))
        self.assertEqual(resolve_help_subargs(['all']), ('all', None))
        self.assertEqual(resolve_help_subargs(['development']), ('section', 'development'))
        self.assertEqual(resolve_help_subargs(['modules']), ('modules', None))


if __name__ == '__main__':
    unittest.main()
