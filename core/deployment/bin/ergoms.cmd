@echo off
REM Локальная обёртка ergoms (core/deployment/bin): только из каталога проекта и подпапок.
setlocal EnableExtensions
for %%I in ("%~dp0..\..\..") do set "ERGO_MS_ROOT=%%~fI"
REM Полный путь: в VS Code tasks ${env:PATH} на Windows часто пуст (переменная Path),
REM и голый powershell.exe даёт exit 9009.
set "ERGO_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%ERGO_POWERSHELL%" set "ERGO_POWERSHELL=powershell.exe"
"%ERGO_POWERSHELL%" -ExecutionPolicy Bypass -NoProfile -File "%~dp0..\windows\invoke_ergoms.ps1" %*
exit /b %ERRORLEVEL%
