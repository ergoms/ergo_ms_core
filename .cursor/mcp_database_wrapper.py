"""
Обертка для запуска MCP сервера PostgreSQL с динамической загрузкой конфигурации из databases.yaml
"""

import subprocess
import sys
from pathlib import Path

import yaml

_cursor_dir = Path(__file__).parent.resolve()
if str(_cursor_dir) not in sys.path:
    sys.path.insert(0, str(_cursor_dir))
from os_abstraction import get_npx_executable


def load_db_config(db_name='default'):
    """
    Загружает конфигурацию базы данных из databases.yaml
    
    Args:
        db_name: Имя базы данных из конфигурации (default, celery_worker, celery_beat)
    
    Returns:
        str: Строка подключения PostgreSQL
    """
    project_dir = Path(__file__).parent.parent.absolute()
    databases_yaml = project_dir / 'databases.yaml'
    
    if not databases_yaml.exists():
        print(f"ОШИБКА: Файл databases.yaml не найден: {databases_yaml}", file=sys.stderr)
        sys.exit(1)
    
    try:
        with open(databases_yaml, 'r', encoding='utf-8') as f:
            config = yaml.safe_load(f)
        
        if not config or 'databases' not in config:
            print("ОШИБКА: Неверный формат файла databases.yaml", file=sys.stderr)
            sys.exit(1)
        
        db_config = config['databases'].get(db_name)
        if not db_config:
            print(f"ОШИБКА: Конфигурация для БД '{db_name}' не найдена", file=sys.stderr)
            sys.exit(1)
        
        # Формируем строку подключения
        user = db_config.get('user')
        password = db_config.get('password')
        host = db_config.get('host')
        port = db_config.get('port', 5432)
        name = db_config.get('name')
        
        connection_string = f"postgresql://{user}:{password}@{host}:{port}/{name}"
        return connection_string
        
    except Exception as e:
        print(f"ОШИБКА при загрузке конфигурации: {e}", file=sys.stderr)
        sys.exit(1)


def main():
    """
    Главная функция - загружает конфигурацию и запускает MCP сервер PostgreSQL
    """
    # Получаем имя БД из аргументов или используем default
    db_name = sys.argv[1] if len(sys.argv) > 1 else 'default'
    
    # Загружаем строку подключения
    connection_string = load_db_config(db_name)
    
    npx_executable = get_npx_executable()
    if not npx_executable:
        print("ОШИБКА: npx не найден в PATH. Установите Node.js и перезапустите терминал.", file=sys.stderr)
        sys.exit(1)

    # Запускаем MCP сервер PostgreSQL с полученной строкой подключения
    try:
        subprocess.run(
            [
                npx_executable,
                '-y',
                '@modelcontextprotocol/server-postgres',
                connection_string
            ],
            check=True
        )
    except subprocess.CalledProcessError as e:
        print(f"ОШИБКА при запуске MCP сервера: {e}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("\nMCP сервер остановлен", file=sys.stderr)
        sys.exit(0)


if __name__ == '__main__':
    main()

