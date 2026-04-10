$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
. "$ScriptDir\lib.ps1"

Set-Location $RootDir

Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "=      Начало проверки команд системы.          =" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan

Step "1. Проверка команд базы данных"
Log "Выполнение ergoms db-makemigrations"
try {
    ergoms db-makemigrations
    Log "db-makemigrations: OK"
} catch {
    Log "[WARNING] db-makemigrations завершился с ошибкой"
}

Log "Выполнение ergoms db-migrate"
try {
    ergoms db-migrate
    Log "db-migrate: OK"
} catch {
    Log "[WARNING] db-migrate завершился с ошибкой"
}

Step "2. Проверка команды очистки (clean)"
Log "Выполнение ergoms clean"
try {
    ergoms clean
    Log "clean: OK"
} catch {
    Log "[WARNING] clean завершился с ошибкой"
}

Step "3. Проверка команды логов (logs)"
Log "Выполнение ergoms logs ergo-api-dev 10"
try {
    ergoms logs ergo-api-dev 10
    Log "logs ergo-api-dev: OK"
} catch {
    Log "[WARNING] logs ergo-api-dev завершился с ошибкой"
}

Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "=     Проверка команд системы завершена.        =" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan
