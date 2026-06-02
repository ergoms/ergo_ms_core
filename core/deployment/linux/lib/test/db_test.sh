#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
enable_test_traps

cd "$ROOT_DIR"

step "Проверка подключения к базам данных (Django ORM и SQLAlchemy)"
ERGO_TEST_CURRENT_STEP="db: connections"

require_python_venv

py_bin="$ROOT_DIR/virtual_env/python/bin/python"
if [[ ! -x "$py_bin" ]]; then
  echo "Не найден python venv: $py_bin" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
tmp_script="$tmp_dir/test_db.py"

cat >"$tmp_script" <<'PY'
import os
import sys
import django
from django.db import connections
import sqlalchemy as sa
from sqlalchemy.sql import text

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "src.config.patterns.test")
django.setup()

from django.conf import settings
from src.core.utils.database.config_manager import DjangoDatabaseConfigLoader
from src.config.settings.base import SYSTEM_DIR

print("--- Проверка Django ORM ---")
all_ok = True

for alias in settings.DATABASES:
    print(f"Тестирование БД (Django ORM) [{alias}]...")
    try:
        conn = connections[alias]
        with conn.cursor() as cursor:
            cursor.execute("SELECT 1")
            row = cursor.fetchone()
            if row and row[0] == 1:
                print(f"  [OK] Django ORM подключение к {alias} успешно.")
            else:
                print(f"  [ERROR] Django ORM подключение к {alias} вернуло неожиданный результат: {row}")
                all_ok = False
    except Exception as e:
        print(f"  [ERROR] Ошибка Django ORM подключения к {alias}: {e}")
        all_ok = False

print("\n--- Проверка SQLAlchemy ---")
loader = DjangoDatabaseConfigLoader(
    system_dir=SYSTEM_DIR,
    resources_dir=SYSTEM_DIR / "virtual_env" / "resources",
    test_connections=False,
)
raw_config = loader._load_yaml_config() or {}

if not raw_config:
    print("  [SKIP] databases.yaml не найден или пуст, пропускаем SQLAlchemy тесты.")
else:
    from urllib.parse import quote_plus

    for db_name, db_config in raw_config.items():
        print(f"Тестирование БД (SQLAlchemy) [{db_name}]...")
        engine_type = (db_config.get("engine", "postgresql") or "postgresql").lower()
        host = db_config.get("host", "localhost")
        port = db_config.get("port", 5432)
        user = db_config.get("user", "")
        password = db_config.get("password", "")
        name = db_config.get("name", "")

        user_q = quote_plus(str(user))
        pwd_q = quote_plus(str(password))

        if engine_type == "postgresql":
            url = f"postgresql://{user_q}:{pwd_q}@{host}:{port}/{name}"
        elif engine_type == "mysql":
            url = f"mysql+mysqlconnector://{user_q}:{pwd_q}@{host}:{port}/{name}"
        elif engine_type == "sqlite":
            url = f"sqlite:///{name}"
        elif engine_type == "mssql":
            url = f"mssql+pyodbc://{user_q}:{pwd_q}@{host}:{port}/{name}?driver=ODBC+Driver+17+for+SQL+Server"
        else:
            print(f"  [SKIP] Неизвестный движок {engine_type} для {db_name}")
            continue

        try:
            connect_args = {}
            if engine_type == "postgresql":
                connect_args["connect_timeout"] = 5
            elif engine_type == "mysql":
                connect_args["connection_timeout"] = 5
            elif engine_type == "sqlite":
                connect_args["timeout"] = 5
            elif engine_type == "mssql":
                connect_args["timeout"] = 5

            engine = sa.create_engine(url, connect_args=connect_args)
            with engine.connect() as conn:
                result = conn.execute(text("SELECT 1")).fetchone()
                if result and result[0] == 1:
                    print(f"  [OK] SQLAlchemy подключение к {db_name} успешно.")
                else:
                    print(f"  [ERROR] SQLAlchemy подключение к {db_name} вернуло неожиданный результат: {result}")
                    all_ok = False
        except Exception as e:
            print(f"  [ERROR] Ошибка SQLAlchemy подключения к {db_name}: {e}")
            all_ok = False

if not all_ok:
    sys.exit(1)
print("\nВсе проверки баз данных успешно пройдены.")
sys.exit(0)
PY

export PYTHONPATH="$tmp_dir:$ROOT_DIR:$ROOT_DIR/core/api"
if "$py_bin" "$tmp_script"; then
  log "db_test: OK (all connections successful)"
else
  log "[ERROR] db_test: FAILED (connection errors)"
  rm -rf "$tmp_dir" 2>/dev/null || true
  exit 1
fi

rm -rf "$tmp_dir" 2>/dev/null || true

