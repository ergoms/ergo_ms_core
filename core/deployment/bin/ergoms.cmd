@echo off
REM Локальная обёртка ergoms (core/deployment/bin): только из каталога проекта и подпапок.
setlocal EnableExtensions
for %%I in ("%~dp0..\..\..") do set "ERGO_MS_ROOT=%%~fI"
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0..\windows\invoke_ergoms.ps1" %*
exit /b %ERRORLEVEL%
