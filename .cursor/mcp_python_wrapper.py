"""
Кроссплатформенная обертка для запуска Python скриптов MCP
Автоматически определяет правильный путь к Python интерпретатору на Windows и Linux

Эта обертка может запускаться системным Python (из PATH) и автоматически найдет
правильный Python из виртуального окружения проекта.
"""

import os
import subprocess
import sys
from pathlib import Path

_cursor_dir = Path(__file__).parent.resolve()
if str(_cursor_dir) not in sys.path:
    sys.path.insert(0, str(_cursor_dir))
from os_abstraction import get_venv_python_path


def find_python_executable():
    """
    Находит правильный Python интерпретатор для виртуального окружения

    Returns:
        str: Путь к Python интерпретатору
    """
    script_dir = Path(__file__).parent.absolute()
    project_root = script_dir.parent.absolute()
    venv_dir = project_root / 'virtual_env' / 'python'

    python_path = get_venv_python_path(venv_dir)

    if not python_path.exists():
        error_msg = (
            f"ОШИБКА: Python интерпретатор не найден по пути: {python_path}\n"
            f"Проверьте, что виртуальное окружение установлено правильно.\n"
            f"Проект: {project_root}\n"
            f"Виртуальное окружение: {venv_dir}"
        )
        print(error_msg, file=sys.stderr)
        sys.exit(1)
    
    return str(python_path)


def main():
    """Главная функция - запускает целевой скрипт с правильным Python"""
    if len(sys.argv) < 2:
        print("Использование: mcp_python_wrapper.py <script_path> [args...]", file=sys.stderr)
        sys.exit(1)
    
    # Находим Python интерпретатор из виртуального окружения
    python_exe = find_python_executable()
    
    # Получаем путь к целевому скрипту и аргументы
    script_path = sys.argv[1]
    script_args = sys.argv[2:]
    
    # Преобразуем относительный путь в абсолютный, если нужно
    if not os.path.isabs(script_path):
        # Если путь относительный, делаем его относительно корня проекта
        script_dir = Path(__file__).parent.absolute()
        project_root = script_dir.parent.absolute()
        script_path = str(project_root / script_path)
    
    # Проверяем существование скрипта
    if not os.path.exists(script_path):
        print(f"ОШИБКА: Скрипт не найден: {script_path}", file=sys.stderr)
        sys.exit(1)
    
    # Запускаем скрипт
    try:
        subprocess.run(
            [python_exe, script_path] + script_args,
            check=True
        )
    except subprocess.CalledProcessError as e:
        sys.exit(e.returncode)
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == '__main__':
    main()

