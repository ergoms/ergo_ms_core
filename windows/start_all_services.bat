@echo off
setlocal enableextensions

REM ========================================================================
REM УСТАРЕЛО: Этот файл сохранён для обратной совместимости
REM 
REM Рекомендуется использовать новую систему управления службами Windows:
REM   - Установка служб: powershell -ExecutionPolicy Bypass -File ergo_ms.ps1 install
REM   - Запуск: ergoms start (или powershell -File ergo_ms.ps1 start)
REM   - Остановка: ergoms stop
REM   - Перезапуск: ergoms restart
REM   - Статус: ergoms status
REM 
REM Или используйте задачи VS Code: Services: Install, Services: Start и т.д.
REM ========================================================================

echo.
echo ========================================================================
echo ВНИМАНИЕ: Используется устаревший способ запуска служб
echo.
echo Рекомендуется установить службы Windows для автоматического управления:
echo   powershell -ExecutionPolicy Bypass -File "%~dp0ergo_ms.ps1" install
echo.
echo Или используйте задачи VS Code:
echo   - Services: Install  - установить службы Windows
echo   - Services: Start    - запустить все службы
echo   - Services: Stop     - остановить все службы
echo   - Services: Status   - проверить статус служб
echo ========================================================================
echo.
timeout /t 5

REM Root directory of the project (folder where this .bat is located, parent of windows/)
cd /d "%~dp0"
cd ..
set ROOT=%CD%
set CORE_DIR=%ROOT%\core
set VENV_ACTIVATE=%ROOT%\virtual_env\python\Scripts\activate.bat

REM Optional checks and friendly messages
if not exist "%CORE_DIR%\api" (
  echo [WARN] Похоже, что путь к API некорректен: %CORE_DIR%\api
)
if not exist "%CORE_DIR%\client" (
  echo [WARN] Похоже, что путь к Client некорректен: %CORE_DIR%\client
)
if not exist "%VENV_ACTIVATE%" (
  echo [WARN] Виртуальное окружение не найдено: %VENV_ACTIVATE%
)

REM Start Client (Vite dev server)
start "Client" cmd /k "cd /d %CORE_DIR% && npm run dev"

REM Start API (Django dev)
start "API" cmd /k "cd /d %CORE_DIR% && call %VENV_ACTIVATE% && api dev"

REM Start Celery Worker
start "Celery Worker" cmd /k "cd /d %CORE_DIR% && call %VENV_ACTIVATE% && api start_celery_worker"

REM Start Celery Beat
start "Celery Beat" cmd /k "cd /d %CORE_DIR% && call %VENV_ACTIVATE% && api start_celery_beat"

endlocal
