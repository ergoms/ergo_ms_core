from __future__ import annotations

import json
import tempfile
import time
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

import _bootstrap  # noqa: F401

from cursor_browser_queue import (  # noqa: E402
    acquire,
    heartbeat,
    hook_before,
    hook_session,
    is_browser_mcp,
    is_ssh_session,
    owner_id,
    queue_paths,
    release,
)
from project_layout import cache_cursor_browser_queue_dir  # noqa: E402


class CursorBrowserQueueTests(unittest.TestCase):
    def test_ssh_env_and_override(self) -> None:
        self.assertTrue(is_ssh_session(environ={'SSH_CONNECTION': '1 2 3 4'}, pid=1))
        self.assertFalse(is_ssh_session(environ={'CURSOR_BROWSER_QUEUE': '0', 'SSH_CONNECTION': '1'}, pid=1))
        self.assertTrue(is_ssh_session(environ={'CURSOR_BROWSER_QUEUE': '1'}, pid=1))
        self.assertFalse(is_ssh_session(environ={}, pid=1))

    def test_browser_mcp_filter(self) -> None:
        self.assertTrue(is_browser_mcp({'mcp_server_name': 'cursor-ide-browser', 'tool_name': 'browser_navigate'}))
        self.assertTrue(is_browser_mcp({'server': 'cursor-ide-browser', 'tool_name': 'browser_tabs'}))
        self.assertTrue(is_browser_mcp({'tool_name': 'browser_snapshot'}))
        self.assertFalse(is_browser_mcp({'mcp_server_name': 'user-eamodio.gitlens-extension-GitKraken', 'tool_name': 'git_status'}))

    def test_owner_prefers_conversation(self) -> None:
        self.assertEqual(
            owner_id({'conversation_id': 'c1', 'session_id': 's1'}),
            'c1',
        )

    def test_queue_lives_in_project_cache(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            state_path, _, log_path = queue_paths(root)
            self.assertTrue(str(state_path).startswith(str(cache_cursor_browser_queue_dir(root))))
            result = acquire(root, 'chat-a', tool='browser_navigate', wait_seconds=1, poll_seconds=0.01)
            self.assertTrue(result['ok'])
            self.assertTrue(state_path.exists())
            self.assertTrue(log_path.exists())
            state = json.loads(state_path.read_text(encoding='utf-8'))
            self.assertEqual(state['holder']['id'], 'chat-a')

    def test_second_owner_waits_then_times_out(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.assertTrue(acquire(root, 'chat-a', wait_seconds=1, poll_seconds=0.01)['ok'])
            started = time.monotonic()
            result = acquire(root, 'chat-b', wait_seconds=0.3, poll_seconds=0.05)
            self.assertFalse(result['ok'])
            self.assertGreaterEqual(time.monotonic() - started, 0.25)
            state = json.loads(queue_paths(root)[0].read_text(encoding='utf-8'))
            self.assertEqual(state['holder']['id'], 'chat-a')
            waiter_ids = [row['id'] for row in state['waiters']]
            self.assertNotIn('chat-b', waiter_ids)

    def test_same_owner_reenters(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.assertTrue(acquire(root, 'chat-a', tool='browser_navigate')['ok'])
            self.assertTrue(acquire(root, 'chat-a', tool='browser_snapshot')['ok'])
            heartbeat(root, 'chat-a', tool='browser_click')
            release(root, 'chat-a')
            state = json.loads(queue_paths(root)[0].read_text(encoding='utf-8'))
            self.assertIsNone(state['holder'])

    def test_stale_holder_is_stolen(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            old = (datetime.now(timezone.utc) - timedelta(seconds=400)).replace(microsecond=0).isoformat()
            acquire(root, 'chat-a')
            state_path = queue_paths(root)[0]
            state = json.loads(state_path.read_text(encoding='utf-8'))
            state['holder']['heartbeat_at'] = old
            state['holder']['acquired_at'] = old
            state_path.write_text(json.dumps(state), encoding='utf-8')
            result = acquire(root, 'chat-b', idle_seconds=60, wait_seconds=1, poll_seconds=0.01)
            self.assertTrue(result['ok'])
            self.assertEqual(result['state']['holder']['id'], 'chat-b')

    def test_hook_skips_without_ssh(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            payload = {
                'mcp_server_name': 'cursor-ide-browser',
                'tool_name': 'browser_navigate',
                'conversation_id': 'c1',
            }
            with patch('cursor_browser_queue.is_ssh_session', return_value=False):
                decision = hook_before(payload, root)
            self.assertEqual(decision.get('permission'), 'allow')
            self.assertFalse(queue_paths(root)[0].exists())
            with patch('cursor_browser_queue.is_ssh_session', return_value=False):
                self.assertEqual(hook_session(root), {})
            with patch('cursor_browser_queue.is_ssh_session', return_value=True):
                started = hook_session(root)
            self.assertEqual(started.get('env', {}).get('CURSOR_BROWSER_QUEUE'), '1')
            self.assertIn('virtual_env/cache/cursor_browser_queue', started.get('additional_context', ''))

    def test_hook_before_allows_holder(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            payload = {
                'mcp_server_name': 'cursor-ide-browser',
                'tool_name': 'browser_navigate',
                'conversation_id': 'c1',
            }
            with patch('cursor_browser_queue.is_ssh_session', return_value=True):
                decision = hook_before(payload, root)
            self.assertEqual(decision.get('permission'), 'allow')
            state = json.loads(queue_paths(root)[0].read_text(encoding='utf-8'))
            self.assertEqual(state['holder']['id'], 'c1')


if __name__ == '__main__':
    unittest.main()
