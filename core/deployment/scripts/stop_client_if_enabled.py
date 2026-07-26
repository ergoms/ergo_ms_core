"""
Заглушка stop для Vite-клиента (ключ client в multi-terminal).

Процесс Vite завершается вместе с терминалом; отдельная остановка не нужна.
"""

from __future__ import annotations


def main() -> int:
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
