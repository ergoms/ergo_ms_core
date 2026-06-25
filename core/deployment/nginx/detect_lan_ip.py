"""Определение LAN IPv4 (без зависимостей Django)."""

from __future__ import annotations

import socket


def detect_lan_ip() -> str:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.connect(('8.8.8.8', 80))
            ip = sock.getsockname()[0]
            if ip and not ip.startswith('127.'):
                return ip
    except OSError:
        pass

    try:
        hostname = socket.gethostname()
        ip = socket.gethostbyname(hostname)
        if ip and not ip.startswith('127.'):
            return ip
    except OSError:
        pass

    return ''


def main() -> int:
    print(detect_lan_ip() or '127.0.0.1')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
