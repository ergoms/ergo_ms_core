@echo off
setlocal enableextensions

REM Root directory of the project (folder where this .bat is located)
set ROOT=%~dp0
set API_DIR=%ROOT%api
set CLIENT_DIR=%ROOT%client

REM Optional checks and friendly messages
if not exist "%API_DIR%\src\manage.py" (
  echo [WARN] Похоже, что путь к API некорректен: %API_DIR%
)
if not exist "%CLIENT_DIR%\package.json" (
  echo [WARN] Похоже, что путь к Client некорректен: %CLIENT_DIR%
)

REM Start Client (Vite dev server)
start "Client" cmd /k "cd /d %CLIENT_DIR% && npm run dev"

REM Start API (Django dev)
start "API" cmd /k "cd /d %API_DIR% && call .venv\Scripts\activate.bat && api dev"

REM Start Celery Worker
start "Celery Worker" cmd /k "cd /d %API_DIR% && call .venv\Scripts\activate.bat && api start_celery_worker"

REM Start Celery Beat
start "Celery Beat" cmd /k "cd /d %API_DIR% && call .venv\Scripts\activate.bat && api start_celery_beat"

endlocal
